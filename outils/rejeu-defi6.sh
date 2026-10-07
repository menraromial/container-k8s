#!/usr/bin/env bash
# Rejeu du défi VI : déploie le Colis à auditer, passe la grille, l'audite avec les outils de la partie VI,
# applique le corrigé et repasse la grille. Sorties dans outils/out/defi6.
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/defi-6
O=$RACINE/outils/out/defi6
export CLE_PUBLIQUE=$RACINE/outils/out/ch14r/cle/cosign.pub
section() { echo; echo "### $*"; }

kubectl delete ns colis-audit defi6-sonde --wait=false >/dev/null 2>&1
for ns in colis-audit defi6-sonde; do while kubectl get ns $ns >/dev/null 2>&1; do sleep 2; done; done
rm -rf "$O"; mkdir -p "$O"; cd "$O"

section "déploiement"
kubectl apply -f $KIT/colis-audit.yaml
for d in postgres redis api web; do kubectl -n colis-audit rollout status deployment/$d --timeout=240s >/dev/null; done
kubectl -n colis-audit get pods

section "grille avant"
bash $KIT/verifier.sh colis-audit

section "audit pss"
python3 $RACINE/kits/durcissement/corrige/niveau-pss.py | grep -E '^namespace|colis-audit'
kubectl label --dry-run=server --overwrite ns colis-audit pod-security.kubernetes.io/enforce=restricted 2>&1 | grep '^Warning' | tail -1

section "audit rbac"
python3 $RACINE/kits/rbac/qui-peut.py get secrets colis-audit | grep -v -E 'system:masters|kubeadm|cert-manager|envoy|keda|kube-system|kube-controller'
echo "--- auditer-rbac.py (sans --tout)"; python3 $RACINE/kits/rbac/corrige/auditer-rbac.py | grep -c colis-audit
echo "--- auditer-rbac.py --tout"; python3 $RACINE/kits/rbac/corrige/auditer-rbac.py --tout | grep -A12 '^Group system:serviceaccounts:colis-audit'
kubectl -n colis-audit get secrets --field-selector type=kubernetes.io/service-account-token
kubectl -n colis-audit get secret jeton-ci -o jsonpath='{.data.token}' | base64 -d | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq -c '{sub, exp}'

section "audit secrets"
kubectl -n colis-audit get configmap colis-config -o json | jq -c '.data'

section "audit réseau"
kubectl -n colis-audit get networkpolicies

section "audit images"
python3 $RACINE/kits/images/corrige/inventaire-images.py $CLE_PUBLIQUE | grep -A1 -E '^host.minikube' | grep -B1 'colis-audit'

section "audit ressources"
for i in $(seq 1 24); do [ "$(kubectl -n colis-audit get policyreports --no-headers 2>/dev/null | wc -l)" -ge 4 ] && break; sleep 5; done
kubectl -n colis-audit get policyreports -o json | jq -r '.items[] | "\(.scope.kind)/\(.scope.name)\tpass=\(.summary.pass // 0)\tfail=\(.summary.fail // 0)\t\([.results[]? | select(.result=="fail") | .message] | join("; "))"' | sort | column -t -s $'\t'

section "correction"
bash $KIT/corrige/corriger.sh 2>&1 | grep -v -E '^Waiting'
kubectl -n colis-audit get pods

section "grille après"
bash $KIT/verifier.sh colis-audit

echo; echo "### fin"
