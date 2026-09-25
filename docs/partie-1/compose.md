---
title: Plusieurs conteneurs avec Compose
sidebar_label: 7. Compose
description: Décrire Colis tout entier dans un fichier compose.yaml, le démarrer d'une commande dans le bon ordre grâce aux sondes de santé, multiplier les workers, gérer les secrets locaux et le cycle de vie d'un projet.
partie: 1
chapitre: '7'
---

import composeOrdre from '@site/src/figures/compose-ordre.svg';
import workersFile from '@site/src/figures/workers-file.svg';

À la fin du chapitre précédent, Colis tournait. Il avait fallu pour cela un réseau, un volume, cinq commandes `docker run` avec leurs options, les lancer dans le bon ordre, et attendre entre deux d'entre elles que PostgreSQL soit prêt. Recommencer demain, ou demander à un collègue de le faire, c'est risquer d'oublier une option, de se tromper d'ordre, et de retomber sur les deux pannes du chapitre 6.

Docker Compose remplace ces commandes par un fichier qui décrit l'application : quels conteneurs, avec quelles images, quelles variables, quels volumes, quels ports, et qui dépend de qui. Une commande lit le fichier et crée tout, dans le bon ordre. Ce fichier se versionne avec le code, se relit, se corrige : c'est la première description déclarative de Colis, et la dernière étape avant Kubernetes, qui généralise exactement cette idée.

Avant de commencer, supprimez le Colis assemblé à la main au chapitre 6 (`docker rm -f web worker api redis postgres`, `docker network rm colis`, `docker volume rm colis-donnees`) : il occupe le port 8080.

## Le fichier compose.yaml

Voici le fichier complet de Colis. Il se place à la racine du dossier `colis`, à côté des dossiers `app` et `web`. Téléchargez [l'archive de Colis à la fin de la partie I](pathname:///kits/colis-partie-1.tar.gz) si vous voulez repartir d'un dossier propre : elle contient `app`, `web`, ce fichier et le fichier `.env` décrit plus bas.

```yaml title="compose.yaml"
# Colis complet : docker compose up -d --build
# Le mot de passe de PostgreSQL vient du fichier .env (chapitre 7).
name: colis

# Fragments réutilisés par plusieurs services (ancres YAML)
x-image-colis: &image-colis
  build: ./app
  image: colis:1.0

x-env-colis: &env-colis
  COLIS_DB: postgresql://colis:${POSTGRES_PASSWORD:?définissez POSTGRES_PASSWORD dans .env}@postgres:5432/colis
  COLIS_REDIS: redis://redis:6379/0

services:
  postgres:
    image: postgres:18-alpine
    environment:
      POSTGRES_USER: colis
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?définissez POSTGRES_PASSWORD dans .env}
      POSTGRES_DB: colis
    volumes:
      - donnees:/var/lib/postgresql
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "colis", "-d", "colis"]
      interval: 2s
      timeout: 3s
      retries: 15
    restart: unless-stopped

  redis:
    image: redis:8.8-alpine
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 2s
      timeout: 3s
      retries: 15
    restart: unless-stopped

  api:
    <<: *image-colis
    environment: *env-colis
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/pret', timeout=2)"]
      interval: 3s
      timeout: 3s
      retries: 10
    restart: unless-stopped

  worker:
    <<: *image-colis
    command: ["python", "-m", "colis.worker"]
    environment: *env-colis
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    restart: unless-stopped

  web:
    build: ./web
    image: colis-web:1.0
    ports:
      - "8080:80"
    depends_on:
      api:
        condition: service_healthy
    restart: unless-stopped

  # Lancée à la demande : docker compose run --rm purge
  purge:
    <<: *image-colis
    command: ["python", "-m", "colis.purge"]
    environment: *env-colis
    depends_on:
      postgres:
        condition: service_healthy
    profiles: ["outils"]

volumes:
  donnees:
```

Le fichier paraît long ; il est surtout répétitif, et chaque bloc correspond à une commande `docker run` du chapitre 6. Prenons-le dans l'ordre.

`name: colis` nomme le **projet**. Compose préfixe par ce nom tout ce qu'il crée : les conteneurs s'appelleront `colis-api-1`, `colis-worker-1`, le réseau `colis_default`, le volume `colis_donnees`. Sans cette ligne, le projet prendrait le nom du dossier.

La section `services` décrit chaque composant. Un **service** n'est pas un conteneur : c'est la description d'un rôle (« l'API », « le worker »), que Compose réalise avec un ou plusieurs conteneurs identiques. On en lancera trois pour le worker un peu plus loin.

