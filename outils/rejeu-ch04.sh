#!/usr/bin/env bash
# Chapitre 4 : écrire un Dockerfile. Travaille dans une copie de kits/colis/app ;
# ne supprime que ses propres conteneurs (ch04-*) et images (colis:etape*).
cd "$(dirname "$0")"; O=$PWD/out/ch04; rm -rf $O; mkdir -p $O; A=$O/app
cp -r ../kits/colis/app $A; rm -f $A/Dockerfile $A/.dockerignore
run() { local n=$1; shift; echo "### $n : $*"; (cd $A && bash -c "$*") > $O/$n.txt 2>&1; cat $O/$n.txt; }
docker rm -f ch04-api ch04-shell ch04-exec ch04-print ch04-print2 >/dev/null 2>&1

# étape 1 : Dockerfile naïf
cat > $A/Dockerfile <<'DF'
FROM python:3.14-slim
WORKDIR /app
COPY . .
RUN pip install -r requirements.txt
CMD uvicorn colis.app:app --host 0.0.0.0 --port 8000
DF
run 01-build1 "/usr/bin/time -f 'durée : %e s' docker build --no-cache -t colis:etape1 . 2>&1 | grep -v '^View build details'"
run 02-size1 "docker image ls colis:etape1 --format '{{.Repository}}:{{.Tag}} {{.Size}}'"
run 03-run1 "docker run -d --name ch04-api -p 8000:8000 colis:etape1 && sleep 3 && curl -s localhost:8000/sante; echo; curl -s -X POST localhost:8000/colis -H 'Content-Type: application/json' -d '{\"destinataire\":\"Ada Lovelace\",\"depart\":\"Paris\",\"arrivee\":\"Brest\",\"poids_kg\":2.5}'; echo; curl -s localhost:8000/colis/1; echo"
run 04-logs1 "docker logs ch04-api"
run 05-pid1-shell "docker exec ch04-api cat /proc/1/cmdline | tr '\0' ' '; echo; docker top ch04-api -o pid,ppid,cmd"
run 06-stop1 "/usr/bin/time -f '%e s' docker stop ch04-api; docker inspect ch04-api --format 'code {{.State.ExitCode}}'"
docker rm -f ch04-api >/dev/null
# modification du code : tout est réinstallé
echo "# correction du $(date '+%F %T')" >> $A/colis/app.py
run 07-rebuild1 "/usr/bin/time -f 'durée : %e s' docker build --progress=plain -t colis:etape1 . 2>&1 | grep -E '^#[0-9]+ \[|CACHED|DONE|durée' "

# étape 2 : dépendances d'abord
cat > $A/Dockerfile <<'DF'
FROM python:3.14-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY colis/ colis/
CMD ["uvicorn", "colis.app:app", "--host", "0.0.0.0", "--port", "8000"]
DF
run 08-build2 "/usr/bin/time -f 'durée : %e s' docker build --progress=plain --no-cache -t colis:etape2 . 2>&1 | grep -E '^#[0-9]+ \[|CACHED|DONE [0-9.]+s$|durée' "
sleep 1; echo "# correction du $(date '+%F %T')" >> $A/colis/app.py
run 09-rebuild2 "/usr/bin/time -f 'durée : %e s' docker build --progress=plain -t colis:etape2 . 2>&1 | grep -E '^#[0-9]+ \[|CACHED|DONE [0-9.]+s$|durée' "
run 10-pid1-exec "docker run -d --name ch04-exec colis:etape2 >/dev/null && sleep 2 && docker exec ch04-exec cat /proc/1/cmdline | tr '\0' ' '; echo; /usr/bin/time -f '%e s' docker stop ch04-exec; docker inspect ch04-exec --format 'code {{.State.ExitCode}}'; docker logs ch04-exec 2>&1 | tail -4"
# forme shell avec deux commandes : le shell reste PID 1
run 11-shell-2cmd "docker run -d --name ch04-shell colis:etape2 sh -c 'echo démarrage de Colis && uvicorn colis.app:app --host 0.0.0.0 --port 8000' >/dev/null && sleep 2 && docker exec ch04-shell cat /proc/1/cmdline | tr '\0' ' '; echo; /usr/bin/time -f '%e s' docker stop ch04-shell; docker inspect ch04-shell --format 'code {{.State.ExitCode}}'"

