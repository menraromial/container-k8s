#!/usr/bin/env bash
# Chapitre 40 : les Services sous le capot. Partie A sur « deux-noeuds » (kindnet, kube-proxy), passe kube-proxy
# en nftables puis en ipvs, puis le remet en iptables. Partie B : RECRÉE le profil « cilium » (minikube delete -p cilium,
# puis --cni=cilium) et le passe sans kube-proxy. Namespace ch40 (recréé). Un profil à la fois. Laisse « cilium » en marche.
cd "$(dirname "$0")"; O=$PWD/out/ch40; rm -rf $O; mkdir -p $O; cp -a ../kits/services-capot $O/m
export PATH=~/.local/opt/cours-k8s/bin:$PATH LC_ALL=C
H() { local n=$1; shift; echo "### $n : $*"; (cd $O/m && timeout 900 bash -c "$*") 2>&1 | grep -v '^W[0-9]' | grep -v 'docker context\|Docker CLI context' > $O/$n.txt; head -c 4000 $O/$n.txt; }
K="kubectl -n ch40"
N2() { minikube ssh -p $P -n $M2 -- "$@" 2>/dev/null | tr -d '\r'; }
mode() { kubectl -n kube-system get cm kube-proxy -o json | jq --arg m "$1" '.data["config.conf"] |= sub("\nmode: [a-z]*\n"; "\nmode: \($m)\n")' | kubectl replace -f - >/dev/null; kubectl -n kube-system rollout restart ds/kube-proxy >/dev/null; kubectl -n kube-system rollout status ds/kube-proxy --timeout=120s >/dev/null; sleep 5; }
export -f mode
installer="kubectl create namespace ch40 >/dev/null; $K apply -f web.yaml; $K rollout status deploy/web >/dev/null; $K wait --for=condition=Ready pod/client --timeout=300s >/dev/null"
debogueur="$K debug node/\$M2 --image=nicolaka/netshoot:v0.14 --profile=sysadmin -- sleep 3600 >/dev/null 2>&1; sleep 2; D=\$($K get pods -o name | grep node-debugger | head -1 | cut -d/ -f2); $K wait --for=condition=Ready pod/\$D --timeout=300s >/dev/null"
kp="KP=\$(kubectl -n kube-system get pods -l k8s-app=kube-proxy --field-selector spec.nodeName=\$M2 -o name)"
syn="$K exec client -- sh -c 'timeout 5 tcpdump -ni eth0 -c 1 \"tcp[tcpflags] & tcp-syn != 0 and tcp[tcpflags] & tcp-ack == 0\" 2>/dev/null & sleep 1; curl -s http://web/hostname; echo; wait'"
repartition="$K exec client -- sh -c 'for i in \$(seq 1 \$0); do curl -s http://web/hostname; echo; done' "

