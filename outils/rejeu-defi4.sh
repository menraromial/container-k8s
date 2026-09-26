#!/usr/bin/env bash
# Défi IV : Colis en production (namespace colis-prod) avec le chart 0.2.0 du corrigé.
# Suppose les chapitres 28 à 31 faits : passerelle principale, cert-manager et colis-ca, metrics-server, KEDA.
# Rejoue d'abord le ménage de la page, puis l'installation, puis la grille. Laisse colis-prod en marche.
cd "$(dirname "$0")"; O=$PWD/out/defi4; rm -rf $O; mkdir -p $O
C=$PWD/../kits/defi-4/corrige
export PATH=~/.local/opt/cours-k8s/bin:$PATH
kubectl config use-context minikube >/dev/null
H() { local n=$1; shift; echo "### $n : $*"; (cd $C && timeout 900 bash -c "$*") 2>&1 | grep -v '^W[0-9]' > $O/$n.txt; head -c 9000 $O/$n.txt; }
kubectl -n cert-manager get secret colis-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > $O/ca.crt
H 01-menage "helm -n colis-prod uninstall colis; kubectl delete namespace colis-prod; kubectl apply -f ../../http/passerelle-tls.yaml; sleep 5; kubectl -n passerelle delete secret colis-prod-tls; kubectl -n passerelle get certificate"
H 02-passerelle "kubectl apply -f passerelle-tls.yaml; kubectl -n passerelle wait --for=condition=Ready certificate/colis-prod-tls --timeout=60s; kubectl -n passerelle get certificate"
H 03-installer "kubectl create namespace colis-prod; kubectl label namespace colis-prod passerelle=principale; T=\$(date +%s); helm install colis ./colis -n colis-prod -f valeurs-prod.yaml --wait | grep -E '^(STATUS|REVISION)'; echo \"installé en \$((\$(date +%s)-T)) s\"; kubectl -n colis-prod get pods,hpa,scaledobject,pdb"
H 04-rendu "helm template colis ./colis -f valeurs-prod.yaml | grep -c 'replicas:' ; helm template colis ./colis | grep 'replicas:'"
H 05-grille "../verifier.sh $O/ca.crt"