Chaque service indique d'où vient son image : `image` seul pour une image publiée (PostgreSQL, Redis), `build` pour une image à construire à partir d'un dossier (l'API, le site). Quand les deux sont présents, Compose construit l'image et lui donne ce nom.

`environment`, `volumes`, `ports` et `command` reprennent les options `-e`, `-v`, `-p` et la commande de `docker run`. Le service `web` est le seul à publier un port. On n'a déclaré aucun réseau : Compose crée d'office un réseau `colis_default` pour le projet, y branche tous les services, et chaque service y est joignable par son nom. L'API trouve donc la base à l'adresse `postgres`, comme au chapitre 6.

`restart: unless-stopped` applique la politique de redémarrage du chapitre 2 : un conteneur qui s'arrête tout seul est relancé.

La section `volumes` en fin de fichier déclare le volume nommé `donnees`, que le service `postgres` monte sur `/var/lib/postgresql`.

Les blocs qui commencent par `x-` ne sont pas des services : Compose ignore toute clé qui commence par `x-`, et on s'en sert pour ranger des fragments réutilisables. La syntaxe `&image-colis` pose une ancre YAML sur un fragment, et `<<: *image-colis` le recopie dans un service. L'API, le worker et la purge partagent ainsi la même consigne de construction et le même nom d'image, `colis:1.0`, et les mêmes variables d'environnement, sans les répéter trois fois. Donner à chacun la consigne `build` a aussi un effet pratique : au premier lancement, Compose construit l'image au lieu de chercher un `colis:1.0` inexistant sur Docker Hub.

## Démarrer dans le bon ordre

Les deux pannes du chapitre 6 venaient de l'ordre de démarrage : l'API lancée avant que PostgreSQL accepte les connexions, nginx lancé avant que le nom `api` existe. Compose les règle avec deux mécanismes.

Le premier est la **sonde de santé** (*healthcheck*). Une sonde est une commande que Docker exécute régulièrement dans le conteneur : si elle réussit (code de sortie 0), le conteneur est déclaré sain (*healthy*) ; si elle échoue `retries` fois de suite, il est déclaré malade (*unhealthy*). PostgreSQL est sain quand `pg_isready` répond, Redis quand `redis-cli ping` répond. Pour l'API, on interroge sa route `/pret`, qui vérifie qu'elle joint bien la base et la file ; l'image de Colis ne contient ni `curl` ni `wget`, mais Python sait faire une requête HTTP. Ces sondes sont une fonction de Docker lui-même, que vous pouvez aussi écrire dans un Dockerfile (instruction `HEALTHCHECK`) ou passer à `docker run` (options `--health-cmd`...).

Le second est `depends_on` avec la condition `service_healthy` : Compose ne démarre un service qu'une fois ses dépendances déclarées saines. Le worker et l'API attendent PostgreSQL et Redis ; le site attend l'API.

```bash
docker compose up -d --build
```

La sortie est longue, parce que Compose annonce chaque étape. En voici l'essentiel, dans l'ordre :

```sortie
 Image colis:1.0 Building
 Image colis-web:1.0 Building
 Image colis:1.0 Built
 Image colis-web:1.0 Built
 Network colis_default Created
 Volume colis_donnees Created
 Container colis-redis-1 Created
 Container colis-postgres-1 Created
 ...
 Container colis-postgres-1 Started
 Container colis-redis-1 Started
 Container colis-redis-1 Waiting
 Container colis-postgres-1 Waiting
 Container colis-postgres-1 Healthy
 Container colis-redis-1 Healthy
 Container colis-worker-1 Starting
 Container colis-api-1 Starting
 Container colis-worker-1 Started
 Container colis-api-1 Started
 Container colis-api-1 Waiting
 Container colis-api-1 Healthy
 Container colis-web-1 Starting
 Container colis-web-1 Started
```

Quand la sortie n'est pas un terminal, comme ici, Compose écrit certaines lignes deux fois ; elles ont été dédoublonnées. Sur le poste du cours, le tout a pris 8,8 secondes, construction des images comprise. Lisez la séquence : les images sont construites, puis le réseau et le volume sont créés, puis les conteneurs. PostgreSQL et Redis démarrent en premier ; Compose attend (`Waiting`) qu'ils soient sains ; alors seulement il démarre l'API et le worker ; il attend que l'API soit saine, et démarre enfin le site.

<Figure svg={composeOrdre} num="7.1" alt="Chronologie du démarrage : postgres et redis démarrent, deviennent sains ; worker et api démarrent ensuite ; api devient saine ; web démarre en dernier.">
L'ordre de démarrage que <code>depends_on</code> et les sondes imposent. Aucun service ne démarre avant que ses dépendances aient passé leur sonde.
</Figure>

```bash
docker compose ps
```

```sortie
NAME               IMAGE                COMMAND                  SERVICE    CREATED         STATUS                   PORTS
colis-api-1        colis:1.0            "uvicorn colis.app:a…"   api        7 seconds ago   Up 4 seconds (healthy)   8000/tcp
colis-postgres-1   postgres:18-alpine   "docker-entrypoint.s…"   postgres   7 seconds ago   Up 7 seconds (healthy)   5432/tcp
colis-redis-1      redis:8.8-alpine     "docker-entrypoint.s…"   redis      7 seconds ago   Up 6 seconds (healthy)   6379/tcp
colis-web-1        colis-web:1.0        "/docker-entrypoint.…"   web        7 seconds ago   Up Less than a second    0.0.0.0:8080->80/tcp, [::]:8080->80/tcp
colis-worker-1     colis:1.0            "python -m colis.wor…"   worker     7 seconds ago   Up 4 seconds             8000/tcp
```

La colonne `STATUS` affiche l'état de santé des services qui ont une sonde. Colis répond :

```bash
curl -s localhost:8080/api/pret
```

```sortie
{"stockage":"postgres","file":"redis","pret":true}
```

Ouvrez http://localhost:8080 : c'est le même site qu'au chapitre 6, démarré cette fois d'une seule commande.

:::tip[Attendre que tout soit prêt]

`docker compose up -d` rend la main dès que les conteneurs sont démarrés. L'option `--wait` le fait attendre que tous les services soient sains (ou en marche, pour ceux qui n'ont pas de sonde) : pratique dans un script, pour enchaîner sur des tests sans `sleep` approximatif. C'est l'équivalent, pour Compose, du `kubectl wait` du chapitre 0.2.

