#!/usr/bin/env bash
# Corrigé du défi VI : supprime ce qu'un apply ne retire pas, crée le Secret, applique le manifeste corrigé.
set -euo pipefail
NS=colis-audit
D=$(dirname "$0")
kubectl -n $NS delete rolebinding equipe-et-robots --ignore-not-found
kubectl -n $NS delete secret jeton-ci --ignore-not-found
# nouveau mot de passe : l'ancien a vécu en clair dans une ConfigMap, il est compromis
kubectl -n $NS create secret generic colis-db --from-literal=POSTGRES_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f $D/colis-audit-corrige.yaml
for d in postgres redis api web; do kubectl -n $NS rollout status deployment/$d --timeout=240s; done
