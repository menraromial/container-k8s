---
title: Premier conteneur
sidebar_label: 2. Premier conteneur
description: Lancer un conteneur au premier plan et en arrière-plan, lire ses journaux, y entrer, l'arrêter et le supprimer ; le cycle de vie d'un conteneur, les codes de sortie et les politiques de redémarrage.
partie: 1
chapitre: '2'
---

import cycleDeVie from '@site/src/figures/cycle-de-vie.svg';
import dockerStopSignaux from '@site/src/figures/docker-stop-signaux.svg';

Le chapitre précédent a lancé des conteneurs sans trop s'attarder sur la façon de le faire. Celui-ci prend le temps. On va démarrer un vrai serveur web, le regarder travailler, entrer dedans, le mettre en pause, l'arrêter, le relancer, et le supprimer. En chemin, vous verrez pourquoi un conteneur met parfois dix secondes à s'arrêter alors qu'un autre s'arrête instantanément, et ce que signifient les codes 137 ou 143 qu'on croise dans tous les journaux d'incidents.

Le serveur choisi est nginx, un serveur web très répandu, dans sa version 1.30 construite sur Alpine. Il a l'avantage de démarrer vite, d'écrire des journaux lisibles et de répondre à un simple `curl`.

## Lancer un conteneur au premier plan

La commande la plus simple :

```bash
docker run --name premier nginx:1.30-alpine
```

La première fois, Docker ne trouve pas l'image sur votre machine et la télécharge. Puis nginx démarre et écrit ses messages directement dans votre terminal :

```sortie
Unable to find image 'nginx:1.30-alpine' locally
1.30-alpine: Pulling from library/nginx
e2de96513ba9: Already exists
e3320d02d578: Pull complete
...
Digest: sha256:985220252f3863977e468f611ef118ebd01421289dd86ee1ae99cb068c3bce2b
Status: Downloaded newer image for nginx:1.30-alpine
/docker-entrypoint.sh: /docker-entrypoint.d/ is not empty, will attempt to perform configuration
...
/docker-entrypoint.sh: Configuration complete; ready for start up
2026/09/25 08:47:41 [notice] 1#1: using the "epoll" event method
2026/09/25 08:47:41 [notice] 1#1: nginx/1.30.5
2026/09/25 08:47:41 [notice] 1#1: OS: Linux 7.0.0-34-generic
2026/09/25 08:47:41 [notice] 1#1: start worker processes
2026/09/25 08:47:41 [notice] 1#1: start worker process 30
2026/09/25 08:47:41 [notice] 1#1: start worker process 31
...
```

Trois choses méritent un coup d'œil. La ligne `e2de96513ba9: Already exists` : l'image nginx est faite de plusieurs couches, et la première était déjà sur la machine, parce que c'est la couche de base d'Alpine, téléchargée au chapitre 1 ; Docker ne l'a pas retéléchargée. Le chapitre 3 explique ce mécanisme. Ensuite, la notation `1#1` : c'est le numéro du processus, et nginx se voit comme le processus 1, comme `sleep` au chapitre précédent. Enfin, nginx démarre un processus de travail (*worker*) par processeur ; sur le poste du cours, qui en a 22, la liste des `start worker process` est longue.

Le terminal est maintenant occupé : le conteneur tourne au premier plan, et votre shell attend qu'il se termine. Appuyez sur Ctrl+C. Docker transmet l'interruption à nginx, qui s'arrête proprement :

```sortie
2026/09/25 08:47:42 [notice] 1#1: signal 2 (SIGINT) received, exiting
2026/09/25 08:47:42 [notice] 32#32: exiting
...
2026/09/25 08:47:42 [notice] 1#1: exit
```

Le conteneur est-il supprimé pour autant ? Non. `docker ps` ne montre que les conteneurs en marche ; ajoutez `-a` (*all*) pour voir aussi les autres :

```bash
docker ps -a --filter name=premier
```

