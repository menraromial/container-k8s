---
title: Les données
sidebar_label: 5. Les données
description: Ce qu'un conteneur écrit et ce qui en reste ; les volumes, les montages liés et les tmpfs ; PostgreSQL et ses données ; sauvegarder, restaurer, et éviter les pièges de droits.
partie: 1
chapitre: '5'
---

import troisMontages from '@site/src/figures/trois-montages.svg';
import volumeSurvit from '@site/src/figures/volume-survit.svg';

Enregistrez un colis dans l'API du chapitre précédent, redémarrez le conteneur, et redemandez la liste :

```bash
docker run -d --name api -p 8000:8000 colis:1.0
curl -s -X POST localhost:8000/colis -H 'Content-Type: application/json' \
     -d '{"destinataire": "Ada Lovelace", "depart": "Paris", "arrivee": "Brest", "poids_kg": 2.5}'
docker restart api
curl -s localhost:8000/colis
```

```sortie
[]
```

La liste est vide. L'API gardait ses colis en mémoire, et un redémarrage relance le processus : tout est perdu. Ce n'est pas propre aux conteneurs, un programme ordinaire perdrait lui aussi sa mémoire en redémarrant. Mais les conteneurs ajoutent une difficulté : même ce qu'un programme écrit sur le disque, dans ses propres fichiers, disparaît quand on supprime le conteneur. Or on supprime et on recrée des conteneurs tout le temps, à chaque mise à jour de l'image. Ce chapitre explique où vont les fichiers qu'écrit un conteneur, et comment garder ceux qui comptent. Au passage, Colis gagne sa base de données.

`docker rm -f api` fait place nette pour la suite.

## Ce qu'écrit un conteneur

Au chapitre 2, on a modifié la page d'accueil de nginx avec `docker exec`, et la modification a disparu avec le conteneur. Regardons ce mécanisme de plus près avec un conteneur qui écrit un fichier et se termine :

```bash
docker run --name ecrit alpine:3.24 sh -c 'echo "colis 1 livré" > /tmp/note.txt'
docker diff ecrit
```

```sortie
C /tmp
A /tmp/note.txt
```

`docker diff` liste les différences entre le système de fichiers du conteneur et celui de son image : `A` pour un fichier ajouté, `C` pour un dossier ou un fichier modifié, `D` pour un fichier supprimé. Ces différences vivent dans la **couche modifiable** du conteneur, une couche propre à lui, posée au-dessus des couches en lecture seule de l'image. Le conteneur est arrêté, mais la couche existe toujours, et on peut en extraire le fichier :

```bash
docker cp ecrit:/tmp/note.txt ./note.txt
cat note.txt
```

```sortie
colis 1 livré
```

Supprimons le conteneur, et réessayons :

```bash
docker rm ecrit
docker cp ecrit:/tmp/note.txt ./note2.txt
```

```sortie
ecrit
Error response from daemon: No such container: ecrit
```

La couche modifiable a disparu avec le conteneur, et le fichier avec elle. C'est voulu : un conteneur doit pouvoir être détruit et recréé à partir de son image sans que rien ne dépende de son passé. Mais une base de données, elle, doit garder ses données. Il faut donc que certains dossiers du conteneur soient stockés ailleurs que dans sa couche modifiable. Docker propose trois façons de le faire.

<Figure svg={troisMontages} num="5.1" alt="Le conteneur voit /var/lib/postgresql, /app/colis et /tmp comme des dossiers ordinaires. En réalité, le premier est un volume géré par Docker dans /var/lib/docker/volumes, le deuxième un dossier de votre machine monté tel quel, le troisième un espace en mémoire vive.">
Trois dossiers d'un même conteneur, trois endroits où les fichiers vivent réellement. Pour le programme qui tourne dans le conteneur, rien ne les distingue d'un dossier ordinaire.
</Figure>

Un **volume** est un espace de stockage créé et géré par Docker, que l'on monte dans un dossier du conteneur. Il existe indépendamment de tout conteneur. Un **montage lié** (*bind mount*) rend visible dans le conteneur un dossier de votre machine, tel quel. Un **tmpfs** est un dossier en mémoire vive, rapide et éphémère. On les passe tous les trois à `docker run` avec l'option `-v` (ou `--mount`, que nous verrons plus loin), sauf le tmpfs, qui a son option `--tmpfs`.

