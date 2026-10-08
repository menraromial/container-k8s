#!/usr/bin/env bash
# Chapitre 52 : les essais de Velero sur un namespace jetable (hostPath, CSI, image de restauration).
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
export DOCKER_CONFIG=~/.local/opt/cours-k8s/docker-config
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/sauvegarde
CA=$RACINE/outils/out/ch28/m/ca.crt
section() { echo; echo "### $*"; }
O=$RACINE/outils/out/ch52r; mkdir -p $O && cd $O
kubectl -n velero port-forward svc/rustfs 9010:9000 >/dev/null 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null' EXIT
sleep 3
compter() { kubectl -n colis exec postgres-0 -- psql -U colis -d colis -Atc "SELECT statut, count(*) FROM colis GROUP BY statut ORDER BY statut" 2>&1; }
sonder() {
  printf 'passerelle %s   ' "$(curl -sk --max-time 5 -o /dev/null -w '%{http_code}' --resolve colis.local:443:192.168.49.102 https://colis.local/api/colis)"
  printf 'service web %s\n' "$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' http://192.168.49.100/api/colis)"
}
pvb() { kubectl -n velero get podvolumebackups -l velero.io/backup-name=$1 -o custom-columns=POD:.spec.pod.name,VOLUME:.spec.volume,ETAT:.status.phase,OCTETS:.status.progress.bytesDone 2>&1; }

# --- remise à zéro des essais (la suppression d'une sauvegarde est asynchrone : on attend)
for r in $(velero restore get -o json 2>/dev/null | jq -r '.items[]?.metadata.name' | grep '^essai'); do velero restore delete $r --confirm >/dev/null 2>&1; done
for b in essai essai-csi; do velero backup delete $b --confirm >/dev/null 2>&1; done
for i in $(seq 1 60); do velero backup get -o json 2>/dev/null | jq -e '[.items[]?.metadata.name | select(startswith("essai"))] | length == 0' >/dev/null && break; sleep 5; done
kubectl -n velero delete configmap fs-restore-action-config --ignore-not-found >/dev/null 2>&1
kubectl delete ns ch52-essai --ignore-not-found --wait=true >/dev/null 2>&1
sleep 10

section "installation"
helm -n velero list
kubectl -n velero get pods
velero backup-location get

section "essai hostpath"
kubectl apply -f $KIT/essai.yaml >/dev/null
kubectl -n ch52-essai rollout status deploy/carnet --timeout=120s >/dev/null
kubectl -n ch52-essai exec deploy/carnet -- cat /donnees/carnet.txt
velero backup create essai --include-namespaces ch52-essai --wait 2>&1 | tail -1
velero backup logs essai 2>/dev/null | grep 'level=warning' | sed 's/^time="[^"]*" //' | cut -c1-200
pvb essai
kubectl delete ns ch52-essai --wait=true >/dev/null
velero restore create essai-1 --from-backup essai --wait 2>&1 | tail -1
kubectl -n ch52-essai rollout status deploy/carnet --timeout=120s >/dev/null
kubectl -n ch52-essai exec deploy/carnet -- cat /donnees/carnet.txt

section "essai csi"
kubectl delete ns ch52-essai --wait=true >/dev/null
kubectl apply -f $KIT/essai-csi.yaml >/dev/null
kubectl -n ch52-essai rollout status deploy/carnet --timeout=120s >/dev/null
kubectl -n ch52-essai get pvc carnet -o custom-columns=PVC:.metadata.name,CLASSE:.spec.storageClassName
kubectl -n ch52-essai exec deploy/carnet -- cat /donnees/carnet.txt
velero backup create essai-csi --include-namespaces ch52-essai --wait 2>&1 | tail -1
pvb essai-csi
kubectl delete ns ch52-essai --wait=true >/dev/null
velero restore create essai-csi-1 --from-backup essai-csi --wait 2>&1 | tail -1
velero restore describe essai-csi-1 2>&1 | sed -n '/^Errors:/,/^Backup:/p' | sed '/^$/d' | cut -c1-330
sleep 5
kubectl -n ch52-essai get pods
kubectl -n ch52-essai exec deploy/carnet -- cat /donnees/carnet.txt 2>&1 | tail -1

section "miroir"
docker buildx imagetools create --builder cours --tag localhost:5001/velero/velero:v1.18.2 docker.io/velero/velero:v1.18.2 2>&1 | grep -E 'DONE|ERROR' | tail -1
kubectl apply -f $KIT/aide-restauration.yaml
kubectl delete ns ch52-essai --wait=true >/dev/null
velero restore create essai-csi-2 --from-backup essai-csi --wait 2>&1 | tail -1
kubectl -n ch52-essai rollout status deploy/carnet --timeout=120s >/dev/null
kubectl -n ch52-essai exec deploy/carnet -c carnet -- cat /donnees/carnet.txt
kubectl -n ch52-essai get pod -o json | jq -c '.items[0].spec.initContainers | map({name, image, securityContext})'
kubectl -n velero get podvolumerestores -l velero.io/restore-name=essai-csi-2 -o custom-columns=POD:.spec.pod.name,VOLUME:.spec.volume,ETAT:.status.phase,OCTETS:.status.progress.bytesDone

echo; echo "### fin"