```sortie
CONTAINER ID   IMAGE               COMMAND                  CREATED        STATUS                              PORTS     NAMES
9d5115957e3a   nginx:1.30-alpine   "/docker-entrypoint.…"   1 second ago   Exited (0) Less than a second ago             premier
```

Le conteneur `premier` existe toujours, dans l'état `Exited (0)` : il est arrêté, et son processus principal s'est terminé avec le code 0, celui d'une fin normale. Ses fichiers et sa configuration sont conservés jusqu'à ce qu'on le supprime. C'est une source classique de confusion : un conteneur arrêté n'est pas un conteneur supprimé.

## Lancer un service en arrière-plan

Un serveur web n'a rien à faire au premier plan. On le lance en arrière-plan avec `-d` (*detached*), et on en profite pour lui donner un nom et publier un port :

```bash
docker run -d --name web -p 8080:80 nginx:1.30-alpine
```

```sortie
f6b02111967583f947dd2f558b6b8c156a0798f89a8757e27e7d0f78bf8cc5d2
```

Docker rend la main aussitôt et affiche l'identifiant complet du conteneur, 64 caractères hexadécimaux. On peut désigner un conteneur par cet identifiant, par son début tant qu'il n'est pas ambigu (`f6b0` suffit ici), ou par son nom. Sans `--name`, Docker en invente un en assemblant un adjectif et le nom d'un scientifique ou d'un ingénieur célèbre (`priceless_buck`, `adoring_noyce`...) ; donnez toujours un nom à vos conteneurs, vous les retrouverez plus facilement.

L'option `-p 8080:80` publie un port : les connexions qui arrivent sur le port 8080 de votre machine sont redirigées vers le port 80 du conteneur, où nginx écoute. Sans elle, nginx tournerait, mais rien ne pourrait l'atteindre depuis votre navigateur. Le chapitre 6 montre comment Docker réalise cette redirection.

```bash
docker ps
curl -s http://localhost:8080 | grep -o '<title>.*</title>'
```

```sortie
CONTAINER ID   IMAGE               COMMAND                  CREATED                  STATUS                  PORTS                                   NAMES
f6b021119675   nginx:1.30-alpine   "/docker-entrypoint.…"   Less than a second ago   Up Less than a second   0.0.0.0:8080->80/tcp, [::]:8080->80/tcp web
...
<title>Welcome to nginx!</title>
```

Les autres conteneurs qui tournaient sur la machine du cours ont été retirés de cette sortie (`...`). La colonne `PORTS` confirme la publication, en IPv4 (`0.0.0.0`, toutes les adresses de la machine) et en IPv6 (`[::]`). Ouvrez http://localhost:8080 dans votre navigateur : vous verrez la page d'accueil de nginx.

## Observer un conteneur

### Les journaux

Tout ce que le processus principal écrit sur sa sortie standard et sa sortie d'erreur est recueilli par Docker. `docker logs` le restitue :

```bash
docker logs web
```

```sortie
/docker-entrypoint.sh: /docker-entrypoint.d/ is not empty, will attempt to perform configuration
...
2026/09/25 08:47:42 [notice] 1#1: start worker process 51
172.17.0.1 - - [25/Sep/2026:08:47:43 +0000] "GET / HTTP/1.1" 200 896 "-" "curl/8.18.0" "-"
```

La dernière ligne est la trace de votre `curl` : nginx écrit une ligne par requête. Elle vient de l'adresse `172.17.0.1`, que nous expliquerons au chapitre 6 ; retenez pour l'instant que la requête n'arrive pas au conteneur avec l'adresse de votre machine sur le réseau, mais avec celle d'une interface réseau propre à Docker.

Pour un conteneur qui tourne depuis des jours, la sortie complète serait interminable. Trois options s'utilisent constamment : `--tail N` pour les N dernières lignes, `--timestamps` pour préfixer chaque ligne de l'heure exacte à laquelle Docker l'a reçue, et `-f` (*follow*) pour suivre le journal en continu, comme `tail -f`, jusqu'à Ctrl+C.

