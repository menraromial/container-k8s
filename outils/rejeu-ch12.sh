#!/usr/bin/env bash
# Chapitre 12 : sécurité d'un conteneur. Conteneurs éphémères (--rm) uniquement, sur alpine:3.24.
cd "$(dirname "$0")"; O=$PWD/out/ch12; rm -rf $O; mkdir -p $O
H() { local n=$1; shift; echo "### $n : $*"; timeout 120 bash -c "$*" > $O/$n.txt 2>&1; head -c 12000 $O/$n.txt; }
A="docker run --rm alpine:3.24"
H 01-caps "$A grep Cap /proc/self/status"
H 02-decode "docker run --rm labo:1.0 capsh --decode=00000000a80425fb"
H 03-privileged "docker run --rm --privileged alpine:3.24 grep CapEff /proc/self/status; $A grep CapEff /proc/self/status; docker run --rm --cap-drop ALL alpine:3.24 grep CapEff /proc/self/status"
H 04-netadmin "docker run --rm labo:1.0 ip link add essai0 type dummy; echo code=\$?; docker run --rm --cap-add NET_ADMIN labo:1.0 sh -c 'ip link add essai0 type dummy && ip -br link show essai0'"
H 05-dropall "docker run --rm --cap-drop ALL alpine:3.24 sh -c 'id; chown nobody /etc/hostname; echo code=\$?; ping -c1 -W1 127.0.0.1 >/dev/null; echo ping=\$?'"
H 06-root-hote "D=\$(mktemp -d -p \$PWD/out); $A touch /d/fichier -v 2>/dev/null; docker run --rm -v \$D:/d alpine:3.24 sh -c 'touch /d/fichier; id -u'; ls -ln \$D; docker run --rm -v \$D:/d alpine:3.24 rm /d/fichier; rmdir \$D"
H 07-user "docker run --rm --user 1000:1000 alpine:3.24 sh -c 'id; touch /etc/essai; echo code=\$?'; docker image inspect nginx:1.30-alpine --format 'User={{.Config.User}}'"
H 08-seccomp-etat "$A grep -E 'Seccomp|NoNewPrivs' /proc/self/status; docker run --rm --security-opt seccomp=unconfined alpine:3.24 grep -E '^Seccomp:' /proc/self/status"
H 09-seccomp-unshare "$A unshare -U -r id; echo code=\$?; docker run --rm --security-opt seccomp=unconfined alpine:3.24 unshare -U -r id; echo code=\$?"
H 10-apparmor "$A cat /proc/self/attr/current; docker info --format '{{json .SecurityOptions}}'"
H 11-mount "docker run --rm --cap-add SYS_ADMIN alpine:3.24 mount -t tmpfs none /mnt; echo code=\$?; docker run --rm --cap-add SYS_ADMIN --security-opt apparmor=unconfined alpine:3.24 sh -c 'mount -t tmpfs none /mnt && df -h /mnt | tail -1'; echo code=\$?"
H 12-nonroot-caps "docker run --rm --user 1000 alpine:3.24 grep CapEff /proc/self/status"
H 13-nnp "docker run --rm labo:1.0 sh -c 'cp /usr/bin/id /usr/local/bin/id-suid && chmod u+s /usr/local/bin/id-suid && setpriv --reuid 1000 --regid 1000 --clear-groups /usr/local/bin/id-suid'; docker run --rm --security-opt no-new-privileges labo:1.0 sh -c 'cp /usr/bin/id /usr/local/bin/id-suid && chmod u+s /usr/local/bin/id-suid && grep NoNewPrivs /proc/self/status && setpriv --reuid 1000 --regid 1000 --clear-groups /usr/local/bin/id-suid'"
H 14-profil "P=\$PWD/out/ch12/sans-mkdir.json; printf '%s' '{\"defaultAction\":\"SCMP_ACT_ALLOW\",\"syscalls\":[{\"names\":[\"mkdir\",\"mkdirat\"],\"action\":\"SCMP_ACT_ERRNO\"}]}' > \$P; cat \$P; echo; docker run --rm --security-opt seccomp=\$P alpine:3.24 sh -c 'mkdir /essai; echo code=\$?; touch /essai.txt && echo touch ok'"
H 15-readonly "docker run --rm --read-only alpine:3.24 touch /essai; echo code=\$?; docker run --rm --read-only --tmpfs /tmp alpine:3.24 sh -c 'touch /tmp/essai && echo /tmp ok'"
H 16-privileged-diff "$A sh -c 'ls /dev | wc -l; grep Seccomp: /proc/self/status; cat /proc/self/attr/current'; docker run --rm --privileged alpine:3.24 sh -c 'ls /dev | wc -l; grep Seccomp: /proc/self/status; cat /proc/self/attr/current'"
H 17-couches "for o in '' '--security-opt seccomp=unconfined' '--security-opt seccomp=unconfined --security-opt apparmor=unconfined' '--cap-add SYS_ADMIN' '--cap-add SYS_ADMIN --security-opt apparmor=unconfined'; do echo \"[\$o]\"; docker run --rm \$o alpine:3.24 sh -c 'mount -t tmpfs none /mnt 2>&1; echo code=\$?'; done"
