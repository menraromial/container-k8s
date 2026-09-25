---
title: La sécurité d'un conteneur
sidebar_label: 12. La sécurité
description: "Ce qui sépare vraiment un conteneur de sa machine : root et ses capabilities, les utilisateurs non root, seccomp, AppArmor, la racine en lecture seule, les user namespaces et le mode rootless ; leur traduction dans Kubernetes ; quelques évasions célèbres et ce qui les aurait arrêtées."
partie: 2
chapitre: '12'
---

import barrieresMount from '@site/src/figures/barrieres-mount.svg';

Le laboratoire des chapitres 8 à 11 était lancé avec `--privileged`, `--pid=host` et `--cgroupns=host`. Au chapitre 8, on avait prévenu que chacune de ces options retirait une protection : depuis ce conteneur, nous avons lu les fichiers de la machine par `/proc/1/root`, créé des cgroups à côté de ceux de Docker et lancé `runc` sur l'hôte. Rien de tout cela n'aurait été possible depuis un conteneur ordinaire. Ce chapitre fait l'inventaire de ce qui, dans un conteneur ordinaire, l'empêche.

Le point de départ est une idée qu'on a vue sous tous les angles : un conteneur est un processus de la machine, qui parle au même noyau que les autres. Il n'y a pas de mur entre lui et l'hôte, seulement des filtres posés par le runtime (chapitre 11) sur ce que ce processus a le droit de voir et de faire. La sécurité d'un conteneur est la somme de ces filtres ; on va les prendre un par un, les voir refuser quelque chose, puis voir comment Kubernetes les règle.

Tout se fait sur votre poste, avec des conteneurs éphémères (`--rm`) : il n'y a rien à nettoyer au fil du chapitre. La partie Kubernetes utilise minikube, et les fichiers de ce chapitre sont dans [l'archive securite](pathname:///kits/securite.tar.gz).

## Root dans le conteneur, root sur la machine

Commençons par la question que tout le monde se pose : le root d'un conteneur est-il le root de la machine ? Créez un dossier vide, donnez-le à un conteneur, et regardez à qui appartient le fichier qu'il y crée :

```bash
mkdir essai-root
docker run --rm -v "$PWD/essai-root:/d" alpine:3.24 sh -c 'touch /d/fichier; id -u'
ls -ln essai-root
```

```sortie
0
total 0
-rw-r--r-- 1 0 0 0 Sep 25 17:04 fichier
```

Le fichier appartient à l'UID 0 de la machine : pour le noyau, le processus du conteneur **est** root, sans nuance. Vous ne pouvez d'ailleurs pas supprimer ce fichier avec votre compte ; faites-le depuis un conteneur, `docker run --rm -v "$PWD/essai-root:/d" alpine:3.24 rm /d/fichier`, puis `rmdir essai-root`.

Si ce root-là ne peut pas tout casser, ce n'est donc pas parce qu'il serait un « faux » root. C'est parce qu'il voit peu de choses (namespaces, chapitre 8) et parce que le runtime lui a retiré la plupart de ses pouvoirs. Il y a deux défenses complémentaires : réduire ces pouvoirs, et ne pas être root du tout.

## Les capabilities

Sous Linux, les pouvoirs de root ne sont pas un bloc. Depuis 1999, ils sont découpés en une quarantaine de **capabilities**, chacune accordant un groupe de privilèges : `CAP_CHOWN` pour changer le propriétaire d'un fichier, `CAP_NET_ADMIN` pour configurer le réseau, `CAP_SYS_ADMIN` pour monter des systèmes de fichiers et une longue liste d'autres opérations[^capabilities]. Un processus root ordinaire les a toutes ; un processus peut en perdre, et ne peut plus les retrouver.

Le noyau affiche celles d'un processus dans `/proc/<pid>/status`, sous forme de masques hexadécimaux :

```bash
docker run --rm alpine:3.24 grep Cap /proc/self/status
```

```sortie
CapInh:	0000000000000000
CapPrm:	00000000a80425fb
CapEff:	00000000a80425fb
CapBnd:	00000000a80425fb
CapAmb:	0000000000000000
```

`CapEff` (*effective*) est l'ensemble réellement utilisé pour les vérifications ; `CapBnd` (*bounding*) est le plafond, ce que le processus et ses descendants ne pourront jamais dépasser. `capsh`, présent dans l'image du laboratoire, traduit le masque en noms :

```bash
docker run --rm labo:1.0 capsh --decode=00000000a80425fb
```

```sortie
0x00000000a80425fb=cap_chown,cap_dac_override,cap_fowner,cap_fsetid,cap_kill,cap_setgid,cap_setuid,cap_setpcap,cap_net_bind_service,cap_net_raw,cap_sys_chroot,cap_mknod,cap_audit_write,cap_setfcap
```

Ce sont les 14 capabilities que nous avions comptées au chapitre 11 dans le `config.json` de `cible`, la liste par défaut de Docker[^docker-caps]. Elles permettent ce qu'un programme installé dans une image fait couramment : changer le propriétaire d'un fichier, passer d'un utilisateur à un autre, écouter sur le port 80. Il manque tout ce qui touche à la machine : `CAP_SYS_ADMIN`, `CAP_NET_ADMIN`, `CAP_SYS_MODULE` (charger un module du noyau), `CAP_SYS_TIME` (changer l'heure), `CAP_SYS_PTRACE` (espionner un autre processus). Comparez avec les deux extrêmes :

```bash
docker run --rm --privileged alpine:3.24 grep CapEff /proc/self/status
docker run --rm alpine:3.24 grep CapEff /proc/self/status
docker run --rm --cap-drop ALL alpine:3.24 grep CapEff /proc/self/status
```

```sortie
CapEff:	000001ffffffffff
CapEff:	00000000a80425fb
CapEff:	0000000000000000
```

