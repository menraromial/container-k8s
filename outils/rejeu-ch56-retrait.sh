#!/usr/bin/env bash
# Chapitre 56, fin : retirer l'ancienne base de Colis, une fois la migration vérifiée.
# Une copie pg_dump de l'ancienne base est gardée dans outils/out/ch56r/securite.
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
section() { echo; echo "### $*"; }
section "retrait"
kubectl -n colis delete networkpolicy import-depuis-postgres import-vers-postgres postgres
kubectl -n colis delete statefulset postgres
kubectl -n colis delete service postgres
kubectl -n colis delete pvc donnees-postgres-0
kubectl -n colis delete secret colis-db
# les règles de sortie vers l'ancien postgres, dans les politiques de l'application
for p in api worker purge; do
  kubectl -n colis get networkpolicy $p -o json \
    | jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.generation, .metadata.managedFields, .metadata.annotations)
          | .spec.egress |= map(select(([.to[]?.podSelector.matchLabels["app.kubernetes.io/name"]] | index("postgres")) | not))' \
    | kubectl replace -f -
done
kubectl -n colis get networkpolicy
section "apres"
sleep 20
kubectl -n colis get pods
kubectl get pv -o json | jq -r '.items[] | select(.status.phase == "Released") | .metadata.name' | while read -r pv; do kubectl delete pv "$pv"; done
curl -sk --max-time 5 -o /dev/null -w 'colis.local : %{http_code}\n' --resolve colis.local:443:192.168.49.102 https://colis.local/api/colis
docker stats --no-stream minikube --format 'mémoire du nœud : {{.MemUsage}}'
section "purge apres"
kubectl -n colis get networkpolicy purge -o json | jq -c '.spec'
kubectl -n colis create job essai-purge2 --from=cronjob/purge
kubectl -n colis wait --for=condition=Complete job/essai-purge2 --timeout=90s
kubectl -n colis logs job/essai-purge2 | tail -1 | jq -r .message
kubectl -n colis delete job essai-purge2
echo; echo "### fin"
