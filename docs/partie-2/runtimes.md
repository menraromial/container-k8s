---
title: Les runtimes
sidebar_label: 11. Les runtimes
description: La spécification OCI, runc et crun, containerd et ses shims, le CRI de Kubernetes ; un bundle OCI lancé avec runc sans Docker, puis la même chaîne observée dans le nœud minikube.
partie: 2
chapitre: '11'
---

import pileRuntimes from '@site/src/figures/pile-runtimes.svg';
import podPause from '@site/src/figures/pod-pause.svg';

Trois chapitres ont démonté un conteneur pièce par pièce : des namespaces pour ce qu'il voit, des cgroups pour ce qu'il consomme, des couches overlay pour ses fichiers. Au chapitre 8, un conteneur fabriqué avec `unshare` et `chroot` tenait en une dizaine de commandes, mais il lui manquait beaucoup : pas de limites, pas de protections, un réseau à brancher à la main. Il reste une question : quel programme fait tout cela, dans le bon ordre, quand on tape `docker run` ?

La réponse tient en un mot, **runtime**, qui désigne en réalité toute une chaîne de programmes. Au bout de la chaîne, un petit outil, `runc`, lit un fichier de configuration et fait les appels système que nous avons faits à la main. Au-dessus de lui, `containerd` gère les images et les conteneurs, et tout en haut, Docker ou Kubernetes décident de ce qu'il faut lancer. Ce chapitre descend cette chaîne par le bas : il commence par lancer un conteneur avec `runc` seul, sans Docker, puis remonte jusqu'au kubelet de minikube.

Il se fait dans le laboratoire du chapitre 8, qui contient `runc` et `crun`, avec un conteneur `cible` neuf :

```bash
docker run -d --name cible nginx:1.30-alpine
docker run -it --rm --name labo --hostname labo \
  --privileged --pid=host --cgroupns=host -v labo:/labo labo:1.0
```

La dernière partie du chapitre utilise aussi minikube ; démarrez-le quand vous y arriverez.

## Une norme pour tous : l'OCI

En 2015, Docker n'était pas seul. CoreOS développait `rkt` et son propre format d'image, appc, et l'on craignait qu'une image construite pour un outil ne fonctionne pas avec l'autre. Pour éviter cette guerre des formats, Docker, CoreOS et une vingtaine d'entreprises ont fondé en juin 2015 l'**Open Container Initiative** (OCI), sous l'égide de la Linux Foundation, avec une mission étroite : écrire des normes ouvertes pour les conteneurs[^oci-about]. Docker y a versé le code de son moteur d'exécution, `libcontainer`, qui est devenu `runc`.

L'OCI publie aujourd'hui trois spécifications :

- la **spécification d'image** (*image-spec*) décrit ce qu'est une image : un manifeste, une configuration et des couches tar, exactement ce que nous avons décortiqué aux chapitres 3 et 10 ;
- la **spécification de distribution** (*distribution-spec*) décrit l'API HTTP d'un registre, celle que `docker pull` et `skopeo` utilisent ;
- la **spécification de runtime** (*runtime-spec*) décrit comment exécuter un conteneur à partir d'un dossier sur le disque.

C'est cette dernière qui nous occupe. Elle définit deux choses[^runtime-spec]. D'abord le **bundle** : un dossier qui contient un fichier `config.json` et, le plus souvent, un sous-dossier `rootfs` avec les fichiers du conteneur. Ensuite les **opérations** qu'un runtime doit savoir faire sur un bundle : `create`, `start`, `kill`, `delete` et `state`. Tout programme qui respecte ce contrat est un runtime OCI, et un bundle peut être lancé par n'importe lequel d'entre eux.

Vous avez déjà fabriqué un bundle : au chapitre 8, `umoci unpack` a transformé l'image Alpine en un dossier `/labo/bundle` qui contient justement `config.json` et `rootfs`. Nous allons nous en servir, mais en partant du fichier de configuration minimal que propose `runc`.

## Le fichier config.json

`runc spec` écrit, dans le dossier courant, un `config.json` par défaut. Créez un dossier de travail et regardez-en les parties principales :

```bash
runc --version
mkdir -p /labo/runc-essai && cd /labo/runc-essai
runc spec
jq '{ociVersion, process: {terminal: .process.terminal, args: .process.args, cwd: .process.cwd}, root, hostname, namespaces: [.linux.namespaces[].type]}' config.json
```

```sortie
runc version 1.4.0-0ubuntu1
spec: 1.3.0
go: go1.24.9
libseccomp: 2.6.0
{
  "ociVersion": "1.3.0",
  "process": {
    "terminal": true,
    "args": [
      "sh"
    ],
    "cwd": "/"
  },
  "root": {
    "path": "rootfs",
    "readonly": true
  },
  "hostname": "runc",
  "namespaces": [
    "pid",
    "network",
    "ipc",
    "uts",
    "mount",
    "cgroup"
  ]
}
```

La première ligne annonce la couleur : `runc` 1.4 implémente la version 1.3.0 de la spécification, écrit en Go, et utilise `libseccomp` pour les filtres d'appels système du chapitre 12. Le fichier, lui, se lit presque comme une commande `unshare` écrite en JSON :

- `process` décrit le programme à lancer : ses arguments (`sh`), son dossier de travail, et s'il doit recevoir un terminal ;
- `root` désigne le dossier qui deviendra la racine, ici `rootfs`, relatif au bundle, et le monte en lecture seule ;
- `hostname` est le nom de machine que verra le conteneur, posé dans son namespace UTS ;
- `namespaces` liste les namespaces à créer : six des huit que nous connaissons. Il manque `user`, puisque le conteneur tournera en root sur l'hôte, et `time`, que presque personne n'utilise.

Le fichier contient bien d'autres choses, que deux requêtes de plus font apparaître :

```bash
jq '.process.capabilities.bounding' config.json
jq '.linux.maskedPaths | length' config.json
jq -c '[.mounts[].destination]' config.json
```

```sortie
[
  "CAP_AUDIT_WRITE",
  "CAP_KILL",
  "CAP_NET_BIND_SERVICE"
]
10
["/proc","/dev","/dev/pts","/dev/shm","/dev/mqueue","/sys","/sys/fs/cgroup"]
```

La liste `mounts` reprend ce que nous faisions après `chroot` au chapitre 8 : monter `/proc`, un `/dev` minimal, `/sys`. `maskedPaths` cache dix chemins sensibles de `/proc` et `/sys`, comme `/proc/kcore`, qui donnerait accès à la mémoire du noyau. Et `capabilities` ne laisse au processus que trois des quarante et quelques privilèges de root. Ces protections sont le sujet du chapitre 12 ; retenez pour l'instant qu'elles se trouvent là, dans le `config.json`, et que c'est le runtime qui les applique.

## Un conteneur lancé par runc

