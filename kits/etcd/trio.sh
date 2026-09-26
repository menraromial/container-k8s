#!/usr/bin/env bash
# Un cluster etcd de trois membres, dans trois conteneurs Docker, pour observer Raft.
#   ./trio.sh demarrer    crée le réseau cours-etcd et les conteneurs cours-etcd-1, -2 et -3
#   ./trio.sh supprimer   les supprime, avec leurs données
# Environ 15 Mio de mémoire par membre. Même image que l'etcd de minikube.
IMAGE=registry.k8s.io/etcd:3.7.0-0
MEMBRES=e1=http://cours-etcd-1:2380,e2=http://cours-etcd-2:2380,e3=http://cours-etcd-3:2380
case "$1" in
  demarrer)
    docker network create cours-etcd >/dev/null
    for i in 1 2 3; do
      docker run -d --name cours-etcd-$i --network cours-etcd $IMAGE etcd \
        --name e$i --data-dir /var/lib/etcd \
        --listen-client-urls http://0.0.0.0:2379 --advertise-client-urls http://cours-etcd-$i:2379 \
        --listen-peer-urls http://0.0.0.0:2380 --initial-advertise-peer-urls http://cours-etcd-$i:2380 \
        --initial-cluster $MEMBRES --initial-cluster-state new --initial-cluster-token cours >/dev/null
    done
    echo "cours-etcd-1, cours-etcd-2 et cours-etcd-3 démarrés" ;;
  supprimer)
    docker rm -f cours-etcd-1 cours-etcd-2 cours-etcd-3 >/dev/null
    docker network rm cours-etcd >/dev/null
    echo "trio supprimé" ;;
  *) echo "usage : $0 demarrer|supprimer"; exit 1 ;;
esac
