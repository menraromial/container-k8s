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

package v1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

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

// Colis est une installation complète de l'application Colis, une par namespace.
type Colis struct {
	metav1.TypeMeta `json:",inline"`

	// +optional
	metav1.ObjectMeta `json:"metadata,omitzero"`

	// +required
	Spec ColisSpec `json:"spec"`

	// +optional
	Status ColisStatus `json:"status,omitzero"`
}

// +kubebuilder:object:root=true

// ColisList contient une liste de Colis.
type ColisList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitzero"`
	Items           []Colis `json:"items"`
}

func init() {
	SchemeBuilder.Register(func(s *runtime.Scheme) error {
		s.AddKnownTypes(SchemeGroupVersion, &Colis{}, &ColisList{})
		return nil
	})
}