Il manque au bundle ses fichiers. Copiez ceux de l'Alpine du chapitre 8, puis modifiez trois champs : pas de terminal, un programme qui dure (`sleep 300`) et un nom de machine à nous.

```bash
cp -a /labo/bundle/rootfs rootfs
jq '.process.terminal=false | .process.args=["sleep","300"] | .hostname="demo"' config.json > c.json && mv c.json config.json
ls
```

```sortie
config.json
rootfs
```

Le dossier est un bundle complet. Lancez-le, en arrière-plan, sous le nom `demo` :

```bash
runc run --detach demo
runc list
runc state demo | jq '{id, pid, status, bundle, created}'
```

```sortie
ID          PID         STATUS      BUNDLE             CREATED                          OWNER
demo        606558      running     /labo/runc-essai   2026-09-25T14:45:43.040218435Z   root
{
  "id": "demo",
  "pid": 606558,
  "status": "running",
  "bundle": "/labo/runc-essai",
  "created": "2026-09-25T14:45:43.040218435Z"
}
```

Aucun démon n'a été contacté : pas de `dockerd`, pas de `containerd`. `runc` a lu `config.json`, créé le conteneur, puis a rendu la main. Ce qui tourne, c'est le processus 606558, et `runc` se souvient de lui grâce à un petit fichier d'état qu'il range dans `/run/runc/demo/state.json`.

Regardons ce processus avec les outils des chapitres 8 et 9 :

```bash
runc ps demo
P=$(runc state demo | jq .pid)
lsns -p $P | tail -n +2 | awk '{print $2}' | sort | tr '\n' ' '; echo
cat /proc/$P/cgroup
```

```sortie
UID          PID    PPID  C STIME TTY          TIME CMD
root      606558  597564  0 14:45 ?        00:00:00 sleep 300
cgroup ipc mnt net pid time user uts
0::/system.slice/demo
```

`lsns` liste tous les namespaces du processus, y compris ceux qu'il partage avec le laboratoire (`time` et `user`) ; les six autres sont neufs. Et `runc` lui a créé un cgroup, `/system.slice/demo`, où il aurait écrit des limites si le `config.json` en avait demandé.

Un détail mérite qu'on s'y arrête : le parent du processus, 597564. Ce n'est pas `runc`, qui a terminé, ni le `bash` du laboratoire. C'est le processus qui fait tourner le laboratoire lui-même, un certain `containerd-shim`. Quand `runc` s'est arrêté, son enfant s'est retrouvé orphelin, et le noyau l'a confié non pas au processus 1, mais à l'ancêtre le plus proche qui s'était déclaré **subreaper**, c'est-à-dire « preneur d'orphelins ». Ce shim est justement là pour ça ; nous y reviendrons plus bas.

Entrez dans le conteneur avec `runc exec`, l'équivalent de `docker exec` :

```bash
runc exec demo sh -c 'hostname; cat /etc/alpine-release; ps; id'
```

```sortie
demo
3.24.2
PID   USER     TIME  COMMAND
    1 root      0:00 sleep 300
    7 root      0:00 sh -c hostname; cat /etc/alpine-release; ps; id
   15 root      0:00 ps
uid=0(root) gid=0(root)
```

Tout y est : le nom `demo`, l'Alpine 3.24.2, `sleep` avec le PID 1 dans son propre namespace. Arrêtez-le, puis supprimez-le :

```bash
runc kill demo KILL
runc list
runc delete demo
runc list
```

```sortie
ID          PID         STATUS      BUNDLE             CREATED                          OWNER
demo        0           stopped     /labo/runc-essai   2026-09-25T14:45:43.040218435Z   root
ID          PID         STATUS      BUNDLE      CREATED     OWNER
```

Entre les deux, le conteneur est `stopped` : son processus est mort, mais `runc` garde son état jusqu'au `delete`. C'est ce qu'on voyait au chapitre 2 avec un conteneur Docker arrêté, qui reste visible dans `docker ps -a` tant qu'on ne l'a pas supprimé.

:::panne[cannot allocate tty if runc will detach without setting console socket]

Ce message apparaît si l'on lance avec `--detach` un bundle dont le `config.json` demande un terminal (`"terminal": true`, la valeur par défaut de `runc spec` et d'`umoci`). En mode détaché, `runc` s'arrête aussitôt le conteneur lancé : il ne peut pas garder le terminal pour lui, et demande donc qu'on lui fournisse une *console socket*, c'est-à-dire un programme qui recevra le terminal à sa place. C'est l'un des rôles du shim de containerd. À la main, le plus simple est de mettre `.process.terminal` à `false`, comme nous l'avons fait, ou de lancer le conteneur au premier plan, sans `--detach`.

:::

## create, puis start

`runc run` enchaîne en réalité deux opérations de la spécification, que l'on peut faire séparément :

```bash
jq '.process.args=["sleep","30"]' config.json > c.json && mv c.json config.json
runc create demo
runc list
ls /run/runc/demo
runc start demo
runc list
runc delete -f demo
```

```sortie
ID          PID         STATUS      BUNDLE             CREATED                          OWNER
demo        630040      created     /labo/runc-essai   2026-09-25T14:51:13.934181692Z   root
exec.fifo
state.json
ID          PID         STATUS      BUNDLE             CREATED                          OWNER
demo        630040      running     /labo/runc-essai   2026-09-25T14:51:13.934181692Z   root
```

Après `create`, le conteneur a déjà un PID : ses namespaces, son cgroup, sa racine existent, mais le programme n'est pas encore lancé. Le processus 630040 est une copie de `runc` qui attend, bloquée sur le tube nommé `exec.fifo`. `start` écrit dans ce tube ; le processus attendant se réveille et se remplace par `sleep` grâce à l'appel `execve`. Le PID ne change donc pas entre `created` et `running`.

Ce découpage n'est pas une coquetterie. Il laisse un moment, entre la création et le démarrage, où tout l'environnement du conteneur existe sans que le programme tourne. Kubernetes et les greffons réseau en profitent : c'est à cet instant qu'on peut brancher une interface réseau dans le namespace du conteneur, avant que l'application ne démarre et ne cherche à se connecter quelque part.

## Ce que runc fait vraiment

Au chapitre 8, `strace` avait montré que `unshare` n'était qu'un appel système du même nom. Faisons la même chose avec `runc`, en remplaçant le programme du conteneur par `true`, qui se termine immédiatement :

```bash
jq '.process.args=["true"]' config.json > c.json && mv c.json config.json
strace -f -o /labo/runc-trace.txt -e trace=clone,clone3,unshare,pivot_root,sethostname,execve runc run demo
grep -E 'CLONE_NEW|pivot_root|sethostname|execve\("/bin/true' /labo/runc-trace.txt | sed 's/^[0-9]* //'
rm /labo/runc-trace.txt
```

