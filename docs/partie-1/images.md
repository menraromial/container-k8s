---
title: Les images
sidebar_label: 3. Les images
description: Ce que contient une image, comment elle est faite de couches, ce qui distingue une étiquette d'une empreinte, comment une image choisit la bonne architecture, et comment elle voyage entre un registre et votre machine.
partie: 1
chapitre: '3'
---

import imageNomVersCouches from '@site/src/figures/image-nom-vers-couches.svg';
import couchesPartagees from '@site/src/figures/couches-partagees.svg';

Au chapitre précédent, la première ligne utile de `docker run nginx:1.30-alpine` était celle-ci :

```sortie
e2de96513ba9: Already exists
```

Docker s'apprêtait à télécharger nginx, et il a constaté qu'un morceau de l'image était déjà sur la machine. Ce morceau n'avait rien à voir avec nginx : il venait de l'image `alpine:3.24` téléchargée au chapitre 1. Comment Docker a-t-il pu le savoir ? Qu'est-ce que ce `e2de96513ba9` ? Et que télécharge-t-on exactement quand on tire une image ?

Ce chapitre ouvre une image pour de bon. On va la décomposer en couches, lire sa configuration, suivre le chemin qui mène de son nom aux octets téléchargés, la déballer fichier par fichier, et finir par la pousser dans un registre qu'on aura démarré soi-même. Tout ce qu'on y verra est défini par les standards de l'Open Container Initiative, et vaut donc aussi pour Podman et Kubernetes.

## Ce que contient une image

Une image contient deux choses : des fichiers, et une configuration qui dit comment les utiliser.

Les fichiers forment un système de fichiers complet, celui que verra le conteneur : `/bin`, `/etc`, `/usr`, et l'application quelque part au milieu. Ils ne sont pas rangés dans une seule archive, mais répartis en **couches** empilées. Chaque couche contient les fichiers ajoutés, modifiés ou supprimés par une étape de la construction de l'image. `docker image history` affiche ces étapes, de la plus récente à la plus ancienne :

```bash
docker image history nginx:1.30-alpine
```

```sortie
IMAGE          CREATED      CREATED BY                                      SIZE      COMMENT
43d9d8c1f896   2 days ago   RUN /bin/sh -c set -x     && apkArch="$(cat …   49.7MB    buildkit.dockerfile.v0
<missing>      2 days ago   ENV ACME_VERSION=0.4.1                          0B        buildkit.dockerfile.v0
...
<missing>      2 days ago   CMD ["nginx" "-g" "daemon off;"]                0B        buildkit.dockerfile.v0
<missing>      2 days ago   STOPSIGNAL SIGQUIT                              0B        buildkit.dockerfile.v0
<missing>      2 days ago   EXPOSE map[80/tcp:{}]                           0B        buildkit.dockerfile.v0
<missing>      2 days ago   ENTRYPOINT ["/docker-entrypoint.sh"]            0B        buildkit.dockerfile.v0
<missing>      2 days ago   COPY 30-tune-worker-processes.sh /docker-ent…   4.62kB    buildkit.dockerfile.v0
<missing>      2 days ago   COPY 20-envsubst-on-templates.sh /docker-ent…   3.03kB    buildkit.dockerfile.v0
<missing>      2 days ago   COPY 15-local-resolvers.envsh /docker-entryp…   389B      buildkit.dockerfile.v0
<missing>      2 days ago   COPY 10-listen-on-ipv6-by-default.sh /docker…   2.14kB    buildkit.dockerfile.v0
<missing>      2 days ago   COPY docker-entrypoint.sh / # buildkit          1.62kB    buildkit.dockerfile.v0
<missing>      2 days ago   RUN /bin/sh -c set -x     && addgroup -g 101…   4.3MB     buildkit.dockerfile.v0
<missing>      2 days ago   ENV DYNPKG_RELEASE=1                            0B        buildkit.dockerfile.v0
<missing>      2 days ago   ENV PKG_RELEASE=1                               0B        buildkit.dockerfile.v0
<missing>      2 days ago   ENV NGINX_VERSION=1.30.5                        0B        buildkit.dockerfile.v0
<missing>      2 days ago   LABEL maintainer=NGINX Docker Maintainers <d…   0B        buildkit.dockerfile.v0
<missing>      7 days ago   CMD ["/bin/sh"]                                 0B        buildkit.dockerfile.v0
<missing>      7 days ago   ADD alpine-minirootfs-3.24.2-x86_64.tar.gz /…   8.42MB    buildkit.dockerfile.v0
```

