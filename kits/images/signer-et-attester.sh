#!/usr/bin/env bash
# Analyse une image du registre du cours avec Trivy, la signe, et attache l'analyse comme attestation signée.
#   signer-et-attester.sh DÉPÔT:ÉTIQUETTE      (ex. colis/web:1.1)
# Variables : CLE (dossier de cosign.key, par défaut celui du chapitre 14), COSIGN_PASSWORD.
# Signature et attestation au format classique (étiquettes .sig et .att) : Kyverno 1.19 ne trouve pas
# les signatures au nouveau format sur un registre sans API referrers (kyverno#16664).
set -euo pipefail
IMAGE=$1
CLE=${CLE:-$HOME/these/docs/container_k8s/outils/out/ch14r/cle}
REGISTRE=localhost:5001
ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
EMPREINTE=$(curl -sI -H "Accept: $ACCEPT" "http://$REGISTRE/v2/${IMAGE%%:*}/manifests/${IMAGE##*:}" \
  | awk 'tolower($1) == "docker-content-digest:" {print $2}' | tr -d '\r')
[ -n "$EMPREINTE" ] || { echo "image introuvable : $IMAGE" >&2; exit 1; }
REF="$REGISTRE/${IMAGE%%:*}@$EMPREINTE"
ANALYSE=$(mktemp --suffix=.json)
trivy image --cache-dir ~/.local/opt/cours-k8s/cache/trivy --format cosign-vuln --output "$ANALYSE" --quiet "$REF"
echo "$IMAGE ($EMPREINTE) : $(jq -c '[.scanner.result.Results[]?.Vulnerabilities[]?.Severity] | group_by(.) | map({(.[0]): length}) | add // {}' "$ANALYSE")"
OPTS=(--yes --key "$CLE/cosign.key" --new-bundle-format=false --use-signing-config=false --tlog-upload=false --allow-http-registry)
cosign sign "${OPTS[@]}" "$REF" 2>&1 | grep -v -i -E 'warning|note' | tail -1
cosign attest "${OPTS[@]}" --type vuln --predicate "$ANALYSE" "$REF" 2>&1 | grep -v -i -E 'warning|note' | tail -1
rm -f "$ANALYSE"
