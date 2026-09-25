---
title: Des images de production
sidebar_label: 13. Images de production
description: "Construire des images petites, sûres, rapides à reconstruire et reproductibles : étapes multiples, scratch et distroless, cache de BuildKit, horodatages maîtrisés, plusieurs architectures avec buildx."
partie: 2
chapitre: '13'
---

import multiEtapes from '@site/src/figures/multi-etapes.svg';
import emulationCroisee from '@site/src/figures/emulation-croisee.svg';

L'image de Colis construite au chapitre 4 fonctionne, et c'est déjà beaucoup. Mais son code pèse 15 Ko dans une image de plus de 160 Mo. Chaque mégaoctet superflu se paie plusieurs fois : en temps de téléchargement sur chaque nœud qui la lance, en place dans le registre, et surtout en programmes qui n'ont rien à faire là. Un interpréteur de commandes, un gestionnaire de paquets, un compilateur oublié dans l'image : autant d'outils offerts à un attaquant qui aurait pris pied dans le conteneur, et autant de logiciels dans lesquels le scanner du chapitre 14 trouvera des failles.

Une image de production se reconnaît à quelques qualités : elle ne contient que ce qui sert à l'exécution, elle tourne sans root (chapitre 12), elle se reconstruit vite après une modification, elle donne le même résultat quand on la reconstruit à partir des mêmes sources, et elle existe pour les processeurs sur lesquels elle sera lancée. Ce chapitre les obtient une par une, sur un exemple choisi pour que les gains soient spectaculaires : un petit service écrit en Go. Les principes valent pour tous les langages, et le défi II vous les fera appliquer à l'API Python de Colis.

## Le service tampon

