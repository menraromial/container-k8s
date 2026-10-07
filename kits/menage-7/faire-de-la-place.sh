#!/usr/bin/env bash
# Avant la partie VII : retirer, par leur nom, ce que les parties III à VI ont installé
# et dont la suite ne se sert plus. Rien n'est supprimé « en masse » : chaque objet est nommé.
set -u
cd "$(dirname "$0")"

# 1. D'abord les webhooks et politiques de mutation dont le service va disparaître :
#    un webhook en failurePolicy Fail sans service bloquerait la création des Pods.
kubectl delete validatingwebhookconfiguration verif-images --ignore-not-found
kubectl delete mutatingwebhookconfiguration epingle-images --ignore-not-found
kubectl delete mutatingadmissionpolicybinding,mutatingadmissionpolicy defauts-securite --ignore-not-found

# 2. Les outils de la partie VI qui ne servent plus : Kyverno, External Secrets et Vault,
#    Sealed Secrets. La ValidatingAdmissionPolicy images-colis (chapitre 45) reste en place.
kubectl -n colis delete externalsecret colis-partenaire --ignore-not-found
kubectl -n colis delete secretstore vault --ignore-not-found
kubectl -n colis delete secret colis-partenaire --ignore-not-found
helm uninstall kyverno -n kyverno 2>/dev/null
helm uninstall external-secrets -n external-secrets 2>/dev/null
kubectl delete -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.40.0/controller.yaml --ignore-not-found
kubectl delete clusterrolebinding cours-vault-tokenreview --ignore-not-found
kubectl delete clusterrole lecture-colis cours-keda-lecture --ignore-not-found

# 3. Le VPA du chapitre 31 (KEDA et le HPA restent : Colis s'en sert)
kubectl -n colis delete vpa worker --ignore-not-found
helm uninstall vpa -n vpa 2>/dev/null
kubectl delete crd verticalpodautoscalers.autoscaling.k8s.io verticalpodautoscalercheckpoints.autoscaling.k8s.io --ignore-not-found

# 4. Le canari du chapitre 28 : la route envoie de nouveau tout /api à l'API.
#    La partie VIII refera des déploiements progressifs, avec un outil fait pour.
kubectl apply -f route.yaml
kubectl -n colis delete deployment,service api-canari --ignore-not-found

# 5. Les copies de Colis et les namespaces d'essai des parties III à VI
helm uninstall colis -n colis-helm 2>/dev/null
kubectl -n default delete deployment essai --ignore-not-found
kubectl delete namespace --ignore-not-found --wait=false \
  ch15 ch43 ch44 ch44-base ch44-libre ch45 ch45-equipe ch45-fret ch45-mut ch45-tard ch46 \
  ch47 ch47-analyse colis-audit colis-defi colis-dev colis-helm vitrine verif-images coffre \
  kyverno external-secrets vpa

# 6. Les volumes persistants libérés (Released) dont la réclamation a disparu
kubectl get pv -o json | jq -r '.items[] | select(.status.phase == "Released") | .metadata.name' |
  while read -r pv; do kubectl delete pv "$pv"; done