```sortie
unshare(CLONE_NEWNS|CLONE_NEWCGROUP|CLONE_NEWUTS|CLONE_NEWIPC|CLONE_NEWPID|CLONE_NEWNET) = 0
pivot_root(".", ".")             = 0
sethostname("demo", 4)           = 0
execve("/bin/true", ["true"], 0xc000022dc0 /* 3 vars */ <unfinished ...>
```

Quatre lignes, et l'on reconnaît tout le chapitre 8 :

- un seul `unshare` crée les six namespaces demandés par le `config.json` ;
- `pivot_root` remplace la racine par le dossier `rootfs`. C'est une version plus sûre de notre `chroot` : `chroot` change seulement le point de départ des chemins du processus, alors que `pivot_root` change la racine de tout le namespace de montage, puis `runc` démonte l'ancienne, si bien qu'il n'existe plus aucun chemin pour remonter vers les fichiers de l'hôte ;
- `sethostname` pose le nom `demo` ;
- `execve` lance enfin le programme demandé.

Entre ces lignes, la trace complète en contient des centaines d'autres : les montages de `/proc` et `/dev`, l'écriture dans les fichiers du cgroup, la réduction des capabilities, le masquage des chemins de `maskedPaths`. `runc` n'a pas de pouvoir magique : il fait, avec soin et dans le bon ordre, ce que nous avons fait à la main.

Le `config.json` montait la racine en lecture seule (`"readonly": true`). Vérifiez-le :

```bash
jq '.process.args=["touch","/essai"]' config.json > c.json && mv c.json config.json
runc run demo; echo code=$?
```

```sortie
touch: /essai: Read-only file system
code=1
```

Docker, lui, laisse la racine modifiable, puisqu'elle est la couche haute d'overlayfs du chapitre 10 ; `docker run --read-only` rétablit ce comportement, et c'est une bonne pratique que le chapitre 12 recommandera.

## Un autre runtime : crun

Puisque la spécification est publique, rien n'empêche d'en écrire une autre implémentation. `crun`, développé chez Red Hat, fait exactement le même travail que `runc`, mais il est écrit en C au lieu de Go[^crun]. Podman l'utilise par défaut sur Fedora et RHEL. Le laboratoire en contient une version :

```bash
crun --version | head -2
```

```sortie
crun version 1.21
commit: 10269840aa07fb7e6b7e1acff6198692d8ff5c88
```

Même bundle, mêmes commandes : `crun run`, `crun list`, `crun delete`. Mesurons la différence en lançant vingt fois le conteneur qui exécute `true`, avec chacun des deux :

```bash
cd /labo/runc-essai
for r in runc crun; do
  debut=$(date +%s%N)
  for i in $(seq 1 20); do $r run demo-$r-$i >/dev/null 2>&1; done
  fin=$(date +%s%N)
  echo "$r : $(( (fin-debut)/20000000 )) ms par conteneur"
done
```

```sortie
runc : 37 ms par conteneur
crun : 10 ms par conteneur
```

Sur la machine du cours, `crun` démarre un conteneur plus de trois fois plus vite. La raison est surtout le langage : un programme Go embarque son environnement d'exécution et démarre plusieurs fils d'exécution, ce qui oblige `runc` à des acrobaties (une partie de son code d'initialisation est d'ailleurs écrite en C) ; un programme C se contente d'enchaîner les appels système. Pour un serveur web qui tourne des semaines, 27 millisecondes ne comptent pas. Pour une plateforme qui lance des milliers de conteneurs éphémères par minute, elles comptent beaucoup.

L'essentiel est ailleurs : le même dossier a été exécuté par deux programmes différents, écrits dans deux langages différents, par deux équipes différentes. C'est exactement ce que la norme OCI promettait.

## La pile de Docker

Remontons maintenant d'un étage. Quand vous tapez `docker run`, `runc` est bien appelé, mais pas directement. Docker l'indique lui-même :

```bash
docker info --format 'runtime par défaut : {{.DefaultRuntime}}'
docker info --format '{{range $k, $v := .Runtimes}}{{$k}} {{end}}'
docker version --format 'containerd {{range .Server.Components}}{{if eq .Name "containerd"}}{{.Version}}{{end}}{{end}}'
```

```sortie
runtime par défaut : runc
io.containerd.runc.v2 runc
containerd v2.2.2
```

Ces trois commandes se lancent sur votre poste, pas dans le laboratoire. Le runtime par défaut est `runc`, et un composant nommé `containerd` apparaît. Depuis Docker 1.11, en 2016, le moteur Docker ne crée plus lui-même ses conteneurs : il a été découpé en plusieurs programmes[^docker-111], chacun avec son rôle.

Suivez la chaîne depuis le laboratoire, qui voit tous les processus de la machine grâce à `--pid=host`. Partez du processus maître de nginx dans `cible` et remontez vers ses ancêtres :

```bash
P=$(pgrep -f 'nginx: master' | head -1)
pstree -sp $P | head -3
ps -o pid,ppid,cmd -C dockerd,containerd
```

```sortie
systemd(1)---containerd-shim(600219)---nginx(600241)-+-nginx(600344)
                                                     |-nginx(600346)
                                                     |-nginx(600348)
    PID    PPID CMD
   3116       1 /usr/bin/containerd
   3558       1 /usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock
```

nginx n'est l'enfant ni de `dockerd`, ni de `containerd`, ni de `runc`. Son parent est un `containerd-shim` (le nom complet, `containerd-shim-runc-v2`, est tronqué à quinze caractères par le noyau), lui-même rattaché directement au processus 1. `dockerd` et `containerd` sont deux services indépendants, lancés par systemd. La ligne de commande du shim dit à quel conteneur il est attaché :

```bash
ps -o args -p 600219
```

```sortie
COMMAND
/usr/bin/containerd-shim-runc-v2 -namespace moby -id 3225c308f308a0a634f79e9362cd9ad5cb8cbd933f23023bd95fe2d3ff01a98f -address /run/containerd/containerd.sock
```

L'identifiant est celui de `cible` (`docker inspect cible --format '{{.Id}}'` le confirme), et `moby` est le nom de l'espace de rangement que Docker utilise dans containerd. Le rôle de chacun est le suivant :

- **`docker`**, le client, ne fait qu'envoyer des requêtes HTTP à `dockerd` par le socket `/var/run/docker.sock` ;
- **`dockerd`** gère tout ce qui fait « Docker » : l'API, la construction d'images, les réseaux, les volumes, les journaux ;
- **`containerd`** gère le cycle de vie des conteneurs et, selon la configuration, le stockage des images. `dockerd` lui parle en gRPC par `/run/containerd/containerd.sock` ;
- **`containerd-shim-runc-v2`**, un par conteneur, reste en place toute la vie du conteneur ;
- **`runc`** crée le conteneur, puis s'en va.

