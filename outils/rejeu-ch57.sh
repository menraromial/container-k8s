#!/usr/bin/env bash
# Chapitre 57 : GitOps avec Argo CD. Repart de zéro : supprime les namespaces argocd, git et colis-staging
# et les CRD d'Argo CD, puis rejoue tout le chapitre. Sorties : outils/out/ch57r.
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/gitops
O=$RACINE/outils/out/ch57r; rm -rf $O; mkdir -p $O && cd $O
section() { echo; echo "### $*"; }
heure() { date +%s.%N; }
duree() { echo "$(echo "$(heure) - $1" | bc | cut -c1-5) s"; }
ARGOCD=https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.4/manifests/install.yaml
MDP_GIT=depot-du-cours-57
GIT_LOCAL=http://cours:$MDP_GIT@localhost:3030/cours/colis-config.git
DEPOT=http://gitea.git.svc.cluster.local:3000/cours/colis-config.git
app() { kubectl -n argocd get application $1 -o jsonpath="$2" 2>/dev/null; }
etat() { echo "$(app $1 '{.status.sync.status} {.status.health.status} {.status.sync.revision}' | cut -c1-30)"; }
web() { curl -s --max-time 5 --resolve colis-staging.local:80:192.168.49.102 "http://colis-staging.local/api$1"; }
# enregistre et pousse le dépôt local ; affiche la révision poussée
pousser() {
  git -C $O/depot add -A
  git -C $O/depot commit --quiet --message "$1"
  git -C $O/depot push --quiet origin main 2>&1 | grep -v "^remote:"
  git -C $O/depot rev-parse HEAD
}
attendre_revision() { # application, révision, délai max : temps pour qu'Argo CD voie la révision
  local d=$(heure)
  for i in $(seq 1 ${3:-300}); do [ "$(app $1 '{.status.sync.revision}')" = "$2" ] && break; sleep 1; done
  echo "révision ${2:0:7} vue par Argo CD après $(duree $d)"
}
remplacer() { # fichier, ancien, nouveau
  python3 -c "import sys; p=sys.argv[1]; s=open(p).read(); assert sys.argv[2] in s; open(p,'w').write(s.replace(sys.argv[2], sys.argv[3]))" "$@"
}

# --- remise à zéro
for a in $(kubectl -n argocd get applications -o name 2>/dev/null); do
  kubectl -n argocd patch $a --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1
done
kubectl delete ns colis-staging argocd git --ignore-not-found --wait=true >/dev/null
kubectl delete crd applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io --ignore-not-found >/dev/null
kubectl delete clusterrole,clusterrolebinding -l app.kubernetes.io/part-of=argocd --ignore-not-found >/dev/null
kubectl get pv -o json | jq -r '.items[] | select(.status.phase == "Released") | .metadata.name' | while read -r pv; do kubectl delete pv "$pv" >/dev/null; done

section "gitea"
kubectl apply -f $KIT/gitea.yaml
kubectl -n git rollout status deployment/gitea --timeout=300s
kubectl -n git exec deploy/gitea -- gitea admin user create --username cours --password $MDP_GIT --email cours@example.com --admin --must-change-password=false 2>&1 | tail -1
kubectl -n git port-forward svc/gitea 3030:3000 >/dev/null 2>&1 & PFG=$!
trap 'kill $PFG ${PFA:-} 2>/dev/null' EXIT
for i in $(seq 1 30); do curl -s -o /dev/null --max-time 2 http://localhost:3030/api/healthz && break; sleep 1; done
curl -s -u cours:$MDP_GIT -X POST -H 'Content-Type: application/json' -d '{"name":"colis-config","private":true,"default_branch":"main"}' \
  http://localhost:3030/api/v1/user/repos | jq -c '{full_name, private}'
