#!/usr/bin/env bash
# Chapitre 12, Kubernetes : Pods defaut, durci, nginx-nonroot, userns (supprimés à la fin).
cd "$(dirname "$0")"; O=$PWD/out/ch12k; rm -rf $O; mkdir -p $O; K=../kits/securite
H() { local n=$1; shift; echo "### $n : $*"; timeout 150 bash -c "$*" 2>&1 | grep -v '^W[0-9]' > $O/$n.txt; head -c 12000 $O/$n.txt; }
kubectl delete pod defaut durci nginx-nonroot userns --ignore-not-found --wait=true >/dev/null 2>&1
H 20-defaut "kubectl apply -f $K/pod-defaut.yaml && kubectl wait --for=condition=Ready pod/defaut --timeout=90s && kubectl exec defaut -- sh -c 'id; grep -E \"CapEff|NoNewPrivs|Seccomp:\" /proc/1/status; touch /essai && echo écriture ok'"
H 21-durci "kubectl apply -f $K/pod-durci.yaml && kubectl wait --for=condition=Ready pod/durci --timeout=90s && kubectl exec durci -- sh -c 'id; grep -E \"CapEff|NoNewPrivs|Seccomp:\" /proc/1/status; touch /essai; echo code=\$?'"
H 22-nginx-nonroot "kubectl apply -f $K/pod-nginx-nonroot.yaml; sleep 15; kubectl get pod nginx-nonroot; kubectl get events --field-selector involvedObject.name=nginx-nonroot | grep -i warn | tail -2"
H 23-userns "kubectl apply -f $K/pod-userns.yaml && kubectl wait --for=condition=Ready pod/userns --timeout=90s && kubectl exec userns -- sh -c 'id; cat /proc/self/uid_map; grep CapEff /proc/1/status'"
H 24-userns-noeud "minikube ssh -- 'for p in \$(pgrep -x sleep); do echo \"PID \$p : UID \$(ps -o uid= -p \$p)\"; done'"
H 25-fin "kubectl delete pod defaut durci nginx-nonroot userns --wait=true"