<Figure svg={pileRuntimes} num="11.1" alt="Deux colonnes. À gauche, Docker : docker, puis dockerd par l'API HTTP, puis containerd par gRPC, puis containerd-shim-runc-v2 lancé par containerd, puis runc qui reçoit un bundle OCI, puis nginx. À droite, Kubernetes : kubelet, puis containerd avec son greffon CRI par le CRI en gRPC sur containerd.sock, puis le shim, un par Pod, puis runc, puis les processus pause et nginx. containerd et le shim forment le runtime de haut niveau, runc le runtime de bas niveau.">
La chaîne qui lance un conteneur. <code>containerd</code> et ses shims forment le runtime « de haut niveau », qui gère images et conteneurs ; <code>runc</code> est le runtime « de bas niveau », qui ne sait qu'exécuter un bundle OCI. Docker et Kubernetes partagent tout le bas de la chaîne.
</Figure>

`containerd` a son propre client en ligne de commande, `ctr`, un outil de débogage fourni avec lui. Il n'est pas installé dans le laboratoire, mais celui de la machine est accessible par le namespace de montage du processus 1 :

```bash
nsenter --target 1 --mount ctr namespaces list
nsenter --target 1 --mount ctr --namespace moby containers list
```

```sortie
NAME   LABELS
k8s.io
moby
CONTAINER                                                           IMAGE    RUNTIME
2a10533deef1bb1a806a677f5387cdf03e96964088a7b645d2d5c01d68f173a4    -        io.containerd.runc.v2
3225c308f308a0a634f79e9362cd9ad5cb8cbd933f23023bd95fe2d3ff01a98f    -        io.containerd.runc.v2
```

Chez vous, la liste compte une ligne par conteneur Docker en cours d'exécution ; les deux lignes ci-dessus sont `labo` et `cible`. La colonne `IMAGE` est vide : sur ce poste, Docker range les images lui-même, avec son pilote `overlay2` (chapitre 10), et ne confie à containerd que l'exécution. Le namespace `k8s.io`, lui, est celui qu'utilise Kubernetes ; ce n'est pas un namespace du noyau, seulement une étiquette qui sépare les objets de plusieurs clients d'un même containerd.

Le bundle OCI que containerd a préparé pour `cible` existe bel et bien sur le disque, sous `/run/containerd`. Le laboratoire le lit par `/proc/1/root`, en remplaçant l'identifiant par celui de votre `cible` :

```bash
ID=3225c308f308a0a634f79e9362cd9ad5cb8cbd933f23023bd95fe2d3ff01a98f
cd /proc/1/root/run/containerd/io.containerd.runtime.v2.task/moby/$ID
ls
jq '{args: .process.args, hostname, root, namespaces: [.linux.namespaces[].type], cgroupsPath: .linux.cgroupsPath}' config.json
jq '.process.capabilities.bounding | length' config.json
jq '.linux.seccomp.defaultAction' config.json
```

```sortie
bootstrap.json
config.json
init.pid
log
log.json
options.json
rootfs
runtime
shim-binary-path
work
{
  "args": [
    "/docker-entrypoint.sh",
    "nginx",
    "-g",
    "daemon off;"
  ],
  "hostname": "3225c308f308",
  "root": {
    "path": "/var/lib/docker/overlay2/9fa9538d2390a97c9eccdcace4d19133e68f6a2fc36e5230cfcb39a9eaa305e1/merged"
  },
  "namespaces": [
    "mount",
    "network",
    "uts",
    "pid",
    "ipc",
    "cgroup"
  ],
  "cgroupsPath": "system.slice:docker:3225c308f308a0a634f79e9362cd9ad5cb8cbd933f23023bd95fe2d3ff01a98f"
}
14
"SCMP_ACT_ERRNO"
```

C'est un bundle comme le nôtre, avec un `config.json` écrit par Docker :

- `args` est la commande de l'image, `ENTRYPOINT` suivi de `CMD` (chapitre 4) ;
- le nom de machine est le début de l'identifiant du conteneur, ce que `hostname` affiche dans tout conteneur Docker ;
- la racine est le dossier `merged` du chapitre 10, la vue fusionnée des couches ;
- `cgroupsPath` est écrit dans la syntaxe du pilote systemd, `tranche:préfixe:nom`, que `runc` traduit en `/system.slice/docker-3225c308….scope`, le cgroup que nous avions trouvé au chapitre 9 ;
- 14 capabilities au lieu de 3, et un filtre seccomp dont l'action par défaut est de refuser l'appel (`SCMP_ACT_ERRNO`) : Docker est plus généreux que `runc spec` sur les capabilities, mais ajoute un filtre d'appels système. Le chapitre 12 les détaillera.

`runc` garde aussi l'état de ces conteneurs, dans un dossier choisi par Docker :

```bash
nsenter --target 1 --mount runc --root /run/docker/runtime-runc/moby list | cut -c1-120
```

```sortie
ID                                                                 PID         STATUS      BUNDLE
2a10533deef1bb1a806a677f5387cdf03e96964088a7b645d2d5c01d68f173a4   597584      running     /run/containerd/io.containerd
3225c308f308a0a634f79e9362cd9ad5cb8cbd933f23023bd95fe2d3ff01a98f   600241      running     /run/containerd/io.containerd
```

Le PID 600241 est le nginx maître de `cible`. Le conteneur Docker est donc, au sens le plus littéral, un conteneur `runc` dont le bundle a été écrit par containerd à la demande de `dockerd`. Regardez, mais ne touchez pas : un `runc kill` ou un `runc delete` sur ces conteneurs contournerait Docker et le laisserait dans un état incohérent.

## À quoi sert le shim

Pourquoi intercaler un processus entre containerd et le conteneur ? Parce que `runc` s'en va dès le conteneur créé, et que containerd doit pouvoir redémarrer (pour une mise à jour, par exemple) sans tuer tous les conteneurs de la machine. Il faut donc que quelqu'un d'autre reste auprès de chaque conteneur. C'est le shim, dont la documentation de containerd décrit les responsabilités[^shim] :

- **être le parent** du conteneur. Le shim se déclare *subreaper* : quand `runc` s'arrête, le processus du conteneur lui est rattaché, et c'est lui qui recevra son code de sortie quand il se terminera. Le 137 d'un OOM kill (chapitre 9) remonte jusqu'à `docker ps` par ce chemin ;
- **garder ouverts** l'entrée et les sorties du conteneur, ou son terminal, pour que `docker logs` et `docker attach` fonctionnent même si containerd a redémarré entre-temps ;
- **exposer une API** à containerd, qui lui demande de lancer, d'arrêter ou d'exécuter une commande dans le conteneur ; c'est alors le shim qui appelle `runc`.

Nous avons déjà vu le premier point à l'œuvre : le `sleep` lancé par `runc` depuis le laboratoire avait pour parent le shim du laboratoire, subreaper le plus proche. La démonstration du second point se fait sans risque dans le nœud minikube, qui a son propre containerd, et dont le redémarrage ne touche pas votre poste. Démarrez minikube (chapitre 0.2), lancez un Pod, puis redémarrez containerd dans le nœud :

