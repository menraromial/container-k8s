#!/usr/bin/env bash
# Chapitre 58, exercices. Suppose rejeu-ch58.sh passé (Rollouts vitrine et bv dans ch58).
# Sorties : outils/out/ch58r/exercices.
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/rollouts
O=$RACINE/outils/out/ch58r/exercices; rm -rf $O; mkdir -p $O && cd $O
section() { echo; echo "### $*"; }
poids() { kubectl -n ch58 get httproute vitrine -o json | jq -c '[.spec.rules[0].backendRefs[] | "\(.name)=\(.weight)"]'; }
etape() { kubectl -n ch58 get rollout ${1:-vitrine} -o jsonpath='{.status.phase} étape {.status.currentStepIndex}{"\n"}'; }
attendre_etape() { for i in $(seq 1 120); do [ "$(kubectl -n ch58 get rollout vitrine -o jsonpath='{.status.currentStepIndex}')" = "$1" ] && break; sleep 1; done; }

section "ex3 repartition"
kubectl argo rollouts set image vitrine podinfo=ghcr.io/stefanprodan/podinfo:6.15.0 -n ch58
attendre_etape 1
sleep 3
echo "\$ python3 repartition.py -n 300      # étape 20 %"
python3 $KIT/corrige/repartition.py -n 300; echo "code : $?"
attendre_etape 3
sleep 3
echo "\$ python3 repartition.py -n 300      # étape 50 %"
python3 $KIT/corrige/repartition.py -n 300; echo "code : $?"

section "ex1 abandon"
echo "\$ kubectl argo rollouts abort vitrine -n ch58"
kubectl argo rollouts abort vitrine -n ch58
sleep 5
etape
poids
kubectl -n ch58 get rs -o custom-columns=RS:.metadata.name,VOULUS:.spec.replicas,IMAGE:.spec.template.spec.containers[0].image | grep -v " 0 "
echo "\$ kubectl argo rollouts retry rollout vitrine -n ch58"
kubectl argo rollouts retry rollout vitrine -n ch58
sleep 5
etape
poids
kubectl argo rollouts status vitrine -n ch58 --timeout 300s | tail -1
poids
kubectl -n ch58 get analysisrun --sort-by=.metadata.creationTimestamp -o custom-columns=ANALYSE:.metadata.name,PHASE:.status.phase | tail -2

section "ex2 sans routage"
cat > sans-routage.yaml <<'Y'
apiVersion: v1
kind: Service
metadata: {name: simple, namespace: ch58}
spec:
  selector: {app: simple}
  ports: [{name: http, port: 80, targetPort: http}]
---
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata: {name: simple, namespace: ch58}
spec:
  replicas: 4
  selector: {matchLabels: {app: simple}}
  template:
    metadata: {labels: {app: simple}}
    spec:
      containers:
      - name: podinfo
        image: ghcr.io/stefanprodan/podinfo:6.14.1
        ports: [{name: http, containerPort: 9898}]
        readinessProbe: {httpGet: {path: /readyz, port: http}, periodSeconds: 2}
        resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {memory: 64Mi}}
  strategy:
    canary:
      steps:
      - setWeight: 10
      - pause: {}
Y
kubectl apply -f sans-routage.yaml
kubectl argo rollouts status simple -n ch58 --timeout 120s | tail -1
kubectl argo rollouts set image simple podinfo=ghcr.io/stefanprodan/podinfo:6.15.0 -n ch58
for i in $(seq 1 60); do [ "$(kubectl -n ch58 get rollout simple -o jsonpath='{.status.phase}')" = Paused ] && break; sleep 1; done
sleep 5
kubectl argo rollouts get rollout simple -n ch58 --no-color | sed -n '/^  SetWeight/,/^  ActualWeight/p'
kubectl -n ch58 get rs -l app=simple -o custom-columns=RS:.metadata.name,VOULUS:.spec.replicas,PRETS:.status.readyReplicas,IMAGE:.spec.template.spec.containers[0].image
kubectl -n ch58 run client-simple --image=ghcr.io/stefanprodan/podinfo:6.15.0 --restart=Never --command -- \
  sh -c 'for i in $(seq 1 400); do wget -qO- -T 1 simple/version | grep -o "6\.[0-9]*\.[0-9]*"; done | sort | uniq -c' >/dev/null
kubectl -n ch58 wait --for=jsonpath='{.status.phase}'=Succeeded pod/client-simple --timeout=180s >/dev/null
echo "400 requêtes au Service simple :"
kubectl -n ch58 logs client-simple
kubectl -n ch58 delete pod client-simple --wait=false >/dev/null
kubectl -n ch58 delete rollout simple >/dev/null; kubectl -n ch58 delete service simple >/dev/null

section "ex4 bleu-vert annule"
kubectl argo rollouts set image bv podinfo=ghcr.io/stefanprodan/podinfo:6.14.1 -n ch58
for i in $(seq 1 60); do [ "$(kubectl -n ch58 get rollout bv -o jsonpath='{.status.phase}')" = Paused ] && break; sleep 2; done
kubectl -n ch58 get rollout bv -o jsonpath='{.status.phase}{"\n"}'
kubectl -n ch58 get svc bv-actif bv-apercu -o custom-columns=SERVICE:.metadata.name,SELECTEUR:.spec.selector
echo "\$ kubectl argo rollouts abort bv -n ch58"
kubectl argo rollouts abort bv -n ch58
sleep 8
kubectl -n ch58 get rollout bv -o jsonpath='{.status.phase}{"\n"}'
kubectl -n ch58 get svc bv-actif bv-apercu -o custom-columns=SERVICE:.metadata.name,SELECTEUR:.spec.selector
kubectl -n ch58 get rs -l app=bv -o custom-columns=RS:.metadata.name,VOULUS:.spec.replicas,IMAGE:.spec.template.spec.containers[0].image
echo "--- 35 s plus tard"
sleep 35
kubectl -n ch58 get rs -l app=bv -o custom-columns=RS:.metadata.name,VOULUS:.spec.replicas,IMAGE:.spec.template.spec.containers[0].image
echo; echo "### fin"
