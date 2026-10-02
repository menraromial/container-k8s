#!/usr/bin/env bash
# Rejeu du chapitre 42 (authentification) sur le profil minikube principal.
# Sorties dans outils/out/ch42r. Durée : environ 15 minutes (rotation d'un jeton, expirations).
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/authentification
O=$RACINE/outils/out/ch42r
API=https://192.168.49.2:8443
CA=$HOME/.minikube/ca.crt
section() { echo; echo "### $*"; }
anonyme() { curl -s -k -o /dev/null -w "/$1 %{http_code}\n" $API/$1; }
avec_jeton() { kubectl --kubeconfig=/dev/null --server=$API --certificate-authority=$CA --token="$1" "${@:2}"; }
charge() { cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null; }

# --- remise à zéro : uniquement les objets de ce chapitre
arreter_fournisseur() {
  local pid
  pid=$(ss -ltnpH 'sport = :9443' 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)
  [ -n "$pid" ] && kill "$pid"
  return 0
}
arreter_fournisseur
(cd "$KIT" && bash brancher-fournisseur.sh --retirer >/dev/null 2>&1)
kubectl delete ns ch42 --wait >/dev/null 2>&1
for c in alice bruno carla pirate bob-60 bob-315360000; do kubectl delete csr $c >/dev/null 2>&1; done
kubectl -n kube-system delete secret bootstrap-token-cours4 >/dev/null 2>&1
rm -rf "$O"; mkdir -p "$O/idp"; cd "$O"
trap 'arreter_fournisseur; (cd "$KIT" && bash brancher-fournisseur.sh --retirer >/dev/null 2>&1)' EXIT
kubectl create ns ch42 >/dev/null

section "ouverture : bruno"
NS=ch42 DUREE=31536000 bash $KIT/nouvel-utilisateur.sh bruno equipe-colis
KUBECONFIG=bruno.kubeconfig kubectl auth whoami
kubectl delete csr bruno
KUBECONFIG=bruno.kubeconfig kubectl auth whoami -o jsonpath='{.status.userInfo.username}{"\n"}'
kubectl api-resources | grep -i -E 'revo|crl' || echo "(aucune ressource)"

# lancés tôt, vérifiés à la fin (exercices 1 et 4, rotation)
mkdir -p ex1 && (cd ex1 && NS=ch42 DUREE=600 bash $KIT/nouvel-utilisateur.sh carla stagiaires > carla.log 2>&1)
kubectl -n ch42 create sa robot >/dev/null
kubectl apply -f $KIT/coffre.yaml >/dev/null
kubectl -n ch42 wait --for=condition=Ready pod/client-coffre --timeout=120s >/dev/null
( for i in $(seq 1 60); do
    echo "$(date +%s) $(kubectl -n ch42 exec client-coffre -- sh -c 'readlink /var/run/secrets/coffre/..data; cut -d. -f2 /var/run/secrets/coffre/jeton' 2>/dev/null | tr '\n' ' ')"
    sleep 15
  done > rotation.log ) &
ROTATION=$!

section "authentificateurs"
kubectl -n kube-system get pod kube-apiserver-minikube -o json | jq -r '.spec.containers[0].command[]' \
  | grep -E 'client-ca|service-account|bootstrap|requestheader-(client|allowed|username|group)|authorization-mode'

section "alice pas à pas"
openssl genpkey -algorithm ed25519 -out alice.key
openssl req -new -key alice.key -subj "/CN=alice/O=equipe-colis" -out alice.csr
openssl req -in alice.csr -noout -subject
cat > alice-csr.yaml <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: alice
spec:
  request: $(base64 -w0 alice.csr)
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400
  usages: [client auth]
EOF
kubectl apply -f alice-csr.yaml
kubectl get csr alice
kubectl certificate approve alice
sleep 2
kubectl get csr alice
kubectl get csr alice -o jsonpath='{.status.certificate}' | base64 -d > alice.crt
date -u +%T
openssl x509 -in alice.crt -noout -subject -issuer -dates -ext extendedKeyUsage
K=alice.kubeconfig
kubectl --kubeconfig=$K config set-cluster cours --server=$API --certificate-authority=$CA --embed-certs
kubectl --kubeconfig=$K config set-credentials alice --client-certificate=alice.crt --client-key=alice.key --embed-certs
kubectl --kubeconfig=$K config set-context alice@cours --cluster=cours --user=alice --namespace=ch42
kubectl --kubeconfig=$K config use-context alice@cours
KUBECONFIG=$K kubectl auth whoami
openssl x509 -in alice.crt -noout -fingerprint -sha256
KUBECONFIG=$K kubectl get pods