```bash
minikube start --driver=docker --cpus=2 --memory=4g --kubernetes-version=v1.37.0
kubectl run demo-runtime --image=nginx:1.30-alpine --restart=Never
kubectl wait --for=condition=Ready pod/demo-runtime --timeout=90s
minikube ssh
```

Les commandes suivantes se tapent dans le nœud, où `crictl`, que nous présentons juste après, donne le PID du conteneur :

```bash
I=$(sudo crictl inspect -o go-template --template '{{.info.pid}}' $(sudo crictl ps --name demo-runtime -q))
echo "nginx avant : $I, containerd : $(pidof containerd)"
sudo systemctl restart containerd
sleep 3
echo "nginx après : $(sudo crictl inspect -o go-template --template '{{.info.pid}}' $(sudo crictl ps --name demo-runtime -q)), containerd : $(pidof containerd)"
ps -o pid,ppid,etime,comm -p $I
```

```sortie
nginx avant : 4071, containerd : 3347
nginx après : 4071, containerd : 4336
    PID    PPID     ELAPSED COMMAND
   4071    4022       00:05 nginx
```

containerd a changé de PID : c'est un nouveau processus. nginx, lui, n'a pas bougé, et son parent est toujours le shim 4022. Au redémarrage, containerd a retrouvé ses shims par leurs sockets et repris le fil. Sans shim, le redémarrage de containerd aurait emporté tous les conteneurs du nœud.

## Kubernetes et le CRI

Kubernetes ne parle pas à Docker. Sur chaque nœud, un agent, le **kubelet**, reçoit la liste des Pods à faire tourner et demande à un runtime de les lancer. Pour ne dépendre d'aucun runtime en particulier, Kubernetes a défini en 2016 une interface, le **CRI** (*Container Runtime Interface*) : une API gRPC, avec des appels comme `RunPodSandbox`, `CreateContainer`, `StartContainer` ou `PullImage`[^cri-2016]. Tout runtime qui implémente cette API peut servir de moteur à un nœud.

Docker n'a jamais implémenté le CRI. Pendant des années, le kubelet a donc embarqué un adaptateur, le *dockershim*, qui traduisait les appels CRI en appels à l'API Docker, laquelle les retraduisait pour containerd. Ce détour a été supprimé de Kubernetes en version 1.24, en 2022[^dockershim]. Les images construites avec Docker n'étaient pas concernées : ce sont des images OCI, que tout runtime sait lancer. Aujourd'hui, deux runtimes CRI dominent :

- **containerd**, par son greffon CRI intégré, utilisé par la plupart des distributions, dont minikube ;
- **CRI-O**, un runtime écrit uniquement pour Kubernetes, utilisé notamment par OpenShift[^crio].

Tous deux délèguent l'exécution finale à un runtime OCI, `runc` ou `crun`.

Dans le nœud minikube, le kubelet est configuré pour parler au socket de containerd :

```bash
sudo crictl version
sudo grep -i containerRuntimeEndpoint /var/lib/kubelet/config.yaml
sudo cat /etc/crictl.yaml
```

```sortie
Version:  0.1.0
RuntimeName:  containerd
RuntimeVersion:  v2.3.4
RuntimeApiVersion:  v1
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
runtime-endpoint: unix:///run/containerd/containerd.sock
```

C'est la ligne `Préparation de Kubernetes v1.37.0 sur containerd 2.3.4` du chapitre 0.2 qui trouve ici son explication. `crictl` est un client du CRI, fourni par le projet Kubernetes pour déboguer un nœud : il parle au runtime exactement comme le kubelet. Il distingue les **Pods**, qu'il appelle *sandboxes*, et les **conteneurs** :

```bash
sudo crictl pods
```

```sortie
POD ID              CREATED              STATE               NAME                               NAMESPACE           ATTEMPT             RUNTIME
0cba0d11799b9       About a minute ago   Ready               coredns-559f6c778d-h7h7j           kube-system         0                   (default)
c1098cc2696b8       About a minute ago   Ready               kube-proxy-n9tb4                   kube-system         1                   (default)
a60a9697a93c7       About a minute ago   Ready               kindnet-rq5t5                      kube-system         1                   (default)
f518cb94ad0a2       About a minute ago   Ready               storage-provisioner                kube-system         0                   (default)
45560a7d7e920       About a minute ago   Ready               kube-scheduler-minikube            kube-system         1                   (default)
4b41040245e3d       About a minute ago   Ready               kube-controller-manager-minikube   kube-system         1                   (default)
7cc87e67d6388       About a minute ago   Ready               kube-apiserver-minikube            kube-system         1                   (default)
b8d42b8bccdb4       About a minute ago   Ready               etcd-minikube                      kube-system         1                   (default)
cb6b5257ae531       6 hours ago          NotReady            kindnet-rq5t5                      kube-system         0                   (default)
6fdd32964e497       6 hours ago          NotReady            kube-proxy-n9tb4                   kube-system         0                   (default)
0260e8d17af60       6 hours ago          NotReady            kube-scheduler-minikube            kube-system         0                   (default)
da4117d1c9675       6 hours ago          NotReady            kube-controller-manager-minikube   kube-system         0                   (default)
8105d8597459f       6 hours ago          NotReady            kube-apiserver-minikube            kube-system         0                   (default)
6c40f3ba97342       6 hours ago          NotReady            etcd-minikube                      kube-system         0                   (default)
```

Ce sont les composants de Kubernetes lui-même, qui tournent dans des Pods du namespace `kube-system` ; la partie V les étudiera un par un. Les lignes `NotReady` datent du démarrage précédent du nœud : minikube avait été arrêté, et au redémarrage le kubelet a recréé chaque Pod (`ATTEMPT 1`) sans que les anciens *sandboxes* aient encore été nettoyés. `sudo crictl ps` montre les conteneurs en cours d'exécution, un par Pod ici, avec l'identifiant du Pod auquel chacun appartient.

containerd lui-même est configuré dans `/etc/containerd/config.toml`. Sa configuration effective contient quelques lignes qui éclairent la suite :

```bash
sudo containerd config dump 2>/dev/null | grep -n -E 'SystemdCgroup|sandbox|runtime_type|default_runtime_name|BinaryName'
```

```sortie
28:      sandbox = 'registry.k8s.io/pause:3.10.2'
61:      default_runtime_name = 'runc'
67:          runtime_type = 'io.containerd.runc.v2'
78:          sandboxer = 'podsandbox'
82:            BinaryName = ''
90:            SystemdCgroup = true
```

