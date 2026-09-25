#!/usr/bin/env bash
# Chapitre 11, seconde moitié : containerd et le CRI dans le nœud minikube (démarré par la personne).
# Crée le Pod demo-runtime et l'espace containerd « cours », qu'il supprime à la fin.
cd "$(dirname "$0")"; O=$PWD/out/ch11n; rm -rf $O; mkdir -p $O
N() { local n=$1; shift; echo "### $n : $*"; timeout 120 minikube ssh -- "$*" 2>&1 | grep -v "^W[0-9]" > $O/$n.txt; head -c 15000 $O/$n.txt; }
H() { local n=$1; shift; echo "### $n : $*"; timeout 120 bash -c "$*" 2>&1 | grep -v "^W[0-9]" > $O/$n.txt; head -c 15000 $O/$n.txt; }
H 20-versions "minikube ssh -- 'sudo crictl version; containerd --version; runc --version | head -1'"
N 21-socket "sudo grep -i containerRuntimeEndpoint /var/lib/kubelet/config.yaml; ls -l /run/containerd/containerd.sock; sudo cat /etc/crictl.yaml"
N 22-pods "sudo crictl pods"
N 23-ps "sudo crictl ps"
N 24-ctr "sudo ctr namespaces list; echo; sudo ctr -n k8s.io containers list | wc -l; sudo ctr -n k8s.io containers list | grep -c pause"
N 25-arbre "ps -e -o pid,ppid,comm | awk 'NR==1 || /containerd|kubelet|shim|pause|etcd|kube-apiserv|coredns/' | head -40"
N 26-config "sudo containerd config dump 2>/dev/null | grep -n -E 'SystemdCgroup|sandbox|runtime_type|default_runtime_name|BinaryName' | head -20"
H 27-pod "kubectl run demo-runtime --image=nginx:1.30-alpine --restart=Never >/dev/null && kubectl wait --for=condition=Ready pod/demo-runtime --timeout=90s && minikube ssh -- 'sudo crictl pods --name demo-runtime; sudo crictl ps --name demo-runtime'"
N 28-partage "P=\$(sudo crictl pods --name demo-runtime --state ready -q); S=\$(sudo crictl inspectp -o go-template --template '{{.info.pid}}' \$P); C=\$(sudo crictl ps --pod \$P --state running -q); I=\$(sudo crictl inspect -o go-template --template '{{.info.pid}}' \$C); echo pause=\$S nginx=\$I; for ns in net uts ipc pid mnt; do echo \"\$ns : \$(sudo readlink /proc/\$S/ns/\$ns) \$(sudo readlink /proc/\$I/ns/\$ns)\"; done; ps -o pid,ppid,comm -p \$S,\$I"
H 29-bundle "minikube ssh -- 'ID=\$(sudo crictl inspect -o go-template --template \"{{.status.id}}\" \$(sudo crictl ps --name demo-runtime -q)); sudo ls /run/containerd/io.containerd.runtime.v2.task/k8s.io/\$ID; echo; sudo cat /run/containerd/io.containerd.runtime.v2.task/k8s.io/\$ID/config.json' 2>/dev/null | tee $O/29-brut.txt | sed -n '1,/^\$/p'; sed '1,/^\$/d' $O/29-brut.txt | tr -d '\r' | jq '{args: .process.args, cgroupsPath: .linux.cgroupsPath, namespaces: [.linux.namespaces[] | {type, path}]}'"
N 30-restart "I=\$(sudo crictl inspect -o go-template --template '{{.info.pid}}' \$(sudo crictl ps --name demo-runtime -q)); echo \"nginx avant : \$I, containerd : \$(pidof containerd)\"; sudo systemctl restart containerd; sleep 3; echo \"nginx après : \$(sudo crictl inspect -o go-template --template '{{.info.pid}}' \$(sudo crictl ps --name demo-runtime -q)), containerd : \$(pidof containerd)\"; ps -o pid,ppid,etime,comm -p \$I"
N 31-ctr-run "sudo ctr -n cours images pull docker.io/library/alpine:3.24 2>&1 | tail -2; sudo ctr -n cours run --rm docker.io/library/alpine:3.24 essai sh -c 'echo bonjour depuis ctr; cat /etc/alpine-release'; sudo ctr namespaces list"
N 32-ctr-cache "sudo crictl images | grep -c . ; sudo crictl images | grep alpine || echo 'alpine invisible pour crictl'"
H 33-menage "kubectl delete pod demo-runtime --wait=true; minikube ssh -- 'sudo ctr -n cours images rm --sync docker.io/library/alpine:3.24 >/dev/null; sudo ctr -n cours content ls -q | xargs -r sudo ctr -n cours content rm >/dev/null; sudo ctr -n cours snapshots ls; sudo ctr namespaces rm cours; sudo ctr namespaces list'"
