#!/usr/bin/env bash
# Retire de Colis tout ce que le chapitre 44 ajoute (champs de sécurité, volumes ajoutés,
# étiquettes Pod Security), pour rejouer le chapitre depuis le début.
set -euo pipefail
NS=${NS:-colis}
for e in pod-security.kubernetes.io/enforce pod-security.kubernetes.io/enforce-version \
         pod-security.kubernetes.io/warn pod-security.kubernetes.io/warn-version \
         pod-security.kubernetes.io/audit pod-security.kubernetes.io/audit-version; do
  kubectl label ns "$NS" "$e-" >/dev/null 2>&1 || true
done
# Volumes ajoutés par le chapitre. Le volume persistant de PostgreSQL s'appelle « donnees » :
# ce nom n'est retiré que du Deployment redis (première version du chapitre).
FILTRE='
  (if .metadata.name == "redis" then ["cache","run","socket","tmp","donnees-redis","donnees"]
   else ["cache","run","socket","tmp","donnees-redis"] end) as $ajoutes
  | def nettoyer:
    del(.automountServiceAccountToken, .securityContext)
    | .containers |= map(del(.securityContext)
        | if .volumeMounts then .volumeMounts |= map(select(.name as $n | $ajoutes | index($n) | not)) else . end
        | if .volumeMounts == [] then del(.volumeMounts) else . end)
    | if .volumes then .volumes |= map(select(.name as $n | $ajoutes | index($n) | not)) else . end
    | if .volumes == [] then del(.volumes) else . end;
  if .kind == "CronJob" then .spec.jobTemplate.spec.template.spec |= nettoyer
  else .spec.template.spec |= nettoyer end
  | del(.metadata.resourceVersion, .metadata.managedFields, .status)'
for o in deployment/api deployment/api-canari deployment/worker deployment/web deployment/redis statefulset/postgres cronjob/purge; do
  kubectl -n "$NS" get "$o" -o json | jq "$FILTRE" | kubectl replace -f - >/dev/null
done
for o in deployment/api deployment/api-canari deployment/web deployment/redis statefulset/postgres; do
  kubectl -n "$NS" rollout status "$o" --timeout=300s >/dev/null
done
echo "Colis remis dans son état d'avant le chapitre 44"
