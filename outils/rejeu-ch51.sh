#!/usr/bin/env bash
# Rejeu du chapitre 51 (journaux et traces), après rejeu-ch51-installation.sh. Journal sur la sortie standard.
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/journaux
CA=$RACINE/outils/out/ch28/m/ca.crt
section() { echo; echo "### $*"; }
mkdir -p $RACINE/outils/out/ch51r && cd $RACINE/outils/out/ch51r
# des redirections neuves à chaque passage : une ancienne peut viser un Pod disparu
PIDS=()
ouvrir() { kubectl -n supervision port-forward svc/$2 $1:$3 >/dev/null 2>&1 & PIDS+=($!); }
ouvrir 9105 supervision-kube-prometheu-prometheus 9090
ouvrir 3111 loki 3100
ouvrir 3211 tempo 3200
ouvrir 3052 supervision-grafana 80
trap 'kill ${PIDS[@]} 2>/dev/null' EXIT
sleep 4
L=http://localhost:3111
T=http://localhost:3211
DEPUIS=$(( $(date +%s) - 900 ))
lignes() {  # $1 requête LogQL, $2 nombre ; les lignes, de la plus ancienne à la plus récente
  curl -s -G $L/loki/api/v1/query_range --data-urlencode "query=$1" --data-urlencode "limit=$2" --data-urlencode "since=15m" \
    | jq -r '[.data.result[] | .values[] ] | sort_by(.[0]) | .[] | .[1]'
}
metrique() {  # $1 requête LogQL de type métrique, évaluée maintenant
  curl -s -G $L/loki/api/v1/query --data-urlencode "query=$1" \
    | jq -r '.data.result[] | "\(.metric | to_entries | map("\(.key)=\(.value)") | join(" ")) \(.value[1] | tonumber | (. * 100 | round) / 100)"'
}
recherche() {  # $1 requête TraceQL, $2 nombre
  curl -s -G $T/api/search --data-urlencode "q=$1" --data-urlencode "limit=$2" --data-urlencode "start=$DEPUIS" --data-urlencode "end=$(date +%s)" \
    | jq -r '.traces[]? | "\(.traceID) \(.rootServiceName) \(.rootTraceName) \(.durationMs // 0) ms"'
}
charge() { python3 $RACINE/kits/metriques/charge.py --ca $CA "$@"; }

# --- remise à zéro : Colis 2.2, pas de traces, pas de politique de sortie
bash $RACINE/kits/metriques/passer-en-2.2.sh >/dev/null 2>&1
kubectl -n colis delete networkpolicy traces --ignore-not-found >/dev/null 2>&1
kubectl -n colis set env deployment/api OTEL_EXPORTER_OTLP_ENDPOINT- OTEL_SERVICE_NAME- OTEL_RESOURCE_ATTRIBUTES- >/dev/null 2>&1
kubectl -n colis set env deployment/worker OTEL_EXPORTER_OTLP_ENDPOINT- OTEL_SERVICE_NAME- OTEL_RESOURCE_ATTRIBUTES- >/dev/null 2>&1
kubectl -n colis rollout status deployment/api >/dev/null 2>&1

section "etiquettes"
charge --duree 20 --debit 4
sleep 10
curl -s $L/loki/api/v1/labels | jq -c .data
curl -s $L/loki/api/v1/label/service_name/values | jq -c .data
curl -s -G $L/loki/api/v1/series --data-urlencode 'match[]={service_name="api"}' --data-urlencode "start=$(( $(date +%s) - 900 ))000000000" \
  | jq -c '.data[0] | with_entries(select(.key | test("^(service_|k8s_namespace|k8s_deployment|k8s_pod_name|k8s_container_name)")))'
curl -s -G $L/loki/api/v1/series --data-urlencode 'match[]={k8s_namespace_name=~".+"}' --data-urlencode "start=$(( $(date +%s) - 900 ))000000000" | jq '.data | length'

