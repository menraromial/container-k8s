#!/usr/bin/env bash
# Active les traces de Colis dans l'API et le worker : adresse du collecteur, nom et espace de service
# (les mêmes que ceux que le collecteur donne aux journaux, pour passer de l'un à l'autre).
set -euo pipefail
C=http://collecteur.supervision.svc:4318
kubectl -n colis set env deployment/api OTEL_EXPORTER_OTLP_ENDPOINT=$C \
  OTEL_SERVICE_NAME=api OTEL_RESOURCE_ATTRIBUTES=service.namespace=colis
kubectl -n colis set env deployment/worker OTEL_EXPORTER_OTLP_ENDPOINT=$C \
  OTEL_SERVICE_NAME=worker OTEL_RESOURCE_ATTRIBUTES=service.namespace=colis
kubectl -n colis rollout status deployment/api
