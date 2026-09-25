---
title: Les systèmes de fichiers en couches
sidebar_label: 10. Les couches
description: Comment overlayfs empile les couches d'une image et la couche modifiable d'un conteneur ; la copie à l'écriture, les whiteouts, les dossiers opaques ; une image nginx montée à la main.
partie: 2
chapitre: '10'
---

import overlayOperations from '@site/src/figures/overlay-operations.svg';

Au chapitre 3, on a vu qu'une image est une pile de couches, chacune une archive tar, et que deux images qui partagent une couche ne la stockent qu'une fois. Au chapitre 5, qu'un conteneur écrit dans une « couche modifiable » qui disparaît avec lui. Ces deux affirmations supposent un tour de passe-passe : comment un programme qui ouvre `/etc/nginx/nginx.conf` peut-il lire un seul fichier, alors que les fichiers du conteneur sont répartis dans neuf dossiers différents, dont huit en lecture seule ?

Le tour de passe-passe s'appelle **overlayfs**, un système de fichiers du noyau Linux qui superpose plusieurs dossiers et les présente comme un seul[^overlayfs]. Ce chapitre le regarde fonctionner chez Docker, puis l'utilise à la main, jusqu'à reconstituer le système de fichiers de nginx à partir de ses huit couches.

Il se fait dans le laboratoire du chapitre 8, avec un conteneur `cible` neuf :

```bash
docker run -d --name cible nginx:1.30-alpine
```

## Où Docker range les fichiers d'un conteneur

`docker info` indique le pilote de stockage utilisé :

```bash
docker info --format '{{.Driver}}'
docker info --format '{{json .DriverStatus}}'
```

```sortie
overlay2
[["Backing Filesystem","extfs"],["Supports d_type","true"],["Using metacopy","false"],["Native Overlay Diff","true"],["userxattr","false"]]
```

`overlay2` est le pilote qui s'appuie sur overlayfs, sur un disque ext4 (`extfs`). `docker inspect` révèle les dossiers qui composent le système de fichiers de `cible` :

```bash
docker inspect cible --format '{{json .GraphDriver}}' | python3 -m json.tool
```

```sortie
{
    "Data": {
        "ID": "70844a66f24e172a49c408c87a875522e5e1cd56035d286f065b45ac78a10498",
        "LowerDir": "/var/lib/docker/overlay2/b40435b6c554...-init/diff:/var/lib/docker/overlay2/e6ea1ef0b5c2.../diff:/var/lib/docker/overlay2/7a2c6525eeea.../diff:...:/var/lib/docker/overlay2/70c927efddcb.../diff",
        "MergedDir": "/var/lib/docker/overlay2/b40435b6c5541493b9a7e9e5c0fb833b6ccba5d10c5f864378af5f194cc2c1fd/merged",
        "UpperDir": "/var/lib/docker/overlay2/b40435b6c5541493b9a7e9e5c0fb833b6ccba5d10c5f864378af5f194cc2c1fd/diff",
        "WorkDir": "/var/lib/docker/overlay2/b40435b6c5541493b9a7e9e5c0fb833b6ccba5d10c5f864378af5f194cc2c1fd/work"
    },
    "Name": "overlay2"
}
```

Quatre sortes de dossiers, et ce sont les quatre notions d'overlayfs :

- `LowerDir`, les **couches basses** : une liste de dossiers en lecture seule, séparés par des deux-points. Il y en a neuf ici : les huit couches de l'image nginx, plus une couche `-init` que Docker ajoute pour chaque conteneur.
- `UpperDir`, la **couche haute** : un dossier modifiable, propre au conteneur. C'est la couche modifiable des chapitres 2 et 5.
- `WorkDir`, un **dossier de travail** qu'overlayfs utilise en interne pour rendre ses opérations atomiques.
- `MergedDir`, le **point de montage** où apparaît la fusion de tout le reste : c'est la racine `/` que voit le conteneur.

Ces chemins existent sur votre machine, mais pas dans le laboratoire, qui a son propre namespace de montage. On peut pourtant les atteindre : avec `--pid=host`, le laboratoire voit le processus 1 de la machine, et le lien `/proc/1/root` désigne la racine de la machine telle que ce processus la voit. Vérifions le montage, vu depuis le namespace de montage de la machine (`nsenter --target 1 --mount`) :

