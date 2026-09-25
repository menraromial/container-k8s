#!/usr/bin/env bash
# Chapitre 11 : les runtimes. Utilise « labo » et « cible ». Crée ses propres conteneurs runc/crun (demo*),
# qu'il supprime ; ne touche pas aux conteneurs Docker (lecture seule via containerd).
cd "$(dirname "$0")"; O=$PWD/out/ch11; rm -rf $O; mkdir -p $O
L() { local n=$1; shift; echo "### $n : $*"; docker exec labo bash -c "$*" > $O/$n.txt 2>&1; head -c 15000 $O/$n.txt; }
H() { local n=$1; shift; echo "### $n : $*"; bash -c "$*" > $O/$n.txt 2>&1; head -c 15000 $O/$n.txt; }
docker exec labo bash -c 'for c in demo demo-crun; do runc delete -f $c 2>/dev/null; crun delete -f $c 2>/dev/null; done; rm -rf /labo/runc-essai' >/dev/null 2>&1
ID=$(docker inspect cible --format '{{.Id}}')
case "$ID" in [0-9a-f]*) ;; *) echo "identifiant de cible inattendu"; exit 1;; esac

L 01-versions "runc --version; crun --version | head -2"
L 02-spec "mkdir -p /labo/runc-essai && cd /labo/runc-essai && runc spec && jq '{ociVersion, process: {terminal: .process.terminal, args: .process.args, cwd: .process.cwd}, root, hostname, namespaces: [.linux.namespaces[].type]}' config.json && jq '.process.capabilities.bounding' config.json && jq '.linux.maskedPaths | length' config.json && jq '[.mounts[].destination]' config.json -c"
L 03-bundle "cd /labo/runc-essai && cp -a /labo/bundle/rootfs rootfs && jq '.process.terminal=false | .process.args=[\"sleep\",\"300\"] | .hostname=\"demo\"' config.json > c.json && mv c.json config.json && ls"
L 04-run "cd /labo/runc-essai && runc run --detach demo && runc list && runc state demo | jq '{id, pid, status, bundle, created}'"
L 05-ps "runc ps demo; P=\$(runc state demo | jq .pid); echo \"PID vu du labo : \$P\"; lsns -p \$P | tail -n +2 | awk '{print \$2}' | sort | tr '\n' ' '; echo; cat /proc/\$P/cgroup"
L 06-exec "runc exec demo sh -c 'hostname; cat /etc/alpine-release; ps; id'"
L 07-kill "runc kill demo KILL; sleep 1; runc list; runc delete demo; runc list"
L 08-strace "cd /labo/runc-essai && jq '.process.args=[\"true\"]' config.json > c.json && mv c.json config.json && strace -f -o /labo/runc-trace.txt -e trace=clone,clone3,unshare,pivot_root,sethostname,execve runc run demo; grep -E 'CLONE_NEW|pivot_root|sethostname|execve\\(\"/bin/true|execve\\(\"true' /labo/runc-trace.txt | sed 's/^[0-9]* //' | cut -c1-160 | head -12; rm -f /labo/runc-trace.txt"
L 09-temps "cd /labo/runc-essai && for r in runc crun; do debut=\$(date +%s%N); for i in \$(seq 1 20); do \$r run demo-\$r-\$i >/dev/null 2>&1; done; fin=\$(date +%s%N); echo \"\$r : \$(( (fin-debut)/20000000 )) ms par conteneur\"; done"
# la pile de Docker
H 10-docker-info "docker info --format 'runtime par défaut : {{.DefaultRuntime}}'; docker info --format '{{range \$k, \$v := .Runtimes}}{{\$k}} {{end}}'; docker version --format 'containerd {{range .Server.Components}}{{if eq .Name \"containerd\"}}{{.Version}}{{end}}{{end}}'"
L 11-arbre "P=\$(pgrep -f 'nginx: master' | head -1); pstree -sp \$P | head -3; ps -o pid,ppid,cmd -C dockerd,containerd | cut -c1-90"
L 12-ctr "nsenter --target 1 --mount ctr namespaces list; nsenter --target 1 --mount ctr --namespace moby containers list | cut -c1-110"
L 13-bundle-docker "cd /proc/1/root/run/containerd/io.containerd.runtime.v2.task/moby/$ID && ls && jq '{args: .process.args, hostname, root, namespaces: [.linux.namespaces[].type], cgroupsPath: .linux.cgroupsPath}' config.json && jq '.process.capabilities.bounding | length' config.json && jq '.linux.seccomp.defaultAction' config.json"
L 14-runc-docker "nsenter --target 1 --mount runc --root /run/docker/runtime-runc/moby list | cut -c1-120 | head -4"
# pannes et état
L 15-panne-tty "cd /labo/runc-essai && jq '.process.terminal=true | .process.args=[\"sleep\",\"30\"]' config.json > c.json && mv c.json config.json && runc run --detach demo; echo code=\$?; runc delete -f demo 2>/dev/null; jq '.process.terminal=false' config.json > c.json && mv c.json config.json"
L 16-etat "cd /labo/runc-essai && jq '.process.terminal=false | .process.args=[\"sleep\",\"30\"]' config.json > c.json && mv c.json config.json && runc create demo && runc list && ls /run/runc/demo && runc start demo && runc list && runc delete -f demo && runc list"
L 17-lecture-seule "cd /labo/runc-essai && jq '.process.args=[\"touch\",\"/essai\"]' config.json > c.json && mv c.json config.json && runc run demo; echo code=\$?"
