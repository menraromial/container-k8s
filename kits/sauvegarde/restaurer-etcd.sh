#!/usr/bin/env bash
# Restaure un instantané d'etcd sur le nœud minikube (un seul membre). Le cluster revient à l'état
# de l'instantané : tout ce qui a été créé ou modifié depuis est perdu.
# Usage : bash restaurer-etcd.sh sauvegardes/etcd-AAAAMMJJ-HHMMSS.db
set -euo pipefail
SNAP=$1
IP=$(minikube ip)
TRAVAIL=$(mktemp -d)
MANIFESTES="kube-apiserver kube-controller-manager kube-scheduler etcd"
DATE=$(date +%Y%m%d-%H%M%S)

echo "1. Reconstruire un répertoire de données à partir de l'instantané (sur le poste)"
etcdutl snapshot restore "$SNAP" --data-dir "$TRAVAIL/etcd" \
  --name minikube --initial-cluster minikube=https://$IP:2380 --initial-advertise-peer-urls https://$IP:2380
tar -C "$TRAVAIL" -cf "$TRAVAIL/etcd.tar" etcd
docker cp "$TRAVAIL/etcd.tar" minikube:/var/lib/minikube/etcd-restaure.tar

echo "2. Arrêter le plan de contrôle : le kubelet arrête un Pod statique dont le manifeste disparaît"
minikube ssh -- "sudo mkdir -p /etc/kubernetes/arret-$DATE && for m in $MANIFESTES; do sudo mv /etc/kubernetes/manifests/\$m.yaml /etc/kubernetes/arret-$DATE/; done"
remettre() {   # en cas d'échec : l'ancien répertoire et les manifestes reviennent
  echo "!! échec : retour à l'état précédent"
  minikube ssh -- "sudo test -d /var/lib/minikube/etcd-avant-$DATE && { sudo rm -rf /var/lib/minikube/etcd; sudo mv /var/lib/minikube/etcd-avant-$DATE /var/lib/minikube/etcd; }; sudo mv /etc/kubernetes/arret-$DATE/*.yaml /etc/kubernetes/manifests/"
}
trap remettre ERR
for i in $(seq 1 60); do
  minikube ssh -- "sudo crictl ps -q --name '^(etcd|kube-apiserver)$'" | grep -q . || break
  sleep 2
done
echo "   etcd et l'API server sont arrêtés"

echo "3. Échanger les répertoires de données (l'ancien est gardé)"
minikube ssh -- "sudo mv /var/lib/minikube/etcd /var/lib/minikube/etcd-avant-$DATE && sudo tar -C /var/lib/minikube -xf /var/lib/minikube/etcd-restaure.tar && sudo rm /var/lib/minikube/etcd-restaure.tar"

echo "4. Redémarrer le plan de contrôle, puis le kubelet"
minikube ssh -- "sudo mv /etc/kubernetes/arret-$DATE/*.yaml /etc/kubernetes/manifests/ && sudo rmdir /etc/kubernetes/arret-$DATE"
trap - ERR
for i in $(seq 1 90); do
  kubectl get --raw /readyz >/dev/null 2>&1 && break
  sleep 2
done
kubectl get --raw /readyz >/dev/null && echo "   API server prêt après $((i * 2)) s"
minikube ssh -- sudo systemctl restart kubelet
rm -rf "$TRAVAIL"
echo "Ancien répertoire de données gardé sur le nœud : /var/lib/minikube/etcd-avant-$DATE"
