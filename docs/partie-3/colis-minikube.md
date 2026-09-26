---
title: "TP : Colis sur minikube"
sidebar_label: "24. TP : Colis sur minikube"
description: "Déployer l'application Colis complète sur minikube : traduire le fichier Compose en objets Kubernetes, charger les images dans le nœud puis les tirer du registre local, mettre à jour sans coupure, et voir ce qui casse quand la base disparaît."
partie: 3
chapitre: '24'
---

import colisK8s from '@site/src/figures/colis-k8s.svg';
import cheminImages from '@site/src/figures/chemin-images.svg';

Colis tourne depuis la partie I avec une seule commande, `docker compose up -d`, sur une seule machine. Si cette machine s'arrête, Colis s'arrête avec elle. Si l'API plante trois fois de suite, `restart: unless-stopped` la relance, mais personne ne vérifie qu'elle répond. Et pour passer à une nouvelle version, on coupe et on relance.

Ce TP rassemble tout ce que la partie a montré, objet par objet, pour installer Colis sur minikube : un namespace, une ConfigMap et un Secret, un Deployment et un Service par composant, des sondes, des ressources, un LoadBalancer pour le site. Il se déroule en deux temps. D'abord, les images sont copiées à la main dans le nœud, ce qui suffit pour un premier essai. Ensuite, le nœud les tire du registre local du chapitre 14, comme le ferait un vrai cluster. Entre les deux, on met l'application à l'épreuve : une mise à jour sous charge, puis la disparition de la base de données.

