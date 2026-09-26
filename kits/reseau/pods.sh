#!/usr/bin/env bash
# Crée un Pod agnhost par nœud du cluster courant, dans le namespace ch39 : p-<nom du nœud>.
kubectl create namespace ch39 --dry-run=client -o yaml | kubectl apply -f - >/dev/null
for n in $(kubectl get nodes -o name | cut -d/ -f2); do
  kubectl -n ch39 run p-$n --image=registry.k8s.io/e2e-test-images/agnhost:2.61 \
    --overrides="{\"spec\":{\"nodeName\":\"$n\"}}" -- netexec >/dev/null
done
kubectl -n ch39 wait --for=condition=Ready pod -l run --timeout=180s >/dev/null
kubectl -n ch39 get pods -o wide
