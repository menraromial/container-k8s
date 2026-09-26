#!/usr/bin/env bash
# Grille de vérification du défi IV. Usage : ./verifier.sh chemin/vers/ca.crt
# Suppose la passerelle du chapitre 28 sur 192.168.49.102 et Colis installé par Helm dans colis-prod.
CA=${1:?"donnez le chemin du certificat de l'autorité (ca.crt)"}
NS=colis-prod; HOTE=colis-prod.local; IP=192.168.49.102
K="kubectl -n $NS"; U="https://$HOTE"; C="curl -s --cacert $CA --resolve $HOTE:443:$IP"
ok=0; ko=0
verdict() { if [ "$1" = 0 ]; then echo "OK      $2"; ok=$((ok+1)); else echo "ÉCHEC   $2"; ko=$((ko+1)); fi; }

# 1. installé par Helm, chart 0.2.0 ou plus récent
helm -n $NS list -o json | jq -e '.[] | select(.name=="colis" and .status=="deployed" and (.chart|test("^colis-0\\.([2-9]|[1-9][0-9])")))' >/dev/null
verdict $? "1. release colis déployée par Helm, chart 0.2.0 ou plus"

# 2. HTTPS, et redirection de HTTP
$C $U/api/pret | jq -e '.pret == true' >/dev/null
verdict $? "2a. $U/api/pret répond en HTTPS, certificat de l'autorité du cours"
[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $HOTE" http://$IP/)" = 301 ]
verdict $? "2b. http://$HOTE/ redirige (301)"

# 3. les données survivent à la perte de PostgreSQL
n="Verif $(date +%s)"
$C -X POST $U/api/colis -H 'Content-Type: application/json' -d "{\"destinataire\":\"$n\",\"depart\":\"Paris\",\"arrivee\":\"Lyon\",\"poids_kg\":1}" >/dev/null
$K delete pod postgres-0 --wait=true >/dev/null 2>&1
$K wait --for=condition=Ready pod/postgres-0 --timeout=120s >/dev/null 2>&1
for i in $(seq 1 30); do $C $U/api/colis | jq -e --arg n "$n" 'any(.[]; .destinataire==$n)' >/dev/null 2>&1 && break; sleep 2; done
$C $U/api/colis | jq -e --arg n "$n" 'any(.[]; .destinataire==$n)' >/dev/null
verdict $? "3. un colis survit à la suppression de postgres-0, sans redémarrer l'API"

# 4. l'API est gérée par un HPA de 2 à 6, et le chart ne fixe pas son nombre de répliques
$K get hpa -o json | jq -e '.items[] | select(.spec.scaleTargetRef.name=="api" and .spec.minReplicas==2 and .spec.maxReplicas==6)' >/dev/null
verdict $? "4a. HPA sur le Deployment api, de 2 à 6 répliques"
helm -n $NS get manifest colis | awk '/^kind: Deployment/{d=1} /^---/{d=0;a=0} d&&/^  name: api$/{a=1} a&&/^  replicas:/{f=1} END{exit f}'
verdict $? "4b. le Deployment api rendu par le chart n'a pas de champ replicas"

# 5. le worker dort à 0 et se réveille quand la file se remplit
# juste après une installation, le worker démarre à 1 : KEDA l'endort après son cooldownPeriod
for i in $(seq 1 45); do [ "$($K get deploy worker -o jsonpath='{.spec.replicas}')" = 0 ] && break; sleep 2; done
[ "$($K get deploy worker -o jsonpath='{.spec.replicas}')" = 0 ]
verdict $? "5a. worker à 0 réplique au repos"
seq 1 30 | xargs -P 10 -I{} $C -o /dev/null -X POST $U/api/colis -H 'Content-Type: application/json' -d '{"destinataire":"Rafale {}","depart":"Paris","arrivee":"Lyon","poids_kg":1}'
vu=0; for i in $(seq 1 30); do [ "$($K get deploy worker -o jsonpath='{.spec.replicas}')" -gt 0 ] && vu=1; [ "$($K exec deploy/redis -- redis-cli LLEN colis:a-estimer)" = 0 ] && [ $vu = 1 ] && break; sleep 2; done
[ $vu = 1 ] && [ "$($K exec deploy/redis -- redis-cli LLEN colis:a-estimer)" = 0 ]
verdict $? "5b. une rafale de 30 colis réveille des workers et la file se vide en moins d'une minute"

# 6. des budgets de perturbation pour l'API et le site
for c in api web; do $K get pdb -o json | jq -e --arg c $c '.items[] | select(.spec.selector.matchLabels["app.kubernetes.io/name"]==$c and .status.disruptionsAllowed>=1)' >/dev/null; verdict $? "6. PDB sur $c, qui autorise au moins une perturbation"; done

# 7. le test du chart réussit
helm -n $NS test colis >/dev/null 2>&1
verdict $? "7. helm test colis"

echo; echo "$ok vérification(s) réussie(s), $ko en échec"