Lisez-la de bas en haut. Tout commence par l'ajout d'une archive, `alpine-minirootfs-3.24.2`, qui pèse 8,42 Mo : c'est l'image Alpine tout entière, construite sept jours plus tôt. Les mainteneurs de nginx sont partis de là. Ils ont créé un utilisateur et installé nginx dans une même étape (`addgroup -g 101...`, 4,3 Mo), copié quelques scripts de démarrage, puis ajouté des modules supplémentaires dans une grosse étape de 49,7 Mo. Chaque ligne est une instruction du fichier qui a servi à construire l'image, le Dockerfile, que nous apprendrons à écrire au chapitre 4.

Les lignes de taille `0B` ne produisent aucun fichier : elles modifient seulement la configuration. `ENV` définit une variable d'environnement, `EXPOSE` déclare un port, `CMD` et `ENTRYPOINT` disent quelle commande lancer. Cette configuration se lit avec `docker image inspect` :

```bash
docker image inspect nginx:1.30-alpine --format 'Entrypoint={{json .Config.Entrypoint}}
Cmd={{json .Config.Cmd}}
Ports={{json .Config.ExposedPorts}}
StopSignal={{.Config.StopSignal}}'
```

```sortie
Entrypoint=["/docker-entrypoint.sh"]
Cmd=["nginx","-g","daemon off;"]
Ports={"80/tcp":{}}
StopSignal=SIGQUIT
```

Voilà l'explication de ce que vous avez vu au chapitre 2. Quand on lance l'image sans préciser de commande, Docker exécute l'`Entrypoint` en lui passant le `Cmd` en arguments : `/docker-entrypoint.sh nginx -g "daemon off;"`. Le script affiche les lignes `/docker-entrypoint.sh: ...` du démarrage, puis se remplace par nginx, qui devient le processus numéro 1. Quant au `StopSignal`, il dit à `docker stop` d'envoyer SIGQUIT plutôt que SIGTERM : pour nginx, c'est SIGQUIT qui demande un arrêt propre, après la fin des requêtes en cours. `docker stop` en tient compte, et c'est une autre raison pour laquelle nginx s'arrêtait si vite.

La colonne `IMAGE` de `docker image history` n'affiche un identifiant que pour la ligne du haut ; les autres portent `<missing>`. Ce n'est pas une erreur : ces étapes ont été construites sur une autre machine, celle des mainteneurs de nginx, et Docker n'a reçu que leur résultat, les couches, sans les images intermédiaires.

## Des couches partagées

Les couches sont désignées par leur empreinte : le résultat de la fonction de hachage SHA-256 appliquée à leur contenu. Deux couches qui contiennent exactement les mêmes octets ont la même empreinte, où qu'elles aient été construites. Comparons les couches de deux images :

```bash
docker image inspect alpine:3.24 --format '{{range .RootFS.Layers}}{{println .}}{{end}}'
docker image inspect nginx:1.30-alpine --format '{{range .RootFS.Layers}}{{println .}}{{end}}'
```

```sortie
sha256:74d97c428c51a828f9051a7a40a53ff1fc99e54fc30323ce36760701b0b7f711

sha256:74d97c428c51a828f9051a7a40a53ff1fc99e54fc30323ce36760701b0b7f711
sha256:2d3fbe0ca19dd389108f7e9a1d89ec5c1f1d7dc3c11fb2123bc425fed39c5f22
sha256:ed752e851ebe79a0e72be1fd48e90474d36ae2bb2ddccff2475f8e050c20a804
sha256:ec2b9a359ab960e2254545e79e9bca77edaeefb652d97b26855217fb8a9c80b3
sha256:267e83adf4c4e342b08cbe40814662493e030c88311c720fbce2f0d7c809f3f4
sha256:8fb5da5ad6fa936ba8c24999da33095b2b6c5fd2bcf4aa22acbf299b0e7294df
sha256:0d250d8db7c20b3c0bd3059b3431dd47f130cb81e7a4c7820950139daafb91d6
sha256:e46f4042ccf5f36d1605617ef6912bdaac437fa0bca12530e77529b191eb02fa
```

L'image Alpine n'a qu'une couche. nginx en a huit, et la première est la même, au bit près : `74d97c42...`. Docker ne la stocke qu'une fois sur le disque, et ne la télécharge qu'une fois. C'est ce qu'annonçait le `Already exists` du chapitre 2.

<Figure svg={couchesPartagees} num="3.1" alt="Quatre images en piles de couches. alpine:3.24, nginx:1.30-alpine et registry:3 reposent sur la même couche de base Alpine 3.24.2, stockée une seule fois. redis:8.8-alpine repose sur une autre couche, Alpine 3.23, et ne partage rien.">
Quatre images présentes sur le poste du cours. Trois partagent la même couche de base ; <code>redis:8.8-alpine</code>, construite sur une version plus ancienne d'Alpine, n'en partage aucune.
</Figure>

Le partage ne fonctionne qu'à l'identique. L'image `redis:8.8-alpine` repose aussi sur Alpine, mais sur la version 3.23.6 :

```bash
docker pull redis:8.8-alpine
```

