#!/usr/bin/env bash
# Rejeu du chapitre 47 (faire confiance aux images) sur le profil minikube principal. Sorties dans outils/out/ch47r.
# Suppose Kyverno installé (chapitre 45), le registre du cours en marche et les clés cosign du chapitre 14.
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
export COSIGN_PASSWORD=mot-de-passe-du-cours
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/images
CLE=$RACINE/outils/out/ch14r/cle
O=$RACINE/outils/out/ch47r
R=host.minikube.internal:5001
section() { echo; echo "### $*"; }
essai() {   # $1 namespace, $2 image : la création à blanc d'un Pod, et l'image enregistrée
  kubectl -n "$1" run "t-$(echo "$2" | tr '/:.@' '----' | cut -c1-40)" --image="$R/$2" --dry-run=server \
    -o jsonpath='{.spec.containers[0].image}{"\n"}' -- sleep 3600 2>&1 | grep -v '^Warning' | sed '/^$/d'
}
LEGACY=(--new-bundle-format=false --use-signing-config=false --tlog-upload=false --allow-http-registry)
empreinte() { curl -sI -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
  "http://localhost:5001/v2/${1%%:*}/manifests/${1##*:}" | awk 'tolower($1) == "docker-content-digest:" {print $2}' | tr -d '\r'; }

# --- remise à zéro
kubectl delete imagevalidatingpolicy images-signees analyse-vulnerabilites --ignore-not-found >/dev/null 2>&1
kubectl delete clusterpolicy analyse-vulnerabilites-classique --ignore-not-found >/dev/null 2>&1
kubectl label ns colis cours/images-signees- cours/analyse-exigee- >/dev/null 2>&1
if [ "$(kubectl -n colis get deploy web -o jsonpath='{.spec.template.spec.containers[0].image}')" != "$R/colis/web:1.0" ]; then
  kubectl -n colis set image deployment/web web=$R/colis/web:1.0 >/dev/null
  kubectl -n colis rollout status deployment/web --timeout=180s >/dev/null
fi
for ns in ch47 ch47-analyse; do kubectl delete ns $ns --wait=false >/dev/null 2>&1; done
for ns in ch47 ch47-analyse; do while kubectl get ns $ns >/dev/null 2>&1; do sleep 2; done; done
rm -rf "$O"; mkdir -p "$O"; cd "$O"
cosign() { command cosign "$@" 2>&1 | grep -v -E '^(WARNING|Note)' ; return "${PIPESTATUS[0]}"; }
python3 $KIT/avec-cle.py $KIT/images-signees.yaml.modele $CLE/cosign.pub > images-signees.yaml
python3 $KIT/avec-cle.py $KIT/analyse-vulnerabilites.yaml.modele $CLE/cosign.pub > analyse-vulnerabilites.yaml
python3 $KIT/avec-cle.py $KIT/analyse-vulnerabilites-classique.yaml.modele $CLE/cosign.pub > analyse-vulnerabilites-classique.yaml

section "ouverture"
kubectl get pods -A -o json | jq -r '[.items[].spec.containers[].image] | unique | .[]' > images.txt
echo "$(wc -l < images.txt) images différentes"
sed -E 's#^([^/]+\.[^/]+|[^/]+:[0-9]+)/.*#\1#; t; s#.*#docker.io (implicite)#' images.txt | sort | uniq -c | sort -rn

section "signatures existantes"
for i in colis/api:2.1 colis/web:1.0 cours/non-signee:1.0; do
  printf "%-24s " "$i"; command cosign verify --key $CLE/cosign.pub "${LEGACY[@]:0:1}" --insecure-ignore-tlog=true --allow-http-registry "localhost:5001/$i" >/dev/null 2>&1 && echo signée || echo "non signée"
done

section "politique"
grep -v -E '^ {10}[A-Za-z0-9+/=-]+$' images-signees.yaml | grep -v -- '-----'
kubectl apply -f images-signees.yaml
sleep 6
kubectl get imagevalidatingpolicy images-signees -o json | jq -c '{prete: .status.conditionStatus.ready}'
kubectl create ns ch47 >/dev/null
kubectl label ns ch47 cours/images-signees=oui >/dev/null
for i in colis/api:2.1 colis/web:1.0 cours/non-signee:1.0; do echo "\$ $i"; essai ch47 $i; done
echo "\$ busybox:1.37 (hors registre du cours)"
kubectl -n ch47 run t-busybox --image=busybox:1.37 --dry-run=server -o jsonpath='{.spec.containers[0].image}{"\n"}' -- sleep 3600

