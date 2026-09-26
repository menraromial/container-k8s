#!/usr/bin/env bash
# Chapitre 18 : décrire plutôt qu'ordonner. Namespaces ch18, ch18p, ch18-a, ch18-b (recréés). Copie de travail dans out/ch18.
cd "$(dirname "$0")"; O=$PWD/out/ch18; rm -rf $O; mkdir -p $O; cp -a ../kits/manifestes $O/m
export PATH=~/.local/opt/cours-k8s/bin:$PATH
kubectl config use-context minikube >/dev/null; kubectl config set-context --current --namespace=default >/dev/null
H() { local n=$1; shift; echo "### $n : $*"; (cd $O/m && timeout 300 bash -c "$*") 2>&1 | grep -v '^W[0-9]' > $O/$n.txt; head -c 8000 $O/$n.txt; }
for ns in ch18 ch18p ch18-a ch18-b; do kubectl delete namespace $ns --wait=true >/dev/null 2>&1; done
H 00-pieges "kubectl create namespace ch18p >/dev/null; for f in tabulation nombre booleen faute indentation; do echo \"--- \$f\"; kubectl -n ch18p apply -f pieges/\$f.yaml 2>&1 | sed 's|pieges/||'; done"
H 01-apply "kubectl apply -f vitrine.yaml; kubectl -n ch18 rollout status deployment/vitrine --timeout=60s; kubectl apply -f vitrine.yaml"
H 02-last-applied "kubectl -n ch18 get deployment vitrine -o jsonpath='{.metadata.annotations.kubectl\\.kubernetes\\.io/last-applied-configuration}' | jq -c ."
H 03-diff "sed -i 's/replicas: 2/replicas: 3/' vitrine.yaml; kubectl diff -f vitrine.yaml; echo code=\$?; kubectl apply -f vitrine.yaml; kubectl -n ch18 get deployment vitrine"
H 04-derive "kubectl -n ch18 scale deployment vitrine --replicas=5; sleep 2; kubectl diff -f vitrine.yaml | grep -E '^[-+] '; kubectl apply -f vitrine.yaml; sleep 3; kubectl -n ch18 get deployment vitrine"
H 05-retrait "sed -i '/annotations:/d; /colis.example\\/responsable/d' vitrine.yaml; kubectl apply -f vitrine.yaml; kubectl -n ch18 get deployment vitrine -o jsonpath='{.metadata.annotations}' | jq -c 'del(.\"kubectl.kubernetes.io/last-applied-configuration\")'"
H 06-create "kubectl create -f vitrine.yaml 2>&1"
H 08-dry-run "kubectl create deployment api --image=localhost:5001/colis/api:2.0 --replicas=2 --port=8000 --dry-run=client -o yaml"
H 09-dry-run-serveur "kubectl apply -f vitrine.yaml --dry-run=server; kubectl -n ch18 apply -f pieges/faute.yaml --dry-run=server 2>&1 | sed 's|pieges/||'"
H 10-etiquettes "kubectl create namespace ch18-a >/dev/null; for p in 'web-dev app=web,env=dev,tier=front' 'web-prod app=web,env=prod,tier=front' 'api-dev app=api,env=dev,tier=back' 'api-prod app=api,env=prod,tier=back' 'outil app=outil'; do set -- \$p; kubectl -n ch18-a run \$1 --image=nginx:1.30-alpine --labels=\$2 >/dev/null; done; kubectl -n ch18-a get pods --show-labels; echo; kubectl -n ch18-a get pods -l env=prod; echo; kubectl -n ch18-a get pods -l 'env in (dev,prod),tier!=back'; echo; kubectl -n ch18-a get pods -l '!env'; echo; kubectl -n ch18-a get pods -L app,env"
H 11-label-cmd "kubectl -n ch18-a label pod outil env=dev; kubectl -n ch18-a label pod outil env=prod 2>&1; kubectl -n ch18-a label pod outil env=prod --overwrite; kubectl -n ch18-a label pod outil env-; kubectl -n ch18-a get pod outil --show-labels"
H 12-annotations "kubectl -n ch18-a annotate pod web-prod colis.example/ticket='OPS-1234' colis.example/note='redémarré après incident'; kubectl -n ch18-a get pod web-prod -o jsonpath='{.metadata.annotations}' | jq .; kubectl -n ch18-a get pods -l colis.example/ticket=OPS-1234 2>&1"
H 13-namespaces "kubectl get namespaces; kubectl create namespace ch18-b >/dev/null; kubectl -n ch18-b run web-prod --image=nginx:1.30-alpine >/dev/null; kubectl get pods -A --field-selector metadata.name=web-prod"
H 14-suppr-ns "kubectl delete namespace ch18-a --wait=false; sleep 1; kubectl get namespace ch18-a; kubectl -n ch18-a get pods 2>&1 | head -3; kubectl wait --for=delete namespace/ch18-a --timeout=120s; kubectl get namespace ch18-a 2>&1"
H 14b-ssa "kubectl delete -f vitrine.yaml --wait=true >/dev/null; kubectl apply --server-side -f vitrine.yaml; kubectl -n ch18 scale deployment vitrine --replicas=4; kubectl apply --server-side -f vitrine.yaml 2>&1; echo code=\$?; kubectl -n ch18 get deployment vitrine -o json --show-managed-fields | jq -r '.metadata.managedFields[] | \"\\(.manager)\t\\(.operation)\t\\(.fieldsV1 | tostring | .[0:90])\"'; kubectl apply --server-side --force-conflicts -f vitrine.yaml; kubectl -n ch18 get deployment vitrine -o json --show-managed-fields | jq -r '.metadata.managedFields[] | \"\\(.manager)\t\\(.operation)\"'"
H 15-delete-f "kubectl delete -f vitrine.yaml"
