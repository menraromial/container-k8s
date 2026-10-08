---
title: Écrire un opérateur
sidebar_label: 55. Écrire un opérateur
description: "Un opérateur en Go avec kubebuilder pour le type Colis : le projet généré, les types et leurs marqueurs, la boucle de réconciliation de controller-runtime, les références de propriétaire, le piège des réécritures, la dérive corrigée, la mise à l'échelle et la montée de version, les tests avec envtest, l'image, le déploiement et les métriques."
partie: 8
chapitre: '55'
---

import operateurBoucle from '@site/src/figures/operateur-boucle.svg';
import operateurObjets from '@site/src/figures/operateur-objets.svg';

`kubectl apply` d'un objet `Colis` répond `created`, et c'est tout. Aucun Pod ne démarre, aucun Service n'apparaît : la définition du type accepte l'objet, le valide, le range dans etcd, et personne ne le lit. Pour qu'un objet `Colis` devienne une installation de l'application, il faut un programme qui le surveille, crée les Deployments, les Services et le volume de la base, puis les maintient dans l'état décrit, quoi qu'il arrive. Ce programme est un **opérateur**.

Le mot vient d'un article de CoreOS publié en novembre 2016. Brandon Philips y décrit un opérateur comme un contrôleur propre à une application, qui étend l'API de Kubernetes pour créer, configurer et gérer des instances d'applications complexes au nom de l'utilisateur, en codant dans un logiciel le savoir d'un administrateur humain[^coreos]. L'article s'appuyait sur les ThirdPartyResources, l'ancêtre des CRD. La documentation de Kubernetes reprend l'idée : un opérateur suit le principe de la boucle de contrôle (chapitre 15), appliqué à des ressources personnalisées[^operateur].