Les manifestes sont dans [l'archive colis-k8s](pathname:///kits/colis-k8s.tar.gz). Il vous faut :

- le cluster minikube avec l'addon metallb (chapitre 20) ;
- le registre `registre` du chapitre 14, démarré (`docker start registre`), qui contient `colis/api:2.0` depuis le défi II ;
- les images `colis:2.0` (défi II) et `colis-web:1.0` (chapitre 6) dans le Docker de votre poste.

Le ménage du défi II a supprimé `colis:2.0`. Reconstruisez-la depuis votre dossier `colis`, avec le `Dockerfile` et le `.dockerignore` du défi II (les vôtres, ou ceux du corrigé, dans `kits/defi-2/corrige` du dépôt du cours) :

```bash
docker build -t colis:2.0 app
docker image ls --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep -E '^colis(-web)?:'
```

```sortie
colis:2.0 90MB
colis:1.0 164MB
colis-web:1.0 62.4MB
```

## De Compose à Kubernetes

Le fichier `compose.yaml` de la partie I décrit six services. Aucune de ses lignes ne se recopie telle quelle, mais chacune a un équivalent, parfois plus riche, parfois absent :

| Dans `compose.yaml` | Sur Kubernetes | Chapitre |
|---|---|---|
| un service (`api`, `web`...) | un Deployment pour les Pods, un Service pour le nom et l'adresse | 19, 20 |
| `environment` | une ConfigMap, lue par `envFrom` | 21 |
| le mot de passe du fichier `.env` | un Secret, lu par `secretKeyRef` | 21 |
| `healthcheck` | des sondes : startup, liveness, readiness | 22 |
| `depends_on: condition: service_healthy` | rien : chaque composant doit supporter l'absence des autres | 24 |
| `restart: unless-stopped` | `restartPolicy: Always`, la valeur par défaut d'un Pod | 17 |
| `ports: "8080:80"` | un Service de type LoadBalancer, servi par MetalLB | 20 |
| le volume nommé `donnees` | provisoirement un `emptyDir`, qui disparaît avec le Pod | 25, 26 |
| `profiles: ["outils"]` et `docker compose run --rm purge` | un Pod avec `restartPolicy: Never`, lancé à la main | 27 |
| (rien) | des requests et des limits pour chaque conteneur | 23 |

Deux lignes de ce tableau méritent qu'on s'y arrête. La première est `depends_on`. Compose sait démarrer les composants dans l'ordre et attendre que la base soit prête avant de lancer l'API. Kubernetes n'a rien de tel : tous les Pods partent en même temps, et c'est à chacun de se débrouiller si sa dépendance n'est pas encore là. Nous allons voir ce que cela donne. La seconde est le volume : sans stockage persistant, que la partie IV présentera, les données de PostgreSQL vivent dans le Pod et meurent avec lui. C'est un choix assumé pour ce TP, et une panne que nous provoquerons exprès.

<Figure svg={colisK8s} num="24.1" alt="Le namespace colis. Le navigateur atteint 192.168.49.100, l'adresse du Service web de type LoadBalancer servie par MetalLB, qui mène au Deployment web, deux Pods nginx. Ceux-ci relaient /api/ vers le Service api (ClusterIP, port 8000), devant le Deployment api, deux Pods avec trois sondes. L'API et le Deployment worker, un Pod, parlent au Service redis (port 6379, devant le Deployment redis) et au Service postgres (port 5432, devant le Deployment postgres, avec un emptyDir et la stratégie Recreate). Un Pod purge, lancé à la main, parle aussi à postgres. La ConfigMap colis-config et le Secret colis-db alimentent l'API et le worker.">
Colis dans le namespace <code>colis</code> : un Deployment par composant, un Service devant chacun de ceux qu'on appelle, la configuration dans une ConfigMap et un Secret. Le worker n'a pas de Service, personne ne l'appelle.
</Figure>

Le worker n'a pas de Service : personne ne l'appelle, c'est lui qui va chercher son travail dans la file Redis. Un Service ne sert qu'à recevoir des connexions ; un composant qui n'en reçoit pas n'en a pas besoin.

## Les manifestes

L'archive contient un fichier par composant, numérotés pour être lus dans l'ordre :

```sortie
00-namespace.yaml   10-config.yaml   20-postgres.yaml   21-redis.yaml
30-api.yaml         31-worker.yaml   40-web.yaml        50-purge.yaml
hosts.toml          metallb-plage.yaml
```

Les deux derniers ne sont pas des manifestes de Colis. `metallb-plage.yaml` est la plage d'adresses de MetalLB du chapitre 20, rangée là pour qu'un `kubectl apply -f .` la remette en place. `hosts.toml` servira à la seconde phase.

Tous les objets portent l'étiquette `app.kubernetes.io/part-of: colis`, et chaque composant `app.kubernetes.io/name` avec son nom. Ce sont les étiquettes recommandées par Kubernetes[^etiquettes], et c'est la seconde qui sert de sélecteur aux Deployments et aux Services.

### La configuration et le mot de passe

La ConfigMap `colis-config` porte ce qui n'est pas secret :

```yaml
data:
  COLIS_REDIS: redis://redis:6379/0
  COLIS_VERSION: "2.0.0"
  COLIS_PURGE_JOURS: "30"
```

Le mot de passe de PostgreSQL, lui, n'est dans aucun fichier. Le chapitre 21 a montré qu'un Secret créé par `kubectl apply` garde une copie de son contenu dans l'annotation `last-applied-configuration`. On le crée donc par une commande, avec un mot de passe tiré au hasard que personne n'a besoin de connaître :

```bash
kubectl -n colis create secret generic colis-db \
  --from-literal=POSTGRES_PASSWORD=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')
```

L'application attend une adresse de connexion complète, `COLIS_DB`, qui contient ce mot de passe. Kubernetes sait composer une variable à partir d'une autre, déclarée avant elle dans la liste `env`, par la syntaxe `$(NOM)`[^dependantes] :

```yaml
        env:
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: colis-db
              key: POSTGRES_PASSWORD
        - name: COLIS_DB
          value: postgresql://colis:$(POSTGRES_PASSWORD)@postgres:5432/colis
```

L'ordre compte : si `COLIS_DB` venait avant `POSTGRES_PASSWORD`, le texte `$(POSTGRES_PASSWORD)` resterait tel quel, sans erreur, et l'application tenterait de se connecter avec ce mot de passe littéral.

### PostgreSQL et Redis

PostgreSQL tourne dans un Deployment à une réplique, avec deux réglages particuliers. La stratégie `Recreate` (chapitre 19) : lors d'une mise à jour, l'ancien Pod est arrêté avant que le nouveau démarre, car deux serveurs PostgreSQL ne doivent jamais écrire dans les mêmes fichiers. Et une sonde readiness qui exécute `pg_isready` dans le conteneur, l'équivalent du `healthcheck` de Compose :

```yaml
        readinessProbe:
          exec:
            command: ["pg_isready", "-U", "colis", "-d", "colis"]
          periodSeconds: 5
```

Le Deployment est une solution provisoire. Une base de données a besoin d'une identité stable et d'un disque qui lui survive, ce qu'apportent le StatefulSet et les volumes persistants de la partie IV. Redis, qui ne sert ici que de file d'attente, est un Deployment ordinaire.

### L'API

C'est le manifeste le plus fourni, parce qu'il applique ce que les chapitres 21 à 23 ont montré :

```yaml
        startupProbe:
          httpGet:
            path: /sante
            port: http
          periodSeconds: 2
          failureThreshold: 15
        livenessProbe:
          httpGet:
            path: /sante
            port: http
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /pret
            port: http
          periodSeconds: 5
        lifecycle:
          preStop:
            sleep:
              seconds: 3
        resources:
          requests:
            cpu: 100m
            memory: 192Mi
          limits:
            memory: 256Mi
```

Colis offre deux adresses de santé depuis la partie I. `/sante` répond dès que le processus tourne ; `/pret` vérifie en plus que PostgreSQL et Redis répondent. La liveness utilise la première : on ne redémarre pas l'API parce que la base est indisponible, car cela ne réparerait rien. La readiness utilise la seconde : une API sans base ne doit pas recevoir de requêtes. La startup laisse 30 secondes au démarrage. Le `preStop` de 3 secondes laisse aux règles de kube-proxy le temps d'oublier le Pod avant qu'il reçoive SIGTERM (chapitre 22). Les ressources sont celles de l'exercice 3 du chapitre 23.

### Le site et la purge

Le Deployment `web` sert la page et relaie `/api/` vers `http://api:8000/`, comme sous Compose. Le nom `api` est celui du Service, que CoreDNS résout dans le namespace du Pod (chapitre 20). La configuration nginx le signale : nginx résout ce nom une fois, au démarrage. Sous Compose, c'était une fragilité, car l'adresse d'un conteneur change quand on le recrée. Ici, c'est sans conséquence : l'adresse d'un Service ne change pas tant que le Service existe, quels que soient les Pods derrière. Le Service `web` est de type LoadBalancer.

La purge est un Pod nu, avec `restartPolicy: Never` : elle s'exécute une fois et s'arrête. Le chapitre 27 la confiera à un CronJob.

## Première phase : charger les images dans le nœud

Le nœud minikube a son propre containerd, qui ne voit pas les images du Docker de votre poste. La manière la plus directe de les lui donner est de les copier[^pousser] :

```bash
minikube image load colis:2.0 colis-web:1.0
minikube ssh -- sudo crictl images | grep colis
```

```sortie
docker.io/library/colis-web                     1.0                  9f5f8a1cbfe67       29MB
docker.io/library/colis                         2.0                  1a4851191b112       34.5MB
```

La copie prend une dizaine de secondes. containerd range les images sous leur nom complet : `colis:2.0` devient `docker.io/library/colis:2.0`, comme Docker le ferait. Les manifestes demandent `imagePullPolicy: IfNotPresent` : le kubelet utilise l'image si elle est déjà dans le nœud, et ne tente de la tirer que sinon. C'est déjà la valeur par défaut pour une étiquette autre que `latest`[^images] ; l'écrire rend le manifeste explicite. Avec `Always`, le kubelet interrogerait Docker Hub, qui ne connaît pas `library/colis`, et le Pod ne démarrerait pas.

## Déployer

Le namespace d'abord, puis le Secret, puis tout le reste :

```bash
kubectl apply -f 00-namespace.yaml
kubectl -n colis create secret generic colis-db \
  --from-literal=POSTGRES_PASSWORD=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')
kubectl apply -f .
kubectl -n colis wait --for=condition=Available deployment --all --timeout=300s
kubectl -n colis get pods
```

```sortie
deployment.apps/api condition met
deployment.apps/postgres condition met
deployment.apps/redis condition met
deployment.apps/web condition met
deployment.apps/worker condition met
NAME                        READY   STATUS    RESTARTS      AGE
api-78d48f5786-cwn9t        1/1     Running   2 (38s ago)   43s
api-78d48f5786-gkqng        1/1     Running   3 (25s ago)   43s
postgres-7847c54c4d-k82wh   1/1     Running   0             43s
purge                       0/1     Error     0             43s
redis-578785659c-ltcbn      1/1     Running   0             43s
web-7777496c95-bvtml        1/1     Running   0             43s
web-7777496c95-h2z85        1/1     Running   0             43s
worker-6bdff94978-qmg47     1/1     Running   2 (39s ago)   43s
```

`kubectl apply -f .` a relu `00-namespace.yaml` (`unchanged`) et appliqué au passage la plage de MetalLB. Tout est disponible en moins d'une minute : entre 20 et 50 secondes selon les essais, et davantage la première fois, quand le nœud doit tirer `postgres:18-alpine` et `redis:8.8-alpine` de Docker Hub. Mais la colonne `RESTARTS` n'est pas à zéro, et la purge est en erreur.

### Ce qui s'est passé au démarrage

Les journaux du conteneur précédent de l'API (`--previous`, chapitre 17) disent pourquoi il est mort :

```bash
kubectl -n colis logs deploy/api --previous | tail -2
kubectl -n colis logs purge | tail -1
```

```sortie
psycopg.OperationalError: connection failed: connection to server at "10.108.157.234", port 5432 failed: Connection refused
	Is the server running on that host and accepting TCP/IP connections?
	Is the server running on that host and accepting TCP/IP connections?
```

L'API, le worker et la purge ont démarré en même temps que PostgreSQL. Au moment où ils ont tenté de se connecter, le nom `postgres` se résolvait bien (le Service existait), mais aucun Pod prêt ne se trouvait derrière, et la connexion a été refusée. Les événements de PostgreSQL confirment qu'il n'était pas encore prêt :

```bash
kubectl -n colis get events --field-selector involvedObject.kind=Pod --sort-by=.lastTimestamp | grep postgres | grep -E 'Pulled|Unhealthy'
```

```sortie
43s         Normal    Pulled      pod/postgres-7847c54c4d-k82wh   Container image "postgres:18-alpine" already present on machine and can be accessed by the pod
42s         Warning   Unhealthy   pod/postgres-7847c54c4d-k82wh   Readiness probe failed: /var/run/postgresql:5432 - no response
```

L'API et le worker s'en sont remis tout seuls : leur conteneur est mort, le kubelet l'a relancé après un délai croissant (10 secondes, puis 20 : c'est le `CrashLoopBackOff` du chapitre 17), et au deuxième ou troisième essai, PostgreSQL était prêt. La purge, elle, a `restartPolicy: Never` : son échec est définitif, et il faut la relancer.

