#!/usr/bin/env bash
# Rejeu du chapitre 49 (catalogue de pannes) sur le profil minikube principal. Journal sur la sortie standard.
# Suppose le registre du cours en marche (colis/api:2.1, colis/web:1.1).
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/pannes
O=$RACINE/outils/out/ch49r
N=ch49
section() { echo; echo "### $*"; }
k() { kubectl -n $N "$@"; }
ev() { k events --for "$1" | cut -c1-240; }
pod() { k get pods -l app="$1" -o name | head -1 | cut -d/ -f2; }

# --- remise à zéro
k patch cm regles-tarifaires --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1
kubectl label node minikube disque- >/dev/null 2>&1
kubectl delete ns $N --ignore-not-found >/dev/null 2>&1
while kubectl get ns $N >/dev/null 2>&1; do sleep 2; done
rm -rf "$O"; mkdir -p "$O"; cd "$O"

section "installation"
kubectl apply -f $KIT/00-namespace.yaml
for f in $KIT/[01][0-9]-*.yaml; do [ "$(basename $f)" = 00-namespace.yaml ] || kubectl apply -f $f; done
sleep 100

section "vue"
k get pods

section "noeud : capacite"
kubectl get node minikube -o json | jq -c '{capacite: .status.capacity | {cpu, memory, pods}, allouable: .status.allocatable | {cpu, memory}}'
kubectl describe node minikube | sed -n '/^Allocated resources:/,/^Events:/p' | head -9

section "1 trop-gourmand"
k get pod trop-gourmand -o jsonpath='{.status.conditions[0]}{"\n"}' | jq -c '{type, status, reason, message}'
ev pod/trop-gourmand
sed 's/memory: 64Gi/memory: 192Mi/' $KIT/01-trop-gourmand.yaml > trop-gourmand.yaml
k delete pod trop-gourmand --wait=true >/dev/null
kubectl apply -f trop-gourmand.yaml
k wait --for=condition=Ready pod/trop-gourmand --timeout=60s

section "2 mauvais-noeud"
ev pod/mauvais-noeud
kubectl get node minikube --show-labels | tr ',' '\n' | grep -E 'disque|kubernetes.io/hostname|topology'
kubectl label node minikube disque=nvme
k wait --for=condition=Ready pod/mauvais-noeud --timeout=60s
ev pod/mauvais-noeud | tail -4
kubectl label node minikube disque-

section "3 volume-introuvable"
ev pod/volume-introuvable
k get pvc donnees
k events --for pvc/donnees | cut -c1-200
kubectl get storageclass
echo "\$ patch pvc storageClassName"
k patch pvc donnees --type=merge -p '{"spec":{"storageClassName":"standard"}}' 2>&1 | cut -c1-300
k delete pod volume-introuvable --wait=true >/dev/null
k delete pvc donnees --wait=true >/dev/null
sed 's/storageClassName: rapide/storageClassName: standard/' $KIT/03-volume-introuvable.yaml | kubectl apply -f -
k wait --for=condition=Ready pod/volume-introuvable --timeout=90s
k get pvc donnees

section "4 etiquette-absente"
k get pod etiquette-absente -o jsonpath='{.status.containerStatuses[0].state.waiting}{"\n"}' | jq -c '{reason, message}'
k events --for pod/etiquette-absente -o json 2>/dev/null | jq -r '[.items[] | select(.reason=="Failed")][0].message'
curl -s http://localhost:5001/v2/colis/api/tags/list; echo
k set image pod/etiquette-absente api=host.minikube.internal:5001/colis/api:2.1
k wait --for=condition=Ready pod/etiquette-absente --timeout=60s

section "5 registre-injoignable"
k events --for pod/registre-injoignable -o json 2>/dev/null | jq -r '[.items[] | select(.reason=="Failed")][0].message'
k set image pod/registre-injoignable api=host.minikube.internal:5001/colis/api:2.1
k wait --for=condition=Ready pod/registre-injoignable --timeout=60s

section "6 cle-manquante"
k get pod cle-manquante -o jsonpath='{.status.containerStatuses[0].state.waiting}{"\n"}' | jq -c '{reason, message}'
k get secret colis-db -o json | jq -c '.data | keys'
date +%T
k patch secret colis-db --type=merge -p '{"stringData":{"POSTGRES_MOT_DE_PASSE":"mot-de-passe-d-essai"}}'
k wait --for=condition=Ready pod/cle-manquante --timeout=120s
date +%T
k get pod cle-manquante

