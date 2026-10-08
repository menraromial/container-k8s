#!/usr/bin/env bash
# Chapitre 51, première partie : alléger la supervision, puis installer Loki, Tempo et le collecteur.
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/journaux
section() { echo; echo "### $*"; }
mkdir -p $RACINE/outils/out/ch51r && cd $RACINE/outils/out/ch51r
P=http://localhost:9095
ss -ltn | grep -q ':9095 ' || { kubectl -n supervision port-forward svc/supervision-kube-prometheu-prometheus 9095:9090 >/dev/null 2>&1 & sleep 3; }
q() { curl -s "$P/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result[] | "\(.metric | del(.__name__) | to_entries | map("\(.key)=\(.value)") | join(" ")) \(.value[1])"'; }
anon() { minikube ssh -- 'awk "/^anon /{printf \"%.0f Mio de mémoire anonyme\\n\", \$2/1048576}" /sys/fs/cgroup/memory.stat' 2>/dev/null; }

section "avant"
anon
q 'count({__name__=~".+"})'
q 'sort_desc(count by (job) ({__name__=~".+"}))' | head -4
kubectl top pod -n supervision --containers --no-headers | sort -k4 -h -r | head -5

section "allegement"
helm -n supervision upgrade supervision oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack --version 92.1.0 \
  -f $RACINE/kits/metriques/valeurs-supervision.yaml -f $KIT/valeurs-allegees.yaml --wait --timeout 10m 2>&1 | grep -E '^(Release|Error)'
kubectl -n supervision get pods -l app.kubernetes.io/name=grafana
sleep 420
q 'count({__name__=~".+"})'
q 'sort_desc(count by (job) ({__name__=~".+"}))' | head -4
anon

section "loki"
helm install loki oci://ghcr.io/grafana-community/helm-charts/loki --version 18.14.0 -n supervision \
  -f $KIT/valeurs-loki.yaml --wait --timeout 15m 2>&1 | grep -E '^(NAME|STATUS|Error)'
section "tempo"
helm install tempo oci://ghcr.io/grafana-community/helm-charts/tempo --version 3.1.0 -n supervision \
  -f $KIT/valeurs-tempo.yaml --wait --timeout 15m 2>&1 | grep -E '^(NAME|STATUS|Error)'
section "collecteur"
helm install collecteur oci://ghcr.io/open-telemetry/opentelemetry-helm-charts/opentelemetry-collector --version 0.175.1 \
  -n supervision -f $KIT/valeurs-collecteur.yaml --wait --timeout 15m 2>&1 | grep -E '^(NAME|STATUS|Error)'

section "apres"
helm -n supervision list
kubectl -n supervision get pods
kubectl -n supervision get pvc
kubectl top pod -n supervision --no-headers | sort -k3 -h -r
anon
echo; echo "### fin"
