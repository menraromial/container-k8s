#!/usr/bin/env bash
# Configure le Vault de développement : un secret pour Colis, l'authentification Kubernetes,
# une politique de lecture et un rôle pour le ServiceAccount eso-colis du namespace colis.
set -euo pipefail
v() { kubectl -n coffre exec -i deploy/vault -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=jeton-racine-du-cours vault "$@"; }
v kv put secret/colis/api jeton-partenaire="${JETON:-jeton-partenaire-v1}"
v auth enable kubernetes || true
# Vault tourne dans le cluster : il utilise son propre jeton et la CA montés dans son Pod
v write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc:443
v policy write colis-lecture - <<'POLITIQUE'
path "secret/data/colis/*" {
  capabilities = ["read"]
}
POLITIQUE
v write auth/kubernetes/role/colis-eso \
  bound_service_account_names=eso-colis \
  bound_service_account_namespaces=colis \
  audience=vault \
  policies=colis-lecture \
  ttl=10m