```bash
MG=/var/lib/docker/overlay2/b40435b6c5541493b9a7e9e5c0fb833b6ccba5d10c5f864378af5f194cc2c1fd/merged
nsenter --target 1 --mount findmnt -n -o OPTIONS $MG | tr ',' '\n'
```

```sortie
rw
relatime
lowerdir=/var/lib/docker/overlay2/l/D4TZPCOI24QF2PIAREDDWZBPI6:/var/lib/docker/overlay2/l/6KC75YIOUK5THR5R7KLAESPALL:...
upperdir=/var/lib/docker/overlay2/b40435b6c5541493b9a7e9e5c0fb833b6ccba5d10c5f864378af5f194cc2c1fd/diff
workdir=/var/lib/docker/overlay2/b40435b6c5541493b9a7e9e5c0fb833b6ccba5d10c5f864378af5f194cc2c1fd/work
nouserxattr
```

Le conteneur est un montage de type `overlay`, avec exactement les trois options `lowerdir`, `upperdir` et `workdir`. Les couches basses y sont désignées par des noms courts, `l/D4TZPCOI...`, qui sont des liens symboliques vers les vrais dossiers. La raison est prosaïque : les options d'un montage doivent tenir dans une page mémoire de 4096 octets, et avec des dizaines de couches aux noms de 64 caractères, les chemins complets ne tiendraient pas.

### La couche -init

La première couche basse, `...-init`, n'appartient pas à l'image. Docker la crée pour chaque conteneur :

```bash
cd /proc/1/root/var/lib/docker/overlay2/b40435b6c554...-init/diff && find . | sort
```

```sortie
.
./.dockerenv
./dev
./dev/console
./dev/pts
./dev/shm
./etc
./etc/hostname
./etc/hosts
./etc/mtab
./etc/resolv.conf
```

Elle prépare les fichiers que chaque conteneur doit avoir à son nom : son nom de machine, son fichier `hosts`, sa configuration DNS, et `.dockerenv`, un fichier vide qui permet à un programme de savoir qu'il tourne sous Docker. En réalité, ces trois fichiers de `/etc` sont ensuite recouverts par des montages liés, que Docker met à jour à chaud (quand on connecte le conteneur à un réseau, par exemple). `docker exec cible mount | grep -E 'hosts|resolv'` le montre : `/etc/hosts` et `/etc/resolv.conf` y sont des montages de type `ext4`.

## La couche haute, en direct

La couche haute d'un conteneur neuf contient déjà quelques fichiers, ceux que nginx crée en démarrant :

```bash
cd /proc/1/root/var/lib/docker/overlay2/b40435b6c554.../diff && find . | sort
```

```sortie
.
./etc
./etc/nginx
./etc/nginx/conf.d
./etc/nginx/conf.d/default.conf
./run
./run/nginx.pid
./var
./var/cache
./var/cache/nginx
./var/cache/nginx/client_temp
...
```

Le fichier `default.conf` y figure : le script de démarrage de l'image le modifie pour activer IPv6 (c'est la ligne `Enabled listen on IPv6` du chapitre 2), et le modifier l'a fait remonter dans la couche haute. Faisons à notre tour deux changements dans le conteneur, depuis votre poste :

```bash
docker exec cible sh -c 'echo bonjour > /tmp/note.txt; rm /etc/nginx/conf.d/default.conf'
docker diff cible
```

```sortie
C /etc
C /etc/nginx
C /etc/nginx/conf.d
D /etc/nginx/conf.d/default.conf
C /tmp
A /tmp/note.txt
C /run
A /run/nginx.pid
...
```

`docker diff`, que l'on a utilisé au chapitre 5, ne fait rien d'autre que parcourir la couche haute. Regardons-la directement :

```bash
ls -l etc/nginx/conf.d/
cat tmp/note.txt
```

```sortie
total 0
c--------- 2 root root 0, 0 Sep 25 14:40 default.conf
bonjour
```

Le fichier créé est là, tel quel. Le fichier supprimé, lui, est devenu un objet étrange : un fichier spécial de type caractère (le `c` en tête des droits), de numéros `0, 0`, sans aucun droit. C'est un **whiteout**, une marque d'effacement : overlayfs ne peut pas supprimer le `default.conf` d'une couche basse, qui est en lecture seule, alors il pose dans la couche haute une marque qui dit « ce fichier n'existe plus ». Le fichier original est toujours dans l'image.

Cette couche haute ne pèse presque rien :

```bash
docker ps -s --filter name=^cible$ --format 'table {{.Names}}\t{{.Size}}'
```

