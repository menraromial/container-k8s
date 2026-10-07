#!/usr/bin/env bash
# Grille du défi VI : vérifie qu'un Colis déployé dans un namespace respecte les règles de la partie VI,
# et qu'il fonctionne encore.
# Usage : ./verifier.sh [namespace]          (colis-audit par défaut)
# Variables : CLE_PUBLIQUE (clé cosign du chapitre 14, cosign.pub par défaut)
NS=${1:-colis-audit}
CLE_PUBLIQUE=${CLE_PUBLIQUE:-cosign.pub}
export PATH=~/.local/opt/cours-k8s/bin:$PATH
K="kubectl -n $NS"; ok=0; ko=0
verdict() { if [ "$1" = 0 ]; then echo "OK      $2"; ok=$((ok+1)); else echo "ÉCHEC   $2"; ko=$((ko+1)); fi; }
C=/var/lib/minikube/certs/etcd
E() { kubectl -n kube-system exec -i etcd-minikube -- etcdctl --cacert=$C/ca.crt --cert=$C/server.crt --key=$C/server.key "$@" 2>/dev/null; }
# les Pods en marche, sans ceux qui sont en cours d'arrêt
PODS=$($K get pods --field-selector=status.phase=Running -o json | jq '.items |= map(select(.metadata.deletionTimestamp == null))')

# 1. le namespace porte les étiquettes de sécurité de la partie VI
L=$(kubectl get ns $NS -o json | jq -r '.metadata.labels')
manque=$(for e in pod-security.kubernetes.io/enforce=restricted cours/politique-images=oui cours/images-signees=oui cours/analyse-exigee=oui; do
  [ "$(echo "$L" | jq -r --arg k "${e%%=*}" '.[$k] // ""')" = "${e#*=}" ] || echo -n "${e%%=*} "; done)
[ -z "$manque" ]; verdict $? "1. étiquettes du namespace (Pod Security, images) ${manque:+: manquent $manque}"

# 2. tous les Pods respectent le niveau restricted
avert=$(kubectl label --dry-run=server --overwrite ns $NS pod-security.kubernetes.io/enforce=restricted 2>&1 | grep -c '^Warning')
[ "$(echo "$PODS" | jq '.items | length')" -gt 0 ] && [ "$avert" = 0 ]; verdict $? "2. Pods conformes au niveau restricted ($avert avertissement(s))"

# 3. aucun secret dans les ConfigMaps ; le mot de passe est dans un Secret chiffré dans etcd
cm=$($K get configmaps -o json | jq -r '[.items[] | select(.metadata.name != "kube-root-ca.crt") | .data // {} | to_entries[] | select(.key | test("PASS|SECRET|TOKEN"; "i")) | .key] | join(",")')
sec=$($K get secrets -o json | jq -r '[.items[] | select(.data.POSTGRES_PASSWORD) | .metadata.name] | first // ""')
pref=$( [ -n "$sec" ] && E get /registry/secrets/$NS/$sec --print-value-only | head -c 8)
[ -z "$cm" ] && [ -n "$sec" ] && [ "$pref" = "k8s:enc:" ]
verdict $? "3. mot de passe hors des ConfigMaps${cm:+ (trouvé : $cm)}, dans le Secret ${sec:-?}, chiffré dans etcd"

# 4. aucun ServiceAccount du namespace ne peut lire les Secrets ni créer des Pods
trop=$(for sa in $($K get sa -o name | cut -d/ -f2); do
  for a in "get secrets" "create pods"; do
    [ "$(kubectl auth can-i $a -n $NS --as=system:serviceaccount:$NS:$sa 2>/dev/null)" = yes ] && echo -n "$sa:${a// /-} "
  done; done)
[ -z "$trop" ]; verdict $? "4. ServiceAccounts sans droit sur les Secrets ni les Pods${trop:+ (trop : $trop)}"

# 5. aucun Pod ne reçoit de jeton d'API
monte=$(echo "$PODS" | jq -r '[.items[] | select(any(.spec.volumes[]?; any(.projected.sources[]?; .serviceAccountToken))) | .metadata.name] | join(",")')
[ -z "$monte" ]; verdict $? "5. aucun jeton de ServiceAccount monté${monte:+ (dans : $monte)}"

