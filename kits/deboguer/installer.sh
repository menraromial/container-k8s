#!/usr/bin/env bash
# Installe la copie cassée de Colis dans le namespace ch48 (mot de passe tiré au hasard).
set -euo pipefail
cd "$(dirname "$0")"
kubectl apply -f colis-panne/00-namespace.yaml
kubectl -n ch48 create secret generic colis-db \
  --from-literal=POSTGRES_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f colis-panne/
