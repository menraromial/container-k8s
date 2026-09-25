---
title: Défi II, une image de production pour Colis
sidebar_label: Défi II
description: "Réduire l'image de l'API Colis sous un seuil de taille et de failles, faire passer les tests pendant la construction, publier l'image pour deux architectures et la signer, selon un cahier des charges vérifiable."
partie: 2
plaque: Défi II
---

L'image de Colis construite au chapitre 4 a rendu de bons services, mais elle ne passerait pas la revue d'une équipe de sécurité : 164 Mo, 159 failles connues dont 46 de sévérité HIGH, et `pip` embarqué avec deux bibliothèques vulnérables. L'équipe d'exploitation vous demande une version 2.0 de l'image, prête pour la production, et publiée dans le registre de l'entreprise, qui est ici le registre local du chapitre 14.

Comme au défi I, il n'y a pas de pas-à-pas. Tout ce qu'il faut a été vu aux chapitres 10 à 14 : les couches (10), l'utilisateur non root (12), les étapes multiples et le cache (13), Trivy, le registre et cosign (14). Le défi consiste à les combiner sur une application réelle, avec des contraintes qui tirent parfois dans des directions opposées.

## Le code

Partez du dossier `colis` de la fin de la partie I. Si vous ne l'avez plus, [l'archive de Colis](pathname:///kits/colis-partie-1.tar.gz) le contient. Seul le dossier `app` change : son `Dockerfile` et son `.dockerignore`. Le reste de l'application (`compose.yaml`, `web`, `.env`) reste tel quel, à une ligne près.

Il vous faut aussi le registre `registre` (chapitre 14), le constructeur `cours` en mode réseau hôte, votre paire de clés cosign et Trivy.

## Le cahier des charges

1. L'image s'appelle `colis:2.0` et pèse moins de 100 Mo.
2. Elle utilise Python 3.14, la version avec laquelle l'application est développée et testée.
3. Trivy n'y trouve aucune faille de sévérité HIGH ou CRITICAL, qu'une correction existe ou non, et pas plus de cinq failles au total.
4. Le service ne tourne pas en `root`.
5. Les tests de Colis (`tests/`, avec `pytest`) s'exécutent pendant la construction, et **la construction de l'image finale échoue si un test échoue**.
6. L'image finale ne contient ni `pytest`, ni les tests, ni `pip`.
7. Modifier le code de Colis puis reconstruire ne réinstalle pas les dépendances.
8. Toute l'application démarre avec `docker compose up -d --build --wait`, avec la même image pour l'API, le worker et la purge, et fonctionne : un colis créé par l'API reçoit une date de livraison estimée du worker.
9. L'image est publiée dans le registre local sous le nom `localhost:5001/colis/api:2.0`, pour les architectures `linux/amd64` et `linux/arm64`.
10. L'image publiée est signée avec votre clé cosign.

## La grille de vérification

Lancez ces commandes depuis le dossier `colis`. Les commandes `trivy` et `cosign` supposent que vous êtes dans le dossier qui contient vos clés, ou que vous adaptez les chemins.

| Exigence | Commande | Résultat attendu |
|---|---|---|
| 1 | `docker image ls colis:2.0` | une taille inférieure à 100 Mo |
| 2 | `docker run --rm colis:2.0 python --version` | `Python 3.14.x` |
| 3 | `trivy image --quiet --severity HIGH,CRITICAL --exit-code 1 colis:2.0; echo $?` | `0` |
| 3 | `trivy image --quiet --format json -o t.json colis:2.0; jq '[.Results[]?.Vulnerabilities[]?] \| length' t.json` | 5 au plus |
| 4 | `docker run --rm colis:2.0 id` | un `uid` différent de 0 |
| 5 | faire échouer un test (changer un `201` en `299` dans `tests/test_api.py`), puis `docker build -t colis:casse app` | la construction échoue sur `pytest` |
| 6 | `docker run --rm colis:2.0 python -c 'import pytest'`, puis la même chose avec `-m pip --version` | deux erreurs : ni `pytest`, ni `pip` |
| 7 | modifier `colis/app.py`, puis `docker build --progress=plain -t colis:2.0 app` | l'installation des dépendances est `CACHED` |
| 8 | `docker compose up -d --build --wait`, créer un colis, attendre quelques secondes, le relire | le statut passe à `estimé`, avec une date |
| 8 | `docker compose run --rm purge` | le message de la purge, sans erreur |
| 9 | `docker buildx imagetools inspect localhost:5001/colis/api:2.0` | `linux/amd64` et `linux/arm64` |
| 10 | `cosign verify --key cosign.pub --insecure-ignore-tlog=true --allow-http-registry localhost:5001/colis/api:2.0` | code 0 |

Pour l'exigence 8, les commandes du chapitre 7 servent à créer et relire un colis :

```bash
curl -s -X POST localhost:8080/api/colis -H 'Content-Type: application/json' \
  -d '{"destinataire":"Ada Lovelace","depart":"Paris","arrivee":"Brest","poids_kg":2.5}'
sleep 4
curl -s localhost:8080/api/colis/1
```

## Indices

Ouvrez-les un par un, seulement si vous êtes bloqué.

<details>
<summary>Indice 1 : choisir l'image de base</summary>

Relisez le tableau des images de base du chapitre 13. Deux exigences s'y croisent : la taille (1) et la version de Python (2). L'image slim de Debian pèse déjà 120 Mo à elle seule, et l'image distroless pour Python n'a pas la bonne version. Vérifiez ensuite que les bibliothèques de Colis ont des paquets précompilés pour la base que vous choisissez : `pip install` vous le dira très vite, en compilant ou non.

</details>

<details>
<summary>Indice 2 : d'où viennent les dernières failles ?</summary>

Lancez Trivy sur l'image de base seule, sans rien y ajouter. Si des failles restent, regardez dans quel paquet Python elles sont, et relisez la section du chapitre 14 sur `pip`.

</details>

<details>
<summary>Indice 3 : installer sans laisser pip derrière soi</summary>

`python -m venv --without-pip /opt/venv` crée un environnement virtuel vide, sans son propre `pip`. Le `pip` de l'image de base sait installer dans un autre environnement grâce à son option `--python /opt/venv/bin/python`. L'environnement virtuel se copie ensuite d'un bloc dans l'étape finale, à condition que l'interpréteur soit au même endroit dans les deux étapes.

</details>

<details>
<summary>Indice 4 : pourquoi mes tests ne tournent-ils pas ?</summary>

Si vous avez mis les tests dans une étape à part, construisez l'image finale avec `--progress=plain` et cherchez `pytest` dans la sortie. BuildKit ne construit que les étapes dont la cible a besoin : une étape dont rien ne dépend est tout simplement ignorée. Il faut donc que l'étape finale dépende de celle des tests, en y prenant quelque chose. Et vérifiez ce que le `.dockerignore` du chapitre 4 laisse entrer dans le contexte.

</details>

<details>
<summary>Indice 5 : quatre mégaoctets en trop</summary>

Si votre image dépasse de peu ce que vous attendiez, regardez `docker history`. L'image officielle de Python supprime les fichiers `.pyc` de la bibliothèque standard pour gagner de la place ; tout programme Python exécuté dans une instruction `RUN` les réécrit, sauf si l'on demande à l'interpréteur de ne pas le faire.

</details>

## Corrigé

Ne l'ouvrez qu'après avoir essayé. Il a été vérifié avec la grille ci-dessus sur le poste du cours ; les fichiers sont dans le dépôt du cours, sous `kits/defi-2/corrige`.

<details>
<summary>Voir le corrigé commenté</summary>

```dockerfile title="app/Dockerfile"
# syntax=docker/dockerfile:1
# Image de Colis, version 2.0 : allégée et durcie (défi II).

# 1. Les dépendances, dans un environnement virtuel sans pip
FROM python:3.14-alpine AS dependances
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_ROOT_USER_ACTION=ignore
RUN python -m venv --without-pip /opt/venv
COPY requirements.txt .
RUN --mount=type=cache,target=/root/.cache/pip \
    pip --python /opt/venv/bin/python install -r requirements.txt

# 2. Les tests, dans une étape à part : la construction échoue s'ils échouent
FROM dependances AS tests
ENV PYTHONDONTWRITEBYTECODE=1
COPY requirements-dev.txt .
RUN --mount=type=cache,target=/root/.cache/pip \
    pip --python /opt/venv/bin/python install -r requirements-dev.txt
WORKDIR /app
COPY colis/ colis/
COPY tests/ tests/
RUN /opt/venv/bin/python -m pytest -q -p no:cacheprovider

# 3. L'image finale : l'interpréteur, l'environnement virtuel, le code testé
FROM python:3.14-alpine
LABEL org.opencontainers.image.title="colis" \
      org.opencontainers.image.source="https://github.com/menraromial/container-k8s" \
      org.opencontainers.image.version="2.0.0"
# PYTHONDONTWRITEBYTECODE d'abord : sinon, faire tourner pip écrit 4 Mo de .pyc
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH=/opt/venv/bin:$PATH
# pip ne sert plus à rien à l'exécution, et embarque des bibliothèques vulnérables
RUN python -m pip uninstall -y -q pip \
 && adduser -D -H -u 10001 colis
COPY --from=dependances /opt/venv /opt/venv
WORKDIR /app
# le code vient de l'étape de tests : sans tests réussis, pas d'image
COPY --from=tests /app/colis/ colis/
USER 10001:10001
EXPOSE 8000
CMD ["uvicorn", "colis.app:app", "--host", "0.0.0.0", "--port", "8000"]
```

```text title="app/.dockerignore"
# ce qui ne doit pas partir dans le contexte de construction
.venv/
__pycache__/
.pytest_cache/
Dockerfile
.dockerignore
```

Dans `compose.yaml`, une seule ligne change, dans le fragment `x-image-colis` : `image: colis:2.0`.

**La base (exigences 1 à 3).** `python:3.14-alpine` pèse 47,8 Mo et fournit Python 3.14. Toutes les dépendances de Colis publient des paquets précompilés pour musl (`pydantic-core`, `psycopg-binary` avec sa copie de `libpq`), si bien que rien n'est compilé. Trivy trouve trois failles dans l'image de base... toutes dans les bibliothèques que `pip` embarque. En désinstallant `pip` de l'étape finale, on tombe à zéro. Remarquez que `pip` occupe toujours de la place dans la couche de l'image de base, puisqu'une suppression ne fait qu'ajouter des whiteouts (chapitre 10) ; mais Trivy analyse le système de fichiers fusionné, où `pip` n'existe plus, et un attaquant ne pourrait plus s'en servir.

**L'environnement virtuel (exigence 6).** `venv --without-pip` évite qu'une copie de `pip` s'installe dans `/opt/venv`. L'environnement est copié d'un bloc ; il fonctionne dans l'étape finale parce que son `python` est un lien vers `/usr/local/bin/python3.14`, présent au même endroit dans les deux étapes, qui partent de la même image. `pytest` et `httpx2` ne sont installés que dans l'étape `tests`, sur une copie de l'environnement : ils n'atteignent jamais l'image finale.

**Les tests (exigence 5).** C'est le piège du défi. Une étape `tests` que rien n'utilise n'est jamais construite : `docker build` sans `--target` passerait sans exécuter un seul test. La ligne `COPY --from=tests /app/colis/ colis/` crée la dépendance : l'image finale prend son code dans l'étape de tests, qui doit donc réussir. C'est aussi une garantie de plus : le code livré est exactement celui qui a été testé. Il fallait retirer `tests/` et `requirements-dev.txt` du `.dockerignore` du chapitre 4, sans quoi ils n'arrivaient pas dans le contexte. `PYTHONDONTWRITEBYTECODE` dans l'étape de tests évite que `pytest` laisse des `__pycache__` dans le code copié. Avec un test cassé :

```sortie
1 failed, 9 passed in 0.54s
ERROR: failed to build: failed to solve: process "/bin/sh -c /opt/venv/bin/python -m pytest -q -p no:cacheprovider" did not complete successfully: exit code: 1
```

**Le cache (exigence 7).** `requirements.txt` est copié seul avant l'installation, comme au chapitre 4, et le montage de cache du chapitre 13 garde les téléchargements de `pip` d'une construction à l'autre, même quand `requirements.txt` change.

**Le résultat (exigences 1 à 8).** Sur le poste du cours :

```sortie
2.0	90MB
1.0	164MB
Python 3.14.7
HIGH ou CRITICAL : code 0
failles au total : 0
uid=10001(colis) gid=10001(colis) groups=10001(colis)
ModuleNotFoundError: No module named 'pytest'
/opt/venv/bin/python: No module named pip
```

`docker history colis:2.0` montre la répartition : 47,8 Mo pour Alpine et Python, 42,2 Mo pour l'environnement virtuel, dont plus de 16 Mo pour `psycopg-binary` et sa copie de `libpq`, et 15 Ko pour le code de Colis. Sans `PYTHONDONTWRITEBYTECODE` avant le `RUN` qui désinstalle `pip`, cette couche pèserait 4,3 Mo au lieu de 3 Ko : des `.pyc` de la bibliothèque standard, écrits par Python en faisant tourner `pip`.

**La publication (exigences 9 et 10).** Mêmes commandes qu'aux chapitres 13 et 14 :

```bash
cd app
docker buildx build --builder cours --platform linux/amd64,linux/arm64 \
  --sbom=true --provenance=mode=max -t localhost:5001/colis/api:2.0 --push .
D=$(docker buildx imagetools inspect localhost:5001/colis/api:2.0 --format '{{json .Manifest}}' | jq -r .digest)
cosign sign --yes --key cosign.key --signing-config sans-journal.json --allow-http-registry localhost:5001/colis/api@$D
cosign verify --key cosign.pub --insecure-ignore-tlog=true --allow-http-registry localhost:5001/colis/api:2.0 >/dev/null; echo $?
```

La construction prend environ 100 secondes sur le poste du cours, presque toutes pour la variante arm64 : Python n'a pas de compilation croisée, et `pip install` y tourne sous l'émulateur QEMU de BuildKit. Ce n'est pas grave ici, puisque `pip` ne fait que décompresser des paquets précompilés pour arm64 ; avec des dépendances à compiler, l'émulation deviendrait vite pénible, et l'on préférerait une machine arm64 pour construire cette variante. N'essayez pas de lancer l'image arm64 sur votre poste : sans émulateur installé dans le noyau, `docker run --platform linux/arm64` échoue avec `exec format error`, exactement comme au chapitre 1.

</details>

## Pour aller plus loin

- Rendez la construction reproductible (chapitre 13) : fixez les images de base par leur empreinte, et vérifiez que deux constructions avec le même `SOURCE_DATE_EPOCH` donnent la même empreinte.
- Faites de même pour l'image `web` de Colis, fondée sur nginx : quelle est sa taille, et que trouve Trivy ?
- Ajoutez à l'image publiée une attestation signée de son SBOM (exercice 4 du chapitre 14).

## Et maintenant

Vous savez désormais ce qu'est un conteneur, jusqu'aux appels système, et comment fabriquer une image digne de la production. La partie III passe à l'orchestration : déployer Colis sur minikube, d'abord en y chargeant l'image, puis en la tirant du registre local où vous venez de la publier.

Pour faire le ménage du défi, en gardant le registre et ce qu'il contient :

```bash
docker compose down -v
docker image rm colis:2.0
```