Ce chapitre écrit cet opérateur en Go, avec kubebuilder, l'outil de génération de projet maintenu par le groupe API Machinery de Kubernetes, et la bibliothèque controller-runtime sur laquelle il repose[^kubebuilder]. Les fichiers sont dans [l'archive operateur](pathname:///kits/operateur.tar.gz) : le projet complet, tel qu'il est à la fin du chapitre.

## Les outils

kubebuilder génère un projet Go ; il faut donc Go sur le poste, et le binaire `kubebuilder` lui-même, téléchargé depuis la page de ses versions :

```bash
go version
curl -sL -o ~/.local/bin/kubebuilder \
  https://github.com/kubernetes-sigs/kubebuilder/releases/download/v4.16.0/kubebuilder_linux_amd64
chmod +x ~/.local/bin/kubebuilder
kubebuilder version
```

```sortie
go version go1.26.0 linux/amd64
KubeBuilder:          v4.16.0
Kubernetes:           1.37.0
```

Les autres outils (le générateur de code `controller-gen`, `kustomize`, les binaires de test) sont téléchargés par le `Makefile` du projet, dans son dossier `bin/`, à la première commande qui en a besoin.

## Le projet généré

Deux commandes créent le projet. `init` pose le squelette : un programme principal, un `Makefile`, une image, les manifestes de déploiement. `create api` ajoute un type, son contrôleur et ses tests :

```bash
mkdir colis-operateur && cd colis-operateur
kubebuilder init --domain example.com --repo example.com/colis-operateur --project-name colis-operateur
kubebuilder create api --group cours --version v1 --kind Colis --plural colis --resource --controller
```

```sortie
# kubebuilder init ...
INFO Get controller runtime 
INFO Update dependencies 
Next: define a resource with:
  $ kubebuilder create api
durée : 5,76 s
# kubebuilder create api ...
Next: implement your new API and generate the manifests (e.g. CRDs,CRs) with:
  $ make manifests
durée : 7,80 s
```

La première fois, `init` a pris 2 min 38 s, presque entièrement passées à télécharger les dépendances Go ; avec le cache de modules rempli, quelques secondes suffisent. Le groupe `cours` et le domaine `example.com` donnent le groupe d'API `cours.example.com`, celui du chapitre 54. Le projet compte 54 fichiers hors du dossier bin/, dont 10 en Go :

```sortie
.custom-gcl.yml
.dockerignore
.gitignore
.golangci.yml
AGENTS.md
Dockerfile
Makefile
PROJECT
README.md
api/v1/colis_types.go
api/v1/groupversion_info.go
api/v1/zz_generated.deepcopy.go
cmd/main.go
config/crd/kustomization.yaml
config/crd/kustomizeconfig.yaml
config/default/cert_metrics_manager_patch.yaml
config/default/kustomization.yaml
config/default/manager_metrics_patch.yaml
config/default/metrics_service.yaml
config/manager/kustomization.yaml
config/manager/manager.yaml
config/network-policy/allow-metrics-traffic.yaml
config/network-policy/kustomization.yaml
config/prometheus/kustomization.yaml
config/prometheus/monitor.yaml
config/prometheus/monitor_tls_patch.yaml
config/rbac/colis_admin_role.yaml
config/rbac/colis_editor_role.yaml
config/rbac/colis_viewer_role.yaml
config/rbac/kustomization.yaml
config/rbac/leader_election_role.yaml
config/rbac/leader_election_role_binding.yaml
config/rbac/metrics_auth_role.yaml
config/rbac/metrics_auth_role_binding.yaml
config/rbac/metrics_reader_role.yaml
config/rbac/role.yaml
config/rbac/role_binding.yaml
config/rbac/service_account.yaml
config/samples/cours_v1_colis.yaml
config/samples/kustomization.yaml
go.mod
go.sum
hack/boilerplate.go.txt
internal/controller/colis_controller.go
internal/controller/colis_controller_test.go
internal/controller/suite_test.go
test/e2e/e2e_suite_test.go
test/e2e/e2e_test.go
test/utils/utils.go
```

Quatre endroits comptent. `api/v1/colis_types.go` décrit le type en Go. `internal/controller/colis_controller.go` contient la fonction de réconciliation. `cmd/main.go` crée le **manager**, l'objet de controller-runtime qui ouvre la connexion à l'API server, tient les caches, lance les contrôleurs, sert les sondes et les métriques, et organise l'élection d'un chef quand plusieurs copies tournent. Le dossier `config/` contient les manifestes Kustomize (chapitre 30) qui installent la CRD, les rôles RBAC et le Deployment de l'opérateur. `zz_generated.deepcopy.go` est produit par `controller-gen` et ne se modifie jamais à la main. Le projet contient aussi un fichier `AGENTS.md`, destiné aux assistants de programmation, et une configuration de conteneur de développement (`.devcontainer`) ; ni l'un ni l'autre ne servent ici.

## Le type, en Go

Au chapitre 54, le schéma était écrit en YAML. Avec kubebuilder, on écrit des structures Go, et des commentaires spéciaux, les **marqueurs** (`// +kubebuilder:...`), portent ce que Go ne sait pas dire : bornes, motifs, valeurs par défaut, règles CEL, sous-ressources, colonnes[^marqueurs]. Le schéma du chapitre 54 se retrouve presque mot pour mot :

```go title="api/v1/colis_types.go (extrait)"
// ColisSpec décrit l'installation voulue. Les marqueurs // +kubebuilder:... deviennent
// le schéma OpenAPI et les règles CEL de la CustomResourceDefinition (make manifests).
// +kubebuilder:validation:XValidation:rule="semver(self.version).compareTo(semver(oldSelf.version)) >= 0",message="pas de retour à une version antérieure"
// +kubebuilder:validation:XValidation:rule="self.worker.max <= 4 * self.api.replicas",messageExpression="'worker.max doit rester sous 4 × api.replicas, soit %d'.format([4 * self.api.replicas])"
type ColisSpec struct {
	// Version de l'image de l'API et du worker.
	// +kubebuilder:validation:Pattern=`^[0-9]+\.[0-9]+\.[0-9]+$`
	// +kubebuilder:validation:MaxLength=20
	// +required
	Version string `json:"version"`

	// +kubebuilder:default={}
	// +optional
	API APISpec `json:"api,omitzero"`

	// +kubebuilder:default={min: 0, max: 5}
	// +optional
	Worker WorkerSpec `json:"worker,omitzero"`

	// +kubebuilder:default={}
	// +optional
	Web WebSpec `json:"web,omitzero"`

	// +kubebuilder:default={}
	// +optional
	Base BaseSpec `json:"base,omitzero"`
}

type APISpec struct {
	// Nombre de répliques de l'API.
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=10
	// +kubebuilder:default=2
	// +optional
	Replicas int32 `json:"replicas,omitempty"`
}

// Le worker est mis à l'échelle par KEDA d'après la longueur de la file Redis.
// +kubebuilder:validation:XValidation:rule="self.min <= self.max",messageExpression="'min (%d) dépasse max (%d)'.format([self.min, self.max])"
type WorkerSpec struct {
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:default=0
	// +optional
	Min int32 `json:"min"`

	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=20
	// +kubebuilder:default=5
	// +optional
	Max int32 `json:"max,omitempty"`
}

type WebSpec struct {
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=10
	// +kubebuilder:default=2
	// +optional
	Replicas int32 `json:"replicas,omitempty"`
}

type BaseSpec struct {
	// Taille du volume de PostgreSQL, fixée à la création.
	// +kubebuilder:validation:Pattern=`^[0-9]+(Mi|Gi)$`
	// +kubebuilder:validation:MaxLength=10
	// +kubebuilder:validation:XValidation:rule="self == oldSelf",message="la taille de la base ne change pas après la création"
	// +kubebuilder:default="1Gi"
	// +optional
	Taille string `json:"taille,omitempty"`

	// +kubebuilder:validation:Enum=standard;csi-hostpath-sc
	// +kubebuilder:default=standard
	// +optional
	Classe string `json:"classe,omitempty"`
}

// ColisStatus est écrit par l'opérateur seul, par la sous-ressource status.
type ColisStatus struct {
	// La génération de spec que l'opérateur a traitée en dernier.
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`

	// Répliques de l'API prêtes : lu par la sous-ressource scale.
	// +optional
	APIPretes int32 `json:"apiPretes,omitempty"`

	// Sélecteur des Pods de l'API, pour un HorizontalPodAutoscaler.
	// +optional
	Selecteur string `json:"selecteur,omitempty"`

	// Prete : tous les composants ont leurs répliques disponibles.
	// +listType=map
	// +listMapKey=type
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:subresource:scale:specpath=.spec.api.replicas,statuspath=.status.apiPretes,selectorpath=.status.selecteur
// +kubebuilder:resource:shortName=cl,categories=cours
// +kubebuilder:printcolumn:name="Version",type=string,JSONPath=`.spec.version`
// +kubebuilder:printcolumn:name="API",type=integer,JSONPath=`.spec.api.replicas`
// +kubebuilder:printcolumn:name="Prête",type=string,JSONPath=`.status.conditions[?(@.type=="Prete")].status`
// +kubebuilder:printcolumn:name="Raison",type=string,JSONPath=`.status.conditions[?(@.type=="Prete")].reason`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`
```

Deux différences avec le chapitre 54. La taille de la base porte maintenant la règle `self == oldSelf` : l'opérateur crée le volume une fois, et un StatefulSet ne permet pas de modifier son gabarit de volume ensuite. Le statut a trois champs, écrits par l'opérateur : `observedGeneration`, le nombre de répliques de l'API prêtes (lu par la sous-ressource `scale`), et une liste de conditions au format standard `metav1.Condition`, celui que recommandent les conventions de l'API de Kubernetes[^conventions].

`make manifests` lit les marqueurs et écrit la CRD ; `make generate` écrit les fonctions de copie profonde :

```bash
make manifests generate
grep -c "" config/crd/bases/cours.example.com_colis.yaml
```

```sortie
bin/controller-gen rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=config/crd/bases
bin/controller-gen object:headerFile="hack/boilerplate.go.txt",year=2026 paths="./..."
229
```

Une définition de 229 lignes, qu'on n'écrit plus à la main. Les mêmes marqueurs dans le contrôleur produisent le ClusterRole de l'opérateur.

## La boucle de réconciliation

controller-runtime fait presque tout le travail qui entoure la réconciliation. Le manager ouvre un *watch* sur chaque type que le contrôleur déclare, garde une copie locale de chaque objet (le cache), et transforme chaque événement en une **clé**, `namespace/nom`, déposée dans une file de travail. La fonction `Reconcile` reçoit ces clés une à une.

<Figure svg={operateurBoucle} num="55.1" alt="L'API server à gauche, avec les types Colis, Deployment, StatefulSet, Service, ConfigMap et ScaledObject. À droite, dans l'opérateur : 1, les caches et informateurs reçoivent les watch de l'API server ; un changement de Colis donne la clé ch55/principal (For), un changement d'un objet possédé donne la clé de son propriétaire, lue dans ownerReferences (Owns) ; 2, ces clés vont dans la file de travail, sans doublon et avec nouvel essai à délai croissant ; 3, Reconcile(ch55/principal) lit dans le cache, compare, crée ou modifie et écrit le statut ; 4, ses écritures (Create, Update, Status().Update) vont à l'API server et reviennent par le watch. La boucle s'arrête quand Reconcile n'a plus rien à écrire.">
La boucle d'un opérateur écrit avec controller-runtime. Reconcile ne reçoit qu'une clé, jamais l'événement qui l'a provoquée.
</Figure>

Un point de conception découle de ce schéma : `Reconcile` ne sait pas pourquoi elle est appelée. Elle reçoit `ch55/principal`, pas « le Deployment `api` vient d'être supprimé ». Elle doit donc comparer l'état voulu à l'état réel, tout entier, à chaque appel. On parle de contrôleur déclenché par niveau (*level-triggered*), par opposition à un programme qui réagirait à chaque événement (*edge-triggered*) : si des événements se perdent, si l'opérateur redémarre, la prochaine réconciliation rattrape tout. La file dédoublonne les clés : plusieurs changements rapprochés sur les objets d'un même `Colis` peuvent ne donner qu'une réconciliation.

La fonction de l'opérateur :

```go title="internal/controller/colis_controller.go (extrait)"
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
```

Chaque étape appelle `controllerutil.CreateOrUpdate`, qui lit l'objet (dans le cache), le crée s'il manque, sinon applique une fonction de modification et n'envoie une mise à jour que si l'objet a changé[^controllerutil]. Le Deployment, par exemple :

```go title="internal/controller/colis_controller.go (extrait)"
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
```

`SetControllerReference` ajoute au Deployment une **référence de propriétaire** (`ownerReferences`) vers le `Colis`, marquée `controller: true`. Elle sert deux fois. Le ramasse-miettes de Kubernetes supprime les objets dont le propriétaire a disparu (chapitre 36) ; et controller-runtime s'en sert pour remonter d'un objet modifié à la clé de son propriétaire. C'est ce que déclare la fin du fichier :

```go title="internal/controller/colis_controller.go (extrait)"
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
```

`For` désigne le type principal, `Owns` les types possédés : un changement sur un Deployment possédé par un `Colis` déclenche la réconciliation de ce `Colis`. Le ScaledObject de KEDA n'a pas de type Go dans le projet ; on le manipule comme un objet générique (`unstructured.Unstructured`), en donnant son groupe, sa version et son type.

Les droits de l'opérateur sont déclarés au même endroit, par des marqueurs placés au-dessus de `Reconcile`. `make manifests` en tire `config/rbac/role.yaml` :

```go title="internal/controller/colis_controller.go (extrait)"
// +kubebuilder:rbac:groups=cours.example.com,resources=colis,verbs=get;list;watch
// +kubebuilder:rbac:groups=cours.example.com,resources=colis/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=apps,resources=deployments;statefulsets,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=services;configmaps;secrets,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=keda.sh,resources=scaledobjects,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=events.k8s.io,resources=events,verbs=create;patch
```

L'opérateur peut lire les `Colis` et écrire leur statut, mais pas modifier leur `spec` : c'est l'utilisateur qui décrit ce qu'il veut, l'opérateur qui constate et agit.

## Premier lancement

Pendant le développement, l'opérateur tourne sur le poste, avec les droits de votre `kubeconfig`. `make install` installe la CRD, `make run` compile et lance le manager :

```bash
make install
make run          # dans un terminal à part ; ici : bin/manager après make build
kubectl create namespace ch55
kubectl apply -f principal.yaml
```

```yaml title="principal.yaml"
apiVersion: cours.example.com/v1
kind: Colis
metadata:
  name: principal
  namespace: ch55
spec:
  version: 2.2.0
```

L'état du `Colis`, relevé chaque seconde pendant le démarrage :

```sortie
1,33 s  EnCours : en attente : api (0/2), web (0/2), postgres (0/1)
2,46 s  EnCours : en attente : api (0/2), postgres (0/1)
6,87 s  EnCours : en attente : api (0/2)
15,7 s  EnCours : en attente : api (1/2)
27,9 s  Disponible : tous les composants sont disponibles
NAME        VERSION   API   PRÊTE   RAISON       AGE
principal   2.2.0     2     True    Disponible   28s
```

En 28 secondes, l'installation est complète. La condition `Prete` donne à chaque instant la liste de ce qui manque, avec le nombre de répliques disponibles : c'est le genre d'information qu'on cherchait à la main au chapitre 48, posée cette fois dans le statut de l'objet. Ce qui a été créé :

```bash
kubectl -n ch55 get deploy,sts,svc,scaledobject,cm,secret,pvc
kubectl -n ch55 get deploy api -o jsonpath='{.metadata.ownerReferences}'
kubectl -n ch55 events --for colis.cours.example.com/principal
```

```sortie
NAME                     READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/api      2/2     2            2           28s
deployment.apps/redis    1/1     1            1           28s
deployment.apps/web      2/2     2            2           27s
deployment.apps/worker   0/0     0            0           28s

NAME                        READY   AGE
statefulset.apps/postgres   1/1     28s

NAME               TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
service/api        ClusterIP   10.99.73.208    <none>        8000/TCP   28s
service/postgres   ClusterIP   None            <none>        5432/TCP   28s
service/redis      ClusterIP   10.111.91.94    <none>        6379/TCP   28s
service/web        ClusterIP   10.97.213.248   <none>        80/TCP     27s

NAME                          SCALETARGETKIND      SCALETARGETNAME   MIN   MAX   READY   ACTIVE   FALLBACK   PAUSED   TRIGGERS   AUTHENTICATIONS   AGE
scaledobject.keda.sh/worker   apps/v1.Deployment   worker            0     5     True    False    False      False    redis                        28s

NAME                         DATA   AGE
configmap/colis-config       3      28s
configmap/kube-root-ca.crt   1      28s

NAME              TYPE     DATA   AGE
secret/colis-db   Opaque   1      28s

NAME                                       STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
persistentvolumeclaim/donnees-postgres-0   Bound    pvc-a822716e-8c9d-4efd-9042-ea207e983f5d   1Gi        RWO            standard       <unset>                 28s
{"kind":"Colis","name":"principal","controller":true,"blockOwnerDeletion":true}
Secret colis-db, propriétaires : 
LAST SEEN   TYPE     REASON   OBJECT            MESSAGE
28s         Normal   Cree     Colis/principal   Secret colis-db
28s         Normal   Cree     Colis/principal   ConfigMap colis-config
28s         Normal   Cree     Colis/principal   redis
28s         Normal   Cree     Colis/principal   postgres
28s         Normal   Cree     Colis/principal   api
28s         Normal   Cree     Colis/principal   worker
28s         Normal   Cree     Colis/principal   web
```

Sept objets créés, un événement par objet sur le `Colis`. La réclamation de volume `donnees-postgres-0` n'a pas été créée par l'opérateur : c'est le contrôleur des StatefulSets qui l'a fabriquée, d'après le gabarit. Le Secret `colis-db` n'a pas de propriétaire, c'est voulu, on y revient plus bas.

L'application fonctionne de bout en bout. Le web répond, l'API enregistre un colis, KEDA réveille le worker, qui calcule la date de livraison :

```bash
kubectl -n ch55 port-forward svc/web 18085:80 &
curl -s http://127.0.0.1:18085/api/colis -o /dev/null -w '%{http_code}\n'
curl -s http://127.0.0.1:18085/api/colis -X POST -H 'Content-Type: application/json' \
  -d '{"destinataire": "Opérateur", "poids_kg": 2.5, "depart": "Brest", "arrivee": "Lille"}'
```

```sortie
GET /api/colis : 200
colis 1 : estimé après 4,16 s
KEDAScalersStarted         Scaler redis is built
KEDAScalersStarted         Started scalers watch
KEDAScaleTargetActivated   Scaled apps/v1.Deployment ch55/worker from 0 to 1, triggered by s0-redis-colis-a-estimer
{"statut":"ok","version":"2.2.0","hote":"api-7f5cc99c58-86vzq"}
```

## Le piège des réécritures

La première version de l'opérateur écrivait le gabarit de Pod sans précaution : `d.Spec.Template.Spec = pod`, à chaque passage. Elle fonctionnait, et l'installation devenait `Disponible`. Son journal disait autre chose. Le même scénario, rejoué avec cette version, pendant une minute environ :

```sortie
réconciliations : 86 lignes « objet ... »
     79 objet updated
Cree : 7
MisAJour : 40
NOM      GENERATION
api      1
redis    1
web      1
worker   1
ReplicaSets : 4
```

79 mises à jour pour 7 créations, 40 événements `MisAJour` sur le `Colis`, et pourtant aucun Deployment n'a changé de génération : pas un seul nouveau ReplicaSet. Ces écritures ne modifiaient rien. L'API server complète chaque gabarit de Pod de valeurs par défaut (`imagePullPolicy`, `terminationMessagePath`, `dnsPolicy`, `schedulerName`, les délais des sondes...). Le gabarit relu contient ces valeurs, celui que l'opérateur construit ne les contient pas, et `CreateOrUpdate` conclut à chaque fois qu'il faut écrire. L'API server reçoit l'objet, le complète à nouveau, constate qu'il est identique à celui qu'il a, et n'incrémente rien. Chaque passage coûte une requête et un événement trompeur ; et chaque changement de statut d'un Deployment, pendant le démarrage des Pods, provoquait un passage.

La correction compare le gabarit voulu au gabarit existant avec `equality.Semantic.DeepDerivative`, qui ignore les champs que le gabarit voulu laisse vides[^equality] :

```go title="internal/controller/colis_controller.go (extrait)"
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
```

Avec elle, le journal du lancement ci-dessus ne compte que les sept créations. Un champ retiré du gabarit voulu est bien détecté : la comparaison exige des listes de même longueur. L'autre solution, plus récente, est l'application côté serveur (*server-side apply*, chapitre 18) : l'opérateur envoie seulement les champs qu'il possède, et l'API server fait la comparaison.

## La dérive

Un opérateur ne crée pas une fois pour toutes : il ramène sans cesse le réel vers le voulu. Trois modifications à la main, que l'opérateur annule :

```bash
kubectl -n ch55 delete deployment api
kubectl -n ch55 scale deployment api --replicas=5
kubectl -n ch55 patch configmap colis-config --type=merge -p '{"data":{"COLIS_VERSION":"9.9.9"}}'
```

```sortie
deployment.apps "api" deleted from ch55 namespace
Deployment api recréé après 0,224 s
deployment.apps/api scaled
replicas demandées : 2
configmap/colis-config patched
COLIS_VERSION : 2.2.0
```

Le Deployment supprimé revient en 0,224 s, le temps que l'événement de suppression arrive par le *watch* et que la réconciliation recrée l'objet. Le nombre de répliques revient à 2, la ConfigMap à sa valeur. Pour changer quelque chose de façon durable, il faut modifier le `Colis` : c'est la seule source de vérité.

### Ce que l'opérateur ne doit pas toucher

La règle a des exceptions, et les oublier fait les pires bogues d'opérateurs.

Le nombre de répliques du worker appartient à KEDA, qui le fait varier de 0 à 5 selon la file Redis (chapitre 31). Si l'opérateur réécrivait `replicas` à chaque passage, il annulerait chaque décision de l'autoscaler, et les deux contrôleurs se renverraient la valeur. La fonction `worker` ne fixe donc ce champ qu'à la création du Deployment :

```go title="internal/controller/colis_controller.go (extrait)"
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
	// ... puis le ScaledObject de KEDA, avec spec.worker.min et spec.worker.max
}
```

Le gabarit de volume du StatefulSet est immuable : la fonction `postgres` ne l'écrit que si l'objet n'existe pas encore (`CreationTimestamp.IsZero()`), comme les sélecteurs des Deployments et l'absence d'adresse du Service de la base.

Le Secret du mot de passe, enfin, est créé une fois et n'est jamais réécrit. Il n'a pas de propriétaire, pour survivre à la suppression du `Colis` avec le volume de la base : un mot de passe neuf face à des données initialisées avec l'ancien rendrait la base inutilisable. Le deuxième exercice montre ce qui arrive quand ce Secret disparaît malgré tout.

Les conflits restent possibles : entre la lecture d'un objet dans le cache et son écriture, KEDA ou un utilisateur peut l'avoir modifié. L'API server refuse alors l'écriture (`the object has been modified; please apply your changes to the latest version`), c'est sa concurrence optimiste, fondée sur `resourceVersion` (chapitres 34 et 35). L'opérateur traite ce cas à part : il recommence une seconde plus tard, sans événement d'erreur.

## Mettre à l'échelle, monter de version

La sous-ressource `scale` du type pointe vers `spec.api.replicas` ; `kubectl scale` sur le `Colis` passe donc par l'opérateur :

```bash
kubectl -n ch55 scale colis principal --replicas=3
```

```sortie
colis.cours.example.com/principal scaled
NAME        VERSION   API   PRÊTE   RAISON       AGE
principal   2.2.0     3     True    Disponible   47s
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
api    3/3     3            3           11s
{"spec":{"replicas":3},"status":{"replicas":3,"selector":"app.kubernetes.io/instance=principal,app.kubernetes.io/name=api"}}
```

Monter de version, c'est modifier un champ :

```bash
kubectl -n ch55 patch colis principal --type=merge -p '{"spec":{"version":"2.2.1"}}'
```

```sortie
colis.cours.example.com/principal patched
Waiting for deployment "api" rollout to finish: 1 out of 3 new replicas have been updated...
...
Waiting for deployment "api" rollout to finish: 1 old replicas are pending termination...
deployment "api" successfully rolled out
NOM      IMAGE
api      host.minikube.internal:5001/colis/api:2.2.1
worker   host.minikube.internal:5001/colis/api:2.2.1
{"statut":"ok","version":"2.2.1","hote":"api-865d45b765-c2h5n"}
The Colis "principal" is invalid: spec: Invalid value: pas de retour à une version antérieure
```

L'opérateur a changé l'image de l'API et du worker et la valeur de `COLIS_VERSION` ; le Deployment a fait sa mise à jour progressive (chapitre 19), Pod par Pod. Le retour en arrière est refusé par la règle CEL, avant d'atteindre l'opérateur.

## Un seul Colis par namespace

Les Services s'appellent `api`, `web`, `postgres` et `redis`, parce que l'image web cherche `api` par ce nom. Deux installations dans un même namespace se battraient pour les mêmes objets. L'opérateur règle la question par l'ancienneté : le plus ancien `Colis` du namespace est servi, les autres reçoivent une condition explicite.

```sortie
colis.cours.example.com/second created
NAME        VERSION   API   PRÊTE   RAISON       AGE
principal   2.2.1     3     True    Disponible   73s
second      2.2.1     2     False   AutreColis   3s
le namespace contient déjà le Colis principal
colis.cours.example.com "second" deleted from ch55 namespace
```

Une règle CEL ne pourrait pas faire ce contrôle : elle ne voit que l'objet qu'elle valide, jamais les autres objets du namespace. Un webhook d'admission (chapitre 45) le pourrait, au prix d'un service de plus à faire tourner.

## Quand l'opérateur s'arrête

Que se passe-t-il si l'opérateur s'arrête ? Les objets qu'il a créés continuent de tourner, servis par les contrôleurs de Kubernetes. Rien ne corrige plus les écarts :

```sortie
# opérateur arrêté
deployment.apps "web" deleted from ch55 namespace
Error from server (NotFound): deployments.apps "web" not found
# opérateur relancé
web recréé 0,421 s après le redémarrage de l'opérateur
```

Au redémarrage, le manager remplit ses caches, met en file une clé pour chaque `Colis` existant, et la première réconciliation constate le manque. Rien n'est rejoué événement par événement : l'état est simplement relu.

## Supprimer un Colis

<Figure svg={operateurObjets} num="55.2" alt="Le Colis principal à gauche. Il possède, par des références de propriétaire : la ConfigMap colis-config, les Services api, web, postgres et redis, les Deployments api, worker, web et redis, le StatefulSet postgres et le ScaledObject worker. Ces objets possèdent à leur tour : le ReplicaSet de l'API et ses Pods, le Pod postgres-0, le HPA keda-hpa-worker de KEDA. Sans propriétaire : le Secret colis-db, et la réclamation de volume donnees-postgres-0, créée par le contrôleur des StatefulSets d'après le gabarit et montée par le Pod. Supprimer le Colis supprime tout ce qui en dépend, de proche en proche ; le Secret et la réclamation de volume survivent.">
Les objets d'une installation et leurs propriétaires. Le ramasse-miettes suit les flèches ; ce qui n'en a pas survit à la suppression.
</Figure>

Supprimer le `Colis` suffit à tout retirer : le ramasse-miettes supprime les objets qu'il possède, puis ceux qu'ils possèdent, de proche en proche. Deux objets restent, par construction :

```bash
kubectl -n ch55 delete colis principal
kubectl -n ch55 get all,cm,secret,pvc,scaledobject
kubectl apply -f principal.yaml
```

```sortie
colis en base avant : 1
colis.cours.example.com "principal" deleted from ch55 namespace
NAME                         DATA   AGE
NAME              TYPE     DATA   AGE
secret/colis-db   Opaque   1      105s
NAME                                       STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
persistentvolumeclaim/donnees-postgres-0   Bound    pvc-a822716e-8c9d-4efd-9042-ea207e983f5d   1Gi        RWO            standard       <unset>                 105s
colis.cours.example.com/principal created
Disponible de nouveau après 6,94 s
colis en base après : 1
```

La réclamation de volume reste parce que la politique de rétention par défaut d'un StatefulSet est `Retain` ; le champ `persistentVolumeClaimRetentionPolicy`, stable depuis Kubernetes 1.32, permet de choisir `Delete`[^statefulset]. Le Secret reste parce que l'opérateur ne s'en est pas déclaré propriétaire. Recréé, le `Colis` retrouve la même base, le même mot de passe, et les données d'avant.

## Tester avec envtest

Tester un opérateur sur un vrai cluster est lent. kubebuilder fournit **envtest** : un vrai `kube-apiserver` et un vrai `etcd`, lancés comme de simples processus pour la durée des tests, sans kubelet ni contrôleurs[^envtest]. Le `Makefile` télécharge ces binaires dans `bin/k8s` (175 Mo ici). Les tests du projet, écrits avec Ginkgo et Gomega, appellent `Reconcile` directement et vérifient ce qu'elle a écrit :

```go title="internal/controller/colis_controller_test.go (extrait)"
	It("corrige une modification faite à la main", func() {
		reconcilier("principal")
		api := deploiement("api")
		api.Spec.Replicas = ptr.To(int32(5))
		Expect(k8sClient.Update(ctx, api)).To(Succeed())
		reconcilier("principal")
		Expect(*deploiement("api").Spec.Replicas).To(Equal(int32(2)))
	})

	It("laisse au worker le nombre de répliques choisi par KEDA", func() {
		reconcilier("principal")
		w := deploiement("worker")
		w.Spec.Replicas = ptr.To(int32(3))
		Expect(k8sClient.Update(ctx, w)).To(Succeed())
		reconcilier("principal")
		Expect(*deploiement("worker").Spec.Replicas).To(Equal(int32(3)))
	})