section "7 configmap-absente"
ev pod/configmap-absente
date +%T
k create configmap colis-regles --from-literal=tarif=4.90
k wait --for=condition=Ready pod/configmap-absente --timeout=180s
sleep 2
date +%T
k logs configmap-absente

section "8 memoire"
M=$(pod memoire)
k get pod $M
k get pod $M -o jsonpath='{.status.containerStatuses[0].lastState.terminated}{"\n"}' | jq -c '{reason, exitCode, startedAt, finishedAt}'
k logs $M --tail=3
minikube ssh -- 'sudo dmesg | grep "Memory cgroup out of memory" | tail -1' 2>/dev/null | cut -c1-200
k set resources deploy/memoire --limits=memory=512Mi --requests=memory=320Mi
k rollout status deploy/memoire --timeout=120s
sleep 10
k get pods -l app=memoire
k logs deploy/memoire --tail=1

section "9 tache-finie"
T=$(pod tache-finie)
k get pod $T
k get pod $T -o jsonpath='{.status.containerStatuses[0].lastState.terminated}{"\n"}' | jq -c '{reason, exitCode}'
k logs $T
k delete deploy tache-finie
k create job purge --image=busybox:1.37 -- sh -c 'echo purge des colis de plus de 30 jours; echo 0 colis supprimé'
k wait --for=condition=Complete job/purge --timeout=60s
k get job purge
k get pods -l job-name=purge

section "10 vie-impatiente"
V=$(pod vie-impatiente)
k get pod $V
k describe pod $V | sed -n '/^    State:/,/^    Ready:/p'
k events --for pod/$V | grep -E 'Unhealthy|Killing|BackOff' | cut -c1-220
cat > demarrage.json <<'EOF'
[{"op":"add","path":"/spec/template/spec/containers/0/startupProbe",
  "value":{"httpGet":{"path":"/sante","port":"http"},"periodSeconds":5,"failureThreshold":12}}]
EOF
k patch deploy vie-impatiente --type=json --patch-file demarrage.json
date +%T
k rollout status deploy/vie-impatiente --timeout=120s
date +%T
sleep 40
k get pods -l app=vie-impatiente

section "11 pas-prete"
k get deploy pas-prete
k get endpointslices -l kubernetes.io/service-name=pas-prete -o json | jq -c '[.items[].endpoints[] | {ip: .addresses[0], ready: .conditions.ready}]'
P=$(pod pas-prete)
ev pod/$P | grep Unhealthy
k exec $P -- python -c "import urllib.request as u
for c in ('/prete', '/pret'):
    try: print(c, u.urlopen('http://localhost:8000' + c).status)
    except Exception as e: print(c, e)"
k patch deploy pas-prete --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/pret"}]'
k rollout status deploy/pas-prete --timeout=120s
k get deploy pas-prete

section "12 dns-coupe"
k exec client -- nslookup -timeout=3 pas-prete.ch49.svc.cluster.local 2>&1
k exec client -- wget -q -T 3 -O - http://pas-prete:8000/sante 2>&1
SVC=$(k get svc pas-prete -o jsonpath='{.spec.clusterIP}')
k exec client -- wget -q -T 3 -O - http://$SVC:8000/sante 2>&1; echo
k get networkpolicy refus-sortie -o jsonpath='{.spec}{"\n"}' | jq -c .
cat > dns.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: dns
  namespace: ch49
spec:
  podSelector:
    matchLabels:
      app: client
  policyTypes: [Egress]
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
EOF
kubectl apply -f dns.yaml
sleep 3
k exec client -- nslookup pas-prete.ch49.svc.cluster.local 2>&1
k exec client -- wget -q -T 3 -O - http://pas-prete:8000/sante; echo

section "13 suppression-bloquee"
k delete cm regles-tarifaires --wait=false
sleep 3
k get cm regles-tarifaires -o json | jq -c '{nom: .metadata.name, suppression: .metadata.deletionTimestamp, finaliseurs: .metadata.finalizers}'
echo "\$ delete cm (avec attente, 10 s)"
timeout 10 kubectl -n $N delete cm regles-tarifaires 2>&1; echo "code de retour : $?"
k patch cm regles-tarifaires --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
sleep 2
k get cm regles-tarifaires 2>&1

section "bilan"
k get pods
echo; echo "### fin"
