#!/usr/bin/env bash
# Chapitre 34 : l'API server. Profil principal (minikube). Namespace ch34 (recréé).
# Toutes les requêtes passent par curl ou kubectl --raw ; ne touche à rien hors de ch34.
cd "$(dirname "$0")"; O=$PWD/out/ch34; rm -rf $O; mkdir -p $O; cp -a ../kits/api $O/m
export PATH=~/.local/opt/cours-k8s/bin:$PATH LC_ALL=C
kubectl config use-context minikube >/dev/null
K="kubectl -n ch34"
H() { local n=$1; shift; echo "### $n : $*"; (cd $O/m && timeout 300 bash -c "source ./acces.sh >/dev/null; $*") 2>&1 | grep -v '^W[0-9]' | grep -v cached_discovery > $O/$n.txt; head -c 7000 $O/$n.txt; }
kubectl delete namespace ch34 --wait=true >/dev/null 2>&1; kubectl create namespace ch34 >/dev/null

H 01-verbeux "$K get pods -v=6 2>&1 | grep -o 'verb=.*'; echo; kubectl -n colis get deploy api -v=8 2>&1 | grep -A2 'url=\"https.*/deployments/api\"' | head -3"
H 02-ressources "kubectl api-resources | wc -l; kubectl api-resources | head -4; kubectl api-resources | grep -E '^(pods|deployments|events|leases|httproutes|scaledobjects) '; kubectl api-versions | wc -l"
H 03-groupes "kubectl api-resources --no-headers -o name | awk -F. '{ if (NF==1) g=\"(noyau)\"; else {g=\$2; for(i=3;i<=NF;i++) g=g\".\"\$i}; c[g]++} END{for(g in c) print c[g], g}' | sort -k2 | column -t"
H 04-proxy "kubectl proxy --port=8011 >/dev/null & P=\$!; sleep 1; curl -s localhost:8011/api/v1/namespaces/ch34/configmaps; kill \$P"
H 05-identites "echo \$API; curl -s \$API/api/v1/namespaces/ch34/configmaps -k | jq -c '{code, reason, message}'; curl -s --cacert ~/.minikube/ca.crt -H 'Authorization: Bearer abc' \$API/api/v1/namespaces/ch34/configmaps | jq -c '{code, reason, message}'; T=\$($K create token default); curl -s --cacert ~/.minikube/ca.crt -H \"Authorization: Bearer \$T\" \$API/api/v1/namespaces/ch34/configmaps | jq -c '{code, reason, message}'; curl -s \"\${ID[@]}\" \$API/api/v1/namespaces/ch34/configmaps | jq -c '{kind, n: (.items|length), noms: [.items[].metadata.name]}'"
H 06-qui "openssl x509 -in ~/.minikube/profiles/minikube/client.crt -noout -subject; kubectl auth whoami | head -3"
H 07-ecrire "curl -sN \"\${ID[@]}\" \"\$API/api/v1/namespaces/ch34/configmaps?watch=true&fieldSelector=metadata.name=reglages\" > watch.txt & W=\$!; sleep 1
U=\$API/api/v1/namespaces/ch34/configmaps
echo '# POST'; curl -s \"\${ID[@]}\" -X POST \$U -H 'Content-Type: application/json' -d @reglages.json | jq -c '{kind, rv: .metadata.resourceVersion, uid: .metadata.uid}'
echo '# POST encore'; curl -s \"\${ID[@]}\" -X POST \$U -H 'Content-Type: application/json' -d @reglages.json | jq -c '{code, reason, message}'
echo '# PATCH merge'; curl -s \"\${ID[@]}\" -X PATCH \$U/reglages -H 'Content-Type: application/merge-patch+json' -d '{\"data\":{\"taille\":\"grande\"}}' | jq -c '{rv: .metadata.resourceVersion, data}'
echo '# PATCH json'; curl -s \"\${ID[@]}\" -X PATCH \$U/reglages -H 'Content-Type: application/json-patch+json' -d '[{\"op\":\"replace\",\"path\":\"/data/couleur\",\"value\":\"vert\"}]' | jq -c '{rv: .metadata.resourceVersion, data}'
echo '# PUT ancien'; curl -s \"\${ID[@]}\" -X PUT \$U/reglages -H 'Content-Type: application/json' -d '{\"apiVersion\":\"v1\",\"kind\":\"ConfigMap\",\"metadata\":{\"name\":\"reglages\",\"resourceVersion\":\"1\"},\"data\":{\"couleur\":\"rouge\"}}' | jq -c '{code, reason, message}'
echo '# DELETE'; curl -s \"\${ID[@]}\" -X DELETE \$U/reglages | jq -c '{kind, status, details}'
sleep 1; kill \$W; echo '# le watch a reçu :'; jq -c '{type, rv: .object.metadata.resourceVersion, data: .object.data}' watch.txt"
H 08-pages "for i in 1 2 3 4 5 6 7; do $K create configmap carton-\$i --from-literal=n=\$i >/dev/null; done; U=\$API/api/v1/namespaces/ch34/configmaps
R=\$(curl -s \"\${ID[@]}\" \"\$U?limit=3\"); echo \"\$R\" | jq -c '{rv: .metadata.resourceVersion, reste: .metadata.remainingItemCount, noms: [.items[].metadata.name]}'; C=\$(echo \"\$R\" | jq -r .metadata.continue); echo \"continue=\$C\"; echo \$C | base64 -d 2>/dev/null; echo
curl -s \"\${ID[@]}\" \"\$U?limit=3&continue=\$C\" | jq -c '{reste: .metadata.remainingItemCount, noms: [.items[].metadata.name]}'
$K get cm --chunk-size=3 -v=6 2>&1 | grep -o 'url=\"[^\"]*configmaps[^\"]*\"' | sed 's/continue=[^&]*/continue=.../'"
H 09-table "curl -s \"\${ID[@]}\" -H 'Accept: application/json;as=Table;v=v1;g=meta.k8s.io' \"\$API/api/v1/namespaces/ch34/configmaps?limit=2\" | jq -c '{kind, colonnes: [.columnDefinitions[].name], lignes: [.rows[].cells]}'"
H 10-vieux "timeout 3 curl -sN \"\${ID[@]}\" \"\$API/api/v1/namespaces/ch34/configmaps?watch=true&resourceVersion=10\" | jq -c '{type, code: .object.code, reason: .object.reason, message: .object.message}'"
H 11-watch-kubectl "$K apply -f vitrine.yaml >/dev/null; $K rollout status deploy/vitrine --timeout=90s >/dev/null; $K get deploy vitrine -w -v=6 > w.txt 2>&1 & W=\$!; sleep 2; $K scale deploy vitrine --replicas=3 >/dev/null; sleep 4; kill \$W; grep -E 'url=|^vitrine|^NAME' w.txt | sed 's/.*verb=/verb=/'; $K delete -f vitrine.yaml >/dev/null"
H 12-versions "kubectl get --raw /apis | jq -c '[.groups[] | select(.name==\"autoscaling\")] | .[0] | {name, versions: [.versions[].version], preferred: .preferredVersion.version}'; kubectl get --raw /apis/autoscaling/v2/namespaces/colis/horizontalpodautoscalers/api | jq -c '{apiVersion, metrics: .spec.metrics}'; kubectl get --raw /apis/autoscaling/v1/namespaces/colis/horizontalpodautoscalers/api | jq -c '{apiVersion, targetCPUUtilizationPercentage: .spec.targetCPUUtilizationPercentage}'"
H 13-ancien "$K apply -f ancien.yaml"
H 14-sous-ressources "kubectl get --raw /api/v1 | jq -r '.resources[].name' | grep '^pods'; $K apply -f vitrine.yaml >/dev/null; kubectl get --raw /apis/apps/v1/namespaces/ch34/deployments/vitrine/scale | jq -c '{kind, apiVersion, spec, status}'"
H 15-agregation "kubectl get apiservices | grep -v Local; kubectl get --raw /apis/metrics.k8s.io/v1beta1/namespaces/colis/pods | jq -c '.items[] | {pod: .metadata.name, cpu: .containers[0].usage.cpu, memoire: .containers[0].usage.memory}' | head -3"
H 16-drapeaux "kubectl -n kube-system get pod kube-apiserver-minikube -o jsonpath='{range .spec.containers[0].command[*]}{@}{\"\\n\"}{end}' | grep -E 'admission|authorization-mode|etcd-servers|^kube-apiserver|secure-port'"
H 17-nu "wc -l < pod-nu.yaml; $K apply -f pod-nu.yaml --dry-run=server -o yaml > rendu.yaml; wc -l < rendu.yaml; sed -n '/^spec:/,\$p' rendu.yaml; $K get pod nu"
H 18-invalide "$K create configmap Reglages_1 --from-literal=a=b"
H 19-ssa "$K delete -f vitrine.yaml >/dev/null; $K apply --server-side --field-manager=equipe-web -f vitrine.yaml; $K get deploy vitrine --show-managed-fields -o yaml | sed -n '/managedFields:/,/time:/p'; $K get deploy vitrine --show-managed-fields -o json | jq -c '.metadata.managedFields[] | {manager, operation, subresource}'"
H 20-conflit "$K rollout status deploy/vitrine --timeout=90s >/dev/null; $K scale deploy vitrine --replicas=4; $K get deploy vitrine --show-managed-fields -o json | jq -c '.metadata.managedFields[] | {manager, operation, subresource}'; $K apply --server-side --field-manager=equipe-web -f vitrine.yaml; echo \"code : \$?\"; $K apply --server-side --field-manager=equipe-web --force-conflicts -f vitrine.yaml; $K get deploy vitrine -o jsonpath='{.spec.replicas}{\"\\n\"}'; $K get deploy vitrine --show-managed-fields -o json | jq -c '.metadata.managedFields[] | {manager, operation, subresource}'"
H 21-sante "kubectl get --raw '/readyz?verbose' | head -5; echo ...; kubectl get --raw '/readyz?verbose' | tail -2; kubectl get --raw /livez; echo"
H 22-metriques "kubectl get --raw /metrics | grep -E '^apiserver_request_total\\{' | grep 'resource=\"configmaps\"' | grep -E 'code=\"(201|409|422)\"' | sed 's/component=\"apiserver\",dry_run=\"\",//'"
H 23-erreur404 "kubectl get --raw /apis/apps/v1/namespaces/ch34/deploiements"
H 24-ex-logs "$K run bavard --image=registry.k8s.io/e2e-test-images/agnhost:2.61 --restart=Never -- netexec >/dev/null; $K wait --for=condition=Ready pod/bavard --timeout=60s >/dev/null; $K logs bavard --tail=1 -v=6 2>&1 | grep -o 'verb=.*'; echo; $K delete pod bavard -v=6 2>&1 | grep -o 'verb=.*'; echo; $K delete -f vitrine.yaml -v=8 2>&1 | grep -A1 'helper.go.*Request Body' | tail -1"
H 25-ex-scale "$K apply -f vitrine.yaml >/dev/null; $K rollout status deploy/vitrine --timeout=90s >/dev/null; curl -s \"\${ID[@]}\" -X PATCH \"\$API/apis/apps/v1/namespaces/ch34/deployments/vitrine/scale\" -H 'Content-Type: application/merge-patch+json' -d '{\"spec\":{\"replicas\":3}}' | jq -c '{kind, spec}'; sleep 6; $K get deploy vitrine"
H 26-ex-python "kubectl proxy --port=8011 >/dev/null & P=\$!; sleep 1; timeout 8 python3 surveiller.py ch34 > py.txt & Q=\$!; sleep 2; $K create configmap essai --from-literal=a=1 >/dev/null; $K label configmap essai vu=oui >/dev/null; $K delete configmap essai >/dev/null; wait \$Q; kill \$P; cat py.txt"
H 27-ex-cession "$K delete -f vitrine.yaml --wait=true >/dev/null 2>&1; $K apply --server-side --field-manager=equipe-web -f vitrine.yaml >/dev/null; $K scale deploy vitrine --replicas=4 >/dev/null; $K apply --server-side --field-manager=equipe-web -f vitrine-sans-replicas.yaml; $K get deploy vitrine -o jsonpath='cas 1 : replicas={.spec.replicas}{\"\\n\"}'
$K delete -f vitrine.yaml --wait=true >/dev/null; $K apply --server-side --field-manager=equipe-web -f vitrine.yaml >/dev/null; $K get deploy vitrine -o jsonpath='cas 2 avant : replicas={.spec.replicas}{\"\\n\"}'; $K apply --server-side --field-manager=equipe-web -f vitrine-sans-replicas.yaml; $K get deploy vitrine -o jsonpath='cas 2 après : replicas={.spec.replicas}{\"\\n\"}'"