section "pirate"
openssl genpkey -algorithm ed25519 -out pirate.key
openssl req -new -key pirate.key -subj "/CN=pirate/O=system:masters" -out pirate.csr
cat > pirate-csr.yaml <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: pirate
spec:
  request: $(base64 -w0 pirate.csr)
  signerName: kubernetes.io/kube-apiserver-client
  usages: [client auth]
EOF
kubectl apply -f pirate-csr.yaml

section "durées"
for d in 60 315360000; do
  openssl genpkey -algorithm ed25519 -out b$d.key; openssl req -new -key b$d.key -subj "/CN=bob-$d" -out b$d.csr
  sed -e "s/name: pirate/name: bob-$d/" -e "s|request: .*|request: $(base64 -w0 b$d.csr)|" -e "s|usages:|expirationSeconds: $d\n  usages:|" pirate-csr.yaml > b$d.yaml
  kubectl apply -f b$d.yaml
done
kubectl certificate approve bob-315360000 >/dev/null; sleep 2
date -u +%T
kubectl get csr bob-315360000 -o jsonpath='{.status.certificate}' | base64 -d | openssl x509 -noout -dates
kubectl delete csr bob-315360000 >/dev/null
openssl x509 -in ~/.minikube/profiles/minikube/client.crt -noout -subject -dates

section "jeton du Pod"
kubectl apply -f $KIT/outil.yaml
kubectl -n ch42 wait --for=condition=Ready pod/outil --timeout=120s
kubectl -n ch42 exec outil -- ls /var/run/secrets/kubernetes.io/serviceaccount/
kubectl -n ch42 exec outil -- cat /var/run/secrets/kubernetes.io/serviceaccount/token > jeton-pod.txt
cut -d. -f1 jeton-pod.txt | base64 -d 2>/dev/null; echo
charge < jeton-pod.txt | jq .
charge < jeton-pod.txt | jq '{validite_jours: ((.exp - .iat) / 86400), alerte_secondes: (.["kubernetes.io"].warnafter - .iat)}'

section "Pod supprimé"
T=$(cat jeton-pod.txt)
avec_jeton "$T" auth whoami
kubectl -n ch42 delete pod outil --wait
avec_jeton "$T" auth whoami
sleep 1
kubectl -n kube-system logs kube-apiserver-minikube --since=20s | grep 'Unable to authenticate' | tail -1 | sed 's/.*err=//'

section "TokenRequest"
kubectl -n ch42 create token robot --duration=1m
kubectl -n ch42 create token robot --duration=87600h > jeton-10ans.txt
charge < jeton-10ans.txt | jq -c '{iat, exp, jours: ((.exp - .iat) / 86400)}'
kubectl -n ch42 create token robot --duration=10m --audience=coffre > jeton-coffre-cli.txt
charge < jeton-coffre-cli.txt | jq -c '{aud, duree: (.exp - .iat), lie_a: (.["kubernetes.io"] | keys)}'

section "TokenReview"
for aud in "" coffre; do
  jq -n --arg t "$(cat jeton-coffre-cli.txt)" --arg a "$aud" \
    '{apiVersion: "authentication.k8s.io/v1", kind: "TokenReview", spec: ({token: $t} + (if $a == "" then {} else {audiences: [$a]} end))}' > revue.json
  kubectl create -f revue.json -o json | jq -c '.status | {authenticated, user: .user.username, audiences, error}'
done

section "volume projeté"
kubectl -n ch42 exec client-coffre -- ls /var/run/secrets/
kubectl -n ch42 exec client-coffre -- ls -la /var/run/secrets/coffre/
kubectl -n ch42 exec client-coffre -- cat /var/run/secrets/coffre/jeton > jeton-coffre.txt
charge < jeton-coffre.txt | jq -c '{aud, iat, exp, duree: (.exp - .iat), warnafter: .["kubernetes.io"].warnafter}'

