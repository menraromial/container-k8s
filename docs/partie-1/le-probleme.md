---
title: Le problème que résolvent les conteneurs
sidebar_label: 1. Le problème
description: Pourquoi une application qui fonctionne sur une machine casse sur une autre, ce qu'est réellement un conteneur, d'où il vient et ce qu'il ne résout pas.
partie: 1
chapitre: '1'
---

import vmVsConteneur from '@site/src/figures/vm-vs-conteneur.svg';

L'API de Colis tourne sur le poste qui a servi à écrire ce cours. Imaginons qu'on veuille l'installer sur un serveur plus ancien, une Debian dont le Python est en version 3.9. On copie le code, on lance l'installation des dépendances comme on le ferait sur son poste, et voici ce qu'on obtient :

```sortie
ERROR: Ignored the following versions that require a different python version: 0.129.0 Requires-Python >=3.10; ...
ERROR: Could not find a version that satisfies the requirement fastapi==0.141.1 (from versions: 0.1.0, 0.1.2, ...)
ERROR: No matching distribution found for fastapi==0.141.1
```

Le message est long mais son sens est clair : la version de FastAPI dont Colis a besoin exige Python 3.10 ou plus récent, et ce serveur n'a que 3.9. Le code est bon, le serveur est en état de marche, et pourtant l'application ne peut pas s'installer. Ce chapitre explique d'où vient ce genre de problème, comment les conteneurs le résolvent, et ce qu'est réellement un conteneur. Il se termine sur ce qu'ils ne résolvent pas, parce que c'est ce qui vous évitera les mauvaises surprises.

## Une application ne vient jamais seule

Le code de l'API de Colis tient en quelques centaines de lignes. Pour qu'il tourne, il lui faut pourtant bien davantage : un interpréteur Python d'une version précise ; les bibliothèques FastAPI, Uvicorn, psycopg et redis, chacune dans une version compatible avec les autres ; et, sous elles, des bibliothèques du système, comme la bibliothèque C ou celle qui chiffre les connexions TLS. Chacun de ces éléments est une dépendance, et chacun peut différer d'une machine à l'autre.

L'erreur ci-dessus est le cas favorable : elle est bruyante, elle arrive tout de suite, elle dit ce qui manque. Les cas difficiles sont ceux où tout s'installe et où le comportement change en silence. Une bibliothèque système légèrement différente arrondit un calcul autrement. Le serveur est réglé sur un autre fuseau horaire, et les dates de livraison sont décalées d'un jour. Une variable d'environnement présente sur le poste du développeur manque en production. Aucun message d'erreur, juste une application qui se comporte autrement qu'en test.

Le problème s'aggrave dès que plusieurs applications partagent une machine. Supposons que le même serveur héberge aussi un vieil outil interne qui ne fonctionne qu'avec Python 3.9. Mettre Python à jour pour Colis casserait l'outil ; ne pas le faire bloque Colis. On peut s'en sortir avec des environnements virtuels et plusieurs versions de Python installées côte à côte, au prix d'une configuration que personne n'a envie de maintenir.

## Trois façons de livrer une application

Pendant longtemps, la réponse a été la procédure d'installation : un document qui liste tout ce qu'il faut mettre sur le serveur, dans quel ordre, avec quels réglages. Elle a deux défauts. Elle suppose que le serveur ressemble à celui sur lequel on l'a écrite, et elle vieillit mal : une mise à jour de la distribution suffit à la rendre fausse.

La deuxième réponse a été la machine virtuelle. Au lieu de décrire comment préparer le serveur, on livre le serveur lui-même : un disque virtuel qui contient un système d'exploitation complet, déjà configuré, avec l'application installée. Un hyperviseur (KVM, VMware, VirtualBox) fait tourner ce système invité comme s'il disposait de sa propre machine. Tout ce dont l'application a besoin voyage avec elle, noyau compris. C'est efficace, mais lourd : chaque machine virtuelle démarre un système complet, occupe plusieurs gigaoctets de disque et réserve sa propre mémoire.

Les conteneurs sont la troisième réponse. Ils gardent l'idée d'emporter avec l'application tout ce dont elle a besoin (l'interpréteur, les bibliothèques, les fichiers de configuration), mais ils laissent de côté ce qui est commun à toutes les applications d'une machine : le noyau.