`--privileged` donne tout (41 bits à 1), `--cap-drop ALL` ne laisse rien. Entre les deux, `--cap-add` et `--cap-drop` ajustent la liste. Voyons une capability à l'œuvre. Créer une interface réseau demande `CAP_NET_ADMIN`, absente par défaut :

```bash
docker run --rm labo:1.0 ip link add essai0 type dummy; echo code=$?
docker run --rm --cap-add NET_ADMIN labo:1.0 sh -c 'ip link add essai0 type dummy && ip -br link show essai0'
```

```sortie
RTNETLINK answers: Operation not permitted
code=2
essai0           DOWN           ce:15:97:53:a9:c9 <BROADCAST,NOARP>
```

Le conteneur est root dans les deux cas. La différence tient à un seul bit. Et dans l'autre sens, un root privé de toutes ses capabilities ne peut plus grand-chose :

```bash
docker run --rm --cap-drop ALL alpine:3.24 sh -c 'id; chown nobody /etc/hostname; echo code=$?; ping -c1 -W1 127.0.0.1 >/dev/null; echo ping=$?'
```

```sortie
uid=0(root) gid=0(root) groups=0(root),1(bin),2(daemon),3(sys),4(adm),6(disk),10(wheel),11(floppy),20(dialout),26(tape),27(video)
chown: /etc/hostname: Operation not permitted
code=1
ping=0
```

`id` affiche toujours `uid=0`, mais `chown` échoue. `ping`, lui, fonctionne encore : historiquement, il lui fallait `CAP_NET_RAW`, mais Docker règle dans chaque conteneur le paramètre `net.ipv4.ping_group_range` à `0 2147483647`, qui autorise tout utilisateur à envoyer des pings par une socket ICMP ordinaire. `sysctl net.ipv4.ping_group_range` dans un conteneur le montre.

La bonne pratique découle de tout cela : partir de `--cap-drop ALL`, puis rajouter une à une les capabilities dont le programme a vraiment besoin. L'exercice 1 le fait pour nginx.

## Ne pas être root du tout

Plus simple encore que de réduire les pouvoirs de root : ne pas l'être. L'option `--user` lance le programme sous un autre UID, et l'instruction `USER` d'un Dockerfile en fait le réglage par défaut de l'image (chapitre 4).

```bash
docker run --rm --user 1000:1000 alpine:3.24 sh -c 'id; touch /etc/essai; echo code=$?'
docker run --rm --user 1000 alpine:3.24 grep CapEff /proc/self/status
```

```sortie
uid=1000 gid=1000 groups=1000
touch: /etc/essai: Permission denied
code=1
CapEff:	0000000000000000
```

Un processus non root n'a aucune capability effective, quelle que soit la liste de Docker : le noyau les efface quand un processus quitte l'UID 0. Il est soumis aux droits ordinaires des fichiers, et `/etc` appartient à root. Si ce processus est compromis, l'attaquant hérite d'un utilisateur quelconque, pas de root.

Beaucoup d'images, pourtant, tournent en root. `docker image inspect nginx:1.30-alpine --format 'User={{.Config.User}}'` affiche `User=` : pas d'utilisateur déclaré, donc root. nginx démarre en root pour se préparer, puis confie le travail à des processus qui tournent sous l'utilisateur `nginx` (UID 101), comme on l'a vu au chapitre 11. Faire tourner nginx entièrement sans root est possible, mais demande quelques aménagements : c'est l'exercice 3.

### no-new-privileges

Un programme non root peut redevenir root d'une façon légitime : en exécutant un fichier marqué **setuid**, comme `passwd` ou `sudo`, qui s'exécute avec les droits de son propriétaire. Pour le montrer sans rien casser, fabriquons une copie setuid de `id` dans un conteneur jetable, puis exécutons-la sous l'UID 1000 :

```bash
docker run --rm labo:1.0 sh -c 'cp /usr/bin/id /usr/local/bin/id-suid && chmod u+s /usr/local/bin/id-suid && setpriv --reuid 1000 --regid 1000 --clear-groups /usr/local/bin/id-suid'
```

```sortie
uid=1000(ubuntu) gid=1000(ubuntu) euid=0(root) groups=1000(ubuntu)
```

`euid=0` : l'UID effectif, celui qui compte pour les vérifications, est redevenu root. Dans une image, un binaire setuid oublié ou vulnérable est donc un chemin vers root. L'option `--security-opt no-new-privileges` pose sur le conteneur un drapeau du noyau qui interdit à tout jamais ce genre de promotion :

```bash
docker run --rm --security-opt no-new-privileges labo:1.0 sh -c 'cp /usr/bin/id /usr/local/bin/id-suid && chmod u+s /usr/local/bin/id-suid && grep NoNewPrivs /proc/self/status && setpriv --reuid 1000 --regid 1000 --clear-groups /usr/local/bin/id-suid'
```

```sortie
NoNewPrivs:	1
uid=1000(ubuntu) gid=1000(ubuntu) groups=1000(ubuntu)
```

Le bit setuid est ignoré, `euid` n'apparaît plus. Le drapeau est hérité par tous les descendants et ne peut pas être retiré. Kubernetes l'appelle `allowPrivilegeEscalation: false`.

## seccomp : filtrer les appels système

Les capabilities disent ce qu'un processus a le droit de faire ; **seccomp** (*secure computing*) décide quels appels système il a le droit de passer. Le noyau Linux en compte plus de 300, et un programme ordinaire n'en utilise qu'une partie. Un filtre seccomp est un petit programme attaché au processus, que le noyau consulte à l'entrée de chaque appel système, et qui peut l'autoriser, le refuser avec un code d'erreur, ou tuer le processus.

Docker attache par défaut un filtre à chaque conteneur :