# --- A. kube-proxy, sur deux-noeuds (kindnet) ---
export P=deux-noeuds M2=deux-noeuds-m02
for p in minikube calico cilium; do minikube stop -p $p >/dev/null 2>&1; done
minikube start -p $P >/dev/null 2>&1; kubectl config use-context $P >/dev/null; kubectl wait --for=condition=Ready node --all --timeout=300s >/dev/null
kubectl -n kube-system rollout status ds/kube-proxy --timeout=300s >/dev/null
bash -c "mode iptables"
kubectl delete namespace ch39 ch40 --ignore-not-found --wait=true >/dev/null 2>&1; while kubectl get ns ch39 ch40 2>/dev/null | grep -q ch; do sleep 2; done
H a01-service "$installer; $K get svc web; $K get endpointslices -l kubernetes.io/service-name=web; $K get pods -o custom-columns=POD:.metadata.name,IP:.status.podIP,NOEUD:.spec.nodeName"
H a00-ping "$K exec client -- sh -c 'ping -c 3 -W 1 web; echo code \$?; curl -s http://web/hostname; echo; ip -br addr; ip route get \$(getent hosts web | cut -d\" \" -f1)'"
H a02-mode "kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\\.conf}' | grep -E '^mode'; $kp; kubectl -n kube-system logs \$KP | grep -E 'Using .* Proxier'"
H a03-iptables "$kp; kubectl -n kube-system exec \$KP -- iptables-nft-save -t nat 2>/dev/null | grep -E 'ch40/web' ; echo \"lignes de la table nat : \$(kubectl -n kube-system exec \$KP -- iptables-nft-save -t nat 2>/dev/null | grep -c '^-A')\""
H a04-repartition "$repartition 300 | sort | uniq -c"
H a05-conntrack "$debogueur; CIP=\$($K get svc web -o jsonpath='{.spec.clusterIP}'); $K exec \$D -- conntrack -L -p tcp --orig-dst \$CIP 2>&1 | tail -3"
H a06-syn "$syn"
H a07-nftables "bash -c 'mode nftables'; $kp; kubectl -n kube-system logs \$KP | grep -E 'Using .* Proxier'; D=\$($K get pods -o name | grep node-debugger | head -1 | cut -d/ -f2); $K exec \$D -- sh -c 'nft list table ip kube-proxy | sed -n \"/map service-ips/,/^\\t}/p\"; nft list table ip kube-proxy | grep -A2 \"chain service-.*ch40/web\"'; echo \"règles KUBE-SVC iptables restantes : \$(kubectl -n kube-system exec \$KP -- iptables-nft-save -t nat 2>/dev/null | grep -c KUBE-SVC)\"; $repartition 30 | sort | uniq -c"
H a08-ipvs "bash -c 'mode ipvs'; $kp; kubectl -n kube-system logs \$KP | grep -E 'Using .* Proxier|deprecated'; D=\$($K get pods -o name | grep node-debugger | head -1 | cut -d/ -f2); CIP=\$($K get svc web -o jsonpath='{.spec.clusterIP}'); $K exec \$D -- ipvsadm -Ln -t \$CIP:80; $repartition 30 | sort | uniq -c"
H a09-retour "bash -c 'mode iptables'; $kp; kubectl -n kube-system logs \$KP | grep -E 'Using .* Proxier'; $repartition 3"
H a10-resolv "$K exec client -- cat /etc/resolv.conf; kubectl -n kube-system get deploy coredns -o jsonpath='{.spec.template.spec.containers[0].image}, {.spec.replicas} réplique(s){\"\\n\"}'; kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'"
H a11-requetes "IP=\$($K get pod client -o jsonpath='{.status.podIP}'); for u in http://example.com/ http://example.com./ http://web/hostname; do T=\$(date -u +%Y-%m-%dT%H:%M:%SZ); sleep 1; $K exec client -- curl -s -m 5 -o /dev/null -w \"\$u : %{http_code}\\n\" \$u; sleep 1; kubectl -n kube-system logs deploy/coredns --since-time=\$T | grep \"\$IP\" | sed -E 's/^\\[INFO\\] //' | cut -c1-150; done"
H a12-headless "$K apply -f web-headless.yaml; sleep 3; $K get svc web web-headless; $K exec client -- dig +short web-headless.ch40.svc.cluster.local; $K exec client -- dig +short SRV _http._tcp.web.ch40.svc.cluster.local; $K exec client -- dig +short SRV _http._tcp.web-headless.ch40.svc.cluster.local"
H a13-nodeport "D=\$($K get pods -o name | grep node-debugger | head -1 | cut -d/ -f2); $K apply -f web-nodeport.yaml; sleep 3; echo '# externalTrafficPolicy: Cluster'; $K exec \$D -- sh -c 'for i in 1 2 3 4 5 6; do curl -s http://192.168.58.2:30080/clientip; echo; done' | sort; $K patch svc web-nodeport -p '{\"spec\":{\"externalTrafficPolicy\":\"Local\"}}' >/dev/null; sleep 3; echo '# externalTrafficPolicy: Local'; $K exec \$D -- sh -c 'for i in 1 2 3 4 5 6; do curl -s -m 2 http://192.168.58.2:30080/clientip; echo; done' | sort"
H a14-ex-quatre "$K scale deploy web --replicas=4; $K rollout status deploy/web >/dev/null; sleep 3; $kp; kubectl -n kube-system exec \$KP -- iptables-nft-save -t nat 2>/dev/null | python3 probabilites.py | grep -A4 'ch40/web'; $K scale deploy web --replicas=3 >/dev/null; $K rollout status deploy/web >/dev/null"
H a15-ex-zero "$K scale deploy web --replicas=0; $K wait --for=delete pod -l app=web --timeout=120s >/dev/null; sleep 3; $kp; kubectl -n kube-system exec \$KP -- iptables-nft-save 2>/dev/null | grep 'ch40/web:http has no endpoints'; $K exec client -- curl -sS -m 3 http://web/hostname; echo \"code \$?\"; $K scale deploy web --replicas=3 >/dev/null; $K rollout status deploy/web >/dev/null"
H a16-ex-ndots "$K apply -f ndots.yaml >/dev/null; $K wait --for=condition=Ready pod/client-ndots1 --timeout=120s >/dev/null; $K exec client-ndots1 -- cat /etc/resolv.conf | tail -1; IP=\$($K get pod client-ndots1 -o jsonpath='{.status.podIP}'); for u in http://example.com/ http://web/hostname; do T=\$(date -u +%Y-%m-%dT%H:%M:%SZ); sleep 1; $K exec client-ndots1 -- curl -s -m 5 -o /dev/null -w \"\$u : %{http_code}\\n\" \$u; sleep 1; echo \"requêtes DNS : \$(kubectl -n kube-system logs deploy/coredns --since-time=\$T | grep -c \"\$IP\")\"; done"