Le runtime par défaut s'appelle `runc`, il passe par le shim `io.containerd.runc.v2`, et `BinaryName` vide veut dire « le programme `runc` trouvé dans le PATH ». Le remplacer par `crun` suffirait à changer de runtime OCI pour tous les Pods du nœud. `SystemdCgroup = true` fait confier les cgroups à systemd, comme Docker sur votre poste. Et une image nommée `pause` apparaît : elle mérite une section à elle seule.

## Le conteneur pause

Revenez sur le Pod `demo-runtime`, lancé plus haut. `crictl` montre un Pod et un conteneur, mais les processus du nœud racontent autre chose :

```bash
ps -e -o pid,ppid,comm | awk 'NR==1 || /containerd|kubelet|shim|pause|etcd|kube-apiserv|coredns/'
```

```sortie
    PID    PPID COMMAND
    598       1 kubelet
    777       1 containerd-shim
    778       1 containerd-shim
    845       1 containerd-shim
    856       1 containerd-shim
    906     777 pause
    909     778 pause
    924     845 pause
    927     856 pause
   1048     777 kube-apiserver
   1062     778 etcd
   1266       1 containerd-shim
   1298    1266 pause
   ...
   1396       1 containerd-shim
   1425    1396 pause
   1510    1396 coredns
```

Chaque shim a deux enfants : un processus `pause` et le vrai programme du Pod. Un shim par Pod, et non plus par conteneur, et dans chaque Pod un conteneur invisible pour `crictl ps` : le **conteneur pause**. Son programme ne fait presque rien, il dort jusqu'à ce qu'on le tue. Il sert à posséder les namespaces du Pod[^pause].

Quand le kubelet appelle `RunPodSandbox`, containerd crée d'abord ce conteneur, avec ses namespaces réseau, UTS et IPC. Puis, pour chaque conteneur du Pod, `CreateContainer` demande à rejoindre ces namespaces au lieu d'en créer. Comparez les namespaces du `pause` et du `nginx` de `demo-runtime` :

```bash
P=$(sudo crictl pods --name demo-runtime --state ready -q)
S=$(sudo crictl inspectp -o go-template --template '{{.info.pid}}' $P)
C=$(sudo crictl ps --pod $P --state running -q)
I=$(sudo crictl inspect -o go-template --template '{{.info.pid}}' $C)
echo pause=$S nginx=$I
for ns in net uts ipc pid mnt; do echo "$ns : $(sudo readlink /proc/$S/ns/$ns) $(sudo readlink /proc/$I/ns/$ns)"; done
ps -o pid,ppid,comm -p $S,$I
```

```sortie
pause=4047 nginx=4071
net : net:[4026534223] net:[4026534223]
uts : uts:[4026534287] uts:[4026534287]
ipc : ipc:[4026534288] ipc:[4026534288]
pid : pid:[4026534289] pid:[4026534291]
mnt : mnt:[4026534286] mnt:[4026534290]
    PID    PPID COMMAND
   4047    4022 pause
   4071    4022 nginx
```

Les numéros d'inode, que le chapitre 8 nous a appris à lire, sont formels : réseau, nom de machine et IPC sont partagés ; PID et montage sont propres à chacun. Le `config.json` que containerd a écrit pour nginx le dit en toutes lettres. Dans le bundle du conteneur, sous `/run/containerd/io.containerd.runtime.v2.task/k8s.io/`, on lit :

```sortie
"namespaces": [
  {"type": "pid"},
  {"type": "ipc", "path": "/proc/4047/ns/ipc"},
  {"type": "uts", "path": "/proc/4047/ns/uts"},
  {"type": "mount"},
  {"type": "network", "path": "/proc/4047/ns/net"},
  {"type": "cgroup"}
]
```

Un namespace sans `path` est créé ; un namespace avec `path` est rejoint, par un `setns` sur le fichier indiqué, exactement comme `nsenter` au chapitre 8. Le `cgroupsPath` du même fichier, `kubepods-besteffort-pod0cf858a9_….slice:cri-containerd:…`, place le conteneur dans l'arbre de cgroups de Kubernetes, que la partie III détaillera à propos des requêtes et des limites.

<Figure svg={podPause} num="11.2" alt="Un Pod, avec son shim de PID 4022, contient deux colonnes : pause, PID 4047, et nginx, PID 4071. Les namespaces net, uts et ipc de nginx portent les mêmes numéros que ceux de pause, qu'il a rejoints par /proc/4047/ns. Les namespaces pid et mnt sont différents pour chacun.">
Un Pod vu par le runtime : un conteneur <code>pause</code> crée les namespaces réseau, UTS et IPC, et chaque conteneur du Pod les rejoint. Numéros relevés dans le nœud minikube.
</Figure>

Pourquoi un conteneur de plus, au lieu de faire posséder les namespaces par le premier conteneur du Pod ? Parce qu'un namespace disparaît avec son dernier processus. Si nginx plante et que le kubelet le redémarre, le Pod doit garder son adresse IP : le namespace réseau ne doit donc pas appartenir à nginx. Le conteneur `pause`, qui ne fait rien et ne plante jamais, le garde en vie. C'est la définition concrète d'un Pod, que la partie III abordera par l'autre bout : un groupe de conteneurs qui partagent une adresse IP, un nom et un espace IPC.

Une dernière ligne de ce `config.json` a de quoi surprendre : il n'y a pas de section `seccomp`. Par défaut, Kubernetes lance les conteneurs sans le filtre d'appels système que Docker applique à `cible`. Le chapitre 12 y reviendra, avec la façon de le rétablir.

## ctr et crictl

On dispose donc dans le nœud de deux clients en ligne de commande, qui ne voient pas le même monde. `crictl` parle le CRI, ne connaît que les Pods, les conteneurs et les images de Kubernetes, rangés par containerd dans son namespace `k8s.io`. `ctr` parle directement l'API de containerd, voit tous ses namespaces et peut lancer un conteneur sans Pod. Essayez :

```bash
sudo ctr -n cours images pull docker.io/library/alpine:3.24
sudo ctr -n cours run --rm docker.io/library/alpine:3.24 essai sh -c 'echo bonjour depuis ctr; cat /etc/alpine-release'
sudo ctr namespaces list
sudo crictl images | grep alpine || echo 'alpine invisible pour crictl'
```

```sortie
bonjour depuis ctr
3.24.2
NAME   LABELS
cours
k8s.io
moby
alpine invisible pour crictl
```

Un conteneur a tourné dans le nœud, lancé par containerd et `runc`, sans que Kubernetes le sache : ni le kubelet ni `kubectl` ne le verront jamais. L'image, rangée dans le namespace `cours`, n'existe pas pour `crictl`. (Le namespace `moby`, vide, est un reste de l'image de base du nœud, qui contient aussi Docker sans l'utiliser.) Dans un nœud Kubernetes, `crictl` est l'outil de diagnostic à préférer, puisqu'il montre ce que voit le kubelet ; `ctr` sert à inspecter containerd lui-même. Nettoyez le namespace `cours`, qui doit être vide pour être supprimé :