## PostgreSQL sans précaution

Lançons PostgreSQL 18 comme on lancerait n'importe quelle image. Trois variables d'environnement suffisent à l'image officielle pour créer un utilisateur, son mot de passe et une base :

```bash
docker run -d --name pg -e POSTGRES_USER=colis -e POSTGRES_PASSWORD=colis -e POSTGRES_DB=colis postgres:18-alpine
```

PostgreSQL met quelques secondes à initialiser sa base au premier démarrage. L'outil `pg_isready`, présent dans l'image, dit quand il est prêt à répondre ; on peut aussi suivre `docker logs -f pg` jusqu'à la ligne `database system is ready to accept connections`. Créons ensuite une table avec le client `psql`, lui aussi présent dans l'image :

```bash
docker exec pg psql -U colis -d colis -c "CREATE TABLE note (texte text); INSERT INTO note VALUES ('colis 1 livré');"
docker exec pg psql -U colis -d colis -c 'SELECT * FROM note;'
```

```sortie
CREATE TABLE
INSERT 0 1
     texte
---------------
 colis 1 livré
(1 row)
```

Supprimons ce conteneur et recréons-en un identique, comme on le ferait pour passer à une version plus récente de l'image :

```bash
docker rm -f pg
docker run -d --name pg -e POSTGRES_USER=colis -e POSTGRES_PASSWORD=colis -e POSTGRES_DB=colis postgres:18-alpine
docker exec pg psql -U colis -d colis -c 'SELECT * FROM note;'
```

```sortie
ERROR:  relation "note" does not exist
LINE 1: SELECT * FROM note;
                      ^
```

La table a disparu. Et pourtant, les données n'étaient pas dans la couche modifiable du premier conteneur. Regardons où elles étaient :

```bash
docker inspect pg --format '{{range .Mounts}}{{.Type}} {{.Name}} -> {{.Destination}}{{println}}{{end}}'
```

```sortie
volume ec3234f3032fc135d575a311c96a3cba8709a4ccc41ac2423d75ac28fd04573a -> /var/lib/postgresql
```

Le conteneur a un volume monté sur `/var/lib/postgresql`, alors qu'on n'a rien demandé. C'est l'image qui l'a voulu : son Dockerfile contient l'instruction `VOLUME /var/lib/postgresql`, que `docker image inspect postgres:18-alpine --format '{{json .Config.Volumes}}'` révèle. Quand une image déclare un volume et qu'on ne fournit rien, Docker crée un **volume anonyme**, nommé par une longue suite hexadécimale. Chaque nouveau conteneur reçoit le sien, tout neuf. Le premier conteneur avait donc bien écrit sa table dans un volume, mais le second en a reçu un autre, vide.

Le premier volume n'a pas été supprimé avec son conteneur. Il est toujours là, orphelin :

```sortie
ec3234f3032fc135d575a311c96a3cba8709a4ccc41ac2423d75ac28fd04573a créé le 2026-09-25T11:42:23+02:00
962bd3bb5e6f2e9ca734ee074d9475c086a54da8320a5478660780fadfc924e5 créé le 2026-09-25T11:42:26+02:00
```

Deux volumes anonymes, un par conteneur lancé. Les données de la table `note` sont dans le premier, mais plus aucun conteneur ne s'en sert, et rien dans son nom ne dit ce qu'il contient. Sur une machine où l'on fait des essais depuis des mois, ces volumes s'accumulent par dizaines et occupent des gigaoctets. L'option `-v` de `docker rm` supprime les volumes anonymes d'un conteneur en même temps que lui ; ici, supprimez-les à la main, par leur nom, avec `docker volume rm` suivi de chaque identifiant (les vôtres seront différents).

## Un volume nommé

La solution est de nommer le volume soi-même, pour pouvoir le monter à nouveau dans le conteneur suivant. On le crée, puis on le monte au chemin que l'image a déclaré :

```bash
docker rm -f pg
docker volume create colis-donnees
docker run -d --name pg -e POSTGRES_USER=colis -e POSTGRES_PASSWORD=colis -e POSTGRES_DB=colis \
  -v colis-donnees:/var/lib/postgresql postgres:18-alpine
```