```sortie
NAMES     SIZE
cible     10B (virtual 62.4MB)
```

`10B` est la taille de la couche haute ; `virtual 62.4MB` celle de l'image partagée en dessous. Cent conteneurs nginx occuperaient cent couches hautes de quelques octets et une seule fois les 62 Mo de l'image.

## overlayfs à la main

Refaisons tout cela nous-mêmes, dans le dossier `/labo` du laboratoire. Il faut quatre dossiers : une couche basse, une couche haute, un dossier de travail et un point de montage.

```bash
mkdir -p /labo/couches/{bas,haut,travail,fusion} && cd /labo/couches
echo 'version de base' > bas/lisez-moi.txt
echo 'config d origine' > bas/config.txt
mkdir bas/dossier && echo a > bas/dossier/a.txt && echo b > bas/dossier/b.txt
mount -t overlay overlay -o lowerdir=bas,upperdir=haut,workdir=travail fusion
ls fusion
```

```sortie
config.txt
dossier
lisez-moi.txt
```

Le dossier `fusion` montre les fichiers de la couche basse, et la couche haute est vide. Toutes les opérations qui suivent se font dans `fusion`, comme le ferait un programme dans un conteneur. Observez à chaque fois ce qui apparaît dans `haut` et ce qui change, ou pas, dans `bas`.

**Lire** ne change rien : `cat fusion/lisez-moi.txt` affiche `version de base`, lu directement dans la couche basse, et `haut` reste vide.

**Modifier** un fichier de la couche basse déclenche une **copie à l'écriture** (*copy-up*) : overlayfs copie d'abord le fichier entier dans la couche haute, puis y applique la modification.

```bash
echo 'modifié' >> fusion/config.txt
cat fusion/config.txt; echo ---; cat bas/config.txt; echo ---; ls -l haut
```

```sortie
config d origine
modifié
---
config d origine
---
total 4
-rw-r--r--+1 root root 26 Sep 25 14:40 config.txt
```

Le conteneur voit la version modifiée ; la couche basse est intacte ; la copie modifiée est dans `haut`. C'est ce qui permet à cent conteneurs de modifier chacun leur `config.txt` sans se gêner ni abîmer l'image.

**Créer** un fichier l'écrit simplement dans la couche haute : après `echo nouveau > fusion/nouveau.txt`, `haut` contient `config.txt` et `nouveau.txt`, `bas` n'a pas bougé.

**Supprimer** un fichier de la couche basse pose un whiteout :

```bash
rm fusion/lisez-moi.txt
ls fusion; ls -l haut/lisez-moi.txt; ls bas
```

```sortie
config.txt
dossier
nouveau.txt
c--------- 2 root root 0, 0 Sep 25 14:40 haut/lisez-moi.txt
config.txt
dossier
lisez-moi.txt
```

Le fichier a disparu de la vue fusionnée, la marque `c 0, 0` est dans `haut`, et l'original dort toujours dans `bas`. C'est la même marque que chez Docker.

**Remplacer un dossier** demande un mécanisme de plus. Supprimons `dossier` et recréons-le avec un autre contenu :

```bash
rm -r fusion/dossier && mkdir fusion/dossier && echo c > fusion/dossier/c.txt
ls fusion/dossier; ls bas/dossier
getfattr -d -m - haut/dossier
```

```sortie
c.txt
a.txt
b.txt
# file: haut/dossier
trusted.overlay.opaque="y"
```

Le nouveau dossier ne montre que `c.txt`, alors que `a.txt` et `b.txt` sont toujours dans la couche basse. Sans précaution, overlayfs fusionnerait les deux dossiers et ferait réapparaître les anciens fichiers. Il marque donc le dossier de la couche haute comme **opaque**, avec l'attribut étendu `trusted.overlay.opaque` : tout ce qui se trouve sous ce nom dans les couches basses est alors ignoré.

<Figure svg={overlayOperations} num="10.1" alt="Trois étages : bas en lecture seule, haut modifiable, fusion vue par le conteneur. Lire un fichier le lit en bas. Modifier le copie en haut puis le modifie. Créer l'écrit en haut. Supprimer pose un whiteout en haut. Remplacer un dossier pose un dossier opaque en haut qui cache celui d'en bas.">
Ce que devient chaque opération dans un overlayfs. La couche basse n'est jamais modifiée ; tout le travail se fait dans la couche haute.
</Figure>

