---
title: Le réseau des conteneurs
sidebar_label: 6. Le réseau
description: Comment les conteneurs obtiennent une adresse, se trouvent par leur nom et reçoivent des connexions de l'extérieur ; ponts, paires veth, DNS intégré, ports publiés ; Colis assemblé à la main.
partie: 1
chapitre: '6'
---

import reseauPont from '@site/src/figures/reseau-pont.svg';
import colisReseau from '@site/src/figures/colis-reseau.svg';

Colis a maintenant tout ce qu'il lui faut : une image pour l'API et le worker, une base PostgreSQL dont les données survivent. Il reste à relier les morceaux. L'API doit joindre PostgreSQL et Redis, le worker aussi, et le site web doit relayer les requêtes vers l'API. Chacun tourne dans son propre conteneur, avec son propre namespace réseau : comment se trouvent-ils ? Quelle adresse donner à l'API pour qu'elle trouve la base ?

Ce chapitre répond en deux temps. D'abord, on regarde ce que Docker installe sur votre machine pour que les conteneurs communiquent : une interface pont, des câbles virtuels, un serveur DNS, des règles de pare-feu. Ensuite, on assemble Colis à la main, conteneur par conteneur, et on tombe sur les deux pannes que Compose, au chapitre 7, apprendra à éviter.

## Le réseau par défaut

Au chapitre 2, les requêtes vers nginx arrivaient de l'adresse `172.17.0.1`. C'est l'adresse d'une interface que Docker crée sur votre machine à son installation, `docker0` :

```bash
ip -br addr show docker0
```

```sortie
docker0          UP             172.17.0.1/16 fe80::8c77:b7ff:fe53:29a8/64
```

`docker0` est un **pont** (*bridge*) : un commutateur réseau virtuel, réalisé par le noyau Linux, auquel on peut brancher d'autres interfaces. Les conteneurs lancés sans option réseau y sont branchés, et reçoivent une adresse dans le réseau `172.17.0.0/16`. Lançons-en deux :

```bash
docker run -d --name un alpine:3.24 sleep 600
docker run -d --name deux alpine:3.24 sleep 600
docker inspect un deux --format '{{.Name}} {{.NetworkSettings.Networks.bridge.IPAddress}}'
```

```sortie
/un 172.17.0.7
/deux 172.17.0.8
```

Vu de l'intérieur, chaque conteneur a une interface `eth0` avec son adresse, et une route par défaut qui passe par `docker0` :

```bash
docker exec un ip -4 addr show eth0
docker exec un ip route
```

```sortie
2: eth0@if413: <BROADCAST,MULTICAST,UP,LOWER_UP,M-DOWN> mtu 1500 qdisc noqueue state UP
    inet 172.17.0.7/16 brd 172.17.255.255 scope global eth0
       valid_lft forever preferred_lft forever
default via 172.17.0.1 dev eth0
172.17.0.0/16 dev eth0 scope link  src 172.17.0.7
```

Le suffixe `@if413` est un indice. L'interface `eth0` du conteneur est une extrémité d'une **paire veth** (*virtual ethernet*) : deux interfaces reliées comme par un câble, tout ce qui entre par l'une ressort par l'autre. Une extrémité est placée dans le namespace réseau du conteneur et renommée `eth0` ; l'autre reste sur votre machine et est branchée sur le pont. Le numéro 413 est l'index de cette autre extrémité. On peut la retrouver sur la machine :

```bash
ip -o link | grep "^413:"
```

```sortie
413: veth5f4250b@if2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue master docker0 state UP ...
```

L'interface `veth5f4250b` est branchée sur `docker0` (`master docker0`), et son `@if2` désigne en retour l'interface numéro 2 du conteneur, son `eth0`. Chaque conteneur lancé ajoute ainsi une interface `veth...` à votre machine ; `ip link` en montre autant qu'il y a de conteneurs en marche. Le numéro d'index change d'une machine et d'un conteneur à l'autre : chez vous, lisez-le dans la sortie de `ip addr` du conteneur.

Les deux conteneurs se joignent par leur adresse :

```bash
docker exec un ping -c 2 -W 1 172.17.0.8
```