# --- B. Cilium sans kube-proxy (profil recréé) ---
export P=cilium M2=cilium-m02
minikube stop -p deux-noeuds >/dev/null 2>&1
minikube delete -p cilium >/dev/null 2>&1
minikube start -p cilium --driver=docker --nodes=2 --cpus=2 --memory=2g --kubernetes-version=v1.37.0 --cni=cilium >/dev/null 2>&1
kubectl config use-context cilium >/dev/null; kubectl wait --for=condition=Ready node --all --timeout=400s >/dev/null; kubectl -n kube-system rollout status ds/cilium --timeout=400s >/dev/null
H b01-avant "kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status 2>/dev/null | grep -E '^KubeProxyReplacement'; kubectl -n kube-system get ds kube-proxy; $installer; $K get svc web; $syn"
H b02-bascule "./cilium-sans-kube-proxy.sh 2>&1 | grep -vE 'Waiting for|^\$'; kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status 2>/dev/null | grep -E '^KubeProxyReplacement'"
H b03-cartes "CIP=\$($K get svc web -o jsonpath='{.spec.clusterIP}'); echo \"ClusterIP de web : \$CIP\"; A=\$(kubectl -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName=\$M2 -o name); kubectl -n kube-system exec \$A -c cilium-agent -- cilium-dbg service list 2>/dev/null | grep -A2 -E \"^ID|\$CIP\" | grep -v '^--'; kubectl -n kube-system exec \$A -c cilium-agent -- cilium-dbg bpf lb list 2>/dev/null | grep -E \"SERVICE ADDRESS|\$CIP:80\"; $K get pods -l app=web -o custom-columns=POD:.metadata.name,IP:.status.podIP; kubectl -n kube-system exec \$A -c cilium-agent -- cilium-dbg status --verbose 2>/dev/null | sed -n '/KubeProxyReplacement Details/,/Session Affinity/p'"
H b04-apres "$syn; $repartition 300 | sort | uniq -c; $debogueur; echo \"règles des chaînes de kube-proxy : \$($K exec \$D -- sh -c 'iptables-nft-save | grep -cE \"KUBE-(SERVICES|SVC|SEP|NODEPORTS|EXT)\"')\""