```sortie
8.8-alpine: Pulling from library/redis
d0c1d894c237: Pull complete
58b94f35da8c: Pull complete
21ec2c8f8d05: Pull complete
d7e15a7e84f6: Pull complete
05f7d7c1db56: Pull complete
4f4fb700ef54: Pull complete
896fda7a3211: Pull complete
Digest: sha256:0b2b77d3ea5078274795e3177cdbdada8b96316684a38911d528534ed679b5ec
Status: Downloaded newer image for redis:8.8-alpine
docker.io/library/redis:8.8-alpine
```

Aucun `Already exists` : pas une seule couche en commun, parce que la couche Alpine 3.23 n'a pas les mêmes octets que la couche Alpine 3.24. Voilà pourquoi les équipes qui gèrent beaucoup d'images s'efforcent de les construire toutes sur la même image de base, dans la même version : les nœuds d'un cluster Kubernetes économisent alors du disque, du réseau, et du temps de démarrage.

Tirez-la une seconde fois :

```bash
docker pull redis:8.8-alpine
```

```sortie
8.8-alpine: Pulling from library/redis
Digest: sha256:0b2b77d3ea5078274795e3177cdbdada8b96316684a38911d528534ed679b5ec
Status: Image is up to date for redis:8.8-alpine
docker.io/library/redis:8.8-alpine
```

Docker a demandé au registre ce que désigne `redis:8.8-alpine`, a reçu la même empreinte que la dernière fois, et n'a rien téléchargé. Cette vérification coûte une requête, ce qui a son importance avec Docker Hub, comme on le verra plus bas.

## Du nom d'une image aux octets

Le nom `nginx:1.30-alpine` est un raccourci. Le nom complet est `docker.io/library/nginx:1.30-alpine`, et chaque morceau a un sens.

<Figure svg={imageNomVersCouches} num="3.2" alt="Le nom docker.io/library/nginx:1.30-alpine se décompose en registre, dépôt et étiquette. Le registre résout l'étiquette en un index, qui liste une variante par plateforme. Docker choisit le manifeste linux/amd64, qui désigne une configuration et huit couches compressées, chacune nommée par son empreinte.">
Du nom d'une image aux octets qu'on télécharge. Chaque flèche suit une empreinte : à partir de l'index, tout est désigné par le contenu.
</Figure>

`docker.io` est le **registre**, le serveur qui stocke les images ; c'est celui de Docker Hub, que Docker utilise quand le nom n'en précise aucun. `library/nginx` est le **dépôt**, où `library` est l'espace réservé aux images officielles, celles qu'on appelle sans préfixe. `1.30-alpine` est l'**étiquette** (*tag*), un nom lisible qui désigne une version. D'autres registres suivent la même forme : `registry.k8s.io/pause:3.10.2` pour les images de Kubernetes, `ghcr.io/headlamp-k8s/headlamp` sur le registre de GitHub, `quay.io` chez Red Hat.

Quand Docker tire une image, il suit ensuite une chaîne de documents[^oci-image]. L'étiquette ne désigne pas directement des fichiers, mais un **index**, qui liste les variantes de l'image, une par plateforme. `docker buildx imagetools inspect` l'affiche :

```bash
docker buildx imagetools inspect nginx:1.30-alpine
```

```sortie
Name:      docker.io/library/nginx:1.30-alpine
MediaType: application/vnd.oci.image.index.v1+json
Digest:    sha256:985220252f3863977e468f611ef118ebd01421289dd86ee1ae99cb068c3bce2b

Manifests:
  Name:        docker.io/library/nginx:1.30-alpine@sha256:8f84ed99befc3891b8f329c5c202785278a2cfb7c25107d57fb2a134a3117433
  MediaType:   application/vnd.oci.image.manifest.v1+json
  Platform:    linux/amd64
  Annotations:
    org.opencontainers.image.base.name:       nginx:1.30.5-alpine-slim
    org.opencontainers.image.created:         2026-09-22T22:10:28Z
    org.opencontainers.image.source:          https://github.com/nginx/docker-nginx.git#a16f1329e13e...:stable/alpine
    org.opencontainers.image.version:         1.30.5-alpine
    ...

  Name:        docker.io/library/nginx:1.30-alpine@sha256:b22e4d863c9a375073cfa364da833328ffd03389cda70b89517b43f14b094c75
  MediaType:   application/vnd.oci.image.manifest.v1+json
  Platform:    unknown/unknown
  Annotations:
    vnd.docker.reference.digest:              sha256:8f84ed99befc3891b8f329c5c202785278a2cfb7c25107d57fb2a134a3117433
    vnd.docker.reference.type:                attestation-manifest
  ...
```