```bash
sudo ctr -n cours images rm --sync docker.io/library/alpine:3.24
sudo ctr -n cours content ls -q | xargs -r sudo ctr -n cours content rm
sudo ctr namespaces rm cours
```

:::podman

Podman n'a ni démon ni containerd : la commande `podman` appelle directement un runtime OCI, `crun` par défaut sur Fedora et RHEL, et place entre les deux un petit moniteur, `conmon`, qui joue le rôle du shim (parent du conteneur, gardien de ses sorties, collecteur de son code de sortie). `podman info --format '{{.Host.OCIRuntime.Name}}'` indique le runtime utilisé. Le reste de la chaîne est identique : un bundle OCI, un `config.json`, les mêmes appels système.

:::

## D'autres runtimes

`runc` et `crun` isolent les conteneurs avec les namespaces et les cgroups d'un noyau partagé. Tous les conteneurs d'une machine parlent au même noyau, et une faille de ce noyau peut permettre d'en sortir. D'autres runtimes OCI font un choix différent :

- **gVisor** (`runsc`), de Google, intercale entre le conteneur et le noyau un noyau écrit en Go qui réimplémente les appels système ; le conteneur ne parle presque plus au vrai noyau[^gvisor] ;
- **Kata Containers** lance chaque Pod dans une petite machine virtuelle, avec son propre noyau, tout en présentant l'interface d'un runtime OCI[^kata].

Les deux s'installent à côté de `runc` dans la configuration de containerd, et Kubernetes laisse choisir le runtime Pod par Pod, grâce à un objet nommé *RuntimeClass*[^runtimeclass]. Ils coûtent un peu de performance contre une isolation plus forte ; on les réserve aux charges qu'on ne maîtrise pas, comme le code envoyé par des clients sur une plateforme partagée.

## Exercices

:::exercice[Exercice 1 : nginx sans Docker]

Au chapitre 10, `skopeo` a copié l'image `nginx:1.30-alpine` dans `/labo/nginx`. Transformez-la en bundle avec `umoci unpack --image /labo/nginx:1.30-alpine /labo/bundle-nginx`, puis lancez-la avec `runc run --detach web`. Faites ce qu'il faut pour qu'elle démarre, puis vérifiez que nginx répond avec `runc exec web curl -s -o /dev/null -w '%{http_code}\n' http://localhost/`. Pourquoi ne peut-on pas l'atteindre depuis le laboratoire ?

:::

<details>
<summary>Corrigé</summary>

Le premier essai échoue avec l'erreur de terminal vue plus haut : `umoci` écrit lui aussi `"terminal": true`. Une fois ce champ corrigé, le conteneur démarre puis s'arrête aussitôt, et ses journaux, affichés dans votre terminal, disent pourquoi :

```sortie
nginx: [emerg] chown("/var/cache/nginx/client_temp", 101) failed (1: Operation not permitted)
```

nginx démarre en root, puis crée ses dossiers de cache et les donne à l'utilisateur `nginx` (UID 101), sous lequel tourneront ses processus de travail. Il lui faut pour cela trois privilèges que le `config.json` d'`umoci`, aussi strict que celui de `runc spec`, ne lui donne pas :

```bash
cd /labo/bundle-nginx
runc delete -f web
jq -c '.process.capabilities.bounding' config.json
jq '.process.capabilities |= with_entries(.value += ["CAP_CHOWN","CAP_SETUID","CAP_SETGID"])' config.json > c.json && mv c.json config.json
runc run --detach web > /labo/web.log 2>&1
runc exec web curl -s -o /dev/null -w '%{http_code}\n' http://localhost/
runc ps web | head -4
```

```sortie
["CAP_AUDIT_WRITE","CAP_KILL","CAP_NET_BIND_SERVICE"]
200
UID          PID    PPID  C STIME TTY          TIME CMD
root      639040  597564  1 14:54 ?        00:00:00 nginx: master process nginx -g daemon off;
101       639062  639040  0 14:54 ?        00:00:00 nginx: worker process
101       639063  639040  0 14:54 ?        00:00:00 nginx: worker process
```

`CAP_CHOWN` permet le `chown`, `CAP_SETUID` et `CAP_SETGID` le passage à l'UID 101. Docker les accorde par défaut, parmi ses 14 capabilities, c'est pourquoi l'image fonctionne sans effort avec `docker run`. Quant au réseau, `runc exec web ip addr` ne montre que l'interface `lo` : `runc` a créé un namespace réseau vide et n'y branche rien. Brancher une paire veth et un pont, comme au chapitre 8, c'est le travail de Docker (au chapitre 6) ou, dans Kubernetes, d'un greffon CNI (partie V). Arrêtez et supprimez : `runc kill web TERM`, `runc delete web`, `rm -rf /labo/bundle-nginx /labo/web.log`.

</details>

:::exercice[Exercice 2 : tuer un shim]

Dans le nœud minikube, lancez un Pod qui redémarre en cas de problème, `kubectl run demo-shim --image=nginx:1.30-alpine --restart=Always`. Trouvez le PID du shim de ce Pod, tuez-le avec `sudo kill -9`, puis observez pendant une vingtaine de secondes les processus, `sudo crictl ps -a --name demo-shim` et `kubectl get pod demo-shim`. Que devient nginx ? Que fait Kubernetes ?

:::

<details>
<summary>Corrigé</summary>

Le PID du shim est le parent du processus nginx :

```bash
C=$(sudo crictl ps --name demo-shim -q)
I=$(sudo crictl inspect -o go-template --template '{{.info.pid}}' $C)
S=$(ps -o ppid= -p $I | tr -d ' ')
echo nginx=$I shim=$S
sudo kill -9 $S; sleep 2
ps -o pid,ppid,stat,comm -p $I
```

```sortie
nginx=5078 shim=5029
    PID    PPID STAT COMMAND
   5078       1 Ss   nginx
```

Deux secondes après, nginx tourne toujours, mais orphelin : son parent est désormais le processus 1 du nœud. Tuer le shim ne tue pas le conteneur. En revanche, containerd a perdu le seul lien qu'il avait avec lui. Il signale au kubelet que le *sandbox* du Pod a disparu, et le kubelet réagit radicalement : il arrête le conteneur restant et reconstruit tout le Pod.

```sortie
CONTAINER           IMAGE               CREATED             STATE               NAME                ATTEMPT             POD ID
f087e7dd516d9       43d9d8c1f8968       21 seconds ago      Running             demo-shim           1                   e5fb0b6d40cf0
74d38e457aed0       43d9d8c1f8968       22 seconds ago      Exited              demo-shim           0                   18c7a03c44b0a
```

