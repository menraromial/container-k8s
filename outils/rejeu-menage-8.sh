#!/usr/bin/env bash
# Le ménage du début de la partie VIII, avec les mesures avant et après. Sorties : outils/out/menage8.
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
O=$RACINE/outils/out/menage8; mkdir -p $O && cd $O
section() { echo; echo "### $*"; }
par_ns() { kubectl top pods -A --no-headers | awk '{m=$4; sub("Mi","",m); s[$1]+=m} END {for (n in s) printf "%6d Mi  %s\n", s[n], n}' | sort -rn; }
section "avant"
docker stats --no-stream minikube --format '{{.MemUsage}}'
par_ns
section "menage"
bash $RACINE/kits/menage-8/faire-de-la-place.sh 2>&1
kubectl -n colis rollout status deployment/api --timeout=180s
kubectl -n colis rollout status deployment/worker --timeout=180s 2>&1 | tail -1
section "apres"
sleep 90
docker stats --no-stream minikube --format '{{.MemUsage}}'
par_ns
kubectl -n supervision get pods
helm -n supervision list
curl -sk --max-time 5 -o /dev/null -w 'colis.local : %{http_code}\n' --resolve colis.local:443:192.168.49.102 https://colis.local/api/colis
echo; echo "### fin"