```bash
docker logs --tail 2 --timestamps web
```

```sortie
2026-09-25T08:47:42.775488780Z 2026/09/25 08:47:42 [notice] 1#1: start worker process 51
2026-09-25T08:47:43.812589770Z 172.17.0.1 - - [25/Sep/2026:08:47:43 +0000] "GET / HTTP/1.1" 200 896 "-" "curl/8.18.0" "-"
```

Cette façon de journaliser, sur la sortie standard plutôt que dans des fichiers, est la norme dans le monde des conteneurs. Les images officielles de nginx redirigent d'ailleurs ses fichiers de journal vers la sortie standard pour cette raison. Une application qui écrit ses journaux dans un fichier à l'intérieur du conteneur les rend invisibles à `docker logs`, et les perd quand le conteneur est supprimé. Nous retrouverons ce principe avec Kubernetes, dont `kubectl logs` fonctionne exactement de la même façon.

### Les processus et la consommation

`docker top` liste les processus du conteneur, vus depuis la machine :

```bash
docker top web
```

```sortie
UID        PID      PPID     C   STIME   TTY   TIME       CMD
root       272812   272791   1   10:47   ?     00:00:00   nginx: master process nginx -g daemon off;
message+   272882   272812   0   10:47   ?     00:00:00   nginx: worker process
message+   272883   272812   0   10:47   ?     00:00:00   nginx: worker process
...
```

On y retrouve ce que l'on a vu au chapitre 1 : le processus principal de nginx porte le numéro 272812 sur la machine, alors qu'il se voit comme le numéro 1. Les *workers* ne tournent pas sous `root` : la colonne `UID` affiche `message+`, un nom tronqué. Le conteneur les fait tourner sous l'utilisateur `nginx`, dont le numéro (101) correspond, sur le poste du cours, à l'utilisateur `messagebus` du système hôte. Le noyau ne connaît que des numéros ; c'est `ps`, sur la machine, qui traduit 101 en nom en lisant le `/etc/passwd` de la machine, pas celui du conteneur. Cette petite étrangeté reviendra au chapitre 12, quand on parlera des utilisateurs dans les conteneurs.

`docker stats` affiche la consommation en direct ; `--no-stream` prend une seule mesure :

```bash
docker stats --no-stream web
```

```sortie
CONTAINER ID   NAME      CPU %     MEM USAGE / LIMIT     MEM %     NET I/O           BLOCK I/O         PIDS
f6b021119675   web       0.00%     17.14MiB / 15.05GiB   0.11%     6.71kB / 2.25kB   16.4kB / 32.8kB   23
```

nginx et ses 22 *workers* (23 processus au total, colonne `PIDS`) occupent 17 Mo. La limite affichée, 15 Go, est toute la mémoire de la machine : on n'a fixé aucun plafond. Ces chiffres viennent directement des cgroups du chapitre 9.

### Tout le reste : docker inspect

`docker inspect` affiche, en JSON, tout ce que Docker sait d'un conteneur : sa configuration, son état, son réseau, ses montages. La sortie complète fait plusieurs centaines de lignes ; l'option `--format` en extrait les champs voulus avec la syntaxe des gabarits Go :

```bash
docker inspect web --format 'état={{.State.Status}} pid={{.State.Pid}} démarré={{.State.StartedAt}} ip={{.NetworkSettings.Networks.bridge.IPAddress}}'
```

```sortie
état=running pid=272812 démarré=2026-09-25T08:47:42.521469524Z ip=172.17.0.7
```

Prenez l'habitude de lancer `docker inspect` sans `--format` sur un conteneur et de parcourir la sortie une fois : vous y retrouverez chaque option de `docker run` que vous avez utilisée.

## Entrer dans un conteneur

`docker exec` lance une commande supplémentaire dans un conteneur qui tourne déjà. Regardons par exemple les fichiers que sert nginx :

```bash
docker exec web ls -l /usr/share/nginx/html
```