C'est la manière de faire de Kubernetes, et elle est voulue. Un orchestrateur qui démarre les composants dans l'ordre ne règle que le premier démarrage ; il ne dit rien de ce qui arrive quand la base redémarre en pleine journée. Kubernetes suppose que chaque composant supporte l'absence de ses dépendances, à tout moment, et relance ceux qui n'y arrivent pas. Les redémarrages observés sont le prix d'une application qui ne tolère pas cette absence au démarrage. L'exercice 1 montre comment les éviter.

## Parcourir l'application

MetalLB a donné au Service `web` la première adresse de sa plage :

```bash
IP=$(kubectl -n colis get service web -o jsonpath='{.status.loadBalancer.ingress[0].ip}'); echo $IP
curl -s http://$IP/ | grep -o '<title>.*</title>'
curl -s http://$IP/api/pret; echo
```

```sortie
192.168.49.100
<title>Colis</title>
{"stockage":"postgres","file":"redis","pret":true}
```

Ouvrez [http://192.168.49.100/](http://192.168.49.100/) dans votre navigateur : c'est le site de la partie I. Enregistrez un colis, par l'interface ou par l'API, puis relisez-le quelques secondes plus tard :

```bash
curl -s -X POST http://$IP/api/colis -H 'Content-Type: application/json' \
  -d '{"destinataire":"Ada Lovelace","depart":"Paris","arrivee":"Brest","poids_kg":2.5}'; echo
sleep 4; curl -s http://$IP/api/colis/1; echo
kubectl -n colis logs deploy/worker --tail=2
```

```sortie
{"id":1,"destinataire":"Ada Lovelace","depart":"Paris","arrivee":"Brest","poids_kg":2.5,"statut":"enregistré","cree_le":"2026-09-26T07:10:02.987357Z","livraison_estimee":null,"livre_le":null}
{"id":1,"destinataire":"Ada Lovelace","depart":"Paris","arrivee":"Brest","poids_kg":2.5,"statut":"estimé","cree_le":"2026-09-26T07:10:02.987357Z","livraison_estimee":"2026-09-29","livre_le":null}
worker worker-6bdff94978-qmg47 prêt (stockage : postgres)
colis 1 : Paris -> Brest, 3 jours, livraison estimée le 2026-09-29
```

Toute la chaîne fonctionne : le navigateur ou `curl` atteint MetalLB, puis un Pod nginx, puis le Service `api` et l'un des deux Pods de l'API, qui écrit dans PostgreSQL et dépose une tâche dans Redis ; le worker la prend et calcule l'estimation. Reste la purge. Un Pod terminé ne se relance pas, on le supprime et on le recrée :

```bash
kubectl -n colis delete pod purge
kubectl apply -f 50-purge.yaml
kubectl -n colis wait --for=jsonpath='{.status.phase}'=Succeeded pod/purge --timeout=90s
kubectl -n colis logs purge
```

```sortie
pod "purge" deleted from colis namespace
pod/purge created
pod/purge condition met
purge : 0 colis livrés depuis plus de 30 jours supprimés
```

## Mettre à jour sans coupure

Sous Compose, changer de version de l'API voulait dire l'arrêter. Ici, envoyons des requêtes pendant 45 secondes, dix par seconde environ, et redémarrons l'API au milieu. `kubectl rollout restart` produit exactement ce que ferait une nouvelle version : il modifie le modèle de Pod (une annotation avec l'heure), et le Deployment remplace les Pods un par un. Dans un premier terminal :

