#!/usr/bin/env bash
# Instantané d'etcd du nœud minikube, rapatrié sur le poste, avec la configuration de chiffrement
# du chapitre 46 : sans elle, les Secrets de l'instantané sont illisibles.
# Usage : bash sauvegarder-etcd.sh [dossier]      (par défaut : ./sauvegardes)
#         PROFIL=montee bash sauvegarder-etcd.sh    pour un autre profil minikube (chapitre 53)
set -euo pipefail
DEST=${1:-sauvegardes}
PROFIL=${PROFIL:-minikube}
mkdir -p "$DEST"
NOM=etcd-$(date +%Y%m%d-%H%M%S)
C=/var/lib/minikube/certs/etcd
kubectl -n kube-system exec etcd-$PROFIL -- etcdctl --cacert=$C/ca.crt --cert=$C/server.crt --key=$C/server.key \
  snapshot save /var/lib/minikube/etcd/$NOM.db
docker cp $PROFIL:/var/lib/minikube/etcd/$NOM.db "$DEST/$NOM.db"
minikube -p $PROFIL ssh -- sudo rm -f /var/lib/minikube/etcd/$NOM.db
# la clé : à ranger AILLEURS que l'instantané (un coffre, un autre support), jamais à côté
CLE=$(minikube -p $PROFIL ssh -- "sudo grep -o 'encryption-provider-config=[^ ]*' /etc/kubernetes/manifests/kube-apiserver.yaml" | cut -d= -f2 | tr -d '\r' || true)
if [ -n "$CLE" ]; then
  minikube -p $PROFIL ssh -- sudo cat "$CLE" > "$DEST/$NOM.cle.yaml"
else
  echo "pas de chiffrement au repos sur ce nœud"
fi
chmod 600 "$DEST"/$NOM.*
etcdutl snapshot status "$DEST/$NOM.db" -w table
echo "$DEST/$NOM.db"
