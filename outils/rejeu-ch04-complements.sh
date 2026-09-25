#!/usr/bin/env bash
# Chapitre 4, compléments : ne supprime que ses propres conteneurs (ch04b-*) et images (colis:essai*)
cd "$(dirname "$0")"; W=$PWD/out/ch04b; rm -rf $W; mkdir -p $W; cp -r ../kits/colis/app $W/app; cd $W/app
docker rm -f ch04b-exec ch04b-expose >/dev/null 2>&1
echo "== exec dans sh -c"; docker run -d --name ch04b-exec colis:1.0 sh -c 'echo démarrage de Colis && exec uvicorn colis.app:app --host 0.0.0.0 --port 8000' >/dev/null; sleep 2; docker exec ch04b-exec cat /proc/1/cmdline | tr '\0' ' '; echo; /usr/bin/time -f '%e s' docker stop ch04b-exec; docker inspect ch04b-exec --format 'code {{.State.ExitCode}}'
echo "== id root"; docker run --rm python:3.14-slim id
echo "== expose"; docker run -d --name ch04b-expose colis:1.0 >/dev/null; sleep 2; docker port ch04b-expose; echo "docker port : [$(docker port ch04b-expose)]"; docker ps --filter name=ch04b-expose --format '{{.Ports}}'; curl -s -m 2 localhost:8000/sante; echo "curl code=$?"
echo "== copy manquant"; printf 'FROM python:3.14-slim\nCOPY introuvable.txt .\n' > Dockerfile.erreur; docker build -f Dockerfile.erreur -t colis:essai . 2>&1 | grep -vE '^#[0-9]+ (\[internal\]|DONE|transferring)|^$|View build' | tail -12
echo "== ignoré"; printf 'FROM python:3.14-slim\nCOPY tests/ tests/\n' > Dockerfile.ignore; docker build -f Dockerfile.ignore -t colis:essai . 2>&1 | grep -E 'ERROR|error|not found|excluded' | head -4
echo "== entrypoint"; cat > Dockerfile.outil <<'DF'
FROM colis:1.0
ENTRYPOINT ["python", "-m"]
CMD ["colis.purge"]
DF
docker build -q -f Dockerfile.outil -t colis:essai-outil . >/dev/null && docker run --rm colis:essai-outil; docker run --rm colis:essai-outil colis.worker; echo "code=$?"
echo "== tests"; docker run --rm -v "$PWD":/src:ro -w /src -e PYTHONDONTWRITEBYTECODE=1 python:3.14-slim sh -c 'pip install -q --root-user-action=ignore -r requirements-dev.txt && python -m pytest -q -p no:cacheprovider' 2>&1 | tail -3
echo "== taille sans PIP_NO_CACHE_DIR"; sed 's/    PIP_NO_CACHE_DIR=1 \\//' ../../../../kits/colis/app/Dockerfile > Dockerfile.cache; grep -c PIP_NO_CACHE Dockerfile.cache; docker build -q -f Dockerfile.cache -t colis:essai-cache . >/dev/null; docker image ls --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep -E '^colis:(1.0|essai-cache)'
docker rm -f ch04b-exec ch04b-expose >/dev/null 2>&1; docker image rm colis:essai colis:essai-outil colis:essai-cache >/dev/null 2>&1; echo "ménage fait"