# contexte de construction : un .venv dans le dossier
python3 -m venv $A/.venv >/dev/null && $A/.venv/bin/pip install -q -r $A/requirements.txt >/dev/null 2>&1
run 12-du-venv "du -sh .venv; du -sh --exclude=.venv ."
cat > $A/Dockerfile <<'DF'
FROM python:3.14-slim
WORKDIR /app
COPY . .
RUN pip install -r requirements.txt
CMD ["uvicorn", "colis.app:app", "--host", "0.0.0.0", "--port", "8000"]
DF
run 13-context-sans "docker build --progress=plain --no-cache -t colis:etape3 . 2>&1 | grep -E 'transferring context|load build context' | head -4; docker run --rm colis:etape3 sh -c 'ls -a /app; du -sh /app'"
cat > $A/.dockerignore <<'DI'
.venv/
__pycache__/
.pytest_cache/
tests/
requirements-dev.txt
Dockerfile
.dockerignore
DI
run 14-context-avec "docker build --progress=plain --no-cache -t colis:etape3 . 2>&1 | grep -E 'transferring context' | head -2; docker run --rm colis:etape3 sh -c 'ls -a /app; du -sh /app'"

# sortie tamponnée de Python
run 15-print "docker run -d --name ch04-print python:3.14-slim python -c 'import time; print(\"colis 1 estimé\"); time.sleep(20)' >/dev/null; sleep 3; echo \"journal : [\$(docker logs ch04-print)]\"; docker run -d --name ch04-print2 -e PYTHONUNBUFFERED=1 python:3.14-slim python -c 'import time; print(\"colis 1 estimé\"); time.sleep(20)' >/dev/null; sleep 3; echo \"journal avec PYTHONUNBUFFERED=1 : [\$(docker logs ch04-print2)]\"; docker rm -f ch04-print ch04-print2 >/dev/null"

# étape finale : l'image de Colis
cp ../kits/colis/app/Dockerfile ../kits/colis/app/.dockerignore $A/ 2>/dev/null
run 16-build-final "/usr/bin/time -f 'durée : %e s' docker build --no-cache -t colis:1.0 . 2>&1 | grep -v '^View build details'"
run 17-inspect-final "docker image ls colis --format '{{.Repository}}:{{.Tag}} {{.Size}}'; docker image inspect colis:1.0 --format 'User={{.Config.User}} Cmd={{json .Config.Cmd}} Ports={{json .Config.ExposedPorts}}'; docker image inspect colis:1.0 --format '{{json .Config.Labels}}' | python3 -m json.tool; docker image inspect colis:1.0 --format '{{range .Config.Env}}{{println .}}{{end}}'"
run 18-run-final "docker run -d --name ch04-api -p 8000:8000 colis:1.0 >/dev/null && sleep 3 && docker exec ch04-api id && curl -s localhost:8000/pret; echo; curl -s localhost:8000/villes; echo"
run 19-worker-purge "docker run --rm colis:1.0 python -m colis.purge; echo \"code=\$?\"; docker run --rm colis:1.0 python -m colis.worker; echo \"code=\$?\""
run 20-history "docker image history colis:1.0 --format 'table {{.CreatedBy}}\t{{.Size}}' | cut -c1-110 | head -14"
run 21-stop-final "/usr/bin/time -f '%e s' docker stop ch04-api; docker inspect ch04-api --format 'code {{.State.ExitCode}}'"
docker rm -f ch04-api ch04-shell ch04-exec >/dev/null 2>&1
docker image rm colis:etape1 colis:etape2 colis:etape3 >/dev/null 2>&1
echo "ménage fait"