```

```bash
make test
```

```sortie
Le contrôleur Colis crée les objets d'une installation complète
• [2.127 seconds]
Le contrôleur Colis ne réécrit rien quand rien n'a changé
• [0.108 seconds]
Le contrôleur Colis corrige une modification faite à la main
• [0.117 seconds]
Le contrôleur Colis laisse au worker le nombre de répliques choisi par KEDA
• [0.112 seconds]
Le contrôleur Colis refuse un second Colis dans le même namespace
• [0.018 seconds]
--- PASS: TestControllers (7.00s)
PASS
ok  	example.com/colis-operateur/internal/controller	7.027s
```

Cinq comportements vérifiés en sept secondes, dont la règle qui laisse les répliques du worker à KEDA. Ce qu'envtest ne fait pas compte autant que ce qu'il fait. Aucun contrôleur ne tourne : un Deployment créé ne donne ni ReplicaSet ni Pod, donc l'installation n'est jamais `Disponible` ; le ramasse-miettes non plus, donc on vérifie la présence des références de propriétaire, pas la suppression en cascade. La ressource personnalisée de KEDA n'existe pas non plus : le dossier `test/crds` contient une copie de sa définition, chargée au démarrage de l'environnement.

## Livrer l'opérateur dans le cluster

En production, l'opérateur tourne dans le cluster, dans son propre namespace, avec son propre compte de service. Le `Dockerfile` généré compile le binaire dans une image Go, puis le copie seul dans une image distroless (chapitre 13) :

```bash
make docker-build IMG=localhost:5001/colis-operateur:0.1.0
docker push localhost:5001/colis-operateur:0.1.0
make deploy IMG=host.minikube.internal:5001/colis-operateur:0.1.0
```

```sortie
#15 DONE 0.1s
#16 naming to localhost:5001/colis-operateur:0.1.0 0.0s done
#16 DONE 0.3s
durée : 43,1 s
taille : 79.3MB
0.1.0: digest: sha256:7ed1ccdf3eb82c73605958fe7b0a58d8f834c4f47bff106ea94f235d4ab97647 size: 3234
```

La première construction a pris 8 min 39 s, à télécharger l'image `golang:1.26` et les modules ; les suivantes réutilisent le cache de BuildKit. `make deploy` applique la configuration Kustomize de `config/default` :

```sortie
namespace/colis-operateur-system created
customresourcedefinition.apiextensions.k8s.io/colis.cours.example.com unchanged
serviceaccount/colis-operateur-controller-manager created
role.rbac.authorization.k8s.io/colis-operateur-leader-election-role created
clusterrole.rbac.authorization.k8s.io/colis-operateur-colis-admin-role created
clusterrole.rbac.authorization.k8s.io/colis-operateur-colis-editor-role created
clusterrole.rbac.authorization.k8s.io/colis-operateur-colis-viewer-role created
clusterrole.rbac.authorization.k8s.io/colis-operateur-manager-role created
clusterrole.rbac.authorization.k8s.io/colis-operateur-metrics-auth-role created
clusterrole.rbac.authorization.k8s.io/colis-operateur-metrics-reader created
rolebinding.rbac.authorization.k8s.io/colis-operateur-leader-election-rolebinding created
clusterrolebinding.rbac.authorization.k8s.io/colis-operateur-manager-rolebinding created
clusterrolebinding.rbac.authorization.k8s.io/colis-operateur-metrics-auth-rolebinding created
service/colis-operateur-controller-manager-metrics-service created
deployment.apps/colis-operateur-controller-manager created
deployment "colis-operateur-controller-manager" successfully rolled out
NAME                                                 READY   STATUS    RESTARTS   AGE
colis-operateur-controller-manager-59974f5c9-fdxnc   1/1     Running   0          42s
NAME                                                 CPU(cores)   MEMORY(bytes)   
colis-operateur-controller-manager-59974f5c9-fdxnc   36m          60Mi            
BAIL                   DETENTEUR
64333509.example.com   colis-operateur-controller-manager-59974f5c9-fdxnc_ba9921f0-5c92-4b95-9163-90f06ad867dd
{"args":["--metrics-bind-address=:8443","--leader-elect","--health-probe-bind-address=:8081"],"image":"host.minikube.internal:5001/colis-operateur:0.1.0","resources":{"limits":{"cpu":"500m","memory":"128Mi"},"requests":{"cpu":"10m","memory":"64Mi"}}}
NAME        VERSION   API   PRÊTE   RAISON       AGE
principal   2.2.0     2     True    Disponible   111s
```

L'opérateur arrêté sur le poste, celui du cluster a pris le bail d'élection (chapitre 36) et a repris le `Colis` sans rien recréer. Grâce à l'option `--leader-elect`, présente dans le manifeste généré, plusieurs copies peuvent tourner, une seule active. Le Deployment généré fixe des ressources (64 Mi demandés, 128 Mi au plus) ; il en utilise ici 60 Mi.

## Les métriques de l'opérateur

controller-runtime publie des métriques Prometheus : nombre de réconciliations par résultat, durée, profondeur de la file de travail, erreurs. Le projet généré les sert en HTTPS, et seulement aux clients autorisés : l'opérateur vérifie le jeton de chaque requête auprès de l'API server (TokenReview), puis son droit de lire `/metrics` (SubjectAccessReview).

```bash
kubectl -n colis-operateur-system create serviceaccount lecteur-metriques
kubectl create clusterrolebinding colis-operateur-lecteur-metriques \
  --clusterrole=colis-operateur-metrics-reader --serviceaccount=colis-operateur-system:lecteur-metriques
