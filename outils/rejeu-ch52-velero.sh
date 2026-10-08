#!/usr/bin/env bash
# Chapitre 52, seconde partie : Velero (RustFS et Velero déjà installés, crochets posés sur PostgreSQL).
# ATTENTION : supprime le namespace colis puis le restaure.
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

# --- remise à zéro de l'essai
for r in $(velero restore get -o json 2>/dev/null | jq -r '.items[]?.metadata.name'); do velero restore delete $r --confirm >/dev/null 2>&1; done
for b in $(velero backup get -o json 2>/dev/null | jq -r '.items[]?.metadata.name'); do velero backup delete $b --confirm >/dev/null 2>&1; done
velero schedule delete colis-quotidien --confirm >/dev/null 2>&1
kubectl -n velero delete configmap fs-restore-action-config --ignore-not-found >/dev/null 2>&1
kubectl delete ns ch52-essai --ignore-not-found --wait=true >/dev/null 2>&1
sleep 20

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

section "colis avant"
compter
sonder
kubectl -n colis get pods

section "colis sauvegarde"
time velero backup create colis-1 --include-namespaces colis --wait 2>&1 | tail -1
velero backup describe colis-1 2>&1 | sed -n '/^Phase/p;/^Hooks Attempted/,/^Hooks Failed/p;/^Resource List/q' | sed '/^$/d'
kubectl -n velero get backup colis-1 -o json | jq -c '{phase: .status.phase, objets: .status.progress, avertissements: .status.warnings, erreurs: .status.errors, crochets: .status.hookStatus}'
pvb colis-1

section "colis contenu"
velero backup download colis-1 -o colis-1.tar.gz 2>&1 | tail -1
tar -tzf colis-1.tar.gz | wc -l
tar -tzf colis-1.tar.gz | sed -n 's#^resources/\([^/]*\)/.*#\1#p' | sort | uniq -c | sort -rn | head -12
tar -xzOf colis-1.tar.gz resources/secrets/namespaces/colis/colis-db.json | jq -c '{nom: .metadata.name, cles: (.data | keys)}'
MDP=$(kubectl -n colis get secret colis-db -o jsonpath='{.data.POSTGRES_PASSWORD}')
echo "mot de passe de la base dans l'archive, en base64 : $(tar -xzOf colis-1.tar.gz resources/secrets/namespaces/colis/colis-db.json | grep -c "$MDP")"
curl -s --aws-sigv4 "aws:amz:us-east-1:s3" --user velero:sauvegardes-du-cours-52 "http://localhost:9010/velero?list-type=2&prefix=backups/colis-1/" | grep -o '<Key>[^<]*</Key><LastModified>[^<]*</LastModified><ETag>[^<]*</ETag><Size>[0-9]*' | sed 's#<Key>##; s#</Key><LastModified>[^<]*</LastModified><ETag>[^<]*</ETag><Size># #'

section "colis catastrophe"
date +%T
kubectl delete namespace colis
date +%T
sonder

section "colis restauration"
time velero restore create colis-1 --from-backup colis-1 --wait 2>&1 | tail -1
velero restore describe colis-1 2>&1 | sed -n '/^Phase/p;/^Warnings:/,/^Backup:/p;/^Restore PVs/p;/^Hooks/,$p' | sed '/^$/d' | cut -c1-300 | head -30
kubectl -n colis get pods
kubectl -n velero get podvolumerestores -l velero.io/restore-name=colis-1 -o custom-columns=POD:.spec.pod.name,VOLUME:.spec.volume,ETAT:.status.phase,OCTETS:.status.progress.bytesDone

section "colis apres"
sleep 20
compter
sonder
kubectl -n colis get svc web -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'
kubectl get ns colis --show-labels | tr ',' '\n' | grep -E 'pod-security.kubernetes.io/enforce=|politique-images|passerelle'
kubectl -n colis get networkpolicy,scaledobject,hpa,servicemonitor,prometheusrule --no-headers | awk '{print $1}'
kubectl get pv -o custom-columns=PV:.metadata.name,RECLAMATION:.spec.claimRef.name,ETAT:.status.phase,POLITIQUE:.spec.persistentVolumeReclaimPolicy | grep -E 'donnees-postgres|ETAT'

section "planification"
velero schedule create colis-quotidien --schedule "0 3 * * *" --include-namespaces colis --ttl 168h0m0s
velero schedule get
velero backup get
echo; echo "### fin"
