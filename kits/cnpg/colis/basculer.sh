#!/usr/bin/env bash
# Fait pointer l'API, le worker et la purge vers colis-pg : l'adresse du Service colis-pg-rw,
# et le mot de passe du rôle colis, rangé par CloudNativePG dans le Secret colis-pg-app.
set -euo pipefail
NS=colis
MDP='{"name":"POSTGRES_PASSWORD","valueFrom":{"secretKeyRef":{"name":"colis-pg-app","key":"password"}}}'
URL='{"name":"COLIS_DB","value":"postgresql://colis:$(POSTGRES_PASSWORD)@colis-pg-rw:5432/colis"}'
for d in api worker; do
  kubectl -n $NS patch deployment $d --type=strategic -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"$d\",\"env\":[$MDP,$URL]}]}}}}"
done
kubectl -n $NS patch cronjob purge --type=strategic -p "{\"spec\":{\"jobTemplate\":{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"purge\",\"env\":[$MDP,$URL]}]}}}}}}"
