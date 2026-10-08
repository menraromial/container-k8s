#!/usr/bin/env bash
# Avant la partie VIII : retirer, par leur nom, les outils de la partie VII dont la suite ne se sert plus.
# Prometheus, Alertmanager et le récepteur pager restent : le chapitre 58 s'appuie sur les métriques.
set -u

# 1. Colis cesse d'envoyer ses traces : sans OTEL_EXPORTER_OTLP_ENDPOINT, il ne charge pas
#    l'exportateur (chapitre 51). Les Pods de l'API et du worker sont remplacés.
kubectl -n colis set env deployment/api deployment/worker \
  OTEL_EXPORTER_OTLP_ENDPOINT- OTEL_SERVICE_NAME- OTEL_RESOURCE_ATTRIBUTES-
kubectl -n colis delete networkpolicy traces --ignore-not-found
kubectl -n colis delete configmap tableau-colis --ignore-not-found

# 2. Le collecteur, Tempo et Loki, puis leurs volumes : un StatefulSet garde ses réclamations
#    de volume quand Helm le désinstalle.
helm -n supervision uninstall collecteur tempo loki
kubectl -n supervision delete pvc storage-loki-0 storage-tempo-0 --ignore-not-found

# 3. Grafana : la même version du chart, les mêmes valeurs, sauf Grafana.
helm -n supervision upgrade supervision oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack \
  --version 92.1.0 --reuse-values --set grafana.enabled=false

# 4. Les volumes persistants libérés (Released) dont la réclamation a disparu
kubectl get pv -o json | jq -r '.items[] | select(.status.phase == "Released") | .metadata.name' |
  while read -r pv; do kubectl delete pv "$pv"; done
