#!/usr/bin/env bash
# Chapitre 11, exercices. Crée web (runc, dans le labo) et le Pod demo-shim ; les supprime à la fin.
cd "$(dirname "$0")"; O=$PWD/out/ch11x; rm -rf $O; mkdir -p $O
L() { local n=$1; shift; echo "### $n : $*"; timeout 120 docker exec labo bash -c "$*" > $O/$n.txt 2>&1; head -c 12000 $O/$n.txt; }
N() { local n=$1; shift; echo "### $n : $*"; timeout 120 minikube ssh -- "$*" 2>&1 | grep -v "^W[0-9]" > $O/$n.txt; head -c 12000 $O/$n.txt; }
H() { local n=$1; shift; echo "### $n : $*"; timeout 120 bash -c "$*" > $O/$n.txt 2>&1; head -c 12000 $O/$n.txt; }
docker exec labo bash -c 'runc delete -f web 2>/dev/null; rm -rf /labo/bundle-nginx'
L x1-unpack "umoci unpack --image /labo/nginx:1.30-alpine /labo/bundle-nginx >/dev/null && cd /labo/bundle-nginx && ls && jq -c '{terminal: .process.terminal, args: .process.args, user: .process.user, ns: [.linux.namespaces[].type]}' config.json"
L x1-run "cd /labo/bundle-nginx && jq '.process.terminal=false' config.json > c.json && mv c.json config.json && runc run --detach web; echo code=\$?; sleep 1; runc list; runc exec web curl -s -o /dev/null -w '%{http_code}\n' http://localhost/; runc exec web ip -brief addr"
L x1-caps "cd /labo/bundle-nginx && runc delete -f web; jq -c '.process.capabilities.bounding' config.json && jq '.process.capabilities |= with_entries(.value += [\"CAP_CHOWN\",\"CAP_SETUID\",\"CAP_SETGID\"])' config.json > c.json && mv c.json config.json && runc run --detach web > /labo/web.log 2>&1; sleep 1; tail -2 /labo/web.log; runc list; runc exec web curl -s -o /dev/null -w '%{http_code}\n' http://localhost/; runc exec web ip addr; runc ps web | head -4"
L x1-fin "runc kill web TERM; sleep 2; runc list; runc delete web; rm -rf /labo/bundle-nginx /labo/web.log"
L x3-rootless "cd /tmp && mkdir -p rl && cd rl && runc spec --rootless && jq -c '{ns: [.linux.namespaces[].type], uid: .linux.uidMappings, gid: .linux.gidMappings, cgroups: .linux.resources}' config.json; jq -c '[.mounts[] | select(.destination==\"/sys\") | .type, .options]' config.json; cd / && rm -rf /tmp/rl"
#H x4-pod "kubectl run demo-shim --image=nginx:1.30-alpine --restart=Always >/dev/null && kubectl wait --for=condition=Ready pod/demo-shim --timeout=90s"
#N x4-kill "C=\$(sudo crictl ps --name demo-shim -q); I=\$(sudo crictl inspect -o go-template --template '{{.info.pid}}' \$C); S=\$(ps -o ppid= -p \$I | tr -d ' '); echo nginx=\$I shim=\$S; ps -o pid,ppid,comm --ppid \$S; sudo kill -9 \$S; sleep 2; echo après:; ps -o pid,ppid,stat,comm -p \$I || echo \"nginx \$I a disparu\"; sleep 20; sudo crictl ps -a --name demo-shim; sudo crictl pods --name demo-shim"
#H x4-kubectl "kubectl get pod demo-shim -o wide; kubectl get events --field-selector involvedObject.name=demo-shim --sort-by=.lastTimestamp | tail -8"
#H x4-fin "kubectl delete pod demo-shim --wait=true"