```bash
docker run --rm alpine:3.24 grep -E 'Seccomp|NoNewPrivs' /proc/self/status
docker run --rm --security-opt seccomp=unconfined alpine:3.24 grep -E '^Seccomp:' /proc/self/status
```

```sortie
NoNewPrivs:	0
Seccomp:	2
Seccomp_filters:	1
Seccomp:	0
```

`Seccomp: 2` signifie « mode filtre » ; `0`, aucun filtre. Le profil par défaut de Docker est une liste d'autorisations : l'action par défaut est de refuser (`SCMP_ACT_ERRNO`, lu au chapitre 11 dans le `config.json` de `cible`), puis viennent les appels autorisés. D'après la documentation de Docker, il bloque ainsi une quarantaine d'appels, rarement utiles à une application et souvent utiles à une attaque : charger un module du noyau, redémarrer la machine, changer l'horloge, manipuler les clés du noyau[^docker-seccomp].

Certains appels sont autorisés sous condition. C'est le cas d'`unshare`, que nous connaissons bien : le profil de Docker ne le laisse passer, pour créer des namespaces, que si le conteneur possède `CAP_SYS_ADMIN`. Or créer un user namespace ne demande normalement aucun privilège, et nous l'avons fait au chapitre 8 avec un simple compte utilisateur :

```bash
docker run --rm alpine:3.24 unshare -U -r id; echo code=$?
docker run --rm --security-opt seccomp=unconfined alpine:3.24 unshare -U -r id; echo code=$?
```

```sortie
unshare: unshare(0x10000000): Operation not permitted
code=1
uid=0(root) gid=0(root) groups=0(root),65534(nobody),65534(nobody),65534(nobody),65534(nobody),65534(nobody),65534(nobody),65534(nobody),65534(nobody),65534(nobody),65534(nobody)
code=0
```

`0x10000000` est `CLONE_NEWUSER`. Sans le filtre, l'appel réussit. Pourquoi l'interdire ? Parce que dans un user namespace, le processus devient root de ce namespace, avec toutes les capabilities, et accède ainsi à des parties du noyau normalement réservées à root. Ces parties ont connu des failles, et la section sur les évasions célèbres montrera que ce blocage a suffi, en 2022, à protéger les conteneurs Docker d'une faille du noyau.

On peut écrire ses propres profils. En voici un, dans le kit, qui autorise tout sauf la création de dossiers :

```json title="sans-mkdir.json"
{
  "defaultAction": "SCMP_ACT_ALLOW",
  "syscalls": [
    {
      "names": ["mkdir", "mkdirat"],
      "action": "SCMP_ACT_ERRNO"
    }
  ]
}
```

```bash
docker run --rm --security-opt seccomp=sans-mkdir.json alpine:3.24 sh -c 'mkdir /essai; echo code=$?; touch /essai.txt && echo touch ok'
```

```sortie
mkdir: can't create directory '/essai': Operation not permitted
code=1
touch ok
```

Le processus est root, avec ses 14 capabilities, et ne peut pourtant pas créer un dossier : le noyau refuse l'appel avant même de regarder qui le fait. Il faut nommer les deux appels. Sur le poste du cours, une machine x86-64, le `mkdir` de BusyBox utilise l'ancien appel `mkdir`, et un profil qui n'interdirait que `mkdirat` le laisserait passer (essayez) ; mais d'autres programmes utilisent `mkdirat`, et sur les machines ARM64 l'ancien appel n'existe même pas. Oublier une variante est l'erreur classique des profils écrits à la main. En pratique, on ne part pas d'une page blanche : on part du profil de Docker, publié dans son dépôt, et on le resserre.

## AppArmor : ce que le programme peut toucher

Troisième mécanisme, les **modules de sécurité Linux** (LSM), qui ajoutent au noyau des règles d'accès obligatoires, que même root ne peut pas contourner. Deux se partagent les distributions : **AppArmor** sur Ubuntu, Debian et SUSE, **SELinux** sur Fedora, RHEL et leurs dérivées. Le poste du cours est sous Ubuntu :

```bash
docker run --rm alpine:3.24 cat /proc/self/attr/current
docker info --format '{{json .SecurityOptions}}'
```

```sortie
docker-default (enforce)
["name=apparmor","name=seccomp,profile=builtin","name=cgroupns"]
```

Chaque conteneur est confiné par le profil AppArmor `docker-default`, en mode `enforce` : ses règles sont appliquées, pas seulement journalisées[^docker-apparmor]. Ce profil interdit notamment tout montage de système de fichiers et l'écriture dans des fichiers sensibles de `/proc` et `/sys`. Pour le voir à l'œuvre, donnons au conteneur la capability qui permet de monter, et essayons :

```bash
docker run --rm --cap-add SYS_ADMIN alpine:3.24 mount -t tmpfs none /mnt; echo code=$?
docker run --rm --cap-add SYS_ADMIN --security-opt apparmor=unconfined alpine:3.24 sh -c 'mount -t tmpfs none /mnt && df -h /mnt | tail -1'
```

```sortie
mount: mounting none on /mnt failed: Permission denied
code=255
none                      7.5G         0      7.5G   0% /mnt
```

Avec `CAP_SYS_ADMIN`, le filtre seccomp de Docker laisse passer `mount`, la capability est là, et pourtant le montage est refusé : c'est AppArmor. Il faut lever aussi le profil pour que le montage réussisse. SELinux, sur les distributions qui l'utilisent, joue le même rôle avec un autre modèle, fondé sur des étiquettes posées sur les processus et les fichiers ; c'est lui qui explique l'option `:Z` des volumes Podman, qui ré-étiquette le dossier pour que le conteneur ait le droit d'y écrire.

## Trois barrières pour un seul appel

