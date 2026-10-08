#!/usr/bin/env bash
# Défi VII : rejoue la « mise en production » d'un collègue sur Colis, puis envoie du trafic.
# Ce script contient la réponse du défi : ne le lisez qu'après avoir rendu votre post-mortem.
# Il ne modifie que trois objets du namespace colis, et note l'heure de début dans debut-incident.
# Usage : ./declencher.sh [durée du trafic en secondes, 900 par défaut]
set -euo pipefail
DUREE=${1:-900}
D=$(cd "$(dirname "$0")" && pwd)
QUI=menage-ressources   # le gestionnaire de champs qu'on retrouvera dans managedFields

date -u +%Y-%m-%dT%H:%M:%SZ > "$D/debut-incident"
# « le worker n'utilise presque rien, l'API réserve trop »
kubectl -n colis patch deployment worker --field-manager=$QUI --type=json -p '[
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources",
   "value": {"requests": {"cpu": "50m", "memory": "48Mi"}, "limits": {"memory": "48Mi"}}}]' >/dev/null
kubectl -n colis patch deployment api --field-manager=$QUI --type=json -p '[
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/requests/memory", "value": "128Mi"}]' >/dev/null
# « la base n'a qu'un client, l'API »
kubectl -n colis patch networkpolicy postgres --field-manager=$QUI --type=json -p '[
  {"op": "replace", "path": "/spec/ingress/0/from",
   "value": [{"podSelector": {"matchLabels": {"app.kubernetes.io/name": "api"}}}]}]' >/dev/null

echo "mise en production faite à $(date +%T) ; trafic pendant $DUREE s (Ctrl-C pour l'arrêter plus tôt)"
python3 "$D/charge.py" --duree "$DUREE" --debit 6