<Figure svg={vmVsConteneur} num="1.1" alt="Deux piles côte à côte. Machines virtuelles : chaque machine contient son noyau invité, un système complet, Python et l'application, au-dessus d'un hyperviseur. Conteneurs : chaque conteneur ne contient que Python et l'application, au-dessus d'un moteur de conteneurs et d'un seul noyau partagé.">
Ce qui est dupliqué et ce qui est partagé. Une machine virtuelle emporte un noyau et un système complet ; un conteneur n'emporte que ce qui est propre à l'application, et partage le noyau de la machine.
</Figure>

Sur la figure, les deux applications de gauche démarrent chacune un noyau et un système d'exploitation. À droite, elles n'emportent que leur version de Python et leurs bibliothèques, et tournent toutes deux sur le même noyau. C'est ce qui permet de faire coexister Python 3.14 et Python 3.9 sur une même machine sans aucun conflit :

```bash
docker run --rm python:3.14-slim python --version
docker run --rm python:3.9-slim python --version
```

```sortie
Python 3.14.7
Python 3.9.25
```

Deux commandes, deux versions de Python, et rien d'installé sur votre système : chacune vit dans son image. L'image `python:3.14-slim` contient un système Debian minimal et l'interpréteur Python ; `python:3.9-slim` contient la même chose avec un interpréteur plus ancien. Le chapitre 3 explique ce que contient exactement une image et comment elle arrive sur votre machine.

## Un conteneur est un processus

Tout ce qui précède pourrait laisser croire qu'un conteneur est une petite machine virtuelle. Ce n'en est pas une, et quelques expériences suffisent à le montrer.

Commençons par le noyau. Le poste du cours est une Ubuntu 26.04 dont le noyau est en version 7.0.0. Lançons trois conteneurs issus de trois distributions différentes, et demandons à chacun le nom de son système et la version de son noyau :

```bash
for image in alpine:3.24 debian:13 fedora:43; do
  docker run --rm $image sh -c 'grep PRETTY_NAME /etc/os-release; uname -r'
done
```

```sortie
PRETTY_NAME="Alpine Linux v3.24"
7.0.0-34-generic
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
7.0.0-34-generic
PRETTY_NAME="Fedora Linux 43 (Container Image)"
7.0.0-34-generic
```

Chaque conteneur voit les fichiers de sa propre distribution : `/etc/os-release` y dit Alpine, Debian ou Fedora. Mais le noyau est toujours le même, `7.0.0-34-generic`, celui de la machine. Il n'y a pas de noyau Alpine ni de noyau Fedora ici : il n'y a que le noyau d'Ubuntu, qui montre à chaque conteneur un jeu de fichiers différent.

Deuxième expérience : lançons un conteneur qui ne fait rien d'autre que dormir cinq minutes, et cherchons-le depuis le poste avec la commande `ps`, qui liste les processus du système.

```bash
docker run -d --name dormeur alpine:3.24 sleep 300
ps -o pid,user,etime,cmd -C sleep
```

```sortie
a168bfc099615ac103117d15b63e1b993f0da1dae0908df5e3fba905ae938854
    PID USER         ELAPSED CMD
 264821 root           00:00 sleep 300
```

La première ligne est l'identifiant du conteneur, que Docker affiche quand on lance un conteneur en arrière-plan (option `-d`). La suite est la réponse de `ps` : le processus `sleep 300` est là, sur votre machine, avec le numéro 264821. Posons maintenant la même question depuis l'intérieur du conteneur :

```bash
docker exec dormeur ps
```

```sortie
PID   USER     TIME  COMMAND
    1 root      0:00 sleep 300
    7 root      0:00 ps
```

Vu de l'intérieur, le même processus porte le numéro 1, et il est presque seul : le conteneur ne voit que ses propres processus, pas les centaines d'autres qui tournent sur la machine. C'est le même programme, dans le même noyau, mais le noyau lui présente une vue restreinte du système. Un conteneur, c'est exactement cela : **un processus ordinaire, auquel le noyau montre ses propres fichiers, ses propres processus et son propre réseau, et dont il limite la consommation de ressources.**

Cette définition explique les deux chiffres qui ont fait le succès des conteneurs. Le premier est le temps de démarrage. Lancer un conteneur, c'est lancer un processus, pas démarrer un système :

```bash
time docker run --rm alpine:3.24 true
```

Sur le poste du cours, trois essais successifs ont mesuré 0,45 s, 0,45 s et 0,48 s, du moment où l'on appuie sur Entrée jusqu'à la suppression du conteneur. La commande `true` ne fait rien et se termine aussitôt ; tout ce temps est celui de Docker, qui prépare le conteneur, le lance et le nettoie.