```sortie
PING 172.17.0.8 (172.17.0.8): 56 data bytes
64 bytes from 172.17.0.8: seq=0 ttl=64 time=0.204 ms
64 bytes from 172.17.0.8: seq=1 ttl=64 time=0.166 ms
```

Mais pas par leur nom :

```bash
docker exec un ping -c 1 -W 1 deux
```

```sortie
ping: bad address 'deux'
```

Sur le réseau par défaut, les conteneurs n'ont pas de noms les uns pour les autres. Et les adresses ne servent à rien pour configurer une application : elles sont attribuées dans l'ordre de démarrage, et changent d'un lancement à l'autre. Il faut un autre réseau.

## Un réseau à soi

`docker network create` crée un nouveau réseau pont, avec sa propre interface sur la machine et sa propre plage d'adresses :

```bash
docker network create colis
docker network inspect colis --format '{{range .IPAM.Config}}{{.Subnet}} passerelle {{.Gateway}}{{end}}'
ip -br addr | grep '^br-'
```

```sortie
41b419c9078870a0481f5ac3aacaf987a24716dcba3ea3e7b93133a150393078
172.19.0.0/16 passerelle 172.19.0.1
br-41b419c90788  DOWN           172.19.0.1/16
```

Le réseau `colis` a son pont, `br-41b419c90788` (les premiers caractères de l'identifiant du réseau), sur la plage `172.19.0.0/16` : Docker a choisi la première plage libre sur votre machine, la vôtre peut différer. Le pont est `DOWN` tant qu'aucun conteneur n'y est branché. Branchons-y le conteneur `un`, en plus du réseau par défaut, et lançons-en un troisième directement sur `colis` :

```bash
docker network connect colis un
docker run -d --name trois --network colis alpine:3.24 sleep 600
docker exec un ping -c 2 -W 1 trois
```

```sortie
PING trois (172.19.0.3): 56 data bytes
64 bytes from 172.19.0.3: seq=0 ttl=64 time=0.202 ms
64 bytes from 172.19.0.3: seq=1 ttl=64 time=0.172 ms
```

Cette fois, le nom fonctionne. Sur un réseau créé par l'utilisateur, Docker fournit un serveur DNS intégré, que chaque conteneur interroge à l'adresse `127.0.0.11` :

```bash
docker exec trois cat /etc/resolv.conf
docker exec trois nslookup un 127.0.0.11
```

```sortie
nameserver 127.0.0.11
options edns0 trust-ad ndots:0
...
Server:		127.0.0.11
Address:	127.0.0.11:53

Name:	un
Address: 172.19.0.2
```

Le fichier `/etc/resolv.conf` du conteneur désigne le serveur DNS intégré (une ligne `search`, propre au réseau du poste du cours, a été retirée de la sortie). Ce serveur répond pour les noms des conteneurs du réseau, et transmet les autres questions aux serveurs DNS de votre machine, si bien que les conteneurs résolvent aussi les noms d'Internet. Sur le réseau par défaut, au contraire, le conteneur reçoit une simple copie des serveurs DNS de votre machine, qui ne connaissent pas les conteneurs : d'où l'échec de `ping deux`.

Le réseau délimite aussi qui peut parler à qui. `trois` n'est branché que sur `colis`, et ne joint pas `deux`, qui n'est que sur le réseau par défaut :

```bash
docker exec trois ping -c 1 -W 1 172.17.0.8
```

```sortie
PING 172.17.0.8 (172.17.0.8): 56 data bytes

--- 172.17.0.8 ping statistics ---
1 packets transmitted, 0 packets received, 100% packet loss
```

Docker isole les réseaux entre eux par des règles de pare-feu. Un conteneur peut être branché sur plusieurs réseaux, comme `un` ici, et sert alors de passerelle entre eux au niveau applicatif : c'est le principe d'un réseau de façade et d'un réseau interne, que l'exercice 1 met en œuvre.

<Figure svg={reseauPont} num="6.1" alt="Sur la machine, les conteneurs web, api et postgres ont chacun une interface eth0 reliée par une paire veth au pont br-41b419c90788. Le DNS intégré résout api en 172.19.0.4. La carte réseau de la machine reçoit les connexions du navigateur sur le port 8080, que des règles iptables redirigent vers web.">
Le réseau <code>colis</code> vu depuis la machine. Chaque conteneur est branché au pont par une paire veth ; des règles iptables posées par Docker redirigent le port publié et masquent les adresses des conteneurs à la sortie.
</Figure>

Deux autres modes existent, à connaître. Avec `--network none`, le conteneur n'a que son interface locale, `lo` : aucune communication réseau, ce qui convient à un traitement qui n'a besoin que de fichiers. Avec `--network host`, le conteneur n'a pas de namespace réseau à lui : il voit et utilise directement les interfaces de la machine. Sur le poste du cours, `docker run --rm --network host alpine:3.24 ip -o link` liste `lo`, `wlp0s20f3` (la carte Wi-Fi), `docker0`, les ponts `br-...` et toutes les interfaces `veth`. Ce mode évite toute traduction d'adresses, mais supprime l'isolation réseau, et deux conteneurs ne peuvent plus écouter sur le même port.

`docker rm -f un deux trois` fait le ménage.

## Publier un port

Un conteneur branché sur un pont a une adresse privée, que rien ne connaît hors de la machine. Pour le rendre joignable, on publie un de ses ports avec `-p port_machine:port_conteneur`. Docker s'y prend de deux façons à la fois.

La première est une traduction d'adresses dans le pare-feu du noyau. Docker ajoute une règle DNAT (*destination NAT*) : un paquet qui arrive sur le port publié de la machine voit son adresse de destination réécrite en celle du conteneur. Voici celle qui publie le port 8080 vers le conteneur `web` que nous lancerons plus loin. Lire les règles du pare-feu demande les droits de `root` ; on les obtient ici en lançant un conteneur privilégié qui partage le réseau de la machine, ce qui revient au même et montre, une fois de plus, ce que vaut l'appartenance au groupe `docker` :

```bash
docker run --rm --privileged --network host alpine:3.24 sh -c \
  'apk add -q iptables >/dev/null 2>&1; iptables -t nat -S DOCKER | grep "dport 8080"; iptables -t nat -S POSTROUTING | grep MASQUERADE'
```

```sortie
-A DOCKER ! -i br-41b419c90788 -p tcp -m tcp --dport 8080 -j DNAT --to-destination 172.19.0.6:80
-A POSTROUTING -s 172.19.0.0/16 ! -o br-41b419c90788 -j MASQUERADE
-A POSTROUTING -s 192.168.49.0/24 ! -o br-b1c5c48739e0 -j MASQUERADE
-A POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE
```

La première ligne se lit : un paquet TCP à destination du port 8080, qui n'arrive pas du pont lui-même, est redirigé vers `172.19.0.6:80`. Les lignes `MASQUERADE` font l'opération inverse pour le trafic sortant : un paquet qui quitte un réseau de conteneurs vers l'extérieur prend l'adresse de la machine. C'est ce qui permet aux conteneurs d'accéder à Internet. Vous reconnaissez `192.168.49.0/24` : c'est le réseau du cluster minikube du chapitre 0.2.

La seconde façon est un petit programme, `docker-proxy`, que Docker lance pour chaque port publié. Il écoute sur le port de la machine et relaie les connexions vers le conteneur. Il sert dans les cas où la traduction d'adresses ne s'applique pas, en particulier les connexions à `localhost` depuis la machine elle-même :

```bash
ps -eo user,cmd | grep '[d]ocker-proxy' | grep 8080
```

```sortie
root     /usr/bin/docker-proxy -proto tcp -host-ip 0.0.0.0 -host-port 8080 -container-ip 172.19.0.6 -container-port 80 -use-listen-fd
root     /usr/bin/docker-proxy -proto tcp -host-ip :: -host-port 8080 -container-ip 172.19.0.6 -container-port 80 -use-listen-fd
```

Un processus pour IPv4, un pour IPv6. Nous retrouverons exactement ce mécanisme, des règles de traduction posées dans le noyau, avec kube-proxy au chapitre 40.

:::warning[Un port publié est ouvert sur toutes les adresses de la machine]

`-p 8080:80` publie le port sur `0.0.0.0`, c'est-à-dire sur toutes les interfaces : il est joignable depuis le réseau Wi-Fi de votre salle, pas seulement depuis votre navigateur. Et les règles de Docker s'appliquent avant celles d'un pare-feu comme ufw, qui ne les voit pas : un port publié peut être ouvert alors que votre pare-feu semble le bloquer[^docker-firewall]. Pour un service qui ne doit être joint que depuis votre machine, publiez-le sur l'adresse locale : avec `-p 127.0.0.1:8090:80`, `docker ps` affiche `127.0.0.1:8090->80/tcp` au lieu de `0.0.0.0:8090->80/tcp`, et le port n'est joignable que depuis votre machine.

:::

:::panne[failed to bind host port 0.0.0.0:5432/tcp: address already in use]

Deux messages voisins désignent deux situations différentes. `port is already allocated` (chapitre 2) signifie qu'un autre conteneur publie déjà ce port. `address already in use` signifie qu'un programme de la machine, hors de Docker, écoute déjà sur ce port. Sur le poste du cours, un serveur PostgreSQL installé en dehors de Docker occupe le 5432 :

```sortie
docker: Error response from daemon: failed to set up container networking: driver failed programming external connectivity on endpoint deux (3ad7052109b3...): failed to bind host port 0.0.0.0:5432/tcp: address already in use
```

`ss -ltnp | grep 5432` montre qui occupe le port. Choisissez un autre port de la machine (`-p 5433:5432`), ou, mieux, ne publiez pas le port d'une base de données : ses clients sont des conteneurs, qui la joignent par le réseau interne.

:::

## Colis, assemblé à la main

Assemblons Colis sur le réseau `colis`, dans l'ordre des dépendances. PostgreSQL d'abord, avec son volume, puis Redis :

```bash
docker volume create colis-donnees
docker run -d --name postgres --network colis \
  -e POSTGRES_USER=colis -e POSTGRES_PASSWORD=colis -e POSTGRES_DB=colis \
  -v colis-donnees:/var/lib/postgresql postgres:18-alpine
docker run -d --name redis --network colis redis:8.8-alpine
```

Le nom du conteneur devient son nom sur le réseau : l'API trouvera la base à l'adresse `postgres`, et Redis à l'adresse `redis`. On lui donne ces adresses par les variables d'environnement prévues au chapitre 4, et on la lance aussitôt :

```bash
docker run -d --name api --network colis \
  -e COLIS_DB=postgresql://colis:colis@postgres:5432/colis \
  -e COLIS_REDIS=redis://redis:6379/0 colis:1.0
docker ps -a --filter name=^api$ --format '{{.Names}} {{.Status}}'
docker logs api 2>&1 | tail -3
```

```sortie
api Exited (1) 1 second ago
psycopg.OperationalError: connection failed: connection to server at "172.19.0.2", port 5432 failed: Connection refused
	Is the server running on that host and accepting TCP/IP connections?
```

Première panne. Le nom `postgres` a bien été résolu en `172.19.0.2`, mais la connexion est refusée : PostgreSQL était encore en train d'initialiser sa base, et n'écoutait pas encore. L'API, qui ouvre sa connexion au démarrage, a échoué et s'est arrêtée. Un conteneur démarré n'est pas un service prêt. Attendons que PostgreSQL le soit, puis relançons l'API :

```bash
until docker exec postgres pg_isready -U colis -d colis; do sleep 1; done
docker rm api
docker run -d --name api --network colis \
  -e COLIS_DB=postgresql://colis:colis@postgres:5432/colis \
  -e COLIS_REDIS=redis://redis:6379/0 colis:1.0
docker logs api 2>&1 | tail -2
```

```sortie
INFO:     Application startup complete.
INFO:     Uvicorn running on http://0.0.0.0:8000 (Press CTRL+C to quit)
```

Le worker suit, avec la même image et sa propre commande :

```bash
docker run -d --name worker --network colis \
  -e COLIS_DB=postgresql://colis:colis@postgres:5432/colis \
  -e COLIS_REDIS=redis://redis:6379/0 colis:1.0 python -m colis.worker
docker logs worker
```

```sortie
worker 3356a4b84ab6 prêt (stockage : postgres)
```

### Le site web

Il reste le composant `web` : nginx, qui sert une petite page et relaie vers l'API tout ce qui commence par `/api/`. Téléchargez [l'archive du site](pathname:///kits/colis-web.tar.gz) et décompressez-la dans le dossier `colis`, à côté de `app`. Sa configuration nginx est courte :

```nginx title="web/nginx.conf"
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;

    location / {
        try_files $uri /index.html;
    }

    # L'API est jointe par son nom, « api », sur le réseau des conteneurs (chapitre 6).
    # nginx résout ce nom au démarrage : sans conteneur « api », il refuse de démarrer.
    location /api/ {
        proxy_pass http://api:8000/;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

La ligne `proxy_pass http://api:8000/` désigne l'API par son nom de conteneur. La barre oblique finale compte : elle fait retirer le préfixe `/api/` avant de transmettre, si bien qu'une requête pour `/api/sante` arrive à l'API sous la forme `/sante`. Le Dockerfile se contente de copier la configuration et les pages dans l'image nginx officielle :

```dockerfile title="web/Dockerfile"
# Image web de Colis : nginx sert la page et relaie /api/ vers l'API.
FROM nginx:1.30-alpine

LABEL org.opencontainers.image.title="colis-web" \
      org.opencontainers.image.description="Site web de Colis, servi par nginx" \
      org.opencontainers.image.source="https://github.com/menraromial/container-k8s" \
      org.opencontainers.image.version="1.0.0"

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY site/ /usr/share/nginx/html/
```

```bash
docker build -t colis-web:1.0 web
```

Avant de le lancer pour de bon, faisons une expérience : que se passe-t-il si l'API n'est pas là ? Arrêtez-la, lancez `web`, et observez son état pendant quelques secondes :

```bash
docker stop api
docker run -d --name web --network colis -p 8080:80 colis-web:1.0
for i in 1 2 3 4; do sleep 2; docker ps -a --filter name=^web$ --format '{{.Status}}'; done
docker logs web 2>&1 | tail -1
```

```sortie
Up 2 seconds
Up 4 seconds
Exited (1) 1 second ago
Exited (1) 3 seconds ago
nginx: [emerg] host not found in upstream "api" in /etc/nginx/conf.d/default.conf:13
```

Deuxième panne, et elle est sournoise : pendant cinq secondes, `docker ps` affiche `Up`, puis le conteneur s'arrête avec le code 1. nginx résout au démarrage chaque nom qui apparaît dans un `proxy_pass`. Un conteneur arrêté n'a plus de nom sur le réseau ; la question est donc transmise aux serveurs DNS de la machine, qui mettent quelques secondes à répondre qu'ils ne connaissent pas `api`, et nginx abandonne. Ces deux pannes ont la même cause : l'ordre de démarrage compte, et « démarré » ne veut pas dire « prêt ». Le chapitre 7 montre comment Compose les règle ; Kubernetes les règle autrement, avec des sondes de santé (chapitre 22).

Remettons tout dans l'ordre :

```bash
docker rm web
docker start api
docker run -d --name web --network colis -p 8080:80 colis-web:1.0
docker ps --filter network=colis --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}'
```

```sortie
NAMES      IMAGE                PORTS
web        colis-web:1.0        0.0.0.0:8080->80/tcp, [::]:8080->80/tcp
worker     colis:1.0            8000/tcp
api        colis:1.0            8000/tcp
redis      redis:8.8-alpine     6379/tcp
postgres   postgres:18-alpine   5432/tcp
```

<Figure svg={colisReseau} num="6.2" alt="Sur le réseau colis, le navigateur atteint web par le port publié 8080 ; web joint api par http://api:8000 ; api joint postgres et redis par leurs noms ; worker lit redis et écrit dans postgres ; postgres garde ses données dans le volume colis-donnees. Seul web est joignable depuis la machine.">
Colis assemblé à la main. Seul <code>web</code> publie un port ; tous les autres ne sont joignables que depuis le réseau <code>colis</code>, par leur nom.
</Figure>

Un seul port publié, celui de `web`. Les autres affichent le port que leur image déclare (`EXPOSE`), sans flèche : ils ne sont joignables que de l'intérieur du réseau. C'est exactement ce qu'on veut, et on peut le vérifier :

```bash
curl -s localhost:8080/api/pret
curl -s localhost:8080/api/sante
curl -s -m 2 localhost:8000/sante; echo "accès direct à l'api : code=$?"
```

```sortie
{"stockage":"postgres","file":"redis","pret":true}
{"statut":"ok","version":"1.0.0","hote":"bde0c59e5156"}
accès direct à l'api : code=7
```

Les requêtes passent par nginx. L'API indique maintenant qu'elle stocke ses colis dans PostgreSQL et délègue les calculs à la file Redis. L'API elle-même n'est pas joignable directement : le code 7 de `curl` signifie « connexion impossible ».

Enregistrons trois colis, par nginx, puis regardons le worker travailler :

```bash
for ville in Brest Lyon Nice; do
  curl -s -o /dev/null -w '%{http_code} ' -X POST localhost:8080/api/colis \
       -H 'Content-Type: application/json' \
       -d "{\"destinataire\": \"Ada Lovelace\", \"depart\": \"Paris\", \"arrivee\": \"$ville\", \"poids_kg\": 2.5}"
done; echo
sleep 3
docker logs worker
```

```sortie
201 201 201
worker 3356a4b84ab6 prêt (stockage : postgres)
colis 1 : Paris -> Brest, 3 jours, livraison estimée le 2026-09-28
colis 2 : Paris -> Lyon, 3 jours, livraison estimée le 2026-09-28
colis 3 : Paris -> Nice, 3 jours, livraison estimée le 2026-09-28
```

Toute la chaîne fonctionne : nginx a relayé les trois requêtes à l'API, qui a enregistré les colis dans PostgreSQL et déposé leurs numéros dans Redis ; le worker les a pris dans la file, a calculé leurs dates de livraison et les a enregistrées. Ouvrez http://localhost:8080 dans votre navigateur : la page affiche l'état de l'API, un formulaire pour enregistrer des colis, et la liste des colis, rafraîchie toutes les deux secondes. Un nouveau colis y apparaît d'abord « enregistré », puis « estimé » une demi-seconde plus tard, quand le worker a fait son travail.

Enfin, voyons comment chacun trouve les autres, depuis le conteneur `web` :

```bash
docker exec web getent hosts api postgres redis worker
```

```sortie
172.19.0.4        api  api
172.19.0.2        postgres  postgres
172.19.0.3        redis  redis
172.19.0.5        worker  worker
```

Cinq commandes `docker run` avec leurs options, un ordre à respecter, des attentes à glisser entre les étapes : assembler une application à la main est instructif une fois, pénible ensuite, et fragile. C'est exactement ce que le chapitre 7 va automatiser.

## Exercices

:::exercice[Exercice 1 : une façade et un réseau interne]

Créez deux réseaux, `front` et `back`. Lancez un nginx nommé `app` sur `back` seulement, un conteneur `proxy` branché sur les deux réseaux, et un conteneur `dehors` sur `front` seulement. Qui peut joindre `app` ? Pourquoi est-ce une bonne organisation pour Colis ?

:::

<details>
<summary>Corrigé</summary>

```bash
docker network create front && docker network create back
docker run -d --name app --network back nginx:1.30-alpine
docker run -d --name proxy --network front alpine:3.24 sleep 600
docker network connect back proxy
docker run -d --name dehors --network front alpine:3.24 sleep 600
docker exec proxy wget -qO- -T 2 http://app | grep -o '<title>.*</title>'
docker exec dehors wget -qO- -T 2 http://app
```

```sortie
<title>Welcome to nginx!</title>
wget: bad address 'app'
```

`proxy` joint `app` ; `dehors` ne connaît même pas son nom. `docker inspect proxy` montre deux adresses, une par réseau. Pour Colis, on placerait `postgres`, `redis`, `api` et `worker` sur un réseau interne, et `web` à cheval sur les deux : un conteneur compromis sur le réseau de façade n'aurait aucun accès direct à la base. Kubernetes obtient le même résultat autrement, avec les NetworkPolicy du chapitre 41. Faites le ménage avec `docker rm -f app proxy dehors && docker network rm front back`.

</details>

:::exercice[Exercice 2 : plusieurs noms pour un conteneur]

Lancez un Redis sur le réseau `colis` sous le nom de conteneur `cache-1`, mais joignable aussi sous les noms `cache` et `file`. Vérifiez depuis `web`. Dans quel cas est-ce utile ?

:::

<details>
<summary>Corrigé</summary>

```bash
docker run -d --name cache-1 --network colis --network-alias cache --network-alias file redis:8.8-alpine
docker exec web getent hosts cache file cache-1
```

Les trois noms désignent la même adresse. Un alias permet de remplacer un conteneur par un autre sans changer la configuration de ses clients : ils continuent de joindre `cache`, quel que soit le conteneur qui porte ce nom. Si deux conteneurs portent le même alias, le DNS intégré renvoie les deux adresses, ce qui répartit grossièrement les connexions : c'est l'idée que les Services de Kubernetes rendront robuste (chapitre 20). Supprimez-le avec `docker rm -f cache-1`.

</details>

:::exercice[Exercice 3 : retrouver la paire veth]

Pour le conteneur `api` de Colis, trouvez l'interface `veth` correspondante sur votre machine, et le pont sur lequel elle est branchée.

:::

<details>
<summary>Corrigé</summary>

```bash
I=$(docker exec api cat /sys/class/net/eth0/iflink)
ip -o link | grep "^$I:"
```

Le fichier `iflink` de l'interface `eth0` du conteneur contient l'index de son autre extrémité. La ligne trouvée sur la machine se termine par `master br-...` : c'est le pont du réseau `colis`, dont le nom reprend le début de l'identifiant du réseau (`docker network ls`). L'image `colis:1.0` n'a pas la commande `ip`, mais `cat` suffit.

</details>

:::exercice[Exercice 4 : partager un namespace réseau]

Lancez un conteneur Alpine qui partage le namespace réseau du conteneur `api`, avec `--network container:api`, et interrogez l'API à l'adresse `127.0.0.1:8000`. Comparez son nom de machine et son adresse avec ceux de l'API. Essayez aussi avec `localhost:8000` : que se passe-t-il ?

:::

<details>
<summary>Corrigé</summary>

```bash
docker run --rm --network container:api alpine:3.24 sh -c 'wget -qO- 127.0.0.1:8000/sante; echo; hostname; ip -4 addr show eth0 | grep inet'
```

```sortie
{"statut":"ok","version":"1.0.0","hote":"bde0c59e5156"}
bde0c59e5156
    inet 172.19.0.4/16 brd 172.19.255.255 scope global eth0
```

Le conteneur Alpine n'a pas de réseau à lui : il utilise celui de l'API, avec son interface, son adresse (`172.19.0.4`) et même son nom de machine. Il joint donc l'API par l'interface locale, comme si les deux programmes tournaient sur la même machine. C'est exactement ce que fait Kubernetes avec les conteneurs d'un même Pod, qui partagent un namespace réseau (chapitre 17).

Avec `localhost:8000`, `wget` échoue avec `Connection refused` : dans Alpine, `localhost` désigne d'abord l'adresse IPv6 `::1`, et Uvicorn n'écoute qu'en IPv4. Un piège courant avec les images Alpine ; en cas de doute, écrivez `127.0.0.1`.

</details>

## Accès aux interfaces

Colis tourne maintenant en entier. Laissez-le en marche si vous voulez l'explorer avant le chapitre suivant :

| Interface | Adresse |
|---|---|
| Site de Colis | http://localhost:8080 |
| API, par nginx | http://localhost:8080/api/sante, http://localhost:8080/api/colis |

## Nettoyer

Le chapitre 7 reconstruira Colis avec Compose, à partir de zéro. Supprimez les conteneurs, le réseau et le volume de ce chapitre, par leur nom :

```bash
docker rm -f web worker api redis postgres
docker network rm colis
docker volume rm colis-donnees
```

Gardez les images `colis:1.0` et `colis-web:1.0`.

[^docker-firewall]: Docker, « Packet filtering and firewalls », sections *Docker and ufw* et *Setting the default bind address for containers*. [docs.docker.com/engine/network/packet-filtering-firewalls](https://docs.docker.com/engine/network/packet-filtering-firewalls/)
