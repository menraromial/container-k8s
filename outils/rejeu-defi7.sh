#!/usr/bin/env bash
# Rejeu du défi VII : déclenche l'incident sur Colis, attend la page, enquête, répare en deux temps,
# mesure l'impact. Sorties dans outils/out/defi7 (rejeu-defi7.log et fichiers annexes).
# Le post-mortem corrigé s'écrit ensuite à partir de ce journal ; la grille finale est passée à part.
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/defi-7
O=$RACINE/outils/out/defi7; mkdir -p $O && cd $O
section() { echo; echo "### $*"; }
heure() { echo "[$(date -u +%T)] $*"; }
kubectl -n supervision port-forward svc/supervision-kube-prometheu-prometheus 9095:9090 >/dev/null 2>&1 & PF1=$!
kubectl -n supervision port-forward svc/loki 3101:3100 >/dev/null 2>&1 & PF2=$!
trap 'kill $PF1 $PF2 2>/dev/null; [ -n "${CH:-}" ] && { pkill -P $CH; kill $CH; } 2>/dev/null' EXIT
sleep 3
prom() { curl -s --get localhost:9095/api/v1/query --data-urlencode "query=$1" | jq -r '.data.result[] | "\(.metric | del(.__name__) | to_entries | map("\(.key)=\(.value)") | join(",")) \(.value[1])"'; }
pager() { kubectl -n supervision logs deploy/pager --timestamps --since-time=$DEBUT | sed -E 's/^([0-9-]+T[0-9:]+)\.[0-9]+Z /\1Z /'; }

section "avant"
kubectl -n colis get pods
kubectl -n colis get deploy worker -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'

section "declenchement"
bash $KIT/declencher.sh 1500 > charge.txt 2>&1 & CH=$!
sleep 5
DEBUT=$(cat $KIT/debut-incident)
head -1 charge.txt
heure "début noté : $DEBUT"

# on attend la page, comme l'astreinte
for i in $(seq 1 60); do pager | grep -q 'FIRING.*ColisFileBloquee' && break; sleep 10; done
heure "page reçue"

section "page"
pager

section "symptomes"
kubectl -n colis get pods
prom 'max(colis_file_longueur{namespace="colis"})'
prom 'sum(rate(colis_http_requetes_total{namespace="colis", code=~"5.."}[5m])) / sum(rate(colis_http_requetes_total{namespace="colis"}[5m]))' | sed 's/^/erreurs 5xx : /'
prom 'colis:latence:p95_5m' | sed 's/^/p95 : /'
prom 'ALERTS{namespace="colis", alertstate="firing", alertname!="InfoInhibitor"}' | sed -E 's/ 1$//'

section "grille pendant"
bash $KIT/verifier.sh $O/aucun-post-mortem.md

section "worker"
W=$(kubectl -n colis get pods -l app.kubernetes.io/name=worker -o jsonpath='{.items[0].metadata.name}')
kubectl -n colis describe pod $W | sed -n '/^    State:/,/^    Ready:/p;/^    Limits:/,/^    Environment:/p' | grep -v Environment
kubectl -n colis logs $W --previous 2>&1 | tail -3
kubectl -n colis get events --field-selector involvedObject.name=$W -o custom-columns=RAISON:.reason,NOMBRE:.count,MESSAGE:.message | cut -c1-150

section "changements"
for o in deployment/worker deployment/api deployment/web statefulset/postgres networkpolicy/postgres networkpolicy/worker configmap/colis-config; do
  kubectl -n colis get $o --show-managed-fields -o json | jq -r --arg o $o '[.metadata.managedFields[] | select(.manager != "kube-controller-manager" and .time != null)] | max_by(.time) | "\($o)\t\(.manager)\t\(.operation)\t\(.time)"'
done | sort -t$'\t' -k4 | column -t -s$'\t'
echo
kubectl -n colis get deployment worker --show-managed-fields -o json | jq -c '.metadata.managedFields[] | select(.manager == "menage-ressources") | {manager, time, champs: .fieldsV1}'
kubectl -n colis get networkpolicy postgres --show-managed-fields -o json | jq -c '.metadata.managedFields[] | select(.manager == "menage-ressources") | {manager, time, champs: .fieldsV1}'
kubectl -n colis get networkpolicy postgres -o jsonpath='{.spec.ingress[0].from}{"\n"}'
echo
kubectl -n colis rollout history deployment/worker | tail -3
kubectl -n colis get rs -l 'app.kubernetes.io/name in (worker,api)' --sort-by=.metadata.creationTimestamp -o custom-columns=RS:.metadata.name,CREE:.metadata.creationTimestamp,VOULUS:.spec.replicas,MEMOIRE:.spec.template.spec.containers[0].resources.requests.memory | tail -5