Le second chiffre est la taille. Une image n'a pas besoin de contenir de noyau, ni tout ce qu'il faut pour démarrer une machine :

```bash
docker image ls --format '{{.Repository}}:{{.Tag}}  {{.Size}}'
```

```sortie
python:3.14-slim  120MB
debian:13  120MB
alpine:3.24  8.42MB
fedora:43  181MB
python:3.9-slim  122MB
```

L'image Alpine complète pèse 8,4 Mo. Celle de Python, système Debian compris, en pèse 120. À titre de comparaison, une machine virtuelle Debian minimale occupe couramment plusieurs gigaoctets de disque une fois installée.

Retirons le dormeur avant de continuer :

```bash
docker rm -f dormeur
```

## Ce que le noyau fournit

Si un conteneur est un processus ordinaire, qu'est-ce qui l'isole des autres ? Trois mécanismes du noyau Linux, que la partie II démonte un par un.

Les **namespaces** (espaces de noms) donnent à un processus sa propre vue d'une ressource du système. Il en existe un pour les numéros de processus (c'est lui qui fait de `sleep` le processus numéro 1 dans le conteneur), un pour les points de montage, un pour le réseau, un pour le nom de la machine, et quelques autres[^namespaces]. Le chapitre 8 construit un conteneur à la main en les combinant.

Les **cgroups** (groupes de contrôle) limitent et mesurent ce qu'un groupe de processus consomme : mémoire, temps de processeur, lectures et écritures sur le disque. Ce sont eux qui ont plafonné le cluster minikube à 4 Go au chapitre 0.2, et ce sont eux qui tuent un conteneur qui dépasse sa limite de mémoire. Chapitre 9.

Le **système de fichiers en couches** assemble les fichiers d'une image à partir de plusieurs couches empilées, et ajoute au-dessus une couche modifiable propre à chaque conteneur. C'est grâce à lui que cent conteneurs issus de la même image ne dupliquent pas cent fois ses fichiers. Chapitre 10.

Aucun de ces mécanismes n'a été inventé pour Docker. Docker les a assemblés et rendus faciles à utiliser, ce qui est une contribution d'un autre ordre, mais tout aussi importante.

## Une courte histoire

L'idée d'enfermer un processus dans une vue restreinte du système est bien plus ancienne que Docker.

| Année | Étape | Ce qu'elle apporte |
|---|---|---|
| 1979 | `chroot`, Unix version 7 | un processus voit un dossier comme la racine du système de fichiers |
| 2000 | *jails* de FreeBSD | chroot étendu aux processus, au réseau et aux utilisateurs[^jails] |
| 2004 | *zones* de Solaris | des environnements isolés sur un même noyau, pour consolider des serveurs[^zones] |
| 2002 à 2013 | namespaces de Linux | du namespace de montage (2002) à celui des utilisateurs (2013)[^namespaces] |
| 2008 | cgroups dans Linux 2.6.24 | proposés par des ingénieurs de Google pour limiter des groupes de processus[^cgroups] |
| 2008 | LXC | les premiers outils pour créer des conteneurs Linux complets |
| 2013 | Docker | un format d'image et une commande qui rendent les conteneurs accessibles à tous[^docker2013] |
| 2015 | Open Container Initiative | des standards ouverts pour les images et leur exécution[^oci] |

L'apport décisif de Docker, présenté pour la première fois en mars 2013 lors d'une courte intervention à la conférence PyCon, n'est pas l'isolation : LXC la fournissait déjà. C'est l'image. Docker a défini un format qui empaquette une application et toutes ses dépendances dans un objet qu'on construit une fois, qu'on stocke dans un registre, et qu'on lance à l'identique sur n'importe quelle machine. En 2015, Docker et d'autres acteurs ont confié ce format à l'Open Container Initiative (OCI), qui en a fait un standard. C'est pour cela qu'une image construite avec Docker tourne sans modification avec Podman, avec containerd ou dans Kubernetes.

## Ce que les conteneurs ne résolvent pas

Parce qu'un conteneur partage le noyau de la machine, trois limites en découlent.

La première tient au noyau et au processeur. Un conteneur Linux a besoin d'un noyau Linux : c'est pourquoi Docker Desktop, sous Windows et macOS, fait tourner une machine virtuelle Linux cachée. De même, un programme compilé pour un processeur ARM ne s'exécute pas sur un processeur Intel ou AMD. Essayons de lancer la variante ARM 64 bits d'Alpine sur le poste du cours, qui est un x86_64 :

```bash
docker run --rm --platform linux/arm64 alpine:3.24 uname -m
```

