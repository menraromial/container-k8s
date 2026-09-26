#!/usr/bin/env bash
# Chapitre 39 : le réseau des Pods. Trois profils, l'un après l'autre (jamais deux en même temps) :
#   deux-noeuds (kindnet), calico (--cni=calico), cilium (--cni=cilium), 2 nœuds de 2 Gio chacun.
# Namespace ch39 dans chacun (recréé). Débogueur de nœud : image nicolaka/netshoot:v0.14. Laisse le profil cilium en marche.
cd "$(dirname "$0")"; O=$PWD/out/ch39; rm -rf $O; mkdir -p $O; cp -a ../kits/reseau $O/m
export PATH=~/.local/opt/cours-k8s/bin:$PATH LC_ALL=C
H() { local n=$1; shift; echo "### $n : $*"; (cd $O/m && timeout 600 bash -c "$*") 2>&1 | grep -v '^W[0-9]' | grep -v 'docker context\|Docker CLI context' > $O/$n.txt; head -c 5000 $O/$n.txt; }
profil() {
  for p in minikube deux-noeuds calico cilium; do [ $p != $1 ] && minikube stop -p $p >/dev/null 2>&1; done
  case $1 in
    deux-noeuds) minikube start -p deux-noeuds >/dev/null 2>&1 ;;
    *) minikube start -p $1 --driver=docker --nodes=2 --cpus=2 --memory=2g --kubernetes-version=v1.37.0 --cni=$1 >/dev/null 2>&1 ;;
  esac
  kubectl config use-context $1 >/dev/null; kubectl wait --for=condition=Ready node --all --timeout=400s >/dev/null
  kubectl delete namespace ch38 ch39 --ignore-not-found --wait=true >/dev/null 2>&1
  while kubectl get namespace ch38 ch39 2>/dev/null | grep -q ch3; do sleep 2; done
}
# attend que le greffon réseau ait posé, sur le second nœud, la route vers les Pods du premier
route_prete() { for i in $(seq 1 90); do N $M2 "ip route" | grep -qE "$1" && return 0; sleep 2; done; echo "route $1 absente" >&2; }
N() { minikube ssh -p $P -n $1 -- "${@:2}" 2>/dev/null | tr -d '\r'; }
export -f N
debogueur="kubectl -n ch39 debug node/\$M2 --image=nicolaka/netshoot:v0.14 --profile=sysadmin -- sleep 3600 >/dev/null 2>&1; sleep 2; D=\$(kubectl -n ch39 get pods -o name | grep node-debugger | head -1 | cut -d/ -f2); kubectl -n ch39 wait --for=condition=Ready pod/\$D --timeout=300s >/dev/null"

# --- kindnet ---
export P=deux-noeuds M1=deux-noeuds M2=deux-noeuds-m02; profil $P
kubectl -n kube-system rollout status ds/kindnet --timeout=300s >/dev/null; route_prete '^10.244.0.0/24 via'
H a01-noeuds "kubectl get nodes -o custom-columns=NOEUD:.metadata.name,IP:.status.addresses[0].address,PODCIDR:.spec.podCIDR"
H a02-cni "N \$M2 'ls /etc/cni/net.d/; ls /opt/cni/bin/ | tr \"\\n\" \" \"; echo; sudo cat /etc/cni/net.d/10-kindnet.conflist'"
H a03-pods "./pods.sh"
H a04-dans-le-pod "kubectl -n ch39 exec p-\$M2 -- ip addr show eth0; kubectl -n ch39 exec p-\$M2 -- ip route"
H a05-noeud "N \$M2 'ip -br link | grep veth; ip route'; I=\$(kubectl -n ch39 get pod p-\$M2 -o jsonpath='{.status.podIP}'); V=\$(N \$M2 \"ip route | grep '^\$I ' | awk '{print \\\$3}'\"); echo \"# côté hôte du Pod p-\$M2 : \$V\"; N \$M2 \"ip -d link show \$V | head -2; ip addr show \$V | grep 'inet '\""
H a06-ipam "N \$M2 'sudo ls /run/cni-ipam-state/kindnet/; for f in /run/cni-ipam-state/kindnet/10.*; do echo \"\$f : \$(sudo cat \$f | tr \"\\n\" \" \")\"; done'; kubectl -n ch39 get pod p-\$M2 -o jsonpath='{.status.containerStatuses[0].containerID}{\"\\n\"}'; S=\$(N \$M2 'sudo crictl pods --name p-deux-noeuds-m02 --state ready -q'); echo \"bac à sable : \$S\""
H a07-capture "$debogueur; IP1=\$(kubectl -n ch39 get pod p-\$M1 -o jsonpath='{.status.podIP}'); kubectl -n ch39 exec \$D -- timeout 6 tcpdump -ni eth0 -c 4 icmp > td.txt 2>&1 & sleep 2; kubectl -n ch39 exec p-\$M2 -- ping -c 2 \$IP1; wait; grep -v 'verbose\\|listening\\|captured\\|received\\|dropped' td.txt"
H a08-ex-adresses "kubectl proxy --port=8011 >/dev/null & Q=\$!; sleep 1; python3 adresses.py; kill \$Q"