:::

## Ce que Compose a créé

Compose n'a rien inventé : il a créé, à votre place, les mêmes objets Docker qu'au chapitre 6. On peut les voir avec les commandes habituelles :

```bash
docker network ls --filter name=colis --format '{{.Name}} {{.Driver}}'
docker volume ls --filter name=colis --format '{{.Name}}'
docker image ls --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep '^colis'
```

```sortie
colis_default bridge
colis_donnees
colis:1.0 164MB
colis-web:1.0 62.4MB
```

La commande `docker compose config` montre le fichier tel que Compose le comprend, une fois les ancres recopiées et les variables remplacées. Voici le service `worker` :

```bash
docker compose config
```

```sortie
  worker:
    build:
      context: /home/.../colis/app
      dockerfile: Dockerfile
    command:
      - python
      - -m
      - colis.worker
    depends_on:
      postgres:
        condition: service_healthy
        required: true
      redis:
        condition: service_healthy
        required: true
    environment:
      COLIS_DB: postgresql://colis:colis-local-2026@postgres:5432/colis
      COLIS_REDIS: redis://redis:6379/0
    image: colis:1.0
    networks:
      default: null
    restart: unless-stopped
```

Le fragment `x-image-colis` a été recopié (`build`, `image`), les variables aussi, et le réseau par défaut apparaît explicitement. Quand un fichier Compose ne fait pas ce qu'on croit, `docker compose config` est la première commande à lancer.

