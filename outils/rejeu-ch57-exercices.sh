#!/usr/bin/env bash
# Chapitre 57, compléments et exercices, sur l'application légère « vitrine ». Suppose rejeu-ch57.sh passé
# (Gitea, Argo CD, dépôt local dans outils/out/ch57r/depot). Sorties : outils/out/ch57r/exercices.
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/gitops
D=$RACINE/outils/out/ch57r/depot
O=$RACINE/outils/out/ch57r/exercices; rm -rf $O; mkdir -p $O && cd $O
section() { echo; echo "### $*"; }
heure() { date +%s.%N; }
duree() { echo "$(echo "$(heure) - $1" | bc | cut -c1-5) s"; }
MDP_GIT=depot-du-cours-57
app() { kubectl -n argocd get application $1 -o jsonpath="$2" 2>/dev/null; }
pousser() {
  git -C $D add -A
  git -C $D commit --quiet --message "$1"
  git -C $D push --quiet origin main 2>&1 | grep -v "^remote:"
  git -C $D rev-parse HEAD
}
attendre_revision() {
  local d=$(heure)
  for i in $(seq 1 ${3:-300}); do [ "$(app $1 '{.status.sync.revision}')" = "$2" ] && break; sleep 0.5; done
  echo "révision ${2:0:7} vue par Argo CD après $(duree $d)"
}
remplacer() {
  python3 -c "import sys; p=sys.argv[1]; s=open(p).read(); assert sys.argv[2] in s; open(p,'w').write(s.replace(sys.argv[2], sys.argv[3]))" "$@"
}
version() { kubectl -n vitrine exec deploy/vitrine -- wget -qO- localhost:9898/version 2>/dev/null | jq -r .version; }

kubectl -n git port-forward svc/gitea 3030:3000 >/dev/null 2>&1 & PFG=$!
kubectl -n argocd port-forward svc/argocd-server 8080:443 >/dev/null 2>&1 & PFA=$!
trap 'kill $PFG $PFA 2>/dev/null' EXIT
for i in $(seq 1 30); do curl -s -o /dev/null --max-time 2 http://localhost:3030/api/healthz && break; sleep 1; done
for i in $(seq 1 30); do curl -sk -o /dev/null --max-time 2 https://localhost:8080/healthz && break; sleep 1; done
argocd login localhost:8080 --username admin --password "$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)" --insecure >/dev/null
kubectl -n argocd delete application vitrine --ignore-not-found --wait=true >/dev/null 2>&1
kubectl delete ns vitrine --ignore-not-found --wait=true >/dev/null

section "webhook"
kubectl -n git logs deploy/gitea --since=6h | grep -o "denied by egress policy.*" | sort -u | head -1
kubectl apply -f $KIT/gitea.yaml >/dev/null
kubectl -n git rollout status deployment/gitea --timeout=300s >/dev/null
kubectl -n git get deployment gitea -o json | jq -r '.spec.template.spec.containers[0].env[] | select(.name | test("ALLOWED_HOST_LIST")) | "\(.name)=\(.value)"'
kill $PFG; kubectl -n git port-forward svc/gitea 3030:3000 >/dev/null 2>&1 & PFG=$!
for i in $(seq 1 30); do curl -s -o /dev/null --max-time 2 http://localhost:3030/api/healthz && break; sleep 1; done
mkdir -p $D/vitrine && cp $KIT/vitrine/vitrine.yaml $D/vitrine/
REV=$(pousser "Vitrine : podinfo 6.14.1" | tail -1)
kubectl apply -f $KIT/vitrine-application.yaml
for i in $(seq 1 120); do [ "$(app vitrine '{.status.health.status}')" = Healthy ] && break; sleep 1; done
echo "vitrine : $(app vitrine '{.status.sync.status} {.status.health.status}'), version $(version)"
remplacer $D/vitrine/vitrine.yaml "podinfo:6.14.1" "podinfo:6.15.0"
d=$(heure)
REV=$(pousser "Vitrine : podinfo 6.15.0" | tail -1)
attendre_revision vitrine $REV 300
for i in $(seq 1 120); do [ "$(version)" = 6.15.0 ] && break; sleep 0.5; done
echo "version $(version) servie $(duree $d) après le push"
kubectl -n git logs deploy/gitea --since=2m | grep -i -E "deliver|webhook" | grep -v "^$" | tail -2 | cut -c1-200

