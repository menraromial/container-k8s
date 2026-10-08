#!/usr/bin/env bash
# Rejeu du chapitre 50 (métriques) sur le profil minikube principal, kube-prometheus-stack déjà installé
# (release supervision, kits/metriques/valeurs-supervision.yaml). Journal sur la sortie standard.
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/metriques
CA=$RACINE/outils/out/ch28/m/ca.crt
section() { echo; echo "### $*"; }
mkdir -p $RACINE/outils/out/ch50r && cd $RACINE/outils/out/ch50r
P=http://localhost:9095
q() {  # une requête PromQL instantanée, résultat en lignes « étiquettes valeur »
  curl -s "$P/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result[] |
    "\(.metric | del(.__name__, .endpoint, .instance, .job, .service, .container, .prometheus) | to_entries | map("\(.key)=\(.value)") | join(" ")) \(.value[1] | tonumber | (. * 1000 | round) / 1000)"'
}
ecoute() { ss -ltn | awk '{print $4}' | grep -q ":$1$"; }
ouvrir() {  # $1 port local, $2 service, $3 port distant
  ecoute $1 || { kubectl -n supervision port-forward svc/$2 $1:$3 >/dev/null 2>&1 & sleep 3; }
}
cibles_colis() {
  curl -s $P/api/v1/targets | jq -r '.data.activeTargets[] | select(.labels.namespace == "colis") |
    "\(.scrapePool) \(.labels.pod) \(.health) \(.lastError)"' | sed 's#^serviceMonitor/##; s#^podMonitor/##'
}

# --- remise à zéro (Colis reste en 2.2 si le rejeu a déjà tourné)
kubectl -n colis delete -f $KIT/moniteurs.yaml -f $KIT/politique-supervision.yaml -f $KIT/regles.yaml \
  -f $KIT/alertmanager-colis.yaml -f $KIT/tableau-colis.yaml --ignore-not-found >/dev/null 2>&1
kubectl delete -f $KIT/pager.yaml --ignore-not-found >/dev/null 2>&1
kubectl -n colis annotate scaledobject worker autoscaling.keda.sh/paused- >/dev/null 2>&1
ouvrir 9095 supervision-kube-prometheu-prometheus 9090
ouvrir 9094 supervision-kube-prometheu-alertmanager 9093
ouvrir 3050 supervision-grafana 80
sleep 20

section "etat"
helm -n supervision list
kubectl -n supervision get pods
docker stats --no-stream minikube --format '{{.MemUsage}}'
kubectl get crd -o name | grep monitoring.coreos.com
kubectl get servicemonitors,podmonitors -A

section "cibles"
curl -s $P/api/v1/targets | jq -r '.data.activeTargets[] | [.scrapePool, .health] | @tsv' \
  | sed 's#serviceMonitor/supervision/supervision-kube-prometheu-##; s#serviceMonitor/supervision/##' | sort | uniq -c

section "passage en 2.2"
bash $KIT/passer-en-2.2.sh
kubectl -n colis get deploy -o custom-columns=NOM:.metadata.name,IMAGE:.spec.template.spec.containers[0].image

section "metriques brutes"
python3 $KIT/charge.py --duree 4 --debit 5 --ca $CA
kubectl -n colis exec deploy/api -- python -c "import urllib.request as u; print(u.urlopen('http://localhost:8000/metrics/').read().decode())" > metriques.txt
grep -E '^# (HELP|TYPE) colis_http_requetes_total|^colis_http_requetes_total' metriques.txt
grep -E '^colis_http_duree_secondes_(bucket|sum|count)\{methode="GET",route="/colis"\}|^colis_http_duree_secondes_bucket\{le="[^"]*",methode="GET",route="/colis"\}' metriques.txt | head -14
grep -E '^colis_(enregistres_total|file_longueur) ' metriques.txt
echo "$(grep -c '^[a-z]' metriques.txt) séries dans la réponse, $(grep -c '^colis_' metriques.txt) pour Colis"
kubectl -n colis logs deploy/api --tail=2

section "moniteurs"
kubectl apply -f $KIT/moniteurs.yaml
for i in $(seq 1 30); do   # la configuration met une à deux minutes à arriver, puis la collecte échoue en 10 s
  sleep 10
  cibles_colis | grep -q -v ' unknown' && [ -n "$(cibles_colis)" ] && ! cibles_colis | grep -q ' unknown' && break
done
echo "après $((i * 10)) s"
cibles_colis

section "politique"
kubectl apply -f $KIT/politique-supervision.yaml
for i in $(seq 1 12); do sleep 10; cibles_colis | grep -q ' down' || break; done
echo "après $((i * 10)) s"
cibles_colis

section "trafic"
python3 $KIT/charge.py --duree 330 --debit 8 --ca $CA > charge.txt &
CHARGE=$!
kubectl apply -f $KIT/regles.yaml -f $KIT/tableau-colis.yaml
sleep 300