## Les secrets locaux : le fichier .env

Le mot de passe de PostgreSQL n'est pas écrit dans `compose.yaml`. Il y apparaît sous la forme `${POSTGRES_PASSWORD:?...}`, que Compose remplace par la valeur de la variable `POSTGRES_PASSWORD`. Cette valeur vient de votre environnement, ou d'un fichier `.env` placé à côté de `compose.yaml`, que Compose lit automatiquement :

```text title=".env"
# Variables lues par Docker Compose. Ne versionnez jamais un vrai mot de passe.
POSTGRES_PASSWORD=colis-local-2026
```

La forme `${VARIABLE:?message}` rend la variable obligatoire. Sans le fichier `.env`, Compose refuse de continuer, et dit pourquoi :

```sortie
error while interpolating services.api.environment.COLIS_DB: required variable POSTGRES_PASSWORD is missing a value: définissez POSTGRES_PASSWORD dans .env
error while interpolating services.postgres.environment.POSTGRES_PASSWORD: required variable POSTGRES_PASSWORD is missing a value: définissez POSTGRES_PASSWORD dans .env
...
```

C'est bien plus sûr que la forme simple `${POSTGRES_PASSWORD}`, qui remplace une variable absente par une chaîne vide, avec un simple avertissement : PostgreSQL démarrerait alors sans mot de passe utilisable. D'autres formes existent, comme `${COLIS_PORT:-8080}`, qui donne une valeur par défaut (exercice 3).

Séparer ainsi les secrets du fichier Compose permet de versionner `compose.yaml` et d'exclure `.env` du dépôt Git (dans `.gitignore`). Ce n'est qu'une première marche : la valeur finit en clair dans la configuration du conteneur, et `docker inspect` la montre à quiconque a accès à Docker. Kubernetes a ses propres objets pour les secrets (chapitre 21), et le chapitre 46 montre comment les protéger vraiment.

## Plusieurs workers

Le worker prend une demi-seconde par colis : c'est le temps de calcul simulé du chapitre 4. Envoyons douze colis d'un coup, puis mesurons le temps nécessaire pour qu'ils soient tous estimés, en interrogeant l'API jusqu'à ce qu'il ne reste plus aucun colis « enregistré » :

```bash
for i in $(seq 1 12); do
  curl -s -o /dev/null -X POST localhost:8080/api/colis -H 'Content-Type: application/json' \
       -d '{"destinataire": "Grace Hopper", "depart": "Lille", "arrivee": "Marseille", "poids_kg": 4}'
done
debut=$(date +%s.%N)
until curl -s localhost:8080/api/colis | grep -qv 'enregistr'; do sleep 0.2; done
awk -v d="$debut" -v f="$(date +%s.%N)" 'BEGIN { printf "tous estimés en %.1f s\n", f - d }'
```

Sur le poste du cours, la mesure a donné :

```sortie
tous estimés en 6.1 s
```

Douze colis, une demi-seconde chacun, un seul worker : six secondes, sans surprise. Demandons trois workers :

```bash
docker compose up -d --scale worker=3
docker compose ps worker --format 'table {{.Name}}\t{{.Status}}'
```

```sortie
NAME             STATUS
colis-worker-1   Up 12 seconds
colis-worker-2   Up Less than a second
colis-worker-3   Up Less than a second
```

Compose a gardé le premier worker et en a démarré deux autres, identiques, qui se branchent sur la même file Redis. Mêmes douze colis :

```sortie
tous estimés en 2.0 s
```

Trois fois plus vite. Le journal montre comment le travail s'est réparti :

```bash
docker compose logs --tail 3 worker
```

