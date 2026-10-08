#!/usr/bin/env bash
# Chapitre 52, première partie : instantané d'etcd et restauration sur le profil minikube principal.
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/sauvegarde
section() { echo; echo "### $*"; }
O=$RACINE/outils/out/ch52r; mkdir -p $O && cd $O
kubectl delete ns ch52 --ignore-not-found >/dev/null 2>&1; kubectl -n default delete cm apres --ignore-not-found >/dev/null 2>&1
while kubectl get ns ch52 >/dev/null 2>&1; do sleep 2; done
rm -rf sauvegardes

section "precieux"
kubectl create ns ch52
kubectl -n ch52 create configmap inventaire --from-literal=entrepots=Lyon,Brest,Lille
kubectl -n ch52 create secret generic acces --from-literal=jeton=jeton-tres-secret-52
kubectl -n ch52 create deployment tampon --image=busybox:1.37 -- sleep 3600
kubectl -n ch52 rollout status deployment/tampon --timeout=90s

section "sauvegarde"
time bash $KIT/sauvegarder-etcd.sh sauvegardes
ls -l sauvegardes | awk '{print $1, $5, $NF}'
SNAP=$(ls sauvegardes/*.db | head -1)

section "contenu"
echo "jeton en clair : $(grep -a -c 'jeton-tres-secret-52' $SNAP)"
echo "valeurs chiffrées (secretbox) : $(grep -a -o 'k8s:enc:secretbox:v1:[a-z0-9]*' $SNAP | sort | uniq -c | tr -s ' ')"
echo "configmap inventaire : $(grep -a -c 'Lyon,Brest,Lille' $SNAP)"

section "catastrophe"
kubectl -n default create configmap apres --from-literal=cree=apres-la-sauvegarde
kubectl delete ns ch52
kubectl get ns ch52 2>&1

section "restauration"
date +%T
time bash $KIT/restaurer-etcd.sh $SNAP
date +%T

section "verification"
kubectl get nodes
kubectl -n ch52 get cm,secret,deploy,pods
kubectl -n ch52 get secret acces -o jsonpath='{.data.jeton}' | base64 -d; echo
kubectl -n default get cm apres 2>&1
sleep 30
kubectl get pods -A --no-headers | awk '$4 != "Running" && $4 != "Completed"' | head
curl -sk --max-time 8 --resolve colis.local:443:192.168.49.102 https://colis.local/api/pret -w ' %{http_code}\n'
minikube ssh -- 'sudo ls -d /var/lib/minikube/etcd*' 2>/dev/null
echo; echo "### fin"