# 6. aucun ancien jeton sans expiration
vieux=$($K get secrets --field-selector type=kubernetes.io/service-account-token -o name | tr '\n' ' ')
[ -z "$vieux" ]; verdict $? "6. aucun jeton de Secret sans expiration${vieux:+ (trouvé : $vieux)}"

# 7. un Pod d'un autre namespace ne joint ni la base, ni Redis, ni l'API
kubectl create ns defi6-sonde >/dev/null 2>&1
kubectl -n defi6-sonde run sonde --image=nicolaka/netshoot:v0.14 --restart=Never -- sleep 300 >/dev/null 2>&1
kubectl -n defi6-sonde wait --for=condition=Ready pod/sonde --timeout=90s >/dev/null 2>&1
ouverts=$(for cible in postgres:5432 redis:6379 api:8000; do
  kubectl -n defi6-sonde exec sonde -- nc -z -w 2 ${cible%%:*}.$NS.svc.cluster.local ${cible#*:} >/dev/null 2>&1 && echo -n "$cible "; done)
kubectl delete ns defi6-sonde --wait=false >/dev/null 2>&1
[ -z "$ouverts" ]; verdict $? "7. base, Redis et API injoignables depuis un autre namespace${ouverts:+ (ouverts : $ouverts)}"

# 8. images : celles du registre du cours signées, avec une analyse signée sans faille HIGH ni CRITICAL ;
#    les autres avec une étiquette précise
mauvaises=$(for img in $(echo "$PODS" | jq -r '[.items[].spec.containers[].image] | unique | .[]'); do
  case $img in
    host.minikube.internal:5001/*)
      ref=localhost:5001/${img#host.minikube.internal:5001/}
      o="--insecure-ignore-tlog=true --new-bundle-format=false --allow-http-registry"
      cosign verify --key $CLE_PUBLIQUE $o $ref >/dev/null 2>&1 || { echo -n "$img(signature) "; continue; }
      graves=$(cosign verify-attestation --key $CLE_PUBLIQUE --type vuln $o $ref 2>/dev/null | head -1 | jq -r .payload | base64 -d \
        | jq '[.predicate.scanner.result.Results[]?.Vulnerabilities[]? | select(.Severity == "HIGH" or .Severity == "CRITICAL")] | length' 2>/dev/null)
      [ "$graves" = 0 ] || echo -n "$img(analyse:${graves:-absente}) " ;;
    *@sha256:*) ;;
    *:latest) echo -n "$img(latest) " ;;
    *:*) ;;
    *) echo -n "$img(sans étiquette) " ;;
  esac; done)
[ -z "$mauvaises" ]; verdict $? "8. images signées et analysées sans faille grave${mauvaises:+ (en défaut : $mauvaises)}"

# 9. chaque conteneur a une limite mémoire
sans=$(echo "$PODS" | jq -r '[.items[] | .metadata.name as $p | .spec.containers[] | select(.resources.limits.memory == null) | "\($p)/\(.name)"] | join(",")')
[ -z "$sans" ]; verdict $? "9. limites mémoire partout${sans:+ (manquent : $sans)}"

# 10. l'application fonctionne : santé, création et lecture d'un colis
$K port-forward svc/web 18080:80 >/dev/null 2>&1 & PF=$!
sleep 3
sante=$(curl -s -m 5 http://127.0.0.1:18080/api/sante | jq -r .statut 2>/dev/null)
id=$(curl -s -m 5 -X POST http://127.0.0.1:18080/api/colis -H 'Content-Type: application/json' \
  -d '{"destinataire":"Grille défi VI","depart":"Rennes","arrivee":"Lille","poids_kg":1}' | jq -r .id 2>/dev/null)
lu=$(curl -s -m 5 http://127.0.0.1:18080/api/colis | jq --arg i "$id" '[.[] | select((.id|tostring) == $i)] | length' 2>/dev/null)
kill $PF 2>/dev/null
[ "$sante" = ok ] && [ "$lu" = 1 ]; verdict $? "10. l'application répond (santé : ${sante:-?}, colis créé et relu : ${id:-?})"

echo; echo "$ok vérification(s) réussie(s), $ko en échec"
