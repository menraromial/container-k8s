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

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/events"
	"k8s.io/utils/ptr"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	coursv1 "example.com/colis-operateur/api/v1"
)

// envtest démarre un vrai API server et un vrai etcd, sans aucun contrôleur : pas de
// ReplicaSets, pas de Pods, pas de ramasse-miettes. On teste ce que Reconcile écrit.
var _ = Describe("Le contrôleur Colis", func() {
	ctx := context.Background()
	var ns string
	var r *ColisReconciler

	reconcilier := func(nom string) {
		_, err := r.Reconcile(ctx, reconcile.Request{NamespacedName: types.NamespacedName{Namespace: ns, Name: nom}})
		Expect(err).NotTo(HaveOccurred())
	}
	deploiement := func(nom string) *appsv1.Deployment {
		d := &appsv1.Deployment{}
		Expect(k8sClient.Get(ctx, client.ObjectKey{Namespace: ns, Name: nom}, d)).To(Succeed())
		return d
	}
	creerColis := func(nom string) {
		Expect(k8sClient.Create(ctx, &coursv1.Colis{
			ObjectMeta: metav1.ObjectMeta{Name: nom, Namespace: ns},
			Spec:       coursv1.ColisSpec{Version: "2.2.0"},
		})).To(Succeed())
	}

	BeforeEach(func() {
		n := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{GenerateName: "essai-"}}
		Expect(k8sClient.Create(ctx, n)).To(Succeed())
		ns = n.Name
		r = &ColisReconciler{Client: k8sClient, Scheme: k8sClient.Scheme(), Recorder: events.NewFakeRecorder(100)}
		creerColis("principal")
	})

	It("crée les objets d'une installation complète", func() {
		reconcilier("principal")

		api := deploiement("api")
		Expect(*api.Spec.Replicas).To(Equal(int32(2)))
		Expect(api.Spec.Template.Spec.Containers[0].Image).To(Equal("host.minikube.internal:5001/colis/api:2.2.0"))
		Expect(api.OwnerReferences).To(HaveLen(1))
		Expect(api.OwnerReferences[0].Kind).To(Equal("Colis"))
		Expect(*deploiement("worker").Spec.Replicas).To(Equal(int32(0)))

		s := &appsv1.StatefulSet{}
		Expect(k8sClient.Get(ctx, client.ObjectKey{Namespace: ns, Name: "postgres"}, s)).To(Succeed())
		Expect(s.Spec.VolumeClaimTemplates[0].Spec.Resources.Requests.Storage().String()).To(Equal("1Gi"))

		secret := &corev1.Secret{}
		Expect(k8sClient.Get(ctx, client.ObjectKey{Namespace: ns, Name: "colis-db"}, secret)).To(Succeed())
		Expect(secret.Data["POSTGRES_PASSWORD"]).To(HaveLen(24))
		Expect(secret.OwnerReferences).To(BeEmpty(), "le Secret doit survivre au Colis")

		so := &unstructured.Unstructured{}
		so.SetGroupVersionKind(scaledObjectGVK)
		Expect(k8sClient.Get(ctx, client.ObjectKey{Namespace: ns, Name: "worker"}, so)).To(Succeed())
		max, _, _ := unstructured.NestedInt64(so.Object, "spec", "maxReplicaCount")
		Expect(max).To(Equal(int64(5)))

		colis := &coursv1.Colis{}
		Expect(k8sClient.Get(ctx, client.ObjectKey{Namespace: ns, Name: "principal"}, colis)).To(Succeed())
		prete := meta.FindStatusCondition(colis.Status.Conditions, "Prete")
		Expect(prete).NotTo(BeNil())
		Expect(prete.Reason).To(Equal("EnCours")) // aucun Pod dans envtest
		Expect(colis.Status.ObservedGeneration).To(Equal(colis.Generation))
	})

	It("ne réécrit rien quand rien n'a changé", func() {
		reconcilier("principal")
		avant := deploiement("api").ResourceVersion
		reconcilier("principal")
		Expect(deploiement("api").ResourceVersion).To(Equal(avant))
	})

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

	It("refuse un second Colis dans le même namespace", func() {
		creerColis("second")
		reconcilier("second")
		colis := &coursv1.Colis{}
		Expect(k8sClient.Get(ctx, client.ObjectKey{Namespace: ns, Name: "second"}, colis)).To(Succeed())
		Expect(meta.FindStatusCondition(colis.Status.Conditions, "Prete").Reason).To(Equal("AutreColis"))
	})
})
