#!/usr/bin/env bash
# Grille du défi VII : Colis est-il rétabli, sans avoir rien ouvert de trop, et le post-mortem est-il complet ?
# Usage : ./verifier.sh [post-mortem.md]
# Variables : PASSERELLE (adresse de la passerelle HTTPS du chapitre 28, 192.168.49.102 par défaut)
PM=${1:-post-mortem.md}
PASSERELLE=${PASSERELLE:-192.168.49.102}
D=$(cd "$(dirname "$0")" && pwd)
export PATH=~/.local/opt/cours-k8s/bin:$PATH
DEBUT=$(cat "$D/debut-incident" 2>/dev/null || echo 1970-01-01T00:00:00Z)
ok=0; ko=0
verdict() { if [ "$1" = 0 ]; then echo "OK      $2"; ok=$((ok+1)); else echo "ÉCHEC   $2"; ko=$((ko+1)); fi; }
kubectl -n supervision port-forward svc/supervision-kube-prometheu-prometheus 19090:9090 >/dev/null 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null' EXIT
for i in $(seq 1 20); do curl -s localhost:19090/-/ready >/dev/null && break; sleep 1; done
prom() { curl -s --get localhost:19090/api/v1/query --data-urlencode "query=$1" | jq -r "${2:-.data.result[0].value[1] // \"\"}"; }
sql() { kubectl -n colis exec postgres-0 -- psql -U colis -d colis -Atc "$1" 2>/dev/null; }
api() { curl -sk --max-time 5 --resolve colis.local:443:$PASSERELLE "https://colis.local/api$1" "${@:2}"; }

# 1. aucune alerte en cours sur le namespace colis
alertes=$(prom 'ALERTS{namespace="colis", alertstate="firing", alertname!="InfoInhibitor", severity!~"info|none"}' '[.data.result[].metric.alertname] | unique | join(",")')
[ -z "$alertes" ]; verdict $? "1. aucune alerte en cours sur colis${alertes:+ (en cours : $alertes)}"

# 2. la file d'estimation est vide
file=$(kubectl -n colis exec deploy/redis -- redis-cli llen colis:a-estimer 2>/dev/null)
[ "$file" = 0 ]; verdict $? "2. file d'estimation vide (${file:-?} colis en attente)"

# 3. tous les colis enregistrés depuis le début de l'incident ont leur date de livraison
reste=$(sql "SELECT count(*) FILTER (WHERE statut = 'enregistré' AND cree_le < now() - interval '1 minute'), count(*)
             FROM colis WHERE cree_le >= '$DEBUT'")
[ "${reste%%|*}" = 0 ]; verdict $? "3. colis de l'incident tous estimés (${reste%%|*} sans date sur ${reste#*|} depuis $DEBUT)"

# 4. un colis neuf passe de bout en bout : créé par l'API, estimé par le worker en moins d'une minute
id=$(api /colis -X POST -H 'Content-Type: application/json' \
  -d '{"destinataire": "Grille VII", "poids_kg": 1.5, "depart": "Brest", "arrivee": "Lyon"}' | jq -r '.id // empty')
t=0; statut=?
while [ -n "$id" ] && [ $t -lt 60 ]; do
  statut=$(api /colis/$id | jq -r .statut); [ "$statut" = estimé ] && break; sleep 3; t=$((t+3)); done
[ "$statut" = estimé ]; verdict $? "4. colis neuf ${id:-non créé} estimé en moins d'une minute (statut : $statut après $t s)"

# 5. le worker a de la marge : requête au-dessus de son pic de mémoire de l'heure, limite 25 % au-dessus
pic=$(prom 'max(max_over_time(container_memory_working_set_bytes{namespace="colis", container="worker"}[1h]))')
res=$(kubectl -n colis get deploy worker -o json | jq -r '.spec.template.spec.containers[0].resources | "\(.requests.memory // "0") \(.limits.memory // "0")"')
octets() { numfmt --from=iec-i --suffix=B "${1}B" 2>/dev/null | tr -d B || echo 0; }
req=$(octets ${res% *}); lim=$(octets ${res#* })
[ -n "$pic" ] && python3 -c "import sys; p=float('$pic'); sys.exit(0 if $req >= p and $lim >= 1.25 * p else 1)"
verdict $? "5. mémoire du worker : requête ${res% *} et limite ${res#* } pour un pic de $( [ -n "$pic" ] && numfmt --to=iec-i ${pic%.*} || echo '?') sur l'heure"

# 6. la purge de la nuit joindra la base
kubectl -n colis delete job defi7-purge --ignore-not-found >/dev/null 2>&1
kubectl -n colis create job defi7-purge --from=cronjob/purge >/dev/null
kubectl -n colis wait --for=condition=Complete job/defi7-purge --timeout=90s >/dev/null 2>&1; r=$?
journal=$(kubectl -n colis logs job/defi7-purge 2>/dev/null | tail -1 | jq -r '.message // empty' 2>/dev/null)
kubectl -n colis delete job defi7-purge --wait=false >/dev/null 2>&1
verdict $r "6. la purge s'exécute${journal:+ ($journal)}"

# 7. la base reste fermée aux Pods qui n'ont rien à y faire
kubectl create ns defi7-sonde >/dev/null 2>&1
kubectl -n defi7-sonde run sonde --image=nicolaka/netshoot:v0.14 --restart=Never -- sleep 300 >/dev/null 2>&1
kubectl -n defi7-sonde wait --for=condition=Ready pod/sonde --timeout=90s >/dev/null 2>&1
kubectl -n defi7-sonde exec sonde -- nc -z -w 2 postgres.colis.svc.cluster.local 5432 >/dev/null 2>&1; ouvert=$?
kubectl delete ns defi7-sonde --wait=false >/dev/null 2>&1
[ $ouvert != 0 ]; verdict $? "7. base fermée aux autres namespaces$( [ $ouvert = 0 ] && echo ' (joignable depuis defi7-sonde)')"

# 8. le post-mortem a ses rubriques, une chronologie horodatée et nomme les trois modifications
if [ -f "$PM" ]; then
  manque=$(for r in Résumé Impact Chronologie Cause Détection Action; do grep -qiE "^#+ .*$r" "$PM" || echo -n "$r "; done)
  heures=$(sed -n '/^#\+ .*[Cc]hronologie/,/^#\+ /p' "$PM" | grep -cE '[0-9]{1,2}[:h][0-9]{2}')
  oublis=$(grep -qiE 'worker' "$PM" || echo -n "worker "; grep -qiE 'networkpolicy|politique réseau' "$PM" || echo -n "politique "
           grep -qiE 'purge' "$PM" || echo -n "purge "; grep -qiE '128 ?Mi|requête.*api|api.*requête' "$PM" || echo -n "api ")
  [ -z "$manque" ] && [ "$heures" -ge 6 ] && [ -z "$oublis" ]
  verdict $? "8. post-mortem ($PM) : rubriques${manque:+ manquantes : $manque}${manque:- complètes}, $heures ligne(s) horodatées${oublis:+, ne parle pas de : $oublis}"
else
  verdict 1 "8. post-mortem : fichier $PM introuvable"
fi

echo; echo "$ok vérification(s) réussie(s), $ko en échec"