```bash
IP=192.168.49.100; ok=0; ko=0; fin=$(( $(date +%s) + 45 ))
while [ $(date +%s) -lt $fin ]; do
  if [ "$(curl -s -o /dev/null -m 2 -w '%{http_code}' http://$IP/api/sante)" = 200 ]
  then ok=$((ok+1)); else ko=$((ko+1)); fi
  sleep 0.1
done; echo "requêtes réussies : $ok, échouées : $ko"
```

Dans un second, pendant que la boucle tourne :

```bash
kubectl -n colis rollout restart deployment/api
kubectl -n colis rollout status deployment/api
```

```sortie
deployment.apps/api restarted
Waiting for deployment "api" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "api" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "api" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "api" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "api" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "api" rollout to finish: 1 old replicas are pending termination...
deployment "api" successfully rolled out
```

Et dans le premier, à la fin :

```sortie
requêtes réussies : 352, échouées : 0
```

Aucune requête perdue, sur plusieurs essais (350, 352 et 353 réussites). Trois mécanismes des chapitres précédents y contribuent. La stratégie par défaut, avec 2 répliques, autorise 1 Pod en plus (`maxSurge` de 25 % arrondi au-dessus) et 0 Pod indisponible (`maxUnavailable` de 25 % arrondi au-dessous) : un nouveau Pod est créé avant qu'un ancien soit arrêté. La readiness sur `/pret` empêche le nouveau Pod de recevoir des requêtes avant d'avoir joint sa base. Et le `preStop` retarde l'arrêt de l'ancien, le temps que kube-proxy le retire des règles. Retirez le `preStop`, et quelques requêtes échouent à chaque mise à jour (chapitre 22).

## Perdre la base

Supprimons maintenant le Pod de PostgreSQL, comme si son nœud était tombé. Le Deployment en recrée un aussitôt :

```bash
curl -s http://$IP/api/colis | head -c 80; echo
kubectl -n colis delete pod -l app.kubernetes.io/name=postgres
kubectl -n colis rollout status deployment/postgres
sleep 20
kubectl -n colis get pods -l app.kubernetes.io/name=api
curl -s -o /dev/null -w 'site -> %{http_code}\n' http://$IP/api/colis
```

```sortie
[{"id":1,"destinataire":"Ada Lovelace","depart":"Paris","arrivee":"Brest","poi
pod "postgres-7847c54c4d-k82wh" deleted from colis namespace
deployment "postgres" successfully rolled out
NAME                   READY   STATUS    RESTARTS   AGE
api-657774dcbd-564tj   0/1     Running   0          68s
api-657774dcbd-vfjjk   0/1     Running   0          64s
site -> 502
```

PostgreSQL est revenu, mais pas l'API : ses deux Pods tournent sans être prêts, et le site répond `502 Bad Gateway`. Ce 502 vient de nginx. Le Service `api` n'a plus aucun Pod prêt, donc plus aucune adresse dans son EndpointSlice ; kube-proxy rejette alors les connexions vers lui (chapitre 20), et nginx signale qu'il n'a pas pu joindre l'application derrière lui.

Demandons à l'API elle-même, depuis l'intérieur de son Pod :

```bash
kubectl -n colis exec deploy/api -- python -c '
import urllib.request, urllib.error
try: print(urllib.request.urlopen("http://127.0.0.1:8000/pret").read().decode())
except urllib.error.HTTPError as e: print(e.code, e.read().decode())'
```

```sortie
503 {"stockage":"postgres","file":"redis","pret":false,"erreur":"the connection is closed"}
```

Le code de Colis explique ce message. Le stockage PostgreSQL ouvre une seule connexion, dans son constructeur, au démarrage de l'API (`colis/stockage.py`) :

