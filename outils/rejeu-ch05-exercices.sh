#!/usr/bin/env bash
# Chapitre 5, exercices. Ne supprime que ses propres objets (conteneurs ch05x-*, volumes ch05x-*).
cd "$(dirname "$0")"; W=$PWD/out/ch05x; rm -rf $W; mkdir -p $W; cd $W
PGENV="-e POSTGRES_USER=colis -e POSTGRES_PASSWORD=colis -e POSTGRES_DB=colis"
attendre_pg() { for i in $(seq 1 30); do docker exec $1 pg_isready -U colis -d colis >/dev/null 2>&1 && return 0; sleep 1; done; }
docker rm -f ch05x-pg ch05x-pg2 ch05x-web >/dev/null 2>&1
echo "== ex1 restauration"
docker run -d --name ch05x-pg $PGENV -v ch05x-a:/var/lib/postgresql postgres:18-alpine >/dev/null; attendre_pg ch05x-pg
docker exec ch05x-pg psql -q -U colis -d colis -c "CREATE TABLE note (texte text); INSERT INTO note VALUES ('colis 1 livré'), ('colis 2 en route');"
docker exec ch05x-pg pg_dump -U colis colis > colis.sql
docker run -d --name ch05x-pg2 $PGENV -v ch05x-b:/var/lib/postgresql postgres:18-alpine >/dev/null; attendre_pg ch05x-pg2
docker exec -i ch05x-pg2 psql -q -U colis -d colis < colis.sql; docker exec ch05x-pg2 psql -U colis -d colis -c 'SELECT * FROM note;'
echo "== ex3 nginx lecture seule"; mkdir site; echo '<h1>Version 1</h1>' > site/index.html
docker run -d --name ch05x-web -p 8085:80 -v "$PWD/site":/usr/share/nginx/html:ro nginx:1.30-alpine >/dev/null; sleep 1; curl -s localhost:8085
echo '<h1>Version 2</h1>' > site/index.html; curl -s localhost:8085
docker exec ch05x-web sh -c 'echo pirate > /usr/share/nginx/html/index.html'; echo "code=$?"
echo "== ex4 nom ou chemin"; docker run --rm -v ch05x-nom:/x alpine:3.24 true; docker volume ls --filter name=ch05x-nom --format '{{.Name}}'; docker run --rm -v ./ch05x-chemin:/x alpine:3.24 true; ls -ld ch05x-chemin
echo "== ex5 mount"; docker run --rm --mount type=bind,src="$PWD/absent2",dst=/x alpine:3.24 true; echo "code=$?"; ls -d absent2 2>&1
docker rm -f ch05x-pg ch05x-pg2 ch05x-web >/dev/null; docker volume rm ch05x-a ch05x-b ch05x-nom >/dev/null
docker run --rm -v "$W":/w alpine:3.24 rm -rf /w/ch05x-chemin; echo "ménage fait"