# --- Calico ---
export P=calico M1=calico M2=calico-m02; profil $P
kubectl -n kube-system rollout status ds/calico-node --timeout=400s >/dev/null; route_prete 'dev tunl0 proto bird'
H b01-calico "kubectl -n kube-system get ds calico-node -o jsonpath='{.spec.template.spec.containers[0].image}{\"\\n\"}'; kubectl get ippools.crd.projectcalico.org -o yaml | grep -E ' cidr:|ipipMode|vxlanMode|natOutgoing|blockSize'; kubectl get blockaffinities.crd.projectcalico.org -o custom-columns=NOEUD:.spec.node,BLOC:.spec.cidr,ETAT:.spec.state"
H b02-pods "./pods.sh"
H b03-dans-le-pod "kubectl -n ch39 exec p-\$M2 -- ip addr show eth0 | grep -E 'eth0|inet '; kubectl -n ch39 exec p-\$M2 -- ip route"
H b04-noeud "N \$M2 'ip -br link | grep -E \"cali|tunl\"; ip route | grep -v docker'"
H b05-bgp "kubectl -n kube-system exec ds/calico-node -c calico-node -- birdcl show protocols 2>&1 | head -8"
H b06-capture "$debogueur; IP1=\$(kubectl -n ch39 get pod p-\$M1 -o jsonpath='{.status.podIP}'); kubectl -n ch39 exec \$D -- timeout 6 tcpdump -ni eth0 -c 1 -v ip proto 4 > td.txt 2>&1 & sleep 2; kubectl -n ch39 exec p-\$M2 -- ping -c 1 \$IP1 | head -2; wait; grep -v 'listening\\|captured\\|received\\|dropped' td.txt"
H b07-ex-adresses "kubectl proxy --port=8011 >/dev/null & Q=\$!; sleep 1; python3 adresses.py; kill \$Q"

# --- Cilium ---
export P=cilium M1=cilium M2=cilium-m02; profil $P
kubectl -n kube-system rollout status ds/cilium --timeout=400s >/dev/null; route_prete 'dev cilium_host'
H c01-cilium "kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status 2>/dev/null | grep -E '^(Kubernetes|KubeProxyReplacement|Cilium|IPAM|Routing|Device Mode|Masquerading):'; kubectl -n kube-system get cm cilium-config -o json | jq -r '.data | to_entries[] | select(.key|test(\"^(routing-mode|tunnel-protocol|kube-proxy-replacement|ipam|cluster-pool-ipv4-cidr)\$\")) | \"\\(.key)=\\(.value)\"'"
H c02-pods "./pods.sh"
H c03-dans-le-pod "kubectl -n ch39 exec p-\$M2 -- ip addr show eth0 | grep -E 'eth0|inet '; kubectl -n ch39 exec p-\$M2 -- ip route"
H c04-noeud "N \$M2 'ip -br link | grep -E \"lxc|cilium\"; ip route | grep -v docker'"
H c05-cartes "A=\$(kubectl -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName=\$M2 -o name); I1=\$(kubectl -n ch39 get pod p-\$M1 -o jsonpath='{.status.podIP}'); I2=\$(kubectl -n ch39 get pod p-\$M2 -o jsonpath='{.status.podIP}'); echo '# bpf endpoint list'; kubectl -n kube-system exec \$A -c cilium-agent -- cilium-dbg bpf endpoint list 2>/dev/null | grep -E \"IP ADDRESS|^\$I2:\"; echo '# bpf ipcache list'; kubectl -n kube-system exec \$A -c cilium-agent -- cilium-dbg bpf ipcache list 2>/dev/null | grep -E \"PREFIX|^\$I1/|^\$I2/|^10.244.0.0/24\""
H c06-capture "$debogueur; A=\$(kubectl -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName=\$M2 -o name); IP1=\$(kubectl -n ch39 get pod p-\$M1 -o jsonpath='{.status.podIP}'); kubectl -n ch39 exec \$D -- timeout 8 tcpdump -ni eth0 -c 40 udp port 8472 > td.txt 2>&1 & timeout 8 kubectl -n kube-system exec \$A -c cilium-agent -- cilium-dbg monitor --type trace > mon.txt 2>&1 & sleep 2; kubectl -n ch39 exec p-\$M2 -- ping -c 1 \$IP1 | head -2; wait; echo '# tcpdump'; grep -B1 ICMP td.txt | head -4; echo '# cilium-dbg monitor'; grep icmp mon.txt | head -2"
H c07-ex-adresses "kubectl proxy --port=8011 >/dev/null & Q=\$!; sleep 1; python3 adresses.py; kill \$Q"
