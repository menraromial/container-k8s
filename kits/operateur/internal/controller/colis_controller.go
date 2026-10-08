/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package controller

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"sort"
	"strings"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/equality"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/client-go/tools/events"
	"k8s.io/utils/ptr"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	logf "sigs.k8s.io/controller-runtime/pkg/log"

	coursv1 "example.com/colis-operateur/api/v1"
)

const (
	registre      = "host.minikube.internal:5001/colis"
	imageWeb      = registre + "/web:1.1"
	imagePostgres = "postgres:18-alpine"
	imageRedis    = "redis:8.8-alpine"
	gestionnaire  = "colis-operateur"
)

// raisons des événements, d'après le résultat de CreateOrUpdate
var raisons = map[controllerutil.OperationResult]string{
	controllerutil.OperationResultCreated: "Cree",
	controllerutil.OperationResultUpdated: "MisAJour",
}

var scaledObjectGVK = schema.GroupVersionKind{Group: "keda.sh", Version: "v1alpha1", Kind: "ScaledObject"}

// ColisReconciler fabrique, pour chaque objet Colis, les objets d'une installation complète.
type ColisReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder events.EventRecorder
}

// Les marqueurs suivants deviennent le ClusterRole de l'opérateur (config/rbac/role.yaml).
// +kubebuilder:rbac:groups=cours.example.com,resources=colis,verbs=get;list;watch
// +kubebuilder:rbac:groups=cours.example.com,resources=colis/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=apps,resources=deployments;statefulsets,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=services;configmaps;secrets,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=keda.sh,resources=scaledobjects,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=events.k8s.io,resources=events,verbs=create;patch

