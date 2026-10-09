#!/usr/bin/env bash
# Chapitre 56, première partie : CloudNativePG sur un cluster d'essai (namespace ch56).
# Repart de zéro : retire ch56, le greffon Barman Cloud, l'opérateur et RustFS, puis réinstalle
# et rejoue. Les images sont dans le cache du nœud : les temps de démarrage sont ceux d'un cache chaud.
# Sorties : outils/out/ch56r/rejeu-ch56-demo.log (et annexes).
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/cnpg
O=$RACINE/outils/out/ch56r/demo; rm -rf $O; mkdir -p $O && cd $O
section() { echo; echo "### $*"; }
CNPG=https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v1.30.1/cnpg-1.30.1.yaml
BARMAN=https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v0.15.1/manifest.yaml
phases() { # cluster, nombre max de relevés : affiche chaque changement de phase avec l'heure
  local prec="" s
  for i in $(seq 1 ${2:-120}); do
    s=$(kubectl -n ch56 get cluster $1 -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$s" != "$prec" ] && echo "$(date +%T) $s" && prec=$s
    [ "$s" = "Cluster in healthy state" ] && [ $i -gt 2 ] && break
    sleep 2
  done
}
primaire() { kubectl -n ch56 get cluster essai -o jsonpath='{.status.currentPrimary}'; }
psql_p() { kubectl -n ch56 exec $(primaire) -c postgres -- psql -U postgres -d app -qtAc "$1"; }

# --- remise à zéro
kubectl delete ns ch56 --ignore-not-found --wait=true >/dev/null
kubectl delete -f $BARMAN --ignore-not-found >/dev/null 2>&1
kubectl delete -f $CNPG --ignore-not-found >/dev/null 2>&1
kubectl delete ns stockage --ignore-not-found --wait=true >/dev/null
kubectl get pv -o json | jq -r '.items[] | select(.status.phase == "Released") | .metadata.name' | while read -r pv; do kubectl delete pv "$pv" >/dev/null; done

section "operateur"
kubectl apply --server-side -f $CNPG | sed -n '1p;$p'
kubectl apply --server-side -f $CNPG | grep -c "serverside-applied" | sed 's/^/objets appliqués : /'
kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager --timeout=180s
kubectl get crd -o name | grep cnpg.io | sed 's#customresourcedefinition.apiextensions.k8s.io/##'
kubectl cnpg version

section "greffon et stockage"
kubectl apply -f $BARMAN | grep -E "deployment|objectstores|certificate"
kubectl -n cnpg-system rollout status deployment/barman-cloud --timeout=180s
kubectl create namespace stockage
kubectl apply -f $KIT/rustfs.yaml
kubectl -n stockage rollout status deployment/rustfs --timeout=180s
# RustFS répond quelques secondes après que son Pod est déclaré prêt : on réessaie
for i in $(seq 1 20); do
  kubectl -n stockage port-forward svc/rustfs 9011:9000 >/dev/null 2>&1 & PF=$!
  sleep 3
  code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT --aws-sigv4 "aws:amz:us-east-1:s3" --user cnpg:sauvegardes-du-cours-56 http://localhost:9011/sauvegardes)
  kill $PF 2>/dev/null; wait $PF 2>/dev/null
  [ "$code" = 200 ] && break
  sleep 2
done
echo "PUT /sauvegardes : $code"

section "cluster"
kubectl create namespace ch56
debut=$(date +%s)
kubectl apply -f $KIT/01-cluster.yaml
phases essai 150
echo "durée : $(( $(date +%s) - debut )) s"
kubectl -n ch56 get cluster,pods,svc,pvc,secret

section "anatomie"
kubectl -n ch56 get statefulsets,deployments 2>&1
kubectl -n ch56 get pod essai-1 -o json | jq -c '{proprietaire: [.metadata.ownerReferences[] | "\(.kind)/\(.name)"], initContainers: [.spec.initContainers[] | {name, image}], containers: [.spec.containers[] | {name, image, command}]}'
kubectl -n ch56 get pods -L cnpg.io/instanceRole
kubectl -n ch56 get svc essai-rw essai-ro essai-r -o custom-columns=SERVICE:.metadata.name,SELECTEUR:.spec.selector
kubectl -n ch56 get secret essai-app -o json | jq -r '.data | keys | join(" ")'
kubectl cnpg status essai -n ch56 2>&1 | sed -n '/^Cluster Summary/,/^Current Write LSN/p;/^Streaming Replication/,$p'

section "replication"
psql_p "CREATE TABLE essai_lecture AS SELECT g AS n FROM generate_series(1, 100000) g" >/dev/null
for p in $(kubectl -n ch56 get pods -l cnpg.io/cluster=essai -o name | sort); do
  echo "${p#pod/} ($(kubectl -n ch56 get $p -o jsonpath='{.metadata.labels.cnpg\.io/instanceRole}')) : $(kubectl -n ch56 exec ${p#pod/} -c postgres -- psql -U postgres -d app -qtAc 'SELECT count(*) FROM essai_lecture')"
done
R=$(kubectl -n ch56 get pods -l cnpg.io/instanceRole=replica -o jsonpath='{.items[0].metadata.name}')
kubectl -n ch56 exec $R -c postgres -- psql -U postgres -d app -qtAc 'INSERT INTO essai_lecture VALUES (0)' 2>&1

section "bascule"
kubectl apply -f $KIT/ecrivain.yaml
kubectl -n ch56 wait --for=condition=Ready pod/ecrivain --timeout=60s
sleep 5
P=$(primaire)
echo "primaire : $P"
kubectl -n ch56 delete pod $P --wait=false
for i in $(seq 1 60); do [ "$(primaire)" != "$P" ] && break; sleep 1; done
sleep 20
echo "nouvelle primaire : $(primaire)"
kubectl -n ch56 logs ecrivain | awk '{print $2, $4}' | uniq -c
kubectl -n ch56 logs ecrivain | grep -B1 -A1 échec | sed -n '1p'
kubectl -n ch56 logs ecrivain | grep échec
kubectl -n ch56 logs ecrivain | grep -A1 échec | tail -1
kubectl -n ch56 get pods -L cnpg.io/instanceRole
kubectl -n ch56 get cluster essai -o json | jq -c '.status | {currentPrimary, timelineID, currentPrimaryTimestamp}'

section "bascule programmee"
kubectl -n ch56 delete pod ecrivain --wait=true >/dev/null
kubectl apply -f $KIT/ecrivain.yaml >/dev/null
kubectl -n ch56 wait --for=condition=Ready pod/ecrivain --timeout=60s >/dev/null
sleep 5
P=$(primaire)
C=$(kubectl -n ch56 get pods -l cnpg.io/instanceRole=replica -o jsonpath='{.items[0].metadata.name}')
echo "\$ kubectl cnpg promote essai $C -n ch56"
kubectl cnpg promote essai $C -n ch56
for i in $(seq 1 60); do [ "$(primaire)" = "$C" ] && break; sleep 1; done
sleep 15
kubectl -n ch56 logs ecrivain | awk '{print $2, $4}' | uniq -c
kubectl -n ch56 logs ecrivain | grep échec
kubectl -n ch56 get pods -L cnpg.io/instanceRole
kubectl -n ch56 delete pod ecrivain --wait=false >/dev/null

section "sauvegarde continue"
kubectl apply -f $KIT/02-sauvegarde.yaml -f $KIT/03-cluster-sauvegarde.yaml
sleep 5
phases essai 150
kubectl -n ch56 get pods
kubectl -n ch56 get pod $(primaire) -o json | jq -c '[.spec.initContainers[] | {name, image, restartPolicy}]'
kubectl -n ch56 get cluster essai -o json | jq -c '.status.conditions[] | {type, status, reason}'
kubectl apply -f $KIT/04-sauvegarde-complete.yaml
for i in $(seq 1 60); do p=$(kubectl -n ch56 get backup premiere -o jsonpath='{.status.phase}'); [ "$p" = completed ] || [ "$p" = failed ] && break; sleep 3; done
kubectl -n ch56 get backup
kubectl -n ch56 get backup premiere -o json | jq -c '.status | {phase, backupId, beginWal, endWal, startedAt, stoppedAt}'
kubectl cnpg status essai -n ch56 2>&1 | sed -n '/^Continuous Backup/,/^$/p'
kubectl -n stockage port-forward svc/rustfs 9011:9000 >/dev/null 2>&1 & PF=$!
sleep 3
curl -s --aws-sigv4 "aws:amz:us-east-1:s3" --user cnpg:sauvegardes-du-cours-56 "http://localhost:9011/sauvegardes?list-type=2" \
  | grep -o '<Key>[^<]*</Key>' | sed 's#</*Key>##g' | sed -E 's#^(essai/[^/]+/[^/]+).*#\1#' | sort | uniq -c
kill $PF

section "accident"
kubectl apply -f $KIT/ecrivain.yaml >/dev/null
kubectl -n ch56 wait --for=condition=Ready pod/ecrivain --timeout=60s >/dev/null
sleep 30
kubectl -n ch56 delete pod ecrivain --wait=true >/dev/null
echo "lignes dans battements : $(psql_p 'SELECT count(*) FROM battements')"
T=$(psql_p "SELECT to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')")
echo "instant choisi : $T"
sleep 2
echo "\$ DROP TABLE battements"
psql_p "DROP TABLE battements"
psql_p "SELECT pg_switch_wal()" >/dev/null
psql_p 'SELECT count(*) FROM battements' 2>&1 | head -1
sleep 15

section "restauration"
sed "s/@@INSTANT@@/$T/" $KIT/05-restauration.yaml > 05-restauration.yaml
grep -n "targetTime" 05-restauration.yaml
debut=$(date +%s)
kubectl apply -f 05-restauration.yaml
phases essai-restaure 150
echo "durée : $(( $(date +%s) - debut )) s"
kubectl -n ch56 exec essai-restaure-1 -c postgres -- psql -U postgres -d app -qtAc "SELECT count(*), max(a) FROM battements"
kubectl -n ch56 get pods
echo; echo "### fin"