L'exemple du montage permet une expérience qui résume la section. Essayons le même `mount` en levant les barrières une par une :

```bash
for o in '' '--security-opt seccomp=unconfined' '--security-opt seccomp=unconfined --security-opt apparmor=unconfined' '--cap-add SYS_ADMIN' '--cap-add SYS_ADMIN --security-opt apparmor=unconfined'; do
  echo "[$o]"; docker run --rm $o alpine:3.24 sh -c 'mount -t tmpfs none /mnt 2>&1; echo code=$?'
done
```

```sortie
[]
mount: permission denied (are you root?)
code=1
[--security-opt seccomp=unconfined]
mount: mounting none on /mnt failed: Permission denied
code=255
[--security-opt seccomp=unconfined --security-opt apparmor=unconfined]
mount: permission denied (are you root?)
code=1
[--cap-add SYS_ADMIN]
mount: mounting none on /mnt failed: Permission denied
code=255
[--cap-add SYS_ADMIN --security-opt apparmor=unconfined]
code=0
```

Les deux messages d'erreur trahissent deux codes différents : « are you root? » est la traduction par BusyBox de l'erreur `EPERM`, « Permission denied » celle d'`EACCES`, qu'AppArmor renvoie. Par défaut, c'est seccomp qui arrête l'appel. Sans seccomp, c'est AppArmor. Sans seccomp ni AppArmor, c'est l'absence de capability. Il faut lever les trois pour que l'appel passe (`--cap-add SYS_ADMIN` lève à la fois la capability et la condition du filtre seccomp).

<Figure svg={barrieresMount} num="12.1" alt="Un processus du conteneur appelle mount. Son appel traverse trois barrières dans l'ordre : le filtre seccomp à l'entrée de l'appel système, qui refuse avec EPERM ; le profil AppArmor docker-default, qui refuse avec EACCES ; la vérification de la capability CAP_SYS_ADMIN, qui refuse avec EPERM. Au-dessus de chaque barrière, l'option de Docker qui la lève. Si les trois sont levées, le noyau monte le tmpfs.">
Le chemin de l'appel <code>mount</code> dans un conteneur Docker, relevé sur le poste du cours. Chacune des trois barrières suffit à elle seule à refuser l'appel.
</Figure>

C'est ce qu'on appelle la **défense en profondeur** : aucune barrière n'est parfaite, mais une faille dans l'une ne suffit pas, puisque les autres tiennent encore. Et c'est pour la même raison que `--privileged` est si dangereux : il les lève toutes d'un coup.

## La racine en lecture seule

Un attaquant qui prend pied dans un conteneur cherche d'abord à y déposer quelque chose : un outil, un script, une bibliothèque modifiée. `--read-only` monte la racine du conteneur en lecture seule, comme le `config.json` de `runc spec` au chapitre 11 :

```bash
docker run --rm --read-only alpine:3.24 touch /essai; echo code=$?
docker run --rm --read-only --tmpfs /tmp alpine:3.24 sh -c 'touch /tmp/essai && echo /tmp ok'
```

```sortie
touch: /essai: Read-only file system
code=1
/tmp ok
```

La plupart des programmes ont besoin d'écrire quelque part (un fichier temporaire, un PID, un cache) : on leur donne alors un `tmpfs` ou un volume, uniquement là où c'est nécessaire. Le bénéfice dépasse la sécurité : un conteneur dont la racine est en lecture seule ne peut pas accumuler d'état caché dans sa couche haute (chapitre 10), et se comporte donc de la même façon à chaque redémarrage.

## --privileged et les autres portes ouvertes

Comparez maintenant un conteneur ordinaire et un conteneur `--privileged` :

```bash
docker run --rm alpine:3.24 sh -c 'ls /dev | wc -l; grep Seccomp: /proc/self/status; cat /proc/self/attr/current'
docker run --rm --privileged alpine:3.24 sh -c 'ls /dev | wc -l; grep Seccomp: /proc/self/status; cat /proc/self/attr/current'
```

```sortie
15
Seccomp:	2
docker-default (enforce)
317
Seccomp:	0
unconfined
```