// Reconcile compare l'objet Colis à ce qui existe dans son namespace et corrige l'écart.
// Elle est appelée à chaque changement du Colis ou d'un objet qu'il possède, et doit pouvoir
// être rejouée sans effet de bord : on décrit l'état voulu, on ne compte pas les appels.
func (r *ColisReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := logf.FromContext(ctx)

	var colis coursv1.Colis
	if err := r.Get(ctx, req.NamespacedName, &colis); err != nil {
		// supprimé entre-temps : ses objets partent avec lui (références de propriétaire)
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	// Un seul Colis par namespace : les Services s'appellent api, web, postgres, redis.
	// Le plus ancien gagne ; les autres sont signalés et laissés de côté.
	if premier, err := r.premierDuNamespace(ctx, colis.Namespace); err != nil {
		return ctrl.Result{}, err
	} else if premier != colis.Name {
		err := r.majStatut(ctx, &colis, metav1.ConditionFalse, "AutreColis",
			fmt.Sprintf("le namespace contient déjà le Colis %s", premier), 0)
		if apierrors.IsConflict(err) {
			return ctrl.Result{RequeueAfter: time.Second}, nil
		}
		return ctrl.Result{}, err
	}

	etapes := []struct {
		nom string
		f   func(context.Context, *coursv1.Colis) (controllerutil.OperationResult, error)
	}{
		{"Secret colis-db", r.secretBase},
		{"ConfigMap colis-config", r.configuration},
		{"redis", r.redis},
		{"postgres", r.postgres},
		{"api", r.api},
		{"worker", r.worker},
		{"web", r.web},
	}
	for _, e := range etapes {
		op, err := e.f(ctx, &colis)
		if apierrors.IsConflict(err) {
			// un autre (KEDA, l'utilisateur) a modifié l'objet entre notre lecture et notre
			// écriture : on recommence un peu plus tard, avec la version à jour
			log.V(1).Info("conflit, nouvel essai", "objet", e.nom)
			return ctrl.Result{RequeueAfter: time.Second}, nil
		}
		if err != nil {
			r.Recorder.Eventf(&colis, nil, corev1.EventTypeWarning, "Echec", e.nom, "%s : %v", e.nom, err)
			return ctrl.Result{}, fmt.Errorf("%s : %w", e.nom, err)
		}
		if op != controllerutil.OperationResultNone {
			log.Info("objet "+string(op), "objet", e.nom)
			// l'action (ici le nom du composant) sépare les séries d'événements : l'API
			// events.k8s.io regroupe les événements de même raison et de même action
			r.Recorder.Eventf(&colis, nil, corev1.EventTypeNormal, raisons[op], e.nom, "%s", e.nom)
		}
	}

	attente, pretes, err := r.disponibilite(ctx, colis.Namespace)
	if err != nil {
		return ctrl.Result{}, err
	}
	if len(attente) > 0 {
		err = r.majStatut(ctx, &colis, metav1.ConditionFalse, "EnCours", "en attente : "+strings.Join(attente, ", "), pretes)
	} else {
		err = r.majStatut(ctx, &colis, metav1.ConditionTrue, "Disponible", "tous les composants sont disponibles", pretes)
	}
	if apierrors.IsConflict(err) {
		return ctrl.Result{RequeueAfter: time.Second}, nil
	}
	return ctrl.Result{}, err
}

func (r *ColisReconciler) premierDuNamespace(ctx context.Context, ns string) (string, error) {
	var liste coursv1.ColisList
	if err := r.List(ctx, &liste, client.InNamespace(ns)); err != nil {
		return "", err
	}
	sort.Slice(liste.Items, func(i, j int) bool {
		a, b := liste.Items[i], liste.Items[j]
		if !a.CreationTimestamp.Equal(&b.CreationTimestamp) {
			return a.CreationTimestamp.Before(&b.CreationTimestamp)
		}
		return a.Name < b.Name
	})
	return liste.Items[0].Name, nil
}

// majStatut n'écrit que si quelque chose change : chaque écriture déclenche une nouvelle
// réconciliation, et un statut réécrit à l'identique ferait tourner la boucle pour rien.
func (r *ColisReconciler) majStatut(ctx context.Context, colis *coursv1.Colis, etat metav1.ConditionStatus,
	raison, message string, pretes int32) error {
	avant := colis.Status.DeepCopy()
	colis.Status.ObservedGeneration = colis.Generation
	colis.Status.APIPretes = pretes
	colis.Status.Selecteur = "app.kubernetes.io/instance=" + colis.Name + ",app.kubernetes.io/name=api"
	meta.SetStatusCondition(&colis.Status.Conditions, metav1.Condition{
		Type: "Prete", Status: etat, Reason: raison, Message: message, ObservedGeneration: colis.Generation,
	})
	if equalStatus(avant, &colis.Status) {
		return nil
	}
	return r.Status().Update(ctx, colis)
}

func equalStatus(a, b *coursv1.ColisStatus) bool {
	if a.ObservedGeneration != b.ObservedGeneration || a.APIPretes != b.APIPretes || a.Selecteur != b.Selecteur ||
		len(a.Conditions) != len(b.Conditions) {
		return false
	}
	for i := range a.Conditions {
		x, y := a.Conditions[i], b.Conditions[i]
		if x.Type != y.Type || x.Status != y.Status || x.Reason != y.Reason || x.Message != y.Message ||
			x.ObservedGeneration != y.ObservedGeneration {
			return false
		}
	}
	return true
}

// disponibilite liste les composants qui n'ont pas encore leurs répliques disponibles.
func (r *ColisReconciler) disponibilite(ctx context.Context, ns string) ([]string, int32, error) {
	var attente []string
	var pretes int32
	for _, nom := range []string{"redis", "api", "web"} {
		var d appsv1.Deployment
		if err := r.Get(ctx, client.ObjectKey{Namespace: ns, Name: nom}, &d); err != nil {
			return nil, 0, client.IgnoreNotFound(err)
		}
		if nom == "api" {
			pretes = d.Status.ReadyReplicas
		}
		voulu := ptr.Deref(d.Spec.Replicas, 1)
		if d.Status.ObservedGeneration < d.Generation || d.Status.UpdatedReplicas < voulu || d.Status.AvailableReplicas < voulu {
			attente = append(attente, fmt.Sprintf("%s (%d/%d)", nom, d.Status.AvailableReplicas, voulu))
		}
	}
	var s appsv1.StatefulSet
	if err := r.Get(ctx, client.ObjectKey{Namespace: ns, Name: "postgres"}, &s); err != nil {
		return nil, 0, client.IgnoreNotFound(err)
	}
	if s.Status.ReadyReplicas < 1 {
		attente = append(attente, "postgres (0/1)")
	}
	return attente, pretes, nil
}

func etiquettes(colis *coursv1.Colis, composant string) map[string]string {
	return map[string]string{
		"app.kubernetes.io/name":       composant,
		"app.kubernetes.io/instance":   colis.Name,
		"app.kubernetes.io/part-of":    "colis",
		"app.kubernetes.io/managed-by": gestionnaire,
	}
}

func selecteur(colis *coursv1.Colis, composant string) *metav1.LabelSelector {
	return &metav1.LabelSelector{MatchLabels: map[string]string{
		"app.kubernetes.io/name": composant, "app.kubernetes.io/instance": colis.Name,
	}}
}

func securitePod(uid int64) *corev1.PodSecurityContext {
	return &corev1.PodSecurityContext{
		RunAsNonRoot: ptr.To(true), RunAsUser: ptr.To(uid), RunAsGroup: ptr.To(uid),
		SeccompProfile: &corev1.SeccompProfile{Type: corev1.SeccompProfileTypeRuntimeDefault},
	}
}

func securiteConteneur() *corev1.SecurityContext {
	return &corev1.SecurityContext{
		AllowPrivilegeEscalation: ptr.To(false), ReadOnlyRootFilesystem: ptr.To(true),
		Capabilities: &corev1.Capabilities{Drop: []corev1.Capability{"ALL"}},
	}
}

// secretBase crée le mot de passe de PostgreSQL une fois, sans jamais le remplacer. Le Secret
// n'appartient pas au Colis : il survit à sa suppression, comme le volume de la base.
func (r *ColisReconciler) secretBase(ctx context.Context, colis *coursv1.Colis) (controllerutil.OperationResult, error) {
	s := &corev1.Secret{ObjectMeta: metav1.ObjectMeta{Name: "colis-db", Namespace: colis.Namespace}}
	return controllerutil.CreateOrUpdate(ctx, r.Client, s, func() error {
		s.Labels = etiquettes(colis, "postgres")
		if len(s.Data["POSTGRES_PASSWORD"]) == 0 {
			octets := make([]byte, 18)
			if _, err := rand.Read(octets); err != nil {
				return err
			}
			s.Data = map[string][]byte{"POSTGRES_PASSWORD": []byte(base64.RawURLEncoding.EncodeToString(octets))}
		}
		return nil
	})
}

func (r *ColisReconciler) configuration(ctx context.Context, colis *coursv1.Colis) (controllerutil.OperationResult, error) {
	cm := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: "colis-config", Namespace: colis.Namespace}}
	return controllerutil.CreateOrUpdate(ctx, r.Client, cm, func() error {
		cm.Labels = etiquettes(colis, "api")
		cm.Data = map[string]string{
			"COLIS_VERSION":     colis.Spec.Version,
			"COLIS_REDIS":       "redis://redis:6379/0",
			"COLIS_PURGE_JOURS": "30",
		}
		return controllerutil.SetControllerReference(colis, cm, r.Scheme)
	})
}

