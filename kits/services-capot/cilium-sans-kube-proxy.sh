#!/usr/bin/env bash
# Passe le profil minikube « cilium » en mode sans kube-proxy (kube-proxy replacement).
# Usage : ./cilium-sans-kube-proxy.sh     (contexte kubectl : cilium)
set -e
API=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].status.addresses[0].address}')
# 1. Cilium doit joindre l'API server par son adresse réelle, puisque 10.96.0.1 ne marchera plus sans kube-proxy
kubectl -n kube-system patch cm cilium-config --type merge \
  -p "{\"data\":{\"kube-proxy-replacement\":\"true\",\"k8s-service-host\":\"$API\",\"k8s-service-port\":\"8443\"}}"
for obj in ds/cilium deploy/cilium-operator; do
  kubectl -n kube-system get $obj -o json | jq --arg h "$API" '
    def adenv: .env = ((.env // []) | map(select(.name != "KUBERNETES_SERVICE_HOST" and .name != "KUBERNETES_SERVICE_PORT"))
                       + [{"name":"KUBERNETES_SERVICE_HOST","value":$h},{"name":"KUBERNETES_SERVICE_PORT","value":"8443"}]);
    .spec.template.spec.containers |= map(adenv)
    | if .spec.template.spec.initContainers then .spec.template.spec.initContainers |= map(adenv) else . end' \
  | kubectl replace -f -
done
# 2. plus de kube-proxy
kubectl -n kube-system delete ds kube-proxy --ignore-not-found
kubectl -n kube-system delete cm kube-proxy --ignore-not-found
# 3. effacer les règles KUBE-* qu'il a laissées sur chaque nœud (Pod de débogage par nœud, supprimé ensuite)
kubectl create namespace nettoyage-kube-proxy --dry-run=client -o yaml | kubectl apply -f - >/dev/null
for n in $(kubectl get nodes -o name | cut -d/ -f2); do
  kubectl -n nettoyage-kube-proxy debug node/$n --image=nicolaka/netshoot:v0.14 --profile=sysadmin -- \
    sh -c 'iptables-nft-save | grep -v KUBE | iptables-nft-restore; echo nettoyé' >/dev/null
done
sleep 20; kubectl delete namespace nettoyage-kube-proxy >/dev/null
# 4. redémarrer Cilium
kubectl -n kube-system rollout restart ds/cilium deploy/cilium-operator
kubectl -n kube-system rollout status ds/cilium --timeout=300s
