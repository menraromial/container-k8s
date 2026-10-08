#!/usr/bin/env bash
# Exercices du chapitre 51, après rejeu-ch51.sh (port-forwards 9095, 3101, 3201 ouverts).
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
CA=$RACINE/outils/out/ch28/m/ca.crt
section() { echo; echo "### $*"; }
mkdir -p $RACINE/outils/out/ch51r && cd $RACINE/outils/out/ch51r
PIDS=()
for pf in "3112 loki 3100" "3212 tempo 3200" "9106 supervision-kube-prometheu-prometheus 9090"; do
  set -- $pf; kubectl -n supervision port-forward svc/$2 $1:$3 >/dev/null 2>&1 & PIDS+=($!)
done
trap 'kill ${PIDS[@]} 2>/dev/null' EXIT
sleep 4
L=http://localhost:3112
T=http://localhost:3212
charge() { python3 $RACINE/kits/metriques/charge.py --ca $CA "$@"; }

section "ex1 journaux et metriques"
charge --duree 60 --debit 6
sleep 30
echo "\$ LogQL"; curl -s -G $L/loki/api/v1/query --data-urlencode 'query=sum(count_over_time({service_name="api"} | json | __error__="" | code="404" [2m]))' | jq -r '.data.result[0].value[1]'
echo "\$ PromQL"; curl -s localhost:9106/api/v1/query --data-urlencode 'query=sum(increase(colis_http_requetes_total{namespace="colis", code="404"}[2m]))' | jq -r '.data.result[0].value[1]'

section "ex4 echantillonnage"
kubectl -n colis set env deployment/api OTEL_TRACES_SAMPLER=parentbased_traceidratio OTEL_TRACES_SAMPLER_ARG=0.1
kubectl -n colis rollout status deployment/api >/dev/null
DEBUT=$(date +%s)
charge --duree 60 --debit 5
sleep 20
FIN=$(date +%s)
echo "traces de l'API dans Tempo : $(curl -s -G $T/api/search --data-urlencode 'q={ resource.service.name = "api" && kind = server }' --data-urlencode limit=1000 --data-urlencode start=$DEBUT --data-urlencode end=$FIN | jq '.traces | length')"
echo "requêtes dans les journaux : $(curl -s -G $L/loki/api/v1/query --data-urlencode "query=sum(count_over_time({service_name=\"api\"} | json | __error__=\"\" | trace_id != \"\" [80s]))" | jq -r '.data.result[0].value[1]')"
for id in $(curl -s -G $L/loki/api/v1/query_range --data-urlencode 'query={service_name="api"} | json | __error__="" | trace_id != ""' --data-urlencode limit=8 --data-urlencode since=60s | jq -r '.data.result[].values[][1]' | jq -r .trace_id | head -8); do
  printf '%s %s\n' $id "$(curl -s $T/api/v2/traces/$id | jq -r 'if .trace.resourceSpans then "trouvée (\([.trace.resourceSpans[].scopeSpans[].spans[]] | length) spans)" else "absente : {\"trace\":{}}" end')"
done
kubectl -n colis set env deployment/api OTEL_TRACES_SAMPLER- OTEL_TRACES_SAMPLER_ARG-
kubectl -n colis rollout status deployment/api >/dev/null
echo; echo "### fin"