La sortie complète liste seize manifestes. Huit correspondent à de vraies plateformes : `linux/amd64`, `linux/arm64/v8`, `linux/arm/v6`, `linux/arm/v7`, `linux/386`, `linux/ppc64le`, `linux/riscv64` et `linux/s390x`. Les huit autres, marqués `unknown/unknown`, sont des **attestations** : des documents joints à chaque variante qui décrivent comment elle a été construite et ce qu'elle contient. Nous nous en servirons au chapitre 14 pour vérifier la provenance d'une image.

Docker choisit dans l'index le manifeste qui correspond à votre machine. C'est ce mécanisme qui fait qu'une même commande, `docker run nginx:1.30-alpine`, lance la version x86_64 sur votre portable et la version ARM sur un Mac récent ou un Raspberry Pi, et c'est lui qui a été contourné au chapitre 1 avec `--platform linux/arm64`. Le manifeste choisi désigne à son tour une configuration et une liste de couches, par leurs empreintes.

Remarquez les annotations `org.opencontainers.image.*`. Elles sont définies par l'OCI et permettent de remonter d'une image à son origine : la date de construction, le dépôt Git et le commit exact qui l'ont produite, et même l'image de base (`nginx:1.30.5-alpine-slim`). Nous en poserons sur les images de Colis.

## Étiquette ou empreinte

Une empreinte désigne un contenu de façon certaine : si un seul octet change, l'empreinte change. On peut tirer une image par son empreinte plutôt que par son étiquette :

```bash
docker image inspect nginx:1.30-alpine --format '{{json .RepoDigests}}'
docker pull nginx@sha256:985220252f3863977e468f611ef118ebd01421289dd86ee1ae99cb068c3bce2b
```

```sortie
["nginx@sha256:985220252f3863977e468f611ef118ebd01421289dd86ee1ae99cb068c3bce2b"]
docker.io/library/nginx@sha256:985220252f3863977e468f611ef118ebd01421289dd86ee1ae99cb068c3bce2b: Pulling from library/nginx
Digest: sha256:985220252f3863977e468f611ef118ebd01421289dd86ee1ae99cb068c3bce2b
Status: Image is up to date for nginx@sha256:985220252f3863977e468f611ef118ebd01421289dd86ee1ae99cb068c3bce2b
```

L'empreinte est celle de l'index : elle désigne toutes les plateformes à la fois. Une étiquette, elle, n'est qu'un pointeur que le propriétaire du dépôt peut déplacer quand il le veut. `nginx:1.30-alpine` désigne aujourd'hui nginx 1.30.5 ; quand la 1.30.6 sortira, les mainteneurs y déplaceront l'étiquette, et le même `docker pull` apportera une autre image. C'est souhaitable pour recevoir les correctifs de sécurité, et gênant quand on veut savoir exactement ce qui tourne en production.

L'étiquette `latest` pousse ce problème à l'extrême. Elle n'a rien de spécial pour Docker : c'est l'étiquette utilisée quand on n'en précise pas (`docker pull nginx` veut dire `docker pull nginx:latest`), et elle désigne ce que le propriétaire du dépôt a décidé d'y mettre, souvent la dernière version publiée. Un fichier de déploiement qui utilise `latest` peut faire tourner deux versions différentes sur deux machines, selon le jour où chacune a tiré l'image. Dans ce cours, on nomme toujours une version précise, et au chapitre 14 nous figerons les images de Colis par leur empreinte.

Enfin, une image stockée sur votre machine a un troisième identifiant, son `IMAGE ID`, que `docker image ls` affiche sous forme abrégée :

```bash
docker image inspect nginx:1.30-alpine --format '{{.Id}}'
```

```sortie
sha256:43d9d8c1f8968f09df8c1aa6c136ecc617e62d64fe4c0b24c97de4eb210bd973
```

Ce n'est ni l'empreinte de l'index (`985220...`) ni celle du manifeste (`8f84ed...`), mais celle du fichier de configuration. Nous allons le vérifier en déballant une image.

## Ouvrir une image

`docker save` écrit une image dans une archive tar, au format défini par l'OCI. Prenons la plus simple, Alpine :

```bash
docker save alpine:3.24 -o alpine.tar
tar -tvf alpine.tar
```

```sortie
drwxr-xr-x 0/0               0 2026-09-17 22:37 blobs/
drwxr-xr-x 0/0               0 1970-01-01 01:00 blobs/sha256/
-rw-r--r-- 0/0             611 2026-09-17 22:37 blobs/sha256/320994c3b997e2ec6433f717f153e108023c5bec8fefa8d76b83451d16d05ea8
-rw-r--r-- 0/0         8704000 2026-09-17 22:37 blobs/sha256/74d97c428c51a828f9051a7a40a53ff1fc99e54fc30323ce36760701b0b7f711
-rw-r--r-- 0/0             749 2026-09-17 22:37 blobs/sha256/9728182782ff20d93a9a7907f25f1f04afb5cef4961748acae08e9ad04996f20
-rw-r--r-- 0/0             400 1970-01-01 01:00 blobs/sha256/d1e016453729980e0d64c56e3c96789ee89b99987a868dba4161687bff68c044
-rw-r--r-- 0/0             358 1970-01-01 01:00 index.json
-rw-r--r-- 0/0             455 1970-01-01 01:00 manifest.json
-rw-r--r-- 0/0              31 1970-01-01 01:00 oci-layout
-rw-r--r-- 0/0              87 1970-01-01 01:00 repositories
```

