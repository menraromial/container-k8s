#!/usr/bin/env bash
# Passe Colis (namespace colis) à la version 2.2 : métriques, journaux JSON, estimation corrigée.
set -euo pipefail
I=host.minikube.internal:5001/colis/api:2.2
kubectl -n colis patch configmap colis-config --type=merge -p '{"data":{"COLIS_VERSION":"2.2.0"}}'
kubectl -n colis set image deployment/api api=$I
# le worker expose ses métriques sur le port 9101 : on le déclare, et on lui donne un nom
kubectl -n colis patch deployment worker --type=json -p "[
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"$I\"},
  {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/ports\",
   \"value\":[{\"name\":\"metriques\",\"containerPort\":9101}]}]"
kubectl -n colis set image cronjob/purge purge=$I
kubectl -n colis label service api app.kubernetes.io/name=api --overwrite
kubectl -n colis rollout status deployment/api