```python
        self._connexion = psycopg.connect(dsn, autocommit=True, row_factory=dict_row)
```

Quand le serveur est parti, cette connexion s'est fermée, et aucune ligne du code n'en ouvre une nouvelle. L'API restera dans cet état tant que son processus vivra. Kubernetes a fait ce qu'on lui a demandé. La readiness a retiré les Pods du Service, ce qui évite d'y envoyer des requêtes vouées à l'échec. La liveness, sur `/sante`, les laisse vivre, puisque le processus répond.

On pourrait être tenté de faire pointer la liveness sur `/pret`, pour que le kubelet redémarre l'API quand elle perd sa base. Ce serait une erreur, contre laquelle la documentation met en garde[^sondes] : à la prochaine panne de PostgreSQL, tous les Pods de l'API redémarreraient en boucle, sans que cela répare quoi que ce soit, et une panne d'un composant deviendrait une panne de tous ceux qui en dépendent. Le vrai remède est dans l'application, qui devrait rouvrir sa connexion, par exemple avec un *pool* de connexions qui vérifie chaque connexion avant de s'en servir. En attendant, on redémarre l'API et le worker à la main :

```bash
kubectl -n colis rollout restart deployment/api deployment/worker
kubectl -n colis rollout status deployment/api
curl -s http://$IP/api/colis; echo
```

```sortie
deployment.apps/api restarted
deployment.apps/worker restarted
deployment "api" successfully rolled out
[]
```

L'application répond à nouveau, et la liste des colis est vide. Le colis d'Ada Lovelace était dans le volume `emptyDir` du Pod supprimé, et l'`emptyDir` disparaît avec son Pod (chapitre 17). Le nouveau PostgreSQL est parti d'une base neuve. Sous Compose, le volume nommé `donnees` avait survécu à la suppression du conteneur ; c'est ce qu'il faudra retrouver sur Kubernetes, avec les volumes persistants de la partie IV.

## Seconde phase : tirer les images du registre

`minikube image load` a dépanné, mais ce n'est pas ainsi que les images arrivent sur un vrai cluster. Il faudrait refaire la copie sur chaque nœud, à chaque version, et un nœud ajouté au cluster n'aurait rien. Sur un cluster réel, le kubelet de chaque nœud tire les images d'un registre, au moment où il en a besoin. Le registre local du chapitre 14 va jouer ce rôle.

### Joindre le registre depuis le nœud

Le registre écoute sur `localhost:5001`. Mais pour containerd, qui tourne dans le nœud minikube, `localhost` désigne le nœud lui-même, pas votre poste. minikube ajoute au nœud un nom qui désigne le poste[^hote] :

```bash
minikube ssh -- grep host.minikube.internal /etc/hosts
```

```sortie
192.168.49.1	host.minikube.internal
```

`192.168.49.1` est l'adresse de votre poste sur le réseau Docker de minikube, et le port 5001 du registre y est ouvert. Il reste un obstacle. Le registre parle HTTP, sans chiffrement, et containerd, par défaut, exige HTTPS. Docker fait une exception pour `localhost`, pas containerd pour `host.minikube.internal`. Sans réglage, un Pod qui demande une image de ce registre échoue :

```sortie
NAME         READY   STATUS         RESTARTS   AGE
essai-http   0/1     ErrImagePull   0          8s
Failed to pull image "host.minikube.internal:5001/cours/tampon:1.0.0": failed to pull and unpack image "host.minikube.internal:5001/cours/tampon:1.0.0": failed to resolve reference "host.minikube.internal:5001/cours/tampon:1.0.0": failed to do request: Head "https://host.minikube.internal:5001/v2/cours/tampon/manifests/1.0.0": http: server gave HTTP response to HTTPS client
```

containerd lit, pour chaque registre, un fichier `hosts.toml` rangé dans `/etc/containerd/certs.d/<registre>/`, et le relit à chaque tirage, sans redémarrage[^hosts]. Celui de l'archive déclare que ce registre se joint en HTTP, pour lire des images :

```toml
server = "http://host.minikube.internal:5001"

[host."http://host.minikube.internal:5001"]
  capabilities = ["pull", "resolve"]
```

`minikube cp` le copie dans le nœud, en créant le dossier :

```bash
minikube cp hosts.toml /etc/containerd/certs.d/host.minikube.internal:5001/hosts.toml
```

Le fichier est écrit sur le disque du nœud, et survit à `minikube stop` et `minikube start`. Il disparaît avec `minikube delete` ; on peut alors passer l'option `--insecure-registry` à la création du cluster, qui produit le même effet[^registres]. minikube propose aussi un addon `registry`, un registre qui tourne dans le cluster lui-même[^pousser] ; nous gardons celui du chapitre 14, qui contient déjà l'image signée du défi II.

<Figure svg={cheminImages} num="24.2" alt="Deux chemins de l'image, du Docker du poste (colis:2.0, colis-web:1.0) vers le containerd du nœud minikube. Premier chemin : minikube image load, direct, une dizaine de secondes. Second chemin : docker push vers le registre local localhost:5001, puis le kubelet du nœud tire l'image de host.minikube.internal:5001 en quelques centaines de millisecondes. host.minikube.internal désigne le poste vu du nœud, et le HTTP est autorisé par /etc/containerd/certs.d/.../hosts.toml.">
Deux façons d'amener une image dans le nœud : la copie directe par <code>minikube image load</code>, ou le tirage par le kubelet depuis le registre du poste, comme sur un vrai cluster. Temps mesurés sur le cluster du cours.
</Figure>

### Publier et changer les manifestes