```sortie
worker-3  | colis 16 : Lille -> Marseille, 4 jours, livraison estimée le 2026-09-29
worker-3  | colis 19 : Lille -> Marseille, 4 jours, livraison estimée le 2026-09-29
worker-3  | colis 22 : Lille -> Marseille, 4 jours, livraison estimée le 2026-09-29
worker-1  | colis 18 : Lille -> Marseille, 4 jours, livraison estimée le 2026-09-29
worker-1  | colis 21 : Lille -> Marseille, 4 jours, livraison estimée le 2026-09-29
worker-1  | colis 24 : Lille -> Marseille, 4 jours, livraison estimée le 2026-09-29
worker-2  | colis 17 : Lille -> Marseille, 4 jours, livraison estimée le 2026-09-29
worker-2  | colis 20 : Lille -> Marseille, 4 jours, livraison estimée le 2026-09-29
worker-2  | colis 23 : Lille -> Marseille, 4 jours, livraison estimée le 2026-09-29
```

`docker compose logs` préfixe chaque ligne par le conteneur qui l'a écrite. Chaque worker a traité un colis sur trois, sans que personne n'ait eu à organiser ce partage.

<Figure svg={workersFile} num="7.2" alt="L'API ajoute les colis 16 à 24 à la liste Redis. Trois workers prennent les colis à l'autre bout ; worker-1 a traité 18, 21, 24 ; worker-2 17, 20, 23 ; worker-3 16, 19, 22.">
La file Redis répartit le travail. Chaque worker attend un colis avec <code>BLPOP</code> ; Redis donne chaque colis à un seul d'entre eux. Répartition réelle des colis 16 à 24 sur le poste du cours.
</Figure>

Ce partage vient de la conception de Colis, pas de Compose. L'API dépose les numéros de colis dans une liste Redis ; chaque worker attend le suivant avec la commande `BLPOP`, que Redis sert au premier arrivé, et chaque colis n'est remis qu'une fois. Ajouter des workers ajoute des mains pour vider la file. C'est le découplage annoncé au chapitre 0.1 : l'API répond immédiatement, et la capacité de calcul s'ajuste indépendamment d'elle. Au chapitre 31, KEDA fera varier le nombre de workers automatiquement, selon la longueur de la file.

Tous les services ne se multiplient pas aussi facilement. Trois PostgreSQL seraient trois bases indépendantes, chacune avec ses propres données. Et deux conteneurs `web` ne peuvent pas publier tous les deux le port 8080. Savoir ce qui se duplique et ce qui ne se duplique pas, c'est toute la différence entre composants sans état et composants avec état, qui gouverne la partie III.

## Un service qui tombe

La politique `restart: unless-stopped` relance un conteneur qui s'arrête de lui-même. Simulons la panne d'un worker, en envoyant SIGTERM à son processus principal depuis l'intérieur :

```bash
docker compose exec --index 1 worker sh -c 'kill 1'
sleep 3
docker compose ps worker --format 'table {{.Name}}\t{{.Status}}'
docker inspect colis-worker-1 --format 'redémarrages : {{.RestartCount}}'
```

```sortie
NAME             STATUS
colis-worker-1   Up 1 second
colis-worker-2   Up 6 seconds
colis-worker-3   Up 6 seconds
redémarrages : 1
```

Le worker a reçu le signal, a terminé proprement (son gestionnaire de SIGTERM, écrit au chapitre 4, affiche `signal SIGTERM reçu, arrêt après le colis en cours`), et Docker l'a relancé aussitôt. Un `docker compose stop worker`, en revanche, n'aurait pas déclenché de redémarrage : c'est tout le sens de `unless-stopped`.

## Lancer une tâche ponctuelle

Le service `purge` porte `profiles: ["outils"]`. Un service rattaché à un profil n'est pas démarré par `docker compose up`, sauf si l'on active ce profil. Il sert pour les tâches qu'on lance à la demande. `docker compose run` crée un conteneur éphémère pour un service, en respectant ses dépendances, et `--rm` le supprime à la fin :

```bash
docker compose run --rm purge
```

```sortie
purge : 0 colis livrés depuis plus de 30 jours supprimés
```

Aucun colis n'a encore été livré, a fortiori depuis trente jours. Au chapitre 27, cette purge deviendra un CronJob Kubernetes, lancé automatiquement chaque nuit.

