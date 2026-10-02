#!/usr/bin/env bash
# Greffon d'authentification pour kubectl : demande un jeton au fournisseur du cours
# et le rend sous la forme d'un ExecCredential, comme le ferait kubelogin.
set -euo pipefail
cd "$(dirname "$0")"
JETON=$(python3 fournisseur.py emettre "${COURRIEL:-lea@colis.example}" developpeurs --duree 900)
FIN=$(date -u -d @$(( $(date +%s) + 900 )) +%Y-%m-%dT%H:%M:%SZ)
printf '{"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential","status":{"token":"%s","expirationTimestamp":"%s"}}\n' "$JETON" "$FIN"