Enfin, démontez, et regardez ce qui reste :

```bash
umount fusion
ls fusion | wc -l; ls -l haut; ls bas
```

```sortie
0
total 12
-rw-r--r--+1 root root   26 Sep 25 14:40 config.txt
drwxr-xr-x+2 root root 4096 Sep 25 14:40 dossier
c--------- 2 root root 0, 0 Sep 25 14:40 lisez-moi.txt
-rw-r--r-- 1 root root    8 Sep 25 14:40 nouveau.txt
config.txt
dossier
lisez-moi.txt
```

La vue fusionnée n'existe plus : `fusion` est un dossier vide. Toutes les modifications sont dans `haut`, sous forme de fichiers ordinaires, de marques d'effacement et d'attributs : c'est exactement ce que contient la couche d'une image. Quand `docker build` exécute une instruction `RUN`, il la fait tourner dans un conteneur, puis archive sa couche haute en tar : c'est la nouvelle couche de l'image. Et à l'extraction, les marques d'effacement deviennent, dans l'archive, des fichiers au nom préfixé par `.wh.`, selon la convention de la spécification OCI[^oci-layer].

## Le prix de la copie à l'écriture

La copie à l'écriture copie le fichier **entier**, même pour modifier un seul octet. Mesurons-le avec un fichier de 500 Mo dans la couche basse :

```bash
mkdir bas2 haut2 trav2 fus2
dd if=/dev/zero of=bas2/gros.bin bs=1M count=500 status=none
mount -t overlay overlay -o lowerdir=bas2,upperdir=haut2,workdir=trav2 fus2
du -sh haut2
time (echo x >> fus2/gros.bin)
du -sh haut2
time (echo y >> fus2/gros.bin)
```

```sortie
4.0K	haut2
real	0m0.330s
501M	haut2
real	0m0.000s
```

Ajouter un octet au fichier a pris un tiers de seconde et fait apparaître 501 Mo dans la couche haute : le fichier entier a été copié. Le deuxième ajout est instantané, puisque la copie est faite. Sur un disque lent, ou avec un fichier de plusieurs gigaoctets, le premier accès en écriture peut prendre des minutes.

C'est la raison profonde pour laquelle une base de données ne doit jamais écrire dans la couche d'un conteneur. Ses fichiers sont gros et modifiés sans cesse, et chaque fichier de l'image touché pour la première fois serait copié en entier ; ses données seraient en outre perdues avec le conteneur (chapitre 5). Un volume, lui, est un dossier ordinaire, sans couche ni copie. L'image PostgreSQL déclare d'ailleurs un volume pour cette raison.

Démontez et nettoyez : `umount fus2 && rm -rf bas2 haut2 trav2 fus2`.

## Une image, montée à la main

Reconstituons maintenant le système de fichiers de nginx à partir de ses couches, sans Docker. `skopeo` télécharge l'image au format OCI, et on extrait chaque couche dans son propre dossier, dans l'ordre du manifeste :

```bash
skopeo copy docker://nginx:1.30-alpine oci:/labo/nginx:1.30-alpine
cd /labo/nginx
M=$(jq -r '.manifests[0].digest' index.json | cut -d: -f2)
i=0; for d in $(jq -r '.layers[].digest' blobs/sha256/$M | cut -d: -f2); do
  i=$((i+1)); mkdir -p /labo/nginx-couches/$i
  tar -xzf blobs/sha256/$d -C /labo/nginx-couches/$i
  echo "couche $i : $(du -sh /labo/nginx-couches/$i | cut -f1)"
done
```

```sortie
couche 1 : 8.7M
couche 2 : 5.4M
couche 3 : 8.0K
couche 4 : 12K
couche 5 : 12K
couche 6 : 12K
couche 7 : 16K
couche 8 : 50M
```

Vous reconnaissez les couches de `docker image history` au chapitre 3 : Alpine (8,7 Mo), nginx lui-même avec son utilisateur (5,4 Mo), les petits scripts de démarrage, et la grosse couche des modules supplémentaires (50 Mo). Pour les empiler, il faut les donner à overlayfs dans le bon ordre : dans l'option `lowerdir`, **le dossier le plus à gauche est celui du dessus**. La couche 8, la plus récente, vient donc en premier :