L'image de l'API est déjà dans le registre, sous le nom `colis/api:2.0`, en deux architectures et signée. Celle du site n'y est pas encore :

```bash
docker tag colis-web:1.0 localhost:5001/colis/web:1.0
docker push -q localhost:5001/colis/web:1.0
curl -s http://localhost:5001/v2/_catalog; echo
```

```sortie
localhost:5001/colis/web:1.0
{"repositories":["colis/api","colis/web","cours/tampon"]}
```

Dans les manifestes, les images changent de nom. Le poste pousse vers `localhost:5001`, le nœud tire de `host.minikube.internal:5001` : c'est le même registre, vu de deux endroits.

```bash
sed -i 's|image: colis:2.0|image: host.minikube.internal:5001/colis/api:2.0|; s|image: colis-web:1.0|image: host.minikube.internal:5001/colis/web:1.0|' *.yaml
grep -h 'image:' *.yaml | sort | uniq -c
```

```sortie
      2         image: host.minikube.internal:5001/colis/api:2.0
      1     image: host.minikube.internal:5001/colis/api:2.0
      1         image: host.minikube.internal:5001/colis/web:1.0
      1         image: postgres:18-alpine
      1         image: redis:8.8-alpine
```

Pour être sûr que le nœud tire vraiment les images, retirons celles qu'on y avait chargées, puis appliquons :

```bash
minikube image rm colis:2.0 colis-web:1.0
kubectl -n colis delete pod purge
kubectl apply -f .
kubectl -n colis rollout status deployment/web
kubectl -n colis get events --field-selector reason=Pulled --sort-by=.lastTimestamp | grep 'Successfully pulled' | tail -3
curl -s http://$IP/api/pret; echo
```

```sortie
7s          Normal   Pulled   pod/web-599d986bdf-hrjvs        Successfully pulled image "host.minikube.internal:5001/colis/web:1.0" in 213ms (824ms including waiting). Image size: 26092250 bytes.
7s          Normal   Pulled   pod/purge                       Successfully pulled image "host.minikube.internal:5001/colis/api:2.0" in 151ms (942ms including waiting). Image size: 30208504 bytes.
7s          Normal   Pulled   pod/worker-799f8788b8-6qg6k     Successfully pulled image "host.minikube.internal:5001/colis/api:2.0" in 109ms (791ms including waiting). Image size: 30208504 bytes.
{"stockage":"postgres","file":"redis","pret":true}
```

`apply` n'a modifié que les objets dont l'image a changé (`configured`), et chaque Deployment concerné a fait une mise à jour progressive. Le kubelet a tiré les images en 100 à 900 millisecondes selon les essais : le registre est sur la même machine. La taille annoncée, 30 Mo pour l'API, est celle des couches compressées de la variante `linux/amd64`, la seule des deux architectures que le nœud télécharge.

:::panne[ErrImagePull sur une image pourtant présente dans le nœud]

Revenez à la première phase après la seconde, par exemple pour refaire le TP : `minikube image load colis-web:1.0`, puis un Pod qui demande `colis-web:1.0`. L'image est bien dans le nœud, et pourtant :

```sortie
NAME        READY   STATUS         RESTARTS   AGE
essai-web   0/1     ErrImagePull   0          8s
Failed to pull image "colis-web:1.0": failed to pull and unpack image "docker.io/library/colis-web:1.0": failed to resolve reference "docker.io/library/colis-web:1.0": pull access denied, repository does not exist or may require authorization: server message: insufficient_scope: authorization failed
```

Le kubelet a tenté de la tirer de Docker Hub, malgré `IfNotPresent`. La cause est une protection récente du kubelet[^kep2535]. Il garde la trace de chaque image qu'il a tirée, et sous quel nom, dans `/var/lib/kubelet/image_manager/pulled` :

```sortie
{"kind":"ImagePulledRecord","apiVersion":"kubelet.config.k8s.io/v1beta1","lastUpdatedTime":"2026-09-26T06:36:38Z","imageRef":"sha256:9f5f8a1cbfe672006a86bcd9cadc4605bed53f32263c099aa084a8cf8f835ed5","credentialMapping":{"host.minikube.internal:5001/colis/web":{"nodePodsAccessible":true}}}
```

L'image `colis-web:1.0` a exactement le même contenu, donc le même identifiant `9f5f8a...`, que `host.minikube.internal:5001/colis/web:1.0`, tirée à la seconde phase. Pour le kubelet, un Pod demande sous un autre nom une image que seul un tirage depuis le registre a amenée : il vérifie que ce Pod a le droit de l'obtenir en la tirant lui-même, sous le nom demandé, et ce tirage échoue. Sur un cluster partagé, cela empêche un Pod d'utiliser une image privée qu'un autre Pod a tirée avec des identifiants qu'il n'a pas. Les images qui n'ont jamais été tirées, comme celles chargées par `minikube image load` sur un nœud neuf, sont considérées comme préchargées et ne sont pas vérifiées : c'est pourquoi la première phase a fonctionné (réglage `imagePullCredentialsVerificationPolicy: NeverVerifyPreloadedImages`, visible par `kubectl get --raw /api/v1/nodes/minikube/proxy/configz`).

Le remède : donnez à chaque image un seul nom, et gardez-le. Une fois passé au registre, restez-y.

:::

### Survivre à un redémarrage du cluster

Arrêtez le cluster, puis relancez-le :

```bash
minikube stop
minikube start
kubectl apply -f metallb-plage.yaml
kubectl -n colis wait --for=condition=Available deployment --all --timeout=300s
kubectl -n colis get pods
```