JETON=$(kubectl -n colis-operateur-system create token lecteur-metriques --duration=10m)
kubectl -n colis-operateur-system port-forward svc/colis-operateur-controller-manager-metrics-service 18443:8443 &
curl -sk https://127.0.0.1:18443/metrics -o /dev/null -w '%{http_code}\n'
curl -sk -H "Authorization: Bearer $JETON" https://127.0.0.1:18443/metrics | grep 'controller="colis"'
```

```sortie
serviceaccount/lecteur-metriques created
clusterrolebinding.rbac.authorization.k8s.io/colis-operateur-lecteur-metriques created
sans jeton : 401
controller_runtime_active_workers{controller="colis"} 0
controller_runtime_reconcile_errors_total{controller="colis"} 0
controller_runtime_reconcile_total{controller="colis",result="error"} 0
controller_runtime_reconcile_total{controller="colis",result="requeue"} 0
controller_runtime_reconcile_total{controller="colis",result="requeue_after"} 0
controller_runtime_reconcile_total{controller="colis",result="success"} 1
workqueue_depth{controller="colis",name="colis",priority="-100"} 0
```

Une seule réconciliation depuis le démarrage dans le cluster : rien n'a changé depuis. Le dossier `config/prometheus` contient un ServiceMonitor (chapitre 50) qui fait relever ces métriques par Prometheus ; il n'est pas activé par défaut.

## Exercices

:::exercice[Exercice 1 : suspendre la réconciliation (programmation)]

Pendant une intervention à la main sur la base, on veut que l'opérateur cesse de tout réparer. Ajoutez au type un champ booléen `spec.suspendu`. Quand il vaut `true`, `Reconcile` ne crée ni ne modifie plus rien, et pose sur le `Colis` une condition `Prete` à `Unknown`, de raison `Suspendu`. Ajoutez un test envtest, puis vérifiez sur le cluster : suspendez, supprimez le Deployment `web`, constatez qu'il ne revient pas, levez la suspension.

:::

<details>
<summary>Corrigé</summary>

Le corrigé, `corrige/suspendu.patch`, n'est pas dans l'archive. Il ajoute le champ au type, un test, et ces lignes au début de `Reconcile`, juste après la vérification du namespace :

```go
	if colis.Spec.Suspendu {
		err := r.majStatut(ctx, &colis, metav1.ConditionUnknown, "Suspendu",
			"réconciliation suspendue (spec.suspendu)", colis.Status.APIPretes)
		if apierrors.IsConflict(err) {
			return ctrl.Result{RequeueAfter: time.Second}, nil
		}
		return ctrl.Result{}, err
	}