section "premier correctif"
F1=$(date -u +%s)
heure "worker : 96 Mi demandés, 192 Mi de limite"
kubectl -n colis patch deployment worker --type=json -p '[
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources",
   "value": {"requests": {"cpu": "50m", "memory": "96Mi"}, "limits": {"memory": "192Mi"}}}]'
sleep 75
kubectl -n colis get pods -l app.kubernetes.io/name=worker
prom 'max(colis_file_longueur{namespace="colis"})' | sed 's/^/file : /'

section "worker apres"
W=$(kubectl -n colis get pods -l app.kubernetes.io/name=worker --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
kubectl -n colis get pod $W -o json | jq -c '.status.containerStatuses[0] | {restartCount, dernier: .lastState.terminated | {reason, exitCode}}'

section "loki"
L() { curl -s --get localhost:3101/loki/api/v1/$1 "${@:2}"; }
echo "# phase 1 (OOM) : démarrages et colis traités par pod, de $DEBUT à la première correction"
L query --data-urlencode "query=sum by (k8s_pod_name) (count_over_time({service_name=\"worker\", k8s_namespace_name=\"colis\"} |= \"prêt\" [$((F1 - $(date -d $DEBUT +%s)))s]))" --data-urlencode "time=$F1" \
  | jq -r '.data.result[] | "\(.metric.k8s_pod_name)\tdémarrages=\(.value[1])"' | sort
L query --data-urlencode "query=sum(count_over_time({service_name=\"worker\", k8s_namespace_name=\"colis\"} |= \"livraison estimée\" [$((F1 - $(date -d $DEBUT +%s)))s]))" --data-urlencode "time=$F1" \
  | jq -r '.data.result[0].value[1] // 0' | sed 's/^/colis estimés pendant la phase 1 : /'
L query --data-urlencode "query=sum(count_over_time({service_name=\"worker\", k8s_namespace_name=\"colis\"} |~ \"(?i)(error|killed|memory)\" [$((F1 - $(date -d $DEBUT +%s)))s]))" --data-urlencode "time=$F1" \
  | jq -r '.data.result[0].value[1] // 0' | sed 's/^/lignes contenant error, killed ou memory pendant la phase 1 : /'
echo "# phase 2 : les dernières lignes d'un worker"
W=$(kubectl -n colis get pods -l app.kubernetes.io/name=worker -o jsonpath='{.items[0].metadata.name}')
L query_range --data-urlencode "query={k8s_pod_name=\"$W\"}" --data-urlencode limit=40 --data-urlencode "start=${F1}000000000" \
  | jq -r '.data.result[].values[] | "\(.[0]) \(.[1])"' | sort | tail -4 | cut -d' ' -f2- | cut -c1-160
L query --data-urlencode 'query=sum(count_over_time({service_name="worker", k8s_namespace_name="colis"} |= "ConnectionTimeout" [5m]))' \
  | jq -r '.data.result[0].value[1] // 0' | sed 's/^/lignes ConnectionTimeout sur 5 min : /'

section "reseau"
W=$(kubectl -n colis get pods -l app.kubernetes.io/name=worker -o jsonpath='{.items[0].metadata.name}')
kubectl -n colis debug $W -c reseau --profile=restricted --image=host.minikube.internal:5001/colis/api:2.2.1 -- python -c '
import socket
for hote, port in [("postgres", 5432), ("redis", 6379)]:
    try:
        socket.create_connection((hote, port), 3).close(); print(hote, port, "ouvert")
    except OSError as e:
        print(hote, port, "fermé :", e)' 2>&1 | grep -v -E '^(Defaulting|Targeting)'
for i in $(seq 1 20); do [ "$(kubectl -n colis get pod $W -o jsonpath='{.status.ephemeralContainerStatuses[?(@.name=="reseau")].state.terminated.reason}')" ] && break; sleep 2; done
kubectl -n colis logs $W -c reseau

section "second correctif"
heure "politique postgres : api, api-canari, worker, purge"
kubectl -n colis patch networkpolicy postgres --type=json -p '[
  {"op": "replace", "path": "/spec/ingress/0/from",
   "value": [{"podSelector": {"matchExpressions": [{"key": "app.kubernetes.io/name", "operator": "In",
              "values": ["api", "api-canari", "worker", "purge"]}]}}]}]'
