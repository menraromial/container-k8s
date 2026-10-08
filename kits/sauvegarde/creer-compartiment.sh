#!/usr/bin/env bash
# Crée le compartiment « velero » dans RustFS, par l'API S3 signée (curl sait signer en SigV4).
set -euo pipefail
kubectl -n velero port-forward svc/rustfs 9010:9000 >/dev/null 2>&1 &
PF=$!; trap 'kill $PF' EXIT; sleep 3
curl -s -o /dev/null -w 'PUT /velero : %{http_code}\n' -X PUT --aws-sigv4 "aws:amz:us-east-1:s3" \
  --user velero:sauvegardes-du-cours-52 http://localhost:9010/velero
curl -s --aws-sigv4 "aws:amz:us-east-1:s3" --user velero:sauvegardes-du-cours-52 http://localhost:9010/ \
  | grep -o '<Name>[^<]*</Name>'