// service crée ou met à jour un Service ClusterIP (ou sans adresse, pour PostgreSQL).
func (r *ColisReconciler) service(ctx context.Context, colis *coursv1.Colis, nom string, port int32,
	sansAdresse bool) (controllerutil.OperationResult, error) {
	svc := &corev1.Service{ObjectMeta: metav1.ObjectMeta{Name: nom, Namespace: colis.Namespace}}
	return controllerutil.CreateOrUpdate(ctx, r.Client, svc, func() error {
		svc.Labels = etiquettes(colis, nom)
		if sansAdresse && svc.CreationTimestamp.IsZero() {
			svc.Spec.ClusterIP = corev1.ClusterIPNone // immuable : seulement à la création
		}
		svc.Spec.Selector = selecteur(colis, nom).MatchLabels
		svc.Spec.Ports = []corev1.ServicePort{{
			Name: nom, Port: port, TargetPort: intstr.FromInt32(port), Protocol: corev1.ProtocolTCP,
		}}
		return controllerutil.SetControllerReference(colis, svc, r.Scheme)
	})
}

// deploiement applique les champs que l'opérateur possède. replicas peut être nil : le champ
// est alors laissé à un autre (KEDA, pour le worker).
func (r *ColisReconciler) deploiement(ctx context.Context, colis *coursv1.Colis, nom string, replicas *int32,
	pod corev1.PodSpec) (controllerutil.OperationResult, error) {
	d := &appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Name: nom, Namespace: colis.Namespace}}
	return controllerutil.CreateOrUpdate(ctx, r.Client, d, func() error {
		d.Labels = etiquettes(colis, nom)
		if d.CreationTimestamp.IsZero() {
			d.Spec.Selector = selecteur(colis, nom) // immuable
		}
		if replicas != nil {
			d.Spec.Replicas = replicas
		}
		d.Spec.Template.Labels = etiquettes(colis, nom)
		remplacer(&d.Spec.Template.Spec, pod)
		return controllerutil.SetControllerReference(colis, d, r.Scheme)
	})
}

