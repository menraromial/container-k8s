#!/usr/bin/env bash
# Exercices du chapitre 52, après rejeu-ch52-velero.sh.
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/sauvegarde
section() { echo; echo "### $*"; }
O=$RACINE/outils/out/ch52r; mkdir -p $O && cd $O
kubectl -n velero port-forward svc/rustfs 9010:9000 >/dev/null 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null' EXIT
sleep 3
velero restore delete copie --confirm >/dev/null 2>&1
kubectl delete ns ch52-copie --ignore-not-found --wait=true >/dev/null 2>&1

section "ex2 autre namespace"
velero restore create copie --from-backup colis-1 --include-resources configmaps,secrets \
  --namespace-mappings colis:ch52-copie --wait 2>&1 | tail -1
kubectl -n ch52-copie get configmaps,secrets
diff <(kubectl -n colis get secret colis-db -o jsonpath='{.data}') <(kubectl -n ch52-copie get secret colis-db -o jsonpath='{.data}') && echo "colis-db identique"

section "ex3 fraicheur avant"
python3 $KIT/corrige/fraicheur.py; echo "code de sortie : $?"
section "ex3 fraicheur apres"
velero backup create --from-schedule colis-quotidien --wait 2>&1 | tail -1
python3 $KIT/corrige/fraicheur.py; echo "code de sortie : $?"

section "ex4 sauvegarde plus propre"
velero backup create colis-2 --include-namespaces colis --exclude-resources events,events.events.k8s.io \
  --selector '!scaledobject.keda.sh/name' --wait 2>&1 | tail -1
for b in colis-1 colis-2; do
  kubectl -n velero get backup $b -o json | jq -r '"\(.metadata.name) : \(.status.progress.itemsBackedUp) objets, \(.status.warnings // 0) avertissements"'
done
velero backup download colis-2 -o colis-2.tar.gz >/dev/null 2>&1
echo "HPA dans colis-2 : $(tar -tzf colis-2.tar.gz | grep 'horizontalpodautoscalers.autoscaling/namespaces' | sed 's#.*/##' | tr '\n' ' ')"
echo "événements dans colis-2 : $(tar -tzf colis-2.tar.gz | grep -c '^resources/events')"
kubectl delete ns ch52-copie --wait=false >/dev/null
echo; echo "### fin"
