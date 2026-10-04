#!/usr/bin/env bash
# Rejeu du chapitre 45 (contrôle d'admission) sur le profil minikube principal. Sorties dans outils/out/ch45r.
# Installe Kyverno (chart OCI, ghcr.io) s'il est absent, et le laisse en place pour le chapitre 47.
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/admission
O=$RACINE/outils/out/ch45r
section() { echo; echo "### $*"; }
redemarrer_api() {
  local c
  c=$(minikube ssh -- "sudo crictl ps --name kube-apiserver -q" 2>/dev/null | tr -d '\r')
  minikube ssh -- "sudo crictl stop $c" >/dev/null 2>&1
  sleep 10
  until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 2; done
  sleep 5
}
compte_vpa() { kubectl get --raw /metrics | awk -F' ' '/^apiserver_admission_webhook_admission_duration_seconds_count\{name="vpa.k8s.io"/ {s+=$2} END {print s+0}'; }

# --- remise à zéro : uniquement les objets de ce chapitre
kubectl delete validatingwebhookconfiguration verif-images --ignore-not-found >/dev/null
kubectl delete mutatingwebhookconfiguration epingle-images --ignore-not-found >/dev/null
kubectl delete validatingadmissionpolicybinding images-colis images-colis-avertir --ignore-not-found >/dev/null
kubectl delete validatingadmissionpolicy images-colis faute-de-frappe --ignore-not-found >/dev/null
kubectl delete mutatingadmissionpolicybinding defauts-securite --ignore-not-found >/dev/null
kubectl delete mutatingadmissionpolicy defauts-securite --ignore-not-found >/dev/null
kubectl delete validatingpolicy limites-memoire --ignore-not-found >/dev/null 2>&1
kubectl delete generatingpolicy refus-par-defaut --ignore-not-found >/dev/null 2>&1
kubectl label ns colis cours/politique-images- >/dev/null 2>&1
for ns in ch45 ch45-mut ch45-fret ch45-equipe ch45-tard verif-images politiques; do kubectl delete ns $ns --wait=false >/dev/null 2>&1; done
for ns in ch45 ch45-mut ch45-fret ch45-equipe ch45-tard verif-images politiques; do while kubectl get ns $ns >/dev/null 2>&1; do sleep 2; done; done
helm status kyverno -n kyverno >/dev/null 2>&1 || helm install kyverno oci://ghcr.io/kyverno/charts/kyverno --version 3.9.1 \
  -n kyverno --create-namespace --set cleanupController.enabled=false --wait --timeout 10m >/dev/null
rm -rf "$O"; mkdir -p "$O"; cd "$O"

section "ouverture"
kubectl create ns ch45 >/dev/null
avant=$(compte_vpa)
kubectl -n ch45 run temoin --image=busybox:1.37 -- sleep 3600 >/dev/null
apres=$(compte_vpa)
echo "appels au webhook de VPA : $avant avant, $apres après"
for k in mutatingwebhookconfigurations validatingwebhookconfigurations; do
  kubectl get $k -o json | jq -r --arg k ${k%%webhookconfigurations} '.items[] | select(.metadata.name | startswith("kyverno") | not) | .webhooks[] |
    "\($k)\t\(.name)\t\([.rules[]? | (.operations | join(",")) + " " + ((.apiGroups | map(if . == "" then "core" else . end) | join(",")) + "/" + (.resources | join(",")))] | join(" ; "))\t\(.failurePolicy)\t\(.timeoutSeconds)s"'
done | column -t -s $'\t'
kubectl get validatingadmissionpolicies

section "politique d'images"
kubectl apply -f $KIT/politiques/images-politique.yaml -f $KIT/politiques/images-parametres.yaml -f $KIT/politiques/images-liaison.yaml
sleep 3
kubectl get validatingadmissionpolicy images-colis -o json | jq -c '.status.typeChecking'
kubectl label ns ch45 cours/politique-images=oui >/dev/null
sleep 3
for img in nginx:latest busybox busybox:1.37 docker.io/library/busybox:1.37 host.minikube.internal:5001/colis/api:2.1; do
  echo "\$ ... --image=$img"; kubectl -n ch45 run essai --image=$img --dry-run=server -o name 2>&1
done

section "faute de frappe"
kubectl apply -f $KIT/politiques/faute-de-frappe.yaml >/dev/null
sleep 3
kubectl get validatingadmissionpolicy faute-de-frappe -o json | jq '.status.typeChecking'
kubectl delete -f $KIT/politiques/faute-de-frappe.yaml >/dev/null

section "colis"
kubectl -n colis get deploy,sts -o json | jq 'del(.items[].metadata.resourceVersion, .items[].metadata.managedFields)' \
  | kubectl replace --dry-run=server -f - -o name
