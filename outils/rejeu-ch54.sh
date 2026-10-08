#!/usr/bin/env bash
# Chapitre 54 : les CustomResourceDefinitions. Repart de zéro (supprime la CRD colis.cours.example.com,
# le namespace ch54 et les ClusterRoles colis-*), puis rejoue tout le chapitre. Sorties : outils/out/ch54r.
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/crd
O=$RACINE/outils/out/ch54r; rm -rf $O; mkdir -p $O && cd $O
section() { echo; echo "### $*"; }
C=/var/lib/minikube/certs/etcd
E() { kubectl -n kube-system exec etcd-minikube -- etcdctl --cacert=$C/ca.crt --cert=$C/server.crt --key=$C/server.key "$@"; }
vue() { kubectl -n ch54 get colis "$1" -o jsonpath='{.spec}{"\n"}'; }

# --- remise à zéro
kubectl delete storageversionmigration colis-vers-v1 --ignore-not-found >/dev/null
kubectl delete crd colis.cours.example.com --ignore-not-found --wait=true >/dev/null
kubectl delete clusterrole colis-lecture colis-ecriture --ignore-not-found >/dev/null
kubectl delete ns ch54 --ignore-not-found --wait=true >/dev/null
# le cache de découverte de kubectl, pour ce groupe seulement : un étudiant qui découvre le chapitre n'en a pas
oublier() { rm -rf ~/.kube/cache/discovery/*/cours.example.com; }
oublier

section "avant"
kubectl get colis 2>&1
echo "types servis : $(kubectl api-resources --no-headers | wc -l), définitions : $(kubectl get crd --no-headers | wc -l)"

section "minimal"
kubectl apply -f $KIT/01-colis-minimal.yaml
kubectl wait --for=condition=Established crd/colis.cours.example.com
kubectl get crd colis.cours.example.com -o json | jq -c '.status.conditions[] | {type, status, reason}'
kubectl api-resources --api-group=cours.example.com
kubectl get --raw /apis/cours.example.com/v1alpha1 | jq -c '.resources[] | {name, namespaced, kind, verbs}'

section "premier objet"
kubectl create namespace ch54
kubectl apply -f $KIT/principal.yaml
kubectl -n ch54 get colis
E get /registry/cours.example.com/colis/ch54/principal --print-value-only | jq -c '{apiVersion, kind, spec}'
P=$(E get /registry/pods/colis --prefix --keys-only --limit 1 | head -1)
echo "$P"
E get $P --print-value-only | head -c 32 | od -An -c | head -2

section "sans schema"
kubectl apply -f $KIT/mauvais.yaml
vue mauvais

section "schema"
kubectl apply -f $KIT/02-colis-schema.yaml
sleep 3
echo "--- mauvais, relu"; vue mauvais
echo "--- principal, relu"; vue principal
echo "--- mauvais, réappliqué"; kubectl apply -f $KIT/mauvais.yaml 2>&1 | sed -E 's/patch: Invalid value: ".*": strict decoding error/patch: Invalid value: "...": strict decoding error/'
echo "--- mauvais, réappliqué sans validation côté client"; kubectl apply -f $KIT/mauvais.yaml --validate=false; vue mauvais
echo "--- la même chose, sous un autre nom"; sed 's/name: mauvais/name: mauvais-2/' $KIT/mauvais.yaml | kubectl apply --validate=false -f - 2>&1
echo "--- invalide"; kubectl apply -f $KIT/invalide.yaml 2>&1
echo "--- sans spec"; printf 'apiVersion: cours.example.com/v1alpha1\nkind: Colis\nmetadata: {name: vide, namespace: ch54}\n' | kubectl apply -f - 2>&1
echo "--- le minimum"; printf 'apiVersion: cours.example.com/v1alpha1\nkind: Colis\nmetadata: {name: mini, namespace: ch54}\nspec: {version: 2.2.1}\n' | kubectl apply -f -; vue mini

section "cel pannes"
sed 's/default: {min: 0, max: 5}.*/default: {}/' $KIT/03-colis-cel.yaml > defaut-vide.yaml
kubectl apply -f defaut-vide.yaml 2>&1
sed "s/messageExpression: .*/messageExpression: \"'min (' + string(self.min) + ') dépasse max (' + string(self.max) + ')'\"/" $KIT/03-colis-cel.yaml > concatenation.yaml
grep messageExpression concatenation.yaml
kubectl apply -f concatenation.yaml 2>&1

section "cel"
kubectl apply -f $KIT/03-colis-cel.yaml
sleep 3
kubectl -n ch54 delete colis mauvais mini >/dev/null
for p in '{"spec":{"worker":{"min":8}}}' '{"spec":{"base":{"taille":"512Mi"}}}' '{"spec":{"base":{"taille":"2Gi"}}}' \
         '{"spec":{"version":"2.10.0"}}' '{"spec":{"version":"2.9.9"}}'; do
  echo "\$ kubectl -n ch54 patch colis principal --type=merge -p '$p'"
  kubectl -n ch54 patch colis principal --type=merge -p "$p" 2>&1
done
vue principal
echo "--- le fichier d'origine, réappliqué"; kubectl apply -f $KIT/principal.yaml 2>&1

section "complet"
kubectl apply -f $KIT/04-colis-complet.yaml
sleep 3
kubectl -n ch54 get cl
kubectl get cours -A
kubectl explain colis.spec.base 2>&1

section "status"
g() { kubectl -n ch54 get colis principal -o jsonpath='generation={.metadata.generation} status={.status}{"\n"}'; }
g
echo "\$ kubectl -n ch54 patch colis principal --type=merge -p '{\"status\":{\"observedGeneration\":3}}'"
kubectl -n ch54 patch colis principal --type=merge -p '{"status":{"observedGeneration":3}}'; g
echo "\$ kubectl -n ch54 patch colis principal --subresource=status --type=merge -p ..."
kubectl -n ch54 patch colis principal --subresource=status --type=merge -p '{"status":{"observedGeneration":3,"selecteur":"app.kubernetes.io/instance=principal","api":{"replicas":2},"conditions":[{"type":"Prete","status":"True","reason":"Disponible","lastTransitionTime":"2026-10-08T20:00:00Z"}]}}'; g
echo "\$ kubectl -n ch54 patch colis principal --subresource=status --type=merge -p '{\"spec\":{\"api\":{\"replicas\":7}}}'"
kubectl -n ch54 patch colis principal --subresource=status --type=merge -p '{"spec":{"api":{"replicas":7}}}'
kubectl -n ch54 get colis principal -o jsonpath='spec.api.replicas={.spec.api.replicas}{"\n"}'
echo "\$ kubectl -n ch54 label colis principal equipe=exploitation"
kubectl -n ch54 label colis principal equipe=exploitation; g

section "scale"
kubectl -n ch54 scale colis principal --replicas=4
kubectl -n ch54 get colis principal -o jsonpath='generation={.metadata.generation} observedGeneration={.status.observedGeneration}{"\n"}'
kubectl -n ch54 get cl
kubectl get --raw /apis/cours.example.com/v1alpha1/namespaces/ch54/colis/principal/scale | jq -c '{kind, apiVersion, spec, status}'
kubectl -n ch54 get colis --field-selector spec.version=2.10.0
kubectl -n ch54 get colis --field-selector spec.api.replicas=4 2>&1

section "versions"
kubectl apply -f $KIT/05-colis-v1.yaml
sleep 3
kubectl get crd colis.cours.example.com -o jsonpath='{.status.storedVersions}{"\n"}'
kubectl get --raw /apis/cours.example.com | jq -c '{versions: [.versions[].version], prefere: .preferredVersion.version}'
echo "--- lu en v1alpha1"; kubectl -n ch54 get colis.v1alpha1.cours.example.com principal -o jsonpath='{.apiVersion} {.spec}{"\n"}' 2>&1
echo "--- lu en v1"; kubectl -n ch54 get colis.v1.cours.example.com principal -o jsonpath='{.apiVersion} {.spec}{"\n"}' 2>&1
echo "--- dans etcd"; E get /registry/cours.example.com/colis/ch54/principal --print-value-only | jq -c '{apiVersion}'
echo "\$ kubectl -n ch54 annotate colis principal note=essai"
kubectl -n ch54 annotate colis principal note=essai
E get /registry/cours.example.com/colis/ch54/principal --print-value-only | jq -c '{apiVersion}'
echo "--- un objet créé en v1alpha1"
printf 'apiVersion: cours.example.com/v1alpha1\nkind: Colis\nmetadata: {name: ancien, namespace: ch54}\nspec: {version: 2.2.1}\n' | kubectl apply -f - 2>&1
E get /registry/cours.example.com/colis/ch54/ancien --print-value-only | jq -c '{apiVersion, spec}'
kubectl -n ch54 get colis.v1.cours.example.com ancien -o jsonpath='{.apiVersion} {.spec}{"\n"}'

section "retrait trop tot"
kubectl apply -f $KIT/06-colis-v1-seul.yaml 2>&1

section "migration"
cat > migration.yaml <<'Y'
apiVersion: storagemigration.k8s.io/v1
kind: StorageVersionMigration
metadata:
  name: colis-vers-v1
spec:
  resource:
    group: cours.example.com
    resource: colis
Y
kubectl apply -f migration.yaml
for i in $(seq 1 60); do [ "$(kubectl get storageversionmigration colis-vers-v1 -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}')" = True ] && break; sleep 2; done
kubectl get storageversionmigration colis-vers-v1 -o json | jq -c '.status.conditions[] | {type, status, reason}'
for k in $(E get /registry/cours.example.com/colis --prefix --keys-only); do echo "$k $(E get $k --print-value-only | jq -r .apiVersion)"; done
kubectl get crd colis.cours.example.com -o jsonpath='{.status.storedVersions}{"\n"}'
kubectl apply -f $KIT/06-colis-v1-seul.yaml
sleep 3
kubectl api-resources --api-group=cours.example.com
kubectl -n ch54 get colis.v1alpha1.cours.example.com principal 2>&1

section "rbac"
kubectl -n ch54 create serviceaccount lecteur
kubectl -n ch54 create rolebinding lecteur-view --clusterrole=view --serviceaccount=ch54:lecteur
for v in list create; do echo "$v colis : $(kubectl auth can-i $v colis.cours.example.com -n ch54 --as=system:serviceaccount:ch54:lecteur)"; done
kubectl apply -f $KIT/07-roles.yaml
sleep 3
for v in list create; do echo "$v colis : $(kubectl auth can-i $v colis.cours.example.com -n ch54 --as=system:serviceaccount:ch54:lecteur)"; done
kubectl get clusterrole view -o json | jq -c '[.rules[] | select(.apiGroups | index("cours.example.com"))]'

section "cout"
mesure() { echo "$(kubectl get crd --no-headers | wc -l) définitions, $(kubectl api-resources --no-headers | wc -l) types, document de découverte $(kubectl get --raw /apis | wc -c) octets, OpenAPI v3 $(kubectl get --raw /openapi/v3 | jq '.paths | length') groupes-versions"; }
for i in $(seq -w 1 50); do cat <<Y
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata: {name: essais$i.cout.example.com}
spec:
  group: cout.example.com
  scope: Namespaced
  names: {kind: Essai$i, plural: essais$i, singular: essai$i}
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            properties:
              taille: {type: integer}
              nom: {type: string}
Y
done > cinquante.yaml
echo "avant : $(mesure)"
debut=$(date +%s.%N)
kubectl apply -f cinquante.yaml >/dev/null
for c in $(seq -w 1 50); do kubectl wait --for=condition=Established crd/essais$c.cout.example.com --timeout=60s >/dev/null; done
echo "50 définitions établies en $(echo "$(date +%s.%N) - $debut" | bc | cut -c1-4) s"
echo "après : $(mesure)"
time kubectl api-resources --cache-dir=$O/cache-vide >/dev/null
kubectl delete -f cinquante.yaml >/dev/null

section "suppression"
echo "objets Colis : $(kubectl get colis -A --no-headers | wc -l)"
kubectl get crd colis.cours.example.com -o jsonpath='{.metadata.finalizers}{"\n"}'
kubectl delete crd colis.cours.example.com
kubectl get colis -A 2>&1
E get /registry/cours.example.com --prefix --keys-only | wc -l

section "ensemble"
oublier
{ cat $KIT/06-colis-v1-seul.yaml; echo "---"; sed 's#cours.example.com/v1alpha1#cours.example.com/v1#' $KIT/principal.yaml; } > ensemble.yaml
kubectl apply -f ensemble.yaml 2>&1
sleep 2
kubectl apply -f ensemble.yaml 2>&1
kubectl -n ch54 get cl
echo; echo "### fin"