Tout le contenu est rangé dans `blobs/sha256/`, et chaque fichier y porte pour nom sa propre empreinte : c'est ce qu'on appelle un stockage adressé par le contenu. Le fichier `oci-layout` annonce le format (`{"imageLayoutVersion": "1.0.0"}`) ; `manifest.json` et `repositories` sont là pour la compatibilité avec les anciennes versions de Docker. Déballons l'archive et suivons la chaîne, en partant de `index.json` :

```bash
mkdir alpine && tar -xf alpine.tar -C alpine && cd alpine
python3 -m json.tool index.json
```

```sortie
{
    "schemaVersion": 2,
    "mediaType": "application/vnd.oci.image.index.v1+json",
    "manifests": [
        {
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "digest": "sha256:d1e016453729980e0d64c56e3c96789ee89b99987a868dba4161687bff68c044",
            "size": 400,
            "annotations": {
                "io.containerd.image.name": "docker.io/library/alpine:3.24",
                "org.opencontainers.image.ref.name": "3.24"
            }
        }
    ]
}
```

L'index désigne un manifeste, le blob `d1e01645...`. Ouvrons-le :

```bash
python3 -m json.tool blobs/sha256/d1e016453729980e0d64c56e3c96789ee89b99987a868dba4161687bff68c044
```

```sortie
{
    "schemaVersion": 2,
    "mediaType": "application/vnd.oci.image.manifest.v1+json",
    "config": {
        "mediaType": "application/vnd.oci.image.config.v1+json",
        "digest": "sha256:320994c3b997e2ec6433f717f153e108023c5bec8fefa8d76b83451d16d05ea8",
        "size": 611
    },
    "layers": [
        {
            "mediaType": "application/vnd.oci.image.layer.v1.tar",
            "digest": "sha256:74d97c428c51a828f9051a7a40a53ff1fc99e54fc30323ce36760701b0b7f711",
            "size": 8704000
        }
    ]
}
```

Le manifeste désigne une configuration (`320994c3...`) et une couche (`74d97c42...`). Vous reconnaissez le début de l'empreinte de configuration : c'est l'`IMAGE ID` d'Alpine, `320994c3b997`, celui que `docker image ls` affiche. Ce fichier de configuration contient, entre autres, la commande par défaut et la liste des couches :

```sortie
{
  "architecture": "amd64",
  "os": "linux",
  "config": {
    "Env": [
      "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    ],
    "Cmd": [
      "/bin/sh"
    ],
    "WorkingDir": "/"
  },
  "rootfs": {
    "type": "layers",
    "diff_ids": [
      "sha256:74d97c428c51a828f9051a7a40a53ff1fc99e54fc30323ce36760701b0b7f711"
    ]
  }
}
```

Reste la couche elle-même. C'est une simple archive tar qui contient les fichiers d'Alpine :

```bash
tar -tf blobs/sha256/74d97c428c51a828f9051a7a40a53ff1fc99e54fc30323ce36760701b0b7f711 | wc -l
tar -tf blobs/sha256/74d97c428c51a828f9051a7a40a53ff1fc99e54fc30323ce36760701b0b7f711 | head -5
sha256sum blobs/sha256/74d97c428c51a828f9051a7a40a53ff1fc99e54fc30323ce36760701b0b7f711
```

```sortie
515
bin/
bin/arch
bin/ash
bin/base64
74d97c428c51a828f9051a7a40a53ff1fc99e54fc30323ce36760701b0b7f711  blobs/sha256/74d97c428c51a828f9051a7a40a53ff1fc99e54fc30323ce36760701b0b7f711
```

515 entrées, qui forment tout le système Alpine. La dernière commande boucle la boucle : l'empreinte SHA-256 du fichier est exactement son nom. Personne ne peut modifier une couche sans que son empreinte change, et donc sans que le manifeste qui la désigne ne devienne faux. C'est ce qui permet à Docker de vérifier chaque couche téléchargée, et de dire en toute confiance qu'une couche « existe déjà ».

:::info[Pourquoi deux empreintes pour une même couche ?]