cp -r $KIT/depot depot
git -C depot init --quiet --initial-branch=main
git -C depot config user.name "Équipe Colis"
git -C depot config user.email "colis@example.com"
git -C depot remote add origin $GIT_LOCAL
pousser "Colis 2.2.0 : base et préproduction" | tail -1
git -C depot log --oneline
find depot -path depot/.git -prune -o -type f -print | sed 's#^depot/##' | sort
for i in $(seq 1 24); do kubectl -n git top pods >/dev/null 2>&1 && break; sleep 5; done
kubectl -n git top pods

section "argocd"
kubectl create namespace argocd
d=$(heure)
kubectl apply -n argocd --server-side -f $ARGOCD | grep -c "serverside-applied" | sed 's/^/objets appliqués : /'
for x in $(kubectl -n argocd get deploy -o name) statefulset/argocd-application-controller; do kubectl -n argocd rollout status $x --timeout=600s >/dev/null; done
echo "prêt après $(duree $d)"
kubectl -n argocd get pods
kubectl get crd -o name | grep argoproj
kubectl -n argocd scale deployment argocd-dex-server argocd-notifications-controller --replicas=0
sleep 40
for i in $(seq 1 24); do [ "$(kubectl -n argocd top pods --no-headers 2>/dev/null | wc -l)" = 5 ] && break; sleep 5; done
kubectl -n argocd top pods
argocd version --client --short

section "connexion"
MDP=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
echo "mot de passe initial : ${MDP:0:4}... (${#MDP} caractères)"
kubectl -n argocd port-forward svc/argocd-server 8080:443 >/dev/null 2>&1 & PFA=$!
for i in $(seq 1 30); do curl -sk -o /dev/null --max-time 2 https://localhost:8080/healthz && break; sleep 1; done
argocd login localhost:8080 --username admin --password "$MDP" --insecure
argocd repo add $DEPOT --username cours --password $MDP_GIT
argocd repo list
kubectl -n argocd get secrets -l argocd.argoproj.io/secret-type=repository -o custom-columns=SECRET:.metadata.name,TYPE:.metadata.labels.argocd\\.argoproj\\.io/secret-type

section "application"
kubectl create namespace colis-staging
kubectl -n colis-staging create secret generic colis-db --from-literal=POSTGRES_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')"
kubectl apply -f $KIT/application.yaml
sleep 10
etat colis-staging
argocd app get colis-staging | sed -n '/^GROUP/,$p'
argocd app diff colis-staging | grep -E "^=====" | head -20

section "synchronisation"
d=$(heure)
argocd app sync colis-staging | sed -n '/^Operation:/,/^Duration:/p'
argocd app wait colis-staging --health --timeout 300 >/dev/null
echo "en bonne santé après $(duree $d)"
etat colis-staging
argocd app get colis-staging | sed -n '/^GROUP/,$p'
kubectl -n colis-staging get pods
web /sante | jq -c .

section "changement"
remplacer depot/base/kustomization.yaml "COLIS_VERSION=2.2.0" "COLIS_VERSION=2.2.1"
remplacer depot/base/kustomization.yaml 'newTag: "2.2.0"' 'newTag: "2.2.1"'
git -C depot diff
d=$(heure)
REV=$(pousser "Colis 2.2.1" | tail -1)
echo "révision poussée : ${REV:0:7}"
attendre_revision colis-staging $REV 300
etat colis-staging
kubectl -n argocd get configmap argocd-cm -o jsonpath='timeout.reconciliation : {.data.timeout\.reconciliation}{"\n"}'
argocd app sync colis-staging >/dev/null
argocd app wait colis-staging --health --timeout 300 >/dev/null
web /sante | jq -c .
argocd app history colis-staging

section "automatique"
kubectl -n argocd patch application colis-staging --type=merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
curl -s -u cours:$MDP_GIT -X POST -H 'Content-Type: application/json' http://localhost:3030/api/v1/repos/cours/colis-config/hooks \
  -d '{"type":"gitea","active":true,"events":["push"],"config":{"url":"https://argocd-server.argocd.svc.cluster.local/api/webhook","content_type":"json"}}' | jq -c '{id, type, events, url: .config.url}'
