#!/usr/bin/env bash
# Chapitre 12 : mode rootless avec Podman (facultatif). Crée ch12-rootless et le supprime.
cd "$(dirname "$0")"; mkdir -p out/ch12p
D=$(mktemp -d -p $PWD/out)
podman run --rm docker.io/library/alpine:3.24 sh -c 'id; cat /proc/self/uid_map'
podman run --rm -v $D:/d:Z docker.io/library/alpine:3.24 sh -c 'touch /d/fichier; id -u'; ls -ln $D; rm -rf $D
podman run -d --name ch12-rootless docker.io/library/alpine:3.24 sleep 60 >/dev/null; sleep 1
ps -o pid,user,uid,comm -p $(podman inspect ch12-rootless --format '{{.State.Pid}}')
podman rm -f -t 0 ch12-rootless >/dev/null
