---
title: Les namespaces Linux
sidebar_label: 8. Les namespaces
description: Ce qu'est un namespace, les huit types que fournit Linux, comment les observer autour d'un conteneur Docker, entrer dedans avec nsenter, en créer avec unshare, et construire un conteneur à la main.
partie: 2
chapitre: '8'
---

import namespacesCible from '@site/src/figures/namespaces-cible.svg';
import conteneurALaMain from '@site/src/figures/conteneur-a-la-main.svg';

Au chapitre 1, on a vu le processus `sleep` d'un conteneur porter deux numéros à la fois : 264821 pour votre machine, 1 pour lui-même. Au chapitre 6, un conteneur avait sa propre interface réseau, sa propre adresse, ses propres routes, alors qu'il tournait sur le même noyau que tous les autres. On avait donné un nom à ce mécanisme, les namespaces, sans l'ouvrir. Ce chapitre l'ouvre. À la fin, vous aurez fabriqué un conteneur sans Docker, avec des commandes du noyau.

## Le laboratoire de la partie II

Tout ce chapitre, et les suivants, manipule directement le noyau : créer des namespaces, monter des systèmes de fichiers, écrire dans les cgroups. Ces opérations demandent les droits de `root`. Plutôt que de les faire sur votre poste avec `sudo`, où une fausse manipulation peut abîmer le système, et où les réglages de sécurité diffèrent d'une distribution à l'autre, on les fait dans un **laboratoire** : un conteneur Ubuntu qui contient tous les outils nécessaires, et qu'on lance en mode privilégié.

