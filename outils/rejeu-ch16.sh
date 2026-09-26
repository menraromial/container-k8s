#!/usr/bin/env bash
# Chapitre 16 : minikube et kubectl. Cluster « minikube » ; active l'addon metrics-server (laissé actif).
cd "$(dirname "$0")"; O=$PWD/out/ch16; rm -rf $O; mkdir -p $O
export PATH=~/.local/opt/cours-k8s/bin:$PATH
H() { local n=$1; shift; echo "### $n : $*"; timeout 300 bash -c "$*" 2>&1 | grep -v '^W[0-9]' > $O/$n.txt; head -c 8000 $O/$n.txt; }
H 01-profils "minikube profile list 2>/dev/null"
H 02-config "minikube config view; minikube profile; minikube ip; minikube status"
H 03-pilotes "minikube start --help 2>/dev/null | grep -A1 -E '^ *-d, --driver'"
H 04-addons "minikube addons list -o json | jq 'length'; minikube addons list -o json | jq -r 'to_entries[] | select(.key|test(\"^(dashboard|headlamp|metrics-server|registry|ingress|default-storageclass|storage-provisioner)\$\")) | \"\\(.key)\\t\\(.value.Status)\"'"
H 05-metrics "minikube addons enable metrics-server 2>&1 | tail -2; kubectl wait -n kube-system --for=condition=Available deployment/metrics-server --timeout=120s; sleep 50; kubectl top nodes; kubectl top pods -n kube-system --sort-by=memory"
H 06-kubeconfig "kubectl config view --minify"
H 07-contextes "kubectl config get-contexts; kubectl config current-context"
H 08-certificat "openssl x509 -in ~/.minikube/profiles/minikube/client.crt -noout -subject -issuer -dates; kubectl auth whoami"
H 09-ressources "kubectl api-resources | wc -l; kubectl api-resources --namespaced=false | wc -l; kubectl api-resources | head -12; kubectl api-resources | grep -E '^(deployments|pods|services|nodes|namespaces) '"
H 10-explain "kubectl explain deployment.spec.replicas; echo ---; kubectl explain pod.spec.containers.imagePullPolicy | head -20"
H 11-explain-rec "kubectl explain deployment.spec.strategy --recursive"
H 12-sorties "kubectl delete deployment essai --ignore-not-found >/dev/null; kubectl create deployment essai --image=nginx:1.30-alpine --replicas=2 >/dev/null; kubectl rollout status deployment/essai >/dev/null; kubectl get pods -o wide; kubectl get pods --show-labels; kubectl get pods -o name; kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{\"  \"}{.status.podIP}{\"\n\"}{end}'; kubectl get pods -o custom-columns='NOM:.metadata.name,NOEUD:.spec.nodeName,IMAGE:.spec.containers[0].image,DEMARRE:.status.startTime'"
H 13-yaml "kubectl get deployment essai -o yaml | head -40; kubectl get deployment essai -o yaml | wc -l; kubectl get deployment essai -o yaml --show-managed-fields | wc -l"
H 14-describe "kubectl describe \$(kubectl get pods -l app=essai -o name | head -1) | sed -n '1,12p;/^Events:/,\$p'"
H 15-logs-exec "P=\$(kubectl get pods -l app=essai -o name | head -1); kubectl logs \$P | tail -3; kubectl exec \$P -- nginx -v; kubectl exec \$P -- cat /etc/hostname"
H 16-port-forward "P=\$(kubectl get pods -l app=essai -o name | head -1); (timeout 8 kubectl port-forward \$P 8090:80 > $O/pf.txt 2>&1 &); sleep 2; curl -s localhost:8090 | grep -o '<title>.*</title>'; cat $O/pf.txt"
H 17-panne-arret "minikube stop 2>&1 | tail -1; kubectl get pods 2>&1 | tail -1; minikube start 2>&1 | tail -1; kubectl wait -n kube-system --for=condition=Ready pods --all --timeout=180s >/dev/null; kubectl get pods --no-headers | wc -l"
H 18-panne-type "kubectl get deploymnt 2>&1; kubectl config use-context inexistant 2>&1"