func (r *ColisReconciler) redis(ctx context.Context, colis *coursv1.Colis) (controllerutil.OperationResult, error) {
	if op, err := r.service(ctx, colis, "redis", 6379, false); err != nil {
		return op, err
	}
	return r.deploiement(ctx, colis, "redis", ptr.To(int32(1)), corev1.PodSpec{
		SecurityContext: &corev1.PodSecurityContext{
			RunAsNonRoot: ptr.To(true), RunAsUser: ptr.To(int64(999)), RunAsGroup: ptr.To(int64(1000)),
			SeccompProfile: &corev1.SeccompProfile{Type: corev1.SeccompProfileTypeRuntimeDefault},
		},
		Containers: []corev1.Container{{
			Name: "redis", Image: imageRedis,
			Ports:           []corev1.ContainerPort{{Name: "redis", ContainerPort: 6379}},
			ReadinessProbe:  sondeCommande("redis-cli", "ping"),
			SecurityContext: securiteConteneur(),
			VolumeMounts:    []corev1.VolumeMount{{Name: "donnees", MountPath: "/data"}},
		}},
		Volumes: []corev1.Volume{{Name: "donnees", VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}}}},
	})
}

// postgres : le gabarit de volume d'un StatefulSet est immuable, il n'est écrit qu'à la création.
func (r *ColisReconciler) postgres(ctx context.Context, colis *coursv1.Colis) (controllerutil.OperationResult, error) {
	if op, err := r.service(ctx, colis, "postgres", 5432, true); err != nil {
		return op, err
	}
	s := &appsv1.StatefulSet{ObjectMeta: metav1.ObjectMeta{Name: "postgres", Namespace: colis.Namespace}}
	return controllerutil.CreateOrUpdate(ctx, r.Client, s, func() error {
		s.Labels = etiquettes(colis, "postgres")
		if s.CreationTimestamp.IsZero() {
			s.Spec.Selector = selecteur(colis, "postgres")
			s.Spec.ServiceName = "postgres"
			s.Spec.VolumeClaimTemplates = []corev1.PersistentVolumeClaim{{
				ObjectMeta: metav1.ObjectMeta{Name: "donnees", Labels: etiquettes(colis, "postgres")},
				Spec: corev1.PersistentVolumeClaimSpec{
					AccessModes:      []corev1.PersistentVolumeAccessMode{corev1.ReadWriteOnce},
					StorageClassName: ptr.To(colis.Spec.Base.Classe),
					Resources: corev1.VolumeResourceRequirements{Requests: corev1.ResourceList{
						corev1.ResourceStorage: resource.MustParse(colis.Spec.Base.Taille),
					}},
				},
			}}
		}
		s.Spec.Replicas = ptr.To(int32(1))
		s.Spec.Template.Labels = etiquettes(colis, "postgres")
		remplacer(&s.Spec.Template.Spec, corev1.PodSpec{
			SecurityContext: securitePod(70),
			Containers: []corev1.Container{{
				Name: "postgres", Image: imagePostgres,
				Ports: []corev1.ContainerPort{{Name: "postgres", ContainerPort: 5432}},
				Env: []corev1.EnvVar{
					{Name: "POSTGRES_USER", Value: "colis"},
					{Name: "POSTGRES_DB", Value: "colis"},
					motDePasse(),
				},
				ReadinessProbe:  sondeCommande("pg_isready", "-U", "colis", "-d", "colis"),
				SecurityContext: securiteConteneur(),
				VolumeMounts: []corev1.VolumeMount{
					{Name: "donnees", MountPath: "/var/lib/postgresql"},
					{Name: "socket", MountPath: "/var/run/postgresql"},
					{Name: "tmp", MountPath: "/tmp"},
				},
			}},
			Volumes: []corev1.Volume{
				{Name: "socket", VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}}},
				{Name: "tmp", VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}}},
			},
		})
		return controllerutil.SetControllerReference(colis, s, r.Scheme)
	})
}

