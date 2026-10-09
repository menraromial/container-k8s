---
title: Utiliser un opérateur existant
sidebar_label: 56. CloudNativePG
description: "Confier PostgreSQL à CloudNativePG : un cluster de trois instances sans StatefulSet, la réplication en flux, deux bascules mesurées, l'arrêt « intelligent » qui retarde la promotion, la sauvegarde continue vers un stockage objet et la restauration à la seconde près, puis la migration réelle de la base de Colis avec 55 secondes de maintenance."
partie: 8
chapitre: '56'
---

import cnpgArchitecture from '@site/src/figures/cnpg-architecture.svg';
import cnpgBascule from '@site/src/figures/cnpg-bascule.svg';

Une base de données dans un StatefulSet à une seule instance a un défaut qu'aucune ligne de YAML ne corrige : quand son Pod tombe, la base tombe avec lui jusqu'à ce que le kubelet le redémarre. Ajouter des répliques au StatefulSet ne change rien, parce que Kubernetes ne sait pas qu'une seule de ces copies peut écrire, laquelle, ni comment en promouvoir une autre. Le reste suit le même chemin. Une sauvegarde par `pg_dump` (chapitre 52) perd tout ce qui a été écrit depuis la dernière ; une montée de version majeure de PostgreSQL ne se fait pas en changeant une étiquette d'image.

