#!/usr/bin/env bash
# Chapitre 7 : Compose. Utilise Compose 5.5.1 via une configuration Docker séparée.
# Ne supprime que ses propres objets : le Colis manuel du chapitre 6 (par nom), le projet Compose « colis »,
# les images colis:1.0 et colis-web:1.0 (reconstruites). Laisse Colis en marche à la fin.
export DOCKER_CONFIG=$HOME/.local/opt/cours-k8s/docker-config
cd "$(dirname "$0")"; O=$PWD/out/ch07; rm -rf $O; mkdir -p $O; K=$(cd ../kits/colis && pwd)
run() { local n=$1; shift; echo "### $n : $*"; (cd $K && bash -c "$*") > $O/$n.txt 2>&1; cat $O/$n.txt; }
attendre_estimes() { local debut=$(date +%s.%N); for i in $(seq 1 200); do n=$(curl -s localhost:8080/api/colis | python3 -c 'import sys,json; print(sum(c["statut"]=="enregistré" for c in json.load(sys.stdin)))'); [ "$n" = "0" ] && break; sleep 0.2; done; python3 -c "print(f'tous estimés en {$(date +%s.%N)-$debut:.1f} s')"; }
envoyer() { for i in $(seq 1 $1); do curl -s -o /dev/null -X POST localhost:8080/api/colis -H 'Content-Type: application/json' -d '{"destinataire":"Grace Hopper","depart":"Lille","arrivee":"Marseille","poids_kg":4}'; done; }

docker rm -f web worker api redis postgres >/dev/null 2>&1; docker network rm colis >/dev/null 2>&1; docker volume rm colis-donnees >/dev/null 2>&1
(cd $K && docker compose --profile outils down -v >/dev/null 2>&1)
docker image rm colis:1.0 colis-web:1.0 >/dev/null 2>&1

run 01-config "docker compose config | sed -n '/^  worker:/,/^  [a-z]*:$/p' | head -30"
run 02-up "/usr/bin/time -f 'durée : %e s' docker compose up -d --build 2>&1 | grep -v '^#\\|^ *=>\\|^$'"
run 03-ps "docker compose ps"
run 04-objets "docker network ls --filter name=colis --format '{{.Name}} {{.Driver}}'; docker volume ls --filter name=colis --format '{{.Name}}'; docker image ls --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep -E '^colis'"
run 05-pret "curl -s localhost:8080/api/pret; echo"
run 06-un-worker "$(declare -f envoyer attendre_estimes); envoyer 12; attendre_estimes"
run 07-scale "docker compose up -d --scale worker=3 2>&1; docker compose ps worker --format 'table {{.Name}}\t{{.Status}}'"
run 08-trois-workers "$(declare -f envoyer attendre_estimes); envoyer 12; attendre_estimes; docker compose logs worker --no-log-prefix 2>/dev/null | grep -c 'Lille -> Marseille'; docker compose logs worker 2>/dev/null | grep 'Lille -> Marseille' | tail -12 | cut -d'|' -f1 | sort | uniq -c"
run 09-logs "docker compose logs --tail 3 worker"
run 10-kill "docker compose exec --index 1 worker sh -c 'kill 1'; sleep 3; docker compose ps worker --format 'table {{.Name}}\t{{.Status}}'; docker inspect colis-worker-1 --format 'redémarrages : {{.RestartCount}}'; docker compose logs --tail 3 worker 2>/dev/null | grep 'worker-1'"
run 11-purge "docker compose run --rm purge 2>&1 | grep -v Container"
run 12-psql "docker compose exec postgres psql -U colis -d colis -c 'SELECT statut, count(*) FROM colis GROUP BY statut;'"
run 13-down "docker compose down 2>&1; docker volume ls --filter name=colis --format '{{.Name}}'"
run 14-up-again "docker compose up -d 2>&1 | tail -3; sleep 1; curl -s localhost:8080/api/colis | python3 -c 'import sys,json; print(len(json.load(sys.stdin)), \"colis retrouvés\")'"
run 15-sans-env "mv .env .env.cache; docker compose config >/dev/null; echo \"code=\$?\"; mv .env.cache .env"
run 16-down-v "docker compose down -v 2>&1"
run 17-up-final "docker compose up -d 2>&1 | tail -2; docker compose ps --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}'"
echo "Colis tourne : http://localhost:8080"