La syntaxe de `-v` est `source:destination` : quand la source est un simple nom, c'est un volume, que Docker crée s'il n'existe pas encore. La création explicite avec `docker volume create` n'est donc pas obligatoire, mais elle rend l'intention claire. Recommençons l'expérience :

```bash
docker exec pg psql -U colis -d colis -c "CREATE TABLE note (texte text); INSERT INTO note VALUES ('colis 1 livré');"
docker rm -f pg
docker run -d --name pg2 -e POSTGRES_USER=colis -e POSTGRES_PASSWORD=colis -e POSTGRES_DB=colis \
  -v colis-donnees:/var/lib/postgresql postgres:18-alpine
docker exec pg2 psql -U colis -d colis -c 'SELECT * FROM note;'
```

```sortie
     texte
---------------
 colis 1 livré
(1 row)
```

La table a survécu à la suppression du conteneur. Le journal du nouveau conteneur le confirme à sa façon :

```sortie
PostgreSQL Database directory appears to contain a database; Skipping initialization
```

Le script de démarrage de l'image a trouvé une base existante et ne l'a pas réinitialisée. Les variables `POSTGRES_USER`, `POSTGRES_PASSWORD` et `POSTGRES_DB` ne servent qu'à la toute première initialisation : les changer ensuite ne change ni l'utilisateur ni le mot de passe d'une base existante, ce qui surprend souvent.

<Figure svg={volumeSurvit} num="5.2" alt="Le conteneur pg a une couche modifiable et le volume colis-donnees monté. Après docker rm -f pg, la couche modifiable est perdue ; le conteneur pg2 reçoit une couche neuve, et le même volume, où la table note est toujours là.">
La couche modifiable meurt avec son conteneur ; un volume nommé survit, et on le remonte dans le conteneur suivant.
</Figure>

### Où est le volume ?

```bash
docker volume inspect colis-donnees
```

```sortie
[
    {
        "CreatedAt": "2026-09-25T11:42:29+02:00",
        "Driver": "local",
        "Labels": null,
        "Mountpoint": "/var/lib/docker/volumes/colis-donnees/_data",
        "Name": "colis-donnees",
        "Options": null,
        "Scope": "local"
    }
]
```

Le pilote `local`, celui par défaut, range le volume dans un dossier de la machine, `/var/lib/docker/volumes/colis-donnees/_data`. Ce dossier appartient à `root` et votre utilisateur ne peut pas y entrer. Le plus simple pour regarder un volume est de le monter dans un conteneur jetable, ici en lecture seule grâce au suffixe `:ro` :

```bash
docker run --rm -v colis-donnees:/v:ro alpine:3.24 sh -c 'ls -l /v; ls /v/18/docker | head -8; du -sh /v'
```

```sortie
total 4
drwxr-xr-x    3 root     root          4096 Sep 25 09:42 18
PG_VERSION
base
global
pg_commit_ts
pg_dynshmem
pg_hba.conf
pg_ident.conf
pg_logical
46.3M	/v
```

Le volume contient un dossier `18`, puis `docker`, et dedans les fichiers de PostgreSQL : 46 Mo pour une base qui ne contient qu'une ligne, parce que PostgreSQL prépare dès le départ ses journaux de transactions. Le dossier `18` n'est pas un hasard, et il cache un piège.

:::panne[in 18+, these Docker images are configured to store database data in a format which is compatible with "pg_ctlcluster"]

Pendant des années, la documentation de l'image PostgreSQL et les tutoriels ont monté le volume sur `/var/lib/postgresql/data`. Depuis la version 18, l'image range les données dans `/var/lib/postgresql/18/docker` (la variable `PGDATA`), pour faciliter les montées de version, et déclare son volume sur `/var/lib/postgresql`. Monter un volume à l'ancien endroit fait échouer le démarrage :

```sortie
Error: in 18+, these Docker images are configured to store database data in a
       format which is compatible with "pg_ctlcluster" (specifically, using
       major-version-specific directory names).  This better reflects how
       PostgreSQL itself works, and how upgrades are to be performed.
       ...
       Counter to that, there appears to be PostgreSQL data in:
         /var/lib/postgresql/data (unused mount/volume)
       ...
       The suggested container configuration for 18+ is to place a single mount
       at /var/lib/postgresql which will then place PostgreSQL data in a
       subdirectory, allowing usage of "pg_upgrade --link" without mount point
       boundary issues.
```

