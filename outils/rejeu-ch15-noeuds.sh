#!/usr/bin/env bash
# Chapitre 15, seconde moitié : une machine qui tombe. Profil minikube « deux-noeuds » (2 nœuds de 2 Go), laissé arrêté.
cd "$(dirname "$0")"; O=$PWD/out/ch15n; rm -rf $O; mkdir -p $O
export PATH=~/.local/opt/cours-k8s/bin:$PATH
P=deux-noeuds; K="kubectl --context $P"
H() { local n=$1; shift; echo "### $n : $*"; timeout 900 bash -c "$*" 2>&1 | grep -v '^W[0-9]' > $O/$n.txt; head -c 9000 $O/$n.txt; }
H 20-demarrer "minikube start -p $P --driver=docker --nodes=2 --cpus=2 --memory=2g --kubernetes-version=v1.37.0 2>&1 | tail -1; $K wait --for=condition=Ready nodes --all --timeout=180s; $K get nodes -o wide | cut -c1-110"
H 21-deployer "$K create deployment vitrine --image=nginx:1.30-alpine --replicas=4 >/dev/null; $K rollout status deployment/vitrine --timeout=180s; $K get pods -o wide | awk '{print \$1, \$3, \$7}' | column -t"
H 22-panne "t0=\$(date +%s); docker stop $P-m02 >/dev/null; echo \"t=0 : docker stop $P-m02\"; last=''; while [ \$(( \$(date +%s)-t0 )) -lt 480 ]; do e=\$(( \$(date +%s)-t0 )); n=\$($K get node $P-m02 --no-headers 2>/dev/null | awk '{print \$2}'); taints=\$($K get node $P-m02 -o jsonpath='{range .spec.taints[*]}{.key}:{.effect} {end}' 2>/dev/null); pods=\$($K get pods -o wide --no-headers | awk '{print \$3\"@\"\$7}' | sort | uniq -c | tr -s ' ' | tr '\n' ';'); cur=\"noeud=\$n | taints=\$taints | pods=\$pods\"; if [ \"\$cur\" != \"\$last\" ]; then echo \"t=\$e s : \$cur\"; last=\$cur; fi; sleep 3; done"
H 23-apres "$K get pods -o wide | awk '{print \$1, \$3, \$7}' | column -t; $K get events --field-selector reason=NodeNotReady -o custom-columns=OBJET:.involvedObject.name,MESSAGE:.message 2>/dev/null | head -4; $K get pods -o json | jq -r '.items[0].spec.tolerations[] | select(.key|test(\"node.kubernetes.io\")) | \"\(.key) \(.effect) \(.tolerationSeconds)\"'"
H 24-retour "minikube node stop m02 -p $P 2>&1 | tail -1; minikube node start m02 -p $P 2>&1 | tail -1; sleep 20; $K get nodes; $K get pods -o wide | awk '{print \$1, \$3, \$7}' | column -t"
