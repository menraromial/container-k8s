#!/usr/bin/env bash
# Compare ce que permettent les rôles view, edit et admin dans un namespace d'essai.
# Usage : roles-par-defaut.sh NAMESPACE
set -u
NS=${1:-ch43}
for r in view edit admin; do
  kubectl -n "$NS" create sa "sa-$r" >/dev/null 2>&1
  kubectl -n "$NS" create rolebinding "sa-$r" --clusterrole="$r" --serviceaccount="$NS:sa-$r" >/dev/null 2>&1
done
printf "%-32s %-5s %-5s %-5s\n" action view edit admin
while read -r verbe ressource; do
  printf "%-32s" "$verbe $ressource"
  for r in view edit admin; do
    printf " %-5s" "$(kubectl auth can-i "$verbe" "$ressource" -n "$NS" --as="system:serviceaccount:$NS:sa-$r")"
  done
  echo
done <<'LISTE'
list pods
get pods/log
get secrets
create pods
create pods/exec
create serviceaccounts/token
impersonate serviceaccounts
patch deployments
create roles
create rolebindings
create resourcequotas
LISTE