`kubectl get events` le raconte en clair : `SandboxChanged: Pod sandbox changed, it will be killed and re-created`, puis `Killing: Stopping container demo-shim`. Le Pod affiche `RESTARTS 1`, avec un nouveau *sandbox*, donc un nouveau conteneur `pause`, de nouveaux namespaces et une nouvelle adresse IP. Leçon : le shim est invisible tant que tout va bien, mais c'est lui qui relie un processus à son conteneur. Supprimez le Pod avec `kubectl delete pod demo-shim`.

</details>

:::exercice[Exercice 3 : un bundle sans root]

Sur votre poste, en tant qu'utilisateur normal et dans un dossier vide, lancez `runc spec --rootless` (le programme `runc` est installé avec Docker). Comparez le `config.json` obtenu à celui de `runc spec` : quels namespaces sont demandés ? Que contient `.linux.uidMappings` ? Pourquoi ces différences ?

:::

<details>
<summary>Corrigé</summary>

```bash
runc spec --rootless
jq -c '{ns: [.linux.namespaces[].type], uid: .linux.uidMappings}' config.json
```

```sortie
{"ns":["pid","ipc","uts","mount","cgroup","user"],"uid":[{"containerID":0,"hostID":1000,"size":1}]}
```

Deux changements. Un namespace `user` apparaît, avec une correspondance qui fait de votre UID (1000 sur la machine du cours) le root du conteneur : c'est le mécanisme du chapitre 8, qui permettait à un utilisateur normal d'obtenir `uid=0` dans `unshare --user --map-root-user`. Et le namespace `network` disparaît : un utilisateur sans privilège ne peut pas créer d'interface veth sur l'hôte, un namespace réseau serait donc vide et inutile, et le conteneur partage le réseau de votre session. D'autres détails suivent la même logique : `/sys` est monté par un simple *bind mount* en lecture seule, puisqu'un utilisateur ne peut pas monter un nouveau `sysfs`, et la section `resources` disparaît, faute de droit sur les cgroups. C'est la base du mode *rootless* de Docker et de Podman, que le chapitre 12 présentera. Lancé en root dans le laboratoire, le même `runc spec --rootless` écrit `"hostID": 0`, puisque votre UID y est 0.

</details>

:::exercice[Exercice 4 : de quel conteneur vient ce processus ?]

`top` ou `ps` vous montrent sur votre poste un processus qui consomme beaucoup de processeur, et vous ne savez pas à quel conteneur il appartient. Donnez deux façons de retrouver le conteneur Docker à partir du seul PID, en vous servant de ce chapitre et du chapitre 9. Essayez-les sur le processus maître de nginx de `cible`.

:::

<details>
<summary>Corrigé</summary>

Première façon, par le shim : on remonte les parents jusqu'au premier `containerd-shim`, dont la ligne de commande porte l'identifiant du conteneur.

```bash
P=$(pgrep -f 'nginx: master' | head -1)
S=$(ps -o ppid= -p $P | tr -d ' ')
ps -o args= -p $S | grep -o -- '-id [0-9a-f]*'
```

```sortie
-id 3225c308f308a0a634f79e9362cd9ad5cb8cbd933f23023bd95fe2d3ff01a98f
```

Si plusieurs nginx tournent sur votre poste, `pgrep` les liste tous et `head -1` ne garde que le premier : vérifiez avec `ps -o args= -p $P` que c'est le bon. Pour un processus plus profond (un worker nginx, par exemple), il faut remonter plusieurs parents ; `pstree -sp $P` montre toute la lignée d'un coup. Seconde façon, par le cgroup, qui est plus directe : `cat /proc/$P/cgroup` affiche `0::/system.slice/docker-3225c308….scope`, et l'identifiant se lit dans le nom. Dans les deux cas, `docker ps --no-trunc | grep 3225c308` donne le nom du conteneur. Dans un nœud Kubernetes, la seconde méthode donne en plus l'UID du Pod, dans le nom de la tranche `kubepods-…-pod<uid>.slice`, et `crictl ps` fait le reste.

</details>

## Nettoyer

Dans le laboratoire, supprimez le bundle d'essai (les conteneurs `runc` ont déjà été supprimés) ; dans le nœud, le Pod ; puis arrêtez minikube si vous n'en avez plus besoin :

```bash
runc list; rm -rf /labo/runc-essai                     # dans le laboratoire
kubectl delete pod demo-runtime demo-shim --ignore-not-found   # sur votre poste
minikube stop
```

Gardez le laboratoire, le volume `labo` et `cible` : le chapitre 12 les utilise pour les capabilities et seccomp.

[^oci-about]: Open Container Initiative, « About the Open Container Initiative ». [opencontainers.org/about/overview](https://opencontainers.org/about/overview/)

[^runtime-spec]: Open Container Initiative, *Runtime Specification*, fichiers `bundle.md` (le bundle), `runtime.md` (les opérations et les états `creating`, `created`, `running`, `stopped`) et `config.md` (le fichier de configuration). [github.com/opencontainers/runtime-spec](https://github.com/opencontainers/runtime-spec)

[^crun]: containers/crun, « A fast and lightweight fully featured OCI runtime and C library for running containers ». [github.com/containers/crun](https://github.com/containers/crun)

[^docker-111]: Docker, « Docker 1.11: The first runtime built on containerd and based on OCI technology », 13 avril 2016. [docker.com/blog/docker-engine-1-11-runc](https://www.docker.com/blog/docker-engine-1-11-runc/)

[^shim]: containerd, « Runtime v2 », documentation des shims : rôle, API et cycle de vie. [github.com/containerd/containerd/blob/main/core/runtime/v2/README.md](https://github.com/containerd/containerd/blob/main/core/runtime/v2/README.md)

[^cri-2016]: Kubernetes Blog, « Introducing Container Runtime Interface (CRI) in Kubernetes », 19 décembre 2016. [kubernetes.io/blog/2016/12/container-runtime-interface-cri-in-kubernetes](https://kubernetes.io/blog/2016/12/container-runtime-interface-cri-in-kubernetes/)

[^dockershim]: Kubernetes Blog, « Updated: Dockershim Removal FAQ », 17 février 2022. [kubernetes.io/blog/2022/02/17/dockershim-faq](https://kubernetes.io/blog/2022/02/17/dockershim-faq/)

[^crio]: CRI-O, « Lightweight Container Runtime for Kubernetes ». [cri-o.io](https://cri-o.io/)

[^pause]: Ian Lewis, « The Almighty Pause Container », 2017. [ianlewis.org/en/almighty-pause-container](https://www.ianlewis.org/en/almighty-pause-container)

[^gvisor]: gVisor, « What is gVisor? ». [gvisor.dev/docs](https://gvisor.dev/docs/)

[^kata]: Kata Containers, « About Kata Containers ». [katacontainers.io](https://katacontainers.io/)

[^runtimeclass]: Kubernetes, « Runtime Class ». [kubernetes.io/docs/concepts/containers/runtime-class](https://kubernetes.io/docs/concepts/containers/runtime-class/)
