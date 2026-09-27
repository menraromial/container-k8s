#!/usr/bin/env bash
# Grille du défi V : vérifie, pour un Deployment, les huit maillons de la chaîne qui va de l'API au processus.
# Usage : ./verifier.sh <namespace> <deployment>     (profil minikube principal, un nœud)
NS=${1:?namespace}; D=${2:?deployment}
export PATH=~/.local/opt/cours-k8s/bin:$PATH
K="kubectl -n $NS"; ok=0; ko=0
verdict() { if [ "$1" = 0 ]; then echo "OK      $2"; ok=$((ok+1)); else echo "ÉCHEC   $2"; ko=$((ko+1)); fi; }
N() { minikube ssh -- "$@" 2>/dev/null | tr -d '\r'; }
C=/var/lib/minikube/certs/etcd
E() { kubectl -n kube-system exec -i etcd-minikube -- etcdctl --cacert=$C/ca.crt --cert=$C/server.crt --key=$C/server.key "$@" 2>/dev/null; }

# 1. l'objet existe dans l'API, et sa resourceVersion est une révision d'etcd
RV=$($K get deploy $D -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null)
MR=$(E get /registry/deployments/$NS/$D -w json | jq -r '.kvs[0].mod_revision')
[ -n "$RV" ] && [ "$RV" = "$MR" ]; verdict $? "1. le Deployment est dans etcd, resourceVersion $RV = mod_revision $MR"

# 2. un ReplicaSet appartient au Deployment
UD=$($K get deploy $D -o jsonpath='{.metadata.uid}')
RS=$($K get rs -o json | jq -r --arg u "$UD" '.items[] | select(.metadata.ownerReferences[]?.uid==$u) | .metadata.name' | head -1)
[ -n "$RS" ]; verdict $? "2. le ReplicaSet $RS a pour propriétaire le Deployment"

# 3. les Pods appartiennent au ReplicaSet, et sont prêts
UR=$($K get rs $RS -o jsonpath='{.metadata.uid}' 2>/dev/null)
PODS=$($K get pods -o json | jq -r --arg u "$UR" '.items[] | select(.metadata.ownerReferences[]?.uid==$u) | select(.status.conditions[]? | .type=="Ready" and .status=="True") | .metadata.name')
VOULU=$($K get deploy $D -o jsonpath='{.spec.replicas}')
[ -n "$PODS" ] && [ "$(echo "$PODS" | wc -l)" = "$VOULU" ]; verdict $? "3. $VOULU Pod(s) prêt(s) appartiennent au ReplicaSet"
P=$(echo "$PODS" | head -1)

# 4. le scheduler a placé le Pod
NOEUD=$($K get pod $P -o jsonpath='{.spec.nodeName}')
$K get events --field-selector involvedObject.name=$P,reason=Scheduled -o jsonpath='{.items[0].reportingComponent}' | grep -q default-scheduler
verdict $? "4. le Pod $P a été placé sur $NOEUD par default-scheduler"

# 5. le kubelet a démarré le conteneur
$K get events --field-selector involvedObject.name=$P,reason=Started -o jsonpath='{.items[0].reportingComponent}' | grep -q kubelet
verdict $? "5. le kubelet de $NOEUD a démarré son conteneur"

# 6. le runtime a un bac à sable et un conteneur pour ce Pod
S=$(N "sudo crictl pods --name $P --namespace $NS --state ready -q")
CT=$(N "sudo crictl ps --pod $S -q" | head -1)
[ -n "$S" ] && [ -n "$CT" ]; verdict $? "6. containerd : bac à sable ${S:0:13}, conteneur ${CT:0:13}"

# 7. un processus du nœud est le conteneur, dans un cgroup qui porte l'uid du Pod
UP=$($K get pod $P -o jsonpath='{.metadata.uid}' | tr - _)
PID=$(N "sudo crictl inspect $CT" | jq -r .info.pid)
N "cat /proc/$PID/cgroup" | grep -q "pod$UP"; verdict $? "7. le processus $PID est dans le cgroup du Pod (pod$UP)"

# 8. le réseau : l'adresse du Pod vient du greffon CNI, et figure dans les EndpointSlices qui visent le Pod
IP=$($K get pod $P -o jsonpath='{.status.podIP}')
N "sudo cat /run/cni-ipam-state/kindnet/$IP" | grep -q "$S"
A=$?; $K get endpointslices -o json | jq -e --arg ip "$IP" '[.items[].endpoints[]?.addresses[]] | index($ip)' >/dev/null; B=$?
[ $A = 0 ] && [ $B = 0 ]; verdict $? "8. l'adresse $IP a été attribuée au bac à sable par le greffon, et figure dans une EndpointSlice"

echo; echo "$ok vérification(s) réussie(s), $ko en échec"