for i in $(seq 1 60); do [ "$(kubectl -n colis exec deploy/redis -c redis -- redis-cli llen colis:a-estimer)" = 0 ] && break; sleep 5; done
heure "file vide"
kubectl -n colis get pods -l app.kubernetes.io/name=worker

# on attend la fin de la page
for i in $(seq 1 40); do pager | grep -q 'RESOLVED.*ColisFileBloquee' && break; sleep 10; done
heure "page résolue"

section "page fin"
pager

section "purge"
kubectl -n colis create job defi7-essai --from=cronjob/purge
kubectl -n colis wait --for=condition=Complete job/defi7-essai --timeout=90s
kubectl -n colis logs job/defi7-essai | tail -1
kubectl -n colis delete job defi7-essai

# encore un peu de trafic normal, puis arrêt de la charge
sleep 120
pkill -P $CH; kill $CH 2>/dev/null; wait $CH 2>/dev/null; CH=
FIN=$(date -u +%Y-%m-%dT%H:%M:%SZ)
heure "charge arrêtée"
# les derniers colis créés doivent encore passer par le worker, et leurs lignes arriver dans Loki
for i in $(seq 1 30); do [ "$(kubectl -n colis exec deploy/redis -c redis -- redis-cli llen colis:a-estimer)" = 0 ] && break; sleep 2; done
sleep 30

section "impact"
python3 $KIT/corrige/impact.py --fin $FIN
D=$(( ($(date -d $FIN +%s) - $(date -d $DEBUT +%s)) / 60 + 1 ))
echo "fenêtre : ${D} min"
prom "max_over_time(max(colis_file_longueur{namespace=\"colis\"})[${D}m:15s])" | sed 's/^/file au plus haut : /'
prom "sum(increase(colis_http_requetes_total{namespace=\"colis\"}[${D}m]))" | sed 's/^/requêtes : /'
prom "sum by (code) (increase(colis_http_requetes_total{namespace=\"colis\"}[${D}m]))" | sed 's/^/  /'
prom "max_over_time(colis:latence:p95_5m[${D}m])" | sed 's/^/p95 au plus haut : /'
prom "sum(increase(kube_pod_container_status_restarts_total{namespace=\"colis\", container=\"worker\"}[${D}m]))" | sed 's/^/redémarrages du worker : /'
prom "sum by (reason) (max_over_time(kube_pod_container_status_last_terminated_reason{namespace=\"colis\", container=\"worker\"}[${D}m]))" | sed 's/^/arrêts du worker : /'
prom "max(max_over_time(container_memory_working_set_bytes{namespace=\"colis\", container=\"worker\"}[${D}m]))" | sed 's/^/pic mémoire du worker : /'

section "evenements"
kubectl -n colis get events -o json | jq -r --arg d $DEBUT '.items[] | {t: (.eventTime // .firstTimestamp), k: .involvedObject.kind, n: .involvedObject.name, r: .reason, c: (.count // .series.count // 1), m: .message}
  | select(.t >= $d and (.k == "Deployment" or .k == "ScaledObject" or .k == "HorizontalPodAutoscaler")) | "\(.t[11:19])  \(.k)/\(.n)  \(.r)  \(.m[0:90])"' | sort | uniq
echo "# premiers événements des Pods du worker"
kubectl -n colis get events -o json | jq -r --arg d $DEBUT '[.items[] | select(.involvedObject.kind == "Pod" and (.involvedObject.name | startswith("worker")) and ((.eventTime // .firstTimestamp) >= $d))]
  | group_by(.reason) | .[] | "\(map(.eventTime // .firstTimestamp) | min | .[11:19])  \(.[0].reason)  \(map(.count // 1) | add) fois"' | sort

echo; echo "### fin"
