#!/usr/bin/env bash
# Chapitre 2 : premier conteneur. Une sortie par étape dans ./out/ch02
cd "$(dirname "$0")"; O=out/ch02; rm -rf $O; mkdir -p $O
run() { local n=$1; shift; echo "### $n : $*"; bash -c "$*" > $O/$n.txt 2>&1; cat $O/$n.txt; }
docker rm -f premier web c2 tue tue2 fragile > /dev/null 2>&1
docker image rm nginx:1.30-alpine > /dev/null 2>&1
run 01-premier "timeout -s INT 4 docker run --name premier nginx:1.30-alpine; echo \"code=\$?\""
run 02-psa "docker ps -a --filter name=premier"
run 03-run-d "docker run -d --name web -p 8080:80 nginx:1.30-alpine"
run 04-ps "docker ps"
sleep 1
run 05-curl "curl -s http://localhost:8080 | grep -o '<title>.*</title>'"
run 06-logs "docker logs web"
run 07-logs-tail "docker logs --tail 2 --timestamps web"
run 08-exec-ls "docker exec web ls -l /usr/share/nginx/html"
run 09-exec-modif "docker exec web sh -c 'echo \"<h1>Bonjour depuis le conteneur</h1>\" > /usr/share/nginx/html/index.html'; curl -s http://localhost:8080"
run 10-tty "script -qc \"docker run -it --rm alpine:3.24 sh -c 'tty; hostname; cat /etc/alpine-release'\" /dev/null"
run 11-top "docker top web"
run 12-stats "docker stats --no-stream web"
run 13-inspect "docker inspect web --format 'état={{.State.Status}} pid={{.State.Pid}} démarré={{.State.StartedAt}} ip={{.NetworkSettings.Networks.bridge.IPAddress}}'"
run 14-pause "docker pause web; docker ps --filter name=web --format '{{.Names}} {{.Status}}'; timeout 3 curl -s http://localhost:8080; echo \"curl code=\$?\"; docker unpause web; curl -s -m 3 http://localhost:8080"
run 15-stop "/usr/bin/time -f '%e s' docker stop web; docker ps -a --filter name=web --format '{{.Names}} {{.Status}}'"
run 16-start "docker start web; sleep 1; curl -s http://localhost:8080 | head -3"
run 17-rm-actif "docker rm web"
run 18-create "docker create --name c2 alpine:3.24 echo bonjour; docker ps -a --filter name=c2 --format '{{.Names}} {{.Status}}'; docker start -a c2; docker ps -a --filter name=c2 --format '{{.Names}} {{.Status}}'"
run 19-exit3 "docker run --rm alpine:3.24 sh -c 'exit 3'; echo \"code=\$?\""
run 20-exit127 "docker run --rm alpine:3.24 commande-inexistante; echo \"code=\$?\""
run 21-exit126 "docker run --rm alpine:3.24 /etc/passwd; echo \"code=\$?\""
run 22-exit125 "docker run --rm --memoire=1g alpine:3.24 true; echo \"code=\$?\""
run 23-stop-sleep "docker run -d --name tue alpine:3.24 sleep 300 >/dev/null; /usr/bin/time -f '%e s' docker stop tue; docker inspect tue --format 'code de sortie : {{.State.ExitCode}}'"
run 24-stop-init "docker run -d --init --name tue2 alpine:3.24 sleep 300 >/dev/null; /usr/bin/time -f '%e s' docker stop tue2; docker inspect tue2 --format 'code de sortie : {{.State.ExitCode}}'"
run 25-kill "docker start tue >/dev/null; docker kill tue; docker inspect tue --format 'code de sortie : {{.State.ExitCode}}'"
run 26-restart "docker run -d --name fragile --restart on-failure:3 alpine:3.24 sh -c 'echo démarrage à \$(date +%T); sleep 1; exit 1' >/dev/null; sleep 12; docker logs fragile; docker inspect fragile --format 'redémarrages : {{.RestartCount}}, état : {{.State.Status}}, code : {{.State.ExitCode}}'"
run 27-psa-exited "docker ps -a --filter status=exited --format 'table {{.Names}}\t{{.Status}}'"
run 28-menage "docker rm -f web premier c2 tue tue2 fragile"
