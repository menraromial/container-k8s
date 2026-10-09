#!/usr/bin/env bash
# Outil interne : remet Colis sur l'ancien StatefulSet postgres et retire colis-pg, pour rejouer
# rejeu-ch56-colis.sh. Ne sert que tant que l'ancienne base existe.
set -u
export PATH=~/.local/opt/cours-k8s/bin:$PATH
NS=colis
MDP='{"name":"POSTGRES_PASSWORD","valueFrom":{"secretKeyRef":{"name":"colis-db","key":"POSTGRES_PASSWORD"}}}'
URL='{"name":"COLIS_DB","value":"postgresql://colis:$(POSTGRES_PASSWORD)@postgres:5432/colis"}'
for d in api worker; do
  kubectl -n $NS patch deployment $d --type=strategic -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"$d\",\"env\":[$MDP,$URL]}]}}}}"
done
kubectl -n $NS patch cronjob purge --type=strategic -p "{\"spec\":{\"suspend\":false,\"jobTemplate\":{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"purge\",\"env\":[$MDP,$URL]}]}}}}}}"
kubectl -n $NS scale deployment api --replicas=2
kubectl -n $NS annotate scaledobject worker autoscaling.keda.sh/paused-replicas- 2>/dev/null
kubectl -n $NS delete backup apres-migration --ignore-not-found
kubectl -n $NS delete cluster colis-pg --ignore-not-found --wait=true
kubectl -n $NS delete objectstore rustfs --ignore-not-found
kubectl -n $NS delete secret s3 --ignore-not-found
kubectl -n $NS delete networkpolicy colis-pg vers-colis-pg import-depuis-postgres import-vers-postgres --ignore-not-found
kubectl -n politiques patch configmap images-autorisees --type=merge -p '{"data":{"registres":"host.minikube.internal:5001/,redis:,postgres:,busybox:"}}'
kubectl -n $NS rollout status deployment/api --timeout=180s