section "une ligne"
lignes '{service_name="api"}' 2

section "logql filtres"
lignes '{service_name="api"} | json | code >= 400' 3
section "logql metriques"
echo '$ par code'; metrique 'sum by (code) (count_over_time({service_name="api"} | json [5m]))'
echo '$ par code, sans les lignes non JSON'; metrique 'sum by (code) (count_over_time({service_name="api"} | json | __error__="" [5m]))'
echo '$ p95 par route'; metrique 'quantile_over_time(0.95, {service_name="api"} | json | __error__="" | unwrap duree_ms [5m]) by (route)'
echo '$ volume par service'; metrique 'sum by (service_name) (bytes_over_time({k8s_namespace_name="colis"}[5m]))'

section "traces bloquees"
bash $KIT/activer-traces.sh
charge --duree 15 --debit 4
sleep 45
echo "(traces trouvées : $(recherche '{ resource.service.name = "api" }' 20 | wc -l))"
kubectl -n colis logs deploy/api | grep -v '^{' | grep -v '^INFO:' | head -4 | cut -c1-220

section "traces"
kubectl apply -f $KIT/politique-traces.yaml
kubectl -n colis rollout restart deployment/api deployment/worker
kubectl -n colis rollout status deployment/api >/dev/null
DEPUIS=$(date +%s)
charge --duree 20 --debit 4
sleep 40
recherche '{ resource.service.name = "api" }' 4
ID=$(recherche '{ resource.service.name = "api" && name = "POST /colis" }' 1 | awk '{print $1}')
echo "\$ arbre-trace.py $ID"
python3 $KIT/arbre-trace.py --tempo $T $ID
echo "\$ journal de la même requête"
lignes "{service_name=\"api\"} |= \"$ID\"" 2
echo "\$ worker"
recherche '{ resource.service.name = "worker" }' 4
echo "\$ racines"
recherche '{ resource.service.name = "api" }' 40 | awk '{print $3}' | sort | uniq -c | sort -rn
recherche '{ resource.service.name = "worker" }' 40 | awk '{print $3, $4}' | sort | uniq -c | sort -rn | head -3

section "ordre"
PGIP=$(kubectl -n colis get pod postgres-0 -o jsonpath='{.status.podIP}')
A=$(kubectl -n colis get pods -l app.kubernetes.io/name=api -o name | head -1)
for o in connexion-avant connexion-apres; do
  kubectl -n colis exec -i $A -- sh -c "cd /app && COLIS_DB=\$(echo \$COLIS_DB | sed s/@postgres:/@$PGIP:/) python - $o" < $KIT/ordre-des-traces.py 2>&1 | tail -1
done

section "correctif"
cat $KIT/colis-2.2.1.patch | grep -c '^@@'
bash $KIT/passer-en-2.2.1.sh
kubectl -n colis rollout status deployment/worker >/dev/null 2>&1
DEPUIS=$(date +%s)
charge --duree 20 --debit 4
sleep 40
ID=$(recherche '{ resource.service.name = "api" && name = "POST /colis" }' 1 | awk '{print $1}')
echo "\$ arbre-trace.py $ID"
python3 $KIT/arbre-trace.py --tempo $T $ID
ID=$(recherche '{ resource.service.name = "api" && name = "GET /colis/{id_}" }' 1 | awk '{print $1}')
echo "\$ arbre-trace.py $ID"
python3 $KIT/arbre-trace.py --tempo $T $ID
W=$(recherche '{ resource.service.name = "worker" && name = "estimer un colis" }' 1 | awk '{print $1}')
echo "\$ arbre-trace.py $W"
python3 $KIT/arbre-trace.py --tempo $T $W
echo "\$ racines"
recherche '{ resource.service.name = "api" }' 40 | awk '{print $3}' | sort | uniq -c | sort -rn
recherche '{ resource.service.name = "worker" }' 40 | awk '{print $3, $4, $5}' | sort | uniq -c | sort -rn | head -3