```sortie
total 8
-rw-r--r--    1 root     root           497 Sep 15 15:16 50x.html
-rw-r--r--    1 root     root           896 Sep 15 15:16 index.html
```

Le nouveau processus entre dans les mêmes namespaces que nginx : il voit les mêmes fichiers, le même réseau, les mêmes processus. On peut donc aussi modifier ce que le conteneur contient :

```bash
docker exec web sh -c 'echo "<h1>Bonjour depuis le conteneur</h1>" > /usr/share/nginx/html/index.html'
curl -s http://localhost:8080
```

```sortie
<h1>Bonjour depuis le conteneur</h1>
```

La page a changé. Cette modification vit dans la couche modifiable du conteneur `web` ; l'image `nginx:1.30-alpine` n'a pas bougé, et un autre conteneur lancé à partir d'elle afficherait toujours la page d'origine. Modifier un conteneur à la main de cette façon est utile pour comprendre ou pour dépanner, jamais pour livrer : la modification disparaîtra avec le conteneur. La bonne façon de changer ce qu'il contient est de construire une nouvelle image (chapitre 4).

Pour travailler de façon interactive, on ouvre un shell. Deux options sont nécessaires : `-i` garde l'entrée standard ouverte, pour que vos frappes arrivent au shell, et `-t` alloue un pseudo-terminal, pour que le shell se comporte comme dans un vrai terminal (invite, édition de la ligne, Ctrl+C). On les écrit presque toujours ensemble :

```bash
docker exec -it web sh
```

Vous êtes alors dans le conteneur ; `exit` vous en fait sortir, sans arrêter nginx. La même paire d'options sert avec `docker run` pour lancer un conteneur interactif. Voici par exemple un shell Alpine jetable, qui affiche le terminal qu'on lui a attribué, son nom de machine et sa version :

```bash
docker run -it --rm alpine:3.24 sh -c 'tty; hostname; cat /etc/alpine-release'
```

```sortie
/dev/pts/0
210a4e30e443
3.24.2
```

Le nom de machine du conteneur est le début de son identifiant : chaque conteneur a son propre namespace UTS, celui qui porte le nom de la machine. L'option `--rm` supprime le conteneur dès qu'il se termine, ce qui évite d'accumuler des conteneurs arrêtés quand on fait des essais.

:::note[Et s'il n'y a pas de shell ?]