```bash
cd /labo && mkdir -p nginx-haut nginx-travail nginx-fusion
L=$(ls nginx-couches | sort -rn | sed 's|^|nginx-couches/|' | paste -sd:)
echo "lowerdir=$L"
mount -t overlay overlay -o lowerdir=$L,upperdir=nginx-haut,workdir=nginx-travail nginx-fusion
ls nginx-fusion
cat nginx-fusion/etc/alpine-release
chroot nginx-fusion nginx -v
```

```sortie
lowerdir=nginx-couches/8:nginx-couches/7:nginx-couches/6:nginx-couches/5:nginx-couches/4:nginx-couches/3:nginx-couches/2:nginx-couches/1
bin  dev  docker-entrypoint.d  docker-entrypoint.sh  etc  home  lib  media  mnt  opt  proc  root  run  sbin  srv  sys  tmp  usr  var
3.24.2
nginx version: nginx/1.30.5
```

Huit archives tar, un montage, et le programme `nginx` de l'image répond, exécuté par `chroot` dans la vue fusionnée. Avec les namespaces du chapitre 8 et un cgroup du chapitre 9, vous avez maintenant tous les ingrédients d'un conteneur Docker ; le chapitre 11 montrera le programme qui les assemble pour de bon. Démontez : `umount /labo/nginx-fusion`.

:::panne[mount: wrong fs type, bad option, bad superblock on overlay]

Ce message, très vague, apparaît si l'on essaie de monter un overlayfs dont la couche haute est elle-même sur un overlayfs. C'est ce qui arrive dans le système de fichiers d'un conteneur : le `/tmp` du laboratoire est un overlayfs (`df -T /tmp` affiche `overlay`), et `mount -t overlay ... /tmp/o/fusion` échoue avec ce message et le code 32. C'est pour cette raison que le laboratoire monte le volume `labo` sur `/labo` : un volume est un vrai dossier du disque de la machine, en ext4. Les autres causes fréquentes de ce message sont un `workdir` qui n'est pas sur le même système de fichiers que l'`upperdir`, ou un dossier qui n'existe pas ; `dmesg | tail` donne en général la vraie raison.

:::

## Au-delà d'overlay2

Docker propose d'autres façons de stocker les images. Depuis Docker 29, les nouvelles installations utilisent par défaut le **magasin d'images de containerd** (*containerd image store*) : Docker délègue alors le stockage des images à containerd et à ses *snapshotters*, dont le principal, `overlayfs`, fonctionne exactement comme ce chapitre l'a décrit[^containerd-store]. Le poste du cours, installé avant, utilise encore le pilote `overlay2` de Docker, d'où les chemins `/var/lib/docker/overlay2`. Dans le nœud minikube, où containerd est le runtime, les couches se trouvent sous `/var/lib/containerd`, et le chapitre 11 ira les regarder. Les principes restent les mêmes : des couches basses partagées, une couche haute par conteneur, et la copie à l'écriture.

## Exercices

:::exercice[Exercice 1 : l'ordre des couches]

Créez deux couches basses `c1` et `c2`, qui contiennent chacune un fichier `qui.txt` au contenu différent (« couche 1 », « couche 2 »), et un fichier `un.txt` dans `c1` seulement. Montez-les avec `lowerdir=c1:c2`, puis avec `lowerdir=c2:c1`. Que voit-on dans `qui.txt` ? Et `un.txt` ?

:::

<details>
<summary>Corrigé</summary>

Avec `lowerdir=c1:c2`, `qui.txt` affiche `couche 1` ; avec `lowerdir=c2:c1`, il affiche `couche 2`. Quand un fichier existe dans plusieurs couches, c'est celui de la couche la plus à gauche dans la liste qui l'emporte : elle est « au-dessus ». `un.txt` apparaît dans les deux cas, puisqu'il n'existe que dans une couche. C'est exactement ce qui se passe quand une instruction d'un Dockerfile modifie un fichier installé par une instruction précédente : la nouvelle version, dans une couche plus récente, masque l'ancienne, qui continue d'occuper de la place dans l'image.

</details>

:::exercice[Exercice 2 : un fichier supprimé coûte-t-il de la place ?]

Écrivez un Dockerfile qui part d'`alpine:3.24`, crée un fichier de 100 Mo avec `RUN dd if=/dev/zero of=/gros bs=1M count=100`, puis le supprime dans une seconde instruction `RUN rm /gros`. Quelle est la taille de l'image obtenue ? Pourquoi ? Comment l'éviter ?

:::

<details>
<summary>Corrigé</summary>

L'image pèse environ 113 Mo (8,4 Mo d'Alpine et 104,9 Mo de la couche du `dd`), bien que le fichier n'y soit plus visible. La première instruction a produit une couche qui contient le fichier ; la seconde, une couche qui ne contient qu'un whiteout. Les deux couches sont dans l'image, et la première occupe ses 100 Mo pour toujours. Pour éviter ce gaspillage, il faut créer et supprimer le fichier dans la même instruction (`RUN dd ... && ... && rm /gros`), ou utiliser une construction en plusieurs étapes, qui ne copie dans l'image finale que ce dont on a besoin (chapitre 13). C'est aussi pourquoi un secret ajouté puis supprimé dans un Dockerfile reste lisible dans l'image : il suffit d'extraire la couche où il a été ajouté.

