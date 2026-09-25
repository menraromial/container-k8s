#!/usr/bin/env bash
# Chapitre 6, exercices. Ne supprime que ses propres objets (ch06x-*).
docker rm -f ch06x-base ch06x-app ch06x-proxy ch06x-dehors >/dev/null 2>&1; docker network rm ch06x-front ch06x-back >/dev/null 2>&1
echo "== ex1 deux réseaux"
docker network create ch06x-front >/dev/null; docker network create ch06x-back >/dev/null
docker run -d --name ch06x-app --network ch06x-back nginx:1.30-alpine >/dev/null
docker run -d --name ch06x-proxy --network ch06x-front alpine:3.24 sleep 600 >/dev/null; docker network connect ch06x-back ch06x-proxy
docker run -d --name ch06x-dehors --network ch06x-front alpine:3.24 sleep 600 >/dev/null; sleep 1
docker exec ch06x-proxy wget -qO- -T 2 http://ch06x-app | grep -o '<title>.*</title>'
docker exec ch06x-dehors wget -qO- -T 2 http://ch06x-app; echo "code=$?"
docker inspect ch06x-proxy --format '{{range $n, $v := .NetworkSettings.Networks}}{{$n}} {{$v.IPAddress}}{{println}}{{end}}'
echo "== ex2 alias"
docker run -d --name ch06x-base --network ch06x-back --network-alias base --network-alias bdd redis:8.8-alpine >/dev/null; sleep 1
docker exec ch06x-proxy getent hosts base bdd ch06x-base
echo "== ex5 namespace partagé"
docker run --rm --network container:api alpine:3.24 sh -c 'wget -qO- localhost:8000/sante; echo; hostname; ip -4 addr show eth0 | grep inet'
docker inspect api --format '{{.NetworkSettings.Networks.colis.IPAddress}}'
docker rm -f ch06x-base ch06x-app ch06x-proxy ch06x-dehors >/dev/null; docker network rm ch06x-front ch06x-back >/dev/null; echo "ménage fait"
