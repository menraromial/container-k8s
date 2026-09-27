#!/usr/bin/env bash
# Corrigé du défi V : la chronologie complète d'un kubectl apply, lue dans etcd au fil de l'eau.
# Usage : ./chronologie.sh    (profil minikube principal ; recrée le namespace defi5)
export PATH=~/.local/opt/cours-k8s/bin:$PATH LC_ALL=C TZ=UTC
cd "$(dirname "$0")"
C=/var/lib/minikube/certs/etcd
kubectl delete namespace defi5 --ignore-not-found --wait=true >/dev/null
kubectl create namespace defi5 >/dev/null
# 1. un watch sur tout /registry, horodaté à la réception, avant la moindre écriture
kubectl -n kube-system exec etcd-minikube -- etcdctl --cacert=$C/ca.crt --cert=$C/server.crt --key=$C/server.key \
  watch /registry/ --prefix -w json 2>/dev/null \
  | while IFS= read -r l; do printf '%s %s\n' "$EPOCHREALTIME" "$l"; done > watch.txt &
W=$!; sleep 2
# 2. le kubectl apply, en montrant ses requêtes HTTP
t=$EPOCHREALTIME; printf '# kubectl apply lancé à %(%H:%M:%S)T.%s UTC\n' ${t%.*} ${t#*.}
kubectl apply -f ../temoin.yaml -v=6 2>&1 | grep -oE 'verb="(POST|PATCH|PUT)" url="[^"]*" status="[^"]*"'
kubectl -n defi5 rollout status deploy/temoin >/dev/null; sleep 3
kill $W 2>/dev/null; pkill -P $W 2>/dev/null
# 3. les écritures dans etcd qui concernent defi5, dans l'ordre des révisions
echo "# écritures dans etcd (révision, heure de réception UTC, écart depuis la première, opération, clé)"
python3 trier.py watch.txt defi5
# 4. et hors d'etcd, sur le nœud : les horodatages du runtime, à la nanoseconde
P=$(kubectl -n defi5 get pods -o name | head -1 | cut -d/ -f2)
S=$(minikube ssh -- "sudo crictl pods --name $P --state ready -q" 2>/dev/null | tr -d '\r')
CT=$(minikube ssh -- "sudo crictl ps --pod $S -q" 2>/dev/null | tr -d '\r' | head -1)
echo "# sur le nœud, pour $P (UTC)"
echo "bac à sable créé      : $(minikube ssh -- "sudo crictl inspectp $S" 2>/dev/null | tr -d '\r' | jq -r .status.createdAt)"
minikube ssh -- "sudo crictl inspect $CT" 2>/dev/null | tr -d '\r' | jq -r '"conteneur créé        : \(.status.createdAt)\nconteneur démarré     : \(.status.startedAt)\nprocessus             : PID \(.info.pid)"'