remplacer depot/overlays/staging/kustomization.yaml "- name: web
  count: 1" "- name: web
  count: 2"
git -C depot diff | grep "^[-+] "
d=$(heure)
REV=$(pousser "Préproduction : deux répliques du web" | tail -1)
attendre_revision colis-staging $REV 300
for i in $(seq 1 120); do [ "$(kubectl -n colis-staging get deployment web -o jsonpath='{.status.readyReplicas}')" = 2 ] && break; sleep 1; done
echo "deux Pods web prêts $(duree $d) après le push"

section "derive"
d=$(heure)
kubectl -n colis-staging scale deployment api --replicas=3
for i in $(seq 1 240); do [ "$(kubectl -n colis-staging get deployment api -o jsonpath='{.spec.replicas}')" = 1 ] && break; sleep 0.5; done
echo "replicas ramené à $(kubectl -n colis-staging get deployment api -o jsonpath='{.spec.replicas}') après $(duree $d)"
d=$(heure)
kubectl -n colis-staging delete service web
for i in $(seq 1 240); do kubectl -n colis-staging get service web >/dev/null 2>&1 && break; sleep 0.5; done
echo "Service web recréé après $(duree $d)"
argocd app history colis-staging | tail -4

section "elagage"
remplacer depot/base/kustomization.yaml "- purge.yaml
" ""
git -C depot rm --quiet base/purge.yaml
git -C depot status --short
REV=$(pousser "Préproduction : pas de purge" | tail -1)
attendre_revision colis-staging $REV 300
sleep 5
kubectl -n colis-staging get cronjob 2>&1

section "hpa"
cp $KIT/hpa.yaml depot/overlays/staging/hpa.yaml
remplacer depot/overlays/staging/kustomization.yaml "- namespace.yaml
" "- namespace.yaml
- hpa.yaml
"
REV=$(pousser "Préproduction : un HPA pour l'API" | tail -1)
attendre_revision colis-staging $REV 300
d=$(date +%s)
for i in $(seq 1 18); do
  echo "$(( $(date +%s) - d )) s  replicas=$(kubectl -n colis-staging get deployment api -o jsonpath='{.spec.replicas}')  $(etat colis-staging | cut -d' ' -f1)"
  sleep 5
done | uniq -f1
kubectl -n colis-staging get events --field-selector involvedObject.name=api,reason=ScalingReplicaSet -o custom-columns=MESSAGE:.message,NOMBRE:.count | tail -4
kubectl -n colis-staging get hpa api

section "app of apps"
mkdir -p depot/apps depot/quotas/staging
cp $KIT/racine/colis-staging.yaml $KIT/racine/quotas-staging.yaml depot/apps/
cp $KIT/quotas/quota.yaml depot/quotas/staging/
REV=$(pousser "Applications déclarées dans le dépôt" | tail -1)
kubectl apply -f $KIT/racine.yaml
for i in $(seq 1 120); do [ "$(app quotas-staging '{.status.health.status}')" = Healthy ] && [ "$(app racine '{.status.sync.status}')" = Synced ] && break; sleep 2; done
argocd app list
argocd app get racine | sed -n '/^GROUP/,$p'
d=$(date +%s)
for i in $(seq 1 12); do
  echo "$(( $(date +%s) - d )) s  replicas=$(kubectl -n colis-staging get deployment api -o jsonpath='{.spec.replicas}')  $(etat colis-staging | cut -d' ' -f1)"
  sleep 5
done | uniq -f1
kubectl -n colis-staging get resourcequota limites
kubectl -n argocd get application colis-staging -o json | jq -c '{ignoreDifferences: .spec.ignoreDifferences, syncOptions: .spec.syncPolicy.syncOptions}'
docker stats --no-stream minikube --format 'mémoire du nœud : {{.MemUsage}}'
echo; echo "### fin"