Téléchargez [l'archive du laboratoire](pathname:///kits/labo.tar.gz), décompressez-la, et construisez l'image :

```dockerfile title="labo/Dockerfile"
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
```

```bash
docker build -t labo:1.0 labo
```

Puis lancez-le. Chaque option compte, et chacune retire une protection :

```bash
docker run -it --rm --name labo --hostname labo \
  --privileged --pid=host --cgroupns=host -v labo:/labo labo:1.0
```

`--privileged` donne au conteneur tous les droits de `root` sur le noyau : créer des namespaces, monter des systèmes de fichiers, configurer le réseau. `--pid=host` le place dans le namespace de PID de votre machine : il voit tous ses processus, y compris ceux des autres conteneurs. `--cgroupns=host` lui montre l'arbre complet des cgroups de la machine (chapitre 9). Enfin, le volume `labo` monté sur `/labo` lui donne un dossier de travail sur un vrai système de fichiers ext4 : le système de fichiers du conteneur est lui-même un overlayfs, sur lequel certaines expériences du chapitre 10 échouent.

:::danger[Un conteneur privilégié, c'est root sur la machine]

Ce laboratoire n'isole presque rien : il peut lire la mémoire des autres processus, modifier le réseau et les montages de votre machine. C'est ce qui le rend utile ici, et c'est aussi la démonstration la plus claire de ce que signifie le mode privilégié. Ne lancez jamais une image que vous ne connaissez pas avec `--privileged`, et quittez le laboratoire (`exit`) quand vous avez fini. Le chapitre 12 revient sur ce que chaque protection retirée ici empêchait.

:::

Toutes les commandes de ce chapitre se tapent dans le laboratoire, sauf quand le texte précise « sur votre poste ». Si vous préférez travailler directement sur votre poste avec `sudo`, les commandes sont les mêmes ; seules les sorties changeront un peu.

Il nous faut aussi une cible : un conteneur ordinaire, lancé par Docker, qu'on observera de l'extérieur. Sur votre poste, dans un autre terminal :

```bash
docker run -d --name cible nginx:1.30-alpine
docker inspect cible --format '{{.State.Pid}}'
```

```sortie
511634
```

C'est le numéro de processus de nginx, vu de votre machine. Grâce à `--pid=host`, le laboratoire voit ce même numéro.

## Ce qu'est un namespace

Un namespace enveloppe une ressource globale du système et en donne une copie privée aux processus qui y appartiennent[^namespaces]. Tant que deux processus sont dans le même namespace de réseau, ils voient les mêmes interfaces et les mêmes ports ; dès que l'un passe dans un autre, il voit un réseau différent. Chaque processus appartient à exactement un namespace de chaque type, et le noyau montre à qui appartient qui dans le dossier `/proc/<pid>/ns` :

```bash
ls -l /proc/1/ns
```

```sortie
cgroup -> cgroup:[4026531835]
ipc -> ipc:[4026531839]
mnt -> mnt:[4026531832]
net -> net:[4026531833]
pid -> pid:[4026531836]
pid_for_children -> pid:[4026531836]
time -> time:[4026531834]
time_for_children -> time:[4026531834]
user -> user:[4026531837]
uts -> uts:[4026531838]
```

Ce sont les namespaces du processus 1 de votre machine, `systemd`. Chaque entrée est un lien symbolique dont le nom contient un numéro : l'identifiant du namespace (son numéro d'inode dans un système de fichiers interne du noyau). Deux processus sont dans le même namespace si et seulement si leurs liens portent le même numéro. Comparons avec nginx :

```bash
ls -l /proc/511634/ns
```

```sortie
cgroup -> cgroup:[4026534119]
ipc -> ipc:[4026534002]
mnt -> mnt:[4026534000]
net -> net:[4026534005]
pid -> pid:[4026534003]
pid_for_children -> pid:[4026534003]
time -> time:[4026531834]
time_for_children -> time:[4026531834]
user -> user:[4026531837]
uts -> uts:[4026534001]
```

Six namespaces sur huit ont un numéro différent : ce sont ceux que Docker a créés pour le conteneur. Deux sont identiques à ceux du poste : `time` et `user`.

<Figure svg={namespacesCible} num="8.1" alt="Pour chaque type de namespace, le numéro du processus 1 du poste et celui de nginx dans le conteneur cible. mnt, uts, ipc, pid, net et cgroup diffèrent ; user et time sont partagés.">
Les namespaces du poste et ceux du conteneur <code>cible</code>, avec les numéros réels relevés sur le poste du cours. Docker crée six namespaces par conteneur ; il laisse le conteneur partager ceux des utilisateurs et des horloges.
</Figure>

Linux fournit huit types de namespaces, apparus entre 2002 et 2020 :

| Type | Ce qu'il isole | Dans un conteneur Docker |
|---|---|---|
| `mnt` | les points de montage, donc l'arborescence des fichiers | propre |
| `uts` | le nom de la machine et le nom de domaine | propre |
| `ipc` | la mémoire partagée et les files de messages System V et POSIX | propre |
| `pid` | les numéros de processus | propre |
| `net` | les interfaces, adresses, routes, règles de pare-feu, ports | propre |
| `cgroup` | la vue sur l'arbre des cgroups | propre |
| `user` | les numéros d'utilisateurs et de groupes, les privilèges | partagé par défaut |
| `time` | les horloges « depuis le démarrage » | partagé |

Le namespace `user` mérite une attention particulière : parce que Docker ne le crée pas par défaut, l'utilisateur `root` d'un conteneur est le même `root` que celui de votre machine, simplement enfermé dans des vues restreintes. On y revient à la fin du chapitre, et au chapitre 12.

## Observer les namespaces d'un conteneur

`lsns` liste les namespaces d'un processus, avec le premier processus de chacun :

```bash
lsns -p 511634
```

```sortie
        NS TYPE   NPROCS    PID USER COMMAND
4026531834 time      662      1 root /sbin/init splash
4026531837 user      648      1 root /sbin/init splash
4026534000 mnt        23 511634 root nginx: master process nginx -g daemon off;
4026534001 uts        23 511634 root nginx: master process nginx -g daemon off;
4026534002 ipc        23 511634 root nginx: master process nginx -g daemon off;
4026534003 pid        23 511634 root nginx: master process nginx -g daemon off;
4026534005 net        23 511634 root nginx: master process nginx -g daemon off;
4026534119 cgroup     23 511634 root nginx: master process nginx -g daemon off;
```

La colonne `NPROCS` compte les processus de chaque namespace : 23 pour ceux du conteneur, c'est-à-dire nginx et ses 22 processus de travail, un par processeur du poste. Les namespaces `time` et `user`, eux, regroupent plus de 600 processus : tout le système.

Le fichier `status` d'un processus montre ses deux numéros d'un coup :

```bash
grep -E '^(Name|PPid|NSpid)' /proc/511634/status
```

```sortie
Name:	nginx
PPid:	511613
NSpid:	511634	1
```

`NSpid` donne le numéro du processus dans chaque namespace de PID imbriqué, du plus extérieur au plus intérieur : 511634 pour la machine, 1 dans le conteneur. Et le parent de nginx, le processus 511613, n'est ni Docker ni `dockerd` :

```bash
ps -o pid,ppid,cmd -p 511613
```

```sortie
    PID    PPID CMD
 511613       1 /usr/bin/containerd-shim-runc-v2 -namespace moby -id 090cfd7665399f9386ad5988ba7c9305268ad7ae808e994aa50...
```

C'est un « shim » de containerd, rattaché au processus 1 de la machine. Le chapitre 11 expliquera pourquoi il existe ; retenez qu'un conteneur survit grâce à lui à un redémarrage de containerd.

## Entrer dans un namespace : nsenter

`nsenter` lance une commande dans un ou plusieurs namespaces d'un processus existant, désigné par `--target`. On choisit les namespaces à rejoindre une par une. Entrons dans le réseau de nginx, et seulement dans son réseau :

```bash
nsenter --target 511634 --net ip -4 addr show eth0
nsenter --target 511634 --net ss -ltn
```

```sortie
2: eth0@if534: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default  link-netnsid 0
    inet 172.17.0.8/16 brd 172.17.255.255 scope global eth0
       valid_lft forever preferred_lft forever
State  Recv-Q Send-Q Local Address:Port Peer Address:Port
LISTEN 0      511          0.0.0.0:80        0.0.0.0:*
LISTEN 0      511             [::]:80           [::]:*
```

On voit l'interface du conteneur et nginx qui écoute sur le port 80. Mais les commandes `ip` et `ss` viennent du laboratoire, pas de l'image nginx : on n'est entré que dans le namespace réseau, et le processus voit toujours les fichiers du laboratoire. C'est une technique de dépannage précieuse en production : quand une image minimale ne contient aucun outil (les images *distroless* du chapitre 13), on apporte les siens et on n'emprunte au conteneur que son réseau.

Ajoutons les autres namespaces, et le décor change :

```bash
nsenter --target 511634 --uts hostname
nsenter --target 511634 --mount cat /etc/os-release | head -2
nsenter --target 511634 --mount --pid ps -e | head -5
```

```sortie
090cfd766539
NAME="Alpine Linux"
ID=alpine
PID   USER     TIME  COMMAND
    1 root      0:00 nginx: master process nginx -g daemon off;
   30 nginx     0:00 nginx: worker process
   31 nginx     0:00 nginx: worker process
   32 nginx     0:00 nginx: worker process
```

Avec `--uts`, on voit le nom de machine du conteneur. Avec `--mount`, on voit ses fichiers : c'est une Alpine, et c'est la commande `ps` d'Alpine qui s'exécute. Avec `--pid` en plus, on voit ses processus, nginx en tête avec le numéro 1. Vous venez de refaire `docker exec`, qui n'est rien d'autre que cela : un processus lancé dans tous les namespaces d'un conteneur existant.

## Créer un namespace : unshare

`unshare` fait l'inverse : il crée de nouveaux namespaces, puis y lance une commande. Commençons par le plus simple, celui du nom de machine :

```bash
hostname
unshare --uts bash -c 'hostname conteneur; echo "dedans : $(hostname)"'
echo "dehors : $(hostname)"
```

```sortie
labo
dedans : conteneur
dehors : labo
```

Le shell lancé par `unshare` a changé son nom de machine, et ce changement n'a été vu que de lui. Pour voir ce qui se passe réellement, `strace` affiche les appels système qu'un programme fait au noyau :

```bash
strace -f -e trace=unshare,clone,execve unshare --uts --pid --fork hostname
```

```sortie
execve("/usr/bin/unshare", ["unshare", "--uts", "--pid", "--fork", "hostname"], ...) = 0
unshare(CLONE_NEWUTS|CLONE_NEWPID)      = 0
clone(child_stack=NULL, flags=CLONE_CHILD_CLEARTID|CLONE_CHILD_SETTID|SIGCHLD, ...) = 565613
strace: Process 565613 attached
[pid 565613] execve("/usr/bin/hostname", ["hostname"], ...) = 0
```

La commande `unshare` porte le nom de l'appel système qu'elle utilise : `unshare(CLONE_NEWUTS|CLONE_NEWPID)` demande au noyau de nouveaux namespaces pour le nom de machine et pour les PID. Puis `clone` crée un processus fils, qui exécute `hostname`. Il n'existe en tout que trois appels système pour les namespaces : `clone` (créer un processus dans de nouveaux namespaces), `unshare` (y faire passer le processus courant) et `setns` (rejoindre un namespace existant, c'est ce qu'utilise `nsenter`). Tout outil de conteneurs, Docker compris, finit par ces trois appels.

### Le namespace de PID et ses deux pièges

L'option `--fork` n'est pas décorative. Comparons :

```bash
unshare --pid bash -c 'echo "mon PID : $$"'
unshare --pid --fork bash -c 'echo "mon PID : $$"; ps -e | head -3'
```

```sortie
mon PID : 506219
mon PID : 1
    PID TTY          TIME CMD
      1 ?        00:01:28 systemd
      2 ?        00:00:00 kthreadd
```

Premier piège : un processus ne change jamais de namespace de PID. `unshare(CLONE_NEWPID)` ne déplace pas le processus qui l'appelle ; il ne concerne que ses futurs enfants, dont le premier deviendra le processus 1 du nouveau namespace. Sans `--fork`, le `bash` lancé reste dans l'ancien namespace, avec son numéro ordinaire. Avec `--fork`, `unshare` crée d'abord un fils, qui devient le numéro 1.

Second piège : ce `bash` numéro 1 lance `ps`, et `ps` affiche... `systemd` et tous les processus de la machine. `ps` ne demande pas la liste des processus au noyau par un appel système ; il la lit dans le dossier `/proc`. Or `/proc` est un système de fichiers monté une fois pour toutes, qui montre le namespace de PID de celui qui l'a monté. Il faut donc un nouveau montage de `/proc`, et pour ne pas remplacer celui de la machine, un nouveau namespace de montage. C'est ce que fait l'option `--mount-proc` :

```bash
unshare --pid --fork --mount-proc bash -c 'echo "mon PID : $$"; ps -e'
```

```sortie
mon PID : 1
    PID TTY          TIME CMD
      1 ?        00:00:00 ps
```

Cette fois l'isolation est complète : `ps` est seul dans son univers, avec le numéro 1. Les namespaces se complètent les uns les autres, et ce n'est pas le dernier exemple de ce chapitre.

## Un conteneur à la main

Assemblons maintenant un vrai conteneur. Il faut d'abord des fichiers : le système de fichiers d'une image. `skopeo` télécharge une image depuis un registre sans passer par Docker, et `umoci` la déballe en un dossier. Les deux outils sont dans le laboratoire :

```bash
skopeo copy docker://alpine:3.24 oci:/labo/alpine:3.24
umoci unpack --image /labo/alpine:3.24 /labo/bundle
ls /labo/bundle
ls /labo/bundle/rootfs
du -sh /labo/bundle/rootfs
```

```sortie
config.json
rootfs
sha256_d56c381f961d307a21b3ca004cf1e3910f106644aefb1f43e654c8a56c4fd395.mtree
umoci.json
bin  dev  etc  home  lib  media  mnt  opt  proc  root  run  sbin  srv  sys  tmp  usr  var
8.7M	/labo/bundle/rootfs
```

`skopeo` a rangé l'image au format OCI du chapitre 3 dans `/labo/alpine`, et `umoci` a empilé ses couches dans `rootfs` : tout le système Alpine, 8,7 Mo. Le fichier `config.json` décrit comment lancer un conteneur à partir de ces fichiers ; il servira au chapitre 11. Ce dossier s'appelle un **bundle**.

Il ne reste qu'à combiner les namespaces et à changer de racine :

```bash
unshare --mount --uts --ipc --net --pid --fork chroot /labo/bundle/rootfs /bin/sh -c '
  mount -t proc proc /proc
  hostname fait-main
  echo "nom : $(hostname)"
  cat /etc/os-release | head -2
  ps
  ip addr'
```

```sortie
nom : fait-main
NAME="Alpine Linux"
ID=alpine
PID   USER     TIME  COMMAND
    1 root      0:00 /bin/sh -c mount -t proc proc /proc; hostname fait-main; ...
    7 root      0:00 ps
1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
```

Voilà un conteneur. Le laboratoire est une Ubuntu, et pourtant le processus voit une Alpine. Il a son propre nom de machine, il est le processus numéro 1 de son univers, et son réseau ne contient qu'une interface locale, éteinte. Tout cela sans Docker, avec une commande de l'`util-linux` et une autre, `chroot`, qui existe depuis 1979.

`chroot` fait ici le travail du changement de racine : il fait de `rootfs` la racine `/` du processus. C'est la façon la plus simple de le faire, mais pas la plus sûre : un processus `root` peut sortir d'un `chroot` par des manipulations connues. Les vrais runtimes utilisent un autre appel système, `pivot_root`, qui remplace la racine du namespace de montage tout entier et démonte l'ancienne, si bien qu'il n'en reste aucune trace accessible. runc le fait pour chaque conteneur, et vous le verrez au chapitre 11.

Vu du laboratoire, ce conteneur a bien ses propres namespaces. Lançons-le avec une commande qui dure, et regardons-le de l'extérieur :

```bash
unshare --mount --uts --ipc --net --pid --fork chroot /labo/bundle/rootfs /bin/sleep 30 &
sleep 1; P=$(pgrep -f '^/bin/sleep 30' | head -1); echo "PID vu du labo : $P"
lsns -p $P
```

```sortie
PID vu du labo : 506369
        NS TYPE   NPROCS    PID USER COMMAND
4026531834 time      589      1 root /sbin/init splash
4026531835 cgroup    576      1 root /sbin/init splash
4026531837 user      575      1 root /sbin/init splash
4026534000 mnt         2 506367 root unshare --mount --uts --ipc --net --pid --fork chroot /labo/bundle/rootfs /bin/sleep 30
4026534001 uts         2 506367 root unshare --mount --uts --ipc --net --pid --fork chroot /labo/bundle/rootfs /bin/sleep 30
4026534002 ipc         2 506367 root unshare --mount --uts --ipc --net --pid --fork chroot /labo/bundle/rootfs /bin/sleep 30
4026534003 pid         1 506369 root `-/bin/sleep 30
4026534005 net         2 506367 root unshare --mount --uts --ipc --net --pid --fork chroot /labo/bundle/rootfs /bin/sleep 30
```

Cinq namespaces neufs, exactement comme ceux de nginx à la figure 8.1, à ceci près que nous n'avons pas créé de namespace `cgroup`. Remarquez aussi la ligne `pid` : un seul processus, `sleep`, alors que les autres namespaces en comptent deux. Le processus `unshare` lui-même, qui a appelé `unshare(CLONE_NEWPID)`, est resté dans l'ancien namespace de PID, comme on l'a vu plus haut.

### Brancher le conteneur au réseau

Notre conteneur n'a qu'une interface éteinte. Refaisons à la main ce que Docker a fait au chapitre 6 : une paire veth, dont une extrémité passe dans le namespace réseau du conteneur.

```bash
unshare --net --fork sleep 60 &
sleep 1; P=$(pgrep -f '^sleep 60$' | head -1)
ip link add veth-labo type veth peer name veth-cont
ip link set veth-cont netns $P
ip addr add 10.99.0.1/24 dev veth-labo && ip link set veth-labo up
nsenter -t $P -n ip addr add 10.99.0.2/24 dev veth-cont
nsenter -t $P -n ip link set veth-cont up
nsenter -t $P -n ip -4 addr show veth-cont
ping -c 2 -W 1 10.99.0.2
```

```sortie
3: veth-cont@if4: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000 link-netnsid 0
    inet 10.99.0.2/24 scope global veth-cont
       valid_lft forever preferred_lft forever
PING 10.99.0.2 (10.99.0.2) 56(84) bytes of data.
64 bytes from 10.99.0.2: icmp_seq=1 ttl=64 time=0.061 ms
64 bytes from 10.99.0.2: icmp_seq=2 ttl=64 time=0.062 ms
```

`ip link set veth-cont netns $P` fait passer une extrémité dans le namespace réseau du processus `sleep`. On lui donne une adresse depuis l'intérieur avec `nsenter`, on donne l'autre adresse à l'extrémité restée dans le laboratoire, et les deux se répondent. Il ne manquerait qu'un pont pour y brancher plusieurs conteneurs, et des règles de traduction d'adresses pour sortir vers Internet : exactement ce que Docker pose pour vous.

Arrêtez le processus (`kill $P`), puis cherchez l'interface : `ip link show veth-labo` répond `Device "veth-labo" does not exist.` Quand le dernier processus d'un namespace réseau disparaît, le noyau détruit le namespace, ses interfaces, et avec elles l'extrémité de la paire restée dehors. C'est pour cela que les interfaces `veth...` de votre machine disparaissent d'elles-mêmes quand un conteneur s'arrête.

<Figure svg={conteneurALaMain} num="8.2" alt="Quatre étapes réalisées : des fichiers avec skopeo et umoci, des namespaces avec unshare, une racine avec chroot, l'intérieur avec mount proc, hostname et une paire veth. Trois manques : des limites (cgroups, chapitre 9), des couches (overlayfs, chapitre 10), des protections (capabilities, seccomp, chapitre 12).">
Le conteneur fait à la main, et ce qui le sépare encore d'un conteneur Docker. Chacun des chapitres suivants comble l'un de ces manques.
</Figure>

## Le namespace des utilisateurs

Il reste un namespace, le plus subtil. Faites cette expérience **sur votre poste**, pas dans le laboratoire, avec votre utilisateur ordinaire et sans `sudo` :

```bash
id
unshare --user --map-root-user bash -c 'id; cat /proc/self/uid_map; touch /tmp/fichier-userns; ls -ln /tmp/fichier-userns'
ls -ln /tmp/fichier-userns
```

```sortie
uid=1000(romial) gid=1000(romial) groups=1000(romial),4(adm),24(cdrom),27(sudo),...
uid=0(root) gid=0(root) groups=0(root),65534(nogroup),65534(nogroup),...
         0       1000          1
-rw-rw-r-- 1 0 0 0 Sep 25 12:37 /tmp/fichier-userns
-rw-rw-r-- 1 1000 1000 0 Sep 25 12:37 /tmp/fichier-userns
```

Dans le nouveau namespace, vous êtes `root`, uid 0, sans avoir tapé de mot de passe. Le fichier `/proc/self/uid_map` explique comment : sa ligne `0 1000 1` se lit « l'uid 0 dans le namespace correspond à l'uid 1000 dehors, pour une plage d'un seul numéro ». Le fichier créé par ce `root` appartient à l'uid 0 vu de l'intérieur, et à l'uid 1000, c'est-à-dire à vous, vu de l'extérieur. Les groupes affichés `nogroup` sont vos groupes supplémentaires, qui n'ont pas de correspondance dans le namespace.

Ce `root` n'a de pouvoir que sur ce qui appartient à son namespace :

```bash
unshare --user --map-root-user bash -c 'cat /etc/shadow; hostname essai'
```

```sortie
cat: /etc/shadow: Permission denied
hostname: you must be root to change the host name
```

Il ne peut pas lire le fichier des mots de passe, qui appartient au vrai `root` de la machine, ni changer le nom d'une machine dont le namespace UTS ne lui appartient pas. Mais il peut créer ses propres namespaces de montage, de réseau ou de PID, et y faire ce qu'il veut. C'est sur ce mécanisme que reposent Podman sans `root` (chapitre 0.2), le mode *rootless* de Docker et les namespaces d'utilisateurs de Kubernetes, que le chapitre 12 détaillera : un `root` de conteneur qui n'est qu'un utilisateur ordinaire pour la machine.

:::note[Ubuntu et les namespaces d'utilisateurs]

Depuis la version 24.04, Ubuntu restreint la création de namespaces d'utilisateurs par les programmes ordinaires, parce qu'ils ont servi de point d'appui à plusieurs failles du noyau. Le réglage `kernel.apparmor_restrict_unprivileged_userns` vaut 1 sur le poste du cours, et la commande `unshare` fonctionne quand même, grâce à un profil AppArmor qui l'autorise explicitement. D'autres programmes peuvent être refusés ; si c'est votre cas, faites l'expérience dans le laboratoire.

:::

## Exercices

:::exercice[Exercice 1 : apporter ses outils]

Depuis le laboratoire, faites une requête HTTP vers nginx en utilisant le `curl` du laboratoire, mais depuis le réseau du conteneur `cible` (à l'adresse `localhost`). Pourquoi ce `curl` n'est-il pas celui de l'image nginx ?

:::

<details>
<summary>Corrigé</summary>

Dans le laboratoire, avec le numéro de processus obtenu plus haut par `docker inspect` (le vôtre sera différent) :

```bash
nsenter --target 511634 --net curl -s localhost | grep -o '<title>.*</title>'
```

```sortie
<title>Welcome to nginx!</title>
```

`localhost` désigne l'interface locale du namespace réseau de `cible` : on parle donc à nginx comme s'il était sur la même machine. Mais on n'a rejoint que ce namespace-là : le namespace de montage est toujours celui du laboratoire, donc le programme exécuté est `/usr/bin/curl` du laboratoire (Ubuntu), et non celui de l'image nginx (Alpine), qui en contient d'ailleurs un aussi. C'est la technique de dépannage des conteneurs qui n'ont aucun outil.

</details>

:::exercice[Exercice 2 : deux numéros pour un processus]

Pour chaque processus de travail de nginx (`nginx: worker process`), affichez ses deux numéros de processus, celui de la machine et celui du conteneur, en une seule commande dans le laboratoire.

:::

<details>
<summary>Corrigé</summary>

```bash
for p in $(pgrep -f 'nginx: worker'); do grep NSpid /proc/$p/status; done | head -3
```

Chaque ligne affiche deux nombres, par exemple `NSpid: 511676 30` : 511676 pour la machine, 30 dans le conteneur, ce qui correspond à la sortie de `ps` vue par `nsenter` plus haut. Si le laboratoire était lui-même dans un namespace de PID différent de celui de la machine (sans `--pid=host`), il verrait trois nombres, un par niveau d'imbrication.

</details>

:::exercice[Exercice 3 : partager un namespace avec Docker]

Sur votre poste, lancez un conteneur Alpine qui partage le namespace de PID de `cible` (`docker run --rm --pid=container:cible alpine:3.24 ps`). Que voit-il ? Pourquoi la colonne `USER` affiche-t-elle `101` et non `nginx` ?

:::

<details>
<summary>Corrigé</summary>

```sortie
PID   USER     TIME  COMMAND
    1 root      0:00 nginx: master process nginx -g daemon off;
   30 101       0:00 nginx: worker process
   31 101       0:00 nginx: worker process
```

Le conteneur Alpine voit les processus de nginx, avec leurs numéros du conteneur `cible`, et se voit aussi lui-même : il partage le namespace de PID, mais pas les autres. Ses fichiers sont ceux d'Alpine, dont le fichier `/etc/passwd` ne contient pas d'utilisateur numéro 101 : `ps` ne peut que montrer le numéro. C'est le pendant, pour les PID, de l'exercice 4 du chapitre 6 qui partageait le réseau, et c'est ainsi que Kubernetes permet à plusieurs conteneurs d'un même Pod de se voir (chapitre 17).

</details>

:::exercice[Exercice 4 : ce qui manque au conteneur fait main]

Lancez le conteneur fait main avec `sh` interactif, puis essayez successivement : `ls /sys`, `cat /proc/meminfo | head -1`, et un programme qui consomme beaucoup de mémoire. Qu'est-ce qui, dans ce que vous voyez, révèle que le conteneur n'est pas encore aussi isolé qu'un conteneur Docker ?

:::

<details>
<summary>Corrigé</summary>

`/sys` est vide : on ne l'a pas monté, contrairement à Docker, qui monte `/sys` en lecture seule. `/proc/meminfo` affiche toute la mémoire de la machine : le namespace de PID ne cache pas les compteurs globaux. Et rien n'empêche le conteneur de consommer toute la mémoire ou tout le processeur de la machine : aucune limite n'est posée. Enfin, son `root` a tous les privilèges du `root` du laboratoire. Ces manques sont exactement ceux de la figure 8.2 : le chapitre 9 ajoute les limites, le chapitre 12 les protections.

</details>

## Nettoyer

Quittez le laboratoire avec `exit` : l'option `--rm` le supprime, mais le volume `labo` et son contenu (l'image Alpine déballée) restent pour les chapitres suivants. Sur votre poste, supprimez la cible :

```bash
docker rm -f cible
```

[^namespaces]: Linux man-pages, `namespaces(7)`, sections *Namespace types* et *The /proc/pid/ns/ directory* ; voir aussi `pid_namespaces(7)`, `user_namespaces(7)` et `unshare(2)`. [man7.org/linux/man-pages/man7/namespaces.7.html](https://man7.org/linux/man-pages/man7/namespaces.7.html)