section "incident"
DEPUIS=$(date +%s)
charge --duree 75 --debit 4 > charge.txt &
CHARGE=$!
charge --duree 75 --debit 4 > charge2.txt &
CHARGE2=$!
sleep 25
date +%T
kubectl -n colis exec postgres-0 -- psql -U colis -d colis -c "BEGIN; LOCK TABLE colis IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(6); COMMIT;" > verrou.txt 2>&1 &
sleep 3
kubectl -n colis exec postgres-0 -- psql -U colis -d colis -c "SELECT pid, state, wait_event_type AS attente, wait_event, now() - query_start AS depuis, left(query, 50) AS requete FROM pg_stat_activity WHERE datname = 'colis' AND pid <> pg_backend_pid() ORDER BY query_start"
wait $CHARGE $CHARGE2; cat charge.txt charge2.txt; cat verrou.txt
kubectl -n colis get pods -l app.kubernetes.io/name=api
sleep 40

section "enquete : journaux"
echo '$ requetes de plus d une seconde'; metrique 'sum by (route) (count_over_time({service_name="api"} | json | __error__="" | duree_ms > 1000 [5m]))'
lignes '{service_name="api"} | json | duree_ms > 1000' 20 | jq -c --arg d "$(date -u -d @$DEPUIS +%Y-%m-%dT%H:%M:%S)" 'select(.moment >= $d)' | jq -r 'tojson' | head -4 > lentes.txt
cat lentes.txt | jq -c '{moment, methode, chemin, code, duree_ms, trace_id}'
LENT=$(jq -r 'select(.methode == "POST") | .trace_id' lentes.txt | head -1)
[ -n "$LENT" ] || LENT=$(head -1 lentes.txt | jq -r .trace_id)

section "enquete : trace"
echo "\$ arbre-trace.py $LENT"
python3 $KIT/arbre-trace.py --tempo $T $LENT
echo '$ traceql api'
recherche '{ resource.service.name = "api" && duration > 1s }' 5
echo '$ traceql postgresql'
recherche '{ span.db.system = "postgresql" && duration > 1s }' 5

section "enquete : metriques"
curl -s localhost:9105/api/v1/query --data-urlencode 'query=max_over_time(colis:latence:p95_5m{route="/colis"}[10m])' | jq -r '.data.result[] | "p95 maximal de /colis sur 10 min : \(.value[1])"'
curl -s localhost:9105/api/v1/query --data-urlencode 'query=histogram_quantile(0.99, sum by (le) (rate(colis_http_duree_secondes_bucket{namespace="colis"}[5m])))' | jq -r '.data.result[] | "p99 global sur 5 min : \(.value[1])"'
curl -s localhost:9105/api/v1/query --data-urlencode 'query=sum(increase(colis_http_duree_secondes_count{namespace="colis"}[10m])) - sum(increase(colis_http_duree_secondes_bucket{namespace="colis", le="2.5"}[10m]))' | jq -r '.data.result[] | "requêtes de plus de 2,5 s sur 10 min : \(.value[1])"'

section "grafana"
MDP=$(kubectl -n supervision get secret supervision-grafana -o jsonpath='{.data.admin-password}' | base64 -d)
curl -s -u admin:$MDP localhost:3052/api/datasources | jq -c '.[] | {name, type, uid}'
for u in prometheus loki tempo; do echo "$u : $(curl -s -u admin:$MDP localhost:3052/api/datasources/uid/$u/health | jq -c '{status, message}')"; done

section "memoire"
kubectl top pod -n supervision --no-headers | sort -k3 -h -r
minikube ssh -- 'awk "/^anon /{printf \"%.0f Mio de mémoire anonyme\\n\", \$2/1048576}" /sys/fs/cgroup/memory.stat' 2>/dev/null
curl -s localhost:3101/metrics | grep -E '^loki_ingester_memory_streams |^loki_distributor_bytes_received_total' | head -3
echo; echo "### fin"