section "format de signature"
mkdir -p format && printf 'FROM busybox:1.37\nLABEL org.opencontainers.image.title="format-recent"\n' > format/Dockerfile
DOCKER_CONFIG=~/.local/opt/cours-k8s/docker-config docker build -q -t localhost:5001/cours/format-recent:1.0 format >/dev/null
docker push -q localhost:5001/cours/format-recent:1.0 >/dev/null
D=$(empreinte cours/format-recent:1.0)
cosign sign --yes --key $CLE/cosign.key --signing-config $CLE/sans-journal.json --allow-http-registry localhost:5001/cours/format-recent@$D | tail -1
curl -s http://localhost:5001/v2/cours/format-recent/tags/list | jq -c .tags
curl -s -H 'Accept: application/vnd.oci.image.index.v1+json' "http://localhost:5001/v2/cours/format-recent/manifests/sha256-${D#sha256:}" | jq -c '[.manifests[] | .artifactType]'
command cosign verify --key $CLE/cosign.pub --insecure-ignore-tlog=true --allow-http-registry localhost:5001/cours/format-recent:1.0 >/dev/null 2>&1 && echo "cosign verify : signature valide"
echo "\$ cours/format-recent:1.0"; essai ch47 cours/format-recent:1.0
kubectl -n kyverno logs deploy/kyverno-admission-controller --since=1m | grep 'image verification failed' | grep -o 'error="[^"]*"' | tail -1
cosign sign --yes --key $CLE/cosign.key "${LEGACY[@]}" localhost:5001/cours/format-recent@$D | tail -1
curl -s http://localhost:5001/v2/cours/format-recent/tags/list | jq -c .tags
echo "\$ cours/format-recent:1.0"; essai ch47 cours/format-recent:1.0

section "colis signé au format classique"
for i in colis/api:2.1 colis/web:1.0; do cosign sign --yes --key $CLE/cosign.key "${LEGACY[@]}" "localhost:5001/${i%%:*}@$(empreinte $i)" | tail -1; done
for i in colis/api:2.1 colis/web:1.0 cours/non-signee:1.0; do echo "\$ $i"; essai ch47 $i; done

section "registre arrêté"
docker stop registre >/dev/null
essai ch47 colis/api:2.1 | cut -c1-260
docker start registre >/dev/null
for i in $(seq 1 30); do curl -s -o /dev/null http://localhost:5001/v2/ && break; sleep 1; done

section "attestations"
for i in colis/api:2.1 colis/web:1.0; do bash $KIT/signer-et-attester.sh $i; done
for r in api web; do echo "$r : $(curl -s http://localhost:5001/v2/colis/$r/tags/list | jq -c '[.tags[] | select(endswith(".sig") or endswith(".att"))]')"; done
command cosign verify-attestation --key $CLE/cosign.pub --type vuln --insecure-ignore-tlog=true --new-bundle-format=false --allow-http-registry localhost:5001/colis/web:1.0 2>/dev/null \
  | head -1 | jq -r '.payload' | base64 -d | jq -c '{predicateType, scanner: .predicate.scanner.uri, failles: [.predicate.scanner.result.Results[]?.Vulnerabilities[]? | "\(.PkgName) \(.VulnerabilityID) \(.Severity)"]}'

section "attestations ivpol"
kubectl apply -f analyse-vulnerabilites.yaml
sleep 6
kubectl create ns ch47-analyse >/dev/null
kubectl label ns ch47-analyse cours/analyse-exigee=oui >/dev/null
for i in colis/api:2.1; do echo "\$ $i"; essai ch47-analyse $i; done
kubectl -n kyverno logs deploy/kyverno-admission-controller --since=1m | grep 'attestation=vuln' | grep -o 'error="[^"]*"' | tail -1
kubectl delete -f analyse-vulnerabilites.yaml

section "attestations classique"
kubectl apply -f analyse-vulnerabilites-classique.yaml 2>&1 | grep -v '^Warning'
sleep 6
for i in colis/api:2.1 colis/web:1.0 cours/non-signee:1.0; do echo "\$ $i"; essai ch47-analyse $i | sed '/^resource Pod/d'; done