Vous avez peut-être remarqué une incohérence. Au téléchargement, la couche de base d'Alpine s'appelait `e2de96513ba9` ; dans `docker image inspect` et dans l'archive, elle s'appelle `74d97c428c51`. C'est la même couche, sous deux formes. Dans un registre, les couches sont stockées compressées (tar.gz), et `e2de9651...` est l'empreinte de l'archive compressée. Une fois sur votre machine, Docker la décompresse, et `74d97c42...` est l'empreinte des octets décompressés, que la spécification OCI appelle `diff_id`. `docker save` écrit les couches décompressées, d'où le type `layer.v1.tar`, sans `+gzip`.

:::

## Les registres

Un registre est un serveur HTTP qui stocke des blobs et des manifestes, et qui répond à une API normalisée par l'OCI[^oci-distribution]. Le plus simple pour la comprendre est d'en faire tourner un. L'image officielle `registry:3` en fournit un complet. On le publie ici sur le port 5001, parce que le 5000 est souvent déjà pris :

```bash
docker run -d --name registre -p 5001:5000 registry:3
```

```sortie
Unable to find image 'registry:3' locally
3: Pulling from library/registry
e2de96513ba9: Already exists
90764beeca7f: Pull complete
2aef3a8beb68: Pull complete
783ed5b12fca: Pull complete
8dc2188d2a74: Pull complete
Digest: sha256:852b3e4d378c426dda6b318fe9d9bfe8e92a0eccb9926671ec3d3ea17a196696
Status: Downloaded newer image for registry:3
7c9bc3a264196b5356441ec38cb9fdaf9454403b36ccf6ba158e75697411807a
```

Le registre lui-même repose sur Alpine 3.24 : encore un `Already exists`. Pour pousser une image vers ce registre, il faut qu'elle porte un nom qui le désigne. `docker tag` ajoute un nom à une image existante, sans rien copier :

```bash
docker tag alpine:3.24 localhost:5001/cours/alpine:3.24
docker push localhost:5001/cours/alpine:3.24
```

```sortie
The push refers to repository [localhost:5001/cours/alpine]
74d97c428c51: Pushed
3.24: digest: sha256:7cefa58bd70cbf86bb0ef44b9c27a9c6a633763977ea40868d1bfe9278967b25 size: 527
```

Poussons maintenant nginx dans un autre dépôt du même registre :

```bash
docker tag nginx:1.30-alpine localhost:5001/cours/nginx:1.30-alpine
docker push localhost:5001/cours/nginx:1.30-alpine
```

```sortie
The push refers to repository [localhost:5001/cours/nginx]
ec2b9a359ab9: Pushed
0d250d8db7c2: Pushed
267e83adf4c4: Pushed
8fb5da5ad6fa: Pushed
74d97c428c51: Mounted from cours/alpine
ed752e851ebe: Pushed
2d3fbe0ca19d: Pushed
e46f4042ccf5: Pushed
1.30-alpine: digest: sha256:0abc90f14cff910302a259f648595d5e2e94e8f0aad4b48a5ed55f23d14d8694 size: 1989
```

Sept couches envoyées, et une « montée » : `Mounted from cours/alpine`. Le registre avait déjà la couche de base dans le dépôt `cours/alpine`, et Docker lui a demandé de la rattacher au dépôt `cours/nginx` plutôt que de la renvoyer. Le partage des couches ne s'arrête donc pas à votre disque : il vaut aussi entre les dépôts d'un registre.

L'empreinte obtenue, `0abc90f1...`, n'est pas celle de Docker Hub (`985220...`). Docker n'avait sur la machine que la variante `linux/amd64` de nginx ; il a poussé cette seule variante, avec un nouveau manifeste, et non l'index à huit plateformes. L'empreinte d'un manifeste dépend de son contenu, et le contenu a changé.

L'API du registre se lit avec `curl`. Elle liste les dépôts, les étiquettes d'un dépôt, et renvoie un manifeste :

```bash
curl -s http://localhost:5001/v2/_catalog
curl -s http://localhost:5001/v2/cours/nginx/tags/list
curl -s -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
     http://localhost:5001/v2/cours/nginx/manifests/1.30-alpine | python3 -m json.tool | head -15
```

```sortie
{"repositories":["cours/alpine","cours/nginx"]}
{"name":"cours/nginx","tags":["1.30-alpine"]}
{
    "schemaVersion": 2,
    "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
    "config": {
        "mediaType": "application/vnd.docker.container.image.v1+json",
        "size": 12296,
        "digest": "sha256:43d9d8c1f8968f09df8c1aa6c136ecc617e62d64fe4c0b24c97de4eb210bd973"
    },
    "layers": [
        {
            "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
            "size": 3849738,
            "digest": "sha256:e2de96513ba9eb53b431787ec8a65cdde380ac4772a3e4c4b714dcfde2a102b5"
        },
```

