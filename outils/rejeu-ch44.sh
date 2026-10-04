#!/usr/bin/env bash
# Rejeu du chapitre 44 (durcir les Pods) sur le profil minikube principal. Sorties dans outils/out/ch44r.
# Commence par défaire le durcissement de Colis (defaire-colis.sh), puis refait tout le chapitre.
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/durcissement
O=$RACINE/outils/out/ch44r
section() { echo; echo "### $*"; }
attendre_ns() { while kubectl get ns "$1" >/dev/null 2>&1; do sleep 2; done; }

# --- remise à zéro : uniquement les objets de ce chapitre
for ns in ch44 ch44-base ch44-libre; do kubectl delete ns $ns --wait=false >/dev/null 2>&1; done
for ns in ch44 ch44-base ch44-libre; do attendre_ns $ns; done
kubectl -n colis delete job purge-durcie --ignore-not-found >/dev/null
bash $KIT/defaire-colis.sh
rm -rf "$O"; mkdir -p "$O"; cd "$O"

section "ouverture"
for n in baseline restricted; do echo "\$ ... enforce=$n"; kubectl label --dry-run=server --overwrite ns colis pod-security.kubernetes.io/enforce=$n; done

section "pod refusé, deployment accepté"
kubectl create ns ch44
kubectl label ns ch44 pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=v1.37
kubectl -n ch44 run nginx-brut --image=nginx:1.30-alpine
kubectl -n ch44 create deployment nginx-brut --image=nginx:1.30-alpine
sleep 5
kubectl -n ch44 get deployment,replicaset
kubectl -n ch44 get events --field-selector reason=FailedCreate -o custom-columns=OBJET:.involvedObject.name,MESSAGE:.message | head -2
kubectl -n ch44 delete deployment nginx-brut >/dev/null

section "étape 1"
kubectl apply -f $KIT/nginx-etape1.yaml
sleep 10
kubectl -n ch44 get pod nginx-durci
kubectl -n ch44 get events --field-selector involvedObject.name=nginx-durci,type=Warning -o custom-columns=RAISON:.reason,MESSAGE:.message | head -2
kubectl -n ch44 delete pod nginx-durci --wait >/dev/null

section "étape 2"
kubectl apply -f $KIT/nginx-etape2.yaml
sleep 10
kubectl -n ch44 get pod nginx-durci
kubectl -n ch44 logs nginx-durci | tail -4
kubectl -n ch44 delete pod nginx-durci --wait >/dev/null

section "étape 3"
kubectl apply -f $KIT/nginx-durci.yaml
kubectl -n ch44 wait --for=condition=Ready pod/nginx-durci --timeout=60s
kubectl -n ch44 exec nginx-durci -- sh -c 'id; wget -qO- http://127.0.0.1/ | grep -o "<title>.*</title>"; grep -E "^(CapPrm|CapEff|CapBnd|NoNewPrivs|Seccomp):" /proc/1/status; touch /etc/essai; netstat -ltn | grep ":80 "'

section "comparaison"
kubectl create ns ch44-libre >/dev/null
kubectl -n ch44-libre run nginx-brut --image=nginx:1.30-alpine >/dev/null
kubectl -n ch44-libre wait --for=condition=Ready pod/nginx-brut --timeout=60s >/dev/null
kubectl -n ch44-libre exec nginx-brut -- sh -c 'id -u; grep -E "^(CapPrm|CapEff|CapBnd|NoNewPrivs|Seccomp):" /proc/1/status; cat /proc/sys/net/ipv4/ip_unprivileged_port_start'
capsh --decode=00000000a80425fb

section "baseline"
kubectl create ns ch44-base >/dev/null
kubectl label ns ch44-base pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/enforce-version=v1.37 >/dev/null
essai() { echo "\$ $1"; kubectl -n ch44-base run "$1" --image=busybox:1.37 --restart=Never --overrides="{\"apiVersion\":\"v1\",\"spec\":$2}" 2>&1; }
essai privilegie '{"containers":[{"name":"c","image":"busybox:1.37","command":["sleep","3600"],"securityContext":{"privileged":true}}]}'
essai hote-fs '{"containers":[{"name":"c","image":"busybox:1.37","command":["sleep","3600"],"volumeMounts":[{"name":"h","mountPath":"/hote"}]}],"volumes":[{"name":"h","hostPath":{"path":"/"}}]}'
essai hote-reseau '{"hostNetwork":true,"containers":[{"name":"c","image":"busybox:1.37","command":["sleep","3600"]}]}'
essai cap-netadmin '{"containers":[{"name":"c","image":"busybox:1.37","command":["sleep","3600"],"securityContext":{"capabilities":{"add":["NET_ADMIN"]}}}]}'
essai cap-netraw '{"containers":[{"name":"c","image":"busybox:1.37","command":["sleep","3600"],"securityContext":{"capabilities":{"add":["NET_RAW"]}}}]}'
essai ordinaire '{"containers":[{"name":"c","image":"busybox:1.37","command":["sleep","3600"]}]}'