kubectl label ns colis cours/politique-images=oui
sleep 3
kubectl -n colis set image deployment/web web=nginx:latest --dry-run=server
kubectl -n colis set image deployment/web web=nginx:1.30-alpine --dry-run=server

section "mutation"
kubectl create ns ch45-mut >/dev/null
kubectl label ns ch45-mut pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=v1.37 >/dev/null
DORMEUR='{"apiVersion":"v1","spec":{"securityContext":{"runAsUser":65534}}}'
kubectl -n ch45-mut run dormeur --image=busybox:1.37 --overrides="$DORMEUR" -- sleep 3600
kubectl apply -f $KIT/politiques/defauts-securite.yaml
kubectl label ns ch45-mut cours/defauts-securite=oui >/dev/null
sleep 3
kubectl -n ch45-mut run dormeur --image=busybox:1.37 --overrides="$DORMEUR" -- sleep 3600
kubectl -n ch45-mut get pod dormeur -o json | jq '{pod: .spec.securityContext, conteneur: .spec.containers[0].securityContext}'
kubectl -n ch45-mut wait --for=condition=Ready pod/dormeur --timeout=60s

section "webhook"
cd $KIT/webhook
kubectl apply -f deploiement.yaml
kubectl -n verif-images create configmap verif-images-code --from-file=webhook.py
kubectl -n verif-images wait --for=condition=Ready certificate/verif-images --timeout=90s
kubectl -n verif-images rollout status deployment/verif-images --timeout=180s
kubectl apply -f configuration.yaml
sleep 5
kubectl get validatingwebhookconfiguration verif-images -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | base64 -d | openssl x509 -noout -ext subjectAltName
cd "$O"
kubectl label ns ch45 cours/images-controlees=oui >/dev/null
kubectl -n ch45 create deployment api-ok --image=host.minikube.internal:5001/colis/api:2.1 --dry-run=server -o name
kubectl -n ch45 create deployment api-faute --image=host.minikube.internal:5001/colis/api:2.2 --dry-run=server -o name
kubectl -n ch45 run p-faute --image=host.minikube.internal:5001/colis/apii:2.1 --dry-run=server -o name
kubectl -n ch45 run p-busybox --image=busybox:1.37 --dry-run=server -o name
kubectl -n verif-images logs deployment/verif-images
kubectl get --raw /metrics | grep '^apiserver_admission_webhook_admission_duration_seconds_count{name="verif-images'

section "webhook en panne"
kubectl -n verif-images scale deployment/verif-images --replicas=0
kubectl -n verif-images wait --for=delete pod -l app=verif-images --timeout=90s >/dev/null
debut=$EPOCHREALTIME
kubectl -n ch45 run p-panne --image=busybox:1.37 --dry-run=server -o name
python3 -c "print(f'réponse en {float(\"$EPOCHREALTIME\") - float(\"$debut\"):.2f} s')"
kubectl -n default run p-ailleurs --image=busybox:1.37 --dry-run=server -o name
kubectl patch validatingwebhookconfiguration verif-images --type=json -p '[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]'
kubectl -n ch45 run p-panne --image=busybox:1.37 --dry-run=server -o name
kubectl -n ch45 run p-faute --image=host.minikube.internal:5001/colis/apii:2.1 --dry-run=server -o name
kubectl patch validatingwebhookconfiguration verif-images --type=json -p '[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Fail"}]' >/dev/null
kubectl -n verif-images scale deployment/verif-images --replicas=1 >/dev/null
kubectl -n verif-images rollout status deployment/verif-images --timeout=120s >/dev/null

section "kyverno : installation"
helm list -n kyverno -o json | jq -r '.[] | "\(.name) \(.chart) \(.app_version) \(.status)"'
kubectl -n kyverno get pods

section "kyverno : limites mémoire"
kubectl apply -f $KIT/kyverno/limites-memoire.yaml
kubectl -n kyverno rollout status deployment/kyverno-reports-controller --timeout=180s >/dev/null
for i in $(seq 1 60); do [ "$(kubectl get policyreports -n colis --no-headers 2>/dev/null | wc -l)" -ge 6 ] && break; sleep 5; done
sleep 20
kubectl get policyreports -A -o json | jq -r '.items[] | "\(.metadata.namespace)\t\(.scope.kind)/\(.scope.name)\t\(.summary.pass // 0)\t\(.summary.fail // 0)"' \
  | sort | awk -F'\t' 'BEGIN {print "NAMESPACE\tOBJET\tPASS\tFAIL"} {print}' | column -t -s $'\t'
kubectl get policyreports -n cert-manager -o json | jq -r '[.items[].results[]? | select(.result == "fail") | .message] | first'

