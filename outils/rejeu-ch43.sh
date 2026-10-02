#!/usr/bin/env bash
# Rejeu du chapitre 43 (RBAC) sur le profil minikube principal. Sorties dans outils/out/ch43r.
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/rbac
O=$RACINE/outils/out/ch43r
API=https://192.168.49.2:8443
CA=$HOME/.minikube/ca.crt
IMAGE_API=host.minikube.internal:5001/colis/api:2.1
section() { echo; echo "### $*"; }

# --- remise à zéro : uniquement les objets de ce chapitre
kubectl delete ns ch43 --wait >/dev/null 2>&1
kubectl -n colis delete role astreinte deployeur journaux --ignore-not-found >/dev/null
kubectl -n colis delete rolebinding astreinte deployeur journaux cours-view-carla --ignore-not-found >/dev/null
kubectl -n colis delete sa deployeur --ignore-not-found >/dev/null
for ns in colis-dev colis-helm; do kubectl -n $ns delete rolebinding lecture-colis --ignore-not-found >/dev/null; done
kubectl delete clusterrole cours-keda-lecture lecture-colis --ignore-not-found >/dev/null
kubectl delete csr alice --ignore-not-found >/dev/null
rm -rf "$O"; mkdir -p "$O"; cd "$O"
kubectl create ns ch43 >/dev/null
kubectl -n colis set image deployment/api api=$IMAGE_API >/dev/null
kubectl -n colis rollout status deployment/api --timeout=180s >/dev/null
# l'image de l'API est remise sur l'étiquette 2.1 en sortant (le rejeu la déploie par empreinte)
trap 'kubectl -n colis set image deployment/api api=$IMAGE_API >/dev/null 2>&1; kubectl -n colis rollout status deployment/api --timeout=180s >/dev/null 2>&1' EXIT

section "ouverture"
kubectl get clusterrolebindings -o json \
  | jq -r '.items[] | select(.roleRef.name == "cluster-admin") | .metadata.name as $b | .subjects[]? | "\($b)\t\(.kind)\t\(.namespace // "-")\t\(.name)"' \
  | column -t

section "qui peut lire les Secrets de colis"
python3 $KIT/qui-peut.py get secrets colis

section "astreinte"
kubectl apply -f $KIT/astreinte.yaml
NS=colis DUREE=86400 bash $RACINE/kits/authentification/nouvel-utilisateur.sh alice equipe-colis >/dev/null 2>&1
export KUBECONFIG=$O/alice.kubeconfig
kubectl auth whoami -o jsonpath='{.status.userInfo.groups}{"\n"}'
kubectl get pods
kubectl logs deployment/api --tail=2
kubectl rollout restart deployment/api
kubectl rollout restart statefulset/postgres
kubectl get secret colis-db
kubectl delete pod postgres-0
kubectl auth can-i --list
unset KUBECONFIG
kubectl -n colis rollout status deployment/api --timeout=180s >/dev/null

section "can-i en tant que"
while read -r v r; do printf "%-28s %s\n" "$v $r" "$(kubectl auth can-i $v $r -n colis --as=alice --as-group=equipe-colis)"; done <<'L'
list pods
get secrets
patch deployments/api
patch deployments/redis
delete pods
L
kubectl auth can-i patch deployments/api -n colis --as=alice

section "rôles par défaut"
bash $KIT/roles-par-defaut.sh ch43

section "agrégation"
kubectl -n colis create rolebinding cours-view-carla --clusterrole=view --user=carla
kubectl auth can-i list scaledobjects.keda.sh -n colis --as=carla
kubectl get clusterrole view -o json | jq '.rules | length'
kubectl apply -f $KIT/keda-lecture.yaml
sleep 1
kubectl get clusterrole view -o json | jq '.rules | length'
kubectl get clusterrole view -o json | jq -c '.rules[] | select(.apiGroups == ["keda.sh"])'
kubectl auth can-i list scaledobjects.keda.sh -n colis --as=carla
kubectl get scaledobjects -n colis --as=carla

