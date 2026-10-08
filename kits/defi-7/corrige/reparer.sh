#!/usr/bin/env bash
# Corrigé du défi VII : rend au worker sa mémoire, puis à la base ses deux autres clients.
# La requête mémoire de l'API (128 Mi) reste : l'API en utilise 70 à 80 Mi, ce n'est pas une cause.
set -euo pipefail
# 1. le worker : requête au-dessus de son pic mesuré (57 Mi), limite à deux fois la requête
kubectl -n colis patch deployment worker --type=json -p '[
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources",
   "value": {"requests": {"cpu": "50m", "memory": "96Mi"}, "limits": {"memory": "192Mi"}}}]'
# 2. la base : l'API, le worker et la purge, comme dans kits/politiques/40-postgres.yaml
kubectl -n colis patch networkpolicy postgres --type=json -p '[
  {"op": "replace", "path": "/spec/ingress/0/from",
   "value": [{"podSelector": {"matchExpressions": [{"key": "app.kubernetes.io/name", "operator": "In",
              "values": ["api", "api-canari", "worker", "purge"]}]}}]}]'
