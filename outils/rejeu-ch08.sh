#!/usr/bin/env bash
# Chapitre 8 : les namespaces. Lance le labo en arrière-plan (conteneur « labo », volume « labo »)
# et y exécute les commandes du chapitre. Ne supprime que le conteneur labo (le volume est gardé pour la suite).
cd "$(dirname "$0")"; O=$PWD/out/ch08; rm -rf $O; mkdir -p $O
L() { local n=$1; shift; echo "### $n : $*"; docker exec labo bash -c "$*" > $O/$n.txt 2>&1; cat $O/$n.txt; }
H() { local n=$1; shift; echo "### $n : $*"; bash -c "$*" > $O/$n.txt 2>&1; cat $O/$n.txt; }
docker rm -f labo >/dev/null 2>&1
docker run -d --name labo --hostname labo --privileged --pid=host --cgroupns=host -v labo:/labo labo:1.0 sleep infinity >/dev/null
docker rm -f cible >/dev/null 2>&1; docker run -d --name cible nginx:1.30-alpine >/dev/null; sleep 1
API=$(docker inspect cible --format '{{.State.Pid}}')
H 01-pid-api "docker inspect cible --format '{{.State.Pid}}'"
L 02-ns-self "ls -l /proc/self/ns | awk '{print \$9, \$10, \$11}'"
L 03-ns-api "ls -l /proc/$API/ns | awk '{print \$9, \$10, \$11}'; echo ---; ls -l /proc/1/ns | awk '{print \$9, \$10, \$11}'"
L 04-lsns-api "lsns -p $API"
L 05-nsenter-net "nsenter --target $API --net ip -4 addr show eth0; nsenter --target $API --net ss -ltnp"
L 06-nsenter-uts-mnt "nsenter --target $API --uts hostname; nsenter --target $API --mount cat /etc/os-release | head -2; nsenter --target $API --mount --pid ps -e 2>&1 | head -5"
L 07-uts "hostname; unshare --uts bash -c 'hostname conteneur; echo \"dedans : \$(hostname)\"'; echo \"dehors : \$(hostname)\""
L 08-pid "unshare --pid --fork --mount-proc bash -c 'echo \"mon PID : \$\$\"; ps -e'"
L 09-pid-sans-fork "unshare --pid bash -c 'echo \"mon PID : \$\$\"' 2>&1; unshare --pid --fork bash -c 'echo \"mon PID : \$\$\"; ps -e | head -3'"
L 10-image "rm -rf /labo/alpine /labo/bundle; skopeo copy -q docker://alpine:3.24 oci:/labo/alpine:3.24 && umoci unpack --image /labo/alpine:3.24 /labo/bundle >/dev/null 2>&1; ls /labo/bundle; ls /labo/bundle/rootfs; du -sh /labo/bundle/rootfs"
L 11-a-la-main "unshare --mount --uts --ipc --net --pid --fork chroot /labo/bundle/rootfs /bin/sh -c 'mount -t proc proc /proc; hostname fait-main; echo \"nom : \$(hostname)\"; cat /etc/os-release | head -2; ps; ip addr'"
L 12-lsns-fait-main "unshare --mount --uts --ipc --net --pid --fork chroot /labo/bundle/rootfs /bin/sleep 30 & sleep 1; P=\$(pgrep -f '^/bin/sleep 30' | head -1); echo \"PID vu du labo : \$P\"; lsns -p \$P; kill \$P"
L 13-veth "unshare --net --fork sleep 60 & sleep 1; P=\$(pgrep -f '^sleep 60\$' | head -1); ip link add veth-labo type veth peer name veth-cont; ip link set veth-cont netns \$P; ip addr add 10.99.0.1/24 dev veth-labo; ip link set veth-labo up; nsenter -t \$P -n ip addr add 10.99.0.2/24 dev veth-cont; nsenter -t \$P -n ip link set veth-cont up; nsenter -t \$P -n ip link set lo up; nsenter -t \$P -n ip -4 addr show veth-cont; ping -c 2 -W 1 10.99.0.2; kill \$P; sleep 1; ip link show veth-labo 2>&1 | head -1"
H 14-user-hote "id; unshare --user --map-root-user bash -c 'id; cat /proc/self/uid_map; touch /tmp/fichier-userns; ls -ln /tmp/fichier-userns'; ls -ln /tmp/fichier-userns; rm /tmp/fichier-userns"
H 15-user-hote-refus "unshare --user --map-root-user bash -c 'cat /etc/shadow 2>&1 | head -1; hostname essai 2>&1'"
echo "labo en marche (docker exec -it labo bash)"
