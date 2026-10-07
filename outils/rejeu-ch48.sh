#!/usr/bin/env bash
# Rejeu du chapitre 48 (déboguer) sur le profil minikube principal. Sorties dans outils/out/ch48r.
# Suppose le registre du cours en marche (images colis/api:2.1 et colis/web:1.1).
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/deboguer
O=$RACINE/outils/out/ch48r
N=ch48
section() { echo; echo "### $*"; }
k() { kubectl -n $N "$@"; }
pod() { k get pods -l app.kubernetes.io/name="$1" -o name | head -1 | cut -d/ -f2; }
# lance une commande dans un conteneur éphémère, attend sa fin, affiche sa sortie
ephemere() {  # $1 pod, $2 nom du conteneur, $3 image, $4 cible (ou -), reste : commande
  local p=$1 c=$2 img=$3 cible=$4; shift 4
  local opt=(); [ "$cible" != - ] && opt=(--target="$cible")
  k debug "$p" -c "$c" --image="$img" "${opt[@]}" -- "$@" 2>&1 | grep -v -E '^(Targeting|All commands|If you)'
  for _ in $(seq 1 60); do
    [ "$(k get pod "$p" -o jsonpath="{.status.ephemeralContainerStatuses[?(@.name==\"$c\")].state.terminated.reason}")" != "" ] && break
    sleep 1
  done
  k logs "$p" -c "$c"
}
noeud() {  # une commande sur le nœud, par kubectl debug node, sortie affichée puis Pod supprimé
  local p
  p=$(kubectl debug node/minikube --image=busybox:1.37 --profile=sysadmin -- chroot /host sh -c "$1" 2>&1 \
      | sed -n 's/^Creating debugging pod \([^ ]*\) .*/\1/p')
  echo "(Pod $p)"
  for _ in $(seq 1 60); do
    case $(kubectl get pod "$p" -o jsonpath='{.status.phase}') in Succeeded|Failed) break ;; esac; sleep 1
  done
  kubectl logs "$p"; kubectl delete pod "$p" --wait=false >/dev/null
}

# --- remise à zéro
k delete pod worker-enquete fin-brutale fin-propre --ignore-not-found >/dev/null 2>&1
kubectl delete ns $N --ignore-not-found >/dev/null 2>&1
while kubectl get ns $N >/dev/null 2>&1; do sleep 2; done
rm -rf "$O"; mkdir -p "$O"; cd "$O"

section "installation"
bash $KIT/installer.sh
kubectl apply -f $KIT/annuaire.yaml
sleep 75
k port-forward svc/web 8048:80 > port-forward.log 2>&1 &
PF=$!
for _ in $(seq 1 30); do curl -s -o /dev/null http://localhost:8048/ && break; sleep 1; done

section "symptome"
for chemin in / /api/colis; do
  printf '%-12s %s\n' "$chemin" "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8048$chemin)"
done

section "vue d'ensemble"
k get deploy
k get pods -o wide

section "exercice 3 : etat-pods"
python3 $KIT/corrige/etat-pods.py $N

section "web : journal"
k logs deploy/web | grep -v kube-probe | tail -2

section "service api"
k get svc api -o wide
k get endpointslices -l kubernetes.io/service-name=api
echo "\$ get pods -l app.kubernetes.io/name=colis-api"
k get pods -l app.kubernetes.io/name=colis-api 2>&1
k get pods -l app.kubernetes.io/name=api --show-labels

section "selecteur corrige"
k patch svc api --type=merge -p '{"spec":{"selector":{"app.kubernetes.io/name":"api"}}}'
sleep 3
k get endpointslices -l kubernetes.io/service-name=api
k get endpointslices -l kubernetes.io/service-name=api -o json | jq -c '.items[].endpoints[] | {ip: .addresses[0], conditions}'
printf '%-12s %s\n' /api/colis "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8048/api/colis)"
k logs deploy/web | grep -v kube-probe | tail -2

section "api : describe"
A=$(pod api)
k describe pod $A > describe-api.txt
sed -n '/^Containers:/,/^    Ready:/p' describe-api.txt
sed -n '/^Conditions:/,/^Volumes:/p' describe-api.txt
sed -n '/^Events:/,$p' describe-api.txt

section "api : events"
k events --for pod/$A
section "api : events warning"
k events --types=Warning

section "api : logs"
echo "\$ logs (courant)"; k logs $A --tail=3
echo "\$ logs --previous"; k logs $A --previous --tail=3
k get pod $A -o jsonpath='{.status.containerStatuses[0].lastState}{"\n"}' | jq .

section "api : dns depuis un conteneur ephemere"
ephemere $A dns busybox:1.37 - sh -c 'cat /etc/resolv.conf; echo; nslookup base; nslookup postgres'
k get pod $A -o jsonpath='{range .spec.ephemeralContainers[*]}{.name} {.image}{"\n"}{end}'

section "api : correction"
k set env deploy/api 'COLIS_DB=postgresql://colis:$(POSTGRES_PASSWORD)@postgres:5432/colis'
k rollout status deploy/api --timeout=120s
k get pods -l app.kubernetes.io/name=api
for chemin in /api/pret /api/colis; do
  printf '%-12s %s %s\n' "$chemin" "$(curl -s -o corps.txt -w '%{http_code}' http://localhost:8048$chemin)" "$(head -c 120 corps.txt)"
done

section "worker"
W=$(pod worker)
k get pod $W
echo "\$ logs"; k logs $W --tail=4
echo "\$ logs --previous"; k logs $W --previous --tail=4
k get pod $W -o jsonpath='{.status.containerStatuses[0].lastState.terminated}{"\n"}' | jq -c '{reason, exitCode, startedAt, finishedAt}'
k get pod $W -o jsonpath='{.status.containerStatuses[0].state.waiting}{"\n"}' | jq -c .

section "noeud"
noeud "crictl ps -a --name worker | cut -c1-110; echo; ls /var/log/pods | grep ^ch48_; echo; ls -l /var/log/pods/ch48_worker-*/worker/; echo; tail -c 300 \$(ls /var/log/pods/ch48_worker-*/worker/*.log | head -1); echo; journalctl -u kubelet --since '-15min' --no-pager | grep -i 'back-off' | grep -m2 $W | cut -c1-400; echo; grep -i -E 'containerLog' /var/lib/kubelet/config.yaml || echo '(containerLogMaxSize non réglé : 10Mi par défaut)'"

section "worker : copie"
k debug $W --copy-to=worker-enquete --container=worker -- sleep 3600 2>&1
k wait --for=condition=Ready pod/worker-enquete --timeout=90s
k get pods worker-enquete
k exec worker-enquete -c worker -- ls /app/colis
k exec worker-enquete -c worker -- python -c 'import colis.worker; print("colis.worker : ok")'
k get pod worker-enquete -o json | jq -c '{labels: .metadata.labels, owner: .metadata.ownerReferences}'
k delete pod worker-enquete --wait=false

section "worker : correction"
k patch deploy worker --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/command/2","value":"colis.worker"}]'
k rollout status deploy/worker --timeout=120s
curl -s -X POST http://localhost:8048/api/colis -H 'Content-Type: application/json' \
  -d '{"destinataire":"Atelier Brun","depart":"Paris","arrivee":"Lyon","poids_kg":2.5}' | jq -c '{id, statut}'
sleep 4
k logs deploy/worker --tail=2
k get pods

section "message de fin"
k run fin-brutale --image=busybox:1.37 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"fin-brutale","image":"busybox:1.37","terminationMessagePolicy":"FallbackToLogsOnError","command":["sh","-c","echo demarrage; echo \"configuration absente : /etc/colis/regles.yaml\" >&2; exit 3"]}]}}'
k run fin-propre --image=busybox:1.37 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"fin-propre","image":"busybox:1.37","command":["sh","-c","echo beaucoup de bruit; echo \"quota epuise pour le client 42\" > /dev/termination-log; exit 4"]}]}}'
sleep 10
for p in fin-brutale fin-propre; do
  k get pod $p -o jsonpath='{.status.containerStatuses[0].state.terminated}{"\n"}' | jq -c '{reason, exitCode, message}'
