#!/usr/bin/env bash
# Chapitre 55, exercices. Suppose rejeu-ch55.sh passé : opérateur déployé dans colis-operateur-system,
# Colis principal Disponible dans ch55. Sorties : outils/out/ch55r/exercices.
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/operateur
O=$RACINE/outils/out/ch55r/exercices; rm -rf $O; mkdir -p $O && cd $O
section() { echo; echo "### $*"; }
plafond() { systemd-run --user --scope --quiet -p MemoryMax=6G -p MemorySwapMax=0 "$@"; }
etat() { kubectl -n ch55 get colis principal -o jsonpath='{.status.conditions[?(@.type=="Prete")].reason}'; }
OPNS=colis-operateur-system
OPDEP=deployment/colis-operateur-controller-manager

section "ex1 tests"
mkdir ex1 && (cd $KIT && tar --exclude=./bin --exclude=./cover.out --exclude=./corrige -cf - .) | (cd ex1 && tar -xf -)
cd ex1
patch -p1 < $KIT/corrige/suspendu.patch
$KIT/bin/controller-gen rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=config/crd/bases
$KIT/bin/controller-gen object:headerFile="hack/boilerplate.go.txt",year=2026 paths="./..."
grep -n -B2 -A2 "suspendu:" config/crd/bases/cours.example.com_colis.yaml
KUBEBUILDER_ASSETS=$KIT/bin/k8s/1.37.0-linux-amd64 plafond go test ./internal/controller/ -count=1 -v -ginkgo.v 2>&1 | grep -E '^(ok|FAIL)|Ran [0-9]+|suspendu'
plafond go build -o manager ./cmd/main.go

section "ex1 cluster"
kubectl -n $OPNS scale $OPDEP --replicas=0
kubectl apply -f config/crd/bases/cours.example.com_colis.yaml
./manager --health-probe-bind-address=0 --metrics-bind-address=0 > manager.log 2>&1 & PM=$!
sleep 5
kubectl -n ch55 patch colis principal --type=merge -p '{"spec":{"suspendu":true}}'
sleep 3
kubectl -n ch55 get cl
kubectl -n ch55 delete deployment web
sleep 10
kubectl -n ch55 get deployment web 2>&1
kubectl -n ch55 patch colis principal --type=merge -p '{"spec":{"suspendu":false}}'
for i in $(seq 1 50); do kubectl -n ch55 get deployment web >/dev/null 2>&1 && break; sleep 0.2; done
kubectl -n ch55 get deployment web
for i in $(seq 1 60); do [ "$(etat)" = Disponible ] && break; sleep 2; done
kubectl -n ch55 get cl
kill $PM; sleep 1
kubectl -n ch55 patch colis principal --type=json -p '[{"op":"remove","path":"/spec/suspendu"}]'
kubectl apply -f $KIT/config/crd/bases/cours.example.com_colis.yaml
kubectl -n $OPNS scale $OPDEP --replicas=1
kubectl -n $OPNS rollout status $OPDEP --timeout=120s
cd $O

section "ex2 secret"
kubectl -n ch55 get secret colis-db -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d | cut -c1-6 | sed 's/^/ancien mot de passe : /; s/$/.../'
kubectl -n ch55 delete secret colis-db
sleep 5
kubectl -n ch55 get secret colis-db -o jsonpath='{.metadata.creationTimestamp}{"\n"}'
kubectl -n ch55 get secret colis-db -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d | cut -c1-6 | sed 's/^/nouveau mot de passe : /; s/$/.../'
kubectl -n ch55 get pods -l app.kubernetes.io/name=api
echo "\$ kubectl -n ch55 rollout restart deployment api"
kubectl -n ch55 rollout restart deployment api
sleep 45
kubectl -n ch55 get pods -l app.kubernetes.io/name=api
P=$(kubectl -n ch55 get pods -l app.kubernetes.io/name=api --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
kubectl -n ch55 logs $P --previous 2>&1 | grep -i -o -E 'psycopg[a-zA-Z.]*: .{0,40}|password authentication failed for user "colis"' | head -2
kubectl -n ch55 get cl
echo "--- réparation : donner à PostgreSQL le nouveau mot de passe"
MDP=$(kubectl -n ch55 get secret colis-db -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
kubectl -n ch55 exec postgres-0 -- psql -U colis -d colis -c "ALTER USER colis PASSWORD '$MDP'" 2>&1
kubectl -n ch55 rollout status deployment api --timeout=180s
for i in $(seq 1 60); do [ "$(etat)" = Disponible ] && break; sleep 2; done
kubectl -n ch55 get cl

section "ex3 droits"
SA=system:serviceaccount:$OPNS:colis-operateur-controller-manager
for v in "list secrets -A" "get secrets -n kube-system" "delete deployments -n colis" "create pods -n ch55" "patch colis -n ch55"; do
  echo "$v : $(kubectl auth can-i $v --as=$SA 2>/dev/null)"
done
kubectl get clusterrolebinding colis-operateur-manager-rolebinding -o json | jq -c '{role: .roleRef.name, sujets: [.subjects[] | "\(.namespace)/\(.name)"]}'
echo; echo "### fin"