```sortie
exec /bin/uname: exec format error
```

Le noyau refuse d'exécuter le fichier : son format ne correspond pas au processeur. Les images publiées sur les registres existent souvent en plusieurs variantes, une par architecture, et Docker choisit automatiquement celle qui convient à votre machine ; le chapitre 3 montre comment. Il est possible d'émuler un autre processeur avec QEMU, au prix d'une forte lenteur ; nous le ferons au chapitre 13 pour construire des images multi-architectures.

:::panne[exec format error sur une image qui fonctionnait]

L'expérience ci-dessus a un effet de bord. Avec le stockage d'images classique de Docker, télécharger la variante `linux/arm64` d'`alpine:3.24` remplace sur votre machine l'image locale qui portait ce nom. Juste après, un simple `docker run --rm alpine:3.24 uname -m` échoue avec la même erreur, alors qu'il fonctionnait une minute plus tôt. `docker image inspect alpine:3.24 --format '{{.Architecture}}'` répond alors `arm64`. Pour revenir à la variante de votre machine :

```bash
docker pull --platform linux/amd64 alpine:3.24
```

:::

La deuxième limite concerne la sécurité. Tous les conteneurs d'une machine partagent le même noyau : une faille dans ce noyau, ou dans le logiciel qui crée les conteneurs, peut permettre à un processus de sortir du sien. En février 2019, la faille CVE-2019-5736 a montré qu'un conteneur malveillant pouvait remplacer le programme `runc`, utilisé par Docker pour créer les conteneurs, et obtenir ainsi les droits de `root` sur la machine hôte[^runc-cve]. Une machine virtuelle, qui a son propre noyau, offre une frontière plus épaisse. Cela ne rend pas les conteneurs dangereux, mais cela veut dire qu'on ne fait pas tourner côte à côte, sans précautions, des conteneurs de clients qui ne se font pas confiance. Le chapitre 12 est consacré à ces précautions.

La troisième limite est d'organisation. Un conteneur est fait pour être jeté et remplacé : ce qu'il écrit dans ses propres fichiers disparaît avec lui. Garder des données demande un mécanisme dédié, les volumes (chapitre 5). Et un conteneur tourne sur une seule machine : le répartir sur plusieurs, le relancer quand la machine tombe, le mettre à jour sans interruption, c'est un autre problème, celui que Kubernetes résout à partir de la partie III.

## Docker, et les autres

Le mot « Docker » désigne plusieurs choses, et la confusion est fréquente. Il y a Docker Engine, le moteur que vous avez installé au chapitre 0.2 : un démon, `dockerd`, et le client `docker`. Il y a Docker Hub, le registre public où sont publiées les images comme `alpine` ou `python`. Et il y a Docker, l'entreprise qui édite ces outils.

Sous Docker Engine se trouvent deux composants que vous croiserez souvent. containerd gère les images et le cycle de vie des conteneurs ; c'est lui qui tourne dans le nœud minikube. runc est le petit programme qui crée effectivement un conteneur en appelant le noyau, puis s'efface. Le chapitre 11 démonte cette pile.

Podman est une alternative à Docker développée par Red Hat. Il se passe de démon et fonctionne sans droits d'administration, mais ses commandes reprennent celles de Docker presque à l'identique. Grâce aux standards de l'OCI, les images sont les mêmes pour tous ces outils : ce que vous construirez avec Docker dans cette partie tournera tel quel dans Kubernetes.

## Exercices

:::exercice[Exercice 1 : le noyau de votre machine]

Lancez `uname -r` sur votre poste, puis dans un conteneur `debian:13` et dans un conteneur `alpine:3.24`. Que constatez-vous ? Pourquoi un conteneur `debian:13` sur un poste Fedora ne voit-il pas un noyau Debian ?

:::

<details>
<summary>Corrigé</summary>

Les trois commandes affichent la même version, celle du noyau de votre poste. Une image ne contient pas de noyau : elle ne contient que des fichiers (programmes, bibliothèques, configuration). Quand le conteneur démarre, ses processus sont exécutés par le noyau de la machine, quel que soit le système dont viennent ces fichiers. « Un conteneur Debian » veut donc dire « un processus qui voit les fichiers d'une Debian », pas « une machine Debian ».

</details>

:::exercice[Exercice 2 : combien de processus ?]

Comptez les processus visibles sur votre poste (`ps -e | wc -l`), puis dans un conteneur Alpine (`docker run --rm alpine:3.24 ps`). Comment expliquer la différence, si le conteneur tourne sur la même machine ?