func motDePasse() corev1.EnvVar {
	return corev1.EnvVar{Name: "POSTGRES_PASSWORD", ValueFrom: &corev1.EnvVarSource{
		SecretKeyRef: &corev1.SecretKeySelector{
			LocalObjectReference: corev1.LocalObjectReference{Name: "colis-db"}, Key: "POSTGRES_PASSWORD",
		},
	}}
}

// conteneurColis : l'image de l'API sert aussi au worker, avec une autre commande.
func conteneurColis(colis *coursv1.Colis, nom string) corev1.Container {
	return corev1.Container{
		Name:  nom,
		Image: registre + "/api:" + colis.Spec.Version,
		Env: []corev1.EnvVar{
			motDePasse(),
			{Name: "COLIS_DB", Value: "postgresql://colis:$(POSTGRES_PASSWORD)@postgres:5432/colis"},
		},
		EnvFrom: []corev1.EnvFromSource{{ConfigMapRef: &corev1.ConfigMapEnvSource{
			LocalObjectReference: corev1.LocalObjectReference{Name: "colis-config"},
		}}},
		SecurityContext: securiteConteneur(),
	}
}

func (r *ColisReconciler) api(ctx context.Context, colis *coursv1.Colis) (controllerutil.OperationResult, error) {
	if op, err := r.service(ctx, colis, "api", 8000, false); err != nil {
		return op, err
	}
	c := conteneurColis(colis, "api")
	c.Ports = []corev1.ContainerPort{{Name: "http", ContainerPort: 8000}}
	c.ReadinessProbe = sondeHTTP("/pret", 5)
	c.LivenessProbe = sondeHTTP("/sante", 10)
	return r.deploiement(ctx, colis, "api", ptr.To(colis.Spec.API.Replicas), corev1.PodSpec{
		SecurityContext: securitePod(10001), Containers: []corev1.Container{c},
	})
}

// worker : le nombre de répliques appartient à KEDA. L'opérateur ne le fixe qu'à la création,
// sans quoi chaque réconciliation annulerait la décision de l'autoscaler.
func (r *ColisReconciler) worker(ctx context.Context, colis *coursv1.Colis) (controllerutil.OperationResult, error) {
	c := conteneurColis(colis, "worker")
	c.Command = []string{"python", "-m", "colis.worker"}
	c.Ports = []corev1.ContainerPort{{Name: "metriques", ContainerPort: 9101}}
	var existant appsv1.Deployment
	var replicas *int32
	err := r.Get(ctx, client.ObjectKey{Namespace: colis.Namespace, Name: "worker"}, &existant)
	if apierrors.IsNotFound(err) {
		replicas = ptr.To(colis.Spec.Worker.Min)
	} else if err != nil {
		return controllerutil.OperationResultNone, err
	}
	op, err := r.deploiement(ctx, colis, "worker", replicas, corev1.PodSpec{
		SecurityContext: securitePod(10001), Containers: []corev1.Container{c},
	})
	if err != nil {
		return op, err
	}
	so := &unstructured.Unstructured{}
	so.SetGroupVersionKind(scaledObjectGVK)
	so.SetName("worker")
	so.SetNamespace(colis.Namespace)
	_, err = controllerutil.CreateOrUpdate(ctx, r.Client, so, func() error {
		so.SetLabels(etiquettes(colis, "worker"))
		voulu := map[string]any{
			"scaleTargetRef":  map[string]any{"name": "worker"},
			"minReplicaCount": int64(colis.Spec.Worker.Min),
			"maxReplicaCount": int64(colis.Spec.Worker.Max),
			"pollingInterval": int64(5),
			"cooldownPeriod":  int64(30),
			"triggers": []any{map[string]any{
				"type": "redis",
				"metadata": map[string]any{
					"address":    "redis." + colis.Namespace + ".svc.cluster.local:6379",
					"listName":   "colis:a-estimer",
					"listLength": "5",
				},
			}},
		}
		if actuel, ok := so.Object["spec"].(map[string]any); !ok || !equality.Semantic.DeepDerivative(voulu, actuel) {
			so.Object["spec"] = voulu
		}
		return controllerutil.SetControllerReference(colis, so, r.Scheme)
	})
	return op, err
}

