# Laboratoire de la partie II : un Ubuntu avec les outils pour manipuler
# namespaces, cgroups, systèmes de fichiers en couches et runtimes.
# À lancer en conteneur privilégié (voir le chapitre 8) : il a alors les droits de root sur la machine.
FROM ubuntu:26.04

LABEL org.opencontainers.image.title="labo" \
      org.opencontainers.image.description="Laboratoire de la partie II du cours Conteneurs et Kubernetes" \
      org.opencontainers.image.source="https://github.com/menraromial/container-k8s"

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      util-linux iproute2 iputils-ping procps psmisc bsdextrautils less \
      runc crun busybox-static stress-ng iptables \
      jq curl ca-certificates strace libcap2-bin attr file tree skopeo umoci \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /labo
CMD ["bash"]
