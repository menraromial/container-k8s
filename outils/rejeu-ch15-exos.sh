#!/usr/bin/env bash
# Chapitre 15, exercices. Namespace « ch15x » (recréé), cluster minikube par défaut.
cd "$(dirname "$0")"; O=$PWD/out/ch15x; rm -rf $O; mkdir -p $O
export PATH=~/.local/opt/cours-k8s/bin:$PATH
K="kubectl --context minikube -n ch15x"
H() { local n=$1; shift; echo "### $n : $*"; timeout 300 bash -c "$*" 2>&1 | grep -v '^W[0-9]' > $O/$n.txt; head -c 7000 $O/$n.txt; }
kubectl --context minikube delete namespace ch15x --wait=true >/dev/null 2>&1; kubectl --context minikube create namespace ch15x >/dev/null
$K create deployment vitrine --image=nginx:1.30-alpine --replicas=3 >/dev/null; $K rollout status deployment/vitrine --timeout=90s >/dev/null
H x1-supprimer-rs "RS=\$($K get rs -o name); echo \$RS; $K get pods --no-headers | awk '{print \$1, \$5}'; $K delete \$RS; sleep 5; $K get rs; $K get pods --no-headers | awk '{print \$1, \$5}'"
H x2-watch "$K get pods -w -v=6 > $O/x2.log 2>&1 & p=\$!; sleep 4; kill \$p; grep -oE 'verb=\"GET\" url=\"[^\"]*\"' $O/x2.log"
H x3-etcd "kubectl --context minikube exec -n kube-system etcd-minikube -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/var/lib/minikube/certs/etcd/ca.crt --cert=/var/lib/minikube/certs/etcd/server.crt --key=/var/lib/minikube/certs/etcd/server.key get /registry/deployments/ch15x/vitrine --print-value-only | head -c 400 | strings -n 4 | head -12"
H x4-image-a-la-main "P=\$($K get pods -o jsonpath='{.items[0].metadata.name}'); $K set image pod/\$P nginx=nginx:1.29-alpine; sleep 15; $K get pods -o custom-columns=NOM:.metadata.name,IMAGE:.spec.containers[0].image,RESTARTS:.status.containerStatuses[0].restartCount"
H x4-etiquette "P=\$($K get pods -o jsonpath='{.items[0].metadata.name}'); $K label pod \$P app=orphelin --overwrite; sleep 5; $K get pods -o 'custom-columns=NOM:.metadata.name,APP:.metadata.labels.app,PROPRIETAIRE:.metadata.ownerReferences[0].name,IMAGE:.spec.containers[0].image'"
H x5-bail "kubectl --context minikube get lease -n kube-node-lease; for i in 1 2 3; do kubectl --context minikube get lease minikube -n kube-node-lease -o jsonpath='{.spec.renewTime}{\"\n\"}'; sleep 10; done; kubectl --context minikube get lease minikube -n kube-node-lease -o jsonpath='{.spec.leaseDurationSeconds}{\"\n\"}'"
