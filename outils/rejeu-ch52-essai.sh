#!/usr/bin/env bash
# Chapitre 52 : Velero sur un namespace d'essai (restricted + politique d'images), avant de toucher à Colis.
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/sauvegarde
section() { echo; echo "### $*"; }
O=$RACINE/outils/out/ch52r; mkdir -p $O && cd $O
for b in essai; do velero backup delete $b --confirm >/dev/null 2>&1; done
for r in $(velero restore get -o json 2>/dev/null | jq -r '.items[]?.metadata.name' | grep '^essai'); do velero restore delete $r --confirm >/dev/null 2>&1; done
kubectl delete ns ch52-essai --ignore-not-found --wait=true >/dev/null 2>&1
kubectl -n velero delete configmap fs-restore-action-config --ignore-not-found >/dev/null 2>&1
sleep 10

section "essai"
kubectl apply -f $KIT/essai.yaml
kubectl -n ch52-essai rollout status deploy/carnet --timeout=120s
kubectl -n ch52-essai exec deploy/carnet -- cat /donnees/carnet.txt

section "sauvegarde essai"
velero backup create essai --include-namespaces ch52-essai --wait 2>&1 | tail -2
velero backup describe essai --details 2>&1 | sed -n '/^Phase/p;/^Backup Volumes/,/^HooksAttempted/p' | sed '/^$/d' | head -14

section "restauration refusee"
kubectl delete ns ch52-essai
velero restore create essai-1 --from-backup essai --wait 2>&1 | tail -2
velero restore describe essai-1 2>&1 | sed -n '/^Phase/p;/^Warnings/,/^Backup:/p' | sed '/^$/d' | cut -c1-260 | head -20
kubectl -n ch52-essai get deploy,rs,pods,pvc
kubectl -n ch52-essai events --types=Warning 2>&1 | tail -3 | cut -c1-300
echo; echo "### fin"
