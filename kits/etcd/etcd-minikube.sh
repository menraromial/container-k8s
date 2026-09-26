# À charger avec « source etcd-minikube.sh » : définit la fonction E, qui lance etcdctl
# dans le Pod etcd de minikube avec les certificats du nœud (l'image n'a pas de shell).
C=/var/lib/minikube/certs/etcd
E() {
  kubectl -n kube-system exec -i etcd-minikube -- \
    etcdctl --cacert=$C/ca.crt --cert=$C/server.crt --key=$C/server.key "$@"
}
