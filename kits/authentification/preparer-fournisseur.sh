#!/usr/bin/env bash
# Clé de signature du fournisseur, et certificat TLS pour 192.168.49.1 signé par une petite CA.
set -euo pipefail
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out idp.key 2>/dev/null
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 \
  -subj "/CN=CA du fournisseur du cours" -keyout idp-ca.key -out idp-ca.crt 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=192.168.49.1" \
  -keyout https.key -out https.csr 2>/dev/null
openssl x509 -req -in https.csr -CA idp-ca.crt -CAkey idp-ca.key -days 30 \
  -extfile <(printf 'subjectAltName=IP:192.168.49.1\nextendedKeyUsage=serverAuth') -out https.crt 2>/dev/null
rm https.csr
echo "idp.key, idp-ca.crt, https.crt et https.key prêts"