Certaines images minimales, dites *distroless*, ne contiennent ni `sh` ni `ls` : seulement l'application et ses bibliothèques. `docker exec -it ... sh` y échoue. C'est voulu (moins de programmes, c'est moins de failles), et nous verrons au chapitre 13 comment déboguer malgré tout ce genre de conteneur.

:::

## Le cycle de vie d'un conteneur

Un conteneur passe par une poignée d'états, et chaque commande le fait passer de l'un à l'autre.

<Figure svg={cycleDeVie} num="2.1" alt="Diagramme d'états : créé, en marche, en pause, arrêté, supprimé, avec les commandes qui font passer de l'un à l'autre.">
Les états d'un conteneur et les commandes qui le font changer d'état. <code>docker run</code> n'est qu'un raccourci pour <code>docker create</code> suivi de <code>docker start</code>.
</Figure>

On peut séparer la création et le démarrage. `docker create` prépare le conteneur sans le lancer ; `docker start -a` le démarre et attache le terminal à sa sortie :

```bash
docker create --name c2 alpine:3.24 echo bonjour
docker ps -a --filter name=c2 --format '{{.Names}} {{.Status}}'
docker start -a c2
docker ps -a --filter name=c2 --format '{{.Names}} {{.Status}}'
```

```sortie
888cf748c2b407af16e121a46e939d73d2e2726cb38a30ec05ffa3bb9d5410f8
c2 Created
bonjour
c2 Exited (0) Less than a second ago
```

Le conteneur passe de `Created` à `Exited (0)` en une fraction de seconde : `echo` affiche son message et se termine. Un conteneur ne vit jamais plus longtemps que son processus principal. C'est la règle la plus importante de ce chapitre, et elle explique beaucoup de surprises de débutant : un conteneur lancé à partir d'une image dont le programme se termine aussitôt (un script, une commande `echo`) s'arrête aussitôt lui aussi.

La pause est un état à part. `docker pause` gèle tous les processus du conteneur sans les arrêter : ils ne reçoivent plus de temps de processeur, mais gardent leur mémoire et leurs connexions.

```bash
docker pause web
docker ps --filter name=web --format '{{.Names}} {{.Status}}'
timeout 3 curl -s http://localhost:8080; echo "curl code=$?"
docker unpause web
curl -s -m 3 http://localhost:8080
```

```sortie
web
web Up 3 seconds (Paused)
curl code=124
web
<h1>Bonjour depuis le conteneur</h1>
```

Pendant la pause, `curl` attend une réponse qui ne vient pas, et `timeout` l'interrompt au bout de 3 secondes (le code 124 est celui de `timeout`). Dès la reprise, nginx répond comme si de rien n'était, avec la page modifiée : rien n'a été perdu. Ce gel est assuré par le *freezer* des cgroups, que nous manipulerons à la main au chapitre 9.

## Arrêter un conteneur, et pourquoi c'est parfois lent

`docker stop` demande poliment au processus principal de s'arrêter :

```bash
time docker stop web
docker ps -a --filter name=web --format '{{.Names}} {{.Status}}'
```

```sortie
web
0.29 s
web Exited (0) Less than a second ago
```

Moins de 3 dixièmes de seconde, et un code de sortie 0. Refaisons la même expérience avec le conteneur `sleep` du chapitre 1 :

```bash
docker run -d --name tue alpine:3.24 sleep 300
time docker stop tue
docker inspect tue --format 'code de sortie : {{.State.ExitCode}}'
```

```sortie
tue
10.24 s
code de sortie : 137
```

Dix secondes, et un code 137. Pour comprendre, il faut savoir ce que fait `docker stop`. Il envoie d'abord au processus principal le signal SIGTERM, qui veut dire « termine-toi proprement ». Puis il attend. Si le processus est toujours là au bout de 10 secondes (le délai par défaut, réglable avec `--time`), Docker envoie SIGKILL, que le noyau exécute sans demander son avis au processus : il est tué sur-le-champ.

nginx a prévu ce qu'il fait quand il reçoit SIGTERM : il termine les requêtes en cours et s'arrête. `sleep`, lui, n'a rien prévu. Dans un processus ordinaire, ce n'est pas un problème : un signal sans gestionnaire provoque l'action par défaut, qui pour SIGTERM est de terminer le processus. Mais `sleep` est ici le processus numéro 1 de son namespace, et le noyau protège ce processus particulier : il ne lui livre un signal que s'il a installé un gestionnaire pour ce signal[^pid-namespaces]. Sans gestionnaire, SIGTERM est ignoré, Docker attend ses 10 secondes et finit par SIGKILL.

Docker propose une parade : l'option `--init` place devant votre programme un minuscule processus d'initialisation, `tini`, qui devient le numéro 1 et transmet les signaux qu'il reçoit :

```bash
docker run -d --init --name tue2 alpine:3.24 sleep 300
time docker stop tue2
docker inspect tue2 --format 'code de sortie : {{.State.ExitCode}}'
```

```sortie
tue2
0.19 s
code de sortie : 143
```

<Figure svg={dockerStopSignaux} num="2.2" alt="Deux chronologies de docker stop. Sans init : SIGTERM ignoré, SIGKILL au bout de 10 secondes, 10,24 s, code 137. Avec --init : SIGTERM transmis, arrêt en 0,19 s, code 143.">
Ce que fait <code>docker stop</code>. Les deux mesures ont été faites sur le poste du cours avec le même conteneur <code>sleep 300</code>.
</Figure>

Ce détail a des conséquences très concrètes. Un conteneur qui met dix secondes à s'arrêter ralentit chaque mise à jour, chaque redémarrage ; en production, avec des dizaines de conteneurs, cela se compte en minutes. Pire, un processus tué par SIGKILL n'a pas le temps de terminer ce qu'il faisait : une requête en cours échoue, un fichier est laissé à moitié écrit. Le chapitre 4 montre comment écrire une image dont le programme reçoit bien les signaux, sans avoir besoin de `--init`.

## Lire un code de sortie

Le code de sortie du processus principal devient celui du conteneur, et `docker run` le renvoie à votre shell. Un script peut ainsi savoir si ce qu'il a lancé dans un conteneur a réussi :

```bash
docker run --rm alpine:3.24 sh -c 'exit 3'; echo "code=$?"
```

```sortie
code=3
```

Au-delà des codes propres à chaque programme, quelques valeurs reviennent constamment, parce qu'elles sont fixées par le shell ou par Docker. Les voici, chacune obtenue sur le poste du cours.

| Code | Signification | Exemple |
|---|---|---|
| 0 | fin normale | `echo bonjour` |
| 1 à 124 | erreur signalée par le programme lui-même | `exit 3` renvoie 3 |
| 125 | Docker lui-même a échoué, avant de lancer quoi que ce soit | option inconnue : `docker run --memoire=1g ...` |
| 126 | la commande existe mais ne peut pas être exécutée | `docker run alpine:3.24 /etc/passwd` |
| 127 | la commande est introuvable | `docker run alpine:3.24 commande-inexistante` |
| 128 + N | le processus a été tué par le signal numéro N | 137 = 128 + 9 (SIGKILL), 143 = 128 + 15 (SIGTERM) |

Les messages de Docker disent la même chose en plus détaillé. Pour une commande introuvable :

```sortie
docker: Error response from daemon: failed to create task for container: failed to create shim task: OCI runtime create failed: runc create failed: unable to start container process: exec: "commande-inexistante": executable file not found in $PATH
```

Ce message long est instructif si on le lit de droite à gauche : `exec` n'a pas trouvé l'exécutable ; c'est `runc` qui essayait de le lancer ; runc était appelé par un *shim* ; le tout à la demande du démon. Vous reconnaîtrez la pile du chapitre 11.

Le code 137 mérite une attention particulière. Il signifie « tué par SIGKILL », et SIGKILL a deux origines fréquentes : un `docker stop` qui a dû forcer, comme ci-dessus, ou le noyau qui tue un processus ayant dépassé sa limite de mémoire. Dans Kubernetes, ce second cas s'affiche `OOMKilled` avec le code 137 ; nous le provoquerons volontairement au chapitre 9.

## Redémarrer automatiquement

Un service doit se relancer s'il plante. Docker le fait avec une politique de redémarrage, choisie au lancement :

| Politique | Effet |
|---|---|
| `no` | ne jamais redémarrer (par défaut) |
| `on-failure[:N]` | redémarrer si le code de sortie n'est pas 0, au plus N fois |
| `always` | toujours redémarrer, y compris au démarrage du démon Docker |
| `unless-stopped` | comme `always`, sauf si on a arrêté le conteneur à la main |

Essayons avec un programme qui échoue systématiquement :

```bash
docker run -d --name fragile --restart on-failure:3 alpine:3.24 sh -c 'echo démarrage à $(date +%T); sleep 1; exit 1'
sleep 12
docker logs fragile
docker inspect fragile --format 'redémarrages : {{.RestartCount}}, état : {{.State.Status}}, code : {{.State.ExitCode}}'
```

```sortie
démarrage à 08:48:04
démarrage à 08:48:05
démarrage à 08:48:06
démarrage à 08:48:08
redémarrages : 3, état : exited, code : 1
```

Un premier démarrage, puis trois redémarrages, et Docker abandonne. Regardez l'heure des démarrages : l'écart entre eux grandit (une seconde, une seconde, puis deux). Docker ajoute avant chaque redémarrage un délai qui double à chaque fois, en partant de 100 millisecondes, pour ne pas faire tourner en boucle folle un programme qui plante dès son lancement[^restart]. Retenez ce comportement : Kubernetes fait exactement la même chose, et l'affiche sous le nom de `CrashLoopBackOff`, l'un des états que vous verrez le plus souvent dans la partie III.

## Supprimer

Un conteneur arrêté occupe encore de la place : sa couche modifiable, sa configuration, ses journaux. `docker rm` le supprime. Sur un conteneur en marche, Docker refuse :

```bash
docker rm web
```

```sortie
Error response from daemon: cannot remove container "web": container is running: stop the container before removing or force remove
```

Il faut l'arrêter d'abord, ou forcer avec `docker rm -f`, qui envoie directement SIGKILL puis supprime. Pour faire le ménage de ce chapitre, on nomme explicitement chaque conteneur :

```bash
docker rm -f web premier c2 tue tue2 fragile
```

:::danger[docker container prune agit sur toute la machine]

La commande `docker container prune` supprime d'un coup **tous** les conteneurs arrêtés de la machine, pas seulement les vôtres ni ceux de votre projet. Sur un poste partagé entre plusieurs projets, elle efface aussi les conteneurs arrêtés des autres, avec tout ce qu'ils avaient écrit dans leur couche modifiable. Pendant l'écriture de ce cours, elle a ainsi supprimé le nœud arrêté d'un cluster minikube et deux conteneurs d'un autre projet qui n'avaient rien à voir avec le chapitre. Préférez toujours `docker rm` avec des noms explicites, et avant tout `prune`, regardez ce qui sera supprimé avec `docker ps -a --filter status=exited`.

:::

## Exercices

:::exercice[Exercice 1 : un conteneur qui ne reste pas]

Lancez `docker run -d --name eclair alpine:3.24` puis `docker ps`. Le conteneur n'apparaît pas. Où est-il passé, et pourquoi ? Faites-le tenir en marche en arrière-plan.

:::

<details>
<summary>Corrigé</summary>

`docker ps -a` le montre dans l'état `Exited (0)`. L'image `alpine:3.24` lance `/bin/sh` par défaut ; sans terminal attaché (`-it`), le shell trouve son entrée standard fermée, n'a rien à lire et se termine aussitôt, et le conteneur avec lui. Un conteneur ne vit pas plus longtemps que son processus principal. Pour le garder en marche, il faut lui donner un processus qui dure, par exemple `docker run -d --name eclair alpine:3.24 sleep infinity`, ou un shell interactif avec `docker run -dit`. Supprimez-le ensuite avec `docker rm -f eclair`.

</details>

:::exercice[Exercice 2 : deux serveurs web]

Lancez deux conteneurs nginx en même temps, l'un joignable sur le port 8081 de votre machine, l'autre sur le port 8082. Modifiez la page d'accueil du second seulement. Vérifiez avec `curl` que les deux pages diffèrent. Que se passe-t-il si vous essayez de lancer un troisième conteneur sur le port 8081 ?

:::

<details>
<summary>Corrigé</summary>

```bash
docker run -d --name web1 -p 8081:80 nginx:1.30-alpine
docker run -d --name web2 -p 8082:80 nginx:1.30-alpine
docker exec web2 sh -c 'echo "<h1>Je suis web2</h1>" > /usr/share/nginx/html/index.html'
curl -s localhost:8081 | grep -o '<title>.*</title>'
curl -s localhost:8082
```

La première page reste celle de nginx, la seconde affiche `Je suis web2` : chaque conteneur a sa propre couche modifiable, même s'ils partagent la même image. Pour le troisième, Docker crée le conteneur mais ne peut pas le démarrer :

```sortie
docker: Error response from daemon: failed to set up container networking: driver failed programming external connectivity on endpoint web3 (57f79b46e0fb...): Bind for 0.0.0.0:8081 failed: port is already allocated
```

Un port de la machine ne peut être publié qu'une fois. La commande renvoie le code 125 (échec de Docker lui-même) et le conteneur reste dans l'état `Created`. Supprimez-le avec les deux autres : `docker rm -f web1 web2 web3`.

</details>

:::exercice[Exercice 3 : trouver le code de sortie]

Pour chacune de ces commandes, prévoyez le code de sortie avant de l'exécuter, puis vérifiez avec `echo $?` :
`docker run --rm alpine:3.24 false`,
`docker run --rm alpine:3.24 ls /inexistant`,
`docker run --rm alpine:3.24 sh -c 'kill -TERM $$'`,
`docker run --rm alpine:3.24 /bin`.

:::

<details>
<summary>Corrigé</summary>

| Commande | Code obtenu |
|---|---|
| `false` | 1 |
| `ls /inexistant` | 1 |
| `sh -c 'kill -TERM $$'` | 0 |
| `/bin` | 126 |

`false` renvoie 1, par définition. `ls` sur un chemin inexistant renvoie 1 dans la version BusyBox d'Alpine (le `ls` de GNU renverrait 2) : chaque programme choisit ses codes, et il faut parfois lire sa documentation.

Le troisième cas est le plus intéressant, et beaucoup de gens prévoient 143. Le shell s'envoie SIGTERM à lui-même. Sur votre poste, c'est bien ce qui arrive : `sh -c 'kill -TERM $$'; echo $?` affiche 143. Mais dans le conteneur, ce shell est le processus numéro 1 de son namespace, sans gestionnaire pour SIGTERM : le noyau ne lui livre pas le signal, le shell continue, n'a plus rien à faire et se termine normalement, avec 0. C'est exactement le mécanisme qui rendait `docker stop` lent sur le conteneur `sleep`.

Enfin, `/bin` est un dossier, pas un programme : le démarrage échoue avec `exec: "/bin": is a directory: permission denied` et le code 126.

</details>

:::exercice[Exercice 4 : un serveur qui s'arrête vite]

Lancez `docker run -d --name lent alpine:3.24 sh -c 'while true; do sleep 1; done'` et mesurez la durée de `docker stop lent`. Proposez deux façons de rendre l'arrêt immédiat, et vérifiez-les.

:::

<details>
<summary>Corrigé</summary>

L'arrêt prend environ 10 secondes et se termine par le code 137 : le shell est le PID 1 du conteneur, il n'a pas de gestionnaire pour SIGTERM, le signal est ignoré et Docker finit par SIGKILL. Première solution : ajouter `--init`, qui place `tini` en PID 1 ; l'arrêt tombe sous la seconde. Seconde solution : installer un gestionnaire dans le script lui-même, par exemple `sh -c 'trap "exit 0" TERM; while true; do sleep 1; done'` ; le shell reçoit alors le signal et sort proprement avec le code 0, au plus une seconde plus tard, le temps que le `sleep` en cours se termine.

</details>

## Nettoyer

Si vous avez fait les exercices, supprimez les conteneurs qu'ils ont créés, par leur nom :

```bash
docker rm -f eclair web1 web2 web3 lent
```

Gardez l'image `nginx:1.30-alpine`, qui resservira au chapitre suivant.

[^pid-namespaces]: Linux man-pages, `pid_namespaces(7)`, section *The namespace init process* : seuls les signaux pour lesquels le processus init a installé un gestionnaire lui sont livrés depuis son propre namespace ; depuis un namespace ancêtre, seuls SIGKILL et SIGSTOP sont livrés d'office. [man7.org/linux/man-pages/man7/pid_namespaces.7.html](https://man7.org/linux/man-pages/man7/pid_namespaces.7.html)

[^restart]: Docker, « Start containers automatically », section *Restart policy details*. [docs.docker.com/engine/containers/start-containers-automatically](https://docs.docker.com/engine/containers/start-containers-automatically/)