Tout y est : la configuration `43d9d8c1...` (l'`IMAGE ID` de nginx), et les couches compressées, dont la première, `e2de9651...`, pèse 3,8 Mo une fois compressée contre 8,7 Mo décompressée. Le type de document est ici celui de Docker (`vnd.docker.distribution.manifest.v2`) plutôt que celui de l'OCI ; les deux formats ont la même structure, et les registres comme les outils acceptent l'un et l'autre.

Pour boucler le trajet, supprimons les noms locaux et tirons l'image depuis notre registre :

```bash
docker image rm localhost:5001/cours/alpine:3.24 localhost:5001/cours/nginx:1.30-alpine
docker pull localhost:5001/cours/nginx:1.30-alpine
```

```sortie
Untagged: localhost:5001/cours/alpine:3.24
Untagged: localhost:5001/cours/alpine@sha256:7cefa58bd70cbf86bb0ef44b9c27a9c6a633763977ea40868d1bfe9278967b25
Untagged: localhost:5001/cours/nginx:1.30-alpine
Untagged: localhost:5001/cours/nginx@sha256:0abc90f14cff910302a259f648595d5e2e94e8f0aad4b48a5ed55f23d14d8694
1.30-alpine: Pulling from cours/nginx
Digest: sha256:0abc90f14cff910302a259f648595d5e2e94e8f0aad4b48a5ed55f23d14d8694
Status: Downloaded newer image for localhost:5001/cours/nginx:1.30-alpine
localhost:5001/cours/nginx:1.30-alpine
```

`docker image rm` n'a supprimé que des noms (`Untagged`) : les couches sont toujours utilisées par `nginx:1.30-alpine` et `alpine:3.24`. Le `pull` suivant n'a donc rien eu à télécharger, et s'est contenté d'ajouter le nom.

:::note[Un registre sans chiffrement]

Docker accepte de parler en HTTP simple à un registre sur `localhost`, et le refuse pour toute autre adresse : un registre doit normalement être servi en HTTPS. Pour utiliser ce registre depuis une autre machine, il faudrait lui donner un certificat, ou déclarer l'adresse comme « registre non sécurisé » dans la configuration du démon. Nous y reviendrons au chapitre 24, quand le cluster minikube devra tirer les images de Colis.

:::

### Docker Hub et ses limites

Docker Hub est gratuit, mais pas illimité. Un utilisateur non connecté a droit à 100 téléchargements par période de 6 heures, comptés par adresse IPv4 (ou par sous-réseau IPv6 /64) ; un compte personnel gratuit, connecté avec `docker login`, en a 200[^hub-limits]. La limite paraît large jusqu'au jour où une salle de TP entière, derrière une seule adresse IP, lance le même `docker compose up`, ou jusqu'à ce qu'un cluster de dix nœuds redémarre. Le message est alors `toomanyrequests: You have reached your pull rate limit`. Les parades sont de se connecter, de garder un cache local des images (un registre miroir), ou d'utiliser d'autres registres pour les images qui y sont publiées.

## Faire le ménage

Les images s'accumulent vite. `docker system df` fait le bilan de ce que Docker occupe sur le disque :

```bash
docker system df
```

```sortie
TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
Images          36        5         8.455GB   3.358GB (39%)
Containers      7         6         3.327MB   3.327MB (100%)
Local Volumes   9         7         7.149GB   72.38MB (1%)
Build Cache     208       0         10.93GB   7.214GB
```

Sur le poste qui a servi à écrire ce cours, et qui sert à bien d'autres projets, les images occupent 8,5 Go, dont 3,4 Go récupérables parce qu'aucun conteneur ne les utilise. Le cache de construction, que nous rencontrerons au chapitre 4, en occupe presque 11. Pour supprimer une image précise, utilisez `docker image rm` avec son nom. Docker refuse si un conteneur, même arrêté, l'utilise encore.

:::danger[Les commandes prune agissent sur toute la machine]

`docker image prune -a`, `docker system prune` et leurs variantes suppriment tout ce qui n'est pas utilisé à l'instant, sur toute la machine : les images de vos autres projets, leurs caches de construction et, avec `--volumes`, leurs données. Elles sont pratiques sur une machine jetable, dangereuses sur un poste de travail. Supprimez ce que vous avez créé, par son nom.

:::

## Exercices

:::exercice[Exercice 1 : lire une image]

Sans lancer de conteneur, trouvez combien de couches compte l'image `python:3.14-slim`, quelle commande elle exécute par défaut, et quelle version exacte de Python elle contient.

:::

<details>
<summary>Corrigé</summary>

```bash
docker image inspect python:3.14-slim --format '{{len .RootFS.Layers}} couches ; Cmd={{json .Config.Cmd}}'
docker image inspect python:3.14-slim --format '{{range .Config.Env}}{{println .}}{{end}}'
```

```sortie
4 couches ; Cmd=["python3"]
PATH=/usr/local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PYTHON_VERSION=3.14.7
PYTHON_SHA256=3b48dac8fb59f62eaa67ac83c1eb12bda1b7a08406dd286e252c11a66be27f81
```

L'image lance l'interpréteur Python si on ne lui donne pas de commande, et ses mainteneurs ont laissé la version dans une variable d'environnement, ce qui est courant. `docker image history python:3.14-slim` montre en plus comment chaque couche a été construite.

</details>

:::exercice[Exercice 2 : figer une image]

Trouvez l'empreinte de votre image `alpine:3.24`, puis lancez un conteneur en désignant l'image par cette empreinte plutôt que par son étiquette. Dans quelle situation cette façon de faire est-elle préférable ?

:::

<details>
<summary>Corrigé</summary>

```bash
docker image inspect alpine:3.24 --format '{{index .RepoDigests 0}}'
docker run --rm alpine@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6 cat /etc/alpine-release
```

La première commande affiche `alpine@sha256:294b683c...` sur le poste du cours ; le conteneur lancé avec cette référence affiche `3.24.2`. Une empreinte désigne toujours le même contenu, alors qu'une étiquette peut être déplacée. On fige par empreinte ce qui doit être reproductible et vérifiable : un déploiement en production, une chaîne d'intégration continue, une image dont on a vérifié la signature (chapitre 14).

</details>

:::exercice[Exercice 3 : une image pour plusieurs systèmes]

Pour quelles plateformes l'image `registry.k8s.io/pause:3.10.2` existe-t-elle ? Que vous apprend la réponse sur la notion de plateforme ?

:::

<details>
<summary>Corrigé</summary>

```bash
docker buildx imagetools inspect registry.k8s.io/pause:3.10.2 | grep Platform
```

On obtient `linux/amd64`, `linux/arm64`, `linux/arm/v7`, `linux/ppc64le`, `linux/s390x`, et trois variantes `windows/amd64`. Une plateforme combine un système d'exploitation et une architecture de processeur. L'image `pause`, qu'on retrouvera dans chaque Pod Kubernetes (chapitre 38), existe aussi pour Windows, parce que Kubernetes sait gérer des nœuds Windows. Les trois variantes Windows correspondent à différentes versions de Windows Server : un conteneur Windows doit correspondre à la version du noyau de l'hôte, une contrainte que les conteneurs Linux n'ont pas.

</details>

:::exercice[Exercice 4 : prévoir un téléchargement]

L'index de `nginx:1.30-alpine` indique que son image de base est `nginx:1.30.5-alpine-slim`. Avant de la tirer, prévoyez combien de couches Docker devra télécharger. Vérifiez, puis comparez la taille des deux images.

:::

<details>
<summary>Corrigé</summary>

```bash
docker pull nginx:1.30.5-alpine-slim
docker image ls --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep '^nginx:'
```

```sortie
1.30.5-alpine-slim: Pulling from library/nginx
e2de96513ba9: Already exists
e3320d02d578: Already exists
3d85d110b167: Already exists
22e5a8a110ec: Already exists
6b4dfb2e8f8a: Already exists
703c5424632f: Already exists
b335b7ac3a40: Already exists
Digest: sha256:32463212baf0e7d91aded2e9b843a4f2b9e017804b8c9d5bae7b51dcef64389c
Status: Downloaded newer image for nginx:1.30.5-alpine-slim
nginx:1.30-alpine 62.4MB
nginx:1.30.5-alpine-slim 12.7MB
```

Aucune. Les sept couches de l'image `slim` sont les sept premières de `nginx:1.30-alpine`, déjà présentes. La version complète n'ajoute qu'une couche, celle de 49,7 Mo vue dans `docker image history`, qui installe les modules supplémentaires de nginx. La version `slim` pèse cinq fois moins, et suffit si vous n'avez besoin que de servir des fichiers.

</details>

## Nettoyer

Arrêtez le registre et supprimez les fichiers déballés :

```bash
docker rm -f registre
docker image rm nginx:1.30.5-alpine-slim registry.k8s.io/pause:3.10.2
cd .. && rm -r alpine alpine.tar
```

Gardez `nginx:1.30-alpine`, `alpine:3.24`, `python:3.14-slim`, `redis:8.8-alpine` et `registry:3`, qui resserviront.

[^oci-image]: Open Container Initiative, *Image Format Specification*, en particulier les documents *Image Index*, *Image Manifest* et *Image Configuration*. [github.com/opencontainers/image-spec](https://github.com/opencontainers/image-spec)

[^oci-distribution]: Open Container Initiative, *Distribution Specification*, qui décrit l'API HTTP des registres. [github.com/opencontainers/distribution-spec](https://github.com/opencontainers/distribution-spec)

[^hub-limits]: Docker, « Docker Hub usage and limits », section *Pull rate limit*. [docs.docker.com/docker-hub/usage/pulls](https://docs.docker.com/docker-hub/usage/pulls/)
