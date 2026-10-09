#!/usr/bin/env bash
# Chapitre 58 : déploiements progressifs avec Argo Rollouts. Repart de zéro : supprime ch58,
# argo-rollouts et les CRD d'Argo Rollouts, puis rejoue. Suppose Gitea (chapitre 57) et Prometheus
# (chapitre 50) en place. Sorties : outils/out/ch58r.
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/rollouts
O=$RACINE/outils/out/ch58r; mkdir -p $O && cd $O && rm -f *.log
section() { echo; echo "### $*"; }
heure() { date +%s.%N; }
duree() { echo "$(echo "$(heure) - $1" | bc | cut -c1-5) s"; }
INSTALL=https://github.com/argoproj/argo-rollouts/releases/download/v1.10.0/install.yaml
GREFFON=https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi/releases/download/v0.17.0/gatewayapi-plugin-linux-amd64
MDP_GIT=depot-du-cours-57
mesure() { # nombre de requêtes : répartition des versions servies par vitrine.local
  for i in $(seq 1 ${1:-200}); do curl -s --max-time 2 --resolve vitrine.local:80:192.168.49.102 http://vitrine.local/version | jq -r '.version // "erreur"' 2>/dev/null || echo erreur; done | sort | uniq -c | tr -s ' ' | tr '\n' ' '; echo
}
poids() { kubectl -n ch58 get httproute vitrine -o json | jq -c '[.spec.rules[0].backendRefs[] | "\(.name)=\(.weight)"]'; }
etat() { kubectl argo rollouts get rollout ${1:-vitrine} -n ch58 --no-color | sed -n '1,/^Replicas:/p' | grep -v "^Replicas:"; }
charge() { # charge de fond vers vitrine.local, 5 requêtes par seconde, pendant $1 secondes
  ( fin=$(( $(date +%s) + $1 )); while [ $(date +%s) -lt $fin ]; do curl -s -o /dev/null --max-time 2 --resolve vitrine.local:80:192.168.49.102 http://vitrine.local/; sleep 0.2; done ) &
  CHARGES="${CHARGES:-} $!"
}

# --- remise à zéro
kubectl delete ns ch58 --ignore-not-found --wait=true >/dev/null
kubectl delete ns argo-rollouts --ignore-not-found --wait=true >/dev/null
kubectl delete crd analysisruns.argoproj.io analysistemplates.argoproj.io clusteranalysistemplates.argoproj.io experiments.argoproj.io rollouts.argoproj.io --ignore-not-found >/dev/null
kubectl delete clusterrole argo-rollouts argo-rollouts-aggregate-to-admin argo-rollouts-aggregate-to-edit argo-rollouts-aggregate-to-view argo-rollouts-gatewayapi --ignore-not-found >/dev/null
kubectl delete clusterrolebinding argo-rollouts argo-rollouts-gatewayapi --ignore-not-found >/dev/null

section "installation"
kubectl create namespace argo-rollouts
echo "\$ kubectl apply -n argo-rollouts -f install.yaml"
kubectl apply -n argo-rollouts -f $INSTALL 2>&1 | grep -E "Too long|deployment" | sed -E 's/^Error from server \(Invalid\): error when creating "[^"]*": /Error from server (Invalid): /'
echo "\$ kubectl apply -n argo-rollouts --server-side -f install.yaml"
kubectl apply -n argo-rollouts --server-side --force-conflicts -f $INSTALL | grep -c "serverside-applied" | sed 's/^/objets appliqués : /'
kubectl get crd -o name | grep -E "rollouts|analysis|experiments" | sed 's#customresourcedefinition.apiextensions.k8s.io/##'
kubectl argo rollouts version --short

section "greffon"
[ -f gatewayapi-plugin-linux-amd64 ] || curl -sL -o gatewayapi-plugin-linux-amd64 $GREFFON
ls -l gatewayapi-plugin-linux-amd64 | awk '{print $5, $NF}'
sha256sum gatewayapi-plugin-linux-amd64
kubectl -n git port-forward svc/gitea 3030:3000 >/dev/null 2>&1 & PFG=$!
trap 'kill $PFG 2>/dev/null' EXIT
for i in $(seq 1 30); do curl -s -o /dev/null --max-time 2 http://localhost:3030/api/healthz && break; sleep 1; done
if ! curl -s -o /dev/null -w '%{http_code}' http://localhost:3030/api/v1/repos/cours/outils | grep -q 200; then
  curl -s -u cours:$MDP_GIT -H 'Content-Type: application/json' -X POST -d '{"name":"outils","private":false,"auto_init":true,"default_branch":"main"}' http://localhost:3030/api/v1/user/repos >/dev/null
fi
R=$(curl -s -u cours:$MDP_GIT http://localhost:3030/api/v1/repos/cours/outils/releases/tags/gatewayapi-v0.17.0 | jq -r '.id // empty')
if [ -z "$R" ]; then
  R=$(curl -s -u cours:$MDP_GIT -H 'Content-Type: application/json' -X POST -d '{"tag_name":"gatewayapi-v0.17.0","name":"greffon Gateway API 0.17.0","target_commitish":"main"}' http://localhost:3030/api/v1/repos/cours/outils/releases | jq -r .id)
  curl -s -u cours:$MDP_GIT -X POST -F "attachment=@gatewayapi-plugin-linux-amd64" "http://localhost:3030/api/v1/repos/cours/outils/releases/$R/assets?name=gatewayapi-plugin-linux-amd64" >/dev/null
fi
curl -s http://localhost:3030/api/v1/repos/cours/outils/releases/$R | jq -c '{tag_name, assets: [.assets[] | {name, size}]}'
kubectl apply -f $KIT/greffon-gateway.yaml
kubectl -n argo-rollouts rollout restart deployment/argo-rollouts >/dev/null
kubectl -n argo-rollouts rollout status deployment/argo-rollouts --timeout=300s >/dev/null
sleep 5
kubectl -n argo-rollouts logs deploy/argo-rollouts | grep -E "Downloading plugin|Download complete" | sed -E 's/^time="[^"]*" level=info msg="//; s/"$//'
kubectl -n argo-rollouts get pods

section "premier deploiement"
kubectl apply -f $KIT/01-services-route.yaml -f $KIT/02-rollout.yaml
kubectl argo rollouts status vitrine -n ch58 --timeout 180s
kubectl argo rollouts get rollout vitrine -n ch58 --no-color
poids
echo "200 requêtes : $(mesure 200)"

section "canari"
kubectl argo rollouts set image vitrine podinfo=ghcr.io/stefanprodan/podinfo:6.15.0 -n ch58
sleep 10
etat
poids
kubectl -n ch58 get rs -o custom-columns=RS:.metadata.name,VOULUS:.spec.replicas,PRETS:.status.readyReplicas,IMAGE:.spec.template.spec.containers[0].image
echo "200 requêtes : $(mesure 200)"
for i in $(seq 1 60); do [ "$(kubectl -n ch58 get rollout vitrine -o jsonpath='{.status.currentStepIndex}')" = 3 ] && break; sleep 2; done
etat
poids
kubectl -n ch58 get rs -o custom-columns=RS:.metadata.name,VOULUS:.spec.replicas,PRETS:.status.readyReplicas,IMAGE:.spec.template.spec.containers[0].image
echo "200 requêtes : $(mesure 200)"
sleep 20
kubectl -n ch58 get rollout vitrine -o jsonpath='étape {.status.currentStepIndex}, en pause : {.spec.paused} {.status.pauseConditions}{"\n"}'

section "promotion"
d=$(heure)
kubectl argo rollouts promote vitrine -n ch58
kubectl argo rollouts status vitrine -n ch58 --timeout 180s
echo "terminé $(duree $d) après la promotion"
poids
kubectl argo rollouts get rollout vitrine -n ch58 --no-color | sed -n '/^NAME/,$p'
sleep 35
kubectl -n ch58 get rs -o custom-columns=RS:.metadata.name,VOULUS:.spec.replicas,IMAGE:.spec.template.spec.containers[0].image

section "analyse"
kubectl apply -f $KIT/03-moniteur.yaml -f $KIT/04-analyse.yaml -f $KIT/05-rollout-analyse.yaml
sleep 40
echo "--- une mauvaise version : podinfo 6.15.0 avec --random-error"
charge 200
kubectl -n ch58 patch rollout vitrine --type=json -p '[{"op":"add","path":"/spec/template/spec/containers/0/args","value":["./podinfo","--port=9898","--random-error=true"]}]'
d=$(heure)
for i in $(seq 1 200); do p=$(kubectl -n ch58 get rollout vitrine -o jsonpath='{.status.phase}'); [ "$p" = Degraded ] && break; sleep 2; done
echo "abandon $(duree $d) après le déploiement de la mauvaise version"
etat
poids
kubectl -n ch58 get analysisrun -o custom-columns=ANALYSE:.metadata.name,PHASE:.status.phase,MESSAGE:.status.message
AR=$(kubectl -n ch58 get analysisrun --sort-by=.metadata.creationTimestamp -o name | tail -1)
kubectl -n ch58 get $AR -o json | jq -c '.status.metricResults[] | {name, phase, successful, failed, mesures: [.measurements[] | {phase, value}]}'
echo "200 requêtes : $(mesure 200)"
echo "--- une bonne version : podinfo 6.14.1"
charge 200
kubectl -n ch58 patch rollout vitrine --type=json -p '[{"op":"remove","path":"/spec/template/spec/containers/0/args"},{"op":"replace","path":"/spec/template/spec/containers/0/image","value":"ghcr.io/stefanprodan/podinfo:6.14.1"}]'
d=$(heure)
for i in $(seq 1 200); do p=$(kubectl -n ch58 get rollout vitrine -o jsonpath='{.status.phase}'); [ "$p" = Healthy ] && break; sleep 2; done
echo "état $p $(duree $d) plus tard"
kubectl -n ch58 get analysisrun -o custom-columns=ANALYSE:.metadata.name,PHASE:.status.phase
AR=$(kubectl -n ch58 get analysisrun --sort-by=.metadata.creationTimestamp -o name | tail -1)
kubectl -n ch58 get $AR -o json | jq -c '.status.metricResults[] | {name, phase, successful, failed, mesures: [.measurements[] | {phase, value}]}'
kubectl argo rollouts get rollout vitrine -n ch58 --no-color | sed -n '/^NAME/,$p' | head -14
wait $CHARGES

section "bleu-vert"
kubectl apply -f $KIT/06-bleu-vert.yaml
kubectl argo rollouts status bv -n ch58 --timeout 180s
kubectl -n ch58 get svc bv-actif bv-apercu -o custom-columns=SERVICE:.metadata.name,SELECTEUR:.spec.selector
kubectl -n ch58 run client --image=ghcr.io/stefanprodan/podinfo:6.15.0 --restart=Never --command -- sh -c \
  'while true; do echo "$(date +%T) actif=$(wget -qO- -T 1 bv-actif/version | grep -o "6\.[0-9]*\.[0-9]*") apercu=$(wget -qO- -T 1 bv-apercu/version | grep -o "6\.[0-9]*\.[0-9]*")"; sleep 1; done' >/dev/null
kubectl -n ch58 wait --for=condition=Ready pod/client --timeout=60s >/dev/null
kubectl argo rollouts set image bv podinfo=ghcr.io/stefanprodan/podinfo:6.15.0 -n ch58
for i in $(seq 1 60); do [ "$(kubectl -n ch58 get rollout bv -o jsonpath='{.status.phase}')" = Paused ] && break; sleep 2; done
etat bv
kubectl -n ch58 get svc bv-actif bv-apercu -o custom-columns=SERVICE:.metadata.name,SELECTEUR:.spec.selector
sleep 5
kubectl -n ch58 logs client --tail=3
date -u +"promotion à %T"
kubectl argo rollouts promote bv -n ch58
sleep 8
kubectl -n ch58 logs client --tail=8
kubectl -n ch58 get rs -l app=bv -o custom-columns=RS:.metadata.name,VOULUS:.spec.replicas,IMAGE:.spec.template.spec.containers[0].image
sleep 35
echo "--- 35 s plus tard"
kubectl -n ch58 get rs -l app=bv -o custom-columns=RS:.metadata.name,VOULUS:.spec.replicas,IMAGE:.spec.template.spec.containers[0].image
kubectl -n ch58 delete pod client --wait=false >/dev/null
kubectl -n argo-rollouts top pods
docker stats --no-stream minikube --format 'mémoire du nœud : {{.MemUsage}}'
echo; echo "### fin"