```

Le champ change le schéma : il faut régénérer la CRD (`make manifests`) et l'installer de nouveau avant de s'en servir, sinon l'API server élague `suspendu` ou `kubectl` refuse le champ inconnu.

```sortie
# tests
Le contrôleur Colis ne touche plus à rien quand le Colis est suspendu
Ran 6 of 6 Specs in 7.123 seconds
ok  	example.com/colis-operateur/internal/controller	7.151s
# sur le cluster : opérateur du cluster arrêté, version modifiée lancée sur le poste
colis.cours.example.com/principal patched
NAME        VERSION   API   PRÊTE     RAISON     AGE
principal   2.2.0     2     Unknown   Suspendu   5m13s
deployment.apps "web" deleted from ch55 namespace
Error from server (NotFound): deployments.apps "web" not found
colis.cours.example.com/principal patched
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
web    0/2     2            0           0s
NAME        VERSION   API   PRÊTE   RAISON       AGE
principal   2.2.0     2     True    Disponible   5m26s
colis.cours.example.com/principal patched
```

Le statut garde le nombre de répliques prêtes connu : suspendre ne veut pas dire oublier. Kubernetes a la même idée sous d'autres noms : `spec.paused` d'un Deployment, `spec.suspend` d'un CronJob ou d'un Job, l'annotation de pause de KEDA.

</details>

:::exercice[Exercice 2 : le Secret disparu]

Supprimez le Secret `colis-db`, puis redémarrez l'API (`kubectl rollout restart deployment api`). Que fait l'opérateur, et quand ? Que deviennent les nouveaux Pods de l'API ? Réparez sans perdre les données, puis proposez une modification de l'opérateur qui évite le piège.

:::

<details>
<summary>Corrigé</summary>

```sortie
ancien mot de passe : EXTfp2...
secret "colis-db" deleted from ch55 namespace
Error from server (NotFound): secrets "colis-db" not found
Error from server (NotFound): secrets "colis-db" not found
NAME                   READY   STATUS    RESTARTS        AGE
api-6cf44984df-j4vtl   1/1     Running   0               99s
api-6cf44984df-t7fvh   1/1     Running   3 (2m10s ago)   2m29s
$ kubectl -n ch55 rollout restart deployment api
deployment.apps/api restarted
NAME                   READY   STATUS             RESTARTS        AGE
api-6cf44984df-j4vtl   1/1     Running            0               2m25s
api-6cf44984df-t7fvh   1/1     Running            3 (2m56s ago)   3m15s
api-74f66f449c-5q7gh   0/1     CrashLoopBackOff   2 (15s ago)     46s
psycopg.OperationalError: connection failed: connection to server 
password authentication failed for user "colis"
NAME        VERSION   API   PRÊTE   RAISON    AGE
principal   2.2.0     2     False   EnCours   6m30s
# réparation : donner à PostgreSQL le nouveau mot de passe
ALTER ROLE
deployment "api" successfully rolled out
NAME        VERSION   API   PRÊTE   RAISON       AGE
principal   2.2.0     2     True    Disponible   6m51s
```

L'opérateur ne surveille pas les Secrets (`Owns` ne les cite pas) : la suppression ne déclenche rien, le Secret reste absent. Le redémarrage de l'API modifie un Deployment possédé, ce qui provoque une réconciliation, et `secretBase` crée un Secret avec un mot de passe neuf. Les Pods déjà lancés gardent l'ancien dans leur environnement et continuent de marcher. Les nouveaux reçoivent le nouveau ; or l'image de PostgreSQL ne lit `POSTGRES_PASSWORD` qu'à l'initialisation d'un répertoire de données vide[^postgres], et la base garde l'ancien. L'API ne peut pas se connecter et redémarre en boucle.

La réparation donne à PostgreSQL le nouveau mot de passe, par une connexion locale au Pod, que l'image officielle accepte sans mot de passe (authentification `trust` en local). Côté opérateur, le défaut est de traiter « Secret absent » comme « premier démarrage ». Une version plus prudente ne crée le mot de passe que si la réclamation de volume `donnees-postgres-0` n'existe pas encore ; sinon, elle pose une condition `Prete` à `False`, de raison `SecretPerdu`, et attend qu'un humain restaure le Secret, par exemple depuis une sauvegarde Velero (chapitre 52).

</details>

:::exercice[Exercice 3 : les droits de l'opérateur]

Avec `kubectl auth can-i --as=system:serviceaccount:colis-operateur-system:colis-operateur-controller-manager`, dressez la liste de ce que l'opérateur peut faire en dehors de `ch55`. Qu'est-ce qui vous inquiète ? Comment le restreindre, et à quel prix ?

:::

<details>
<summary>Corrigé</summary>

```sortie
list secrets -A : yes
get secrets -n kube-system : yes
delete deployments -n colis : yes
create pods -n ch55 : no
patch colis -n ch55 : no
{"role":"colis-operateur-manager-role","sujets":["colis-operateur-system/colis-operateur-controller-manager"]}
```

Le rôle généré est un ClusterRole lié par un ClusterRoleBinding : l'opérateur peut lire tous les Secrets du cluster, y compris ceux de `kube-system`, et supprimer les Deployments de n'importe quel namespace, dont `colis`. Un défaut de l'opérateur, ou la fuite de son jeton, aurait cette portée (chapitre 43). Il y a pire : le client de controller-runtime passe par le cache pour chaque type qu'il lit, et le premier `Get` sur un Secret a démarré un *watch* sur tous les Secrets du cluster, gardés en mémoire dans l'opérateur.

Deux réductions, à combiner. Limiter le cache aux namespaces servis, par l'option `Cache.DefaultNamespaces` du manager, puis remplacer le ClusterRole par des Roles dans ces namespaces : les marqueurs RBAC acceptent un paramètre `namespace=`. Et restreindre le cache des Secrets à ceux de l'opérateur, par un sélecteur d'étiquettes (`Cache.ByObject`), ou lire les Secrets sans cache (`mgr.GetAPIReader()`). Le prix : déclarer à l'avance où l'opérateur travaille, et redéployer pour chaque nouveau namespace.

</details>

:::exercice[Exercice 4 : une sauvegarde avant de supprimer]

On veut qu'à la suppression d'un `Colis`, l'opérateur lance un `pg_dump` de la base et ne laisse partir les objets qu'une fois la sauvegarde terminée. Pourquoi une référence de propriétaire ne suffit-elle pas ? Quel mécanisme de Kubernetes faut-il utiliser, et à quoi faut-il penser pour ne pas bloquer la suppression pour toujours ?

:::

<details>
<summary>Corrigé</summary>

Le ramasse-miettes supprime les objets possédés dès que le propriétaire a disparu : l'opérateur n'est pas consulté, et quand il reçoit la clé, le `Colis` n'existe déjà plus. Il faut un **finaliseur** (chapitre 49) : l'opérateur ajoute à chaque `Colis` une valeur dans `metadata.finalizers`, par exemple `cours.example.com/sauvegarde`. À la suppression, l'API server ne supprime pas l'objet : il pose `metadata.deletionTimestamp` et attend que la liste des finaliseurs soit vide. `Reconcile` voit le `deletionTimestamp`, lance un Job de sauvegarde, attend qu'il réussisse, puis retire son finaliseur ; l'objet disparaît alors, et le ramasse-miettes fait le reste. Le marqueur `colis/finalizers` du ClusterRole généré est là pour ça.

Le piège est le finaliseur qui ne part jamais : base injoignable, Job en échec permanent, opérateur désinstallé avant ses objets. Il faut une issue (une annotation qui permet de passer outre, un nombre d'essais au-delà duquel on abandonne en le signalant), et désinstaller les objets avant l'opérateur, comme pour Velero au chapitre 52.

</details>

## Nettoyer

La suite de la partie ne se sert pas de cet opérateur. `make undeploy` retire le namespace de l'opérateur, ses rôles et la CRD, ce qui supprime le `Colis` et, par le ramasse-miettes, ses objets. Le namespace `ch55` garde le Secret et le volume : on le supprime aussi.

```bash
make undeploy
kubectl delete namespace ch55
kubectl delete clusterrolebinding colis-operateur-lecteur-metriques
```

Go, kubebuilder et le dossier `bin/` du projet restent sur le poste ; `bin/k8s` (les binaires d'envtest) se supprime sans dommage, `make test` les retéléchargera. L'image `colis-operateur:0.1.0` reste dans le registre du cours.

[^coreos]: Brandon Philips, « Introducing Operators: Putting Operational Knowledge into Software », blog de CoreOS, 3 novembre 2016 (archive) : un opérateur est un contrôleur propre à une application, qui étend l'API de Kubernetes pour créer, configurer et gérer des instances d'applications complexes avec état. [web.archive.org/web/2016/https://coreos.com/blog/introducing-operators.html](https://web.archive.org/web/2016/https://coreos.com/blog/introducing-operators.html)
[^operateur]: Kubernetes, « Operator pattern » : capturer le savoir d'un opérateur humain, ressources personnalisées et boucle de contrôle. [kubernetes.io/docs/concepts/extend-kubernetes/operator](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/)
[^kubebuilder]: The Kubebuilder Book : projet, `init`, `create api`, manager, contrôleurs, marqueurs, déploiement. [book.kubebuilder.io](https://book.kubebuilder.io/) ; et la version 4.16.0 utilisée ici. [github.com/kubernetes-sigs/kubebuilder/releases/tag/v4.16.0](https://github.com/kubernetes-sigs/kubebuilder/releases/tag/v4.16.0)
[^marqueurs]: The Kubebuilder Book, « Markers for Config/Code Generation » : marqueurs de validation, de valeurs par défaut, de sous-ressources, de colonnes et de RBAC. [book.kubebuilder.io/reference/markers.html](https://book.kubebuilder.io/reference/markers.html)
[^conventions]: Kubernetes, « API Conventions », sections « Spec and Status » et « Typical status properties » : `observedGeneration`, conditions avec `type`, `status`, `reason`, `message`, `lastTransitionTime`. [github.com/kubernetes/community/.../api-conventions.md](https://github.com/kubernetes/community/blob/master/contributors/devel/sig-architecture/api-conventions.md)
[^controllerutil]: controller-runtime, paquet `controllerutil` : `CreateOrUpdate`, `SetControllerReference`. [pkg.go.dev/sigs.k8s.io/controller-runtime/pkg/controller/controllerutil](https://pkg.go.dev/sigs.k8s.io/controller-runtime/pkg/controller/controllerutil)
[^equality]: apimachinery, paquet `equality` : `Semantic.DeepDerivative` compare deux valeurs en ignorant les champs non renseignés de la première. [pkg.go.dev/k8s.io/apimachinery/pkg/api/equality](https://pkg.go.dev/k8s.io/apimachinery/pkg/api/equality)
[^statefulset]: Kubernetes, « StatefulSets », section « PersistentVolumeClaim retention » : champ `persistentVolumeClaimRetentionPolicy`, `whenDeleted` et `whenScaled`, `Retain` par défaut, stable depuis 1.32. [kubernetes.io/docs/concepts/workloads/controllers/statefulset](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/)
[^envtest]: The Kubebuilder Book, « Configuring envtest for integration tests » : API server et etcd sans contrôleurs ; pas de ramasse-miettes, tester les références de propriétaire. [book.kubebuilder.io/reference/envtest.html](https://book.kubebuilder.io/reference/envtest.html)
[^postgres]: Docker Official Images, documentation de l'image `postgres` : les variables propres à l'image ne s'appliquent qu'à un répertoire de données vide ; authentification `trust` pour les connexions locales, dans le conteneur. [github.com/docker-library/docs/blob/master/postgres/README.md](https://github.com/docker-library/docs/blob/master/postgres/README.md)
