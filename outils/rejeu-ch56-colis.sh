#!/usr/bin/env bash
# Chapitre 56, seconde partie : migrer la base de Colis (namespace colis) vers CloudNativePG.
# Suppose rejeu-ch56-demo.sh passé (opérateur, greffon Barman Cloud et RustFS installés).
# L'ancien StatefulSet postgres n'est PAS supprimé ici : voir rejeu-ch56-retrait.sh.
# En cas d'échec : ch56-annuler-migration.sh remet Colis sur l'ancienne base.
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/cnpg/colis
O=$RACINE/outils/out/ch56r/colis; rm -rf $O; mkdir -p $O && cd $O
section() { echo; echo "### $*"; }
web() { curl -sk --max-time 5 -o /dev/null -w '%{http_code}' --resolve colis.local:443:192.168.49.102 "https://colis.local/api$1"; }
ancien() { kubectl -n colis exec postgres-0 -c postgres -- psql -U colis -d colis -qtAc "$1"; }
nouveau() { kubectl -n colis exec $(kubectl -n colis get cluster colis-pg -o jsonpath='{.status.currentPrimary}') -c postgres -- psql -U postgres -d colis -qtAc "$1"; }
COMPTE="SELECT count(*) || ' colis, ' || count(*) FILTER (WHERE statut = 'estimé') || ' estimés, dernier n° ' || max(id) FROM colis"

section "avant"
kubectl -n colis get pods
echo "ancienne base : $(ancien "$COMPTE")"
echo "colis.local : $(web /colis)"
kubectl -n politiques get configmap images-autorisees -o jsonpath='{.data.registres}{"\n"}'

section "images"
for img in ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie ghcr.io/cloudnative-pg/cloudnative-pg:1.30.1 ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar:v0.15.1; do
  echo "\$ cosign verify $img ..."
  cosign verify $img --certificate-identity-regexp='^https://github.com/cloudnative-pg/' \
    --certificate-oidc-issuer=https://token.actions.githubusercontent.com 2>&1 | grep -v -E '^\[|^$' | head -3
done
kubectl -n politiques patch configmap images-autorisees --type=merge \
  -p '{"data":{"registres":"host.minikube.internal:5001/,redis:,postgres:,busybox:,ghcr.io/cloudnative-pg/"}}'

section "politiques"
kubectl apply -f $KIT/11-politiques.yaml -f $KIT/12-sauvegarde.yaml

section "maintenance"
debut=$(date +%s)
date -u +"début de la maintenance : %T UTC"
kubectl -n colis annotate scaledobject worker autoscaling.keda.sh/paused-replicas="0" --overwrite
kubectl -n colis patch cronjob purge --type=merge -p '{"spec":{"suspend":true}}'
kubectl -n colis scale deployment api --replicas=0
kubectl -n colis wait --for=delete pod -l app.kubernetes.io/name=api --timeout=120s
kubectl -n colis wait --for=delete pod -l app.kubernetes.io/name=worker --timeout=120s 2>/dev/null
echo "colis.local : $(web /colis)"
echo "ancienne base, figée : $(ancien "$COMPTE")"

section "creation"
d2=$(date +%s)
kubectl apply -f $KIT/13-colis-pg.yaml
prec=""
for i in $(seq 1 200); do
  s=$(kubectl -n colis get cluster colis-pg -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$s" != "$prec" ] && echo "$(date +%T) $s" && prec=$s
  [ "$s" = "Cluster in healthy state" ] && break
  sleep 3
done
echo "durée : $(( $(date +%s) - d2 )) s"
kubectl -n colis get jobs -l cnpg.io/cluster=colis-pg
J=$(kubectl -n colis get pods -l cnpg.io/cluster=colis-pg,cnpg.io/jobRole -o name | head -1)
kubectl -n colis logs $J --all-containers 2>/dev/null | grep -i -E 'pg_dump|pg_restore|import' | jq -r '[.ts // .level, .msg, (.cmd // .args // "" | tostring)] | join(" | ")' 2>/dev/null | cut -c1-200 | head -12
kubectl -n colis get pods -l cnpg.io/cluster=colis-pg -L cnpg.io/instanceRole
kubectl -n colis get events --field-selector involvedObject.kind=Cluster,involvedObject.name=colis-pg -o custom-columns=RAISON:.reason,MESSAGE:.message | head -12
kubectl -n colis get secret colis-pg-app -o json | jq -c '{type, cles: (.data | keys), utilisateur: (.data.username | @base64d)}'

section "verification"
echo "ancienne base : $(ancien "$COMPTE")"
echo "colis-pg      : $(nouveau "$COMPTE")"
nouveau "SELECT tablename, tableowner FROM pg_tables WHERE schemaname = 'public'"
nouveau "SELECT pg_size_pretty(pg_database_size('colis'))"

section "bascule"
bash $KIT/basculer.sh
kubectl -n colis scale deployment api --replicas=2
kubectl -n colis annotate scaledobject worker autoscaling.keda.sh/paused-replicas-
kubectl -n colis patch cronjob purge --type=merge -p '{"spec":{"suspend":false}}'
kubectl -n colis rollout status deployment/api --timeout=180s
for i in $(seq 1 60); do [ "$(web /colis)" = 200 ] && break; sleep 1; done
date -u +"fin de la maintenance : %T UTC"
echo "durée de la maintenance : $(( $(date +%s) - debut )) s"
kubectl -n colis get deployment api -o json | jq -c '.spec.template.spec.containers[0].env'

section "fonctionnement"
id=$(curl -sk --max-time 5 --resolve colis.local:443:192.168.49.102 https://colis.local/api/colis -X POST -H 'Content-Type: application/json' \
  -d '{"destinataire": "CloudNativePG", "poids_kg": 3.2, "depart": "Lyon", "arrivee": "Brest"}' | jq -r .id)
for i in $(seq 1 60); do s=$(curl -sk --max-time 5 --resolve colis.local:443:192.168.49.102 https://colis.local/api/colis/$id | jq -r .statut); [ "$s" = estimé ] && break; sleep 2; done
echo "colis $id : $s"
echo "colis-pg : $(nouveau "$COMPTE")"
echo "ancienne base : $(ancien "$COMPTE")"
kubectl -n colis create job essai-purge --from=cronjob/purge
kubectl -n colis wait --for=condition=Complete job/essai-purge --timeout=90s
kubectl -n colis logs job/essai-purge | tail -1 | jq -r .message
kubectl -n colis delete job essai-purge

section "sauvegarde colis"
cat > sauvegarde.yaml <<'Y'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: apres-migration
  namespace: colis
spec:
  cluster: {name: colis-pg}
  method: plugin
  pluginConfiguration: {name: barman-cloud.cloudnative-pg.io}
Y
kubectl apply -f sauvegarde.yaml
for i in $(seq 1 60); do p=$(kubectl -n colis get backup apres-migration -o jsonpath='{.status.phase}'); [ "$p" = completed ] || [ "$p" = failed ] && break; sleep 3; done
kubectl -n colis get backup
kubectl cnpg status colis-pg -n colis 2>&1 | sed -n '/^Cluster Summary/,/^Current Write LSN/p;/^Continuous Backup/,/^$/p'
docker stats --no-stream minikube --format 'mémoire du nœud : {{.MemUsage}}'
echo; echo "### fin"