done
k describe pod fin-brutale | sed -n '/^    State:/,/^    Ready:/p'

section "annuaire : exec"
D=$(pod annuaire)
k exec $D -- sh 2>&1 | tail -1
k run -i --rm essai-dns --image=nicolaka/netshoot:v0.14 --restart=Never -- \
  dig +tries=1 +timeout=2 @annuaire.ch48.svc.cluster.local api.colis.interne 2>&1 | grep -v '^pod '

section "annuaire : ephemere"
ephemere $D enquete nicolaka/netshoot:v0.14 coredns sh -c 'ps -o user,pid,args; echo; ss -lunp; echo; cat /proc/1/root/etc/coredns/Corefile; echo; tr "\0" "\n" < /proc/1/environ | grep -v _PORT | head -4'
k get pod $D -o json | jq -c '.spec.containers[0] | {args, ports}'

section "annuaire : correction"
k get cm annuaire -o json | jq '.data.Corefile |= sub("colis.interne:53"; "colis.interne:1053")' | kubectl apply -f -
k rollout restart deploy/annuaire
k rollout status deploy/annuaire --timeout=90s
sleep 5
k run -i --rm essai-dns --image=nicolaka/netshoot:v0.14 --restart=Never -- \
  dig +short +tries=1 +timeout=2 @annuaire.ch48.svc.cluster.local api.colis.interne 2>&1 | grep -v '^pod '
