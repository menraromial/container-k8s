#!/usr/bin/env bash
# Chapitre 55 : écrire un opérateur avec kubebuilder. Repart de zéro : retire l'opérateur déployé,
# sa CRD et le namespace ch55, puis rejoue tout le chapitre. Sorties : outils/out/ch55r.
# Durée : une vingtaine de minutes (dépendances Go, compilation, image).
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/operateur
O=$RACINE/outils/out/ch55r; rm -rf $O; mkdir -p $O && cd $O
section() { echo; echo "### $*"; }
heure() { date +%s.%N; }
duree() { echo "$(echo "$(heure) - $1" | bc | cut -c1-4) s"; }
plafond() { systemd-run --user --scope --quiet -p MemoryMax=6G -p MemorySwapMax=0 "$@"; }
# arrête les opérateurs lancés en local par ce script, reconnus au chemin de leur binaire : le processus
# de l'opérateur déployé dans minikube s'appelle aussi « manager » et il est visible depuis l'hôte
arreter() {
  for p in $(pgrep -u "$USER" -x manager; pgrep -u "$USER" -x manager-naif); do
    case "$(readlink /proc/$p/exe)" in $KIT/*|$O/*) kill $p ;; esac
  done
  sleep 1
}
etat() { kubectl -n ch55 get colis "${1:-principal}" -o jsonpath='{.status.conditions[?(@.type=="Prete")].reason}' 2>/dev/null; }
api() { curl -s --max-time 5 "http://127.0.0.1:18085/api$1" "${@:2}"; }

# --- remise à zéro
arreter
(cd $KIT && make undeploy ignore-not-found=true >/dev/null 2>&1)
kubectl delete crd colis.cours.example.com --ignore-not-found --wait=true >/dev/null
kubectl delete ns ch55 ch55-naif --ignore-not-found --wait=true >/dev/null

section "outils"
go version
kubebuilder version | head -2

section "init"
mkdir -p neuf && cd neuf
debut=$(heure)
plafond kubebuilder init --domain example.com --repo example.com/colis-operateur --project-name colis-operateur 2>&1 | grep -v -E '^go: (downloading|finding)' | tail -4
echo "durée : $(duree $debut)"
section "create api"
debut=$(heure)
plafond kubebuilder create api --group cours --version v1 --kind Colis --plural colis --resource --controller 2>&1 | grep -v -E '^go: (downloading|finding)' | tail -4
echo "durée : $(duree $debut)"
section "arbre"
find . -path ./bin -prune -o -path ./.git -prune -o -type f -print | sort | grep -v -E '^\./(\.devcontainer|\.github)/' | sed 's#^\./##'
echo "--- fichiers : $(find . -path ./bin -prune -o -type f -print | wc -l), dont $(find . -name '*.go' -not -path './bin/*' | wc -l) en Go"
cd $O

section "generation"
cd $KIT
plafond make manifests generate 2>&1 | tail -2
grep -c "" config/crd/bases/cours.example.com_colis.yaml
cd $O

section "naif"
rm -rf naif && mkdir naif && (cd $KIT && tar --exclude=./bin --exclude=./cover.out -cf - .) | (cd naif && tar -xf -)
python3 - naif/internal/controller/colis_controller.go <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
a = "\tif !equality.Semantic.DeepDerivative(voulu, *actuel) {\n\t\t*actuel = voulu\n\t}\n"
assert a in s
s = s.replace(a, "\t*actuel = voulu // version naïve : on écrase toujours\n\t_ = equality.Semantic\n")
open(p, "w").write(s)
EOF
(cd naif && plafond go build -o manager-naif ./cmd/main.go)
kubectl apply -f $KIT/config/crd/bases/cours.example.com_colis.yaml >/dev/null
kubectl create ns ch55-naif >/dev/null
naif/manager-naif --health-probe-bind-address=0 --metrics-bind-address=0 > naif.log 2>&1 & PN=$!
sleep 3
printf 'apiVersion: cours.example.com/v1\nkind: Colis\nmetadata: {name: principal, namespace: ch55-naif}\nspec: {version: 2.2.0}\n' | kubectl apply -f -
for i in $(seq 1 60); do [ "$(kubectl -n ch55-naif get colis principal -o jsonpath='{.status.conditions[0].reason}')" = Disponible ] && break; sleep 2; done
sleep 30
kill $PN; sleep 1
echo "réconciliations : $(grep -c 'objet ' naif.log) lignes « objet ... »"
grep -o 'objet [a-z]*' naif.log | sort | uniq -c
kubectl get events.events.k8s.io -n ch55-naif --field-selector regarding.kind=Colis -o json | jq -r '[.items[] | {r: .reason, c: (.series.count // 1)}] | group_by(.r) | map("\(.[0].r) : \(map(.c) | add)") | .[]'
kubectl -n ch55-naif get deploy -o custom-columns=NOM:.metadata.name,GENERATION:.metadata.generation
kubectl -n ch55-naif get rs --no-headers | wc -l | sed 's/^/ReplicaSets : /'
kubectl delete ns ch55-naif --wait=true >/dev/null

section "lancement"
cd $KIT
plafond make build 2>&1 | tail -1
bin/manager --health-probe-bind-address=0 --metrics-bind-address=0 > $O/manager.log 2>&1 &
sleep 3
kubectl create namespace ch55
cat > $O/principal.yaml <<'EOF'
apiVersion: cours.example.com/v1
kind: Colis
metadata:
  name: principal
  namespace: ch55
spec:
  version: 2.2.0
EOF
debut=$(heure)
kubectl apply -f $O/principal.yaml
prec=""
for i in $(seq 1 120); do
  m=$(kubectl -n ch55 get colis principal -o jsonpath='{.status.conditions[?(@.type=="Prete")].reason} : {.status.conditions[?(@.type=="Prete")].message}' 2>/dev/null)
  [ "$m" != "$prec" ] && echo "$(echo "$(heure) - $debut" | bc | cut -c1-4) s  $m" && prec=$m
  [ "${m%% *}" = Disponible ] && break
  sleep 1
done
kubectl -n ch55 get cl
cd $O

section "objets"
kubectl -n ch55 get deploy,sts,svc,scaledobject,cm,secret,pvc
kubectl -n ch55 get deploy api -o jsonpath='{.metadata.ownerReferences}' | jq -c '.[] | {kind, name, controller, blockOwnerDeletion}'
echo "Secret colis-db, propriétaires : $(kubectl -n ch55 get secret colis-db -o jsonpath='{.metadata.ownerReferences}')"
kubectl -n ch55 events --for colis.cours.example.com/principal 2>&1 | cut -c1-120
grep -o 'objet [a-z]*' manager.log | sort | uniq -c
echo "réconciliations : $(grep -c 'Reconcil\|objet ' manager.log)"
grep 'Reconciler error' manager.log | sed -E 's/.*"error": "([^"]{0,110}).*/\1/' | sort | uniq -c

section "application"
kubectl -n ch55 port-forward svc/web 18085:80 >/dev/null 2>&1 & PF=$!
sleep 3
api /colis -o /dev/null -w 'GET /api/colis : %{http_code}\n'
id=$(api /colis -X POST -H 'Content-Type: application/json' -d '{"destinataire": "Opérateur", "poids_kg": 2.5, "depart": "Brest", "arrivee": "Lille"}' | jq -r .id)
debut=$(heure)
for i in $(seq 1 60); do s=$(api /colis/$id | jq -r .statut); [ "$s" = estimé ] && break; sleep 1; done
echo "colis $id : $s après $(duree $debut)"
kubectl -n ch55 get events.events.k8s.io --field-selector regarding.name=worker -o custom-columns=RAISON:.reason,NOTE:.note | grep -i keda | head -3
api /sante | jq -c .

section "derive"
debut=$(heure)
kubectl -n ch55 delete deployment api
for i in $(seq 1 50); do kubectl -n ch55 get deployment api >/dev/null 2>&1 && break; sleep 0.2; done
echo "Deployment api recréé après $(duree $debut)"
kubectl -n ch55 scale deployment api --replicas=5
sleep 2
kubectl -n ch55 get deployment api -o jsonpath='replicas demandées : {.spec.replicas}{"\n"}'
kubectl -n ch55 patch configmap colis-config --type=merge -p '{"data":{"COLIS_VERSION":"9.9.9"}}'
sleep 2
kubectl -n ch55 get configmap colis-config -o jsonpath='COLIS_VERSION : {.data.COLIS_VERSION}{"\n"}'

section "echelle"
kubectl -n ch55 scale colis principal --replicas=3
for i in $(seq 1 60); do [ "$(kubectl -n ch55 get colis principal -o jsonpath='{.status.apiPretes}')" = 3 ] && break; sleep 2; done
kubectl -n ch55 get cl
kubectl -n ch55 get deployment api
kubectl get --raw /apis/cours.example.com/v1/namespaces/ch55/colis/principal/scale | jq -c '{spec, status}'

section "version"
kubectl -n ch55 patch colis principal --type=merge -p '{"spec":{"version":"2.2.1"}}'
sleep 3
kubectl -n ch55 rollout status deployment/api --timeout=180s
for i in $(seq 1 60); do [ "$(etat)" = Disponible ] && break; sleep 2; done
kubectl -n ch55 get deploy api worker -o custom-columns=NOM:.metadata.name,IMAGE:.spec.template.spec.containers[0].image
kill $PF 2>/dev/null; kubectl -n ch55 port-forward svc/web 18085:80 >/dev/null 2>&1 & PF=$!
sleep 3
api /sante | jq -c .
kubectl -n ch55 patch colis principal --type=merge -p '{"spec":{"version":"2.2.0"}}' 2>&1

section "second"
printf 'apiVersion: cours.example.com/v1\nkind: Colis\nmetadata: {name: second, namespace: ch55}\nspec: {version: 2.2.1}\n' | kubectl apply -f -
sleep 3
kubectl -n ch55 get cl
kubectl -n ch55 get colis second -o jsonpath='{.status.conditions[0].message}{"\n"}'
kubectl -n ch55 delete colis second

section "operateur arrete"
arreter
kubectl -n ch55 delete deployment web
sleep 10
kubectl -n ch55 get deployment web 2>&1
debut=$(heure)
(cd $KIT && bin/manager --health-probe-bind-address=0 --metrics-bind-address=0 >> $O/manager.log 2>&1 &)
for i in $(seq 1 100); do kubectl -n ch55 get deployment web >/dev/null 2>&1 && break; sleep 0.2; done
echo "web recréé $(duree $debut) après le redémarrage de l'opérateur"

section "suppression"
for i in $(seq 1 60); do [ "$(etat)" = Disponible ] && break; sleep 2; done
kill $PF 2>/dev/null; kubectl -n ch55 port-forward svc/web 18085:80 >/dev/null 2>&1 & PF=$!
sleep 3
avant=$(api /colis | jq length)
echo "colis en base avant : $avant"
kill $PF 2>/dev/null
kubectl -n ch55 delete colis principal
sleep 15
kubectl -n ch55 get all,cm,secret,pvc,scaledobject 2>&1 | grep -v -E '^$|kube-root-ca'
debut=$(heure)
kubectl apply -f principal.yaml 2>&1
for i in $(seq 1 120); do [ "$(etat)" = Disponible ] && break; sleep 1; done
echo "Disponible de nouveau après $(duree $debut)"
kubectl -n ch55 port-forward svc/web 18085:80 >/dev/null 2>&1 & PF=$!
sleep 3
echo "colis en base après : $(api /colis | jq length)"
kill $PF 2>/dev/null

section "tests"
cd $KIT
ASSETS=$(bin/setup-envtest use 1.37 --bin-dir bin -p path)
du -sh bin/k8s | sed 's/^/binaires envtest : /'
ls bin/k8s/*/
KUBEBUILDER_ASSETS=$KIT/$ASSETS plafond go test ./internal/controller/ -count=1 -v -ginkgo.v 2>&1 | grep -E '^(ok|FAIL|---|Ran|PASS)|Le contrôleur|\[It\]|^  (crée|ne |corrige|laisse|refuse)|•' | head -30
cd $O

section "image"
cd $KIT
debut=$(heure)
plafond make docker-build IMG=localhost:5001/colis-operateur:0.1.0 2>&1 | grep -E 'DONE|naming|ERROR' | tail -3
echo "durée : $(duree $debut)"
docker images localhost:5001/colis-operateur:0.1.0 --format 'taille : {{.Size}}'
docker push localhost:5001/colis-operateur:0.1.0 2>&1 | tail -1
cd $O

section "deploiement"
arreter
cd $KIT
make deploy IMG=host.minikube.internal:5001/colis-operateur:0.1.0 2>&1 | grep -v -E '^(/|cd |\$)' | tail -16
kubectl -n colis-operateur-system rollout status deployment/colis-operateur-controller-manager --timeout=120s
git -C $KIT checkout -- config/manager/kustomization.yaml 2>/dev/null || sed -i '/^images:/,$d' config/manager/kustomization.yaml
cd $O
sleep 30
kubectl -n colis-operateur-system get pods
kubectl -n colis-operateur-system top pods
kubectl -n colis-operateur-system get lease -o custom-columns=BAIL:.metadata.name,DETENTEUR:.spec.holderIdentity
kubectl -n colis-operateur-system get deployment colis-operateur-controller-manager -o json | jq -c '.spec.template.spec.containers[0] | {args, image, resources}'
kubectl -n ch55 get cl

section "metriques"
kubectl -n colis-operateur-system create serviceaccount lecteur-metriques
kubectl create clusterrolebinding colis-operateur-lecteur-metriques --clusterrole=colis-operateur-metrics-reader --serviceaccount=colis-operateur-system:lecteur-metriques
JETON=$(kubectl -n colis-operateur-system create token lecteur-metriques --duration=10m)
kubectl -n colis-operateur-system port-forward svc/colis-operateur-controller-manager-metrics-service 18443:8443 >/dev/null 2>&1 & PM=$!
sleep 3
curl -sk -o /dev/null -w 'sans jeton : %{http_code}\n' https://127.0.0.1:18443/metrics
curl -sk -H "Authorization: Bearer $JETON" https://127.0.0.1:18443/metrics | grep -E '^controller_runtime_reconcile_(total|errors_total)\{controller="colis"|^workqueue_depth\{.*colis|^controller_runtime_active_workers\{controller="colis"' | head -8
kill $PM

echo; echo "### fin"
