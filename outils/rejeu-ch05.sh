#!/usr/bin/env bash
# Chapitre 5 : les données. Ne supprime que ses propres objets, par leur nom
# (conteneurs ecrit, api, pg, pg2, api-dev ; volumes colis-donnees, ch05-ancien, colis-restaure et
# les volumes anonymes créés par ses propres conteneurs, relevés au passage dans $O/anonymes.txt).
cd "$(dirname "$0")"; O=$PWD/out/ch05; rm -rf $O; mkdir -p $O/travail; W=$O/travail; cp -r ../kits/colis/app $W/app
run() { local n=$1; shift; echo "### $n : $*"; (cd $W && bash -c "$*") > $O/$n.txt 2>&1; cat $O/$n.txt; }
attendre_pg() { for i in $(seq 1 30); do docker exec $1 pg_isready -U colis -d colis >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
PGENV="-e POSTGRES_USER=colis -e POSTGRES_PASSWORD=colis -e POSTGRES_DB=colis"
docker rm -f ecrit api pg pg2 api-dev >/dev/null 2>&1

run 01-diff "docker run --name ecrit alpine:3.24 sh -c 'echo \"colis 1 livré\" > /tmp/note.txt'; docker diff ecrit; docker cp ecrit:/tmp/note.txt ./note.txt; cat note.txt; docker rm ecrit; docker cp ecrit:/tmp/note.txt ./note2.txt"
run 02-api-memoire "docker run -d --name api -p 8000:8000 colis:1.0 >/dev/null; sleep 2; curl -s -o /dev/null -w 'POST : %{http_code}\n' -X POST localhost:8000/colis -H 'Content-Type: application/json' -d '{\"destinataire\":\"Ada Lovelace\",\"depart\":\"Paris\",\"arrivee\":\"Brest\",\"poids_kg\":2.5}'; curl -s localhost:8000/colis | python3 -c 'import sys,json; print(len(json.load(sys.stdin)), \"colis\")'; docker restart api >/dev/null; sleep 2; curl -s localhost:8000/colis; echo; docker rm -f api >/dev/null"
run 03-pg-sans "docker run -d --name pg $PGENV postgres:18-alpine >/dev/null; sleep 1"
attendre_pg pg
run 04-pg-table "docker exec pg psql -U colis -d colis -c \"CREATE TABLE note (texte text); INSERT INTO note VALUES ('colis 1 livré');\" && docker exec pg psql -U colis -d colis -c 'SELECT * FROM note;'"
run 05-pg-mounts "docker inspect pg --format '{{range .Mounts}}{{.Type}} {{.Name}} -> {{.Destination}}{{println}}{{end}}'"
docker inspect pg --format '{{range .Mounts}}{{.Name}}{{end}}' >> $O/anonymes.txt
run 06-pg-recree "docker rm -f pg >/dev/null; docker run -d --name pg $PGENV postgres:18-alpine >/dev/null; sleep 1"
attendre_pg pg
run 07-pg-perdu "docker exec pg psql -U colis -d colis -c 'SELECT * FROM note;'"
docker inspect pg --format '{{range .Mounts}}{{.Name}}{{end}}' >> $O/anonymes.txt
run 08-orphelins "for v in \$(cat $O/anonymes.txt); do docker volume inspect \$v --format '{{.Name}} créé le {{.CreatedAt}}'; done"
docker rm -f pg >/dev/null
run 09-ancien-chemin "docker volume create ch05-ancien >/dev/null; timeout 30 docker run --rm --name pg $PGENV -v ch05-ancien:/var/lib/postgresql/data postgres:18-alpine; echo \"code=\$?\""

run 10-volume "docker volume create colis-donnees && docker volume ls --filter name=colis && docker volume inspect colis-donnees"
run 11-pg-volume "docker run -d --name pg $PGENV -v colis-donnees:/var/lib/postgresql postgres:18-alpine >/dev/null; sleep 1"
attendre_pg pg
run 12-pg-ecrit "docker exec pg psql -U colis -d colis -c \"CREATE TABLE note (texte text); INSERT INTO note VALUES ('colis 1 livré');\""
run 13-pg-survit "docker rm -f pg; docker run -d --name pg2 $PGENV -v colis-donnees:/var/lib/postgresql postgres:18-alpine >/dev/null; sleep 1"
attendre_pg pg2
run 14-pg-relu "docker exec pg2 psql -U colis -d colis -c 'SELECT * FROM note;'; docker logs pg2 2>&1 | grep -iE 'skipping|already' | head -2"
run 15-contenu "docker run --rm -v colis-donnees:/v:ro alpine:3.24 sh -c 'ls -l /v; ls /v/18/docker | head -8; du -sh /v'"
run 16-dump "docker exec pg2 pg_dump -U colis colis > colis.sql; wc -l colis.sql; grep -A3 'COPY public.note' colis.sql"
run 17-tar "docker run --rm -v colis-donnees:/donnees:ro -v \"\$PWD\":/sauvegarde alpine:3.24 tar czf /sauvegarde/colis-donnees.tar.gz -C /donnees . ; ls -l colis-donnees.tar.gz"
run 18-restaure "docker volume create colis-restaure >/dev/null; docker run --rm -v colis-restaure:/donnees -v \"\$PWD\":/sauvegarde:ro alpine:3.24 tar xzf /sauvegarde/colis-donnees.tar.gz -C /donnees; docker run --rm -v colis-restaure:/v:ro alpine:3.24 ls /v/18/docker | head -3"
docker rm -f pg2 >/dev/null

# montage lié pour le développement
run 19-reload "docker run -d --name api-dev -p 8001:8000 -v \"\$PWD/app/colis\":/app/colis colis:1.0 uvicorn colis.app:app --host 0.0.0.0 --port 8000 --reload >/dev/null; sleep 3; curl -s localhost:8001/sante; echo"
sed -i 's/COLIS_VERSION", "1.0.0"/COLIS_VERSION", "1.0.1-dev"/' $W/app/colis/app.py; sleep 3
run 20-reload-apres "curl -s localhost:8001/sante; echo; docker logs api-dev 2>&1 | tail -8"
docker rm -f api-dev >/dev/null

# droits sur les montages liés
run 21-root-ecrit "mkdir -p sortie && docker run --rm -v \"\$PWD/sortie\":/sortie alpine:3.24 sh -c 'echo x > /sortie/par-root.txt'; ls -l sortie; rm sortie/par-root.txt; echo \"rm code=\$?\""
run 22-uid-refuse "docker run --rm -v \"\$PWD/sortie\":/sortie colis:1.0 sh -c 'echo x > /sortie/par-colis.txt'; echo \"code=\$?\"; ls -ld sortie"
run 23-user "docker run --rm --user \$(id -u):\$(id -g) -v \"\$PWD/sortie\":/sortie colis:1.0 sh -c 'id; echo x > /sortie/par-moi.txt'; ls -l sortie"
run 24-absent "docker run --rm -v \"\$PWD/absent\":/absent alpine:3.24 true; ls -ld absent"
# tmpfs et lecture seule
run 25-ro "docker run --rm --read-only alpine:3.24 touch /note.txt; echo \"code=\$?\"; docker run --rm --read-only --tmpfs /tmp alpine:3.24 sh -c 'touch /tmp/note.txt && df -h /tmp'"
run 26-api-ro "docker run -d --name api --read-only -p 8000:8000 colis:1.0 >/dev/null; sleep 2; curl -s localhost:8000/sante; echo; docker rm -f api >/dev/null"

# ménage (uniquement nos objets)
docker run --rm -v "$W":/w alpine:3.24 sh -c 'rm -rf /w/sortie /w/absent /w/colis-donnees.tar.gz' 
docker volume rm colis-donnees colis-restaure ch05-ancien $(cat $O/anonymes.txt) >/dev/null
echo "ménage fait"; docker volume ls --format '{{.Name}}' | grep -cE '^(colis|ch05)'