</details>

:::exercice[Exercice 3 : retrouver un fichier « supprimé » d'une image]

Avec `docker save` et `tar` (chapitre 3), récupérez le fichier `/etc/nginx/conf.d/default.conf` de l'image `nginx:1.30-alpine`, sans lancer de conteneur. Dans quelle couche se trouve-t-il ?

:::

<details>
<summary>Corrigé</summary>

```bash
docker save nginx:1.30-alpine -o nginx.tar && mkdir n && tar -xf nginx.tar -C n
for f in n/blobs/sha256/*; do tar -tf "$f" 2>/dev/null | grep -q '^etc/nginx/conf.d/default.conf$' && echo "$f"; done
```

Une seule archive contient le fichier, `2d3fbe0ca19d...`, qui pèse 4,6 Mo : c'est la deuxième couche, celle qui crée l'utilisateur `nginx` et installe nginx lui-même. La grosse couche de 50 Mo, elle, n'ajoute que des modules. `tar -xOf <cette couche> etc/nginx/conf.d/default.conf` affiche le fichier. Toute la démarche tient en un principe : une image n'est qu'une pile d'archives, et chaque archive est lisible par n'importe qui, avec n'importe quel outil. Supprimez ensuite `nginx.tar` et le dossier `n`.

</details>

:::exercice[Exercice 4 : la couche d'un conteneur qui écrit beaucoup]

Lancez `docker run -d --name bavard alpine:3.24 sh -c 'while true; do date >> /journal.txt; sleep 0.1; done'`. Au bout d'une minute, que montre `docker ps -s` pour ce conteneur ? Que se passerait-il au bout d'un mois ? Quelle leçon en tirer pour les journaux d'une application ?

:::

<details>
<summary>Corrigé</summary>

La taille de la couche haute (`SIZE`) grandit de quelques kilo-octets par seconde. Au bout d'un mois, le fichier occuperait des centaines de mégaoctets dans la couche du conteneur, sur le disque de la machine, sans rotation, et serait perdu à la suppression du conteneur. Une application conteneurisée doit écrire ses journaux sur sa sortie standard, que Docker (et Kubernetes) récupère et fait tourner, pas dans un fichier de son système de fichiers : c'est la règle posée au chapitre 2, et ce chapitre en montre la raison physique. Supprimez le conteneur avec `docker rm -f bavard`.

</details>

## Nettoyer

Dans le laboratoire, démontez ce qui reste monté et supprimez les dossiers d'essai ; sur votre poste, supprimez `cible`, dont la couche a été modifiée :

```bash
umount /labo/couches/fusion /labo/nginx-fusion 2>/dev/null        # dans le laboratoire
rm -rf /labo/couches /labo/nginx-couches /labo/nginx-haut /labo/nginx-travail /labo/nginx-fusion
docker rm -f cible                                                  # sur votre poste
```

Gardez `/labo/nginx` et `/labo/bundle` : le chapitre 11 s'en servira.

[^overlayfs]: Linux kernel documentation, « Overlay Filesystem », sections *Upper and Lower*, *whiteouts and opaque directories* et *Multiple lower layers*. [docs.kernel.org/filesystems/overlayfs.html](https://docs.kernel.org/filesystems/overlayfs.html)

[^oci-layer]: Open Container Initiative, *Image Format Specification*, « Image Layer Filesystem Changeset », section *Whiteouts*. [github.com/opencontainers/image-spec/blob/main/layer.md](https://github.com/opencontainers/image-spec/blob/main/layer.md)

[^containerd-store]: Docker, « containerd image store ». [docs.docker.com/engine/storage/containerd](https://docs.docker.com/engine/storage/containerd/)