section "deployeur"
kubectl apply -f $KIT/deployeur.yaml
T=$(kubectl -n colis create token deployeur --duration=10m)
ci() { kubectl --kubeconfig=/dev/null --server=$API --certificate-authority=$CA --token="$T" -n colis "$@"; }
EMPREINTE=$(curl -s -I -H 'Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json' \
  http://localhost:5001/v2/colis/api/manifests/2.1 | grep -i docker-content-digest | awk '{print $2}' | tr -d '\r')
echo "empreinte : $EMPREINTE"
ci set image deployment/api api=host.minikube.internal:5001/colis/api@$EMPREINTE
ci rollout status deployment/api --timeout=180s
ci get deployment api -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
ci set image deployment/redis redis=redis:8.8
ci get pods
ci get secrets

section "garde-fou"
kubectl apply -f $KIT/chef-projet.yaml
export KUBECONFIG=$O/alice.kubeconfig
kubectl -n ch43 create role lecteur --verb=get,list --resource=pods,configmaps
kubectl -n ch43 create rolebinding lecteur-bruno --role=lecteur --user=bruno
kubectl -n ch43 create role lecteur-secrets --verb=get --resource=secrets
kubectl -n ch43 create rolebinding admin-bruno --clusterrole=admin --user=bruno > admin-bruno.txt 2>&1
head -3 admin-bruno.txt; echo "[...]"; echo "$(grep -c '^{APIGroups' admin-bruno.txt) règles manquantes au total"
unset KUBECONFIG

section "Node"
kubectl -n ch43 create secret generic orphelin --from-literal=cle=valeur >/dev/null
N="--as=system:node:minikube --as-group=system:nodes"
printf "%-36s %s\n" "get secret colis-db (colis)" "$(kubectl auth can-i get secret/colis-db -n colis $N)"
printf "%-36s %s\n" "get secret orphelin (ch43)" "$(kubectl auth can-i get secret/orphelin -n ch43 $N)"
printf "%-36s %s\n" "list secrets (colis)" "$(kubectl auth can-i list secrets -n colis $N)"
printf "%-36s %s\n" "get secret colis-db, nœud m02" "$(kubectl auth can-i get secret/colis-db -n colis --as=system:node:m02 --as-group=system:nodes)"

section "SubjectAccessReview"
revue() {
  jq -n --arg u "$1" --argjson g "$2" --argjson ra "$3" \
    '{apiVersion: "authorization.k8s.io/v1", kind: "SubjectAccessReview", spec: {user: $u, groups: $g, resourceAttributes: $ra}}' > sar.json
  kubectl create -f sar.json -o json | jq -c .status
}
revue alice '["equipe-colis"]' '{"verb":"patch","group":"apps","resource":"deployments","name":"api","namespace":"colis"}'
revue alice '["equipe-colis"]' '{"verb":"get","resource":"secrets","name":"colis-db","namespace":"colis"}'
revue system:serviceaccount:kube-system:default '["system:serviceaccounts"]' '{"verb":"delete","resource":"namespaces","name":"colis"}'

section "ex1 journaux"
kubectl -n colis create role journaux --verb=get --resource=pods/log
kubectl -n colis create rolebinding journaux --role=journaux --group=support
P=$(kubectl -n colis get pods --field-selector=status.phase=Running -o name | grep -m1 '^pod/api-' | cut -d/ -f2)
kubectl -n colis logs $P --tail=1 --as=sam --as-group=support
kubectl -n colis delete role journaux >/dev/null
kubectl -n colis create role journaux --verb=get --resource=pods,pods/log
kubectl -n colis logs $P --tail=1 --as=sam --as-group=support
kubectl -n colis logs deployment/api --tail=1 --as=sam --as-group=support

section "ex2 un rôle, deux namespaces"
kubectl apply -f $KIT/corrige/lecture-colis.yaml
for ns in colis-dev colis-helm; do kubectl -n $ns create rolebinding lecture-colis --clusterrole=lecture-colis --group=equipe-colis; done
for ns in colis-dev colis-helm colis-defi colis; do printf "%-11s list pods : %-4s get secrets : %s\n" $ns "$(kubectl auth can-i list pods -n $ns --as=bruno --as-group=equipe-colis)" "$(kubectl auth can-i get secrets -n $ns --as=bruno --as-group=equipe-colis)"; done

section "ex3 audit"
python3 $KIT/corrige/auditer-rbac.py

section "ex4 liste par nom"
kubectl -n ch43 create configmap reglages --from-literal=a=1 >/dev/null
kubectl -n ch43 create configmap autre --from-literal=b=2 >/dev/null
kubectl -n ch43 create role un-seul --verb=get,list --resource=configmaps --resource-name=reglages
kubectl -n ch43 create rolebinding un-seul --role=un-seul --user=sam
kubectl -n ch43 get configmap reglages --as=sam
kubectl -n ch43 get configmaps --as=sam
kubectl -n ch43 get configmaps --field-selector=metadata.name=reglages --as=sam
kubectl -n ch43 get configmap autre --as=sam

echo; echo "### fin"