```sortie
deployment.apps/api condition met
deployment.apps/postgres condition met
deployment.apps/redis condition met
deployment.apps/web condition met
deployment.apps/worker condition met
NAME                        READY   STATUS      RESTARTS      AGE
api-84969c7499-j97lf        1/1     Running     3 (31s ago)   91s
api-84969c7499-rqcl2        1/1     Running     3 (30s ago)   95s
postgres-7847c54c4d-2qv4g   1/1     Running     1 (60s ago)   3m30s
purge                       0/1     Completed   0             2m2s
redis-578785659c-d86vl      1/1     Running     1 (60s ago)   6m9s
web-684f8657cf-5rhd9        1/1     Running     3 (31s ago)   95s
web-684f8657cf-7nh4f        1/1     Running     3 (32s ago)   94s
worker-7658fc5ffc-5rgmm     1/1     Running     3 (30s ago)   95s
```

Les mêmes Pods sont revenus, avec un compteur de redémarrages augmenté : le kubelet, en redémarrant, a relancé les conteneurs de ses Pods, et l'API, le worker et le site ont de nouveau échoué quelques fois avant que leurs dépendances soient prêtes. Le fichier `hosts.toml` est toujours là, et les images aussi. La seule chose à refaire est la plage de MetalLB, que `minikube start` remet à zéro (chapitre 20) : sans elle, `192.168.49.100` ne répond plus.

## Exercices

:::exercice[Exercice 1 : attendre ses dépendances]

Faites démarrer l'API et le worker sans aucun redémarrage, en ajoutant à leur Pod un init container (chapitre 17) qui attend que PostgreSQL soit prêt. Indice : l'image `postgres:18-alpine` contient `pg_isready`, qui accepte `-h` pour désigner un serveur distant. Supprimez le namespace, redéployez, et comparez la colonne `RESTARTS`.

:::

<details>
<summary>Corrigé</summary>

Dans `30-api.yaml` et `31-worker.yaml`, au même niveau que `containers` :

```yaml
      initContainers:
      - name: attendre-postgres
        image: postgres:18-alpine
        command: ["sh", "-c", "until pg_isready -h postgres -U colis -d colis; do sleep 1; done"]
```

Après `kubectl delete namespace colis`, la création du Secret et `kubectl apply -f .` :

```sortie
disponible en 11 s
NAME                        READY   STATUS    RESTARTS   AGE
api-789d5d5f8d-9xf8s        1/1     Running   0          11s
api-789d5d5f8d-jsbwx        1/1     Running   0          11s
postgres-7847c54c4d-szfgc   1/1     Running   0          12s
purge                       0/1     Error     0          11s
redis-578785659c-48lq8      1/1     Running   0          12s
web-599d986bdf-md86x        1/1     Running   0          11s
web-599d986bdf-vx59k        1/1     Running   0          11s
worker-75f7766fd6-4mv8r     1/1     Running   0          11s
```

Les journaux de l'init container montrent l'attente :

```bash
kubectl -n colis logs deploy/api -c attendre-postgres | uniq -c
```

```sortie
      5 postgres:5432 - no response
      1 postgres:5432 - accepting connections
```

Plus aucun redémarrage, et le déploiement est même plus rapide (11 secondes au lieu de 20 à 50), puisqu'on ne subit plus les délais croissants du `CrashLoopBackOff`. La purge est encore en erreur : il faudrait lui ajouter le même init container. Notez les limites de ce remède. Il ne vaut qu'au démarrage du Pod : il ne fait rien pour la perte de la base en cours de route, qu'il faut régler dans l'application. Et il utilise une image de 100 Mo pour une seule commande ; le nœud l'a déjà, puisque PostgreSQL tourne dessus, mais sur un nœud où la base ne tourne pas, il faudrait la tirer.

</details>

:::exercice[Exercice 2 : une sonde de trop]

Un collègue propose, pour régler la panne de la section « Perdre la base », de remplacer `/sante` par `/pret` dans la liveness de l'API. Décrivez ce qui se passerait lors de la même panne, puis lors d'une panne de Redis de deux minutes. Que proposez-vous à la place ?

:::

<details>
<summary>Corrigé</summary>

Lors de la perte de PostgreSQL, la liveness échouerait trois fois (sa valeur par défaut de `failureThreshold`), soit en 30 secondes avec une période de 10, et le kubelet redémarrerait le conteneur. La nouvelle API ouvrirait une nouvelle connexion à la base revenue, et tout rentrerait dans l'ordre : dans ce cas précis, la proposition fonctionne.