Le message, très complet, donne la solution : un seul montage, sur `/var/lib/postgresql`. Retenez surtout la leçon générale : avant de monter un volume, lisez dans la documentation de l'image, ou dans `docker image inspect`, où elle écrit réellement ses données.

:::

## Sauvegarder et restaurer

Un volume survit aux conteneurs, mais pas à une fausse manipulation (`docker volume rm`), ni à la perte du disque. Il faut le sauvegarder. Deux méthodes, qu'il faut savoir distinguer.

La première passe par l'application. PostgreSQL fournit `pg_dump`, qui produit un fichier SQL capable de recréer la base :

```bash
docker exec pg2 pg_dump -U colis colis > colis.sql
wc -l colis.sql
grep -A3 'COPY public.note' colis.sql
```

```sortie
51 colis.sql
COPY public.note (texte) FROM stdin;
colis 1 livré
\.
```

Le fichier est écrit sur votre machine, puisque la redirection `>` est interprétée par votre shell, hors du conteneur. C'est la bonne méthode pour une base de données en marche : `pg_dump` lit une photographie cohérente de la base, même si des écritures ont lieu pendant la sauvegarde.

La seconde copie les fichiers bruts du volume, avec un conteneur jetable qui monte à la fois le volume et un dossier de votre machine :

```bash
docker run --rm -v colis-donnees:/donnees:ro -v "$PWD":/sauvegarde alpine:3.24 \
  tar czf /sauvegarde/colis-donnees.tar.gz -C /donnees .
ls -l colis-donnees.tar.gz
```

```sortie
-rw-r--r-- 1 root root 6906690 Sep 25 11:42 colis-donnees.tar.gz
```

Elle fonctionne pour n'importe quel volume, quelle que soit l'application. Mais copier les fichiers d'une base en marche est risqué : si PostgreSQL écrit pendant la copie, l'archive peut contenir un état incohérent. Réservez cette méthode aux volumes d'applications arrêtées, ou aux données qui ne sont pas des bases. Remarquez aussi le propriétaire de l'archive : `root`. On y revient dans un instant.

La restauration suit le chemin inverse, vers un volume neuf :

```bash
docker volume create colis-restaure
docker run --rm -v colis-restaure:/donnees -v "$PWD":/sauvegarde:ro alpine:3.24 \
  tar xzf /sauvegarde/colis-donnees.tar.gz -C /donnees
docker run --rm -v colis-restaure:/v:ro alpine:3.24 ls /v/18/docker | head -3
```

```sortie
PG_VERSION
base
global
```

Une sauvegarde n'existe vraiment que si on a déjà réussi à la restaurer. L'exercice 1 vous fait restaurer le fichier `colis.sql`. Le chapitre 52 reviendra sur les sauvegardes, à l'échelle d'un cluster Kubernetes.

## Les montages liés

Un montage lié rend un dossier de votre machine visible dans le conteneur. Quand la source de `-v` est un chemin (qui commence par `/` ou `./`) plutôt qu'un nom, c'est un montage lié. Son usage le plus courant est le développement : on veut modifier le code sur sa machine, avec son éditeur, et le voir pris en compte dans le conteneur sans reconstruire l'image.

Placez-vous dans `colis/app` et lancez l'API en montant le dossier du code par-dessus celui de l'image, avec l'option `--reload` d'Uvicorn, qui surveille les fichiers et redémarre le serveur quand ils changent :

```bash
docker run -d --name api-dev -p 8001:8000 -v "$PWD/colis":/app/colis colis:1.0 \
  uvicorn colis.app:app --host 0.0.0.0 --port 8000 --reload
curl -s localhost:8001/sante
```

```sortie
{"statut":"ok","version":"1.0.0","hote":"9c6e51b438e6"}
```

Ouvrez `colis/app.py` dans votre éditeur et changez la version par défaut, `"1.0.0"`, en `"1.0.1-dev"`. Enregistrez, puis :

```bash
docker logs api-dev 2>&1 | tail -7
curl -s localhost:8001/sante
```

```sortie
WARNING:  StatReload detected changes in 'colis/app.py'. Reloading...
INFO:     Shutting down
INFO:     Waiting for application shutdown.
INFO:     Application shutdown complete.
INFO:     Finished server process [8]
INFO:     Started server process [9]
...
{"statut":"ok","version":"1.0.1-dev","hote":"9c6e51b438e6"}
```

