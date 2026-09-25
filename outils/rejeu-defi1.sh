#!/usr/bin/env bash
# Défi I : vérifie le corrigé avec la grille. Ne supprime que le projet « compteur » et l'image compteur:1.0.
export DOCKER_CONFIG=$HOME/.local/opt/cours-k8s/docker-config
cd "$(dirname "$0")"; W=$PWD/out/defi1; rm -rf $W; mkdir -p $W
cp -r ../kits/defi-1/compteur/. $W/; cp ../kits/defi-1/corrige/Dockerfile ../kits/defi-1/corrige/.dockerignore ../kits/defi-1/corrige/compose.yaml $W/; cd $W
docker compose down -v >/dev/null 2>&1; docker image rm compteur:1.0 >/dev/null 2>&1
echo "== up"; docker compose up -d --build --wait 2>&1 | grep -E "Built|Healthy" | sort -u
echo "== taille"; docker image ls compteur:1.0 --format '{{.Repository}}:{{.Tag}} {{.Size}}'
echo "== utilisateur"; docker compose exec app id
echo "== visites"; for i in 1 2 3; do curl -s 127.0.0.1:3000/visite; done
echo "== ps"; docker compose ps --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}'
echo "== persistance"; docker compose down 2>&1 | tail -1; docker compose up -d --wait 2>&1 | tail -1; curl -s 127.0.0.1:3000/visite
echo "== arrêt avec init"; /usr/bin/time -f '%e s' docker compose stop app 2>&1 | tail -1; docker compose start --wait app >/dev/null 2>&1
echo "== arrêt sans init"; sed -i 's/^    init: true/    init: false/' compose.yaml; docker compose up -d app >/dev/null 2>&1; sleep 4; /usr/bin/time -f '%e s' docker compose stop app 2>&1 | tail -1; docker inspect compteur-app-1 --format 'code {{.State.ExitCode}}'; sed -i 's/^    init: false/    init: true/' compose.yaml; docker compose up -d app >/dev/null 2>&1
echo "== cache"; echo "// modification du $(date +%T)" >> server.js; docker compose build --progress=plain app 2>&1 | grep -E "npm ci|COPY server|CACHED" | head -6
echo "== écoute"; ss -ltn | grep ':3000 '
echo "== sonde"; docker compose up -d --wait app >/dev/null 2>&1; docker inspect compteur-app-1 --format "{{.State.Health.Status}}"; docker inspect compteur-app-1 --format "{{range .State.Health.Log}}{{.ExitCode}} {{.Output}}{{end}}" | head -2