En plus de toutes les capabilities, le conteneur privilégié n'a plus de filtre seccomp, plus de profil AppArmor, et voit 317 fichiers dans `/dev` au lieu de 15 : les disques, les terminaux, les périphériques de la machine. Il reste dans ses namespaces, mais avec les pouvoirs complets de root et l'accès direct au matériel, il n'y a plus grand-chose entre lui et l'hôte. Il faut considérer un conteneur `--privileged` comme un accès root à la machine. Il a des usages légitimes (notre laboratoire, un outil d'administration du nœud, Docker dans Docker), mais il ne doit jamais servir à « faire marcher » une application qui se heurte à une permission.

D'autres réglages courants sont des portes tout aussi larges, parce qu'ils donnent au conteneur un accès à l'hôte que les namespaces lui retiraient :

- **monter le socket de Docker** (`-v /var/run/docker.sock:/var/run/docker.sock`). Qui peut parler à `dockerd` peut lui demander de lancer un conteneur privilégié avec le disque de la machine monté dedans : c'est un accès root à l'hôte. C'est aussi pourquoi appartenir au groupe `docker` revient à être root, comme la documentation de Docker le dit en toutes lettres[^docker-surface] ;
- **monter la racine de l'hôte** ou un dossier système (`-v /:/host`, et dans Kubernetes un volume `hostPath`) ;
- **partager les namespaces de l'hôte** (`--pid=host`, `--network=host`), qui rend visibles les processus ou les interfaces de la machine, comme dans notre laboratoire.

## User namespaces et mode rootless

Toutes les défenses vues jusqu'ici partent du même constat : le root du conteneur est le root de la machine, et on le bride. Les **user namespaces** (chapitre 8) attaquent le problème à la racine : le root du conteneur est un utilisateur ordinaire de la machine. Même s'il sortait de son conteneur, il n'aurait que les droits de cet utilisateur.

C'est le principe du mode **rootless**, dans lequel le moteur de conteneurs lui-même tourne sans root. Docker le propose, au prix d'une installation séparée[^docker-rootless]. Podman, s'il est installé sur votre poste, fonctionne ainsi par défaut, et l'illustre en trois commandes :

```bash
podman run --rm docker.io/library/alpine:3.24 sh -c 'id; cat /proc/self/uid_map'
mkdir essai-rootless
podman run --rm -v "$PWD/essai-rootless:/d:Z" docker.io/library/alpine:3.24 sh -c 'touch /d/fichier; id -u'
ls -ln essai-rootless
```

```sortie
uid=0(root) gid=0(root) groups=0(root),1(bin),2(daemon),3(sys),4(adm),6(disk),10(wheel),11(floppy),20(dialout),26(tape),27(video)
         0       1000          1
         1     100000      65536
0
total 0
-rw-r--r-- 1 1000 1000 0 Sep 25 17:11 fichier
```

Dans le conteneur, `id` affiche root. Mais la table de correspondance dit que l'UID 0 du conteneur est l'UID 1000 de la machine (votre compte), et que les UID 1 à 65536 sont empruntés à une plage réservée à votre compte dans `/etc/subuid` (ici à partir de 100000). Le fichier créé par « root » appartient à l'UID 1000 : comparez avec le même essai sous Docker, au début du chapitre. Et le processus, vu de la machine, est bien à vous :

```bash
podman run -d --name rootless docker.io/library/alpine:3.24 sleep 60
ps -o pid,user,uid,comm -p $(podman inspect rootless --format '{{.State.Pid}}')
podman rm -f -t 0 rootless
```

```sortie
    PID USER       UID COMMAND
 670137 romial    1000 sleep
```

Supprimez le dossier d'essai avec `rm -r essai-rootless`, sans difficulté cette fois, puisque le fichier vous appartient. Le mode rootless a des limites, qui viennent toutes de ce qu'un utilisateur ordinaire n'a pas le droit de faire : pas de port sous 1024 sans réglage, un réseau plus lent car simulé en espace utilisateur, certains pilotes de stockage indisponibles. Mais il ferme une classe entière d'évasions.

Kubernetes propose la même idée Pod par Pod, avec le champ `hostUsers: false` : le kubelet demande au runtime de placer le Pod dans un user namespace, avec une plage d'UID propre à ce Pod[^k8s-userns]. Le fichier `pod-userns.yaml` du kit l'essaie :

:::panne[error mounting "sysfs" to rootfs at "/sys": ... operation not permitted]

Dans minikube, ce Pod reste bloqué en `ContainerCreating`, et `kubectl get events` affiche `FailedCreatePodSandBox` avec ce message, renvoyé par `runc`. La cause n'est pas le Pod, mais le nœud : avec le pilote `docker`, le nœud minikube est lui-même un conteneur, dont le `/sys` est monté avec des restrictions. Depuis un user namespace imbriqué dans ce conteneur, le noyau refuse de monter un nouveau `sysfs`. Les user namespaces des Pods demandent un nœud qui soit une vraie machine, virtuelle ou physique, ainsi qu'un noyau et un système de fichiers récents ; la documentation de Kubernetes en donne la liste. Supprimez le Pod avec `kubectl delete pod userns`.

:::

## Dans Kubernetes : le securityContext

Tous ces réglages existent dans Kubernetes, rassemblés dans le champ `securityContext` d'un Pod ou d'un conteneur. Mais leurs valeurs par défaut ne sont pas celles de Docker. Démarrez minikube, lancez le Pod le plus simple possible, et regardez :

```yaml title="pod-defaut.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: defaut
spec:
  containers:
  - name: alpine
    image: alpine:3.24
    command: ["sleep", "3600"]
```

```bash
kubectl apply -f pod-defaut.yaml
kubectl wait --for=condition=Ready pod/defaut --timeout=90s
kubectl exec defaut -- sh -c 'id; grep -E "CapEff|NoNewPrivs|Seccomp:" /proc/1/status; touch /essai && echo écriture ok'
```

```sortie
uid=0(root) gid=0(root) groups=0(root),1(bin),2(daemon),3(sys),4(adm),6(disk),10(wheel),11(floppy),20(dialout),26(tape),27(video)
CapEff:	00000000a80425fb
NoNewPrivs:	0
Seccomp:	0
écriture ok
```

Root, les mêmes 14 capabilities que Docker, une racine modifiable, et `Seccomp: 0` : **aucun filtre seccomp**. C'est ce que le `config.json` du chapitre 11 laissait deviner. Kubernetes lance les conteneurs sans filtre (`Unconfined`) tant qu'on ne lui demande rien d'autre, par compatibilité avec ses premières versions ; le kubelet peut être réglé pour appliquer le profil du runtime par défaut (`seccompDefault`), mais ce n'est pas le cas de minikube[^k8s-seccomp]. Sur ce point précis, un Pod par défaut est moins protégé qu'un conteneur Docker par défaut.

Voici le même Pod, durci avec tout ce que ce chapitre a présenté :

```yaml title="pod-durci.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: durci
spec:
  securityContext:              # pour tout le Pod
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: alpine
    image: alpine:3.24
    command: ["sleep", "3600"]
    securityContext:            # pour ce conteneur
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
```

Chaque ligne a son équivalent Docker : `runAsUser` et `runAsGroup` pour `--user`, `seccompProfile: RuntimeDefault` pour le profil par défaut du runtime (celui de containerd, très proche de celui de Docker), `allowPrivilegeEscalation: false` pour `no-new-privileges`, `readOnlyRootFilesystem` pour `--read-only`, `capabilities.drop` pour `--cap-drop`. `runAsNonRoot` n'a pas d'équivalent : c'est une vérification, qui refuse de démarrer le conteneur s'il devait tourner en root.

```bash
kubectl apply -f pod-durci.yaml
kubectl wait --for=condition=Ready pod/durci --timeout=90s
kubectl exec durci -- sh -c 'id; grep -E "CapEff|NoNewPrivs|Seccomp:" /proc/1/status; touch /essai; echo code=$?'
```

```sortie
uid=1000 gid=1000 groups=1000
CapEff:	0000000000000000
NoNewPrivs:	1
Seccomp:	2
touch: /essai: Read-only file system
code=1
```

Toutes les protections sont en place. Ce Pod respecte le niveau **restricted** des *Pod Security Standards*, les trois niveaux de sécurité (privileged, baseline, restricted) que Kubernetes définit et peut imposer à tout un namespace[^pss] ; la partie VI y reviendra.

`runAsNonRoot` montre son utilité dès qu'on l'applique à une image qui tourne en root. Le fichier `pod-nginx-nonroot.yaml` du kit le fait avec nginx :

```bash
kubectl apply -f pod-nginx-nonroot.yaml
kubectl get pod nginx-nonroot
kubectl get events --field-selector involvedObject.name=nginx-nonroot | grep -i warn
```

```sortie
NAME            READY   STATUS                       RESTARTS   AGE
nginx-nonroot   0/1     CreateContainerConfigError   0          15s
2s          Warning   Failed      pod/nginx-nonroot   Error: container has runAsNonRoot and image will run as root (pod: "nginx-nonroot_default(e6eefa14-3797-41dc-aaa5-ad1bdbd10db3)", container: nginx)
```

Le kubelet a lu l'image, vu qu'elle ne déclare pas d'utilisateur, et refusé de la lancer. C'est exactement le but : l'erreur arrive au déploiement, pas après une compromission. L'exercice 4 rend ce Pod fonctionnel.

## Des évasions célèbres

Une **évasion** (*container escape*) est une faille qui permet à un processus d'agir hors de son conteneur, en général avec les droits de root sur la machine. Il y en a eu, et il y en aura d'autres. Leur intérêt, pour nous, n'est pas la technique d'attaque, que les avis de sécurité décrivent pour qui veut l'approfondir, mais leur cause et ce qui les aurait arrêtées. On y retrouve toutes les barrières de ce chapitre.

**runc, CVE-2019-5736.** Une faille de `runc` lui-même, publiée en février 2019 : un conteneur malveillant pouvait, au démarrage d'une image piégée ou au moment où l'on exécutait une commande dedans (`docker exec`), remplacer le programme `runc` de la machine par le sien, et donc faire exécuter son code en root sur l'hôte à la prochaine utilisation[^cve-2019-5736]. La correction a consisté à faire exécuter par `runc` une copie de lui-même, inaccessible au conteneur. Ce qui aurait arrêté l'attaque avant correction : un conteneur non root, ou un user namespace, puisque le root du conteneur n'avait alors pas le droit d'écrire dans ce fichier appartenant au root de l'hôte ; SELinux en mode `enforce` la bloquait aussi.

**Noyau, CVE-2022-0185.** Un débordement de mémoire dans le code du noyau qui analyse les options de montage, publié en janvier 2022. Pour l'atteindre, il fallait `CAP_SYS_ADMIN`, qu'un processus peut obtenir dans un user namespace créé par lui-même[^cve-2022-0185]. Dans un conteneur Docker par défaut, le filtre seccomp interdisait justement cette création (l'expérience `unshare -U` de ce chapitre) : l'attaque échouait. Dans un Pod Kubernetes sans profil seccomp, elle passait. C'est l'argument le plus concret pour `seccompProfile: RuntimeDefault`.

**cgroups v1, CVE-2022-0492.** Un contrôle de droits manquant dans les cgroups v1, publié en février 2022 : sous certaines conditions, un processus pouvait faire exécuter un programme par le noyau, hors de tout conteneur, grâce à un mécanisme de notification propre aux cgroups v1[^cve-2022-0492]. L'analyse publiée par Palo Alto Networks montre qu'il suffisait d'une seule des protections par défaut, AppArmor, SELinux ou le filtre seccomp de Docker, pour la bloquer ; et les cgroups v2 (chapitre 9) n'ont pas ce mécanisme.

**runc, CVE-2024-21626 (« Leaky Vessels »).** Publiée en janvier 2024 : `runc` laissait ouvert, au moment de lancer le conteneur, un descripteur de fichier qui pointait vers le système de fichiers de l'hôte. Une image dont le dossier de travail (`WORKDIR`) désignait ce descripteur donnait au conteneur un accès aux fichiers de la machine[^cve-2024-21626]. La correction est `runc` 1.1.12. La leçon est double : mettre à jour le runtime, et ne lancer que des images dont on connaît la provenance, sujet du chapitre 14.

Ces quatre cas ont un point commun : aucune ne franchissait toutes les barrières par défaut à la fois. Deux étaient des failles du runtime ou du noyau, que seules les mises à jour corrigent vraiment ; mais chaque fois, un réglage de ce chapitre (non root, user namespace, seccomp, AppArmor) aurait suffi à désamorcer l'attaque. Et le noyau partagé reste la limite fondamentale du conteneur : quand la faille est dans le noyau et qu'aucune barrière ne la couvre, seule une isolation plus forte, comme gVisor ou Kata Containers (chapitre 11), change la donne.

## Exercices

:::exercice[Exercice 1 : les capabilities minimales de nginx]

Lancez `nginx:1.30-alpine` avec `--cap-drop ALL`. Pourquoi ne démarre-t-il pas ? Trouvez la plus petite liste de capabilities à rajouter avec `--cap-add` pour qu'il réponde `200` à `curl http://localhost/` exécuté dans le conteneur. `CAP_NET_BIND_SERVICE` est-elle nécessaire pour écouter sur le port 80 ?

:::

<details>
<summary>Corrigé</summary>

```bash
docker run -d --name x12 --cap-drop ALL nginx:1.30-alpine
docker logs x12 2>&1 | grep emerg
docker rm -f x12
```

```sortie
nginx: [emerg] chown("/var/cache/nginx/client_temp", 101) failed (1: Operation not permitted)
```

C'est la même erreur qu'avec `runc` à l'exercice 1 du chapitre 11. nginx crée ses dossiers de cache et les donne à l'utilisateur `nginx` (`CAP_CHOWN`), puis ses processus de travail passent sous cet utilisateur (`CAP_SETUID`, `CAP_SETGID`). Avec ces trois-là, il fonctionne :

```bash
docker run -d --name x12 --cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID nginx:1.30-alpine
docker exec x12 curl -s -o /dev/null -w 'http %{http_code}\n' http://localhost/
docker rm -f x12
```

```sortie
http 200
```

`CAP_NET_BIND_SERVICE` n'est pas nécessaire : Docker règle dans chaque conteneur `net.ipv4.ip_unprivileged_port_start` à `0` (`docker run --rm alpine:3.24 sysctl net.ipv4.ip_unprivileged_port_start` le montre), si bien que tous les ports sont « non privilégiés ». Trois capabilities sur quatorze : le conteneur a perdu, entre autres, `CAP_DAC_OVERRIDE`, qui permettait à root de lire et d'écrire n'importe quel fichier sans tenir compte de ses droits, et `CAP_NET_RAW`.

</details>

:::exercice[Exercice 2 : un profil seccomp contre chmod]

Écrivez un profil seccomp qui interdit de changer les droits d'un fichier, et vérifiez-le avec `chmod 600 /etc/hostname`. Quels appels système faut-il nommer ? Comment le vérifier sans connaître par cœur les appels système ?

:::

<details>
<summary>Corrigé</summary>

```json title="sans-chmod.json"
{
  "defaultAction": "SCMP_ACT_ALLOW",
  "syscalls": [
    {
      "names": ["chmod", "fchmod", "fchmodat", "fchmodat2"],
      "action": "SCMP_ACT_ERRNO"
    }
  ]
}
```

```bash
docker run --rm --security-opt seccomp=sans-chmod.json alpine:3.24 sh -c 'chmod 600 /etc/hostname; echo code=$?; stat -c %a /etc/hostname'
```

```sortie
chmod: /etc/hostname: Operation not permitted
code=1
644
```

Le noyau propose quatre appels qui changent des droits : `chmod` (par chemin), `fchmod` (par descripteur de fichier), `fchmodat` (par chemin relatif à un dossier) et `fchmodat2`, ajouté en 2023. Sur x86-64, la commande `chmod` d'Alpine comme celle d'Ubuntu utilise le premier ; sur ARM64, où il n'existe pas, c'est `fchmodat`, et un programme qui a déjà ouvert le fichier utilise `fchmod`. Pour savoir lequel un programme appelle vraiment, on le trace : `docker run --rm labo:1.0 sh -c 'touch /f; strace -e trace=chmod,fchmod,fchmodat,fchmodat2 chmod 600 /f'` affiche `chmod("/f", 0600) = 0`. Un profil qui n'en nomme qu'un laisse passer les autres, d'où l'intérêt de partir d'une liste d'autorisations, comme le profil de Docker, plutôt que d'une liste d'interdictions.

</details>

:::exercice[Exercice 3 : nginx sans root, avec Docker]

Lancez `nginx:1.30-alpine` avec `--user 101:101`, l'UID de l'utilisateur `nginx` de l'image. Lisez l'erreur, corrigez-la, relancez, lisez la suivante. Arrivez à un nginx qui répond `200` en tournant entièrement sous l'UID 101, sans modifier l'image.

:::

<details>
<summary>Corrigé</summary>

Première erreur :

```sortie
nginx: [emerg] mkdir() "/var/cache/nginx/client_temp" failed (13: Permission denied)
```

`/var/cache/nginx` appartient à root. Plutôt que de modifier l'image, on y monte un `tmpfs` qui appartient à l'UID 101. Seconde erreur, une fois celle-ci corrigée :

```sortie
nginx: [emerg] open() "/run/nginx.pid" failed (13: Permission denied)
```

Le fichier de PID est dans `/run` (la ligne `pid /run/nginx.pid;` de `/etc/nginx/nginx.conf`), qui appartient aussi à root. Même remède :

```bash
docker run -d --name x12 --user 101:101 \
  --tmpfs /var/cache/nginx:uid=101,gid=101 --tmpfs /run:uid=101,gid=101 nginx:1.30-alpine
docker exec x12 sh -c 'id; curl -s -o /dev/null -w "http %{http_code}\n" http://localhost/'
docker rm -f x12
```

```sortie
uid=101(nginx) gid=101(nginx) groups=101(nginx)
http 200
```

Le port 80 ne pose pas de problème, pour la raison vue à l'exercice 1. Les journaux signalent seulement que le script d'entrée n'a pas pu modifier `default.conf` pour activer IPv6, ce qui est sans conséquence ici. Sans aucune capability et sans root, ce nginx a une surface d'attaque bien plus réduite ; le chapitre 13 montrera comment construire des images qui tournent ainsi d'emblée.

</details>

:::exercice[Exercice 4 : un Pod nginx « restricted »]

Modifiez `pod-nginx-nonroot.yaml` pour que le Pod démarre, en gardant `runAsNonRoot: true` et en ajoutant tout le durcissement de `pod-durci.yaml` : profil seccomp du runtime, pas d'élévation de privilèges, racine en lecture seule, aucune capability. Vérifiez depuis le Pod l'UID, les capabilities, seccomp et la réponse de nginx.

:::

<details>
<summary>Corrigé</summary>

Il faut un UID explicite, puisque l'image n'en déclare pas, et remplacer les `tmpfs` de l'exercice 3 par des volumes `emptyDir`, que Kubernetes crée avec des droits ouverts à tous :

```yaml title="pod-nginx-restreint.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: nginx-restreint
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 101
    runAsGroup: 101
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: nginx
    image: nginx:1.30-alpine
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
    volumeMounts:
    - name: cache
      mountPath: /var/cache/nginx
    - name: run
      mountPath: /run
  volumes:
  - name: cache
    emptyDir: {}
  - name: run
    emptyDir: {}
```

```bash
kubectl apply -f pod-nginx-restreint.yaml
kubectl wait --for=condition=Ready pod/nginx-restreint --timeout=90s
kubectl exec nginx-restreint -- sh -c 'id; grep -E "CapEff|NoNewPrivs|Seccomp:" /proc/1/status; curl -s -o /dev/null -w "http %{http_code}\n" http://localhost/'
```

```sortie
uid=101(nginx) gid=101(nginx) groups=101(nginx)
CapEff:	0000000000000000
NoNewPrivs:	1
Seccomp:	2
http 200
```

Le port 80 fonctionne sans capability parce que containerd règle lui aussi `ip_unprivileged_port_start` à 0 dans les Pods (`enable_unprivileged_ports = true` dans sa configuration). Les journaux de nginx contiennent un avertissement instructif : `the "user" directive makes sense only if the master process runs with super-user privileges, ignored`. La directive `user nginx;` de la configuration ne sert qu'à un nginx lancé en root ; ici, il n'y a plus de changement d'utilisateur à faire. Supprimez le Pod avec `kubectl delete pod nginx-restreint`.

</details>

## Nettoyer

Les conteneurs Docker de ce chapitre étaient éphémères. Supprimez les Pods, puis arrêtez minikube si vous n'en avez plus besoin :

```bash
kubectl delete pod defaut durci nginx-nonroot userns nginx-restreint --ignore-not-found
minikube stop
```

Si vous avez utilisé Podman, l'image Alpine qu'il a téléchargée se supprime avec `podman rmi docker.io/library/alpine:3.24`.

[^capabilities]: Linux man-pages, *capabilities(7)*, « overview of Linux capabilities ». [man7.org/linux/man-pages/man7/capabilities.7.html](https://man7.org/linux/man-pages/man7/capabilities.7.html)

[^docker-caps]: Docker, « Running containers », section *Runtime privilege and Linux capabilities*, qui donne la liste des capabilities accordées par défaut. [docs.docker.com/engine/containers/run](https://docs.docker.com/engine/containers/run/#runtime-privilege-and-linux-capabilities)

[^docker-seccomp]: Docker, « Seccomp security profiles for Docker », section *Significant syscalls blocked by the default profile*. [docs.docker.com/engine/security/seccomp](https://docs.docker.com/engine/security/seccomp/)

[^docker-apparmor]: Docker, « AppArmor security profiles for Docker ». [docs.docker.com/engine/security/apparmor](https://docs.docker.com/engine/security/apparmor/)

[^docker-surface]: Docker, « Docker Engine security », section *Docker daemon attack surface*. [docs.docker.com/engine/security](https://docs.docker.com/engine/security/#docker-daemon-attack-surface)

[^docker-rootless]: Docker, « Rootless mode ». [docs.docker.com/engine/security/rootless](https://docs.docker.com/engine/security/rootless/)

[^k8s-userns]: Kubernetes, « User Namespaces », avec la liste des prérequis du nœud. [kubernetes.io/docs/concepts/workloads/pods/user-namespaces](https://kubernetes.io/docs/concepts/workloads/pods/user-namespaces/)

[^k8s-seccomp]: Kubernetes, « Restrict a Container's Syscalls with seccomp », sections *Create Pod that uses the container runtime default seccomp profile* et *Enable the use of RuntimeDefault as the default seccomp profile for all workloads*. [kubernetes.io/docs/tutorials/security/seccomp](https://kubernetes.io/docs/tutorials/security/seccomp/)

[^pss]: Kubernetes, « Pod Security Standards ». [kubernetes.io/docs/concepts/security/pod-security-standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)

[^cve-2019-5736]: Aleksa Sarai, « CVE-2019-5736: runc container breakout (all versions) », liste oss-security, 11 février 2019. [seclists.org/oss-sec/2019/q1/119](https://seclists.org/oss-sec/2019/q1/119)

[^cve-2022-0185]: NIST, National Vulnerability Database, « CVE-2022-0185 ». [nvd.nist.gov/vuln/detail/CVE-2022-0185](https://nvd.nist.gov/vuln/detail/CVE-2022-0185)

[^cve-2022-0492]: Yuval Avrahami, « New Linux Vulnerability CVE-2022-0492 Affecting Cgroups: Can Containers Escape? », Palo Alto Networks Unit 42, mars 2022. [unit42.paloaltonetworks.com/cve-2022-0492-cgroups](https://unit42.paloaltonetworks.com/cve-2022-0492-cgroups/)

[^cve-2024-21626]: opencontainers/runc, avis de sécurité GHSA-xr7r-f8xq-vfvv (CVE-2024-21626), sur la fuite de descripteurs de fichiers et le dossier de travail du processus. [github.com/opencontainers/runc/security/advisories/GHSA-xr7r-f8xq-vfvv](https://github.com/opencontainers/runc/security/advisories/GHSA-xr7r-f8xq-vfvv)