Uvicorn a vu la modification, a redémarré son processus de travail, et l'API répond avec la nouvelle version, sans reconstruction ni redémarrage du conteneur. Le montage a masqué le dossier `/app/colis` de l'image : c'est votre dossier que le conteneur voit à cet endroit. Remettez `"1.0.0"` dans le fichier et supprimez le conteneur (`docker rm -f api-dev`) : ce montage est un outil de développement, jamais une façon de livrer une application.

### Le piège des droits

Un montage lié partage les fichiers tels quels, avec leurs propriétaires et leurs droits, et le noyau ne connaît que des numéros d'utilisateur. Or le numéro d'un utilisateur dans le conteneur n'a rien à voir avec votre propre numéro sur la machine. Trois expériences le montrent, dans un dossier `sortie` qui vous appartient.

Un conteneur qui tourne en `root` écrit des fichiers qui appartiennent à `root` :

```bash
mkdir -p sortie
docker run --rm -v "$PWD/sortie":/sortie alpine:3.24 sh -c 'echo x > /sortie/par-root.txt'
ls -l sortie
```

```sortie
total 4
-rw-r--r-- 1 root root 2 Sep 25 11:42 par-root.txt
```

Vous pouvez supprimer ce fichier, parce que le droit de suppression dépend du dossier qui le contient, et ce dossier est à vous. Mais vous ne pouvez pas le modifier, et si le conteneur avait créé des sous-dossiers, vous ne pourriez pas les vider. C'est la mésaventure décrite au chapitre 4 : lancés dans un conteneur en `root`, Python et pytest avaient laissé des dossiers `__pycache__` et `.pytest_cache` impossibles à supprimer sans `sudo`. Il avait fallu passer par un conteneur pour les effacer.

À l'inverse, un conteneur qui tourne sous un utilisateur ordinaire ne peut pas écrire dans votre dossier. L'image de Colis tourne sous l'utilisateur 10001 :

```bash
docker run --rm -v "$PWD/sortie":/sortie colis:1.0 sh -c 'echo x > /sortie/par-colis.txt'
```

```sortie
sh: 1: cannot create /sortie/par-colis.txt: Permission denied
```

Pour le noyau, l'utilisateur 10001 n'est pas le propriétaire du dossier (vous, numéro 1000 sur le poste du cours), et le dossier n'est pas ouvert en écriture aux autres. La solution, pour un montage de développement, est de faire tourner le conteneur sous votre propre numéro, avec `--user` :

```bash
docker run --rm --user $(id -u):$(id -g) -v "$PWD/sortie":/sortie colis:1.0 sh -c 'id; echo x > /sortie/par-moi.txt'
ls -l sortie
```

```sortie
uid=1000 gid=1000 groups=1000
-rw-r--r-- 1 romial romial 2 Sep 25 11:42 par-moi.txt
```

Le conteneur tourne sous le numéro 1000, qui n'a pas de nom dans le conteneur (d'où l'absence de nom dans `id`), et le fichier vous appartient. Le chapitre 12 présentera une solution plus générale, les namespaces d'utilisateurs, qui font correspondre automatiquement les numéros du conteneur à une plage de numéros de la machine.

:::warning[Un chemin absent devient un dossier de root]

Avec `-v`, si le dossier source d'un montage lié n'existe pas, Docker le crée, et il le crée en tant que `root` : `docker run --rm -v "$PWD/absent":/absent alpine:3.24 true` laisse derrière lui un dossier `absent` qui appartient à `root`, dans lequel vous ne pouvez rien écrire. Une faute de frappe dans un chemin passe ainsi inaperçue : le conteneur démarre avec un dossier vide au lieu de vos fichiers. La syntaxe `--mount`, plus verbeuse, n'a pas ce défaut : elle refuse un chemin qui n'existe pas (exercice 5).

:::

## Les tmpfs et les conteneurs en lecture seule

Un tmpfs est un système de fichiers en mémoire vive. Monté dans un conteneur, il offre un dossier très rapide, qui n'écrit rien sur le disque et disparaît à l'arrêt du conteneur : idéal pour des fichiers temporaires, ou pour des données sensibles qu'on ne veut jamais voir écrites sur un disque.