:::

<details>
<summary>Corrigé</summary>

Sur le poste du cours, `ps -e | wc -l` compte 630 processus. Le conteneur, lui, n'en montre qu'un :

```sortie
PID   USER     TIME  COMMAND
    1 root      0:00 ps
```

`ps` est le seul programme lancé dans ce conteneur, il en est donc le processus principal et porte le numéro 1. Les 630 processus du poste existent toujours, mais le conteneur a son propre namespace de PID : le noyau ne lui montre que les processus créés à l'intérieur. C'est le sujet du chapitre 8.

</details>

:::exercice[Exercice 3 : deux Python, aucune installation]

Sans rien installer sur votre machine, exécutez la commande Python `import sys; print(sys.version)` avec Python 3.9, puis avec Python 3.14. Vérifiez ensuite que votre poste n'a gagné aucun nouveau Python (`which -a python3.9`).

:::

<details>
<summary>Corrigé</summary>

```bash
docker run --rm python:3.9-slim python -c 'import sys; print(sys.version)'
docker run --rm python:3.14-slim python -c 'import sys; print(sys.version)'
which -a python3.9
```

Les deux premières commandes affichent la version complète de chaque interpréteur. La troisième ne trouve rien (sauf si Python 3.9 était déjà installé sur votre poste) : les interpréteurs vivent dans les images, pas dans votre système. C'est exactement ce qui aurait permis de faire tourner Colis sur le vieux serveur du début du chapitre.

</details>

:::exercice[Exercice 4 : une image pour un autre processeur]

Quelle est l'architecture de votre processeur (`uname -m`) ? Lancez `docker run --rm --platform linux/arm64 alpine:3.24 uname -m` (ou `linux/amd64` si votre machine est un ARM). Expliquez le résultat, puis remettez votre image `alpine:3.24` dans l'état initial.

:::

<details>
<summary>Corrigé</summary>

Sur un processeur x86_64, la commande échoue avec `exec format error` : le programme `uname` de cette image est compilé pour ARM, et le noyau ne sait pas l'exécuter. Si elle affiche `aarch64`, c'est que votre machine a un émulateur QEMU enregistré dans le noyau (`ls /proc/sys/fs/binfmt_misc/` montre alors une entrée `qemu-aarch64`) : le programme ARM est traduit instruction par instruction, ce qui marche mais lentement. Dans les deux cas, remettez la bonne variante avec `docker pull --platform linux/amd64 alpine:3.24` (ou `linux/arm64` sur un Mac récent).

</details>

## Nettoyer

Les images `debian:13`, `fedora:43` et `python:3.9-slim` ne serviront plus. Gardez `alpine:3.24` et `python:3.14-slim`, que les chapitres suivants utilisent :

```bash
docker image rm debian:13 fedora:43 python:3.9-slim
```

[^namespaces]: Linux man-pages, `namespaces(7)`, sections *Namespace types* et historique des versions du noyau. [man7.org/linux/man-pages/man7/namespaces.7.html](https://man7.org/linux/man-pages/man7/namespaces.7.html)

[^jails]: Poul-Henning Kamp, Robert N. M. Watson, « Jails: Confining the omnipotent root », *2nd International SANE Conference*, 2000. [papers.freebsd.org/2000/phk-jails](https://papers.freebsd.org/2000/phk-jails/)

[^zones]: Daniel Price, Andrew Tucker, « Solaris Zones: Operating System Support for Consolidating Commercial Workloads », *LISA 2004*, USENIX. [usenix.org/legacy/event/lisa04/tech/price.html](https://www.usenix.org/legacy/event/lisa04/tech/price.html)

[^cgroups]: Jonathan Corbet, « Process containers », *LWN.net*, 29 mai 2007 ; les cgroups sont entrés dans Linux 2.6.24 en janvier 2008. [lwn.net/Articles/236038](https://lwn.net/Articles/236038/)

[^docker2013]: Solomon Hykes, « The future of Linux Containers », intervention éclair à PyCon US, mars 2013. [youtube.com/watch?v=wW9CAH9nSLs](https://www.youtube.com/watch?v=wW9CAH9nSLs)

[^oci]: Open Container Initiative, « About the OCI ». [opencontainers.org/about/overview](https://opencontainers.org/about/overview/)

[^runc-cve]: NIST, National Vulnerability Database, CVE-2019-5736. [nvd.nist.gov/vuln/detail/CVE-2019-5736](https://nvd.nist.gov/vuln/detail/CVE-2019-5736)
