#!/usr/bin/env bash
# Chapitre 2 : vérification des exercices ; ne supprime que ses propres conteneurs
echo "== ex1"; docker run -d --name eclair alpine:3.24 >/dev/null; sleep 1; docker ps -a --filter name=eclair --format '{{.Names}} {{.Status}}'
docker rm -f eclair >/dev/null; docker run -d --name eclair alpine:3.24 sleep infinity >/dev/null; docker ps --filter name=eclair --format '{{.Names}} {{.Status}}'
echo "== ex2"; docker run -d --name web1 -p 8081:80 nginx:1.30-alpine >/dev/null; docker run -d --name web2 -p 8082:80 nginx:1.30-alpine >/dev/null
docker exec web2 sh -c 'echo "<h1>Je suis web2</h1>" > /usr/share/nginx/html/index.html'; sleep 1
curl -s localhost:8081 | grep -o '<title>.*</title>'; curl -s localhost:8082
docker run -d --name web3 -p 8081:80 nginx:1.30-alpine; echo "code=$?"; docker ps -a --filter name=web3 --format '{{.Names}} {{.Status}}'
echo "== ex3"
docker run --rm alpine:3.24 false; echo "false code=$?"
docker run --rm alpine:3.24 ls /inexistant; echo "ls code=$?"
docker run --rm alpine:3.24 sh -c 'kill -TERM $$'; echo "kill code=$?"
docker run --rm alpine:3.24 /bin 2>&1 | head -1; docker run --rm alpine:3.24 /bin >/dev/null 2>&1; echo "/bin code=$?"
echo "== ex4"; docker run -d --name lent alpine:3.24 sh -c 'while true; do sleep 1; done' >/dev/null; /usr/bin/time -f '%e s' docker stop lent; docker inspect lent --format 'code {{.State.ExitCode}}'
docker rm -f lent >/dev/null; docker run -d --init --name lent alpine:3.24 sh -c 'while true; do sleep 1; done' >/dev/null; /usr/bin/time -f '%e s' docker stop lent; docker inspect lent --format 'code {{.State.ExitCode}}'
docker rm -f lent >/dev/null; docker run -d --name lent alpine:3.24 sh -c 'trap "exit 0" TERM; while true; do sleep 1; done' >/dev/null; sleep 1; /usr/bin/time -f '%e s' docker stop lent; docker inspect lent --format 'code {{.State.ExitCode}}'
echo "== uid"; getent passwd 101; docker run --rm nginx:1.30-alpine id nginx; docker run --rm nginx:1.30-alpine ls -l /var/log/nginx
docker rm -f eclair web1 web2 web3 lent >/dev/null 2>&1; echo "ménage fait"