section "ancien jeton"
cat > robot-jeton.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: robot-jeton
  namespace: ch42
  annotations:
    kubernetes.io/service-account.name: robot
type: kubernetes.io/service-account-token
EOF
kubectl apply -f robot-jeton.yaml
until [ -n "$(kubectl -n ch42 get secret robot-jeton -o jsonpath='{.data.token}' 2>/dev/null)" ]; do sleep 0.2; done
kubectl -n ch42 get secret robot-jeton -o jsonpath='{.data.token}' | base64 -d > jeton-secret.txt
charge < jeton-secret.txt | jq .
avec_jeton "$(cat jeton-secret.txt)" auth whoami -o jsonpath='{.status.userInfo.username}{"\n"}'
kubectl -n ch42 get secret robot-jeton -o jsonpath='{.metadata.labels}{"\n"}'

section "découverte OIDC"
kubectl get --raw /.well-known/openid-configuration | jq .
kubectl get --raw /openid/v1/jwks | jq '.keys[] | {kty, alg, use, kid, n: (.n[0:20] + "...")}'
kubectl get clusterrolebinding system:service-account-issuer-discovery -o jsonpath='{.subjects}{"\n"}'
curl -s -k $API/openid/v1/jwks | jq -c '{code, message}'
minikube ssh -- sudo cat /var/lib/minikube/certs/sa.pub 2>/dev/null > sa.pub
openssl pkey -pubin -in sa.pub -outform DER | openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | tr -d '='

section "vérifier hors ligne"
python3 - jeton-coffre.txt > jeton-falsifie.txt <<'EOF'
import base64, json, sys
entete, charge, signature = open(sys.argv[1]).read().strip().split(".")
donnees = json.loads(base64.urlsafe_b64decode(charge + "=="))
donnees["sub"] = "system:serviceaccount:kube-system:clusterrole-aggregation-controller"
charge = base64.urlsafe_b64encode(json.dumps(donnees, separators=(",", ":")).encode()).decode().rstrip("=")
print(entete + "." + charge + "." + signature)
EOF
for j in "jeton-pod.txt" "jeton-coffre.txt" "jeton-coffre.txt coffre" "jeton-secret.txt" "jeton-falsifie.txt coffre"; do
  echo "\$ python3 verifier-jeton.py $j"
  python3 $KIT/verifier-jeton.py $j
done
avec_jeton "$(cat jeton-pod.txt)" auth whoami 2>&1 | tail -1

section "SA supprimé"
code() { curl -s -o /dev/null -w "%{http_code}" --cacert $CA -H "Authorization: Bearer $(cat $1)" $API/api; }
echo "avant : jeton-10ans $(code jeton-10ans.txt), jeton-secret $(code jeton-secret.txt)"
debut=$EPOCHREALTIME
kubectl -n ch42 delete sa robot
echo "aussitôt : jeton-10ans $(code jeton-10ans.txt), jeton-secret $(code jeton-secret.txt)"
while [ "$(code jeton-secret.txt)" = 200 ]; do sleep 0.2; done
python3 -c "print(f'jeton-secret refusé après {float(\"$EPOCHREALTIME\") - float(\"$debut\"):.1f} s')"
kubectl -n ch42 get secret
kubectl -n ch42 create sa robot
sleep 2
echo "SA recréé : jeton-10ans $(code jeton-10ans.txt)"

section "anonyme avant"
for p in livez version api; do anonyme $p; done

section "fournisseur"
cd idp
bash $KIT/preparer-fournisseur.sh
cp $KIT/fournisseur.py $KIT/jeton-exec.sh .
python3 fournisseur.py servir > serveur.log 2>&1 &
sleep 1; cat serveur.log
curl -s --cacert idp-ca.crt https://192.168.49.1:9443/.well-known/openid-configuration | jq .

section "brancher"
time bash $KIT/brancher-fournisseur.sh 2>&1 | grep -v -i 'docker'
kubectl -n kube-system get pod kube-apiserver-minikube -o jsonpath='{.spec.containers[0].command}' | tr ',' '\n' | tr -d '"' | grep authentication-config

section "lea"
T=$(python3 fournisseur.py emettre lea@colis.example developpeurs astreinte)
echo "$T" | charge | jq .
avec_jeton "$T" auth whoami
avec_jeton "$T" get pods -n colis

