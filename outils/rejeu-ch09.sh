#!/usr/bin/env bash
# Chapitre 9 : les cgroups. Utilise le conteneur « labo » (déjà lancé, voir rejeu-ch08.sh) et « cible ».
# Crée et supprime ses propres cgroups (/sys/fs/cgroup/essai*) et conteneurs (limite, gourmand).
# Toute expérience de consommation se fait sous un plafond posé AVANT de consommer.
cd "$(dirname "$0")"; O=$PWD/out/ch09; rm -rf $O; mkdir -p $O
L() { local n=$1; shift; echo "### $n : $*"; docker exec labo bash -c "$*" > $O/$n.txt 2>&1; cat $O/$n.txt; }
H() { local n=$1; shift; echo "### $n : $*"; bash -c "$*" > $O/$n.txt 2>&1; cat $O/$n.txt; }
docker rm -f limite gourmand >/dev/null 2>&1
docker exec labo bash -c 'for c in essai-memoire essai-cpu essai-pids; do [ -d /sys/fs/cgroup/$c ] && rmdir /sys/fs/cgroup/$c; done' 2>/dev/null
P=$(docker inspect cible --format '{{.State.Pid}}'); ID=$(docker inspect cible --format '{{.Id}}')
L 01-proc-cgroup "cat /proc/$P/cgroup; cat /proc/1/cgroup"
L 02-racine "cat /sys/fs/cgroup/cgroup.controllers; ls /sys/fs/cgroup | head -40 | column -c 120"
L 03-fichiers-cible "cd /sys/fs/cgroup/system.slice/docker-$ID.scope && ls | grep -E '^(cgroup.procs|memory.(current|max|peak|events|stat)|cpu.(max|stat|weight)|pids.(current|max))$' && echo --- && cat memory.current memory.max cpu.max pids.current pids.max && echo --- && wc -l < cgroup.procs"
H 04-limite "docker run -d --name limite --memory 64m --cpus 0.5 --pids-limit 50 nginx:1.30-alpine >/dev/null; sleep 1; docker stats --no-stream limite --format 'table {{.Name}}\t{{.MemUsage}}\t{{.PIDs}}'"
IDL=$(docker inspect limite --format '{{.Id}}')
L 05-fichiers-limite "cd /sys/fs/cgroup/system.slice/docker-$IDL.scope && for f in memory.max memory.swap.max cpu.max pids.max pids.current; do printf '%-16s %s\n' \$f \"\$(cat \$f)\"; done"
L 06-cree "mkdir /sys/fs/cgroup/essai-memoire && cd /sys/fs/cgroup/essai-memoire && ls | wc -l && cat memory.max memory.current && echo 50M > memory.max && echo 0 > memory.swap.max && cat memory.max memory.swap.max"
L 07-oom "cd /sys/fs/cgroup/essai-memoire && bash -c 'echo \$\$ > /sys/fs/cgroup/essai-memoire/cgroup.procs; exec stress-ng --vm 1 --vm-bytes 200M --vm-keep --oomable --timeout 10s' 2>&1 | grep -E 'passed|failed|successful'; grep -E '^(max|oom|oom_kill) ' memory.events; cat memory.peak"
L 08-dmesg "dmesg 2>/dev/null | grep -iE 'memory cgroup out of memory|oom-kill:|Killed process' | tail -3"
L 09-cpu "mkdir /sys/fs/cgroup/essai-cpu && cd /sys/fs/cgroup/essai-cpu && echo '20000 100000' > cpu.max && cat cpu.max && bash -c 'echo \$\$ > /sys/fs/cgroup/essai-cpu/cgroup.procs; stress-ng --cpu 1 --timeout 5s --metrics-brief 2>&1 | grep -E \"cpu  \"' ; grep -E 'usage_usec|nr_periods|nr_throttled|throttled_usec' cpu.stat"
L 10-cpu-libre "bash -c 'stress-ng --cpu 1 --timeout 5s --metrics-brief 2>&1 | grep -E \"cpu  \"'"
L 11-pids "mkdir /sys/fs/cgroup/essai-pids && cd /sys/fs/cgroup/essai-pids && echo 5 > pids.max && busybox sh -c 'echo \$\$ > /sys/fs/cgroup/essai-pids/cgroup.procs; for i in 1 2 3 4 5 6 7; do sleep 30 & echo \"lancé \$i\"; done'; cat pids.events; cat cgroup.procs | xargs -r kill; sleep 1"
H 12-docker-oom "docker run --name gourmand --memory 64m python:3.14-slim python -c 'b = bytearray(200 * 1024 * 1024); print(\"alloué\")'; echo \"code=\$?\"; docker inspect gourmand --format 'OOMKilled={{.State.OOMKilled}} code={{.State.ExitCode}}'"
H 13-pause "docker pause cible >/dev/null"
L 14-freeze "cat /sys/fs/cgroup/system.slice/docker-$ID.scope/cgroup.freeze; grep frozen /sys/fs/cgroup/system.slice/docker-$ID.scope/cgroup.events"
H 15-unpause "docker unpause cible >/dev/null; echo repris"
L 16-menage "rmdir /sys/fs/cgroup/essai-memoire /sys/fs/cgroup/essai-cpu /sys/fs/cgroup/essai-pids && echo cgroups supprimés"
H 17-menage-docker "docker rm -f limite gourmand"
