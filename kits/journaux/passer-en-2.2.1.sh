#!/usr/bin/env bash
# Colis 2.2.1 : le correctif d'instrumentation du chapitre 51, pour l'API, le worker et la purge.
set -euo pipefail
I=host.minikube.internal:5001/colis/api:2.2.1
kubectl -n colis patch configmap colis-config --type=merge -p '{"data":{"COLIS_VERSION":"2.2.1"}}'
kubectl -n colis set image deployment/api api=$I
kubectl -n colis set image deployment/worker worker=$I
kubectl -n colis set image cronjob/purge purge=$I
kubectl -n colis rollout status deployment/api