Deux autres commandes permettent d'agir sur un service en marche. `docker compose exec` lance une commande dans un conteneur existant, comme `docker exec` :

```bash
docker compose exec postgres psql -U colis -d colis -c 'SELECT statut, count(*) FROM colis GROUP BY statut;'
```

```sortie
 statut | count
--------+-------
 estimé |    24
(1 row)
```

Et `docker compose logs -f` suit les journaux de tous les services à la fois, chaque ligne préfixée par son conteneur, jusqu'à Ctrl+C.

## Arrêter, supprimer, recommencer

Trois commandes gouvernent le cycle de vie d'un projet, et il faut bien les distinguer :

| Commande | Conteneurs | Réseau | Volumes |
|---|---|---|---|
| `docker compose stop` | arrêtés, conservés | conservé | conservés |
| `docker compose down` | supprimés | supprimé | **conservés** |
| `docker compose down -v` | supprimés | supprimé | **supprimés** |

`down` supprime les conteneurs et le réseau, mais garde les volumes nommés, donc les données :

```bash
docker compose down
docker compose up -d
curl -s localhost:8080/api/colis | python3 -c 'import sys, json; print(len(json.load(sys.stdin)), "colis retrouvés")'
```

```sortie
24 colis retrouvés
```

Les conteneurs sont neufs, les données sont là. `down -v`, en revanche, supprime aussi le volume `colis_donnees`, et avec lui tous les colis :

```sortie
 ...
 Volume colis_donnees Removing
 Network colis_default Removing
 Volume colis_donnees Removed
 Network colis_default Removed
```

Réservez `down -v` au moment où vous voulez vraiment repartir de zéro. Il ne supprime que les volumes du projet, pas ceux des autres projets, ce qui le rend bien moins dangereux que `docker volume prune`, mais il est tout aussi définitif.

Après une modification du code de l'API ou du site, `docker compose up -d --build` reconstruit les images et ne recrée que les conteneurs dont l'image ou la configuration a changé. Les autres continuent de tourner.

## Compose et Kubernetes

Compose décrit une application qui tourne sur une seule machine. Il ne sait pas répartir les conteneurs sur plusieurs machines, ni remplacer une machine tombée, ni mettre à jour l'API sans interruption. C'est ce que fait Kubernetes, et la partie III reprendra Colis là où ce chapitre le laisse.

Presque tout ce que vous avez écrit ici a un équivalent direct. Un service devient un Deployment (chapitre 19) ; son nom sur le réseau devient un Service (chapitre 20) ; `environment` et `.env` deviennent un ConfigMap et un Secret (chapitre 21) ; les sondes de santé deviennent des probes (chapitre 22) ; le volume devient un PersistentVolumeClaim (chapitre 25) ; la purge devient un CronJob (chapitre 27). Même `depends_on` a son pendant, même si Kubernetes aborde le problème autrement : plutôt que d'ordonner les démarrages, il laisse chaque composant attendre ses dépendances et redémarre ceux qui échouent, jusqu'à ce que tout se stabilise.

## Exercices

:::exercice[Exercice 1 : un fichier pour le développement]

Écrivez un fichier `compose.dev.yaml` qui, ajouté à `compose.yaml`, lance l'API avec `--reload` et monte le dossier `app/colis` de votre machine dans le conteneur. Démarrez l'API avec les deux fichiers, modifiez la version dans `app/colis/app.py`, et vérifiez qu'elle change sans reconstruction.

:::

<details>
<summary>Corrigé</summary>

```yaml title="compose.dev.yaml"
services:
  api:
    command: ["uvicorn", "colis.app:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]
    volumes:
      - ./app/colis:/app/colis:ro
```

```bash
docker compose -f compose.yaml -f compose.dev.yaml up -d api
curl -s localhost:8080/api/sante
# modifier "1.0.0" en "1.0.1-dev" dans app/colis/app.py, puis :
curl -s localhost:8080/api/sante
```