section "requetes"
echo '$ up{namespace="colis"}'; q 'up{namespace="colis"}'
echo '$ taux par route et code'; q 'sum by (route, code) (rate(colis_http_requetes_total{namespace="colis"}[5m]))'
echo '$ part des 404'; q 'sum(rate(colis_http_requetes_total{namespace="colis", code="404"}[5m])) / sum(rate(colis_http_requetes_total{namespace="colis"}[5m]))'
echo '$ p95 par route'; q 'histogram_quantile(0.95, sum by (le, route) (rate(colis_http_duree_secondes_bucket{namespace="colis"}[5m])))'
echo '$ p50 par route'; q 'histogram_quantile(0.5, sum by (le, route) (rate(colis_http_duree_secondes_bucket{namespace="colis"}[5m])))'
echo '$ regle enregistree'; q 'colis:latence:p95_5m'
echo '$ memoire'; q 'sum by (pod) (container_memory_working_set_bytes{namespace="colis", container!=""}) / 2^20'
echo '$ requests memoire'; q 'sum by (pod) (kube_pod_container_resource_requests{namespace="colis", resource="memory"}) / 2^20'
echo '$ redemarrages'; q 'sum by (pod) (increase(kube_pod_container_status_restarts_total{namespace="colis"}[1h])) > 0'
echo '$ estimes'; q 'sum by (par) (increase(colis_estimes_total{namespace="colis"}[5m]))'
echo '$ workers'; q 'sum by (deployment) (kube_deployment_status_replicas{namespace="colis", deployment="worker"})'
echo '$ series'; q 'count({__name__=~".+"})'
echo '$ series colis'; q 'count({__name__=~"colis_.+"})'
wait $CHARGE; cat charge.txt

section "grafana"
MDP=$(kubectl -n supervision get secret supervision-grafana -o jsonpath='{.data.admin-password}' | base64 -d)
echo "mot de passe : ${#MDP} caractères"
curl -s -u admin:$MDP 'http://localhost:3050/api/search?query=Colis' | jq -c '.[] | {title, uid, url}'
curl -s -u admin:$MDP 'http://localhost:3050/api/search?type=dash-db' | jq length
curl -s -u admin:$MDP 'http://localhost:3050/api/datasources' | jq -c '.[] | {name, uid, url}'

section "alertes : regles"
kubectl -n colis get prometheusrules
sleep 5
curl -s $P/api/v1/rules | jq -r '.data.groups[] | select(.name | startswith("colis")) | .rules[] | "\(.type) \(.name) \(.health) \(.state // "-")"'

section "alertes : routage"
kubectl apply -f $KIT/pager.yaml -f $KIT/alertmanager-colis.yaml
kubectl -n supervision rollout status deploy/pager --timeout=90s
sleep 40
kubectl -n supervision get secret alertmanager-supervision-kube-prometheu-alertmanager-generated -o jsonpath='{.data.alertmanager\.yaml\.gz}' \
  | base64 -d | gunzip | sed -n '/^route:/,/^templates/p' | head -40

section "alertes : declenchement"
kubectl -n colis annotate scaledobject worker autoscaling.keda.sh/paused=true
kubectl -n colis get scaledobject worker
python3 - "$CA" <<'EOF'
import json, socket, ssl, sys, urllib.request
r = socket.getaddrinfo
socket.getaddrinfo = lambda h, *a, **k: r("192.168.49.102" if h == "colis.local" else h, *a, **k)
ctx = ssl.create_default_context(cafile=sys.argv[1])
for i in range(40):
    corps = json.dumps({"destinataire": f"Lot {i}", "depart": "Paris", "arrivee": "Lyon", "poids_kg": 1.0}).encode()
    urllib.request.urlopen(urllib.request.Request("https://colis.local/api/colis", data=corps,
                           headers={"Content-Type": "application/json"}), context=ctx)
print("40 colis enregistrés")
EOF
date +%T
for i in $(seq 1 12); do
  sleep 20
  etat=$(curl -s $P/api/v1/alerts | jq -r '.data.alerts[] | select(.labels.alertname == "ColisFileBloquee") | "\(.state) depuis \(.activeAt) valeur \(.value)"')
  echo "$(date +%T) ${etat:-inactive}"
  case $etat in firing*) break ;; esac
done
sleep 45
kubectl -n supervision logs deploy/pager
curl -s localhost:9094/api/v2/alerts | jq -c '.[] | {alerte: .labels.alertname, namespace: .labels.namespace, etat: .status.state, recepteurs: [.receivers[].name]}'

section "alertes : retour a la normale"
kubectl -n colis annotate scaledobject worker autoscaling.keda.sh/paused-
date +%T
for i in $(seq 1 15); do
  sleep 20
  echo "$(date +%T) workers=$(kubectl -n colis get deploy worker -o jsonpath='{.status.replicas}') file=$(q 'max(colis_file_longueur{namespace="colis"})' | awk '{print $NF}')"
  kubectl -n supervision logs deploy/pager | grep -q RESOLVED && break
done
kubectl -n supervision logs deploy/pager

section "memoire"
kubectl top pod -n supervision --no-headers
docker stats --no-stream minikube --format '{{.MemUsage}}'
echo; echo "### fin"
