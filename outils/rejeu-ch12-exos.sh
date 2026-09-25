#!/usr/bin/env bash
# Chapitre 12, exercices. Conteneurs x12-* et Pod nginx-101, supprimés à la fin.
cd "$(dirname "$0")"; O=$PWD/out/ch12x; rm -rf $O; mkdir -p $O
H() { local n=$1; shift; echo "### $n : $*"; timeout 150 bash -c "$*" 2>&1 | grep -v '^W[0-9]' > $O/$n.txt; head -c 8000 $O/$n.txt; }
docker rm -f x12-a x12-b x12-c x12-d >/dev/null 2>&1
T() { echo "docker run -d --name $1 $2 nginx:1.30-alpine >/dev/null; sleep 2; docker logs $1 2>&1 | grep -E 'emerg|crit' | tail -1; docker exec $1 curl -s -o /dev/null -w 'http %{http_code}\n' http://localhost/ 2>&1 | tail -1; docker rm -f $1 >/dev/null"; }
H x1-dropall "$(T x12-a '--cap-drop ALL')"
H x1-trois "$(T x12-b '--cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID')"
H x1-quatre "$(T x12-c '--cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID --cap-add NET_BIND_SERVICE')"
H x2-chmod "P=$O/sans-chmod.json; printf '%s' '{\"defaultAction\":\"SCMP_ACT_ALLOW\",\"syscalls\":[{\"names\":[\"chmod\",\"fchmod\",\"fchmodat\",\"fchmodat2\"],\"action\":\"SCMP_ACT_ERRNO\"}]}' > \$P; docker run --rm --security-opt seccomp=\$P alpine:3.24 sh -c 'chmod 600 /etc/hostname; echo code=\$?; stat -c %a /etc/hostname'"
H x3-user101 "$(T x12-d '--user 101:101')"
H x4-pod "kubectl run nginx-101 --image=nginx:1.30-alpine --overrides='{\"spec\":{\"securityContext\":{\"runAsNonRoot\":true,\"runAsUser\":101,\"runAsGroup\":101}}}' >/dev/null; sleep 20; kubectl get pod nginx-101; kubectl logs nginx-101 2>&1 | grep -E 'emerg|crit|warn' | tail -2; minikube ssh -- 'sudo containerd config dump 2>/dev/null | grep -E \"enable_unprivileged_(ports|icmp)\"'"
H x4-fin "kubectl delete pod nginx-101 --wait=true"
H x3-tmpfs "docker run -d --name x12-d --user 101:101 --tmpfs /var/cache/nginx:uid=101,gid=101 --tmpfs /run:uid=101,gid=101 nginx:1.30-alpine >/dev/null; sleep 2; docker logs x12-d 2>&1 | grep -E 'emerg|crit|info' | tail -3; docker exec x12-d sh -c 'id; curl -s -o /dev/null -w \"http %{http_code}\n\" http://localhost/'; docker rm -f x12-d >/dev/null"
H x4-restreint "kubectl apply -f ../kits/securite/pod-nginx-restreint.yaml >/dev/null && kubectl wait --for=condition=Ready pod/nginx-restreint --timeout=90s && kubectl exec nginx-restreint -- sh -c 'id; grep -E \"CapEff|NoNewPrivs|Seccomp:\" /proc/1/status; curl -s -o /dev/null -w \"http %{http_code}\n\" http://localhost/'; kubectl logs nginx-restreint | grep -E 'info|warn|emerg' | head -3"
H x4-fin2 "kubectl delete pod nginx-restreint --wait=true"
