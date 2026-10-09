#!/usr/bin/env bash
# Chapitre 56, exercices, sur colis-pg (namespace colis). Sorties : outils/out/ch56r/exercices.
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/cnpg
O=$RACINE/outils/out/ch56r/exercices; rm -rf $O; mkdir -p $O && cd $O
section() { echo; echo "### $*"; }
primaire() { kubectl -n colis get cluster colis-pg -o jsonpath='{.status.currentPrimary}'; }

section "ex1 bascule sous charge"
# mesure : charge.py pendant la bascule, puis les erreurs 5xx vues par l'API
bascule() { # durée de la charge, en secondes
  python3 $RACINE/kits/metriques/charge.py --duree $1 --debit 6 > charge.txt 2>&1 & CH=$!
  sleep 15
  P=$(primaire)
  date -u +"%T suppression de $P (primaire)"
  kubectl -n colis delete pod $P --wait=false >/dev/null
  for i in $(seq 1 400); do [ "$(primaire)" != "$P" ] && break; sleep 1; done
  date -u +"%T nouvelle primaire : $(primaire)"
  kubectl -n colis get cluster colis-pg -o jsonpath='promotion : {.status.currentPrimaryTimestamp}{"\n"}'
  wait $CH
  cat charge.txt
  for a in $(kubectl -n colis get pods -l app.kubernetes.io/name=api -o name); do
    echo "${a#pod/} : $(kubectl -n colis logs $a --since=$(( $1 + 30 ))s | grep -c '"code": 5') réponses 5xx"
  done
  for i in $(seq 1 60); do [ "$(kubectl -n colis get cluster colis-pg -o jsonpath='{.status.phase}')" = "Cluster in healthy state" ] && break; sleep 3; done
  kubectl -n colis get cluster colis-pg
}
echo "--- réglage par défaut"
kubectl -n colis get cluster colis-pg -o jsonpath='smartShutdownTimeout : {.spec.smartShutdownTimeout}, stopDelay : {.spec.stopDelay}{"\n"}'
bascule 240
echo "--- smartShutdownTimeout à 10 s"
kubectl -n colis patch cluster colis-pg --type=merge -p '{"spec":{"smartShutdownTimeout":10}}'
sleep 10
for i in $(seq 1 100); do [ "$(kubectl -n colis get cluster colis-pg -o jsonpath='{.status.phase}')" = "Cluster in healthy state" ] && break; sleep 3; done
bascule 90

section "ex2 planification"
cat > planifiee-5.yaml <<'Y'
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata: {name: quotidienne, namespace: colis}
spec:
  schedule: "0 2 * * *"
  cluster: {name: colis-pg}
  method: plugin
  pluginConfiguration: {name: barman-cloud.cloudnative-pg.io}
Y
sed 's/"0 2 \* \* \*"/"0 0 2 * * *"/' planifiee-5.yaml > planifiee-6.yaml
echo '$ kubectl apply -f planifiee-5.yaml      # schedule: "0 2 * * *"'
kubectl apply -f planifiee-5.yaml 2>&1
sleep 3
kubectl -n cnpg-system logs deploy/cnpg-controller-manager --since=1m | grep '"Next backup schedule"' | grep '"quotidienne"' | tail -1 | jq -r '"prochaine sauvegarde : " + .next'
kubectl -n colis delete scheduledbackup quotidienne --ignore-not-found >/dev/null
echo '$ kubectl apply -f planifiee-6.yaml      # schedule: "0 0 2 * * *"'
kubectl apply -f planifiee-6.yaml
sleep 3
kubectl -n cnpg-system logs deploy/cnpg-controller-manager --since=1m | grep '"Next backup schedule"' | grep '"quotidienne"' | tail -1 | jq -r '"prochaine sauvegarde : " + .next'
date -u +"maintenant : %FT%TZ"

section "ex3 retard"
python3 $KIT/corrige/retard-replication.py -n colis colis-pg; echo "code : $?"
P=$(primaire)
( kubectl -n colis exec $P -c postgres -- psql -U postgres -d colis -qc "CREATE TABLE lest AS SELECT g, md5(g::text) AS h FROM generate_series(1, 2000000) g" ) & LEST=$!
python3 $KIT/corrige/retard-replication.py -n colis colis-pg --repetitions 8 --intervalle 1 --seuil-octets 8388608; echo "code : $?"
wait $LEST
python3 $KIT/corrige/retard-replication.py -n colis colis-pg; echo "code : $?"
kubectl -n colis exec $(primaire) -c postgres -- psql -U postgres -d colis -qc "DROP TABLE lest"

section "ex4 metriques"
cat > moniteur-colis-pg.yaml <<'Y'
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata: {name: colis-pg, namespace: colis}
spec:
  selector:
    matchLabels: {cnpg.io/cluster: colis-pg}
  podMetricsEndpoints:
  - port: metrics
    interval: 15s
Y
kubectl apply -f moniteur-colis-pg.yaml
kubectl -n supervision port-forward svc/supervision-kube-prometheu-prometheus 9095:9090 >/dev/null 2>&1 & PF=$!
for i in $(seq 1 40); do
  # deux cibles, et un collecteur en état sur chacune (il échoue un temps après une promotion)
  n=$(curl -s --get localhost:9095/api/v1/query --data-urlencode 'query=sum(cnpg_collector_up{namespace="colis"})' | jq -r '.data.result[0].value[1] // 0' 2>/dev/null)
  [ "$n" = 2 ] && break; sleep 5
done
q() { curl -s --get localhost:9095/api/v1/query --data-urlencode "query=$1" | jq -r '.data.result[] | "\(.metric.pod // "") \(.metric.role // "") \(.value[1])"'; }
echo '# up'; q 'up{namespace="colis", pod=~"colis-pg-.*"}'
echo '# cnpg_collector_up'; q 'cnpg_collector_up{namespace="colis"}'
echo '# cnpg_pg_replication_lag'; q 'cnpg_pg_replication_lag{namespace="colis"}'
echo '# cnpg_pg_database_size_bytes'; q 'cnpg_pg_database_size_bytes{namespace="colis", datname="colis"}'
echo '# séries exportées par instance'; q 'count by (pod) ({namespace="colis", pod=~"colis-pg-.*", __name__=~"cnpg_.*"})'
kill $PF
echo; echo "### fin"