section "tiers sans clé"
I=$(kubectl -n kyverno get deploy kyverno-admission-controller -o jsonpath='{.spec.template.spec.containers[0].image}')
echo "$I"
COSIGN_REPOSITORY=ghcr.io/kyverno/signatures command cosign verify "$I" \
  --certificate-identity-regexp '^https://github.com/kyverno/kyverno/' --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  > kyverno.json 2> kyverno.err; echo "code de sortie : $?"
grep -E '^  - ' kyverno.err
jq -c '.[0] | {empreinte: .critical.image["docker-manifest-digest"], optional}' kyverno.json
kubectl -n kyverno get pods -l app.kubernetes.io/component=admission-controller -o jsonpath='{.items[0].status.containerStatuses[0].imageID}{"\n"}'

section "kubelet"
kubectl get --raw /api/v1/nodes/minikube/proxy/configz | jq '.kubeletconfig | {imagePullCredentialsVerificationPolicy, preloadedImagesVerificationAllowlist}'

section "colis"
kubectl label ns colis cours/images-signees=oui
kubectl -n colis rollout restart deployment/api
kubectl -n colis rollout status deployment/api --timeout=180s >/dev/null
kubectl -n colis get pods -l app.kubernetes.io/name=api -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.containers[0].image}{"\n"}{end}'
kubectl -n colis get deploy api -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

section "ex2 inventaire"
python3 $KIT/corrige/inventaire-images.py $CLE/cosign.pub | grep -A1 -E '^host.minikube'

section "ex3 corriger web"
rm -rf web-1.1 && cp -r $KIT/corrige/web-1.1 web-1.1
DOCKER_CONFIG=~/.local/opt/cours-k8s/docker-config docker build -q -t localhost:5001/colis/web:1.1 web-1.1 >/dev/null
docker push -q localhost:5001/colis/web:1.1 >/dev/null
bash $KIT/signer-et-attester.sh colis/web:1.1
echo "\$ colis/web:1.1"; essai ch47-analyse colis/web:1.1
kubectl -n colis set image deployment/web web=$R/colis/web:1.1
kubectl -n colis rollout status deployment/web --timeout=180s >/dev/null
kubectl label ns colis cours/analyse-exigee=oui
kubectl -n colis rollout restart deployment/web deployment/api
kubectl -n colis rollout status deployment/web --timeout=180s >/dev/null
kubectl -n colis rollout status deployment/api --timeout=180s >/dev/null
kubectl -n colis get pods -l 'app.kubernetes.io/name in (api,web)' -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.containers[0].image}{"\n"}{end}'
curl -s -o /dev/null -w "page d'accueil : %{http_code}\n" http://192.168.49.100/
curl -s http://192.168.49.100/api/sante; echo

section "ex1 mauvaise clé"
D=$(empreinte cours/autre-cle:1.0)
cosign sign --yes --key $CLE/autre/cosign.key "${LEGACY[@]}" localhost:5001/cours/autre-cle@$D | tail -1
echo "\$ cours/autre-cle:1.0"; essai ch47 cours/autre-cle:1.0
kubectl -n kyverno logs deploy/kyverno-admission-controller --since=1m | grep 'image verification failed' | grep 'autre-cle' | grep -o 'error="[^"]*"' | tail -1
command cosign verify --key $CLE/cosign.pub --insecure-ignore-tlog=true --new-bundle-format=false --allow-http-registry localhost:5001/cours/autre-cle:1.0 2>&1 | tail -1
command cosign verify --key $CLE/autre/cosign.pub --insecure-ignore-tlog=true --new-bundle-format=false --allow-http-registry localhost:5001/cours/autre-cle:1.0 2>&1 | grep -E '^  - ' | head -2

section "ex4 external secrets"
I=ghcr.io/external-secrets/external-secrets:v2.12.0
command cosign verify $I --certificate-identity-regexp '^https://github.com/external-secrets/external-secrets/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com > eso.json 2>/dev/null; echo "code de sortie : $?"
jq '.[0] | {empreinte: .critical.image["docker-manifest-digest"], Subject: .optional.Subject, Issuer: .optional.Issuer, githubWorkflowTrigger: .optional.githubWorkflowTrigger, githubWorkflowSha: .optional.githubWorkflowSha}' eso.json
kubectl -n external-secrets get pods -o jsonpath='{.items[0].status.containerStatuses[0].imageID}{"\n"}'

echo; echo "### fin"