D2=$(pod annuaire)
echo "conteneurs éphémères de $D2 : $(k get pod $D2 -o jsonpath='{.spec.ephemeralContainers[*].name}')"

section "exercice 2 : codes de sortie"
k run code-faute --image=busybox:1.37 --restart=Never -- sh -c 'comand-introuvable' >/dev/null
k run code-droits --image=busybox:1.37 --restart=Never -- sh -c '/etc/passwd' >/dev/null
k run code-binaire --image=busybox:1.37 --restart=Never --command -- /bin/introuvable >/dev/null
k run code-pid1 --image=busybox:1.37 --restart=Never -- sh -c 'kill -KILL $$$$; echo "PID $$$$ toujours là, statut de kill : $?"' >/dev/null
k run code-enfant --image=busybox:1.37 --restart=Never -- sh -c 'sh -c "kill -KILL \$$$$"; echo "le shell enfant a fini avec le statut $?"; exit 137' >/dev/null
k run code-dollar --image=busybox:1.37 --restart=Never -- sh -c 'kill -KILL $$' >/dev/null
sleep 12
for nom in faute droits binaire pid1 enfant dollar; do
  printf '%-13s ' code-$nom; k get pod code-$nom -o jsonpath='{.status.containerStatuses[0].state.terminated}' | jq -c '{reason, exitCode}'
done
for nom in pid1 enfant dollar; do echo "\$ logs code-$nom"; k logs code-$nom; done
k get pod code-pid1 -o jsonpath='{.spec.containers[0].args}{"\n"}'
python3 $KIT/corrige/etat-pods.py $N | grep -A1 code-
k delete pod code-faute code-droits code-binaire code-pid1 code-enfant code-dollar fin-brutale fin-propre --wait=false >/dev/null

section "exercice 4 : copie et service"
WEB=$(pod web)
k get rs -l app.kubernetes.io/name=web -o jsonpath='{.items[0].spec.selector.matchLabels}{"\n"}'
k get svc web -o jsonpath='{.spec.selector}{"\n"}'
echo "\$ debug --copy-to=web-essai --set-image"
k debug $WEB --copy-to=web-essai --set-image=web=host.minikube.internal:5001/colis/web:1.1 2>&1
sleep 3
k get pod web-essai 2>&1
k get events --field-selector reason=SuccessfulDelete -o custom-columns=OBJET:.involvedObject.name,MESSAGE:.message | grep -e OBJET -e essai
echo "\$ debug --copy-to=web-essai --container=web --image"
k debug $WEB --copy-to=web-essai --container=web --image=host.minikube.internal:5001/colis/web:1.1 --keep-readiness 2>&1
k get pod web-essai -o json | jq -c '{labels: .metadata.labels, owner: .metadata.ownerReferences, securityContext: .spec.containers[0].securityContext, readiness: (.spec.containers[0].readinessProbe != null)}'
k label pod web-essai app.kubernetes.io/name=web
k wait --for=condition=Ready pod/web-essai --timeout=60s >/dev/null
sleep 2
k get endpointslices -l kubernetes.io/service-name=web -o json | jq -r '.items[].endpoints[] | "\(.targetRef.name) \(.addresses[0]) prêt=\(.conditions.ready)"'
k get pod web-essai -o jsonpath='{.metadata.ownerReferences}{"(aucun propriétaire)\n"}'
k delete pod web-essai --wait=false >/dev/null

section "events : duree de vie"
k get events -o json | jq -r '.items | length as $n | "\($n) événements dans ch48"'
k get events --field-selector reason=BackOff -o custom-columns=OBJET:.involvedObject.name,COMPTE:.count,PREMIER:.firstTimestamp,DERNIER:.lastTimestamp
kubectl -n kube-system get pod kube-apiserver-minikube -o yaml | grep -c -- '--event-ttl' | sed 's/^0$/--event-ttl absent : 1h par défaut/'

section "journaux du noeud par l'API"
kubectl get --raw "/api/v1/nodes/minikube/proxy/logs/" | sed -n 's/.*href="\([^"]*\)".*/\1/p' | head -8
minikube ssh -- 'sudo grep -q enableSystemLogQuery /var/lib/kubelet/config.yaml || echo "enableSystemLogQuery: true" | sudo tee -a /var/lib/kubelet/config.yaml >/dev/null; sudo systemctl restart kubelet' 2>/dev/null
sleep 15
kubectl get --raw "/api/v1/nodes/minikube/proxy/logs/?query=kubelet&pattern=back-off.*$W&tailLines=3" | cut -c1-260

kill $PF 2>/dev/null
cat port-forward.log | grep -v "^Handling" | head -5
echo; echo "### fin"