func (r *ColisReconciler) web(ctx context.Context, colis *coursv1.Colis) (controllerutil.OperationResult, error) {
	if op, err := r.service(ctx, colis, "web", 80, false); err != nil {
		return op, err
	}
	return r.deploiement(ctx, colis, "web", ptr.To(colis.Spec.Web.Replicas), corev1.PodSpec{
		SecurityContext: securitePod(101),
		Containers: []corev1.Container{{
			Name: "web", Image: imageWeb,
			Ports:           []corev1.ContainerPort{{Name: "http", ContainerPort: 80}},
			ReadinessProbe:  sondeHTTP("/", 5),
			SecurityContext: securiteConteneur(),
			VolumeMounts: []corev1.VolumeMount{
				{Name: "cache", MountPath: "/var/cache/nginx"},
				{Name: "run", MountPath: "/run"},
			},
		}},
		Volumes: []corev1.Volume{
			{Name: "cache", VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}}},
			{Name: "run", VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}}},
		},
	})
}

// remplacer n'écrit le gabarit voulu que s'il diffère de l'existant. L'API server complète
// chaque gabarit de valeurs par défaut (imagePullPolicy, terminationMessagePath, dnsPolicy...) :
// comparé tel quel, un gabarit écrit sans elles paraît toujours différent, et l'opérateur
// renverrait l'objet à chaque passage. DeepDerivative ignore les champs que le gabarit voulu
// laisse vides.
func remplacer(actuel *corev1.PodSpec, voulu corev1.PodSpec) {
	if !equality.Semantic.DeepDerivative(voulu, *actuel) {
		*actuel = voulu
	}
}

func sondeHTTP(chemin string, periode int32) *corev1.Probe {
	return &corev1.Probe{
		ProbeHandler:  corev1.ProbeHandler{HTTPGet: &corev1.HTTPGetAction{Path: chemin, Port: intstr.FromString("http")}},
		PeriodSeconds: periode, TimeoutSeconds: 1, FailureThreshold: 3, SuccessThreshold: 1,
	}
}

func sondeCommande(cmd ...string) *corev1.Probe {
	return &corev1.Probe{
		ProbeHandler:  corev1.ProbeHandler{Exec: &corev1.ExecAction{Command: cmd}},
		PeriodSeconds: 5, TimeoutSeconds: 1, FailureThreshold: 3, SuccessThreshold: 1,
	}
}

// SetupWithManager déclare ce que le contrôleur surveille : les Colis, et les objets qu'ils
// possèdent. Un changement sur un Deployment possédé réveille la réconciliation de son Colis.
func (r *ColisReconciler) SetupWithManager(mgr ctrl.Manager) error {
	so := &unstructured.Unstructured{}
	so.SetGroupVersionKind(scaledObjectGVK)
	return ctrl.NewControllerManagedBy(mgr).
		For(&coursv1.Colis{}).
		Owns(&appsv1.Deployment{}).
		Owns(&appsv1.StatefulSet{}).
		Owns(&corev1.Service{}).
		Owns(&corev1.ConfigMap{}).
		Owns(so).
		Named("colis").
		Complete(r)
}