Il prend tout son intérêt avec l'option `--read-only`, qui rend en lecture seule tout le système de fichiers du conteneur, couche modifiable comprise :

```bash
docker run --rm --read-only alpine:3.24 touch /note.txt
docker run --rm --read-only --tmpfs /tmp alpine:3.24 sh -c 'touch /tmp/note.txt && df -h /tmp'
```

```sortie
touch: /note.txt: Read-only file system
Filesystem                Size      Used Available Use% Mounted on
tmpfs                     7.5G         0      7.5G   0% /tmp
```

Le conteneur ne peut plus rien écrire, sauf dans `/tmp`, monté en mémoire. La taille affichée, 7,5 Go, est la limite par défaut : la moitié de la mémoire du poste du cours. L'option `--tmpfs /tmp:size=64m` la réduit.

Un conteneur en lecture seule est une excellente protection : si un attaquant prend le contrôle de l'application, il ne peut ni modifier ses fichiers ni déposer un programme malveillant sur le disque. L'API de Colis le supporte sans rien changer, puisqu'elle n'écrit rien :

```bash
docker run -d --name api --read-only -p 8000:8000 colis:1.0
curl -s localhost:8000/sante
```

```sortie
{"statut":"ok","version":"1.0.0","hote":"1ed9909b9a94"}
```

C'est l'une des raisons pour lesquelles on a désactivé l'écriture des fichiers `.pyc` au chapitre 4. Nous rendrons ce réglage systématique dans Kubernetes, au chapitre 44.

## Faire le ménage des volumes

`docker volume ls` liste les volumes, et `docker volume rm` supprime ceux qu'on désigne. Docker refuse de supprimer un volume monté dans un conteneur, même arrêté. Ce refus est une sécurité : supprimer un volume, c'est supprimer définitivement ses données.

:::danger[docker volume prune ne connaît pas vos intentions]

`docker volume prune` supprime tous les volumes qu'aucun conteneur n'utilise, et avec l'option `--all` même les volumes nommés. Sur un poste de développement, les bases de données de vos autres projets sont souvent dans des volumes que rien n'utilise à cet instant, parce que leurs conteneurs sont supprimés entre deux séances de travail. Ne supprimez des volumes que par leur nom, après avoir vérifié ce qu'ils contiennent.

:::

## Exercices

:::exercice[Exercice 1 : restaurer une sauvegarde SQL]

À partir du fichier `colis.sql` produit par `pg_dump`, recréez la table `note` dans une base PostgreSQL toute neuve, lancée avec un autre volume. Vérifiez son contenu.

:::

<details>
<summary>Corrigé</summary>

```bash
docker run -d --name pg-neuf -e POSTGRES_USER=colis -e POSTGRES_PASSWORD=colis -e POSTGRES_DB=colis \
  -v colis-neuf:/var/lib/postgresql postgres:18-alpine
# attendre que la base soit prête : docker exec pg-neuf pg_isready -U colis
docker exec -i pg-neuf psql -q -U colis -d colis < colis.sql
docker exec pg-neuf psql -U colis -d colis -c 'SELECT * FROM note;'
```

L'option `-i` de `docker exec` garde l'entrée standard ouverte : c'est elle qui permet à `psql`, dans le conteneur, de lire le fichier redirigé depuis votre machine. Sans elle, `psql` ne recevrait rien. La table réapparaît avec son contenu. Supprimez ensuite le conteneur et son volume : `docker rm -f pg-neuf && docker volume rm colis-neuf`.

</details>

