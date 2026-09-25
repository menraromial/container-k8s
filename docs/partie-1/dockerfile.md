---
title: Écrire un Dockerfile
sidebar_label: 4. Écrire un Dockerfile
description: Construire l'image de l'API de Colis, comprendre chaque instruction d'un Dockerfile, tirer parti du cache, maîtriser le contexte de construction et faire en sorte que le programme reçoive bien les signaux.
partie: 1
chapitre: '4'
---

import cacheDockerfile from '@site/src/figures/cache-dockerfile.svg';

Jusqu'ici, toutes les images venaient d'ailleurs : nginx, Alpine, Python, publiées par d'autres. Ce chapitre construit la première image du cours, celle de l'API de Colis. On commencera par le Dockerfile que presque tout le monde écrit la première fois. Il fonctionne, mais il a trois défauts : il met dix secondes à s'arrêter, il reconstruit tout à la moindre modification du code, et il embarque ce qu'il ne devrait pas. On les corrigera un par un, en mesurant à chaque fois ce qu'on gagne.

## Le code de Colis

Téléchargez [l'archive de départ de Colis](pathname:///kits/colis-app-depart.tar.gz), décompressez-la et placez-vous dans le dossier de l'API :

```bash
tar -xzf colis-app-depart.tar.gz
cd colis/app
find . -type f | sort
```

```sortie
./colis/__init__.py
./colis/app.py
./colis/config.py
./colis/delais.py
./colis/file.py
./colis/modele.py
./colis/purge.py
./colis/stockage.py
./colis/worker.py
./requirements-dev.txt
./requirements.txt
./tests/__init__.py
./tests/test_api.py
./tests/test_delais.py
```

Le paquet Python `colis` contient trois programmes. `app.py` est l'API HTTP, écrite avec FastAPI et servie par Uvicorn ; `worker.py` est le worker qui calcule les dates de livraison ; `purge.py` supprime les vieux colis. Les trois lisent leur configuration dans des variables d'environnement (`config.py`) : `COLIS_DB` pour l'adresse de la base PostgreSQL, `COLIS_REDIS` pour celle de la file Redis. Quand elles sont absentes, l'API garde les colis en mémoire et calcule les dates de livraison elle-même, sans file. C'est ce mode autonome qui nous servira dans ce chapitre ; on branchera PostgreSQL et Redis aux chapitres 5 et 6.

Le fichier `requirements.txt` fixe la version exacte de chaque dépendance :

```text title="requirements.txt"
fastapi==0.141.1
uvicorn==0.54.0
psycopg[binary]==3.3.6
redis==8.1.0
```

Vous n'avez pas besoin d'avoir Python sur votre machine : tout se passera dans des conteneurs.

## Un premier Dockerfile

Un Dockerfile est un fichier texte qui décrit, instruction par instruction, comment construire une image. Créez celui-ci dans `colis/app` :

```dockerfile title="Dockerfile"
FROM python:3.14-slim
WORKDIR /app
COPY . .
RUN pip install -r requirements.txt
CMD uvicorn colis.app:app --host 0.0.0.0 --port 8000
```

Cinq lignes, cinq instructions.

`FROM` choisit l'image de départ. Toute image est construite au-dessus d'une autre, et on hérite de tout ce qu'elle contient : ici, un système Debian minimal et Python 3.14. Les couches de `python:3.14-slim` deviendront les premières couches de notre image.

`WORKDIR` fixe le dossier de travail pour la suite, et le crée s'il n'existe pas. Les chemins relatifs des instructions suivantes, et le dossier courant du programme au démarrage, seront `/app`.

`COPY . .` copie le contenu du dossier de construction (le premier `.`) dans le dossier de travail de l'image (le second `.`, donc `/app`).

`RUN` exécute une commande pendant la construction, dans un conteneur temporaire, et enregistre ce qu'elle a modifié dans une nouvelle couche. Ici, `pip` installe les dépendances.

`CMD` indique la commande à lancer quand on démarrera un conteneur à partir de l'image. Elle n'est pas exécutée pendant la construction. `--host 0.0.0.0` demande à Uvicorn d'écouter sur toutes les interfaces réseau du conteneur : par défaut il n'écouterait que sur `127.0.0.1`, l'interface locale du conteneur lui-même, et le port publié ne mènerait nulle part.

Construisons :

```bash
docker build -t colis:etape1 .
```

L'option `-t` donne un nom à l'image, et le `.` final désigne le dossier de construction, qu'on appelle le **contexte**. BuildKit, le moteur de construction de Docker, détaille chaque étape :

```sortie
#0 building with "default" instance using docker driver

#1 [internal] load build definition from Dockerfile
#1 transferring dockerfile: 172B done
#1 WARN: JSONArgsRecommended: JSON arguments recommended for CMD to prevent unintended behavior related to OS signals (line 5)
#1 DONE 0.0s
...
#6 [internal] load build context
#6 transferring context: 18.62kB done
#6 DONE 0.0s

#7 [3/4] COPY . .
#7 DONE 0.1s

#8 [4/4] RUN pip install -r requirements.txt
#8 2.396 Collecting fastapi==0.141.1 (from -r requirements.txt (line 1))
#8 2.642   Downloading fastapi-0.141.1-py3-none-any.whl.metadata (27 kB)
...
#8 9.154 WARNING: Running pip as the 'root' user can result in broken permissions and conflicting behaviour with the system package manager, ...
#8 DONE 9.5s

#9 exporting to image
#9 exporting layers 0.4s done
#9 writing image sha256:f76757b05a0b91ca74797c7e93f4f51611b950231159673b538c114d7dedc64d done
#9 naming to docker.io/library/colis:etape1 0.0s done
#9 DONE 0.4s

 1 warning found (use docker --debug to expand):
 - JSONArgsRecommended: JSON arguments recommended for CMD to prevent unintended behavior related to OS signals (line 5)
```

La construction a pris 10,4 secondes sur le poste du cours, dont 9,5 pour `pip`. Deux avertissements méritent déjà votre attention. Celui de pip rappelle qu'installer des paquets en tant que `root` peut abîmer un système ; dans une image, qui ne sert qu'à cette application, le risque ne se pose pas, et on le fera taire proprement plus loin. Celui de BuildKit, `JSONArgsRecommended`, est plus sérieux : il annonce exactement le premier problème que nous allons rencontrer.

## Lancer l'API

```bash
docker run -d --name api -p 8000:8000 colis:etape1
curl -s localhost:8000/sante
curl -s -X POST localhost:8000/colis -H 'Content-Type: application/json' \
     -d '{"destinataire": "Ada Lovelace", "depart": "Paris", "arrivee": "Brest", "poids_kg": 2.5}'
curl -s localhost:8000/colis/1
```

```sortie
{"statut":"ok","version":"1.0.0","hote":"9d9cd5a63038"}
{"id":1,"destinataire":"Ada Lovelace","depart":"Paris","arrivee":"Brest","poids_kg":2.5,"statut":"estimé","cree_le":"2026-09-25T09:31:13.555167Z","livraison_estimee":"2026-09-28","livre_le":null}
{"id":1,"destinataire":"Ada Lovelace","depart":"Paris","arrivee":"Brest","poids_kg":2.5,"statut":"estimé","cree_le":"2026-09-25T09:31:13.555167Z","livraison_estimee":"2026-09-28","livre_le":null}
```

L'API répond. Le champ `hote` est le nom de machine du conteneur, c'est-à-dire le début de son identifiant : il nous servira plus tard à savoir quelle copie de l'API a répondu. Le colis a été enregistré et sa livraison estimée à trois jours, puisque Paris et Brest sont à environ 660 km par la route. FastAPI génère aussi une documentation interactive de l'API : ouvrez http://localhost:8000/docs dans votre navigateur.

```bash
docker logs api
```

```sortie
INFO:     Started server process [7]
INFO:     Waiting for application startup.
INFO:     Application startup complete.
INFO:     Uvicorn running on http://0.0.0.0:8000 (Press CTRL+C to quit)
INFO:     172.17.0.1:37938 - "GET /sante HTTP/1.1" 200 OK
INFO:     172.17.0.1:37942 - "POST /colis HTTP/1.1" 201 Created
INFO:     172.17.0.1:37950 - "GET /colis/1 HTTP/1.1" 200 OK
```

Regardez la première ligne : `Started server process [7]`. Uvicorn se présente comme le processus numéro 7, et non comme le numéro 1. Qui est donc le processus 1 ?

## Le premier défaut : qui est le processus numéro 1 ?

Le fichier `/proc/1/cmdline` contient la ligne de commande du processus 1 :

```bash
docker exec api cat /proc/1/cmdline | tr '\0' ' '
docker top api -o pid,ppid,cmd
```

```sortie
/bin/sh -c uvicorn colis.app:app --host 0.0.0.0 --port 8000
PID                 PPID                CMD
362910              362889              /bin/sh -c uvicorn colis.app:app --host 0.0.0.0 --port 8000
362990              362910              /usr/local/bin/python3.14 /usr/local/bin/uvicorn colis.app:app --host 0.0.0.0 --port 8000
```

Le processus 1 est un shell, `/bin/sh -c`, et Uvicorn est son enfant. C'est la conséquence de la façon dont on a écrit `CMD`. Une instruction `CMD` (comme `ENTRYPOINT` et `RUN`) s'écrit de deux façons[^dockerfile-ref] :

| Forme | Écriture | Ce que Docker exécute |
|---|---|---|
| shell | `CMD uvicorn colis.app:app ...` | `/bin/sh -c "uvicorn colis.app:app ..."` |
| exec | `CMD ["uvicorn", "colis.app:app", ...]` | `uvicorn` directement, sans shell |

La forme shell est pratique pour écrire des variables ou des enchaînements de commandes, mais elle intercale un shell. Et vous connaissez la suite depuis le chapitre 2 : ce shell est le PID 1, il n'a pas de gestionnaire pour SIGTERM, le noyau ne lui livre donc pas le signal, et il ne le transmet pas non plus à Uvicorn :

```bash
time docker stop api
docker inspect api --format 'code {{.State.ExitCode}}'
```

```sortie
api
10.31 s
code 137
```

Dix secondes d'attente, puis SIGKILL. Uvicorn n'a pas eu la moindre chance de terminer les requêtes en cours. Passons à la forme exec :

```dockerfile title="Dockerfile" {5}
FROM python:3.14-slim
WORKDIR /app
COPY . .
RUN pip install -r requirements.txt
CMD ["uvicorn", "colis.app:app", "--host", "0.0.0.0", "--port", "8000"]
```

Supprimons l'ancien conteneur, reconstruisons, et refaisons les mêmes mesures :

```bash
docker rm api
docker build -t colis:etape2 .
docker run -d --name api -p 8000:8000 colis:etape2
docker exec api cat /proc/1/cmdline | tr '\0' ' '
time docker stop api
docker inspect api --format 'code {{.State.ExitCode}}'
```

Le processus 1 est maintenant Uvicorn lui-même, et l'arrêt change du tout au tout :

```sortie
/usr/local/bin/python3.14 /usr/local/bin/uvicorn colis.app:app --host 0.0.0.0 --port 8000
api
0.43 s
code 0
```

Et le journal (`docker logs api`) montre qu'Uvicorn a fermé proprement :

```sortie
INFO:     Shutting down
INFO:     Waiting for application shutdown.
INFO:     Application shutdown complete.
INFO:     Finished server process [1]
```

Moins d'une demi-seconde, et un code 0. L'écriture entre crochets n'est pas une affaire de style : elle décide de qui reçoit les signaux.

Il arrive qu'on ait vraiment besoin d'un shell, par exemple pour afficher un message ou préparer un fichier avant de lancer le programme. Écrire `sh -c 'echo démarrage de Colis && uvicorn ...'` reproduit le problème : mesuré sur le poste du cours, l'arrêt reprend 10,26 s et le code 137. La parade est le mot-clé `exec` du shell, qui remplace le shell par le programme au lieu de le lancer comme enfant : avec `sh -c 'echo démarrage de Colis && exec uvicorn ...'`, Uvicorn redevient le PID 1 et l'arrêt tombe à 0,52 s. Retenez la règle : **le programme principal d'un conteneur doit être son processus numéro 1**, soit par la forme exec, soit par `exec` à la fin d'un script.

:::panne[JSONArgsRecommended: JSON arguments recommended for CMD]

BuildKit affiche cet avertissement pour tout `CMD` ou `ENTRYPOINT` écrit en forme shell. Il ne bloque pas la construction, mais il signale presque toujours un conteneur qui mettra dix secondes à s'arrêter. Réécrivez l'instruction en forme exec, avec des guillemets doubles : `CMD ["programme", "arg1", "arg2"]`. Des guillemets simples ne seraient pas du JSON valide, et Docker reviendrait silencieusement à la forme shell.

:::

## Le deuxième défaut : tout est reconstruit

Corrigeons un bogue imaginaire : ajoutez une ligne de commentaire à la fin de `colis/app.py`, et reconstruisez. On demande à BuildKit un affichage détaillé (`--progress=plain`) pour voir ce qu'il fait de chaque étape :

```bash
echo "# correction" >> colis/app.py
docker build --progress=plain -t colis:etape1 .
```

```sortie
#6 [2/4] WORKDIR /app
#6 CACHED
#7 [3/4] COPY . .
#7 DONE 0.1s
#8 [4/4] RUN pip install -r requirements.txt
#8 DONE 9.3s
```

Une ligne de commentaire, et `pip` a tout retéléchargé et tout réinstallé : 10,30 secondes de construction. Pour comprendre, il faut savoir comment fonctionne le cache.

BuildKit garde le résultat de chaque étape. Avant d'exécuter une instruction, il calcule une clé qui dépend de l'étape précédente et de l'instruction elle-même ; pour un `COPY`, la clé inclut une empreinte du contenu des fichiers copiés. Si la clé est déjà connue, il réutilise la couche (`CACHED`) ; sinon, il exécute l'instruction, et toutes celles qui suivent doivent être refaites, puisque leur point de départ a changé. Ici, `COPY . .` copie tout le dossier, code compris : la moindre modification du code invalide cette étape, et donc l'installation des dépendances qui vient après.

La solution est d'ordonner les instructions de ce qui change le moins à ce qui change le plus. Les dépendances changent rarement ; le code change tout le temps. On copie donc d'abord `requirements.txt` seul, on installe, et on copie le code ensuite :

```dockerfile title="Dockerfile" {3-5}
FROM python:3.14-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY colis/ colis/
CMD ["uvicorn", "colis.app:app", "--host", "0.0.0.0", "--port", "8000"]
```

La première construction de cette version installe les dépendances une dernière fois. Modifions à nouveau le code et reconstruisons :

```sortie
#6 [2/5] WORKDIR /app
#6 CACHED
#7 [3/5] COPY requirements.txt .
#7 CACHED
#8 [4/5] RUN pip install -r requirements.txt
#8 CACHED
#9 [5/5] COPY colis/ colis/
#9 DONE 0.1s
```

Tout est en cache jusqu'à la copie du code, seule étape refaite. La construction prend 0,63 seconde. Le conteneur `api` arrêté plus haut ne sert plus : `docker rm api`.

<Figure svg={cacheDockerfile} num="4.1" alt="Deux Dockerfiles après une modification du code. À gauche, COPY . . est refait, puis pip est refait : 10,30 s. À droite, tout est en cache sauf COPY colis/ : 0,63 s.">
Ce que BuildKit refait après une modification d'une ligne de code, selon l'ordre des instructions. Durées mesurées sur le poste du cours.
</Figure>

Seize fois plus rapide, pour avoir échangé deux lignes. Sur un vrai projet, avec des centaines de dépendances et des constructions lancées des dizaines de fois par jour par une chaîne d'intégration continue, ce gain se compte en heures.

:::warning[Le cache ne voit que le texte des instructions RUN]

Pour un `COPY`, BuildKit regarde le contenu des fichiers. Pour un `RUN`, il ne regarde que le texte de la commande. Une instruction `RUN apt-get update` reste donc en cache indéfiniment, même quand la liste des paquets de Debian a changé depuis des semaines : l'image continuera d'embarquer les versions de la première construction, correctifs de sécurité en moins. On évite le problème en mettant `apt-get update` et `apt-get install` dans la même instruction `RUN`, et en reconstruisant régulièrement sans cache (`docker build --no-cache`).

:::

## Le troisième défaut : ce qu'on envoie au constructeur

Le contexte de construction est tout le dossier désigné par le `.` de `docker build`. BuildKit le lit avant de commencer, et c'est dans ce contexte que `COPY` va chercher les fichiers. Tant qu'il ne contient que quelques fichiers Python, personne ne s'en soucie : 18,62 Ko à la première construction.

Mais un dossier de développement contient souvent bien plus. Un développeur Python y a presque toujours un environnement virtuel, `.venv`, créé pour travailler sans conteneur. Sur le poste du cours, celui de Colis pèse 59 Mo, contre 72 Ko pour tout le reste du dossier. Reprenons le premier Dockerfile, avec son `COPY . .` (mais en gardant la forme exec pour `CMD`), et construisons avec ce `.venv` dans le dossier :

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
docker build --progress=plain -t colis:etape3 .
```

```sortie
#6 [internal] load build context
#6 transferring context: 55.49MB 0.4s done
```

55 Mo transférés, et le contenu de l'image le confirme :

```bash
docker run --rm colis:etape3 sh -c 'ls -a /app; du -sh /app'
```

```sortie
.
..
.venv
Dockerfile
colis
requirements-dev.txt
requirements.txt
tests
59M	/app
```

L'environnement virtuel, les tests, le Dockerfile lui-même : tout est dans l'image, qui a grossi de 59 Mo pour rien. Le problème ne s'arrête pas à la taille. Si le dossier contenait un fichier `.env` avec des mots de passe, ou une clé SSH, ils seraient dans l'image, et donc chez tous ceux qui la téléchargeront. C'est une fuite de secrets très répandue.

Le fichier `.dockerignore`, placé à côté du Dockerfile, liste ce qui ne doit jamais partir dans le contexte, avec la même syntaxe qu'un `.gitignore` :

```text title=".dockerignore"
# ce qui ne doit pas partir dans le contexte de construction
.venv/
__pycache__/
.pytest_cache/
tests/
requirements-dev.txt
Dockerfile
.dockerignore
```

Avec lui, le même Dockerfile ne copie plus que l'essentiel :

```sortie
.
..
colis
requirements.txt
52K	/app
```

52 Ko au lieu de 59 Mo. Prenez l'habitude d'écrire le `.dockerignore` en même temps que le Dockerfile, et même avant d'y mettre un `COPY . .`.

:::panne[failed to calculate checksum ... not found]

`COPY` ne trouve pas un fichier dans le contexte. Voici le message pour un fichier qui n'existe pas :

```sortie
#6 ERROR: failed to calculate checksum of ref 840c7e9a-...: "/introuvable.txt": not found
------
Dockerfile.erreur:2
--------------------
   1 |     FROM python:3.14-slim
   2 | >>> COPY introuvable.txt .
--------------------
ERROR: failed to build: failed to solve: failed to compute cache key: ...: "/introuvable.txt": not found
```

Trois causes possibles : le fichier n'existe vraiment pas, le chemin est écrit relativement au Dockerfile au lieu du contexte, ou le fichier est exclu par `.dockerignore`. Dans ce dernier cas, BuildKit vous aide avec un avertissement supplémentaire : `CopyIgnoredFile: Attempting to Copy file "tests" that is excluded by .dockerignore`.

:::

## Configurer l'image

Il reste à régler ce que l'image fera au démarrage. Quatre instructions ne produisent aucun fichier, mais changent la configuration de l'image.

### ENV : les variables d'environnement

`ENV` définit des variables d'environnement pour les instructions suivantes et pour les conteneurs lancés à partir de l'image. Une variable compte particulièrement pour une application Python dans un conteneur : `PYTHONUNBUFFERED`. Quand la sortie standard n'est pas un terminal, ce qui est le cas dans un conteneur lancé avec `-d`, Python accumule ce qu'on lui demande d'afficher et ne l'écrit que par blocs. Démonstration, avec un programme qui affiche une ligne puis attend vingt secondes :

```bash
docker run -d --name tampon python:3.14-slim python -c 'import time; print("colis 1 estimé"); time.sleep(20)'
sleep 3; docker logs tampon
docker run -d --name direct -e PYTHONUNBUFFERED=1 python:3.14-slim python -c 'import time; print("colis 1 estimé"); time.sleep(20)'
sleep 3; docker logs direct
```

Trois secondes après le démarrage, le journal du premier conteneur est vide ; celui du second affiche `colis 1 estimé`. Sans cette variable, un worker qui tourne depuis des heures peut ne rien montrer dans `docker logs`, ou montrer ses messages avec un grand retard, et on perd un temps fou à chercher une panne qui n'existe pas. `docker rm -f tampon direct` fait le ménage.

### USER : ne pas tourner en root

Par défaut, les processus d'un conteneur tournent sous l'utilisateur `root` :

```bash
docker run --rm python:3.14-slim id
```

```sortie
uid=0(root) gid=0(root) groups=0(root)
```

C'est le `root` du conteneur, isolé par les namespaces, mais c'est aussi le numéro 0 pour le noyau de la machine. Si une faille permettait de sortir du conteneur, on en sortirait avec tous les droits. Le chapitre 12 détaille les protections qui existent ; la première, la plus simple, est de ne pas tourner en `root` quand on n'en a pas besoin. Une API web n'en a jamais besoin. On crée donc un utilisateur ordinaire, et on le désigne avec `USER` :

```dockerfile
RUN useradd --uid 10001 --user-group --no-create-home colis
USER colis
```

Le numéro 10001 est choisi délibérément élevé, pour ne correspondre à aucun utilisateur existant de la machine hôte. Toutes les instructions qui suivent `USER`, et le programme principal, tournent sous cet utilisateur. Les fichiers copiés avant appartiennent à `root` et restent lisibles par tous : l'application peut les lire, mais pas les modifier, ce qui est exactement ce qu'on veut.

### EXPOSE : une déclaration, pas une ouverture

`EXPOSE 8000` déclare que l'application écoute sur le port 8000. C'est de la documentation : l'instruction n'ouvre rien. Lancez l'image finale sans `-p` :

```bash
docker run -d --name sans-port colis:1.0
docker ps --filter name=sans-port --format '{{.Ports}}'
curl -s -m 2 localhost:8000/sante; echo "curl code=$?"
```

```sortie
8000/tcp
curl code=7
```

`docker ps` affiche le port déclaré, `8000/tcp`, mais sans flèche vers un port de la machine ; `curl` échoue avec le code 7, « connexion impossible ». Seul `-p` publie un port. `EXPOSE` reste utile : il informe ceux qui liront l'image, et des outils s'en servent, comme `docker run -P` qui publie tous les ports déclarés sur des ports choisis au hasard.

### LABEL : dire d'où vient l'image

`LABEL` attache des métadonnées à l'image. L'OCI a normalisé une série de clés, `org.opencontainers.image.*`, pour indiquer le titre, la version, la source[^oci-annotations]. Vous les avez croisées dans l'index de nginx au chapitre 3 ; mettons-les sur Colis.

## Le Dockerfile de Colis

Voici le Dockerfile complet, qui reprend tout ce qui précède. C'est celui du kit de Colis :

```dockerfile title="Dockerfile"
# Image de Colis : une seule image pour l'API, le worker et la purge.
# Construite au chapitre 4 ; allégée et durcie au chapitre 13.
FROM python:3.14-slim

LABEL org.opencontainers.image.title="colis" \
      org.opencontainers.image.description="API, worker et purge de Colis, application fil rouge du cours" \
      org.opencontainers.image.source="https://github.com/menraromial/container-k8s" \
      org.opencontainers.image.version="1.0.0"

# PYTHONUNBUFFERED : les print() arrivent tout de suite dans docker logs
# PYTHONDONTWRITEBYTECODE : pas de fichiers .pyc écrits à l'exécution
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# les dépendances changent rarement : leur couche reste en cache
COPY requirements.txt .
RUN pip install -r requirements.txt

# un utilisateur sans privilèges, sans dossier personnel
RUN useradd --uid 10001 --user-group --no-create-home colis

# le code change souvent : il vient en dernier
COPY colis/ colis/

USER colis
EXPOSE 8000

# forme exec : uvicorn est le PID 1 et reçoit SIGTERM
CMD ["uvicorn", "colis.app:app", "--host", "0.0.0.0", "--port", "8000"]
```

Deux variables sont nouvelles. `PIP_NO_CACHE_DIR=1` empêche pip de garder dans l'image une copie des paquets téléchargés, qui ne servirait plus jamais : mesurée sur le poste du cours, l'image pèse 164 Mo avec ce réglage et 176 Mo sans. `PIP_DISABLE_PIP_VERSION_CHECK=1` évite que pip cherche à chaque construction s'il existe une version plus récente de lui-même.

L'utilisateur est créé après l'installation des dépendances, mais avant la copie du code : cette étape ne change jamais, elle reste en cache, et la copie du code reste la seule étape refaite quand on travaille.

Construisons la version 1.0 :

```bash
docker build -t colis:1.0 .
docker image inspect colis:1.0 --format 'User={{.Config.User}} Cmd={{json .Config.Cmd}} Ports={{json .Config.ExposedPorts}}'
docker image inspect colis:1.0 --format '{{json .Config.Labels}}' | python3 -m json.tool
```

```sortie
User=colis Cmd=["uvicorn","colis.app:app","--host","0.0.0.0","--port","8000"] Ports={"8000/tcp":{}}
{
    "org.opencontainers.image.description": "API, worker et purge de Colis, application fil rouge du cours",
    "org.opencontainers.image.source": "https://github.com/menraromial/container-k8s",
    "org.opencontainers.image.title": "colis",
    "org.opencontainers.image.version": "1.0.0"
}
```

`docker image history` montre la contribution de chaque instruction :

```bash
docker image history colis:1.0 --format 'table {{.CreatedBy}}\t{{.Size}}'
```

```sortie
CREATED BY                                      SIZE
CMD ["uvicorn" "colis.app:app" "--host" "0.0…   0B
EXPOSE [8000/tcp]                               0B
USER colis                                      0B
COPY colis/ colis/ # buildkit                   14.9kB
RUN /bin/sh -c useradd --uid 10001 --user-gr…   4.35kB
RUN /bin/sh -c pip install -r requirements.t…   44.1MB
COPY requirements.txt . # buildkit              69B
WORKDIR /app                                    0B
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECO…   0B
LABEL org.opencontainers.image.title=colis o…   0B
CMD ["python3"]                                 0B
RUN /bin/sh -c set -eux;  for src in idle3 p…   36B
RUN /bin/sh -c set -eux;   savedAptMark="$(a…   37MB
...
```

Au-dessus de l'image Python, notre code pèse 14,9 Ko, et les dépendances 44 Mo. C'est typique : dans la plupart des images, l'application elle-même est une goutte d'eau. Le chapitre 13 montrera comment réduire le reste.

Vérifions l'utilisateur et l'API :

```bash
docker run -d --name api -p 8000:8000 colis:1.0
docker exec api id
curl -s localhost:8000/pret
```

```sortie
uid=10001(colis) gid=10001(colis) groups=10001(colis)
{"stockage":"mémoire","file":"aucune","pret":true}
```

L'API tourne sous l'utilisateur `colis`. La route `/pret` indique d'où elle tire ses données : de la mémoire, sans file d'attente. Ces deux réponses changeront au chapitre 6.

## Une image, trois programmes

La commande donnée à `docker run` après le nom de l'image remplace le `CMD`. La même image peut donc lancer les deux autres programmes de Colis :

```bash
docker run --rm colis:1.0 python -m colis.purge
docker run --rm colis:1.0 python -m colis.worker; echo "code=$?"
```

```sortie
purge : 0 colis livrés depuis plus de 30 jours supprimés
COLIS_REDIS n'est pas défini : le worker n'a pas de file à lire
code=1
```

La purge fonctionne, même si elle n'a rien à purger dans une API vide. Le worker, lui, refuse de démarrer sans file Redis, et le dit, avec un code de sortie non nul. C'est le comportement qu'on veut d'un programme lancé dans un conteneur : échouer tôt, avec un message clair et un code de sortie qui permet à Docker, puis à Kubernetes, de savoir que quelque chose ne va pas.

Construire une seule image pour plusieurs programmes qui partagent le même code est un choix courant : une seule chose à construire, à tester et à publier, et la certitude que l'API et le worker utilisent exactement la même version du code. Kubernetes lancera chacun avec sa propre commande.

## Exercices

:::exercice[Exercice 1 : les tests dans un conteneur]

Exécutez les tests de Colis (`pytest`) sans installer Python sur votre machine, en montant le dossier `colis/app` dans un conteneur `python:3.14-slim`. Veillez à ce que le conteneur n'écrive aucun fichier dans votre dossier.

:::

<details>
<summary>Corrigé</summary>

```bash
docker run --rm -v "$PWD":/src:ro -w /src -e PYTHONDONTWRITEBYTECODE=1 python:3.14-slim \
  sh -c 'pip install -q --root-user-action=ignore -r requirements-dev.txt && python -m pytest -q -p no:cacheprovider'
```

```sortie
..........                                                               [100%]
10 passed in 0.55s
```

L'option `-v "$PWD":/src:ro` monte votre dossier dans le conteneur en lecture seule (`ro`), ce que le chapitre 5 détaille. Sans `:ro`, et sans `PYTHONDONTWRITEBYTECODE=1` ni `-p no:cacheprovider`, Python et pytest écriraient des dossiers `__pycache__` et `.pytest_cache` dans votre dossier, et comme le conteneur tourne en `root`, ces dossiers appartiendraient à `root` : vous ne pourriez plus les supprimer sans `sudo`. C'est exactement ce qui est arrivé pendant la préparation de ce chapitre.

</details>

:::exercice[Exercice 2 : prévoir le cache]

Avec le Dockerfile final de Colis, qu'est-ce qui sera refait si vous modifiez `requirements.txt` pour changer la version de `redis` ? Et si vous modifiez `tests/test_api.py` ? Prévoyez, puis vérifiez avec `docker build --progress=plain`.

:::

<details>
<summary>Corrigé</summary>

Modifier `requirements.txt` invalide `COPY requirements.txt .`, donc aussi l'installation des dépendances, la création de l'utilisateur et la copie du code : tout ce qui suit est refait, et pip réinstalle l'ensemble des paquets. Modifier un test ne change rien : le dossier `tests/` est exclu par `.dockerignore`, il n'entre même pas dans le contexte, et toutes les étapes sont en cache. Cela illustre un intérêt du `.dockerignore` souvent oublié : un fichier exclu ne peut pas invalider le cache.

</details>

:::exercice[Exercice 3 : un point d'entrée]

Écrivez un Dockerfile de trois lignes, basé sur `colis:1.0`, qui produit une image « outil » : `docker run --rm colis:outil` lance la purge, et `docker run --rm colis:outil colis.worker` lance le worker. Utilisez `ENTRYPOINT` et `CMD`.

:::

<details>
<summary>Corrigé</summary>

```dockerfile title="Dockerfile.outil"
FROM colis:1.0
ENTRYPOINT ["python", "-m"]
CMD ["colis.purge"]
```

```bash
docker build -f Dockerfile.outil -t colis:outil .
docker run --rm colis:outil
docker run --rm colis:outil colis.worker
```

```sortie
purge : 0 colis livrés depuis plus de 30 jours supprimés
COLIS_REDIS n'est pas défini : le worker n'a pas de file à lire
```

`ENTRYPOINT` fixe la partie de la commande qui ne change pas ; `CMD` fournit des arguments par défaut, que les arguments de `docker run` remplacent. C'est le schéma de l'image nginx vue au chapitre 3 (`/docker-entrypoint.sh` suivi de `nginx -g "daemon off;"`). L'option `-f` indique un Dockerfile qui ne porte pas le nom par défaut.

</details>

:::exercice[Exercice 4 : le shell nécessaire]

On veut que l'API affiche la date de démarrage dans son journal avant de lancer Uvicorn. Écrivez le `CMD` correspondant, et vérifiez que `docker stop` reste rapide.

:::

<details>
<summary>Corrigé</summary>

```dockerfile
CMD ["sh", "-c", "echo \"démarrage le $(date)\" && exec uvicorn colis.app:app --host 0.0.0.0 --port 8000"]
```

La forme exec lance explicitement `sh -c`, dont on a besoin pour évaluer `$(date)`. Le `exec` devant `uvicorn` remplace le shell par Uvicorn, qui devient le PID 1 : `docker exec api cat /proc/1/cmdline` affiche la commande d'Uvicorn, et `docker stop` rend la main en moins d'une seconde, avec le code 0. Sans `exec`, on retombe sur 10 secondes et le code 137.

</details>

## Nettoyer

```bash
docker rm -f api sans-port
docker image rm colis:etape1 colis:etape2 colis:etape3 colis:outil
```

Gardez `colis:1.0` : c'est l'image qu'utiliseront les chapitres suivants.

[^dockerfile-ref]: Docker, « Dockerfile reference », sections *Shell and exec form* et *CMD*. [docs.docker.com/reference/dockerfile](https://docs.docker.com/reference/dockerfile/)

[^oci-annotations]: Open Container Initiative, *Image Format Specification*, « Annotations », section *Pre-Defined Annotation Keys*. [github.com/opencontainers/image-spec/blob/main/annotations.md](https://github.com/opencontainers/image-spec/blob/main/annotations.md)
