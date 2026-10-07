#!/usr/bin/env bash
# Branche (ou débranche) le chiffrement au repos des Secrets sur l'API server de minikube.
#   brancher-chiffrement.sh FICHIER   installe FICHIER (une EncryptionConfiguration) ; au premier appel,
#                                     ajoute l'option à l'API server et attend son redémarrage
#   brancher-chiffrement.sh --retirer remet le manifeste d'origine (les Secrets chiffrés deviennent illisibles :
#                                     les réécrire en clair AVANT, voir le chapitre 46)
set -euo pipefail
PROFIL=${PROFIL:-minikube}
MANIFESTE=/etc/kubernetes/manifests/kube-apiserver.yaml
COPIE=/etc/kubernetes/kube-apiserver.yaml.cours-ch46
DOSSIER=/var/lib/minikube/certs/cours-chiffrement
noeud() { minikube -p "$PROFIL" ssh -- "$@" 2>/dev/null; }
attendre_api() {
  sleep 5
  for _ in $(seq 1 90); do kubectl get --raw /readyz >/dev/null 2>&1 && return 0; sleep 2; done
  echo "l'API server ne devient pas prêt : des données chiffrées sont-elles devenues illisibles ?" >&2
  return 1
}

if [ "${1:-}" = "--retirer" ]; then
  if kubectl get --raw /readyz >/dev/null 2>&1 && [ "${FORCER:-}" != oui ]; then
    echo "Avant de retirer le chiffrement, réécrivez les Secrets en clair (fournisseur identity en tête)." >&2
    echo "Sinon l'API server ne pourra plus les lire. FORCER=oui pour passer outre." >&2
    exit 1
  fi
  noeud "sudo test -f $COPIE && sudo cp $COPIE $MANIFESTE && sudo rm $COPIE && sudo rm -rf $DOSSIER" || true
  attendre_api
  echo "API server remis dans son état d'origine"
  exit 0
fi

minikube -p "$PROFIL" cp "$1" "$PROFIL:$DOSSIER/chiffrement.yaml" >/dev/null
noeud "sudo chmod 600 $DOSSIER/chiffrement.yaml"
if noeud "sudo grep -q encryption-provider-config $MANIFESTE"; then
  echo "configuration remplacée ; l'API server la relit seul (rechargement automatique)"
  exit 0
fi
noeud "sudo cp $MANIFESTE $COPIE"
noeud "sudo sed -i 's|^    - kube-apiserver$|&\n    - --encryption-provider-config=$DOSSIER/chiffrement.yaml\n    - --encryption-provider-config-automatic-reload=true|' $MANIFESTE"
attendre_api
echo "API server redémarré avec $DOSSIER/chiffrement.yaml"
