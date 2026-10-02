#!/usr/bin/env bash
# Branche (ou débranche) le fournisseur du cours sur l'API server de minikube.
# À lancer dans le dossier qui contient idp-ca.crt (et authentification.yaml s'il existe déjà).
#   brancher-fournisseur.sh           installe la configuration ; au premier appel, redémarre l'API server
#   brancher-fournisseur.sh --retirer remet le manifeste d'origine
set -euo pipefail
PROFIL=${PROFIL:-minikube}
MANIFESTE=/etc/kubernetes/manifests/kube-apiserver.yaml
COPIE=/etc/kubernetes/kube-apiserver.yaml.cours
DOSSIER=/var/lib/minikube/certs/cours-authn
noeud() { minikube -p "$PROFIL" ssh -- "$@" 2>/dev/null; }

attendre_api() {
  sleep 5
  until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 2; done
}

if [ "${1:-}" = "--retirer" ]; then
  noeud "sudo test -f $COPIE && sudo cp $COPIE $MANIFESTE && sudo rm $COPIE && sudo rm -rf $DOSSIER" || true
  attendre_api
  echo "API server remis dans son état d'origine"
  exit 0
fi

# authentification.yaml est produit à partir du modèle la première fois ; ensuite, c'est le vôtre.
if [ ! -f authentification.yaml ]; then
  CA=$(mktemp)
  sed 's/^/      /' idp-ca.crt > "$CA"
  sed -e "/CA_DU_FOURNISSEUR/{r $CA" -e 'd}' "$(dirname "$0")/authentification.yaml.modele" > authentification.yaml
  rm "$CA"
fi
minikube -p "$PROFIL" cp authentification.yaml "$PROFIL:$DOSSIER/authentification.yaml" >/dev/null
if noeud "sudo grep -q authentication-config $MANIFESTE"; then
  echo "fichier remplacé ; l'API server le relit seul, sans redémarrer"
  exit 0
fi
noeud "sudo cp $MANIFESTE $COPIE"
noeud "sudo sed -i 's|^    - kube-apiserver$|&\n    - --authentication-config=$DOSSIER/authentification.yaml|' $MANIFESTE"
attendre_api
echo "API server redémarré avec $DOSSIER/authentification.yaml"