section "refus OIDC"
for essai in "lea@colis.example developpeurs --audience autre-cluster" "lea@colis.example developpeurs --non-verifie" "lea@colis.example developpeurs --duree -60" "max@colis.example system:masters"; do
  echo "\$ emettre $essai"
  avec_jeton "$(python3 fournisseur.py emettre $essai)" auth whoami 2>&1 | tail -2
done
sleep 1
kubectl -n kube-system logs kube-apiserver-minikube --since=20s | grep 'Unable to authenticate' | sed 's/.*err=//'

section "anonyme après"
for p in livez version api; do anonyme $p; done

section "rechargement"
T=$(python3 fournisseur.py emettre zoe@ailleurs.example developpeurs --duree 3600)
avec_jeton "$T" auth whoami -o jsonpath='{.status.userInfo.username}{"\n"}'
python3 - <<'EOF'
s = open("authentification.yaml").read()
regle = """  claimValidationRules:
  - expression: "claims.email.endsWith('@colis.example')"
    message: "seules les adresses @colis.example sont admises"
"""
s = s.replace("  claimMappings:", regle + "  claimMappings:")
open("authentification.yaml", "w").write(s)
EOF
sed -n '/^jwt:/,/^anonymous:/p' authentification.yaml | grep -v -E '^ {6}[A-Za-z0-9+/=-]+$'
debut=$EPOCHREALTIME
bash $KIT/brancher-fournisseur.sh 2>&1 | grep -v -i docker
until ! avec_jeton "$T" auth whoami >/dev/null 2>&1; do sleep 1; done
python3 -c "print(f'refusé {float(\"$EPOCHREALTIME\") - float(\"$debut\"):.0f} s après la copie')"
kubectl -n kube-system logs kube-apiserver-minikube --since=3m | grep 'reloaded authentication config' | tail -1
sleep 1
kubectl -n kube-system logs kube-apiserver-minikube --since=20s | grep 'Unable to authenticate' | tail -1 | sed 's/.*err=//'
kubectl get --raw /metrics | grep -E '^apiserver_authentication_config_controller_automatic_reloads_total' | sed 's/apiserver_id_hash="[^"]*",//'

section "greffon exec"
cd "$O"
kubectl --kubeconfig=lea.kubeconfig config set-cluster cours --server=$API --certificate-authority=$CA --embed-certs
kubectl --kubeconfig=lea.kubeconfig config set-credentials lea --exec-api-version=client.authentication.k8s.io/v1 --exec-command=$O/idp/jeton-exec.sh --exec-interactive-mode=Never
kubectl --kubeconfig=lea.kubeconfig config set-context lea@cours --cluster=cours --user=lea
kubectl --kubeconfig=lea.kubeconfig config use-context lea@cours
grep -A6 'exec:' lea.kubeconfig
KUBECONFIG=lea.kubeconfig kubectl auth whoami
echo "--- même chose, kubeconfig dans le dossier du greffon"
cd idp
kubectl --kubeconfig=lea2.kubeconfig config set-cluster cours --server=$API --certificate-authority=$CA --embed-certs >/dev/null
kubectl --kubeconfig=lea2.kubeconfig config set-credentials lea --exec-api-version=client.authentication.k8s.io/v1 --exec-command=./jeton-exec.sh --exec-interactive-mode=Never >/dev/null
kubectl --kubeconfig=lea2.kubeconfig config set-context lea@cours --cluster=cours --user=lea >/dev/null
kubectl --kubeconfig=lea2.kubeconfig config use-context lea@cours >/dev/null
grep 'command:' lea2.kubeconfig
KUBECONFIG=lea2.kubeconfig kubectl auth whoami 2>&1 | head -3
sed -i 's|command: jeton-exec.sh|command: ./jeton-exec.sh|' lea2.kubeconfig
KUBECONFIG=lea2.kubeconfig kubectl auth whoami -o jsonpath='{.status.userInfo.username}{"\n"}'
cd "$O"

section "débrancher"
arreter_fournisseur
(cd $KIT && bash brancher-fournisseur.sh --retirer 2>&1 | grep -v -i docker)
for p in livez version; do anonyme $p; done

section "ex2 automount"
cat > discret.yaml <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: discret
  namespace: ch42