:::exercice[Exercice 2 : la taille d'un volume]

Quelle place occupe le volume `colis-donnees` ? Pourquoi `du -sh /var/lib/docker/volumes/colis-donnees` échoue-t-il sur votre machine, et comment obtenir la réponse sans `sudo` ?

:::

<details>
<summary>Corrigé</summary>

Le dossier `/var/lib/docker/volumes` appartient à `root` et n'est pas lisible par les autres utilisateurs : `du` répond `Permission denied`. On passe par un conteneur, qui tourne en `root` et voit le volume monté :

```bash
docker run --rm -v colis-donnees:/v:ro alpine:3.24 du -sh /v
```

Sur le poste du cours, le volume occupe 46 Mo. Remarquez que ce contournement est possible parce que votre utilisateur est dans le groupe `docker` : c'est l'illustration concrète de l'avertissement du chapitre 0.2, ce groupe vaut un accès `root`.

</details>

:::exercice[Exercice 3 : un site modifiable à chaud]

Servez avec nginx un dossier `site` de votre machine, contenant un `index.html`, sur le port 8085, en lecture seule pour le conteneur. Modifiez le fichier sur votre machine : la page change-t-elle sans redémarrer nginx ? Et que se passe-t-il si on essaie de modifier la page depuis le conteneur ?

:::

<details>
<summary>Corrigé</summary>

```bash
mkdir site && echo '<h1>Version 1</h1>' > site/index.html
docker run -d --name site -p 8085:80 -v "$PWD/site":/usr/share/nginx/html:ro nginx:1.30-alpine
curl -s localhost:8085
echo '<h1>Version 2</h1>' > site/index.html
curl -s localhost:8085
docker exec site sh -c 'echo pirate > /usr/share/nginx/html/index.html'
```

```sortie
<h1>Version 1</h1>
<h1>Version 2</h1>
sh: can't create /usr/share/nginx/html/index.html: Read-only file system
```

La page change immédiatement : nginx relit le fichier à chaque requête, et le conteneur voit votre dossier en direct. Le suffixe `:ro` interdit en revanche toute écriture depuis le conteneur. Pour une configuration ou un site statique monté dans un conteneur, c'est la bonne habitude : le conteneur lit, il n'écrit pas.

</details>

:::exercice[Exercice 4 : un nom ou un chemin]

Quelle différence entre `docker run --rm -v donnees:/x alpine:3.24 true` et `docker run --rm -v ./donnees:/x alpine:3.24 true` ? Exécutez les deux et observez ce qui a été créé.

:::

<details>
<summary>Corrigé</summary>

La première crée un volume nommé `donnees` (`docker volume ls` le montre). La seconde crée un dossier `donnees` dans votre dossier courant, qui appartient à `root`, et le monte : c'est un montage lié. Les deux points qui précèdent le nom font toute la différence. Supprimez le volume avec `docker volume rm donnees` et le dossier avec `docker run --rm -v "$PWD":/w alpine:3.24 rm -r /w/donnees`, puisque vous ne pouvez pas le supprimer vous-même s'il contient quelque chose.

</details>

:::exercice[Exercice 5 : la syntaxe --mount]

Réécrivez `docker run --rm -v "$PWD/absent2":/x alpine:3.24 true` avec l'option `--mount`, puis lancez-la. Que se passe-t-il ?

:::

<details>
<summary>Corrigé</summary>

```bash
docker run --rm --mount type=bind,src="$PWD/absent2",dst=/x alpine:3.24 true
```

```sortie
docker: Error response from daemon: invalid mount config for type "bind": bind source path does not exist: /home/.../absent2
```

Avec `--mount`, Docker refuse un chemin inexistant au lieu de le créer en silence, et renvoie le code 125. La syntaxe est plus longue (`type=volume` ou `type=bind` ou `type=tmpfs`, `src`, `dst`, `readonly`), mais explicite, et c'est celle que recommande la documentation de Docker. Vous retrouverez la même structure, type, source et destination, dans les fichiers Compose du chapitre 7 et dans les Pods de Kubernetes.

</details>

## Nettoyer

Les conteneurs et volumes de ce chapitre ne resserviront pas : le chapitre 6 recréera PostgreSQL proprement. Supprimez-les par leur nom, ainsi que les deux volumes anonymes relevés plus haut (vos identifiants seront différents) :

```bash
docker rm -f api pg2 site
docker volume rm colis-donnees colis-restaure
docker volume rm ec3234f3032fc135d575a311c96a3cba8709a4ccc41ac2423d75ac28fd04573a 962bd3bb5e6f2e9ca734ee074d9475c086a54da8320a5478660780fadfc924e5
docker run --rm -v "$PWD":/w alpine:3.24 rm -rf /w/sortie /w/absent /w/colis-donnees.tar.gz
rm -f note.txt colis.sql
```

La dernière commande `docker run` supprime, en `root` à travers un conteneur, les fichiers que des conteneurs ont créés en `root` dans votre dossier.
