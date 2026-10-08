#!/usr/bin/env bash
# Exercices du chapitre 50, à lancer après rejeu-ch50.sh (port-forward de Prometheus sur 9095 ouvert).
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/metriques
P=http://localhost:9095
section() { echo; echo "### $*"; }
mkdir -p $RACINE/outils/out/ch50r && cd $RACINE/outils/out/ch50r
q() { curl -s "$P/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result[] | "\(.metric | del(.__name__) | to_entries | map("\(.key)=\(.value)") | join(" ")) \(.value[1] | tonumber | (. * 10000 | round) / 10000)"'; }

section "histogramme"
echo '$ buckets /colis, 10 min'; q 'sum by (le) (increase(colis_http_duree_secondes_bucket{namespace="colis", route="/colis"}[10m]))'
echo '$ p95 /colis, 10 min'; q 'histogram_quantile(0.95, sum by (le) (rate(colis_http_duree_secondes_bucket{namespace="colis", route="/colis"}[10m])))'

section "ex1 cardinalite"
echo '$ series de duree'; q 'count(colis_http_duree_secondes_bucket{namespace="colis"})'
echo '$ par pod'; q 'count by (pod) (colis_http_duree_secondes_bucket{namespace="colis"})'
kubectl -n colis exec postgres-0 -- psql -U colis -d colis -Atc 'SELECT count(*) FROM colis'

section "ex2 objectifs"
echo '$ disponibilite 30 min'; q '1 - sum(increase(colis_http_requetes_total{namespace="colis", code=~"5.."}[30m])) / sum(increase(colis_http_requetes_total{namespace="colis"}[30m]))'
echo '$ disponibilite 30 min (corrigee)'; q '1 - (sum(increase(colis_http_requetes_total{namespace="colis", code=~"5.."}[30m])) or vector(0)) / sum(increase(colis_http_requetes_total{namespace="colis"}[30m]))'
echo '$ part sous 25 ms'; q 'sum(rate(colis_http_duree_secondes_bucket{namespace="colis", le="0.025"}[30m])) / sum(rate(colis_http_duree_secondes_count{namespace="colis"}[30m]))'

section "ex3 dimensionner"
python3 $KIT/corrige/dimensionner.py colis --periode 1h

section "ex4 cible muette"
cat > muette.yaml <<'YAML'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: colis-collecte
  namespace: colis
spec:
  groups:
  - name: colis.collecte
    rules:
    - alert: ColisApiMuette
      expr: (sum by (namespace) (up{namespace="colis", service="api"}) == 0) or absent(up{namespace="colis", service="api"})
      for: 1m
      labels:
        severite: page
        namespace: colis
      annotations:
        resume: "Prometheus ne collecte plus l'API de Colis"
        description: "Aucune instance de l'API ne répond à la collecte depuis 1 minute."
YAML
kubectl apply -f muette.yaml
kubectl -n colis delete networkpolicy supervision
date +%T
for i in $(seq 1 18); do
  sleep 15
  etat=$(curl -s $P/api/v1/alerts | jq -r '.data.alerts[] | select(.labels.alertname == "ColisApiMuette") | .state')
  echo "$(date +%T) ${etat:-inactive} $(q 'sum(up{namespace="colis", service="api"})' | awk '{print "up=" $NF}')"
  [ "$etat" = firing ] && break
done
sleep 40
kubectl -n supervision logs deploy/pager | tail -2
kubectl apply -f $KIT/politique-supervision.yaml
for i in $(seq 1 16); do sleep 15; kubectl -n supervision logs deploy/pager | grep -q "RESOLVED ColisApiMuette" && break; done
kubectl -n supervision logs deploy/pager | tail -1
kubectl delete -f muette.yaml
echo; echo "### fin"
