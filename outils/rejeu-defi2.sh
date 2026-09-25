#!/usr/bin/env bash
# Défi II : vérifie le corrigé avec la grille. Copie de Colis dans out/defi2r, projet Compose « colis-defi2 »
# (laissé en marche, http://localhost:8080), images colis:2.0 et localhost:5001/colis/api:2.0.
cd "$(dirname "$0")"; O=$PWD/out/defi2r; rm -rf $O; mkdir -p $O
export PATH=~/.local/opt/cours-k8s/bin:$PATH DOCKER_CONFIG=~/.local/opt/cours-k8s/docker-config TRIVY_CACHE_DIR=~/.local/opt/cours-k8s/cache/trivy COSIGN_PASSWORD=mot-de-passe-du-cours
CLE=$PWD/out/ch14r/cle
cp -a ../kits/colis $O/colis && cp ../kits/defi-2/corrige/Dockerfile ../kits/defi-2/corrige/.dockerignore $O/colis/app/
sed -i 's/  image: colis:1.0/  image: colis:2.0/' $O/colis/compose.yaml
H() { local n=$1; shift; echo "### $n : $*"; (cd $O/colis && timeout 900 bash -c "$*") 2>&1 | grep -v 'docker-desktop://' > $O/$n.txt; head -c 6000 $O/$n.txt; }
docker compose -p colis-defi2 -f $O/colis/compose.yaml down >/dev/null 2>&1
H 01-taille "docker build -q -t colis:2.0 app >/dev/null; docker image ls colis --format '{{.Tag}}\t{{.Size}}'"
H 02-python "docker run --rm colis:2.0 python --version"
H 03-trivy "trivy image --quiet --severity HIGH,CRITICAL --exit-code 1 colis:2.0 >/dev/null; echo \"HIGH ou CRITICAL : code \$?\"; trivy image --quiet --format json -o t.json colis:2.0; echo \"failles au total : \$(jq '[.Results[]?.Vulnerabilities[]?] | length' t.json)\"; rm t.json"
H 04-uid "docker run --rm colis:2.0 id"
H 05-tests "docker build --progress=plain --target tests app 2>&1 | grep -E 'passed|failed' | tail -1; docker run --rm colis:2.0 python -c 'import pytest' 2>&1 | tail -1; docker run --rm colis:2.0 python -m pip --version 2>&1 | tail -1"
H 06-test-casse "sed -i 's/assert r.status_code == 201/assert r.status_code == 299/' app/tests/test_api.py; docker build --progress=plain -t colis:casse app 2>&1 | grep -E '[0-9]+ failed|ERROR: failed' | sed 's/^#[0-9]* [0-9.]* //' | tail -2; docker image ls colis:casse --format '{{.Tag}}' | grep -c casse; sed -i 's/assert r.status_code == 299/assert r.status_code == 201/' app/tests/test_api.py"
H 07-cache "echo \"# essai \$(date +%s%N)\" >> app/colis/app.py; docker build --progress=plain -t colis:2.0 app 2>&1 | grep -E 'install -r requirements.txt' -A1 | grep -E 'CACHED|DONE' | head -2; sed -i '\$d' app/colis/app.py; docker build -q -t colis:2.0 app >/dev/null"
H 08-compose "docker compose -p colis-defi2 up -d --wait 2>&1 | tail -1; docker compose -p colis-defi2 ps --format 'table {{.Service}}\t{{.Status}}'; curl -s -X POST localhost:8080/api/colis -H 'Content-Type: application/json' -d '{\"destinataire\":\"Ada Lovelace\",\"depart\":\"Paris\",\"arrivee\":\"Brest\",\"poids_kg\":2.5}'; echo; sleep 4; curl -s localhost:8080/api/colis/1; echo; docker compose -p colis-defi2 run --rm purge 2>&1 | tail -1"
H 09-multi "cd app && docker buildx build --builder cours --platform linux/amd64,linux/arm64 --sbom=true --provenance=mode=max -t localhost:5001/colis/api:2.0 --push . >/dev/null 2>&1; echo code=\$?; docker buildx imagetools inspect localhost:5001/colis/api:2.0 | grep -E '^Digest|Platform'"
H 10-signature "D=\$(docker buildx imagetools inspect localhost:5001/colis/api:2.0 --format '{{json .Manifest}}' | jq -r .digest); cosign sign --yes --key $CLE/cosign.key --signing-config $CLE/sans-journal.json --allow-http-registry localhost:5001/colis/api@\$D 2>&1 | tail -1; cosign verify --key $CLE/cosign.pub --insecure-ignore-tlog=true --allow-http-registry localhost:5001/colis/api:2.0 >/dev/null 2>&1; echo \"vérification : code \$?\""
docker rmi colis:casse >/dev/null 2>&1