```sortie
{"statut":"ok","version":"1.0.0","hote":"40fd37850bac"}
{"statut":"ok","version":"1.0.1-dev","hote":"40fd37850bac"}
```

Quand on donne plusieurs fichiers avec `-f`, Compose les fusionne dans l'ordre : les clés du second remplacent ou complètent celles du premier. `docker compose -f compose.yaml -f compose.dev.yaml config` montre le résultat, avec la commande `--reload` et le montage. Le montage est en lecture seule (`:ro`) : Uvicorn n'a besoin que de lire le code. Remettez la version d'origine dans le fichier, puis `docker compose up -d api` (sans le second fichier) recrée l'API normale.

</details>

:::exercice[Exercice 2 : la file qui s'allonge]

Arrêtez le worker, enregistrez cinq colis, et regardez la longueur de la file avec `redis-cli LLEN colis:a-estimer`. Que montre le site pour ces colis ? Redémarrez le worker, et regardez à nouveau.

:::

<details>
<summary>Corrigé</summary>

```bash
docker compose stop worker
# enregistrer cinq colis, par le site ou avec curl
docker compose exec redis redis-cli LLEN colis:a-estimer
docker compose start worker
sleep 4
docker compose exec redis redis-cli LLEN colis:a-estimer
```

La première mesure donne 5, la seconde 0. Pendant l'arrêt du worker, l'API a continué d'accepter les colis : ils apparaissent sur le site avec le statut « enregistré » et une livraison « en cours de calcul ». Dès que le worker revient, il vide la file et les colis passent à « estimé ». Une panne du worker ralentit Colis sans le casser : c'est l'intérêt d'une file entre deux composants.

</details>

:::exercice[Exercice 3 : un port configurable]

Modifiez `compose.yaml` pour que le port publié par `web` soit lu dans la variable `COLIS_PORT`, avec 8080 comme valeur par défaut. Vérifiez avec `COLIS_PORT=9090 docker compose config`.

:::

<details>
<summary>Corrigé</summary>

```yaml
    ports:
      - "${COLIS_PORT:-8080}:80"
```

```bash
COLIS_PORT=9090 docker compose config | grep -A4 'ports:'
```

```sortie
    ports:
      - mode: ingress
        target: 80
        published: "9090"
        protocol: tcp
```

La forme `${VARIABLE:-défaut}` utilise la valeur par défaut quand la variable est absente ou vide. Vous pouvez aussi ajouter `COLIS_PORT=9090` dans le fichier `.env`. C'est utile quand deux personnes n'ont pas les mêmes ports libres, ou pour lancer deux copies du projet sur la même machine (avec l'option `-p` de `docker compose`, qui change le nom du projet).

</details>

:::exercice[Exercice 4 : stop ou down ?]

Pour chacune de ces situations, quelle commande choisissez-vous : `stop`, `down` ou `down -v` ? Vous partez déjeuner et voulez libérer de la mémoire. Vous avez modifié `compose.yaml` et voulez repartir de conteneurs neufs sans perdre les colis. Vous voulez revenir à une base vide pour refaire le chapitre depuis le début.

:::

<details>
<summary>Corrigé</summary>

Pour une pause, `docker compose stop` : tout est conservé, et `docker compose start` relance les mêmes conteneurs en quelques secondes. Après une modification du fichier, `docker compose up -d` suffit en général, puisqu'il recrée ce qui a changé ; `docker compose down` puis `up -d` repart de conteneurs entièrement neufs, et les données survivent dans le volume nommé. Pour repartir de zéro, `docker compose down -v`, en sachant que les colis seront définitivement perdus.

</details>

## Accès aux interfaces

| Interface | Adresse |
|---|---|
| Site de Colis | http://localhost:8080 |
| API, par nginx | http://localhost:8080/api/sante, http://localhost:8080/api/colis |

## Nettoyer

Arrêtez Colis quand vous avez terminé. `stop` garde tout pour la prochaine fois ; `down -v` supprime aussi les données :

```bash
docker compose stop        # pause
docker compose down -v     # tout supprimer, données comprises
```

Le défi de la partie I vous attend : conteneuriser seul une application que vous ne connaissez pas.
