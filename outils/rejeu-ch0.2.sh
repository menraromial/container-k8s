#!/usr/bin/env bash
# Rejoue le chapitre 0.2 dans l'ordre de la page ; une sortie par étape dans ./out
# ATTENTION : commence par « minikube delete » (profil minikube) pour repartir d'un cluster neuf.
export PATH=~/.local/opt/cours-k8s/bin:$PATH
cd "$(dirname "$0")"; mkdir -p out
F='Unable to resolve the current Docker CLI context\|docker context use default'
run() { local n=$1; shift; echo "### $n : $*"; bash -c "$*" 2>&1 | grep -v "$F" | tee out/$n.txt; }
minikube delete > /dev/null 2>&1
run 01-start "minikube start --driver=docker --cpus=2 --memory=4g --kubernetes-version=v1.37.0 | grep -v '^    >'"
run 01b-wait "kubectl wait --for=condition=Ready nodes --all --timeout=120s && kubectl wait -n kube-system --for=condition=Ready pods --all --timeout=180s"
run 02-dockerps "docker ps --filter name=^minikube\$ --format 'table {{.ID}}\t{{.Image}}\t{{.Names}}\t{{.Status}}'"
run 03-crictl "minikube ssh -- sudo crictl ps"
run 04-ps "ps -eo pid,user,rss,cmd --sort=-rss | grep '[k]ube-apiserver' | head -1 | cut -c1-110"
run 05-context "kubectl config current-context; kubectl cluster-info"
run 06-nodes "kubectl get nodes"
run 07-pods "kubectl get pods --all-namespaces"
run 08-deploy "kubectl create deployment bonjour --image=nginx:1.29-alpine && kubectl rollout status deployment/bonjour && kubectl expose deployment bonjour --type=NodePort --port=80"
sleep 2
run 09-url "minikube service bonjour --url; curl -s \$(minikube service bonjour --url) | grep title"
run 10-headlamp "minikube addons enable headlamp"
run 11-crb "kubectl -n headlamp rollout status deploy/headlamp --timeout=180s >/dev/null; kubectl get clusterrolebinding headlamp-admin -o wide"
run 12-token "T=\$(kubectl create token headlamp --duration 24h -n headlamp); echo \"\${T:0:12}... (\${#T} caractères)\""
run 13-stats "docker stats --no-stream minikube --format '{{.MemUsage}}'"
run 14-stop "/usr/bin/time -f '%e s' minikube stop"
run 15-start "/usr/bin/time -f '%e s' minikube start && kubectl get deployments --all-namespaces"
run 16-profiles "minikube profile list"
run 17-pid "pgrep -a kube-apiserver | cut -c1-60; minikube ssh -- 'pgrep -a kube-apiserver | cut -c1-60'; minikube ssh -- ps -o pid,comm -p 1"
run 18-curl "curl -sk https://192.168.49.2:8443/api/v1/namespaces | grep message; TOKEN=\$(kubectl create token headlamp --duration 1h -n headlamp); curl -sk -H \"Authorization: Bearer \$TOKEN\" https://192.168.49.2:8443/api/v1/namespaces | grep '\"name\"'"
run 19-stats2 "docker stats --no-stream minikube --format '{{.MemUsage}}'"
