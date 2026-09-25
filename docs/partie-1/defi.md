---
title: Défi I, conteneuriser une application inconnue
sidebar_label: Défi I
description: Conteneuriser seul une petite application Node.js et Redis, selon un cahier des charges vérifiable, puis comparer avec un corrigé commenté.
partie: 1
plaque: Défi I
---

Une équipe vous confie un petit service écrit en Node.js : un compteur de visites. Chaque requête sur `/visite` incrémente un compteur stocké dans Redis et renvoie sa valeur. Le service tourne sur le poste de son auteur, avec Node et Redis installés à la main. Votre mission : le livrer sous forme de conteneurs, démarrables d'une seule commande, selon les exigences de l'équipe d'exploitation.

Ce défi n'a pas de pas-à-pas. Tout ce qu'il demande a été vu dans les chapitres 1 à 7, mais pas forcément avec Node.js : une partie du travail consiste justement à transposer ce que vous savez à une technologie que vous connaissez moins. Prenez le temps de chercher dans la documentation des images officielles avant d'ouvrir le corrigé.

## Le code

Téléchargez [l'archive du compteur](pathname:///kits/defi-1-compteur.tar.gz) et décompressez-la. Elle contient trois fichiers :

- `server.js`, le service lui-même, une cinquantaine de lignes ;
- `package.json`, qui déclare l'unique dépendance, le client `redis` ;
- `package-lock.json`, qui fige la version exacte de toutes les dépendances, directes et indirectes.

Le service lit deux variables d'environnement : `REDIS_URL`, l'adresse de Redis (par défaut `redis://localhost:6379`), et `PORT`, le port d'écoute (par défaut 3000). Il répond sur trois chemins : `/visite` incrémente et renvoie le compteur, `/sante` répond `ok` si Redis est joignable et `503` sinon, tout le reste renvoie `404`. Lisez `server.js` en entier avant de commencer : un détail de ce code compte pour l'une des exigences.

## Le cahier des charges

L'équipe d'exploitation demande un `Dockerfile`, un `.dockerignore` et un `compose.yaml` qui satisfont les exigences suivantes.

1. L'image s'appelle `compteur:1.0`, est construite à partir de l'image officielle `node:24-alpine`, et pèse moins de 200 Mo.
2. Le service ne tourne pas en `root` dans le conteneur.
3. Modifier `server.js` puis reconstruire ne réinstalle pas les dépendances.
4. Les dépendances sont installées exactement dans les versions de `package-lock.json`, sans les paquets de développement.
5. `docker compose up -d` démarre Redis puis le compteur, et le compteur ne démarre qu'une fois Redis prêt à répondre.
6. Le compteur a une sonde de santé qui utilise sa route `/sante`.
7. Le port 3000 du compteur n'est joignable que depuis votre machine, pas depuis le réseau.
8. Redis n'est joignable par aucun port de votre machine.
9. La valeur du compteur survit à un `docker compose down` suivi d'un `docker compose up -d`.
10. `docker compose stop app` prend moins de deux secondes.
11. Un conteneur qui plante est relancé automatiquement.

## La grille de vérification

Votre solution est complète quand chacune de ces commandes donne le résultat attendu. Lancez-les depuis le dossier du projet.

| Exigence | Commande | Résultat attendu |
|---|---|---|
| 1 | `docker image ls compteur:1.0` | une taille inférieure à 200 Mo |
| 2 | `docker compose exec app id` | un `uid` différent de 0 |
| 3 | modifier `server.js`, puis `docker compose build --progress=plain app` | l'étape qui installe les dépendances est `CACHED` |
| 4 | `docker compose exec app ls node_modules` | `redis` et ses dépendances, rien d'autre |
| 5 et 6 | `docker compose up -d --wait` puis `docker compose ps` | les deux services `(healthy)` |
| 7 | `ss -ltn \| grep ':3000 '` | une écoute sur `127.0.0.1:3000` seulement |
| 8 | `docker compose ps redis` | aucune flèche `->` dans la colonne `PORTS` |
| 9 | `curl -s 127.0.0.1:3000/visite` trois fois, `docker compose down`, `docker compose up -d --wait`, puis de nouveau `curl` | le compteur reprend à 4 |
| 10 | `time docker compose stop app` | moins de 2 secondes |
| 11 | `docker compose exec app kill 1`, puis `docker compose ps app` après quelques secondes | le service est de nouveau `Up` |

Pour l'exigence 11, `kill 1` envoie SIGTERM au processus principal depuis l'intérieur du conteneur. Selon votre solution pour l'exigence 10, le processus principal ne sera peut-être pas celui que vous croyez : c'est normal, et c'est justement ce qu'il faut comprendre.

## Indices

Ouvrez-les un par un, seulement si vous êtes bloqué.

<details>
<summary>Indice 1 : installer les dépendances d'un projet Node.js</summary>

`npm install` résout les versions à partir de `package.json` et peut mettre à jour le verrou. `npm ci` installe exactement ce que dit `package-lock.json`, et échoue si les deux fichiers ne concordent pas : c'est la commande faite pour les constructions reproductibles. Son option `--omit=dev` laisse de côté les dépendances de développement.

</details>

<details>
<summary>Indice 2 : un utilisateur tout prêt</summary>

Les images officielles de Node.js contiennent déjà un utilisateur non privilégié. Cherchez son nom dans la documentation de l'image, ou avec `docker run --rm node:24-alpine cat /etc/passwd`.

</details>

<details>
<summary>Indice 3 : le détail de server.js</summary>

Cherchez dans `server.js` ce qui se passe quand le processus reçoit SIGTERM. Puis relisez la section du chapitre 2 sur le processus numéro 1. Compose a une option qui correspond à `docker run --init`.

</details>

<details>
<summary>Indice 4 : où Redis écrit-il ses données ?</summary>

Par défaut, Redis garde tout en mémoire et n'écrit sur le disque que de temps en temps. Son option `--appendonly yes` lui fait enregistrer chaque modification. La documentation de l'image officielle indique dans quel dossier il écrit.

</details>

## Corrigé

Ne l'ouvrez qu'après avoir essayé. Il a été vérifié avec la grille ci-dessus sur le poste du cours.

<details>
<summary>Voir le corrigé commenté</summary>

```dockerfile title="Dockerfile"
FROM node:24-alpine

ENV NODE_ENV=production
WORKDIR /app

# les dépendances d'abord : cette couche reste en cache tant que les fichiers npm ne changent pas
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY server.js ./

# l'image officielle fournit un utilisateur non privilégié, « node »
USER node
EXPOSE 3000
CMD ["node", "server.js"]
```

```text title=".dockerignore"
node_modules/
npm-debug.log
Dockerfile
compose.yaml
.dockerignore
```

```yaml title="compose.yaml"
name: compteur

services:
  app:
    build: .
    image: compteur:1.0
    # le programme ne gère pas SIGTERM : tini (init: true) le relaie et l'arrêt reste immédiat
    init: true
    environment:
      REDIS_URL: redis://redis:6379
    ports:
      - "127.0.0.1:3000:3000"
    depends_on:
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:3000/sante"]
      interval: 3s
      timeout: 2s
      retries: 5
    restart: unless-stopped

  redis:
    image: redis:8.8-alpine
    # appendonly : Redis écrit chaque modification sur le disque, dans /data
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - donnees:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 2s
      timeout: 2s
      retries: 10
    restart: unless-stopped

volumes:
  donnees:
```

**Exigences 1 à 4, l'image.** Elle suit le schéma du chapitre 4 : dépendances d'abord, code ensuite. `npm ci --omit=dev` installe exactement le verrou, sans les paquets de développement, et `npm cache clean --force` retire de l'image le cache de téléchargement de npm, comme `PIP_NO_CACHE_DIR` pour Python. `NODE_ENV=production` est la convention de l'écosystème Node.js : beaucoup de bibliothèques s'en servent pour désactiver leurs fonctions de débogage. L'utilisateur `node` (uid 1000) est fourni par l'image. L'image obtenue pèse 179 Mo, dont l'essentiel est Node.js lui-même : le chapitre 13 montrera comment descendre bien plus bas.

**Exigence 10, le piège.** `server.js` n'installe aucun gestionnaire pour SIGTERM. Node.js, lancé comme processus numéro 1, est alors dans la situation de `sleep` au chapitre 2 : le noyau ne lui livre pas le signal. Sans rien faire, la mesure donne :

```sortie
10.38 s
code 137
```

Deux solutions sont acceptables. La première, celle du corrigé, est `init: true`, l'équivalent Compose de `docker run --init` : `tini` devient le processus 1 et relaie SIGTERM à Node.js, qui applique alors l'action par défaut et s'arrête. La mesure tombe à 0,34 s. La seconde est d'ajouter à `server.js` un gestionnaire (`process.on('SIGTERM', ...)`) qui ferme le serveur et la connexion à Redis : c'est la meilleure solution à long terme, parce que le service peut alors finir les requêtes en cours avant de s'arrêter, mais elle demande de modifier le code d'une autre équipe.

**Exigence 11.** Avec `init: true`, `kill 1` envoie SIGTERM à `tini`, qui le relaie à Node.js ; le conteneur s'arrête et `restart: unless-stopped` le relance. Sans `init`, `kill 1` viserait Node.js directement, qui ignorerait le signal : rien ne se passerait, ce qui montre bien le problème.

**Exigences 5 et 6, l'ordre.** `depends_on` avec `service_healthy` attend que `redis-cli ping` réponde. La sonde du compteur utilise `wget`, présent dans Alpine grâce à BusyBox ; `/sante` répond `503` tant que Redis n'est pas joint, et `wget` échoue alors. `docker compose up -d --wait` permet de vérifier les deux d'un coup.

**Exigences 7 et 8, les ports.** Le compteur est publié sur `127.0.0.1` seulement ; Redis n'est pas publié du tout, et le compteur le joint par son nom, `redis`, sur le réseau du projet.

**Exigence 9, les données.** Redis écrit dans `/data` (c'est indiqué dans la documentation de l'image, et `docker image inspect redis:8.8-alpine` montre un `VOLUME` à cet endroit). Sans volume nommé, Docker créerait un volume anonyme, que `docker compose down` suivi de `up` remplacerait par un neuf : le compteur repartirait de zéro. Avec le volume `donnees` et `--appendonly yes`, la vérification donne bien :

```sortie
{"visites":1,"hote":"c229f592a860"}
{"visites":2,"hote":"c229f592a860"}
{"visites":3,"hote":"c229f592a860"}
...
{"visites":4,"hote":"fc79a507e0ae"}
```

Le nom de machine a changé, puisque le conteneur a été recréé ; le compteur, lui, a continué.

</details>

## Et maintenant

Si vous avez réussi ce défi sans le corrigé, vous maîtrisez l'usage quotidien des conteneurs. La partie II descend sous le capot : ce qu'est un namespace, comment un cgroup limite la mémoire, comment les couches d'une image deviennent un système de fichiers, et ce qui se passe entre `docker run` et le noyau. Si vous êtes pressé de passer à Kubernetes, la partie III reprend Colis là où le chapitre 7 le laisse ; revenez ensuite à la partie II.

Pour faire le ménage du défi :

```bash
docker compose down -v
docker image rm compteur:1.0
```