`tampon` est un service HTTP d'une soixantaine de lignes, qui répond par un « tampon de la poste » : son nom, sa version, la machine et le processeur sur lesquels il tourne, et l'heure à Paris. Une seconde adresse, `/distant`, vérifie qu'il sait joindre un site en HTTPS. Téléchargez [l'archive de tampon](pathname:///kits/tampon.tar.gz) et décompressez-la. Elle contient le code (`main.go`, `go.mod`), un `.dockerignore`, et les Dockerfile successifs de ce chapitre.

Le premier Dockerfile est celui qu'on écrirait spontanément, en suivant le chapitre 4 :

```dockerfile title="Dockerfile.naif"
FROM golang:1.27
WORKDIR /src
COPY . .
RUN go build -o /usr/local/bin/tampon .
EXPOSE 8080
CMD ["tampon"]
```

```bash
cd tampon
docker build -q -f Dockerfile.naif -t tampon:naif .
docker image ls tampon:naif --format '{{.Size}}'
docker history tampon:naif --format '{{.Size}}\t{{.CreatedBy}}' | head -4
```

```sortie
989MB
0B	CMD ["tampon"]
0B	EXPOSE [8080/tcp]
104MB	RUN /bin/sh -c go build -o /usr/local/bin/ta…
1.78kB	COPY . . # buildkit
```

989 Mo pour un programme qui tient sur une page. L'image `golang:1.27` pèse à elle seule 885 Mo : une Debian complète, le compilateur Go et sa bibliothèque standard, `git`, `gcc` et tout ce qu'il faut pour compiler. La couche du `go build` ajoute 104 Mo, dont le binaire et surtout le cache de compilation que Go laisse dans `/root/.cache`. Rien de tout cela ne sert à l'exécution, à part le binaire.

## Construire en plusieurs étapes

La solution s'appelle la **construction en plusieurs étapes** (*multi-stage build*). Un Dockerfile peut contenir plusieurs instructions `FROM`, chacune ouvrant une nouvelle étape qui part d'une image différente. Une étape peut copier des fichiers produits par une étape précédente, avec `COPY --from=<nom>`. Seule la dernière étape devient l'image ; les autres ne servent que pendant la construction, et leurs couches ne sont jamais envoyées nulle part[^multistage].

```dockerfile title="Dockerfile.alpine"
FROM golang:1.27 AS construction
WORKDIR /src
COPY . .
RUN go build -o /tampon .

FROM alpine:3.24
COPY --from=construction /tampon /usr/local/bin/tampon
EXPOSE 8080
CMD ["tampon"]
```

La première étape, nommée `construction` par `AS`, compile. La seconde part d'Alpine, 8,4 Mo, et n'y ajoute que le binaire. L'image finale pèse 19 Mo. Lançons-la :

```bash
docker build -q -f Dockerfile.alpine -t tampon:alpine .
docker run --rm tampon:alpine
```

```sortie
exec /usr/local/bin/tampon: no such file or directory
```

:::panne[exec /usr/local/bin/tampon: no such file or directory]

Le fichier existe pourtant, `docker run --rm --entrypoint ls tampon:alpine -l /usr/local/bin` le montre. Le message ne parle pas du programme, mais d'un fichier dont il a besoin pour démarrer :

```bash
docker run --rm --entrypoint sh tampon:alpine -c 'ldd /usr/local/bin/tampon'
```

```sortie
	/lib64/ld-linux-x86-64.so.2 (0x7f009d5b2000)
	libc.so.6 => /lib64/ld-linux-x86-64.so.2 (0x7f009d5b2000)
```

Le binaire a été compilé dans l'image `golang:1.27`, une Debian, et lié dynamiquement à la bibliothèque C de Debian, la glibc : pour démarrer, il demande au noyau de charger `/lib64/ld-linux-x86-64.so.2`. Alpine n'utilise pas la glibc mais musl, et ce fichier n'y existe pas. Go ne se lie à la bibliothèque C que pour quelques fonctions (la résolution de noms, les utilisateurs du système), et seulement si `cgo`, son mécanisme d'appel au C, est actif, ce qui est le cas par défaut quand un compilateur C est présent. C'est l'erreur classique des images multi-étapes : construire dans une distribution et exécuter dans une autre.

:::

Le remède, pour Go, est de désactiver `cgo` avec `CGO_ENABLED=0` : le compilateur utilise alors ses propres implémentations en Go pur et produit un binaire **statique**, qui ne dépend d'aucun autre fichier. Un tel binaire n'a plus besoin d'Alpine, ni de rien d'autre.

## Partir de rien : scratch

`scratch` n'est pas une vraie image : c'est le nom réservé qui signifie « aucune couche »[^scratch]. Une image construite `FROM scratch` ne contient que ce qu'on y copie.

```dockerfile title="Dockerfile.scratch"
FROM golang:1.27 AS construction
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -o /tampon .

FROM scratch
COPY --from=construction /tampon /tampon
EXPOSE 8080
ENTRYPOINT ["/tampon"]
```

L'image pèse 10,5 Mo, le poids du binaire. Elle démarre, et répond... mal :

```bash
docker build -q -f Dockerfile.scratch -t tampon:scratch .
docker run -d --rm --name t13 -p 8081:8080 tampon:scratch
curl -s localhost:8081/
curl -s localhost:8081/distant
docker rm -f t13
```

```sortie
fuseau horaire : unknown time zone Europe/Paris
HTTPS : Get "https://example.org/": tls: failed to verify certificate: x509: certificate signed by unknown authority
```

Deux fichiers qu'on ne remarque jamais manquent à l'appel. La base des fuseaux horaires, `/usr/share/zoneinfo`, dit que Paris est à UTC+2 en été ; sans elle, Go ne sait pas convertir l'heure. Le magasin des certificats racine, `/etc/ssl/certs/ca-certificates.crt`, contient les autorités de certification auxquelles on fait confiance ; sans lui, aucune connexion HTTPS ne peut être vérifiée. Toute distribution fournit ces fichiers. Dans `scratch`, il faut les apporter, et l'étape de construction les a justement :

```dockerfile title="Dockerfile.scratch2"
FROM golang:1.27 AS construction
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -o /tampon .

FROM scratch
COPY --from=construction /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=construction /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=construction /tampon /tampon
USER 65534:65534
EXPOSE 8080
ENTRYPOINT ["/tampon"]
```

```sortie
{"service":"tampon","version":"dev","hote":"a5463090f2fd","arch":"amd64","go":"go1.27.1","heure":"2026-09-25 17:35:40 CEST"}
HTTPS : 200 OK
```

L'image fait 11,3 Mo et tourne sous l'UID 65534, `nobody` par convention, puisqu'il n'existe dans l'image ni `/etc/passwd` ni aucun utilisateur. Elle ne contient que quatre choses : un binaire, des fuseaux, des certificats et rien d'autre. Pas de shell : `docker run --rm --entrypoint sh tampon:scratch` échoue avec `exec: "sh": executable file not found in $PATH`. Un attaquant qui prendrait le contrôle de `tampon` n'y trouverait aucun outil.

On sent pourtant la fragilité de la méthode : il faut connaître les fichiers dont le programme a besoin, et la liste s'allonge vite (le fichier `/etc/passwd` que certaines bibliothèques lisent, `/etc/nsswitch.conf`, un dossier `/tmp`). Quelqu'un a déjà fait ce travail.

## Les images distroless

Les images **distroless**, publiées par Google, sont des images minimales construites à partir de paquets Debian, mais sans gestionnaire de paquets ni shell : seulement ce qu'il faut à un programme pour s'exécuter[^distroless]. Il en existe plusieurs, selon ce que le programme attend :

```bash
docker image ls --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' | grep -E 'distroless|python:3.14|debian:13-slim|alpine:3.24|golang:1.27' | sort
```

```sortie
alpine:3.24	8.42MB
debian:13-slim	78.8MB
gcr.io/distroless/base-debian13:latest	24.4MB
gcr.io/distroless/python3-debian13:latest	59.8MB
gcr.io/distroless/static-debian13:latest	2.37MB
gcr.io/distroless/static-debian13:nonroot	2.37MB
golang:1.27	885MB
golang:1.27-alpine	253MB
python:3.14	1.12GB
python:3.14-alpine	47.8MB
python:3.14-slim	120MB
```

(Téléchargez-les d'abord avec `docker pull` si vous voulez la même liste.) `static` convient aux binaires statiques comme le nôtre : 2,4 Mo de certificats, de fuseaux horaires, de fichiers `/etc/passwd` et `/etc/group`, et rien d'exécutable. `base` y ajoute la glibc et OpenSSL, pour les programmes liés dynamiquement. Il existe aussi des variantes pour Python, Java et Node.js. Chaque image existe en version `:nonroot`, dont l'utilisateur par défaut est `nonroot`, UID 65532, et en version `:debug`, qui ajoute un shell BusyBox pour le dépannage.

Voici le Dockerfile de production de `tampon`. Il rassemble tout ce chapitre ; les lignes que nous n'avons pas encore vues sont expliquées dans les sections suivantes.

```dockerfile title="Dockerfile"
# syntax=docker/dockerfile:1
# Image de production de tampon (chapitre 13).

# 1. Construction, toujours sur l'architecture de la machine qui construit
FROM --platform=$BUILDPLATFORM golang:1.27 AS construction
ARG TARGETOS TARGETARCH
ARG VERSION=dev
WORKDIR /src
COPY go.mod ./
COPY *.go ./
# le cache de compilation de Go survit d'une construction à l'autre
RUN --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /tampon .

# 2. Exécution : un binaire statique, des certificats, les fuseaux, un utilisateur
FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=construction /tampon /tampon
EXPOSE 8080
ENTRYPOINT ["/tampon"]
```

Les options de `go build` ont chacune leur rôle. `-ldflags="-s -w"` retire du binaire la table des symboles et les informations de débogage, inutiles en production : le binaire passe de 10,5 à 7,1 Mo (exercice 2). `-X main.version=${VERSION}` écrit la version dans la variable `version` du programme au moment de l'édition de liens, sans toucher au code. `-trimpath` retire du binaire les chemins de la machine qui l'a compilé (`/src/main.go` au lieu d'un chemin absolu), ce qui compte pour la reproductibilité.

```bash
docker build -q --build-arg VERSION=1.0.0 -t tampon:1.0.0 .
docker run -d --rm --name t13 -p 8081:8080 tampon:1.0.0
curl -s localhost:8081/
curl -s localhost:8081/distant
docker image inspect tampon:1.0.0 --format 'User={{.Config.User}}'
docker rm -f t13
```

```sortie
{"service":"tampon","version":"1.0.0","hote":"3a27ce6e1369","arch":"amd64","go":"go1.27.1","heure":"2026-09-25 17:35:43 CEST"}
HTTPS : 200 OK
User=65532
```

La version est bien 1.0.0, l'heure est juste, HTTPS fonctionne, et l'image tourne d'emblée sans root. `docker history` montre ce qu'elle contient :

```bash
docker history tampon:1.0.0 --format '{{.Size}}\t{{.CreatedBy}}'
```

```sortie
0B	ENTRYPOINT ["/tampon"]
0B	EXPOSE [8080/tcp]
7.09MB	COPY /tampon /tampon # buildkit
261kB	bazel build //common:cacerts_debian13_amd64_…
344B	bazel build //common:os_release_debian13
497B	bazel build //static:nsswitch
0B	bazel build //common:tmp
64B	bazel build //common:group
0B	bazel build //common:home
149B	bazel build //common:passwd
0B	bazel build //common:rootfs
88.8kB	bazel build @trixie//media-types/amd64:data_…
822kB	bazel build @trixie//tzdata-legacy/amd64:dat…
754kB	bazel build @trixie//tzdata/amd64:data_statu…
23.2kB	bazel build @trixie//netbase/amd64:data_stat…
422kB	bazel build @trixie//base-files/amd64:data_s…
```

Les couches de distroless sont produites par Bazel, l'outil de construction de Google, et chacune porte un nom explicite : certificats, `/etc/passwd`, `/tmp`, fuseaux horaires issus des paquets Debian 13 (*trixie*). Au-dessus, notre binaire de 7,09 Mo. Le récapitulatif est parlant :

| Image | Taille | Remarque |
|---|---|---|
| `tampon:naif` | 989 Mo | compilateur et Debian compris |
| `tampon:alpine` | 19 Mo | ne démarre pas (glibc absente) |
| `tampon:scratch` | 10,5 Mo | ni fuseaux horaires, ni certificats |
| `tampon:scratch2` | 11,3 Mo | fonctionne, liste de fichiers à entretenir soi-même |
| `tampon:1.0.0` | 9,47 Mo | distroless, non root, binaire allégé |

<Figure svg={multiEtapes} num="13.1" alt="Deux cadres. À gauche, l'étape construction : l'image golang de 885 Mo, les sources main.go et go.mod, et le binaire statique /tampon de 7,1 Mo ; cette étape est jetée à la fin de la construction. Une flèche COPY --from=construction emporte le binaire dans le cadre de droite, l'image finale : distroless/static de 2,4 Mo, avec certificats, fuseaux horaires, /etc/passwd et l'utilisateur 65532, plus le binaire ; au total 9,47 Mo. En bas, le rappel qu'en une seule étape tout reste dans l'image, 989 Mo.">
Une construction en deux étapes. Tout ce qui a servi à compiler reste dans l'étape de construction ; seul le binaire passe dans l'image finale. Tailles relevées sur le poste du cours.
</Figure>

## Déboguer une image sans shell

Le revers d'une image sans shell apparaît le jour où l'on veut regarder dedans :

```bash
docker run -d --rm --name t13 tampon:1.0.0
docker exec t13 sh
```

```sortie
OCI runtime exec failed: exec failed: unable to start container process: exec: "sh": executable file not found in $PATH
```

Le chapitre 8 donne la solution : un conteneur n'est qu'un ensemble de namespaces, et un autre conteneur peut rejoindre certains d'entre eux. On lance donc un conteneur d'outils, BusyBox par exemple, dans le namespace PID de `t13` :

```bash
docker run --rm --pid container:t13 busybox:1.37 sh -c 'ps; ls /proc/1/root/'
```

```sortie
PID   USER     TIME  COMMAND
    1 65532     0:00 /tampon
   16 root      0:00 sh -c ps; ls /proc/1/root/
   21 root      0:00 ps
ls: /proc/1/root/: Permission denied
```

On voit le processus `tampon` (UID 65532), mais pas ses fichiers : parcourir `/proc/<pid>/root` d'un processus d'un autre utilisateur est réservé à qui a le droit de l'inspecter avec `ptrace`, c'est-à-dire, pour root, à qui possède `CAP_SYS_PTRACE`. Cette capability ne fait pas partie de la liste par défaut de Docker (chapitre 12). Accordons-la à ce seul conteneur de dépannage :

```bash
docker run --rm --pid container:t13 --cap-add SYS_PTRACE busybox:1.37 sh -c 'ls /proc/1/root/; cat /proc/1/root/etc/passwd'
docker rm -f t13
```

```sortie
bin
boot
dev
etc
home
lib
lib64
proc
root
run
sbin
sys
tampon
tmp
usr
var
root:x:0:0:root:/root:/sbin/nologin
nobody:x:65534:65534:nobody:/nonexistent:/sbin/nologin
nonroot:x:65532:65532:nonroot:/home/nonroot:/sbin/nologin
```

Le système de fichiers de `tampon` est entièrement lisible, avec ses outils à nous. On ajoute `--network container:t13` pour voir aussi le réseau du conteneur, comme au chapitre 8 avec `nsenter`. Kubernetes a formalisé la même idée sous le nom de **conteneurs éphémères**, avec la commande `kubectl debug`, que la partie IV utilisera. L'image de production reste minimale ; les outils de dépannage ne viennent qu'au moment où l'on en a besoin.

## Et pour Python ?

Un programme Python ne se compile pas en un binaire statique : l'image finale doit contenir un interpréteur, la bibliothèque standard et les dépendances. Les leviers restent les mêmes, mais les gains sont plus modestes, et le choix de l'image de base pèse davantage. Le tableau des tailles, plus haut, résume les options pour Python 3.14 :

- `python:3.14`, 1,12 Go, contient une Debian complète et les outils de compilation. Elle est utile pour **construire**, quand une dépendance doit compiler du C, mais n'a pas sa place à l'exécution ;
- `python:3.14-slim`, 120 Mo, celle du chapitre 4, garde un shell, `apt` et `pip`, mais pas de compilateur ;
- `python:3.14-alpine`, 47,8 Mo, repose sur musl. La plupart des bibliothèques Python courantes publient des paquets précompilés pour musl (le format *musllinux*), mais pas toutes : il faut alors les compiler, ce qui demande un compilateur à la construction et rallonge celle-ci ;
- `gcr.io/distroless/python3-debian13`, 59,8 Mo, sans shell ni `pip`. Mais `docker run --rm --entrypoint /usr/bin/python3 gcr.io/distroless/python3-debian13 --version` affiche `Python 3.13.5` : c'est le Python de Debian 13, pas le 3.14 de l'image officielle. Une application testée avec une version de Python doit tourner avec la même.

Le schéma en plusieurs étapes s'applique aussi : une étape installe les dépendances (dans un environnement virtuel, par exemple, qu'on copie ensuite d'un bloc), avec les outils qu'il faut ; l'étape finale ne reçoit que le résultat. Choisir la base, adapter le Dockerfile et mesurer le gain sur l'API Colis : c'est précisément le défi II.

## Reconstruire vite : le cache de BuildKit

Le chapitre 4 a montré le cache des couches : une instruction dont les entrées n'ont pas changé n'est pas réexécutée, d'où l'ordre « dépendances d'abord, code ensuite ». Dans notre Dockerfile, `go.mod` est copié avant le code pour la même raison. Mais dès que le code change, l'instruction `RUN go build` est réexécutée entièrement, et le compilateur repart de zéro : il recompile même la bibliothèque standard de Go (`net/http`, `crypto/tls`...), dont les résultats vivaient dans le cache de compilation de l'étape précédente, perdu avec elle.

BuildKit, le moteur de construction de Docker, propose des **montages de cache** : `RUN --mount=type=cache,target=/root/.cache/go-build` monte à cet endroit un dossier qui appartient au constructeur, pas à l'image, et qui survit d'une construction à l'autre[^buildkit-cache]. Le compilateur y retrouve son travail précédent. Mesurons, sur la machine du cours, le temps de construction après une modification du code, avec et sans cette option :

```sortie
sans cache de compilation, 1re construction : 9161 ms
sans cache de compilation, après une modification : 9435 ms
avec cache de compilation, 1re construction : 8936 ms
avec cache de compilation, après une modification : 2317 ms
```

La première construction coûte le même prix dans les deux cas. Ensuite, sans cache, chaque modification coûte 9 secondes ; avec, 2,3 secondes, dont l'essentiel est le travail fixe de Docker (lire le contexte, exporter l'image). Sur un vrai projet, avec des centaines de dépendances, l'écart se compte en minutes. Le script `outils/rejeu-ch13.sh` du dépôt du cours reproduit la mesure. Le même mécanisme existe pour tous les gestionnaires de paquets : `/root/.cache/pip` pour pip, `/root/.npm` pour npm, `/var/cache/apt` pour apt. Le cache n'entre jamais dans l'image, ce qui évite l'erreur du chapitre 4 de l'y laisser par mégarde.

Deux autres montages de BuildKit rendent service. `--mount=type=secret` donne à une instruction un secret (un jeton d'accès à un dépôt privé, par exemple) sous la forme d'un fichier qui n'existe que pendant cette instruction et ne laisse aucune trace dans l'image : c'est la réponse au secret ajouté puis supprimé de l'exercice 2 du chapitre 10, et l'objet de l'exercice 3. `--mount=type=bind` monte des fichiers du contexte sans les copier dans une couche.

Enfin, BuildKit sait relire un Dockerfile sans rien construire. `docker build --check .` applique une série de règles et signale les erreurs courantes : sur un Dockerfile qui écrirait `FROM golang:1.27 as construction` et `CMD /tampon`, il signale `FromAsCasing` (majuscules et minuscules mélangées) et `JSONArgsRecommended` (la forme shell de `CMD`, dont le chapitre 4 a montré qu'elle empêche le programme de recevoir `SIGTERM`).

## Des constructions reproductibles

Construisons deux fois la même image, à partir des mêmes sources, et comparons les empreintes :

```sortie
construction 1 : sha256:073be2bf82b40fd9325c69ef7ce204dff09a76908833146117811b59fbbd7b79
construction 2 : sha256:caea05b9c371218a71722f23dfc76e23c950312e764bb9cc882f219338d3f354
```

Deux images différentes. Est-ce le binaire qui diffère ? Examinons les deux archives OCI produites :

```sortie
r1 : created 2026-09-25T15:35:59.294697715Z, binaire aec3087c7e20, date du fichier 2026-09-25 17:35, couche 6f49ea20bb62
r2 : created 2026-09-25T15:36:09.167493385Z, binaire aec3087c7e20, date du fichier 2026-09-25 17:36, couche fd4f9e044687
```

Le binaire est identique octet pour octet (`-trimpath` y est pour quelque chose). Ce qui change, ce sont des **dates** : la date de création inscrite dans la configuration de l'image (`created`) et la date de modification du fichier `/tampon` dans l'archive tar de la couche. Une date différente fait une archive différente, donc une empreinte de couche différente (chapitre 3), donc une image différente.

Pourquoi s'en soucier ? Parce qu'une construction **reproductible** permet de vérifier qu'une image publiée correspond bien aux sources qu'elle prétend contenir : n'importe qui peut la reconstruire et comparer l'empreinte. C'est l'un des fondements de la sécurité de la chaîne d'approvisionnement, sujet du chapitre 14. Le projet *Reproducible Builds* a défini pour cela une convention, la variable d'environnement `SOURCE_DATE_EPOCH`, qui donne la date à utiliser à la place de « maintenant »[^sde]. BuildKit la respecte pour les dates de l'image et, avec l'option `rewrite-timestamp=true` de la sortie, ramène aussi à cette date celles des fichiers des couches[^buildkit-repro] :

```bash
export SOURCE_DATE_EPOCH=1788220800     # 1er septembre 2026 à minuit (UTC)
docker buildx build --builder cours --platform linux/amd64 --no-cache --provenance=false \
  --build-arg VERSION=1.0.0 --output type=oci,dest=r3.tar,rewrite-timestamp=true .
```

(Le constructeur `cours` est créé dans la section suivante.) Deux constructions ainsi réglées, lancées à plusieurs minutes d'intervalle, donnent la même empreinte, et c'était déjà celle d'une construction faite quelques minutes plus tôt, dans un autre dossier, pour préparer ce chapitre :

```sortie
construction 3 : sha256:ccb0ec011241dce79c7d4609c9410c5eb4c166e32711b1eaed378a1bdf810a19
construction 4 : sha256:ccb0ec011241dce79c7d4609c9410c5eb4c166e32711b1eaed378a1bdf810a19
```

`--provenance=false` retire l'attestation de provenance que BuildKit ajoute par défaut (nous la verrons à la section suivante), parce qu'elle décrit la construction elle-même, avec ses propres dates. Il reste un point pour que la reproductibilité tienne dans la durée : `FROM golang:1.27` et `FROM gcr.io/distroless/static-debian13:nonroot` désignent des étiquettes qui bougent, à chaque correctif publié. Pour figer la base, on la désigne par son empreinte, que `docker image inspect --format '{{index .RepoDigests 0}}'` donne :

```dockerfile
FROM gcr.io/distroless/static-debian13:nonroot@sha256:e2e927ec666bae08560abb3c55d0659eceabb657f56b6782ab500a9fc7f555e3
```

Figer n'est pas oublier : une base figée ne reçoit plus les correctifs de sécurité. On confie en général à un outil automatique (Renovate, Dependabot) le soin de proposer la nouvelle empreinte quand l'image de base change, pour la faire passer par les mêmes vérifications que le code.

## Plusieurs architectures avec buildx

Votre poste a sans doute un processeur x86-64 (`amd64`). Mais un Mac récent, un Raspberry Pi ou beaucoup de serveurs du nuage (AWS Graviton, par exemple) ont un processeur ARM (`arm64`), qui ne sait pas exécuter un binaire `amd64` : c'est l'`exec format error` du chapitre 1. Une image publiée pour plusieurs processeurs est en réalité un **index** (chapitre 3), qui pointe vers une image par architecture ; `docker pull` choisit celle qui convient.

Construire plusieurs architectures d'un coup demande un constructeur qui sache produire un index. Le constructeur par défaut de Docker, sur un poste qui utilise le stockage `overlay2` (chapitre 10), ne le sait pas : `docker buildx build --platform linux/amd64,linux/arm64 .` s'arrête sur `Multi-platform build is not supported for the docker driver. Switch to a different driver, or turn on the containerd image store, and try again.` On crée donc un constructeur à part, qui fait tourner BuildKit dans un conteneur :

```bash
docker buildx create --name cours --driver docker-container --bootstrap
docker buildx ls | grep -A1 '^cours'
```

```sortie
cours         docker-container
 \_ cours0     \_ unix:///var/run/docker.sock   running   v0.32.2    linux/amd64 (+3), linux/386
```

Le constructeur `cours` tourne dans le conteneur `buildx_buildkit_cours0`, avec BuildKit 0.32.2. Construisons `tampon` pour deux architectures, en écrivant le résultat dans une archive OCI puisque nous n'avons pas encore de registre (chapitre 14) :

```bash
docker buildx build --builder cours --platform linux/amd64,linux/arm64 \
  --build-arg VERSION=1.0.0 --output type=oci,dest=tampon-multi.tar .
mkdir oci && tar -xf tampon-multi.tar -C oci
IDX=$(jq -r '.manifests[0].digest' oci/index.json | cut -d: -f2)
jq -c '.manifests[] | {platform, type: .annotations["vnd.docker.reference.type"]}' oci/blobs/sha256/$IDX
```

```sortie
{"platform":{"architecture":"amd64","os":"linux"},"type":null}
{"platform":{"architecture":"arm64","os":"linux"},"type":null}
{"platform":{"architecture":"unknown","os":"unknown"},"type":"attestation-manifest"}
{"platform":{"architecture":"unknown","os":"unknown"},"type":"attestation-manifest"}
```

L'index contient une image par architecture et, pour chacune, une **attestation de provenance** : un document au format SLSA qui décrit comment l'image a été construite (le Dockerfile, les images de base et leurs empreintes, les arguments). Le chapitre 14 apprendra à la lire et à la vérifier. Extrayons le binaire de chacune des deux images :

```sortie
amd64 : /dev/stdin: ELF 64-bit LSB executable, x86-64
arm64 : /dev/stdin: ELF 64-bit LSB executable, ARM aarch64
```

Deux binaires pour deux processeurs, construits sur une seule machine x86-64. Tout le mérite revient aux trois lignes du Dockerfile que nous avions laissées de côté :

- `FROM --platform=$BUILDPLATFORM golang:1.27` fait tourner l'étape de construction sur l'architecture de la machine qui construit (`BUILDPLATFORM`, ici `linux/amd64`), quelle que soit l'architecture visée ;
- `ARG TARGETOS TARGETARCH` récupère l'architecture visée, que buildx fournit pour chaque plateforme demandée ;
- `GOOS=$TARGETOS GOARCH=$TARGETARCH go build` demande au compilateur Go de produire un binaire pour cette architecture : c'est la **compilation croisée**, que Go sait faire nativement.

L'étape finale, elle, part de `distroless/static` sans `--platform` : buildx prend donc la variante arm64 de l'image de base pour l'image arm64. Les journaux de construction le montrent, avec des lignes comme `[linux/amd64->arm64 construction 5/5] RUN ... go build` : l'étape tourne en amd64 et produit de l'arm64.

Que se passe-t-il sans `--platform=$BUILDPLATFORM` ? L'étape de construction utilise alors l'image `golang` pour arm64, dont les programmes ne peuvent pas s'exécuter sur un processeur x86-64. BuildKit s'en sort quand même : son image embarque des émulateurs **QEMU** (`buildkit-qemu-aarch64` et quelques autres), qui traduisent les instructions ARM à la volée. La construction réussit, mais au prix annoncé au chapitre 1 :

```sortie
Dockerfile.emule : #13 DONE 109.2s
Dockerfile.croise : #13 DONE 7.6s
```

La compilation émulée prend 109 secondes, contre 7,6 en compilation croisée, soit plus de quatorze fois plus. L'émulation reste la seule solution quand l'étape de construction exécute des programmes qu'on ne sait pas compiler de façon croisée (un `apt-get install` pour arm64, par exemple) ; on la réserve à ces cas.

<Figure svg={emulationCroisee} num="13.2" alt="Deux lignes. En haut, l'émulation : l'image golang pour arm64 exécutée par QEMU, puis go build dont chaque instruction est traduite, 109 secondes pour obtenir le binaire arm64. En bas, la compilation croisée avec FROM --platform=$BUILDPLATFORM : l'image golang pour amd64 en natif, puis GOARCH=arm64 go build, 7,6 secondes pour le même binaire arm64. Dans les deux cas, le binaire est ensuite copié dans distroless/static pour arm64.">
Deux façons de produire un binaire arm64 sur une machine x86-64, mesurées sur le poste du cours pour l'étape <code>go build</code>.
</Figure>

Une image multi-architecture ne peut pas être chargée telle quelle dans le magasin d'images de votre Docker, qui ne garde qu'une architecture par étiquette avec le pilote `overlay2`. On la pousse dans un registre, qui stocke l'index complet, ou on charge une seule plateforme avec `--platform linux/amd64 --load`. Le chapitre 14 installera un registre local.

## Exercices

:::exercice[Exercice 1 : réparer l'image Alpine]

L'image `tampon:alpine` ne démarrait pas. Au lieu d'ajouter `CGO_ENABLED=0`, remplacez l'image de construction par `golang:1.27-alpine`, sans rien changer d'autre. L'image démarre-t-elle ? Répond-elle correctement à `/` et à `/distant` ? Que montre `ldd` sur le binaire ?

:::

<details>
<summary>Corrigé</summary>

L'image démarre, et `/distant` répond `HTTPS : 200 OK`, mais `/` répond `fuseau horaire : unknown time zone Europe/Paris`. `ldd` affiche :

```sortie
/lib/ld-musl-x86_64.so.1: /usr/local/bin/tampon: Not a valid dynamic program
```

« Pas un programme dynamique » : le binaire est statique. L'image `golang:1.27-alpine` ne contient pas de compilateur C, si bien que Go désactive `cgo` de lui-même. Les certificats sont présents, car Alpine installe par défaut le paquet `ca-certificates-bundle`, mais pas les fuseaux horaires. Deux corrections possibles : `RUN apk add --no-cache tzdata` dans l'étape finale, ou ajouter `import _ "time/tzdata"` au programme, qui embarque la base des fuseaux (environ 450 Ko) dans le binaire lui-même. La leçon générale : il faut construire et exécuter sur la même bibliothèque C, ou ne dépendre d'aucune.

</details>

:::exercice[Exercice 2 : le poids des symboles]

Compilez `tampon` deux fois dans un conteneur `golang:1.27`, avec et sans `-ldflags="-s -w"`, et comparez les tailles. Que perd-on en retirant les symboles ?

:::

<details>
<summary>Corrigé</summary>

```bash
docker run --rm -v "$PWD:/src" -w /src -e CGO_ENABLED=0 -e GOCACHE=/tmp/c golang:1.27 \
  sh -c 'go build -o /tmp/a . && go build -ldflags="-s -w" -o /tmp/b . && ls -l /tmp/a /tmp/b'
```

Le binaire complet fait 10 455 637 octets, le binaire allégé 7 106 720, un tiers de moins. `-s` retire la table des symboles, `-w` les informations de débogage DWARF. On perd la possibilité de déboguer le binaire avec un débogueur comme `delve` ou `gdb` et d'analyser finement un profil. Les traces d'une panique Go (`panic`), elles, restent lisibles, car Go garde dans le binaire la table dont il a besoin pour les produire. Pour une image de production, le compromis est presque toujours bon ; on garde le binaire complet dans le système de construction pour le jour où il faudra déboguer.

</details>

:::exercice[Exercice 3 : un secret de construction]

Écrivez un Dockerfile qui part d'`alpine:3.24` et dont une instruction `RUN` a besoin d'un jeton secret, fourni dans un fichier `jeton.txt` : pour l'exercice, elle se contente d'écrire dans `/info.txt` la longueur du jeton. Utilisez `--mount=type=secret` et l'option `--secret` de `docker build`. Vérifiez que le jeton ne se trouve nulle part dans l'image.

:::

<details>
<summary>Corrigé</summary>

```dockerfile title="Dockerfile.secret"
# syntax=docker/dockerfile:1
FROM alpine:3.24
RUN --mount=type=secret,id=jeton \
    echo "le jeton fait $(wc -c < /run/secrets/jeton) octets" > /info.txt
```

```bash
printf 'jeton-tres-secret-42' > jeton.txt
docker build -q -f Dockerfile.secret --secret id=jeton,src=jeton.txt -t essai-secret .
docker run --rm essai-secret sh -c 'cat /info.txt; ls /run/secrets'
docker save essai-secret | tar -xO | grep -a -c jeton-tres-secret
docker rmi essai-secret; rm jeton.txt
```

```sortie
le jeton fait 20 octets
ls: /run/secrets: No such file or directory
0
```

Pendant l'instruction, le secret était lisible dans `/run/secrets/jeton` ; après, il n'existe plus, ni dans le système de fichiers, ni dans aucune couche : `grep` ne le trouve dans aucun des fichiers de l'archive de l'image (le `-a` traite les couches binaires comme du texte). `docker history` ne montre que la commande, pas le contenu. Comparez avec un `COPY jeton.txt` suivi d'un `RUN rm`, qui laisserait le jeton dans une couche pour toujours (exercice 2 du chapitre 10). Attention : écrire le secret lui-même dans un fichier de l'image, ou dans un `ENV`, annulerait toute cette précaution.

</details>

:::exercice[Exercice 4 : relire un Dockerfile avant de le construire]

Lancez `docker build --check` sur le `Dockerfile.naif` de `tampon`, puis sur une copie à laquelle vous ferez les modifications suivantes : `as` en minuscules après `FROM`, et `CMD tampon` en forme shell. Quels avertissements obtenez-vous ? Que risque-t-on avec le second ?

:::

<details>
<summary>Corrigé</summary>

Le `Dockerfile.naif` ne déclenche aucun avertissement : il est inefficace, mais correct. La copie modifiée donne :

```sortie
Check complete, 2 warnings have been found!
WARNING: FromAsCasing - https://docs.docker.com/go/dockerfile/rule/from-as-casing/
WARNING: JSONArgsRecommended - https://docs.docker.com/go/dockerfile/rule/json-args-recommended/
```

Le premier est une affaire de style. Le second est un vrai défaut : en forme shell, `CMD tampon` devient `/bin/sh -c tampon`, et c'est le shell qui est le PID 1 du conteneur ; il ne relaie pas `SIGTERM` à `tampon`, qui sera tué brutalement au bout de dix secondes à chaque `docker stop` (chapitre 4). Avec une base distroless, ce serait pire : il n'y a pas de `/bin/sh`, et le conteneur ne démarrerait pas du tout. `--check` s'intègre facilement à une chaîne d'intégration continue : il rend un code de sortie non nul quand une règle est enfreinte, si l'on ajoute `# check=error=true` en tête du Dockerfile.

</details>

## Nettoyer

Supprimez les images d'essai, l'archive multi-architecture et le constructeur `cours`, dont le conteneur garde son propre cache :

```bash
docker rmi tampon:naif tampon:alpine tampon:scratch tampon:scratch2 tampon:1.0.0
rm -rf tampon-multi.tar oci r3.tar
docker buildx rm cours
```

Les montages de cache créés par le constructeur par défaut de Docker restent dans son cache de construction ; `docker buildx du --filter type=exec.cachemount` les liste. Gardez `busybox:1.37`, qui resservira pour le dépannage.

[^multistage]: Docker, « Multi-stage builds ». [docs.docker.com/build/building/multi-stage](https://docs.docker.com/build/building/multi-stage/)

[^scratch]: Docker, « Base images », section *Create a minimal base image using scratch*. [docs.docker.com/build/building/base-images](https://docs.docker.com/build/building/base-images/)

[^distroless]: GoogleContainerTools, « Distroless container images ». [github.com/GoogleContainerTools/distroless](https://github.com/GoogleContainerTools/distroless)

[^buildkit-cache]: Docker, « Optimize cache usage in builds », section *Use cache mounts*. [docs.docker.com/build/cache/optimize](https://docs.docker.com/build/cache/optimize/)

[^sde]: Reproducible Builds, « SOURCE_DATE_EPOCH ». [reproducible-builds.org/docs/source-date-epoch](https://reproducible-builds.org/docs/source-date-epoch/)

[^buildkit-repro]: moby/buildkit, « Build reproducibility », documentation de `SOURCE_DATE_EPOCH` et de l'option `rewrite-timestamp`. [github.com/moby/buildkit/blob/master/docs/build-repro.md](https://github.com/moby/buildkit/blob/master/docs/build-repro.md)