section "colis : warn et audit"
kubectl label ns colis pod-security.kubernetes.io/warn=restricted pod-security.kubernetes.io/warn-version=v1.37 \
  pod-security.kubernetes.io/audit=restricted pod-security.kubernetes.io/audit-version=v1.37
kubectl -n colis rollout restart deployment/redis
kubectl -n colis rollout status deployment/redis --timeout=180s >/dev/null

section "colis : api, api-canari, worker"
kubectl -n colis patch deployment api --patch-file $KIT/colis/api.yaml
kubectl -n colis patch deployment api-canari --patch-file $KIT/colis/api.yaml
kubectl -n colis patch deployment worker --patch-file $KIT/colis/worker.yaml
kubectl -n colis rollout status deployment/api --timeout=180s >/dev/null
kubectl -n colis rollout status deployment/api-canari --timeout=180s >/dev/null
curl -s http://192.168.49.100/api/sante; echo
curl -s -X POST http://192.168.49.100/api/colis -H 'Content-Type: application/json' -d '{"destinataire":"Essai ch44","depart":"Brest","arrivee":"Nantes","poids_kg":2}' | jq -c '{id, statut}'
for i in $(seq 1 60); do W=$(kubectl -n colis get pods -l app.kubernetes.io/name=worker --field-selector=status.phase=Running -o name | head -1); [ -n "$W" ] && break; sleep 2; done
sleep 8
kubectl -n colis logs $W --tail=2
kubectl -n colis exec $W -- sh -c 'id; grep -E "^(CapEff|NoNewPrivs|Seccomp):" /proc/1/status; ls /var/run/secrets/kubernetes.io'
curl -s http://192.168.49.100/api/colis | jq -c '[.[] | select(.destinataire == "Essai ch44") | {id, statut}] | max_by(.id)'

section "colis : web, redis, purge"
kubectl -n colis patch deployment web --patch-file $KIT/colis/web.yaml
kubectl -n colis patch deployment redis --patch-file $KIT/colis/redis.yaml
kubectl -n colis patch cronjob purge --patch-file $KIT/colis/purge.yaml
kubectl -n colis rollout status deployment/web --timeout=180s >/dev/null
kubectl -n colis rollout status deployment/redis --timeout=180s >/dev/null
kubectl -n colis exec deploy/redis -- sh -c 'id; redis-cli ping'
sleep 3
curl -s -o /dev/null -w "page d'accueil : %{http_code}\n" http://192.168.49.100/
kubectl -n colis create job purge-durcie --from=cronjob/purge
kubectl -n colis wait --for=condition=Complete job/purge-durcie --timeout=120s
kubectl -n colis logs job/purge-durcie --tail=1

section "colis : postgres"
kubectl -n colis patch statefulset postgres --patch-file $KIT/colis/postgres.yaml
kubectl -n colis rollout status statefulset/postgres --timeout=300s
kubectl -n colis logs postgres-0 --tail=2
kubectl -n colis exec postgres-0 -- sh -c 'id; ls -lnd /var/lib/postgresql/18/docker'
sleep 5
curl -s http://192.168.49.100/api/colis | jq length
curl -s -X POST http://192.168.49.100/api/colis -H 'Content-Type: application/json' -d '{"destinataire":"Essai ch44 bis","depart":"Rennes","arrivee":"Lille","poids_kg":1}' | jq -c '{id, statut}'

section "colis : enforce"
kubectl label --dry-run=server --overwrite ns colis pod-security.kubernetes.io/enforce=restricted
kubectl label --overwrite ns colis pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=v1.37
kubectl get ns colis -o json | jq -r '.metadata.labels | to_entries[] | select(.key | startswith("pod-security")) | "\(.key)=\(.value)"'
kubectl -n colis get pods

section "tout le cluster"
for n in baseline restricted; do echo "===== $n"; kubectl label --dry-run=server --overwrite ns --all pod-security.kubernetes.io/enforce=$n 2>&1 | grep '^Warning' | sed 's/^Warning: //'; done

section "ex1"
cat > dormeur.yaml <<'Y'
apiVersion: v1
kind: Pod
metadata:
  name: dormeur
  namespace: ch44
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: c
    image: busybox:1.37
    command: [sleep, "3600"]
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: [ALL]
Y
kubectl apply -f dormeur.yaml
kubectl -n ch44 wait --for=condition=Ready pod/dormeur --timeout=60s
kubectl -n ch44 exec dormeur -- id

section "ex3"
python3 $KIT/corrige/niveau-pss.py

section "ex4"
P=$(kubectl -n colis get pods --field-selector=status.phase=Running -o name | grep -m1 '^pod/api-' | cut -d/ -f2)
kubectl -n colis debug $P --image=busybox:1.37 --target=api -- sleep 30
kubectl -n colis debug $P --image=busybox:1.37 --target=api --profile=restricted -- sh -c 'id; ps -o user,pid,args | head -3'
sleep 8
C=$(kubectl -n colis get pod $P -o json | jq -r '.status.ephemeralContainerStatuses[-1].name')
kubectl -n colis logs $P -c $C

echo; echo "### fin"