automountServiceAccountToken: false
---
apiVersion: v1
kind: Pod
metadata:
  name: sans-jeton
  namespace: ch42
spec:
  serviceAccountName: discret
  containers:
  - name: c
    image: busybox:1.37
    command: [sleep, infinity]
---
apiVersion: v1
kind: Pod
metadata:
  name: avec-jeton
  namespace: ch42
spec:
  serviceAccountName: discret
  automountServiceAccountToken: true
  containers:
  - name: c
    image: busybox:1.37
    command: [sleep, infinity]
EOF
kubectl apply -f discret.yaml
kubectl -n ch42 wait --for=condition=Ready pod/sans-jeton pod/avec-jeton --timeout=120s
for p in sans-jeton avec-jeton; do echo "$p : $(kubectl -n ch42 exec $p -- ls /var/run/secrets/kubernetes.io/serviceaccount 2>&1 | tr '\n' ' ')"; done

section "ex3 audit"
kubectl config view --minify --flatten --context=minikube > minikube.kubeconfig
kubectl -n ch42 create token robot --duration=87600h > jeton-10ans.txt
kubectl -n ch42 apply -f robot-jeton.yaml >/dev/null
until [ -n "$(kubectl -n ch42 get secret robot-jeton -o jsonpath='{.data.token}' 2>/dev/null)" ]; do sleep 0.2; done
kubectl -n ch42 get secret robot-jeton -o jsonpath='{.data.token}' | base64 -d > jeton-secret.txt
kubectl --kubeconfig=robot-10ans.kubeconfig config set-credentials robot-10ans --token="$(cat jeton-10ans.txt)" >/dev/null
kubectl --kubeconfig=robot-secret.kubeconfig config set-credentials robot-secret --token="$(cat jeton-secret.txt)" >/dev/null
KUBECONFIG=minikube.kubeconfig:alice.kubeconfig:lea.kubeconfig:robot-10ans.kubeconfig:robot-secret.kubeconfig kubectl config view --flatten > equipe.kubeconfig
python3 $KIT/corrige/auditer-kubeconfig.py equipe.kubeconfig

section "ex4 amorçage"
FIN_AMORCE=$(date -u -d '+2 min' +%Y-%m-%dT%H:%M:%SZ)
cat > amorce.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: bootstrap-token-cours4
  namespace: kube-system
type: bootstrap.kubernetes.io/token
stringData:
  token-id: cours4
  token-secret: 0123456789abcdef
  usage-bootstrap-authentication: "true"
  auth-extra-groups: system:bootstrappers:cours
  expiration: "$FIN_AMORCE"
EOF
kubectl apply -f amorce.yaml
avec_jeton cours4.0123456789abcdef auth whoami
avec_jeton cours4.0123456789abcdef get pods -n ch42
echo "expiration : $FIN_AMORCE"
until [ "$(date +%s)" -gt "$(date -d "$FIN_AMORCE" +%s)" ]; do sleep 2; done
date -u +%T
avec_jeton cours4.0123456789abcdef auth whoami 2>&1 | tail -1
for i in $(seq 1 60); do kubectl -n kube-system get secret bootstrap-token-cours4 >/dev/null 2>&1 || { echo "Secret supprimé à $(date -u +%T)"; break; }; sleep 2; done

section "ex1 carla"
cat ex1/carla.log
openssl x509 -in ex1/carla.crt -noout -dates
FIN=$(openssl x509 -in ex1/carla.crt -noout -enddate | cut -d= -f2)
until [ "$(date +%s)" -gt "$(date -d "$FIN" +%s)" ]; do sleep 5; done
date -u +%T
KUBECONFIG=ex1/carla.kubeconfig kubectl auth whoami 2>&1 | tail -1
sleep 1
kubectl -n kube-system logs kube-apiserver-minikube --since=15s | grep 'Unable to authenticate' | tail -1 | sed 's/.*err=//'

section "rotation"
wait $ROTATION 2>/dev/null || true
while read -r t lien p; do echo "$t ${lien:-?} $(echo "$p" | tr '_-' '/+' | base64 -d 2>/dev/null | jq -c '{iat, exp}' 2>/dev/null)"; done < rotation.log | uniq -f1 -c | head

echo; echo "### fin"