section "self-heal"
for n in 1 2 3 4 5; do
  d=$(heure)
  kubectl -n vitrine scale deployment vitrine --replicas=4 >/dev/null
  for i in $(seq 1 800); do [ "$(kubectl -n vitrine get deployment vitrine -o jsonpath='{.spec.replicas}')" = 2 ] && break; sleep 0.25; done
  echo "écart n° $n corrigé après $(duree $d)"
  sleep 3
done
kubectl -n argocd get configmap argocd-cmd-params-cm -o json | jq -c '.data // {}'

section "ex1 retour arriere"
echo "\$ argocd app rollback vitrine 1"
argocd app rollback vitrine 1 2>&1 | sed -E 's/.*"msg":"([^"]*)".*/\1/' | head -2
argocd app history vitrine
git -C $D log --oneline -3
git -C $D revert --no-edit HEAD >/dev/null
git -C $D log --oneline -2
d=$(heure)
git -C $D push --quiet origin main 2>&1 | grep -v "^remote:"
REV=$(git -C $D rev-parse HEAD)
attendre_revision vitrine $REV 300
for i in $(seq 1 120); do [ "$(version)" = 6.14.1 ] && break; sleep 0.5; done
echo "version $(version) servie $(duree $d) après le push du revert"
argocd app history vitrine | tail -2

section "ex2 prune false"
cat > $D/vitrine/garder.yaml <<'Y'
apiVersion: v1
kind: ConfigMap
metadata:
  name: garder
  annotations:
    argocd.argoproj.io/sync-options: Prune=false   # ne jamais supprimer cet objet, même absent du dépôt
data:
  note: conservé
Y
cat > $D/vitrine/jetable.yaml <<'Y'
apiVersion: v1
kind: ConfigMap
metadata:
  name: jetable
data:
  note: élagué
Y
REV=$(pousser "Vitrine : deux ConfigMaps" | tail -1)
attendre_revision vitrine $REV 120
for i in $(seq 1 60); do kubectl -n vitrine get configmap garder jetable >/dev/null 2>&1 && break; sleep 1; done
kubectl -n vitrine get configmap garder jetable
git -C $D rm --quiet vitrine/garder.yaml vitrine/jetable.yaml
REV=$(pousser "Vitrine : plus de ConfigMaps" | tail -1)
attendre_revision vitrine $REV 120
sleep 10
kubectl -n vitrine get configmap garder jetable 2>&1
echo "vitrine : $(app vitrine '{.status.sync.status}')"
argocd app get vitrine | grep -E "ConfigMap"

section "ex3 etat"
echo "\$ python3 etat-gitops.py --depot-local ..."
python3 $KIT/corrige/etat-gitops.py --depot-local http://gitea.git.svc.cluster.local:3000/cours/colis-config.git=http://cours:$MDP_GIT@localhost:3030/cours/colis-config.git; echo "code de sortie : $?"
kubectl -n argocd patch application vitrine --type=json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]' >/dev/null
remplacer $D/vitrine/vitrine.yaml "replicas: 2" "replicas: 3"
REV=$(pousser "Vitrine : trois répliques" | tail -1)
attendre_revision vitrine $REV 120
echo "\$ python3 etat-gitops.py --depot-local ..."
python3 $KIT/corrige/etat-gitops.py --depot-local http://gitea.git.svc.cluster.local:3000/cours/colis-config.git=http://cours:$MDP_GIT@localhost:3030/cours/colis-config.git; echo "code de sortie : $?"
kubectl apply -f $KIT/vitrine-application.yaml >/dev/null
for i in $(seq 1 120); do [ "$(kubectl -n vitrine get deployment vitrine -o jsonpath='{.status.readyReplicas}')" = 3 ] && break; sleep 1; done

section "cascade"
kubectl -n argocd get application vitrine -o jsonpath='{.metadata.finalizers}{"\n"}'
kubectl -n argocd delete application vitrine
for i in $(seq 1 60); do [ -z "$(kubectl -n vitrine get pods --no-headers 2>/dev/null)" ] && break; sleep 2; done
kubectl -n vitrine get all,configmap 2>&1 | grep -v kube-root-ca
kubectl delete namespace vitrine --wait=false
echo; echo "### fin"
