#!/usr/bin/env bash
# Fabrique un utilisateur à certificat client et son kubeconfig, par l'API CertificateSigningRequest.
#   nouvel-utilisateur.sh NOM [GROUPE...]
# Variables : DUREE (secondes, 86400 par défaut), NS (namespace du contexte, default par défaut)
set -euo pipefail
NOM=$1; shift
SUJET="/CN=$NOM"
for g in "$@"; do SUJET="$SUJET/O=$g"; done

openssl genpkey -algorithm ed25519 -out "$NOM.key"
openssl req -new -key "$NOM.key" -subj "$SUJET" -out "$NOM.csr"

kubectl apply -f - <<FIN
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: $NOM
spec:
  request: $(base64 -w0 "$NOM.csr")
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: ${DUREE:-86400}
  usages: [client auth]
FIN
kubectl certificate approve "$NOM"
until [ -n "$(kubectl get csr "$NOM" -o jsonpath='{.status.certificate}')" ]; do sleep 1; done
kubectl get csr "$NOM" -o jsonpath='{.status.certificate}' | base64 -d > "$NOM.crt"

K="$NOM.kubeconfig"
rm -f "$K"
SERVEUR=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > ca-cluster.crt
[ -s ca-cluster.crt ] || cp "$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.certificate-authority}')" ca-cluster.crt
kubectl --kubeconfig="$K" config set-cluster cours --server="$SERVEUR" --certificate-authority=ca-cluster.crt --embed-certs >/dev/null
kubectl --kubeconfig="$K" config set-credentials "$NOM" --client-certificate="$NOM.crt" --client-key="$NOM.key" --embed-certs >/dev/null
kubectl --kubeconfig="$K" config set-context "$NOM@cours" --cluster=cours --user="$NOM" --namespace="${NS:-default}" >/dev/null
kubectl --kubeconfig="$K" config use-context "$NOM@cours" >/dev/null
rm -f "$NOM.csr" ca-cluster.crt
echo "$K prêt : $(openssl x509 -in "$NOM.crt" -noout -subject), valable jusqu'au $(openssl x509 -in "$NOM.crt" -noout -enddate | cut -d= -f2)"
