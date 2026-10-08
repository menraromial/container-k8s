#!/usr/bin/env bash
# Rejeu du chapitre 53 (mettre à jour un cluster) sur le profil minikube « montee », créé en v1.35.8.
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/montee
section() { echo; echo "### $*"; }
O=$RACINE/outils/out/ch53r; mkdir -p $O && cd $O
P=montee
kubectl config use-context $P >/dev/null
versions() {
  kubectl version 2>&1 | grep -v '^Kustomize'
  kubectl get nodes -o custom-columns=NOEUD:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion
  kubectl -n kube-system get pods -o custom-columns=POD:.metadata.name,IMAGE:.spec.containers[0].image --no-headers | grep -E 'kube-(apiserver|controller|scheduler|proxy)|etcd|coredns' | awk '{print $2}'
}
deprecies() {   # demande chaque groupe/version, puis lit les dépréciations que l'API server a comptées
  for gv in $(kubectl api-versions); do
    case $gv in */*) kubectl get --raw /apis/$gv >/dev/null 2>&1 ;; *) kubectl get --raw /api/$gv >/dev/null 2>&1 ;; esac
    for r in $(kubectl get --raw $( [[ $gv == */* ]] && echo /apis/$gv || echo /api/$gv ) | jq -r '.resources[] | select(.verbs | index("list")) | select(.name | contains("/") | not) | .name'); do
      kubectl get --raw "$( [[ $gv == */* ]] && echo /apis/$gv || echo /api/$gv )/$r?limit=1" >/dev/null 2>&1
    done
  done
  kubectl get --raw /metrics | grep '^apiserver_requested_deprecated_apis' | sed 's/^apiserver_requested_deprecated_apis//'
}
monter() {   # $1 version cible
  IP=$(minikube -p $P ip)
  python3 $KIT/sonde.py http://$IP:30080/ sonde-$1.log & S=$!
  sleep 3
  date +%T
  ( time minikube start -p $P --kubernetes-version=$1 ) 2>&1 | grep -v -E '^\s*$|^W[0-9]{4}|^(user|sys)\s' | tail -12
  date +%T
  sleep 20
  kill $S; wait $S 2>/dev/null
  python3 $KIT/sonde.py --resume sonde-$1.log
}

section "versions 1.35"
versions
kubectl api-versions > api-1.35.txt; wc -l < api-1.35.txt

section "deprecies 1.35"
deprecies

section "temoin"
kubectl apply -f $KIT/vitrine.yaml
kubectl rollout status deploy/vitrine --timeout=180s
kubectl get pods -o wide

section "sauvegarde"
PROFIL=$P bash $RACINE/kits/sauvegarde/sauvegarder-etcd.sh sauvegardes 2>&1 | grep -v -E '^W[0-9]{4}|^\{"level"' | tail -8

section "montee 1.36"
monter v1.36.4

section "apres 1.36"
versions
kubectl -n kube-system rollout status ds/kube-proxy --timeout=300s
kubectl -n kube-system rollout status deploy/coredns --timeout=300s
kubectl -n kube-system get pods -l k8s-app=kube-proxy -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}' 
kubectl get pods -o custom-columns=POD:.metadata.name,REDEMARRAGES:.status.containerStatuses[0].restartCount,DEPUIS:.status.startTime
kubectl api-versions > api-1.36.txt
diff api-1.35.txt api-1.36.txt

section "montee 1.37"
monter v1.37.0

section "apres 1.37"
versions
kubectl -n kube-system rollout status ds/kube-proxy --timeout=300s
kubectl -n kube-system rollout status deploy/coredns --timeout=300s
kubectl -n kube-system get pods -l k8s-app=kube-proxy -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}' 
kubectl get pods -o custom-columns=POD:.metadata.name,REDEMARRAGES:.status.containerStatuses[0].restartCount,DEPUIS:.status.startTime
kubectl api-versions > api-1.37.txt
diff api-1.36.txt api-1.37.txt
echo "--- 1.35 -> 1.37"; diff api-1.35.txt api-1.37.txt

section "deprecies 1.37"
deprecies
kubectl get endpoints -n default 2>&1 | head -2

section "migration"
cat > migration.yaml <<'YAML'
apiVersion: storagemigration.k8s.io/v1
kind: StorageVersionMigration
metadata:
  name: secrets-apres-1-37
spec:
  resource:
    group: ""
    resource: secrets
YAML
kubectl apply -f migration.yaml
for i in $(seq 1 30); do
  kubectl get storageversionmigration secrets-apres-1-37 -o jsonpath='{.status.conditions[?(@.status=="True")].type}' | grep -q Succeeded && break; sleep 2
done
kubectl get storageversionmigration secrets-apres-1-37 -o json | jq -c '{conditions: [.status.conditions[] | {type, status, reason}], resourceVersion: .status.resourceVersion}'

section "retour arriere"
minikube start -p $P --kubernetes-version=v1.36.4 2>&1 | grep -v -E '^\s*$|^W[0-9]{4}' | tail -14; echo "code de sortie : ${PIPESTATUS[0]}"
kubectl version 2>&1 | grep Server
echo; echo "### fin"