Ce savoir-faire existe, et d'autres l'ont écrit dans un opérateur. Le chapitre 55 a montré comment on en construit un ; celui-ci montre comment on en utilise un, et ce qu'il faut vérifier avant de lui confier des données. L'opérateur est **CloudNativePG**, projet en incubation initiale (*sandbox*) à la CNCF, qui gère des clusters PostgreSQL de bout en bout[^cnpg]. On l'essaie d'abord dans un namespace jetable, `ch56`, puis on lui confie la vraie base de Colis. Les fichiers sont dans [l'archive cnpg](pathname:///kits/cnpg.tar.gz).

## Installer l'opérateur

CloudNativePG s'installe par un seul manifeste, publié avec chaque version, et se pilote en partie par un greffon de `kubectl` :

```bash
kubectl apply --server-side -f \
  https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v1.30.1/cnpg-1.30.1.yaml
kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager
kubectl get crd -o name | grep cnpg.io
curl -sL https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v1.30.1/kubectl-cnpg_1.30.1_linux_x86_64.tar.gz \
  | tar -xz -C ~/.local/bin kubectl-cnpg
kubectl cnpg version
```

```sortie
namespace/cnpg-system serverside-applied
validatingwebhookconfiguration.admissionregistration.k8s.io/cnpg-validating-webhook-configuration serverside-applied
objets appliqués : 26
Waiting for deployment "cnpg-controller-manager" rollout to finish: 0 of 1 updated replicas are available...
deployment "cnpg-controller-manager" successfully rolled out
backups.postgresql.cnpg.io
clusterimagecatalogs.postgresql.cnpg.io
clusters.postgresql.cnpg.io
databaseroles.postgresql.cnpg.io
databases.postgresql.cnpg.io
failoverquorums.postgresql.cnpg.io
imagecatalogs.postgresql.cnpg.io
poolers.postgresql.cnpg.io
publications.postgresql.cnpg.io
scheduledbackups.postgresql.cnpg.io
subscriptions.postgresql.cnpg.io
Build: {Version:1.30.1 Commit:2a35abb46 Date:2026-09-23}
```

`--server-side` n'est pas décoratif. En mode client, `kubectl apply` recopie chaque objet dans l'annotation `last-applied-configuration` (chapitre 18) ; or la définition du type `Pooler` pèse 361 Ko en JSON, et l'API server n'accepte pas plus de 262 144 octets d'annotations par objet. Onze types arrivent. `Cluster` décrit un cluster PostgreSQL ; `Backup` et `ScheduledBackup` les sauvegardes ; `Pooler` un PgBouncer devant le cluster ; `Database`, `DatabaseRole`, `Publication` et `Subscription` des objets de PostgreSQL décrits comme des ressources Kubernetes. L'opérateur occupe une quarantaine de mégaoctets en mémoire (39 Mi selon `kubectl top`, sur le cluster du cours).

La sauvegarde vers un stockage objet passe, depuis la version 1.26, par un greffon séparé, Barman Cloud, qui s'installe à côté de l'opérateur et demande cert-manager pour chiffrer leurs échanges[^barman]. Le stockage objet lui-même est RustFS, déjà utilisé avec Velero au chapitre 52, dans un namespace `stockage` :

```bash
kubectl apply -f https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v0.15.1/manifest.yaml
kubectl create namespace stockage
kubectl apply -f rustfs.yaml
```

```sortie
customresourcedefinition.apiextensions.k8s.io/objectstores.barmancloud.cnpg.io created
deployment.apps/barman-cloud created
certificate.cert-manager.io/barman-cloud-client created
certificate.cert-manager.io/barman-cloud-server created
Waiting for deployment "barman-cloud" rollout to finish: 0 of 1 updated replicas are available...
deployment "barman-cloud" successfully rolled out
namespace/stockage created
secret/rustfs created
persistentvolumeclaim/rustfs created
deployment.apps/rustfs created
service/rustfs created
deployment "rustfs" successfully rolled out
PUT /sauvegardes : 200
```

## Un premier cluster

```yaml title="01-cluster.yaml"
# Un cluster PostgreSQL de trois instances : une primaire, deux répliques en flux.
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: essai
  namespace: ch56
spec:
  instances: 3
  storage:
    size: 1Gi
  resources:
    requests: {cpu: 50m, memory: 128Mi}
    limits: {memory: 256Mi}
```

Trois instances, un volume de 1 Gio chacune. Rien d'autre n'est obligatoire : la version de PostgreSQL, l'utilisateur, la base, les certificats, la réplication ont des valeurs par défaut.

```bash
kubectl create namespace ch56
kubectl apply -f 01-cluster.yaml
```

```sortie
namespace/ch56 created
cluster.postgresql.cnpg.io/essai created
07:35:56 Setting up primary
07:36:02 Waiting for the instances to become active
07:36:13 Creating a new replica
07:36:21 Waiting for the instances to become active
07:36:32 Creating a new replica
07:36:38 Waiting for the instances to become active
07:36:51 Cluster in healthy state
durée : 57 s
NAME                               AGE   INSTANCES   READY   STATUS                     PRIMARY
cluster.postgresql.cnpg.io/essai   57s   3           3       Cluster in healthy state   essai-1

NAME          READY   STATUS    RESTARTS   AGE
pod/essai-1   1/1     Running   0          50s
pod/essai-2   1/1     Running   0          30s
pod/essai-3   1/1     Running   0          13s

NAME               TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
service/essai-r    ClusterIP   10.108.9.92     <none>        5432/TCP   57s
service/essai-ro   ClusterIP   10.97.253.225   <none>        5432/TCP   57s
service/essai-rw   ClusterIP   10.103.29.29    <none>        5432/TCP   57s

NAME                            STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
persistentvolumeclaim/essai-1   Bound    pvc-0d4a25b8-6bc4-4e40-992b-1cd274272e3f   1Gi        RWO            standard       <unset>                 57s
persistentvolumeclaim/essai-2   Bound    pvc-70b4a3ea-31ef-41af-ae95-41bbd4f1d60d   1Gi        RWO            standard       <unset>                 38s
persistentvolumeclaim/essai-3   Bound    pvc-1d19e636-302d-4ced-a70d-9d575bd0c596   1Gi        RWO            standard       <unset>                 19s

NAME                       TYPE                       DATA   AGE
secret/essai-app           kubernetes.io/basic-auth   11     57s
secret/essai-ca            Opaque                     2      57s
secret/essai-replication   kubernetes.io/tls          2      57s
secret/essai-server        kubernetes.io/tls          2      57s
```

Moins d'une minute ici, avec l'image déjà sur le nœud. La toute première fois, il a fallu 5 min 16 s, dont 4 min 30 s pour télécharger l'image `postgresql:18.6-system-trixie` (279 Mo). L'opérateur crée la primaire, puis les répliques une à une, chacune clonée de la primaire. Il crée aussi trois Services, quatre Secrets (le compte de l'application, l'autorité de certification du cluster, le certificat du serveur, celui de la réplication) et un volume par instance.

### Ni StatefulSet, ni Deployment

```sortie
# kubectl -n ch56 get statefulsets,deployments
No resources found in ch56 namespace.
# kubectl -n ch56 get pod essai-1 -o json | jq -c '{proprietaire, initContainers, containers}'
{"proprietaire":["Cluster/essai"],"initContainers":[{"name":"bootstrap-controller","image":"ghcr.io/cloudnative-pg/cloudnative-pg:1.30.1"}],"containers":[{"name":"postgres","image":"ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie","command":["/controller/manager","instance","run","--status-port-tls","--log-level=info"]}]}
```

Pas de StatefulSet : les Pods appartiennent directement au `Cluster`. CloudNativePG gère lui-même ses Pods et ses volumes, ce que sa documentation justifie par les limites du StatefulSet pour une base de données : on ne peut pas y agrandir un volume, et un volume supprimé y serait recréé vide, à côté d'un autre qui en dépend, alors qu'il faut reconstruire l'instance entière[^controller]. Chaque Pod a deux conteneurs. Le conteneur d'initialisation `bootstrap-controller` utilise l'image de l'opérateur : il copie dans le Pod le **gestionnaire d'instance**, le programme qui devient ensuite le processus principal du conteneur `postgres` (`/controller/manager instance run`). C'est lui qui lance PostgreSQL, le surveille, répond aux sondes, expose les métriques et applique les ordres de l'opérateur ; CloudNativePG ne s'appuie sur aucun outil externe de bascule[^instance].

Les rôles sont des étiquettes, et les Services sélectionnent par elles :

```sortie
# kubectl -n ch56 get pods -L cnpg.io/instanceRole
NAME      READY   STATUS    RESTARTS   AGE   INSTANCEROLE
essai-1   1/1     Running   0          50s   primary
essai-2   1/1     Running   0          30s   replica
essai-3   1/1     Running   0          13s   replica
# les Services et leurs sélecteurs
SERVICE    SELECTEUR
essai-rw   map[cnpg.io/cluster:essai cnpg.io/instanceRole:primary]
essai-ro   map[cnpg.io/cluster:essai cnpg.io/instanceRole:replica]
essai-r    map[cnpg.io/cluster:essai cnpg.io/podRole:instance]
# les clés du Secret essai-app
dbname fqdn-jdbc-uri fqdn-uri host jdbc-uri password pgpass port uri user username
```

`essai-rw` mène toujours à la primaire, `essai-ro` aux répliques, `essai-r` à n'importe quelle instance[^services]. Une bascule consiste, côté Kubernetes, à changer l'étiquette `cnpg.io/instanceRole` de deux Pods. Le Secret `essai-app` contient tout ce qu'il faut à une application pour se connecter, sous plusieurs formes (URI, JDBC, fichier `pgpass`).

<Figure svg={cnpgArchitecture} num="56.1" alt="L'opérateur CloudNativePG, dans cnpg-system, crée et surveille trois Pods d'instance. Chaque Pod contient le gestionnaire d'instance, processus principal, qui pilote PostgreSQL ; un conteneur d'initialisation a copié ce gestionnaire depuis l'image de l'opérateur, et un sidecar Barman Cloud est ajouté quand la sauvegarde est active. Chaque instance a son propre volume. La primaire envoie ses journaux (WAL) en flux aux deux répliques. Trois Services : rw vers la primaire, ro vers les répliques, r vers toutes. Le sidecar de la primaire envoie les journaux et les sauvegardes complètes vers le stockage objet, d'où un nouveau cluster peut être reconstruit à un instant choisi.">
Un cluster CloudNativePG : pas de StatefulSet, un gestionnaire d'instance dans chaque Pod, des Services qui suivent l'étiquette de rôle, et le stockage objet pour les sauvegardes.
</Figure>

L'état complet du cluster, tel que le voit le greffon :

```bash
kubectl cnpg status essai -n ch56
```

```sortie
Cluster Summary
Name                     ch56/essai
System ID:               7694553126469017627
PostgreSQL Image:        ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie
Primary instance:        essai-1
Primary promotion time:  2026-10-09 06:36:05 +0000 UTC (48s)
Status:                  Cluster in healthy state 
Instances:               3
Ready instances:         3
Size:                    128M
Current Write LSN:       0/6000060 (Timeline: 1 - WAL File: 000000010000000000000006)
Streaming Replication status
Replication Slots Enabled
Name     Sent LSN   Write LSN  Flush LSN  Replay LSN  Write Lag  Flush Lag  Replay Lag  State      Sync State  Sync Priority  Replication Slot
----     --------   ---------  ---------  ----------  ---------  ---------  ----------  -----      ----------  -------------  ----------------
essai-2  0/6000060  0/6000060  0/6000060  0/6000060   00:00:00   00:00:00   00:00:00    streaming  async       0              active
essai-3  0/6000060  0/6000060  0/6000060  0/6000060   00:00:00   00:00:00   00:00:00    streaming  async       0              active

Instances status
Name     Current LSN  Replication role  Status  QoS        Manager Version  Node
----     -----------  ----------------  ------  ---        ---------------  ----
essai-1  0/6000060    Primary           OK      Burstable  1.30.1           minikube
essai-2  0/6000060    Standby (async)   OK      Burstable  1.30.1           minikube
essai-3  0/6000060    Standby (async)   OK      Burstable  1.30.1           minikube
```

## La réplication en flux

La primaire envoie ses journaux de transactions (WAL, *write-ahead log*) aux répliques, qui les rejouent en continu : c'est la réplication en flux de PostgreSQL. Une table de cent mille lignes, créée sur la primaire, puis comptée sur chaque instance ; et une tentative d'écriture sur une réplique :

```sortie
essai-1 (primary) : 100000
essai-2 (replica) : 100000
essai-3 (replica) : 100000
ERROR:  cannot execute INSERT in a read-only transaction
command terminated with exit code 1
```

Les répliques sont en lecture seule. Elles servent la lecture (le Service `-ro`) et surtout la reprise : chacune peut devenir primaire.

## Deux bascules

Le client d'essai écrit une ligne toutes les 200 ms par le Service `essai-rw`, avec une connexion neuve à chaque écriture, et note l'heure et le résultat :

```yaml title="ecrivain.yaml (extrait)"
  - name: ecrivain
    image: ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie
    env:
    - name: PGCONNECT_TIMEOUT      # sans délai, une connexion vers un Pod disparu attend l'échec de TCP
      value: "2"
    - name: URI
      valueFrom: {secretKeyRef: {name: essai-app, key: uri}}
    command: [bash, -c]
    args:
    - |
      psql "$URI" -qc "CREATE TABLE IF NOT EXISTS battements (n int, a timestamptz DEFAULT now(), serveur text DEFAULT inet_server_addr())"
      n=0
      while true; do
        n=$((n+1))
        if r=$(psql "$URI" -qtAc "INSERT INTO battements (n) VALUES ($n) RETURNING serveur" 2>&1); then
          echo "$(date +%T.%3N) ok $n $r"
        else
          echo "$(date +%T.%3N) échec $n $(echo "$r" | head -1 | cut -c1-160)"
        fi
        sleep 0.2
      done
    securityContext:
      allowPrivilegeEscalation: false
      capabilities: {drop: [ALL]}
```

`PGCONNECT_TIMEOUT` n'est pas un détail. Sans lui, la première version du client s'est figée au premier essai : une connexion lancée vers l'adresse d'un Pod qui vient de disparaître attend que TCP abandonne, et le client est resté figé pendant toute la mesure.

### Une bascule subie

On supprime le Pod de la primaire :

```sortie
primaire : essai-1
pod "essai-1" deleted from ch56 namespace
nouvelle primaire : essai-2
     20 ok 10.244.0.237/32
     10 échec psql:
     77 ok 10.244.0.239/32
06:37:00.231 ok 20 10.244.0.237/32
06:37:00.486 échec 21 psql: error: connection to server at "essai-rw.ch56" (10.103.29.29), port 5432 failed: FATAL:  the database system is shutting down
06:37:00.736 échec 22 psql: error: connection to server at "essai-rw.ch56" (10.103.29.29), port 5432 failed: Connection refused
06:37:00.979 échec 23 psql: error: connection to server at "essai-rw.ch56" (10.103.29.29), port 5432 failed: Connection refused
06:37:01.228 échec 24 psql: error: connection to server at "essai-rw.ch56" (10.103.29.29), port 5432 failed: Connection refused
06:37:01.475 échec 25 psql: error: connection to server at "essai-rw.ch56" (10.103.29.29), port 5432 failed: Connection refused
06:37:01.721 échec 26 psql: error: connection to server at "essai-rw.ch56" (10.103.29.29), port 5432 failed: Connection refused
06:37:01.971 échec 27 psql: error: connection to server at "essai-rw.ch56" (10.103.29.29), port 5432 failed: Connection refused
06:37:02.220 échec 28 psql: error: connection to server at "essai-rw.ch56" (10.103.29.29), port 5432 failed: Connection refused
06:37:02.469 échec 29 psql: error: connection to server at "essai-rw.ch56" (10.103.29.29), port 5432 failed: Connection refused
06:37:02.717 échec 30 psql: error: connection to server at "essai-rw.ch56" (10.103.29.29), port 5432 failed: Connection refused
06:37:04.037 ok 31 10.244.0.239/32
NAME       READY   STATUS    RESTARTS   AGE   INSTANCEROLE
ecrivain   1/1     Running   0          31s   
essai-1    1/1     Running   0          22s   replica
essai-2    1/1     Running   0          64s   primary
essai-3    1/1     Running   0          47s   replica
{"currentPrimary":"essai-2","timelineID":2,"currentPrimaryTimestamp":"2026-10-09T06:37:03.637760Z"}
```

Quatre secondes sans écriture possible : onze tentatives refusées, la première par « the database system is shutting down », les suivantes par « Connection refused », le temps que l'opérateur constate la perte de la primaire, promeuve `essai-2` et que le Service `essai-rw` suive. La ligne de temps (`timelineID`) passe à 2 : c'est ainsi que PostgreSQL distingue l'histoire d'avant et d'après une promotion. L'ancienne primaire, recréée sous le même nom, est revenue comme réplique de la nouvelle.

### Une bascule programmée

Quand on sait à l'avance qu'une instance doit s'arrêter (vidage de nœud, maintenance), on demande une bascule programmée (*switchover*) :

```sortie
$ kubectl cnpg promote essai essai-1 -n ch56
{"level":"info","ts":"2026-10-09T07:38:02.909231743+01:00","msg":"Cluster has become unhealthy"}
Node essai-1 in cluster essai will be promoted
      1 relation already
     20 ok 10.244.0.239/32
     13 échec psql:
     36 ok 10.244.0.243/32
06:38:03.180 échec 21 psql: error: connection to server at "essai-rw.ch56" (10.103.29.29), port 5432 failed: Connection refused
06:38:03.431 échec 22 psql: error: connection to server at "essai-rw.ch56" (10.103.29.29), port 5432 failed: Connection refused
06:38:03.678 échec 23 psql: error: connection to server at "essai-rw.ch56" (10.103.29.29), port 5432 failed: Connection refused
06:38:03.928 échec 24 psql: error: connection to server at "essai-rw.ch56" (10.103.29.29), port 5432 failed: Connection refused
06:38:04.178 échec 25 psql: error: connection to server at "essai-rw.ch56" (10.103.29.29), port 5432 failed: Connection refused
06:38:04.423 échec 26 psql: error: connection to server at "essai-rw.ch56" (10.103.29.29), port 5432 failed: Connection refused
06:38:04.671 échec 27 psql: error: connection to server at "essai-rw.ch56" (10.103.29.29), port 5432 failed: Connection refused
06:38:05.968 échec 28 psql: error: connection to server at "essai-rw.ch56" (10.103.29.29), port 5432 failed: Connection refused
06:38:06.217 échec 29 psql: error: connection to server at "essai-rw.ch56" (10.103.29.29), port 5432 failed: Connection refused
06:38:07.505 échec 30 psql: error: connection to server at "essai-rw.ch56" (10.103.29.29), port 5432 failed: Connection refused
06:38:08.785 échec 31 psql: error: connection to server at "essai-rw.ch56" (10.103.29.29), port 5432 failed: Connection refused
06:38:10.065 échec 32 psql: error: connection to server at "essai-rw.ch56" (10.103.29.29), port 5432 failed: Connection refused
06:38:10.313 échec 33 psql: error: connection to server at "essai-rw.ch56" (10.103.29.29), port 5432 failed: Connection refused
NAME       READY   STATUS    RESTARTS      AGE    INSTANCEROLE
ecrivain   1/1     Running   0             25s    
essai-1    1/1     Running   0             78s    primary
essai-2    1/1     Running   1 (18s ago)   2m     replica
essai-3    1/1     Running   0             103s   replica
```

Programmée ne veut pas dire sans interruption : onze écritures refusées, cette fois encore, sur environ cinq secondes. L'ancienne primaire est arrêtée proprement avant la promotion, ce qui garantit qu'aucune transaction validée n'est perdue ; la bascule subie, elle, peut perdre les dernières transactions qui n'avaient pas atteint une réplique, puisque la réplication est asynchrone par défaut (`Sync State` vaut `async` dans le statut). Une application doit donc savoir refaire une écriture qui a échoué, quelle que soit la bascule.

## L'arrêt « intelligent » et les connexions qui durent

L'écrivain ouvrait une connexion par écriture. L'API de Colis, elle, garde ses connexions ouvertes, comme la plupart des applications. Le premier exercice rejoue la bascule subie sur la base de Colis, sous la charge du chapitre 50, et le résultat n'a rien à voir :

```sortie
smartShutdownTimeout : 180, stopDelay : 1800
06:52:27 suppression de colis-pg-2 (primaire)
06:55:33 nouvelle primaire : colis-pg-1
promotion : 2026-10-09T06:55:31.924622Z
réponses : 200 x882, 201 x288, 404 x140, 500 x1, 503 x1
api-5b7b7bd699-r8tp2 : 1 réponses 5xx
api-5b7b7bd699-wbm8f : 0 réponses 5xx
NAME       AGE   INSTANCES   READY   STATUS                     PRIMARY
colis-pg   12m   2           2       Cluster in healthy state   colis-pg-1
```

Trois minutes entre la suppression du Pod et la promotion. La cause est dans la procédure d'arrêt d'une instance[^instance]. Quand son Pod est supprimé, le gestionnaire d'instance demande à PostgreSQL un arrêt **intelligent** (*smart shutdown*) : les nouvelles connexions sont refusées, mais les sessions déjà ouvertes continuent de travailler, jusqu'à `smartShutdownTimeout` secondes (180 par défaut). Ensuite seulement vient l'arrêt **rapide**, qui coupe les sessions. Pendant ces trois minutes, l'API de Colis a continué d'écrire sur l'ancienne primaire par ses connexions existantes, et l'opérateur a attendu qu'elle s'arrête pour promouvoir la réplique. Une seule réponse en erreur côté utilisateurs, mais trois minutes pendant lesquelles un nouveau Pod de l'API n'aurait pas pu se connecter.

```sortie
# kubectl -n colis patch cluster colis-pg --type=merge -p '{"spec":{"smartShutdownTimeout":10}}'
cluster.postgresql.cnpg.io/colis-pg patched
06:56:37 suppression de colis-pg-1 (primaire)
06:56:54 nouvelle primaire : colis-pg-2
promotion : 2026-10-09T06:56:53.823992Z
réponses : 200 x328, 201 x94, 404 x40, 500 x2
api-5b7b7bd699-r8tp2 : 1 réponses 5xx
api-5b7b7bd699-wbm8f : 1 réponses 5xx
NAME       AGE   INSTANCES   READY   STATUS                     PRIMARY
colis-pg   14m   2           2       Cluster in healthy state   colis-pg-2
```

Avec `smartShutdownTimeout: 10`, la promotion arrive en 17 secondes. La documentation de CloudNativePG donne la règle à suivre : ne pas supprimer le Pod de la primaire, mais faire d'abord une bascule programmée, qui arrête l'ancienne primaire par un arrêt rapide[^instance]. Un `kubectl drain` sur le nœud de la primaire déclenche justement l'arrêt du Pod : c'est pour cela que CloudNativePG crée deux PodDisruptionBudgets par cluster, dont `colis-pg-primary` : quand un nœud qui porte la primaire doit être vidé, l'opérateur fait d'abord une bascule programmée, et le vidage reprend ensuite[^pdb].

<Figure svg={cnpgBascule} num="56.2" alt="Trois bascules subies, sur une même échelle de temps à partir de la suppression du Pod primaire. Client à connexions courtes (cluster d'essai) : écritures refusées pendant environ 4 secondes, puis reprise sur la nouvelle primaire. API de Colis, réglage par défaut : l'ancienne primaire refuse les nouvelles connexions mais sert les sessions ouvertes pendant l'arrêt intelligent, jusqu'à 180 secondes ; la promotion arrive 3 minutes 4 secondes après la suppression. Avec smartShutdownTimeout à 10 secondes : promotion après 17 secondes.">
Trois bascules mesurées. La durée dépend moins de PostgreSQL que des connexions ouvertes par les clients et du délai d'arrêt intelligent.
</Figure>

## La sauvegarde continue

Une sauvegarde par `pg_dump` est une photographie : tout ce qui est écrit après est perdu si la base disparaît. CloudNativePG combine deux choses, comme PostgreSQL le prévoit : des sauvegardes complètes du répertoire de données (*base backups*), et l'archivage continu de chaque segment de journal (WAL) dès qu'il est rempli. Avec les deux, on peut reconstruire la base à n'importe quel instant entre la première sauvegarde complète et le dernier journal archivé.

Le compartiment, ses identifiants et l'objet `ObjectStore` du greffon :

```yaml title="02-sauvegarde.yaml"
# La sauvegarde continue : le compartiment, ses identifiants, et le greffon Barman Cloud
# déclaré dans le cluster comme archiveur des journaux (WAL).
apiVersion: v1
kind: Secret
metadata:
  name: s3
  namespace: ch56
stringData:
  ACCESS_KEY_ID: cnpg
  ACCESS_SECRET_KEY: sauvegardes-du-cours-56
---
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: rustfs
  namespace: ch56
spec:
  retentionPolicy: "7d"
  configuration:
    destinationPath: s3://sauvegardes/
    endpointURL: http://rustfs.stockage.svc.cluster.local:9000
    s3Credentials:
      accessKeyId: {name: s3, key: ACCESS_KEY_ID}
      secretAccessKey: {name: s3, key: ACCESS_SECRET_KEY}
    wal:
      compression: gzip
    data:
      compression: gzip
```

Le cluster déclare le greffon comme archiveur de ses journaux, par quatre lignes ajoutées à sa définition :

```yaml title="03-cluster-sauvegarde.yaml (fin)"
  plugins:
  - name: barman-cloud.cloudnative-pg.io
    isWALArchiver: true
    parameters:
      barmanObjectName: rustfs
```

```bash
kubectl apply -f 02-sauvegarde.yaml -f 03-cluster-sauvegarde.yaml
```

```sortie
secret/s3 created
objectstore.barmancloud.cnpg.io/rustfs created
cluster.postgresql.cnpg.io/essai configured
07:38:27 Waiting for the instances to become active
07:38:50 Primary instance is being restarted without a switchover
07:39:07 Cluster in healthy state
NAME      READY   STATUS    RESTARTS   AGE
essai-1   2/2     Running   0          12s
essai-2   2/2     Running   0          28s
essai-3   2/2     Running   0          42s
[{"name":"bootstrap-controller","image":"ghcr.io/cloudnative-pg/cloudnative-pg:1.30.1","restartPolicy":null},{"name":"plugin-barman-cloud","image":"ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar:v0.15.1","restartPolicy":"Always"}]
{"type":"Initialized","status":"True","reason":"BootstrapCompleted"}
{"type":"ConsistentSystemID","status":"True","reason":"Unique"}
{"type":"Ready","status":"True","reason":"ClusterIsReady"}
{"type":"ContinuousArchiving","status":"True","reason":"ContinuousArchivingSuccess"}
```

Les trois Pods ont été recréés, les répliques d'abord, la primaire en dernier, redémarrée sur place (*restarted without a switchover*) : c'est la mise à jour progressive de CloudNativePG, qui laisse la primaire pour la fin[^rolling]. Chacun a maintenant un deuxième conteneur, `plugin-barman-cloud`, déclaré comme conteneur d'initialisation avec `restartPolicy: Always`, c'est-à-dire un sidecar natif (chapitre 17). La condition `ContinuousArchiving` passe à `True` au premier journal archivé. Une sauvegarde complète se demande par un objet `Backup` :

```yaml title="04-sauvegarde-complete.yaml"
# Une sauvegarde complète (base backup), copiée par le greffon dans le compartiment.
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: premiere
  namespace: ch56
spec:
  cluster:
    name: essai
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
```

```sortie
backup.postgresql.cnpg.io/premiere created
NAME       AGE   CLUSTER   METHOD   PHASE       ERROR
premiere   59s   essai     plugin   completed   
{"phase":"completed","backupId":"20261009T063908","beginWal":"000000030000000000000009","endWal":"000000030000000000000009","startedAt":"2026-10-09T06:39:08Z","stoppedAt":"2026-10-09T06:40:04Z"}
Continuous Backup status (Barman Cloud Plugin)
ObjectStore / Server name:      rustfs/essai
First Point of Recoverability:  2026-10-09 07:40:04 WAT
Last Successful Backup:         2026-10-09 07:40:04 WAT
Last Failed Backup:             -
Working WAL archiving:          OK
WALs waiting to be archived:    0
Last Archived WAL:              000000030000000000000008   @   2026-10-09T06:38:59.803316Z
Last Failed WAL:                000000030000000000000008   @   2026-10-09T06:38:54.092362Z

      2 essai/base/20261009T063908
      1 essai/wals/0000000300000000
```

Dans le compartiment, un dossier par serveur, avec ses sauvegardes complètes (`base`) et ses journaux (`wals`). La ligne `Last Failed WAL` date du remplacement des Pods, quelques secondes plus tôt : un journal dont l'archivage a été refusé pendant le redémarrage, puis archivé au passage suivant. Le premier essai de ce rejeu avait échoué en chaîne : le compartiment n'avait pas été créé, RustFS ne répondant pas encore au moment de la requête, et le statut disait `Working WAL archiving: Failing`, puis la sauvegarde `failed` avec un simple `exit status 1`. Quand l'archivage échoue, le premier endroit à regarder est le compartiment.

## Revenir à la seconde près

L'accident classique : une commande lancée sur la mauvaise base. L'écrivain remplit la table pendant trente secondes, on note l'heure, puis :

```sortie
lignes dans battements : 591
instant choisi : 2026-10-09T06:41:13.727267Z
$ DROP TABLE battements
ERROR:  relation "battements" does not exist
```

La table a disparu de la primaire et, quelques millisecondes plus tard, des répliques : la réplication recopie fidèlement les erreurs. Les journaux archivés, eux, contiennent tout ce qui s'est passé avant. On reconstruit un nouveau cluster à partir du stockage objet, en rejouant les journaux jusqu'à l'instant noté :

```yaml title="05-restauration.yaml"
# Un nouveau cluster, reconstruit depuis le stockage objet : la sauvegarde complète,
# puis les journaux rejoués jusqu'à l'instant choisi, juste avant l'accident.
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: essai-restaure
  namespace: ch56
spec:
  instances: 1
  storage:
    size: 1Gi
  resources:
    requests: {cpu: 50m, memory: 128Mi}
    limits: {memory: 256Mi}
  bootstrap:
    recovery:
      source: origine
      recoveryTarget:
        targetTime: "2026-10-09T06:41:13.727267Z"     # remplacé par l'instant choisi, au format ISO 8601 en UTC
  externalClusters:
  - name: origine
    plugin:
      name: barman-cloud.cloudnative-pg.io
      parameters:
        barmanObjectName: rustfs
        serverName: essai
```

```sortie
cluster.postgresql.cnpg.io/essai-restaure created
07:41:34 Setting up primary
07:41:57 Waiting for the instances to become active
07:42:07 Primary instance is being restarted without a switchover
07:42:22 Cluster in healthy state
durée : 51 s
591|2026-10-09 06:41:11.907659+00
NAME               READY   STATUS    RESTARTS   AGE
essai-1            2/2     Running   0          3m27s
essai-2            2/2     Running   0          3m43s
essai-3            2/2     Running   0          3m57s
essai-restaure-1   1/1     Running   0          12s
```

Cinquante et une secondes pour un cluster neuf, avec les 591 lignes et la dernière écrite à moins de deux secondes de l'instant choisi[^recovery]. On restaure dans un **nouveau** cluster, jamais dans celui qui a subi l'accident : on compare, on récupère les données perdues, et c'est seulement ensuite qu'on décide quoi faire de chacun.

## Confier la base de Colis à CloudNativePG

La base de Colis vit depuis le chapitre 26 dans un StatefulSet `postgres`, avec un volume et un Secret `colis-db`. La migration doit déplacer les données sans en perdre, faire pointer l'application vers la nouvelle base, et respecter les trois protections du namespace `colis` : le niveau `restricted` de Pod Security (chapitre 44), la politique d'images `images-colis` (chapitre 45) et le refus réseau par défaut (chapitre 41).

### Des images qu'on accepte

```sortie
NAME                     READY   STATUS    RESTARTS      AGE
api-f96c76847-wdd6d      1/1     Running   0             10h
api-f96c76847-wq9qj      1/1     Running   0             10h
postgres-0               1/1     Running   0             12h
redis-5cbb6759f7-2cjfs   1/1     Running   1 (12h ago)   21h
web-65cdb99b99-6ppdj     1/1     Running   1 (12h ago)   21h
web-65cdb99b99-wctcb     1/1     Running   1 (12h ago)   21h
ancienne base : 4041 colis, 4040 estimés, dernier n° 4043
colis.local : 200
host.minikube.internal:5001/,redis:,postgres:,busybox:
```

Les images de CloudNativePG viennent de `ghcr.io/cloudnative-pg/`, qui n'est pas dans la liste. Avant de l'y ajouter, on vérifie qu'elles sont signées par le projet. Ses images sont signées sans clé : là où le chapitre 14 signait avec une paire de clés, la signature est ici liée à l'identité du flux GitHub Actions qui a construit l'image, et `cosign` vérifie cette identité.

```sortie
$ cosign verify ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie ...
Verification for ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
$ cosign verify ghcr.io/cloudnative-pg/cloudnative-pg:1.30.1 ...
Verification for ghcr.io/cloudnative-pg/cloudnative-pg:1.30.1 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
$ cosign verify ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar:v0.15.1 ...
Error: no signatures found
error during command execution: no signatures found
configmap/images-autorisees patched
```

L'image de PostgreSQL et celle de l'opérateur sont signées par un flux de GitHub Actions du projet ; celle du sidecar Barman Cloud ne l'est pas, à cette version. La politique `images-colis` ne vérifie que le registre, pas la signature (la vérification par Kyverno a été retirée au début de la partie VII) : on accepte donc ce sidecar en connaissance de cause, et c'est à noter dans le registre des risques de l'équipe. Les Pods de CloudNativePG respectent le niveau `restricted` sans réglage : un essai à blanc de l'étiquette `pod-security.kubernetes.io/enforce=restricted` sur `ch56` n'avait produit aucun avertissement.

### Le réseau

Les politiques existantes des Pods `api`, `worker` et `purge` visent la base par l'étiquette `app.kubernetes.io/name=postgres`. Donner cette étiquette aux instances de CloudNativePG (le champ `inheritedMetadata` le permet) ferait passer le trafic sans toucher aux politiques. Ce serait une erreur : le Service `postgres` de l'ancienne base sélectionne ses Pods par cette même étiquette, et pendant la migration il enverrait une partie des requêtes de l'application vers les nouvelles instances, dont une réplique en lecture seule. On écrit donc des politiques pour l'étiquette que pose CloudNativePG, `cnpg.io/cluster=colis-pg` :

```yaml title="colis/11-politiques.yaml (extrait)"
# Le trafic des instances de colis-pg, dans un namespace où tout est refusé par défaut (chapitre 41).
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: colis-pg
  namespace: colis
spec:
  podSelector:
    matchLabels: {cnpg.io/cluster: colis-pg}
  policyTypes: [Ingress, Egress]
  ingress:
  - from:            # l'application
    - podSelector:
        matchExpressions:
        - {key: app.kubernetes.io/name, operator: In, values: [api, api-canari, worker, purge]}
    ports: [{port: 5432}]
  - from:            # les autres instances : réplication, et l'état de chaque instance
    - podSelector:
        matchLabels: {cnpg.io/cluster: colis-pg}
    ports: [{port: 5432}, {port: 8000}]
  - from:            # l'opérateur interroge chaque instance sur son port 8000
    - namespaceSelector:
        matchLabels: {kubernetes.io/metadata.name: cnpg-system}
    ports: [{port: 8000}]
  - from:            # Prometheus relève les métriques sur le port 9187
    - namespaceSelector:
        matchLabels: {kubernetes.io/metadata.name: supervision}
    ports: [{port: 9187}]
  egress:
  - to:
    - podSelector:
        matchLabels: {cnpg.io/cluster: colis-pg}
    ports: [{port: 5432}, {port: 8000}]
  - to:              # l'API server, par l'adresse du nœud après traduction (chapitre 41)
    - ipBlock: {cidr: 192.168.49.2/32}
    ports: [{port: 8443}]
  - to:              # le stockage objet des sauvegardes
    - namespaceSelector:
        matchLabels: {kubernetes.io/metadata.name: stockage}
      podSelector:
        matchLabels: {app.kubernetes.io/name: rustfs}
    ports: [{port: 9000}]
```

Les instances ont besoin de plus que l'application : se joindre entre elles pour la réplication, répondre à l'opérateur sur le port 8000 (l'état de chaque instance), joindre l'API server (le gestionnaire d'instance lit et met à jour des objets), envoyer leurs sauvegardes à RustFS, et laisser Prometheus lire leurs métriques. L'API server se joint par l'adresse du nœud et le port 8443, parce que la politique s'applique après la traduction d'adresse du Service `kubernetes` (chapitre 41). Le même fichier contient deux politiques temporaires, qui laissent les nouvelles instances lire l'ancienne base le temps de l'import, et une politique `vers-colis-pg` qui ouvre le chemin depuis l'application.

```sortie
networkpolicy.networking.k8s.io/colis-pg created
networkpolicy.networking.k8s.io/vers-colis-pg created
networkpolicy.networking.k8s.io/import-depuis-postgres created
networkpolicy.networking.k8s.io/import-vers-postgres created
secret/s3 created
objectstore.barmancloud.cnpg.io/rustfs created
```

### La maintenance

Copier une base pendant que l'application y écrit, c'est risquer d'oublier les dernières écritures. La migration se fait donc dans une fenêtre de maintenance : l'API est arrêtée, KEDA mis en pause sur zéro worker (annotation `autoscaling.keda.sh/paused-replicas`, chapitre 31), la purge suspendue.

```sortie
début de la maintenance : 06:43:13 UTC
scaledobject.keda.sh/worker annotated
cronjob.batch/purge patched
deployment.apps/api scaled
pod/api-f96c76847-wdd6d condition met
pod/api-f96c76847-wq9qj condition met
colis.local : 503
ancienne base, figée : 4041 colis, 4040 estimés, dernier n° 4043
```

La passerelle répond 503 : elle n'a plus aucun Pod de l'API derrière elle. Le cluster `colis-pg` importe la base pendant sa création :

```yaml title="colis/13-colis-pg.yaml"
# La base de Colis, confiée à CloudNativePG : deux instances, les données importées de l'ancien
# StatefulSet par pg_dump et pg_restore, les journaux archivés en continu.
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: colis-pg
  namespace: colis
spec:
  instances: 2
  imageName: ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie
  storage:
    size: 1Gi
  resources:
    requests: {cpu: 50m, memory: 128Mi}
    limits: {memory: 256Mi}
  bootstrap:
    initdb:
      database: colis
      owner: colis
      import:
        type: microservice
        databases: [colis]
        source:
          externalCluster: ancien
  externalClusters:
  - name: ancien
    connectionParameters:
      host: postgres.colis.svc.cluster.local
      user: colis
      dbname: colis
    password:
      name: colis-db
      key: POSTGRES_PASSWORD
  plugins:
  - name: barman-cloud.cloudnative-pg.io
    isWALArchiver: true
    parameters:
      barmanObjectName: rustfs
```

L'import de type `microservice` crée une base `colis` appartenant à un rôle `colis`, puis y copie la base de l'ancien serveur par `pg_dump` et `pg_restore`, depuis le Pod de la nouvelle primaire[^import]. Le mot de passe de l'ancien serveur est lu dans le Secret `colis-db` existant.

```sortie
cluster.postgresql.cnpg.io/colis-pg created
07:43:21 Setting up primary
07:43:31 Waiting for the instances to become active
07:43:43 Creating a new replica
07:43:49 Waiting for the instances to become active
07:44:02 Cluster in healthy state
durée : 44 s
No resources found in colis namespace.
NAME         READY   STATUS    RESTARTS   AGE   INSTANCEROLE
colis-pg-1   2/2     Running   0          32s   primary
colis-pg-2   2/2     Running   0          13s   replica
RAISON                        MESSAGE
CreatingPodDisruptionBudget   Creating PodDisruptionBudget colis-pg-primary
CreatingServiceAccount        Creating ServiceAccount
CreatingRole                  Creating Cluster Role
CreatingInstance              Primary instance (initdb)
CreatingInstance              Creating instance colis-pg-2
{"type":"kubernetes.io/basic-auth","cles":["dbname","fqdn-jdbc-uri","fqdn-uri","host","jdbc-uri","password","pgpass","port","uri","user","username"],"utilisateur":"colis"}
```

Quarante-quatre secondes. Le Secret `colis-pg-app` contient le compte de l'application, `colis`, avec un mot de passe neuf. La vérification compare les deux bases :

```sortie
ancienne base : 4041 colis, 4040 estimés, dernier n° 4043
colis-pg      : 4041 colis, 4040 estimés, dernier n° 4043
colis|colis
8814 kB
```

Même nombre de colis, mêmes statuts, même dernier numéro. La séquence des numéros a suivi : le prochain colis créé prendra le numéro qui suit. Reste à faire pointer l'application vers la nouvelle base, par un script qui modifie deux variables dans l'API, le worker et la purge :

```bash title="colis/basculer.sh (extrait)"
# Fait pointer l'API, le worker et la purge vers colis-pg : l'adresse du Service colis-pg-rw,
# et le mot de passe du rôle colis, rangé par CloudNativePG dans le Secret colis-pg-app.
set -euo pipefail
NS=colis
MDP='{"name":"POSTGRES_PASSWORD","valueFrom":{"secretKeyRef":{"name":"colis-pg-app","key":"password"}}}'
URL='{"name":"COLIS_DB","value":"postgresql://colis:$(POSTGRES_PASSWORD)@colis-pg-rw:5432/colis"}'
for d in api worker; do
  kubectl -n $NS patch deployment $d --type=strategic -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"$d\",\"env\":[$MDP,$URL]}]}}}}"
done
kubectl -n $NS patch cronjob purge --type=strategic -p "{\"spec\":{\"jobTemplate\":{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"purge\",\"env\":[$MDP,$URL]}]}}}}}}"
```

```sortie
deployment.apps/api patched
deployment.apps/worker patched
cronjob.batch/purge patched
deployment.apps/api scaled
scaledobject.keda.sh/worker annotated
cronjob.batch/purge patched
Waiting for deployment "api" rollout to finish: 0 of 2 updated replicas are available...
deployment "api" successfully rolled out
fin de la maintenance : 06:44:08 UTC
durée de la maintenance : 55 s
[{"name":"POSTGRES_PASSWORD","valueFrom":{"secretKeyRef":{"key":"password","name":"colis-pg-app"}}},{"name":"COLIS_DB","value":"postgresql://colis:$(POSTGRES_PASSWORD)@colis-pg-rw:5432/colis"}]
```

Cinquante-cinq secondes de maintenance, de l'arrêt de l'API à la première réponse 200. Un colis neuf traverse toute l'application, la purge joint la base, et la première sauvegarde complète de `colis-pg` part vers RustFS :

```sortie
colis 4044 : estimé
colis-pg : 4042 colis, 4041 estimés, dernier n° 4044
ancienne base : 4041 colis, 4040 estimés, dernier n° 4043
job.batch/essai-purge created
job.batch/essai-purge condition met
purge : 0 colis livrés depuis plus de 30 jours supprimés
job.batch "essai-purge" deleted from colis namespace
# sauvegarde complète de colis-pg
backup.postgresql.cnpg.io/apres-migration created
NAME              AGE   CLUSTER    METHOD   PHASE       ERROR
apres-migration   10s   colis-pg   plugin   completed   
Cluster Summary
Name                     colis/colis-pg
System ID:               7694555034706124827
PostgreSQL Image:        ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie
Primary instance:        colis-pg-1
Primary promotion time:  2026-10-09 06:43:34 +0000 UTC (57s)
Status:                  Cluster in healthy state 
Instances:               2
Ready instances:         2
Size:                    80M
Current Write LSN:       0/3107710 (Timeline: 1 - WAL File: 000000010000000000000003)
Continuous Backup status (Barman Cloud Plugin)
ObjectStore / Server name:      rustfs/colis-pg
First Point of Recoverability:  2026-10-09 07:44:26 WAT
Last Successful Backup:         2026-10-09 07:44:26 WAT
Last Failed Backup:             -
Working WAL archiving:          OK
WALs waiting to be archived:    0
Last Archived WAL:              000000010000000000000002.00000028.backup   @   2026-10-09T06:43:46.973505Z
Last Failed WAL:                -

mémoire du nœud : 4.336GiB / 5GiB
```

L'ancienne base n'a pas reçu le colis 4044 : elle est désormais figée, et ne sert plus que de point de comparaison.

### Retirer l'ancienne base

Une fois la migration vérifiée, et une copie `pg_dump` de l'ancienne base mise de côté par précaution, on retire le StatefulSet, son Service, son volume, son Secret, les politiques qui le concernaient et les règles de sortie vers lui dans les politiques de l'application :

```sortie
networkpolicy.networking.k8s.io "import-depuis-postgres" deleted from colis namespace
networkpolicy.networking.k8s.io "import-vers-postgres" deleted from colis namespace
networkpolicy.networking.k8s.io "postgres" deleted from colis namespace
statefulset.apps "postgres" deleted from colis namespace
service "postgres" deleted from colis namespace
persistentvolumeclaim "donnees-postgres-0" deleted from colis namespace
secret "colis-db" deleted from colis namespace
networkpolicy.networking.k8s.io/api replaced
networkpolicy.networking.k8s.io/worker replaced
networkpolicy.networking.k8s.io/purge replaced
NAME               POD-SELECTOR                                              AGE
api                app.kubernetes.io/name in (api,api-canari)                21h
colis-pg           cnpg.io/cluster=colis-pg                                  106s
dns                <none>                                                    21h
purge              app.kubernetes.io/name=purge                              21h
redis              app.kubernetes.io/name=redis                              21h
refus-par-defaut   <none>                                                    21h
supervision        app.kubernetes.io/name in (api,worker)                    21h
vers-colis-pg      app.kubernetes.io/name in (api,api-canari,purge,worker)   106s
web                app.kubernetes.io/name=web                                21h
worker             app.kubernetes.io/name=worker                             21h
# après le retrait
NAME                     READY   STATUS    RESTARTS      AGE
api-5b7b7bd699-r8tp2     1/1     Running   0             75s
api-5b7b7bd699-wbm8f     1/1     Running   0             75s
colis-pg-1               2/2     Running   0             109s
colis-pg-2               2/2     Running   0             90s
redis-5cbb6759f7-2cjfs   1/1     Running   1 (12h ago)   21h
web-65cdb99b99-6ppdj     1/1     Running   1 (12h ago)   21h
web-65cdb99b99-wctcb     1/1     Running   1 (12h ago)   21h
persistentvolume "pvc-72307363-a964-4130-b2cf-c1bf9ce85db5" deleted
colis.local : 200
mémoire du nœud : 4.261GiB / 5GiB
# la purge, par la nouvelle base
{"podSelector":{"matchLabels":{"app.kubernetes.io/name":"purge"}},"policyTypes":["Egress"]}
job.batch/essai-purge2 created
job.batch/essai-purge2 condition met
purge : 0 colis livrés depuis plus de 30 jours supprimés
job.batch "essai-purge2" deleted from colis namespace
```

La politique `purge` n'a plus de règle de sortie propre. Ce n'est pas un refus total : les politiques s'additionnent, et `vers-colis-pg` et `dns` autorisent ce dont la purge a besoin, comme le confirme le Job lancé à la fin. La base de Colis est maintenant `colis-pg` : deux instances, une bascule automatique, l'archivage continu des journaux et une sauvegarde complète. Le nœud est à 4,261 Gio, un peu moins qu'avant la migration malgré la seconde instance, puisque l'ancien StatefulSet est parti.

## Exercices

:::exercice[Exercice 1 : la bascule vue par l'application]

Avec `charge.py` (chapitre 50) en marche contre Colis, supprimez le Pod de la primaire de `colis-pg`. Mesurez le temps jusqu'à la promotion, et le nombre de réponses en erreur. Recommencez après avoir fixé `smartShutdownTimeout` à 10 secondes. Expliquez la différence avec la bascule du cluster d'essai.

:::

<details>
<summary>Corrigé</summary>

Les mesures sont dans la section sur l'arrêt intelligent, plus haut : 3 min 4 s avec le réglage par défaut, 17 s avec 10 secondes. Le client d'essai ouvrait une connexion par écriture ; l'API de Colis garde les siennes, et l'arrêt intelligent les laisse travailler jusqu'au bout du délai. Dans les deux cas, l'API n'a renvoyé que une ou deux réponses 5xx : le code de Colis abandonne une connexion perdue, en ouvre une neuve à la requête suivante, et rejoue une fois les lectures. Réduire `smartShutdownTimeout` raccourcit la bascule subie ; la vraie réponse reste de ne pas supprimer la primaire, mais de demander une bascule programmée avant toute intervention.

</details>

:::exercice[Exercice 2 : une sauvegarde par jour]

Écrivez une `ScheduledBackup` qui fait une sauvegarde complète de `colis-pg` chaque jour à 2 h. Vérifiez la date de la prochaine sauvegarde dans le journal de l'opérateur (ligne `Next backup schedule`).

:::

<details>
<summary>Corrigé</summary>

```sortie
# kubectl apply -f planifiee-5.yaml      # schedule: "0 2 * * *"
Warning: Schedule parameter may not have the right number of arguments (usually six arguments are needed)
scheduledbackup.postgresql.cnpg.io/quotidienne created
prochaine sauvegarde : 2026-10-09T07:02:00Z
# kubectl apply -f planifiee-6.yaml      # schedule: "0 0 2 * * *"
scheduledbackup.postgresql.cnpg.io/quotidienne created
prochaine sauvegarde : 2026-10-10T02:00:00Z
maintenant : 2026-10-09T06:58:00Z
```

L'expression habituelle de cron, `0 2 * * *`, est acceptée avec un avertissement, et elle est fausse : CloudNativePG lit six champs, le premier pour les secondes[^cron]. `0 2 * * *` y signifie « à la seconde 0 de la minute 2 de chaque heure » : une sauvegarde complète toutes les heures, à 7 h 02, 8 h 02, et ainsi de suite. La bonne écriture est `0 0 2 * * *`. Un CronJob de Kubernetes, lui, attend cinq champs (chapitre 27) : on ne peut pas recopier une expression de l'un à l'autre.

</details>

:::exercice[Exercice 3 : le retard des répliques (programmation)]

Écrivez un script Python qui affiche, pour chaque réplique d'un cluster CloudNativePG, son état, son retard en octets (journaux produits par la primaire et pas encore rejoués) et en temps. Le script trouve la primaire dans le statut du `Cluster`, interroge la vue `pg_stat_replication` par `kubectl exec`, peut répéter la mesure, et sort avec le code 1 si une réplique dépasse un seuil ou s'il en manque une. Testez-le pendant qu'une grosse table est créée sur la primaire.

:::

<details>
<summary>Corrigé</summary>

Le corrigé, `corrige/retard-replication.py`, n'est pas dans l'archive. La requête calcule le retard en octets par `pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)`, et en temps par la colonne `replay_lag`. Pendant la création d'une table de deux millions de lignes :

```sortie
07:58:00  primaire colis-pg-2, 1/1 répliques connectées
    colis-pg-1     streaming  async         0 o    0.00 s
code : 0
07:58:01  primaire colis-pg-2, 1/1 répliques connectées
    colis-pg-1     streaming  async         0 o    0.00 s
07:58:02  primaire colis-pg-2, 1/1 répliques connectées
    colis-pg-1     streaming  async    61.4 Mio    0.05 s  TROP EN RETARD
07:58:03  primaire colis-pg-2, 1/1 répliques connectées
    colis-pg-1     streaming  async    72.0 Kio    0.09 s
07:58:05  primaire colis-pg-2, 1/1 répliques connectées
    colis-pg-1     streaming  async         0 o    0.04 s
07:58:06  primaire colis-pg-2, 1/1 répliques connectées
    colis-pg-1     streaming  async         0 o    0.04 s
07:58:07  primaire colis-pg-2, 1/1 répliques connectées
    colis-pg-1     streaming  async         0 o    0.00 s
07:58:09  primaire colis-pg-2, 1/1 répliques connectées
    colis-pg-1     streaming  async         0 o    0.00 s
07:58:10  primaire colis-pg-2, 1/1 répliques connectées
    colis-pg-1     streaming  async         0 o    0.00 s
code : 1
07:58:10  primaire colis-pg-2, 1/1 répliques connectées
    colis-pg-1     streaming  async         0 o    0.00 s
code : 0
```

La réplique a eu jusqu'à 61 Mio de retard pendant une seconde, puis a rattrapé. En temps, le retard reste sous le dixième de seconde : la mesure en octets voit l'écart que la mesure en temps cache. C'est ce que mesure aussi la métrique `cnpg_pg_replication_lag` de l'exercice suivant, et la seule chose qui compte au moment d'une bascule subie, puisque ce retard est ce qu'on risque de perdre.

</details>

:::exercice[Exercice 4 : les métriques dans Prometheus]

Chaque instance expose des métriques sur son port `metrics` (9187). Faites-les relever par le Prometheus du chapitre 50, puis trouvez dans Prometheus le retard de réplication et la taille de la base `colis`.

:::

<details>
<summary>Corrigé</summary>

Un PodMonitor sur l'étiquette `cnpg.io/cluster`, et la politique réseau `colis-pg` qui laisse entrer le namespace `supervision` sur le port 9187 :

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata: {name: colis-pg, namespace: colis}
spec:
  selector:
    matchLabels: {cnpg.io/cluster: colis-pg}
  podMetricsEndpoints:
  - port: metrics
    interval: 15s
```

```sortie
podmonitor.monitoring.coreos.com/colis-pg created
# up
colis-pg-1  1
colis-pg-2  1
# cnpg_collector_up
colis-pg-1  1
colis-pg-2  1
# cnpg_pg_replication_lag
colis-pg-1  0
colis-pg-2  0
# cnpg_pg_database_size_bytes
colis-pg-1  8869567
colis-pg-2  8869567
# séries exportées par instance
colis-pg-1  427
colis-pg-2  452
```

Plus de 400 séries par instance, dont l'état du collecteur, le retard de chaque réplique, la taille de chaque base. Au premier essai, la nouvelle primaire, promue une minute plus tôt par l'exercice 1, avait `cnpg_collector_up` à 0 et seulement 49 séries : son collecteur échouait encore. Une alerte sur `cnpg_collector_up == 0` doit donc avoir une durée (`for`) de quelques minutes pour ne pas sonner à chaque bascule.

</details>

## Nettoyer

Le namespace d'essai `ch56` a été supprimé à la fin de la démonstration. Le reste sert la suite : l'opérateur, le greffon, RustFS et `colis-pg` sont désormais l'installation de PostgreSQL de Colis. La `ScheduledBackup` et le PodMonitor des exercices peuvent rester. Si vous ne gardez pas la sauvegarde quotidienne, supprimez-la : elle remplirait le volume de RustFS.

```bash
kubectl -n colis delete scheduledbackup quotidienne
```

[^cnpg]: CloudNativePG, dépôt et documentation de la version 1.30.1 ; projet *sandbox* de la Cloud Native Computing Foundation (README). [github.com/cloudnative-pg/cloudnative-pg](https://github.com/cloudnative-pg/cloudnative-pg)
[^barman]: CloudNativePG, greffon Barman Cloud (CNPG-I), version 0.15.1 : sauvegarde et archivage des journaux vers un stockage objet, objet `ObjectStore`. [github.com/cloudnative-pg/plugin-barman-cloud](https://github.com/cloudnative-pg/plugin-barman-cloud)
[^controller]: CloudNativePG, « Custom Pod Controller » et FAQ (« Why isn't CloudNativePG using StatefulSets? ») : volumes gérés directement, redimensionnement, cohérence des volumes d'une instance. [github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.1/docs/src/controller.md](https://github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.1/docs/src/controller.md)
[^instance]: CloudNativePG, « Postgres instance manager » : pas d'outil externe de bascule ; « Shutdown control » : `smartShutdownTimeout` (180 s) et `stopDelay` (1 800 s), arrêt intelligent puis rapide, et la consigne de ne pas supprimer le Pod de la primaire, mais de faire d'abord une bascule programmée. [github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.1/docs/src/instance_manager.md](https://github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.1/docs/src/instance_manager.md)
[^services]: CloudNativePG, « Service management » : Services `rw`, `ro` et `r`. [github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.1/docs/src/service_management.md](https://github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.1/docs/src/service_management.md)
[^rolling]: CloudNativePG, « Rolling Updates » : répliques d'abord, primaire en dernier, par redémarrage ou par bascule programmée. [github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.1/docs/src/rolling_update.md](https://github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.1/docs/src/rolling_update.md)
[^recovery]: CloudNativePG, « Recovery » : reconstruction d'un nouveau cluster depuis un stockage objet, cible de restauration `targetTime`. [github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.1/docs/src/recovery.md](https://github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.1/docs/src/recovery.md)
[^import]: CloudNativePG, « Importing Postgres databases » : type `microservice`, une base importée par `pg_dump` et `pg_restore` dans un cluster neuf. [github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.1/docs/src/database_import.md](https://github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.1/docs/src/database_import.md)
[^cron]: CloudNativePG, « Backup », section « Cron Schedule » : expression à six champs, secondes comprises, au format du paquet Go `cron`. [github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.1/docs/src/backup.md](https://github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.1/docs/src/backup.md)
[^pdb]: CloudNativePG, « Kubernetes Upgrade and Maintenance » : deux PodDisruptionBudgets par cluster, bascule programmée avant le vidage d'un nœud qui porte la primaire. [github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.1/docs/src/kubernetes_upgrade.md](https://github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.1/docs/src/kubernetes_upgrade.md)