Mais lors d'une panne de Redis de deux minutes, `/pret` échouerait aussi, et les deux Pods de l'API seraient redémarrés. Au redémarrage, l'API tenterait de joindre Redis, échouerait, et selon son code, planterait ou démarrerait non prête ; la liveness la tuerait de nouveau, avec des délais croissants. Quand Redis reviendrait, l'API pourrait être en attente d'un délai de `CrashLoopBackOff` de plusieurs dizaines de secondes, voire cinq minutes, et la panne durerait plus longtemps que celle de Redis. Pendant tout ce temps, les requêtes qui n'ont pas besoin de Redis (la lecture d'un colis) auraient pu être servies. C'est le scénario contre lequel la documentation de Kubernetes met en garde : une liveness qui dépend d'un composant extérieur transforme la panne de ce composant en panne de tous ses clients.

À la place : garder la liveness sur `/sante`, la readiness sur `/pret`, et corriger l'application pour qu'elle rouvre ses connexions (un pool de connexions qui vérifie chaque connexion avant usage, ou une reconnexion sur erreur). La sonde doit dire si le processus est bloqué, pas si le monde autour de lui va bien.

</details>

:::exercice[Exercice 3 : le registre vu de trois endroits]

Pour chacune de ces commandes, dites si elle réussit et pourquoi :
1. `docker pull localhost:5001/colis/web:1.0`, sur votre poste ;
2. `docker pull host.minikube.internal:5001/colis/web:1.0`, sur votre poste ;
3. `minikube ssh -- sudo crictl pull localhost:5001/colis/web:1.0`.

Vérifiez ensuite vos réponses.

:::

<details>
<summary>Corrigé</summary>

```bash
docker pull -q localhost:5001/colis/web:1.0
docker pull -q host.minikube.internal:5001/colis/web:1.0
minikube ssh -- sudo crictl pull localhost:5001/colis/web:1.0
```

```sortie
localhost:5001/colis/web:1.0
Error response from daemon: Get "https://host.minikube.internal:5001/v2/": dial tcp: lookup host.minikube.internal: no such host
FATA[0000] pulling image: failed to pull and unpack image "localhost:5001/colis/web:1.0": failed to resolve reference "localhost:5001/colis/web:1.0": failed to do request: Head "https://localhost:5001/v2/colis/web/manifests/1.0": dial tcp [::1]:5001: connect: connection refused
```

1. Réussit : sur le poste, `localhost:5001` est le port publié du conteneur `registre`, et Docker accepte le HTTP pour `localhost`.
2. Échoue : le nom `host.minikube.internal` n'existe que dans le fichier `/etc/hosts` du nœud minikube. Votre poste ne sait pas le résoudre (`no such host`).
3. Échoue : dans le nœud, `localhost` est le nœud lui-même, où rien n'écoute sur le port 5001 (`connection refused`).

Le même registre a donc deux noms, selon d'où on le regarde : `localhost:5001` depuis le poste, `host.minikube.internal:5001` depuis le nœud. Sur un vrai cluster, le problème disparaît, car le registre a un nom DNS unique, joignable de partout, et un certificat.

</details>

## Pour aller plus loin

- Passez l'API à 3 répliques, puis appelez `/api/sante` une vingtaine de fois : combien de noms d'hôte différents voyez-vous ? Pourquoi ne sont-ils pas servis à tour de rôle (chapitre 20) ?
- Donnez au Deployment `web` une readiness qui vérifie aussi l'API, `/api/pret`. Que devient le site lors de la perte de la base ? Est-ce mieux ou pire ?
- Signez l'image `colis/web:1.0` avec la clé du chapitre 14. La partie VI montrera comment faire refuser par le cluster les images qui ne sont pas signées.

## Accéder à Colis et nettoyer

Colis peut rester en marche : le défi III en installe une seconde copie à côté, dans son propre namespace, et a besoin du registre et du fichier `hosts.toml` mis en place ici. Le site est à l'adresse [http://192.168.49.100/](http://192.168.49.100/), et l'API derrière `/api/`. Après un `minikube start`, réappliquez `metallb-plage.yaml`.

Pour tout retirer quand vous n'en aurez plus besoin :

```bash
kubectl delete namespace colis
minikube ssh -- sudo crictl rmi host.minikube.internal:5001/colis/api:2.0 host.minikube.internal:5001/colis/web:1.0
```

Supprimer le namespace supprime tout ce qu'il contient : Deployments, Pods, Services, ConfigMap, Secret. Gardez le registre, les images de votre poste et le fichier `hosts.toml` du nœud : les parties suivantes en ont besoin.

[^etiquettes]: Kubernetes, « Recommended Labels ». [kubernetes.io/docs/concepts/overview/working-with-objects/common-labels](https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/)

[^dependantes]: Kubernetes, « Define Dependent Environment Variables ». [kubernetes.io/docs/tasks/inject-data-application/define-interdependent-environment-variables](https://kubernetes.io/docs/tasks/inject-data-application/define-interdependent-environment-variables/)

[^pousser]: minikube, « Pushing images », qui compare les manières d'amener une image dans le cluster (`image load`, addon `registry`, registre extérieur...). [minikube.sigs.k8s.io/docs/handbook/pushing](https://minikube.sigs.k8s.io/docs/handbook/pushing/)

[^images]: Kubernetes, « Images », sections *Image pull policy* et *Ensure image pull credential verification*. [kubernetes.io/docs/concepts/containers/images](https://kubernetes.io/docs/concepts/containers/images/)

[^sondes]: Kubernetes, « Configure Liveness, Readiness and Startup Probes », et « Liveness, Readiness, and Startup Probes », qui recommandent de ne pas faire dépendre la liveness de services extérieurs. [kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes](https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/)

[^registres]: minikube, « Registries », section *Enabling Insecure Registries*. [minikube.sigs.k8s.io/docs/handbook/registry](https://minikube.sigs.k8s.io/docs/handbook/registry/)

[^hote]: minikube, « Host access », sur le nom `host.minikube.internal`. [minikube.sigs.k8s.io/docs/handbook/host-access](https://minikube.sigs.k8s.io/docs/handbook/host-access/)

[^hosts]: containerd, « Registry Configuration - Introduction » (`docs/hosts.md`), sur les fichiers `hosts.toml` du dossier `certs.d`. [github.com/containerd/containerd/blob/main/docs/hosts.md](https://github.com/containerd/containerd/blob/main/docs/hosts.md)

[^kep2535]: Kubernetes Enhancement Proposal 2535, « Ensure Secret Pulled Images ». [github.com/kubernetes/enhancements/tree/master/keps/sig-node/2535-ensure-secret-pulled-images](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/2535-ensure-secret-pulled-images)
