#!/usr/bin/env bash
# Exercices du chapitre 49 : quota, conteneur d'initialisation, palmarès, namespace bloqué. À lancer après rejeu-ch49.sh.
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/pannes
section() { echo; echo "### $*"; }
for ns in ch49-quota ch49-init ch49-fin; do
  kubectl -n $ns patch cm archive --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1
  kubectl delete ns $ns --ignore-not-found --wait=false >/dev/null 2>&1
done
for ns in ch49-quota ch49-init ch49-fin; do while kubectl get ns $ns >/dev/null 2>&1; do sleep 2; done; done

section "ex1 quota"
kubectl create ns ch49-quota
kubectl -n ch49-quota create quota memoire --hard=requests.memory=512Mi,limits.memory=1Gi
kubectl -n ch49-quota create deployment api --image=host.minikube.internal:5001/colis/api:2.1 --replicas=2
sleep 8
kubectl -n ch49-quota get deploy,rs,pods
kubectl -n ch49-quota events --types=Warning | cut -c1-260
kubectl -n ch49-quota get deploy api -o json | jq -c '.status.conditions[] | {type, status, reason}'
kubectl -n ch49-quota set resources deploy/api --requests=memory=192Mi --limits=memory=256Mi
kubectl -n ch49-quota rollout status deploy/api --timeout=90s
kubectl -n ch49-quota scale deploy/api --replicas=3
sleep 6
kubectl -n ch49-quota get deploy api
kubectl -n ch49-quota describe quota memoire | tail -4
kubectl -n ch49-quota events --types=Warning | tail -1 | cut -c1-260

section "ex2 init"
kubectl create ns ch49-init
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: migration-ratee
  namespace: ch49-init
spec:
  initContainers:
  - name: migration
    image: busybox:1.37
    command: ["sh", "-c", "echo application des migrations; echo 'table colis : colonne poids_kg déjà présente' >&2; exit 2"]
  containers:
  - name: api
    image: host.minikube.internal:5001/colis/api:2.1
---
apiVersion: v1
kind: Pod
metadata:
  name: attente-base
  namespace: ch49-init
spec:
  initContainers:
  - name: attendre-postgres
    image: busybox:1.37
    command: ["sh", "-c", "until nc -z -w 2 postgres 5432; do echo 'postgres pas encore joignable'; sleep 5; done"]
  containers:
  - name: api
    image: host.minikube.internal:5001/colis/api:2.1
YAML
sleep 45
kubectl -n ch49-init get pods
kubectl -n ch49-init logs migration-ratee -c migration
kubectl -n ch49-init get pod migration-ratee -o jsonpath='{.status.initContainerStatuses[0].lastState.terminated}' | jq -c '{reason, exitCode}'
kubectl -n ch49-init logs attente-base -c attendre-postgres --tail=2
kubectl -n ch49-init events --for pod/attente-base | tail -3 | cut -c1-200

section "ex3 palmares"
kubectl -n ch49 patch cm regles-tarifaires --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1
kubectl label node minikube disque- >/dev/null 2>&1
kubectl delete ns ch49 --ignore-not-found >/dev/null 2>&1
while kubectl get ns ch49 >/dev/null 2>&1; do sleep 2; done
kubectl apply -f $KIT/00-namespace.yaml >/dev/null
for f in $KIT/[01][0-9]-*.yaml; do [ "$(basename $f)" = 00-namespace.yaml ] || kubectl apply -f $f >/dev/null; done
sleep 100
python3 $KIT/corrige/palmares.py ch49 --top 12
kubectl -n ch49 patch cm regles-tarifaires --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null
kubectl delete ns ch49 --wait=false >/dev/null

section "ex4 namespace bloque"
kubectl create ns ch49-fin
kubectl -n ch49-fin create configmap archive --from-literal=a=1
kubectl -n ch49-fin patch cm archive --type=merge -p '{"metadata":{"finalizers":["cours.exemple/archivage"]}}'
kubectl delete ns ch49-fin --wait=false
sleep 8
kubectl get ns ch49-fin
kubectl get ns ch49-fin -o json | jq -c '.status.conditions[] | select(.status == "True") | {type, reason, message}'
kubectl api-resources --verbs=list --namespaced -o name | xargs -n1 kubectl -n ch49-fin get --ignore-not-found -o name 2>/dev/null
kubectl -n ch49-fin patch cm archive --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
sleep 8
kubectl get ns ch49-fin 2>&1
echo; echo "### fin"
