#!/usr/bin/env bash
# Chapitre 6 : le réseau. Ne supprime que ses propres objets, par leur nom :
# conteneurs un, deux, trois, postgres, redis, api, worker, web ; réseau colis ; volume colis-donnees ; image colis-web:1.0 (gardée).
cd "$(dirname "$0")"; O=$PWD/out/ch06; rm -rf $O; mkdir -p $O
run() { local n=$1; shift; echo "### $n : $*"; bash -c "$*" > $O/$n.txt 2>&1; cat $O/$n.txt; }
docker rm -f un deux trois postgres redis api worker web >/dev/null 2>&1; docker network rm colis >/dev/null 2>&1; docker volume rm colis-donnees >/dev/null 2>&1

run 01-docker0 "ip -br addr show docker0"
run 02-defaut "docker run -d --name un alpine:3.24 sleep 600 >/dev/null; docker run -d --name deux alpine:3.24 sleep 600 >/dev/null; docker inspect un deux --format '{{.Name}} {{.NetworkSettings.Networks.bridge.IPAddress}}'"
run 03-ip-dedans "docker exec un ip -4 addr show eth0; docker exec un ip route"
run 04-ping-ip "docker exec un ping -c 2 -W 1 \$(docker inspect deux --format '{{.NetworkSettings.Networks.bridge.IPAddress}}')"
run 05-ping-nom "docker exec un ping -c 1 -W 1 deux; echo \"code=\$?\""
run 06-veth "ip -br link | grep veth | head -3; docker exec un cat /sys/class/net/eth0/iflink; docker exec un cat /etc/resolv.conf | grep -v '^#'"
run 07-reseau "docker network create colis && docker network inspect colis --format '{{range .IPAM.Config}}{{.Subnet}} passerelle {{.Gateway}}{{end}}' && ip -br addr | grep -E '^br-' | tail -1"
run 08-connect "docker network connect colis un; docker run -d --name trois --network colis alpine:3.24 sleep 600 >/dev/null; docker exec un ping -c 2 -W 1 trois; docker exec trois cat /etc/resolv.conf | grep -v '^#'; docker exec trois nslookup un 127.0.0.11"
run 09-isolement "docker exec trois ping -c 1 -W 1 \$(docker inspect deux --format '{{.NetworkSettings.Networks.bridge.IPAddress}}'); echo \"code=\$?\""
run 10-none-host "docker run --rm --network none alpine:3.24 ip addr; docker run --rm --network host alpine:3.24 ip -o link | awk -F': ' '{print \$2}' | cut -d@ -f1"
docker rm -f un deux trois >/dev/null

# Colis à la main
run 11-volume-pg "docker volume create colis-donnees >/dev/null; docker run -d --name postgres --network colis -e POSTGRES_USER=colis -e POSTGRES_PASSWORD=colis -e POSTGRES_DB=colis -v colis-donnees:/var/lib/postgresql postgres:18-alpine; docker run -d --name redis --network colis redis:8.8-alpine"
run 12-api-trop-tot "docker run -d --name api --network colis -e COLIS_DB=postgresql://colis:colis@postgres:5432/colis -e COLIS_REDIS=redis://redis:6379/0 colis:1.0 >/dev/null; sleep 3; docker ps -a --filter name=^api\$ --format '{{.Names}} {{.Status}}'; docker logs api 2>&1 | tail -4"
for i in $(seq 1 30); do docker exec postgres pg_isready -U colis -d colis >/dev/null 2>&1 && break; sleep 1; done
run 13-api "docker rm -f api >/dev/null; docker run -d --name api --network colis -e COLIS_DB=postgresql://colis:colis@postgres:5432/colis -e COLIS_REDIS=redis://redis:6379/0 colis:1.0 >/dev/null; sleep 3; docker logs api 2>&1 | tail -3"
run 14-worker "docker run -d --name worker --network colis -e COLIS_DB=postgresql://colis:colis@postgres:5432/colis -e COLIS_REDIS=redis://redis:6379/0 colis:1.0 python -m colis.worker >/dev/null; sleep 2; docker logs worker"
run 15-build-web "cd ../kits/colis/web && docker build -q -t colis-web:1.0 . && docker image ls colis-web --format '{{.Repository}}:{{.Tag}} {{.Size}}'"
# web démarré sans api : on arrête l'api le temps de l'essai
run 16-web-sans-api "docker stop api >/dev/null; docker run -d --name web --network colis -p 8080:80 colis-web:1.0 >/dev/null; for i in 1 3 5 7; do sleep 2; echo \"après \$((i+1)) s : \$(docker ps -a --filter name=^web\$ --format '{{.Status}}')\"; done; docker logs web 2>&1 | tail -2; docker rm -f web >/dev/null; docker start api >/dev/null; sleep 3"
run 17-web "docker run -d --name web --network colis -p 8080:80 colis-web:1.0 >/dev/null; sleep 2; docker ps --filter network=colis --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}'"
run 18-pret "curl -s localhost:8080/api/pret; echo; curl -s localhost:8080/api/sante; echo; curl -s -m 2 localhost:8000/sante; echo \"accès direct à l'api : code=\$?\""
run 19-colis "for d in Brest Lyon Nice; do curl -s -o /dev/null -w '%{http_code} ' -X POST localhost:8080/api/colis -H 'Content-Type: application/json' -d \"{\\\"destinataire\\\":\\\"Ada Lovelace\\\",\\\"depart\\\":\\\"Paris\\\",\\\"arrivee\\\":\\\"\$d\\\",\\\"poids_kg\\\":2.5}\"; done; echo; sleep 3; docker logs worker; curl -s localhost:8080/api/colis | python3 -c 'import sys,json; [print(c[\"id\"], c[\"arrivee\"], c[\"statut\"], c[\"livraison_estimee\"]) for c in json.load(sys.stdin)]'"
run 20-inspect-reseau "docker network inspect colis --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{println}}{{end}}' | sort"
run 21-dns-api "docker exec web getent hosts api postgres redis worker"
run 22-proxy "ps -eo user,cmd | grep '[d]ocker-proxy' | grep 8080"
run 23-nat "docker run --rm --privileged --network host alpine:3.24 sh -c 'apk add -q iptables >/dev/null 2>&1; iptables -t nat -S DOCKER | grep -E \"dport 8080\"; iptables -t nat -S POSTROUTING | grep -E \"MASQUERADE\" | head -3'"
run 24-localhost "docker run -d --name un -p 127.0.0.1:8090:80 nginx:1.30-alpine >/dev/null; docker ps --filter name=^un\$ --format '{{.Ports}}'; docker rm -f un >/dev/null"
run 25-conflit "docker run -d --name deux -p 5432:5432 -e POSTGRES_PASSWORD=x postgres:18-alpine; echo \"code=\$?\"; docker rm -f deux >/dev/null"
echo "Colis tourne : web sur http://localhost:8080"