section "kyverno : génération"
kubectl apply -f $KIT/kyverno/refus-par-defaut.yaml
sleep 5
kubectl create ns ch45-fret
kubectl label ns ch45-fret cours/equipe=fret
cat > ch45-equipe.yaml <<'Y'
apiVersion: v1
kind: Namespace
metadata:
  name: ch45-equipe
  labels:
    cours/equipe: fret
Y
kubectl apply -f ch45-equipe.yaml
sleep 6
kubectl -n ch45-fret get networkpolicy
kubectl -n ch45-equipe get networkpolicy
kubectl -n ch45-equipe get networkpolicy refus-par-defaut -o json | jq '.metadata.labels'
kubectl -n ch45-equipe delete networkpolicy refus-par-defaut
for i in $(seq 1 30); do kubectl -n ch45-equipe get networkpolicy refus-par-defaut >/dev/null 2>&1 && { echo "recréée après environ $((i * 2)) s"; break; }; sleep 2; done

section "ex1"
kubectl apply -f $KIT/corrige/images-avertir.yaml
sleep 5
kubectl -n default create deployment essai-latest --image=nginx:latest --dry-run=server -o name
kubectl -n default create deployment essai-busybox --image=busybox:1.37 --dry-run=server -o name

section "ex2"
# la remise à zéro a supprimé puis recréé la politique : on redémarre l'API server pour repartir
# d'un informer de paramètres neuf (voir la section suivante)
redemarrer_api
kubectl -n politiques delete configmap images-autorisees
sleep 3
kubectl -n colis set env deployment/web ESSAI=1 --dry-run=server -o name
kubectl -n default create deployment essai-latest --image=nginx:latest --dry-run=server -o name
kubectl apply -f $KIT/politiques/images-parametres.yaml
sleep 3
kubectl -n colis set env deployment/web ESSAI=1 --dry-run=server -o name
kubectl delete -f $KIT/corrige/images-avertir.yaml

section "cache des paramètres"
message() { kubectl -n colis set image deployment/web web=nginx:latest --dry-run=server 2>&1 | tail -1 | sed 's/.*denied request: //'; }
kubectl delete -f $KIT/politiques/images-politique.yaml
sleep 3
kubectl apply -f $KIT/politiques/images-politique.yaml
sleep 5
kubectl -n politiques delete configmap images-autorisees
sleep 10
message
kubectl -n kube-system logs kube-apiserver-minikube --since=2m | grep -o 'informer started for .*' | tail -1
kubectl apply -f $KIT/politiques/images-parametres.yaml
redemarrer_api
kubectl -n politiques delete configmap images-autorisees
sleep 3
message
kubectl apply -f $KIT/politiques/images-parametres.yaml
sleep 3
message

section "ex3"
kubectl -n verif-images create configmap verif-images-code --from-file=webhook.py=$KIT/corrige/webhook-epingle.py --dry-run=client -o yaml | kubectl replace -f -
# le kubelet met à jour le fichier monté avec un peu de retard : on attend la nouvelle version avant de redémarrer
until kubectl -n verif-images exec deployment/verif-images -- grep -q epingler /app/webhook.py 2>/dev/null; do sleep 3; done
kubectl -n verif-images rollout restart deployment/verif-images
kubectl -n verif-images rollout status deployment/verif-images --timeout=120s
# l'ancien Pod répond encore tant qu'il n'a pas disparu : on attend qu'il n'en reste qu'un
until [ "$(kubectl -n verif-images get pods -l app=verif-images --no-headers | wc -l)" -eq 1 ]; do sleep 2; done
kubectl apply -f $KIT/corrige/epingle-configuration.yaml
until [ -n "$(kubectl get mutatingwebhookconfiguration epingle-images -o jsonpath='{.webhooks[0].clientConfig.caBundle}')" ]; do sleep 1; done
kubectl label ns ch45 cours/images-epinglees=oui >/dev/null
sleep 3
kubectl -n ch45 create deployment api-epinglee --image=host.minikube.internal:5001/colis/api:2.1 --dry-run=server -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n ch45 create deployment autre --image=busybox:1.37 --dry-run=server -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n verif-images logs deployment/verif-images | tail -3

section "ex4"
kubectl create ns ch45-tard >/dev/null
kubectl label ns ch45-tard cours/equipe=fret
sleep 6
kubectl -n ch45-tard get networkpolicy
kubectl apply -f $KIT/corrige/refus-par-defaut-existants.yaml
for i in $(seq 1 30); do kubectl -n ch45-tard get networkpolicy refus-par-defaut >/dev/null 2>&1 && break; sleep 2; done
kubectl -n ch45-tard get networkpolicy
kubectl -n ch45-fret get networkpolicy

echo; echo "### fin"
