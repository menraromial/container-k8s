---
title: Déboguer
sidebar_label: 48. Déboguer
description: "Une méthode pour passer d'un symptôme à sa cause, couche après couche : la vue d'ensemble, le Service et ses EndpointSlices, describe et les événements, les journaux courants et précédents, les codes de sortie, les conteneurs éphémères pour les images sans shell, les copies de Pods, et le nœud vu de l'intérieur."
partie: 7
chapitre: '48'
---

import diagnosticCouches from '@site/src/figures/diagnostic-couches.svg';
import conteneurEphemere from '@site/src/figures/conteneur-ephemere.svg';

Seize lignes, quinze objets créés, aucun message d'erreur :

```bash
bash installer.sh && kubectl apply -f annuaire.yaml
```

```sortie
namespace/ch48 created
secret/colis-db created
namespace/ch48 unchanged
configmap/colis-config created
deployment.apps/postgres created
service/postgres created
deployment.apps/redis created
service/redis created
deployment.apps/api created
service/api created
deployment.apps/worker created
deployment.apps/web created
service/web created
configmap/annuaire created
deployment.apps/annuaire created
service/annuaire created
```

Une minute plus tard, la page d'accueil répond, mais l'API derrière elle renvoie une erreur 502 :

```bash
kubectl -n ch48 port-forward svc/web 8048:80 &
for chemin in / /api/colis; do
  printf '%-12s %s\n' $chemin "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8048$chemin)"
done
```

```sortie
/            200
/api/colis   502
```

Il n'y a là aucune contradiction. `kubectl apply` ne promet qu'une chose : l'API server a enregistré les objets. Tout ce qui vient ensuite se passe plus tard et ailleurs. Le scheduler place les Pods, le kubelet tire les images et lance les conteneurs, les contrôleurs remplissent les EndpointSlices, l'application lit sa configuration et ouvre ses connexions. Chacun de ces acteurs signale ses échecs à sa manière et à un endroit différent : un événement, un champ de statut, un journal, un fichier sur le nœud. Déboguer dans Kubernetes, c'est savoir où chercher, et dans quel ordre.

Le namespace `ch48` contient une copie de Colis dans laquelle trois erreurs ont été glissées, plus un petit serveur DNS qui a la sienne. Tout est dans [l'archive deboguer](pathname:///kits/deboguer.tar.gz). Si vous voulez vous entraîner pour de bon, lancez `installer.sh` sans lire les manifestes, et cherchez avant de lire la suite.

## Une méthode : une couche à la fois

Devant une panne, la tentation est de relancer, de supprimer le Pod, de réappliquer le manifeste, en espérant que ça passe. Parfois ça passe, et on n'a rien appris. La méthode qui marche est plus lente au départ et beaucoup plus rapide au total : partir du symptôme, puis descendre une couche à la fois, en ne passant à la couche suivante que lorsque celle-ci n'explique pas ce qu'on observe.

<Figure svg={diagnosticCouches} num="48.1" alt="Sept couches empilées, chacune avec sa question et ses commandes. 1, le symptôme : quel code, quel message, pour quelle URL, toujours ou parfois ? curl -v, port-forward, journal du composant d'entrée. 2, les objets : qui n'est pas prêt, qui redémarre, depuis quand ? get deploy,pods -o wide, events --types=Warning. 3, le Service : a-t-il des points d'accès, et sont-ils prêts ? get svc -o wide, get endpointslices. 4, le Pod : placé, démarré, pourquoi le kubelet l'a-t-il tué ou écarté ? describe pod, events --for, .status.containerStatuses. 5, le conteneur : pourquoi le processus s'arrête-t-il, que dit-il avant ? logs, logs --previous, lastState.terminated. 6, l'intérieur du Pod : que voit le processus, DNS, ports, fichiers, variables ? exec, debug éphémère, debug --copy-to. 7, le nœud : que disent le kubelet et le runtime, où sont les fichiers ? debug node, crictl, journalctl -u kubelet. En bas : on ne descend d'une couche que si celle-ci n'explique pas le symptôme.">
Les couches du diagnostic. Chacune a sa question et ses outils ; la plupart des pannes se résolvent dans les cinq premières.
</Figure>

Trois habitudes rendent cette descente efficace. **Noter ce qu'on voit, avec l'heure**, avant de toucher à quoi que ce soit : un Pod supprimé emporte ses journaux, et un événement disparaît au bout d'une heure. **Ne changer qu'une chose à la fois**, puis revérifier le symptôme : deux corrections simultanées, dont l'une casse autre chose, et on ne sait plus laquelle a agi. **Se méfier des messages**, qui disent ce que le programme a cru comprendre, pas forcément ce qui s'est passé. On en verra un exemple trompeur un peu plus loin.

## La vue d'ensemble

Première couche sous le symptôme : l'état des objets. Deux commandes suffisent à savoir où regarder.

```bash
kubectl -n ch48 get deploy
kubectl -n ch48 get pods -o wide
```

```sortie
NAME       READY   UP-TO-DATE   AVAILABLE   AGE
annuaire   1/1     1            1           76s
api        0/1     1            0           76s
postgres   1/1     1            1           77s
redis      1/1     1            1           77s
web        1/1     1            1           76s
worker     0/1     1            0           76s
NAME                        READY   STATUS             RESTARTS      AGE   IP             NODE       NOMINATED NODE   READINESS GATES
annuaire-c5859896c-bczk5    1/1     Running            0             76s   10.244.0.211   minikube   <none>           <none>
api-67f478b5f6-hkfpg        0/1     CrashLoopBackOff   3 (14s ago)   76s   10.244.0.208   minikube   <none>           <none>
postgres-7847c54c4d-vjtl9   1/1     Running            0             77s   10.244.0.206   minikube   <none>           <none>
redis-578785659c-rzzmq      1/1     Running            0             77s   10.244.0.207   minikube   <none>           <none>
web-66df747b46-zvncx        1/1     Running            0             76s   10.244.0.210   minikube   <none>           <none>
worker-59555c986f-wfp5b     0/1     Error              3 (61s ago)   76s   10.244.0.209   minikube   <none>           <none>
```

La colonne `STATUS` n'est pas un champ de l'objet Pod : elle est calculée, pour l'affichage, à partir de l'état des conteneurs. `CrashLoopBackOff` signifie que le conteneur s'est arrêté plusieurs fois et que le kubelet attend avant de le relancer. `Error` signifie qu'il vient de s'arrêter avec un code non nul et que le kubelet n'a pas encore décidé de la suite. Ce sont deux moments du même cycle, et les deux Pods en cause y passent tour à tour. La colonne `RESTARTS` donne le nombre de redémarrages et l'âge du dernier : `3 (14s ago)`.

Le kubelet ne relance pas un conteneur qui échoue à rythme constant. Il double l'attente à chaque échec, de 10 secondes jusqu'à 5 minutes, et remet le compteur à zéro quand le conteneur a tenu 10 minutes sans incident[^cycle]. C'est le *back-off* de `CrashLoopBackOff`. Conséquence pratique : un Pod qui boucle depuis une heure ne redémarre plus que toutes les 5 minutes, et une correction peut mettre ce temps à se voir. Un `kubectl rollout restart`, ou la suppression du Pod, repart d'un compteur neuf.

Deux Pods vont mal, mais le symptôme concerne l'API. On commence par elle, en suivant le chemin d'une requête : `web` relaie `/api/` vers le Service `api`.

## Le Service, le maillon qu'on oublie

Le journal de `web` dit précisément ce qui a échoué :

```bash
kubectl -n ch48 logs deploy/web | grep -v kube-probe | tail -2
```

```sortie
127.0.0.1 - - [07/Oct/2026:22:00:35 +0000] "GET /api/colis HTTP/1.1" 502 157 "-" "curl/8.18.0" "-"
2026/10/07 22:00:35 [error] 46#46: *18 connect() failed (111: Connection refused) while connecting to upstream, client: 127.0.0.1, server: _, request: "GET /api/colis HTTP/1.1", upstream: "http://10.97.59.69:8000/colis", host: "localhost:8048"
```

nginx s'est vu refuser la connexion (`111: Connection refused`) vers `10.97.59.69:8000`, l'adresse virtuelle du Service `api`. Le chapitre 40 a montré ce que fait kube-proxy pour un Service sans point d'accès prêt : une règle qui rejette les connexions. Un refus immédiat sur une adresse de Service veut donc presque toujours dire « aucun Pod derrière ». Vérifions :

```bash
kubectl -n ch48 get svc api -o wide
kubectl -n ch48 get endpointslices -l kubernetes.io/service-name=api
kubectl -n ch48 get pods -l app.kubernetes.io/name=colis-api
kubectl -n ch48 get pods -l app.kubernetes.io/name=api --show-labels
```

```sortie
NAME   TYPE        CLUSTER-IP    EXTERNAL-IP   PORT(S)    AGE   SELECTOR
api    ClusterIP   10.97.59.69   <none>        8000/TCP   77s   app.kubernetes.io/name=colis-api
NAME        ADDRESSTYPE   PORTS     ENDPOINTS   AGE
api-kg8lf   IPv4          <unset>   <unset>     77s
No resources found in ch48 namespace.
NAME                   READY   STATUS             RESTARTS      AGE   LABELS
api-67f478b5f6-hkfpg   0/1     CrashLoopBackOff   3 (15s ago)   77s   app.kubernetes.io/name=api,app.kubernetes.io/part-of=colis,pod-template-hash=67f478b5f6
```

Le Service cherche des Pods étiquetés `app.kubernetes.io/name=colis-api`, et il n'en existe aucun : le Pod de l'API porte `app.kubernetes.io/name=api`. Le contrôleur d'EndpointSlices a donc produit une tranche vide (`<unset>`). Aucun message d'erreur ne le signale nulle part : pour Kubernetes, un Service qui ne sélectionne rien est parfaitement valide. C'est la **première erreur**. Corrigeons le sélecteur, et seulement lui :

```bash
kubectl -n ch48 patch svc api --type=merge -p '{"spec":{"selector":{"app.kubernetes.io/name":"api"}}}'
kubectl -n ch48 get endpointslices -l kubernetes.io/service-name=api
kubectl -n ch48 get endpointslices -l kubernetes.io/service-name=api -o json \
  | jq -c '.items[].endpoints[] | {ip: .addresses[0], conditions}'
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8048/api/colis
```

```sortie
service/api patched
NAME        ADDRESSTYPE   PORTS   ENDPOINTS      AGE
api-kg8lf   IPv4          8000    10.244.0.208   80s
{"ip":"10.244.0.208","conditions":{"ready":false,"serving":false,"terminating":false}}
/api/colis   502
```

Le Pod apparaît dans la tranche, avec `ready: false` : kube-proxy ne lui enverra rien tant qu'il n'est pas prêt, et le 502 reste. Le Service n'explique plus le symptôme à lui seul. On descend d'une couche, vers le Pod.

:::panne[Un Service répond « Connection refused » alors que les Pods tournent]

Comparez le sélecteur du Service (`kubectl get svc X -o wide`) et les étiquettes des Pods (`--show-labels`), puis regardez les EndpointSlices. Tranche vide : le sélecteur ne correspond à rien. Adresses présentes mais `ready: false` : les Pods ne passent pas leur sonde de disponibilité. Adresses prêtes mais connexion refusée quand même : le `targetPort` du Service ne correspond pas au port sur lequel le processus écoute.

:::

## Le Pod : describe et les événements

`kubectl describe pod` rassemble trois sources : la spécification, l'état courant des conteneurs et les événements qui concernent le Pod. Voici les trois morceaux qui comptent ici :

```bash
A=$(kubectl -n ch48 get pods -l app.kubernetes.io/name=api -o name | head -1)
kubectl -n ch48 describe $A
```

```sortie
Containers:
  api:
    Container ID:   containerd://e795d59ad56f57a978b4fc1b0097b6e0e851851f0a84939a9a3945a67c4ea29d
    Image:          host.minikube.internal:5001/colis/api:2.1
    Image ID:       host.minikube.internal:5001/colis/api@sha256:ade99a611b6a907ceacc9deb10f1a7cc21a1f49f7f4395d5d5b5a145205ad3a5
    Port:           8000/TCP (http)
    Host Port:      0/TCP (http)
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Reason:       Error
      Exit Code:    1
      Started:      Wed, 07 Oct 2026 23:00:14 +0100
      Finished:     Wed, 07 Oct 2026 23:00:21 +0100
    Ready:          False
Conditions:
  Type                        Status
  PodReadyToStartContainers   True 
  Initialized                 True 
  Ready                       False 
  ContainersReady             False 
  PodScheduled                True 
Volumes:
Events:
  Type     Reason     Age                 From               Message
  ----     ------     ----                ----               -------
  Normal   Scheduled  81s                 default-scheduler  Successfully assigned ch48/api-67f478b5f6-hkfpg to minikube
  Normal   Pulled     26s (x4 over 81s)   kubelet            spec.containers{api}: Container image "host.minikube.internal:5001/colis/api:2.1" already present on machine and can be accessed by the pod
  Normal   Created    26s (x4 over 81s)   kubelet            spec.containers{api}: Container created
  Normal   Started    26s (x4 over 81s)   kubelet            spec.containers{api}: Container started
  Warning  Unhealthy  19s (x15 over 79s)  kubelet            spec.containers{api}: Startup probe failed: Get "http://10.244.0.208:8000/sante": dial tcp 10.244.0.208:8000: connect: connection refused
  Normal   Killing    19s                 kubelet            spec.containers{api}: Container api failed startup probe, will be restarted
  Warning  BackOff    11s (x9 over 66s)   kubelet            spec.containers{api}: Back-off restarting failed container api in pod api-67f478b5f6-hkfpg_ch48(66ed58ec-b266-414b-a654-1cfce9d30128)
```

À lire de haut en bas. `State: Waiting, CrashLoopBackOff` : le conteneur n'existe pas en ce moment, le kubelet attend. `Last State: Terminated, Error, Exit Code: 1` : la dernière tentative s'est terminée d'elle-même, par une erreur, au bout de sept secondes. Un code 1 vient du programme, pas de Kubernetes : le processus a décidé de s'arrêter. Les conditions confirment que le Pod a été placé (`PodScheduled`), que son bac à sable réseau existe (`PodReadyToStartContainers`) et que ses conteneurs d'initialisation, ici aucun, sont passés (`Initialized`) ; seul `Ready` manque.

Les événements racontent le cycle : l'image est déjà là, le conteneur est créé et démarré quatre fois (`x4 over 81s`), la sonde de démarrage échoue parce que rien n'écoute encore sur le port 8000, puis le kubelet espace les relances (`BackOff`). Attention à l'avertissement `Unhealthy` : il est vrai, mais ce n'est pas la cause. Le processus meurt avant d'avoir ouvert son port, et la sonde ne fait que le constater.

Les événements sont des objets à part entière, qu'on peut lire sans `describe`. `kubectl events` les trie dans l'ordre chronologique, ce que `kubectl get events` ne fait pas, et sait filtrer par objet ou par type :

```bash
kubectl -n ch48 events --types=Warning
```

```sortie
LAST SEEN            TYPE      REASON      OBJECT                          MESSAGE
81s (x2 over 81s)    Warning   Unhealthy   Pod/postgres-7847c54c4d-vjtl9   Readiness probe failed: /var/run/postgresql:5432 - no response
81s                  Warning   Unhealthy   Pod/redis-578785659c-rzzmq      Readiness probe failed: Could not connect to Redis at 127.0.0.1:6379: Connection refused
81s                  Warning   Unhealthy   Pod/web-66df747b46-zvncx        Readiness probe failed: Get "http://10.244.0.210:80/": dial tcp 10.244.0.210:80: connect: connection refused
37s (x3 over 79s)    Warning   BackOff     Pod/worker-59555c986f-wfp5b     Back-off restarting failed container worker in pod worker-59555c986f-wfp5b_ch48(72f6c363-fa4d-453f-a3d6-394b60bd6e29)
19s (x15 over 79s)   Warning   Unhealthy   Pod/api-67f478b5f6-hkfpg        Startup probe failed: Get "http://10.244.0.208:8000/sante": dial tcp 10.244.0.208:8000: connect: connection refused
11s (x9 over 66s)    Warning   BackOff     Pod/api-67f478b5f6-hkfpg        Back-off restarting failed container api in pod api-67f478b5f6-hkfpg_ch48(66ed58ec-b266-414b-a654-1cfce9d30128)
```

Les trois premières lignes sont du bruit normal : au tout premier passage, les sondes de disponibilité de Redis, de PostgreSQL et de nginx arrivent avant que le processus écoute. Elles ne se répètent pas, et c'est ce qui les distingue des deux autres. Quatre propriétés des événements sont à connaître[^events] :

- ils sont **regroupés** : `x15 over 79s` signifie quinze occurrences du même événement, comptées dans un seul objet ;
- ils **expirent** : l'API server les supprime au bout d'une heure par défaut (option `--event-ttl`, absente du manifeste de minikube, donc à sa valeur par défaut) ;
- ils sont **émis au mieux** : sous forte charge, l'émetteur peut en abandonner, et aucun outil ne doit compter dessus pour fonctionner ;
- ils sont **rattachés à un objet** : l'erreur d'un Deployment qui ne peut pas créer ses Pods (quota dépassé, Pod Security) se trouve sur son ReplicaSet, pas sur les Pods, qui n'existent pas. Le chapitre 44 en a donné un exemple.

## Le conteneur : ses journaux et son code de sortie

Le code 1 dit que le programme a choisi de s'arrêter. Ses journaux disent pourquoi :

```bash
kubectl -n ch48 logs $A --tail=3
kubectl -n ch48 logs $A --previous --tail=3
kubectl -n ch48 get $A -o jsonpath='{.status.containerStatuses[0].lastState}' | jq .
```

```sortie
(logs)
  File "/opt/venv/lib/python3.14/site-packages/psycopg/_conninfo_attempts.py", line 55, in conninfo_attempts
    raise last_exc
psycopg.OperationalError: failed to resolve host 'base': [Errno -3] Try again
(logs --previous)
  File "/opt/venv/lib/python3.14/site-packages/psycopg/_conninfo_attempts.py", line 55, in conninfo_attempts
    raise last_exc
psycopg.OperationalError: failed to resolve host 'base': [Errno -3] Try again
{
  "terminated": {
    "containerID": "containerd://e795d59ad56f57a978b4fc1b0097b6e0e851851f0a84939a9a3945a67c4ea29d",
    "exitCode": 1,
    "finishedAt": "2026-10-07T22:00:21Z",
    "reason": "Error",
    "startedAt": "2026-10-07T22:00:14Z"
  }
}
```

L'API ne parvient pas à résoudre le nom `base`. Elle essaie de créer son schéma dès le démarrage, échoue, et s'arrête. Avant de corriger, remarquez le libellé : `[Errno -3] Try again`. Il laisse croire à un incident passager, un serveur DNS momentanément injoignable. On verra dans un instant que le nom n'existe tout simplement pas. Le message de la bibliothèque n'est pas un diagnostic.

`kubectl logs` lit le fichier du conteneur le plus récent ; `--previous` celui de l'instance d'avant. Ici, les deux donnent le même texte, parce que chaque tentative échoue de la même façon. Mais `--previous` a une limite, que le Pod du worker montre bien :

```bash
W=$(kubectl -n ch48 get pods -l app.kubernetes.io/name=worker -o name | head -1)
kubectl -n ch48 logs $W --tail=4
kubectl -n ch48 logs $W --previous --tail=4
```

```sortie
(logs)
/opt/venv/bin/python: No module named colis.travailleur
(logs --previous)
unable to retrieve container logs for containerd://c4dc230c145898d96346a8f10fb2ce62cff455ae6bbb3a72b29ec07b3bd38837
```

Le kubelet ne garde qu'**un seul conteneur mort** par conteneur de Pod, et supprime les plus anciens[^gc]. Quand le worker vient de s'arrêter, le conteneur « courant » est celui qui a échoué, et l'instance d'avant a déjà été effacée, avec son journal. Règle pratique : sur un Pod en boucle, commencez par `kubectl logs` tout court. `--previous` sert surtout quand le conteneur a été relancé et tourne de nouveau, après un arrêt pour dépassement de mémoire ou une sonde de vie ratée : le journal intéressant est alors celui de l'instance tuée. Et quand le Pod lui-même est supprimé, tous ses journaux partent avec lui : c'est l'une des raisons d'être des journaux centralisés du chapitre 51.

Le message du worker suffit ici : `No module named colis.travailleur`. On y reviendra, une fois l'API réparée.

### Lire un code de sortie

Le code de sortie est souvent le premier indice, avant même les journaux :

| Code | Ce qu'il signifie |
|---|---|
| 0 | arrêt normal ; dans un Deployment, le kubelet le relance quand même (`restartPolicy: Always`) |
| 1, 2, ou autre petit nombre | choix du programme : lire ses journaux |
| 126 | le fichier existe mais n'est pas exécutable |
| 127 | commande introuvable, d'après le shell |
| 128, raison `StartError` | le runtime n'a pas pu lancer le processus : binaire absent de l'image, montage impossible |
| 128 + n | le processus a été tué par le signal n : 137 pour SIGKILL (9), 143 pour SIGTERM (15) |
| 137, raison `OOMKilled` | tué par le noyau pour avoir dépassé sa limite de mémoire (chapitre 49) |

Un 137 sans `OOMKilled` peut venir d'une sonde de vie ratée (le kubelet tue le conteneur), d'un arrêt qui a dépassé son délai de grâce, ou d'un `kill -9` venu d'ailleurs. L'exercice 2 fait apparaître la plupart de ces codes.

### Laisser un dernier mot

Un conteneur peut écrire une explication courte dans `/dev/termination-log` avant de s'arrêter : le kubelet la recopie dans le statut, où `describe` l'affiche. Avec `terminationMessagePolicy: FallbackToLogsOnError`, le kubelet prend la fin du journal si le fichier est vide et que le conteneur a échoué[^terminaison]. Deux Pods d'essai :

```bash
kubectl -n ch48 run fin-brutale --image=busybox:1.37 --restart=Never --overrides='{"spec":{"containers":[{
  "name":"fin-brutale","image":"busybox:1.37","terminationMessagePolicy":"FallbackToLogsOnError",
  "command":["sh","-c","echo demarrage; echo \"configuration absente : /etc/colis/regles.yaml\" >&2; exit 3"]}]}}'
kubectl -n ch48 run fin-propre --image=busybox:1.37 --restart=Never --overrides='{"spec":{"containers":[{
  "name":"fin-propre","image":"busybox:1.37",
  "command":["sh","-c","echo beaucoup de bruit; echo \"quota epuise pour le client 42\" > /dev/termination-log; exit 4"]}]}}'
for p in fin-brutale fin-propre; do
  kubectl -n ch48 get pod $p -o jsonpath='{.status.containerStatuses[0].state.terminated}' | jq -c '{reason, exitCode, message}'
done
```

```sortie
pod/fin-brutale created
pod/fin-propre created
{"reason":"Error","exitCode":3,"message":"demarrage\nconfiguration absente : /etc/colis/regles.yaml\n"}
{"reason":"Error","exitCode":4,"message":"quota epuise pour le client 42\n"}
```

Le premier a recopié la fin du journal, sortie standard et erreur mêlées ; le second, exactement la phrase choisie, sans le bruit. Le message est limité à 4096 octets par conteneur. Pour une application que vous écrivez, la seconde forme est la plus utile : une ligne qui dit pourquoi, visible dans `kubectl describe` et dans les outils de supervision, même après la disparition du journal.

## Entrer dans le Pod

### Un conteneur éphémère pour vérifier le DNS

`kubectl exec` lance une commande dans un conteneur qui tourne. Celui de l'API ne tourne presque jamais : il meurt au bout de sept secondes. Et même vivant, son image ne contient ni `nslookup` ni `dig`. La réponse de Kubernetes à ces deux problèmes est le **conteneur éphémère** : un conteneur ajouté à un Pod existant, avec l'image de son choix, qui partage l'espace réseau du Pod[^ephemere].

```bash
kubectl -n ch48 debug -i $A --image=busybox:1.37 -c dns -- \
  sh -c 'cat /etc/resolv.conf; echo; nslookup base; nslookup postgres'
```

```sortie
search ch48.svc.cluster.local svc.cluster.local cluster.local home
nameserver 10.96.0.10
options ndots:5

Server:		10.96.0.10
Address:	10.96.0.10:53

** server can't find base.home: NXDOMAIN

** server can't find base.svc.cluster.local: NXDOMAIN

** server can't find base.svc.cluster.local: NXDOMAIN

** server can't find base.cluster.local: NXDOMAIN

** server can't find base.ch48.svc.cluster.local: NXDOMAIN

** server can't find base.ch48.svc.cluster.local: NXDOMAIN

** server can't find base.cluster.local: NXDOMAIN

** server can't find base.home: NXDOMAIN

Server:		10.96.0.10
Address:	10.96.0.10:53

** server can't find postgres.svc.cluster.local: NXDOMAIN

** server can't find postgres.svc.cluster.local: NXDOMAIN

Name:	postgres.ch48.svc.cluster.local
Address: 10.104.192.39

** server can't find postgres.cluster.local: NXDOMAIN


** server can't find postgres.cluster.local: NXDOMAIN

** server can't find postgres.home: NXDOMAIN

** server can't find postgres.home: NXDOMAIN
```

Le fichier `resolv.conf` est celui du Pod, et il explique la longue liste d'échecs. Avec `ndots:5`, un nom de moins de cinq points est d'abord essayé avec chacun des domaines de recherche. `base` devient `base.ch48.svc.cluster.local`, puis `base.svc.cluster.local`, `base.cluster.local` et `base.home`, chacun en IPv4 et en IPv6, d'où les doublons. Le dernier domaine, `home`, ne vient pas de Kubernetes : c'est celui du réseau du poste, transmis au nœud minikube puis aux Pods. Aucun ne répond pour `base`. `postgres`, lui, se résout dès le premier domaine en `postgres.ch48.svc.cluster.local`. C'est la **deuxième erreur** : la chaîne de connexion de l'API vise un hôte `base` qui n'existe pas. Le Service s'appelle `postgres`.

Le conteneur éphémère est maintenant inscrit dans la spécification du Pod, et il y restera :

```bash
kubectl -n ch48 get $A -o jsonpath='{range .spec.ephemeralContainers[*]}{.name} {.image}{"\n"}{end}'
```

```sortie
dns busybox:1.37
```

On ne peut ni le retirer ni le modifier ; il disparaît avec le Pod. Il n'a pas de ports, pas de sondes, pas de ressources réservées. On corrige la variable d'environnement dans le Deployment, ce qui crée de nouveaux Pods sans conteneur éphémère :

```bash
kubectl -n ch48 set env deploy/api 'COLIS_DB=postgresql://colis:$(POSTGRES_PASSWORD)@postgres:5432/colis'
kubectl -n ch48 rollout status deploy/api
curl -s http://localhost:8048/api/pret
curl -s http://localhost:8048/api/colis
```

```sortie
deployment.apps/api env updated
Waiting for deployment "api" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "api" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "api" rollout to finish: 1 old replicas are pending termination...
deployment "api" successfully rolled out
{"stockage":"postgres","file":"redis","pret":true}
[]
```

Les guillemets simples comptent : `$(POSTGRES_PASSWORD)` doit arriver tel quel dans le manifeste, où c'est Kubernetes qui le remplace par la valeur de la variable définie juste avant (chapitre 24). Le symptôme de départ a disparu : `/api/colis` répond, avec une liste encore vide. La descente a trouvé deux erreurs à deux couches différentes, et corriger la première seule n'aurait rien changé au code HTTP. C'est pour cela qu'on revérifie le symptôme après chaque correction, sans conclure trop vite que « ça ne marche toujours pas, donc ce n'était pas ça ».

### Une image sans shell

Le Deployment `annuaire` fait tourner CoreDNS, le logiciel qui sert aussi de DNS au cluster, configuré pour répondre sur une petite zone `colis.interne`. Son image est dite *distroless* : un binaire et des certificats, sans shell ni outils. C'est une bonne pratique de sécurité (rien à exploiter pour qui y entrerait), et un obstacle pour qui débogue. Le Service `annuaire` ne répond pas :

```bash
kubectl -n ch48 run -it --rm essai-dns --image=nicolaka/netshoot:v0.14 --restart=Never -- \
  dig +tries=1 +timeout=2 @annuaire.ch48.svc.cluster.local api.colis.interne
D=$(kubectl -n ch48 get pods -l app.kubernetes.io/name=annuaire -o name | head -1)
kubectl -n ch48 exec $D -- sh
```

```sortie
;; communications error to 10.100.158.99#53: connection refused

; <<>> DiG 9.20.10 <<>> +tries=1 +timeout=2 @annuaire.ch48.svc.cluster.local api.colis.interne
; (1 server found)
;; global options: +cmd
;; no servers could be reached
error: Internal error occurred: Internal error occurred: error executing command in container: failed to exec in container: failed to start exec "e787cb7a89ef8c03f27e69169bd7d2fef092901b3180116ebfa7a5df5b563ac1": OCI runtime exec failed: exec failed: unable to start container process: exec: "sh": executable file not found in $PATH
```

Un refus de connexion, et `exec` impossible. Un conteneur éphémère, cette fois avec `--target`, qui le fait entrer dans l'espace de processus du conteneur visé :

<Figure svg={conteneurEphemere} num="48.2" alt="Le Pod annuaire contient deux bandes partagées et deux conteneurs. L'espace réseau du Pod est toujours partagé : même adresse IP, même localhost, mêmes ports d'écoute, ss -lunp y voit le port 53. L'espace de processus de coredns est partagé grâce à --target=coredns : le conteneur éphémère voit le PID 1, ses arguments, /proc/1/environ. En dessous, le conteneur coredns, image distroless, un binaire et des certificats, pas de shell, PID 1, utilisateur 65532, exec -- sh introuvable ; et le conteneur éphémère enquete, en pointillés, image netshoot avec shell, dig, ss, tcpdump, ajouté au Pod en marche et jamais retiré, sans ports, sondes ni ressources. Une flèche du second vers le premier : il lit les fichiers par /proc/1/root.">
Ce qu'un conteneur éphémère partage avec sa cible. Le réseau est commun à tout le Pod ; les processus, grâce à <code>--target</code> ; les fichiers de la cible restent dans son image, mais on les atteint par <code>/proc/1/root</code>.
</Figure>

```bash
kubectl -n ch48 debug -i $D --image=nicolaka/netshoot:v0.14 --target=coredns -c enquete -- \
  sh -c 'ps -o user,pid,args; echo; ss -lunp; echo; cat /proc/1/root/etc/coredns/Corefile; echo;
         tr "\0" "\n" < /proc/1/environ | grep -v _PORT | head -4'
kubectl -n ch48 get $D -o json | jq -c '.spec.containers[0] | {args, ports}'
```

```sortie
USER     PID   COMMAND
65532        1 /coredns -conf /etc/coredns/Corefile -dns.port 1053
root        29 sh -c ps -o user,pid,args; echo; ss -lunp; echo; cat /proc/1/root/etc/coredns/Corefile; echo; tr "\0" "\n" < /proc/1/environ | grep -v _PORT | head -4
root        35 ps -o user,pid,args

State  Recv-Q Send-Q Local Address:Port Peer Address:PortProcess                        
UNCONN 0      0                  *:53              *:*    users:(("coredns",pid=1,fd=7))

colis.interne:53 {
    file /etc/coredns/colis.interne.zone
    log
    errors
}

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
HOSTNAME=annuaire-c5859896c-bczk5
SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
POSTGRES_SERVICE_HOST=10.104.192.39
{"args":["-conf","/etc/coredns/Corefile","-dns.port","1053"],"ports":[{"containerPort":1053,"name":"dns","protocol":"UDP"}]}
```

La sortie mêle les quatre commandes, dans l'ordre. Le `-i` attache le terminal au conteneur éphémère ; avec `-it` et `-- sh` seul, on obtient un shell interactif, plus commode pour explorer. Tout est là. Le processus `coredns` est le PID 1 et tourne sous l'utilisateur 65532. Il a reçu l'option `-dns.port 1053`, que le Service et le `containerPort` attendent aussi, mais `ss` montre qu'il écoute sur le port **53**. La configuration, lue à travers `/proc/1/root`, donne la raison : le bloc `colis.interne:53` fixe son propre port, qui l'emporte sur l'option de la ligne de commande. C'est l'erreur du serveur DNS. `ss` voit le nom du processus parce que le profil de débogage par défaut, `general`, donne au conteneur éphémère la capability `SYS_PTRACE` ; le même profil permet de lire `/proc/1/root` et `/proc/1/environ` d'un processus qui appartient à un autre utilisateur.

Dans un namespace en `restricted` comme `colis`, ce profil est refusé : il faut `--profile=restricted`, qui retire toutes les capabilities : on voit encore les processus de la cible, mais on ne lit plus les fichiers ni l'environnement d'un processus d'un autre utilisateur (exercice 4 du chapitre 44). Les autres profils, `netadmin` (capabilities réseau, pour `tcpdump`) et `sysadmin` (conteneur privilégié), servent à des cas plus rares, et ne passent que dans des namespaces qui les autorisent.

La correction aligne le Corefile sur le port annoncé. CoreDNS ne relit pas sa configuration sans l'extension `reload`, d'où le redémarrage :

```bash
kubectl -n ch48 get cm annuaire -o json \
  | jq '.data.Corefile |= sub("colis.interne:53"; "colis.interne:1053")' | kubectl apply -f -
kubectl -n ch48 rollout restart deploy/annuaire
kubectl -n ch48 rollout status deploy/annuaire
kubectl -n ch48 run -it --rm essai-dns --image=nicolaka/netshoot:v0.14 --restart=Never -- \
  dig +short @annuaire.ch48.svc.cluster.local api.colis.interne
```

```sortie
configmap/annuaire configured
deployment.apps/annuaire restarted
Waiting for deployment "annuaire" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "annuaire" rollout to finish: 1 old replicas are pending termination...
deployment "annuaire" successfully rolled out
10.0.0.10
```

Le nouveau Pod n'a pas de conteneur éphémère : c'est le seul moyen de s'en débarrasser.

### Une copie du Pod pour comprendre un plantage immédiat

Reste le worker, qui meurt en une fraction de seconde : `No module named colis.travailleur`. Un conteneur éphémère n'aiderait pas beaucoup, puisqu'il n'y a presque jamais de processus à observer. `kubectl debug --copy-to` crée une **copie** du Pod, avec des modifications : ici, la même image et le même environnement, mais une commande qui ne fait qu'attendre. On peut alors explorer à loisir l'image dans les conditions exactes du Pod :

```bash
kubectl -n ch48 debug $W --copy-to=worker-enquete --container=worker -- sleep 3600
kubectl -n ch48 wait --for=condition=Ready pod/worker-enquete
kubectl -n ch48 exec worker-enquete -c worker -- ls /app/colis
kubectl -n ch48 exec worker-enquete -c worker -- python -c 'import colis.worker; print("colis.worker : ok")'
kubectl -n ch48 get pod worker-enquete -o json | jq -c '{labels: .metadata.labels, owner: .metadata.ownerReferences}'
kubectl -n ch48 delete pod worker-enquete
```

```sortie
pod/worker-enquete condition met
__init__.py
app.py
config.py
delais.py
file.py
modele.py
purge.py
stockage.py
worker.py
colis.worker : ok
{"labels":null,"owner":null}
pod "worker-enquete" deleted from ch48 namespace
```

Le module s'appelle `worker`, pas `travailleur`. C'est la **troisième erreur**, dans la commande du Deployment. La copie n'a ni étiquettes ni propriétaire : aucun Service ne lui envoie de trafic, aucun ReplicaSet ne la gère, et personne ne la supprimera à votre place. Les options `--keep-labels`, `--keep-readiness` et voisines changent ce comportement ; l'exercice 4 montre un piège qu'elles ne couvrent pas.

```bash
kubectl -n ch48 patch deploy worker --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/command/2","value":"colis.worker"}]'
kubectl -n ch48 rollout status deploy/worker
curl -s -X POST http://localhost:8048/api/colis -H 'Content-Type: application/json' \
  -d '{"destinataire":"Atelier Brun","depart":"Paris","arrivee":"Lyon","poids_kg":2.5}' | jq -c '{id, statut}'
kubectl -n ch48 logs deploy/worker --tail=2
kubectl -n ch48 get pods
```

```sortie
deployment.apps/worker patched
Waiting for deployment "worker" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "worker" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "worker" rollout to finish: 1 old replicas are pending termination...
deployment "worker" successfully rolled out
{"id":1,"statut":"enregistré"}
worker worker-5d589695d-7t4xq prêt (stockage : postgres)
colis 1 : Paris -> Lyon, 3 jours, livraison estimée le 2026-10-10
NAME                        READY   STATUS    RESTARTS   AGE
annuaire-c5859896c-bczk5    1/1     Running   0          98s
api-64797c77f4-zjmdx        1/1     Running   0          15s
postgres-7847c54c4d-vjtl9   1/1     Running   0          99s
redis-578785659c-rzzmq      1/1     Running   0          99s
web-66df747b46-zvncx        1/1     Running   0          98s
worker-5d589695d-7t4xq      1/1     Running   0          5s
```

Le colis est enregistré par l'API, pris dans la file par le worker, et sa date de livraison calculée. Tout est prêt.

## Descendre sur le nœud

Les six premières couches se traversent avec l'API. La dernière demande d'aller voir le nœud : ce que le kubelet a fait, ce que le runtime contient, où sont les fichiers. Sur un vrai cluster, on n'a pas toujours d'accès SSH aux nœuds, et c'est tant mieux. `kubectl debug node/` crée un Pod sur le nœud choisi, dans les espaces de noms de l'hôte, avec le système de fichiers du nœud monté sous `/host`. Avec le profil `sysadmin`, ce Pod est privilégié, et `chroot /host` donne un shell du nœud. Voici ce qu'on y voyait pendant que le worker bouclait encore :

```bash
kubectl debug node/minikube -it --image=busybox:1.37 --profile=sysadmin -- chroot /host sh
# sur le nœud :
crictl ps -a --name worker | cut -c1-110
ls /var/log/pods | grep ^ch48_
ls -l /var/log/pods/ch48_worker-*/worker/
cat /var/log/pods/ch48_worker-*/worker/*.log
journalctl -u kubelet --since -15min | grep -i back-off | grep -m2 worker
grep containerLog /var/lib/kubelet/config.yaml || echo '(containerLogMaxSize non réglé : 10Mi par défaut)'
```

```sortie
CONTAINER           IMAGE               CREATED             STATE               NAME                ATTEMPT   
3006fe8c50c64       9de9241b800e6       45 seconds ago      Exited              worker              3         

ch48_annuaire-c5859896c-bczk5_1f2d0bde-8660-49e0-91c2-42387580031e
ch48_api-64797c77f4-zjmdx_d0808e09-3768-4f1f-b88d-b0898d582022
ch48_api-67f478b5f6-hkfpg_66ed58ec-b266-414b-a654-1cfce9d30128
ch48_postgres-7847c54c4d-vjtl9_3fb51036-294c-4c24-ae9d-95488008ad0d
ch48_redis-578785659c-rzzmq_94b9fa3a-696f-4d14-bdab-f0a01159cdaa
ch48_web-66df747b46-zvncx_ff0492fe-cbcf-4af7-a698-f706e57570a4
ch48_worker-59555c986f-wfp5b_72f6c363-fa4d-453f-a3d6-394b60bd6e29

total 4
-rw-r----- 1 root root 95 Oct  7 22:00 3.log

2026-10-07T22:00:02.42177864Z stderr F /opt/venv/bin/python: No module named colis.travailleur

Oct 07 21:59:21 minikube kubelet[163154]: E1007 21:59:21.810494  163154 pod_workers.go:1338] "Error syncing pod, skipping" err="failed to \"StartContainer\" for \"worker\" with CrashLoopBackOff: \"back-off 10s restarting failed container=worker pod=worker-59555c986f-wfp5b_ch48(72f6c363-fa4d-453f-a3d6-394b60bd6e29)\"" pod="ch48/worker-59555c986f-wfp5b" podUID="72f6c363-fa4d-453f-a3d6-394b60bd6e29"
Oct 07 21:59:34 minikube kubelet[163154]: E1007 21:59:34.903880  163154 pod_workers.go:1338] "Error syncing pod, skipping" err="failed to \"StartContainer\" for \"worker\" with CrashLoopBackOff: \"back-off 20s restarting failed container=worker pod=worker-59555c986f-wfp5b_ch48(72f6c363-fa4d-453f-a3d6-394b60bd6e29)\"" pod="ch48/worker-59555c986f-wfp5b" podUID="72f6c363-fa4d-453f-a3d6-394b60bd6e29"

(containerLogMaxSize non réglé : 10Mi par défaut)
```

`crictl` parle directement au runtime, sans passer par l'API : il ne montre qu'un conteneur `worker` arrêté, la quatrième tentative (`ATTEMPT 3`, en comptant à partir de 0). Les précédentes ont déjà été supprimées, ce qui confirme ce qu'on a vu avec `--previous`. Les journaux des conteneurs sont des fichiers, rangés par `namespace_pod_uid/conteneur/tentative.log`, au format du CRI : horodatage, flux (`stdout` ou `stderr`), `F` pour une ligne complète (`P` pour un morceau de ligne longue), puis le texte. C'est ce fichier que lit `kubectl logs`, par l'intermédiaire du kubelet. Le kubelet le fait tourner à 10 Mio et garde 5 fichiers par défaut (`containerLogMaxSize`, `containerLogMaxFiles`)[^journaux]. Son propre journal montre l'attente qui double : 10 s, puis 20 s.

Le Pod de débogage reste après la session, dans le namespace courant (`default` ici) : supprimez-le (`kubectl get pods` le montre sous le nom `node-debugger-minikube-…`).

Le kubelet peut aussi servir les journaux du nœud par l'API, sans Pod privilégié. Le chemin `/api/v1/nodes/<nœud>/proxy/logs/` liste les fichiers de `/var/log` ; pour interroger le journal système, il faut activer `enableSystemLogQuery` dans la configuration du kubelet[^logquery]. minikube ne le fait pas ; on peut l'ajouter (le réglage disparaît au prochain `minikube start`, qui réécrit le fichier) :

```bash
kubectl get --raw "/api/v1/nodes/minikube/proxy/logs/" | sed -n 's/.*href="\([^"]*\)".*/\1/p'
minikube ssh -- 'sudo grep -q enableSystemLogQuery /var/lib/kubelet/config.yaml \
  || echo "enableSystemLogQuery: true" | sudo tee -a /var/lib/kubelet/config.yaml; sudo systemctl restart kubelet'
kubectl get --raw "/api/v1/nodes/minikube/proxy/logs/?query=kubelet&pattern=back-off.*worker&tailLines=3" | cut -c1-260
```

```sortie
alternatives.log
containers/
pods/
Oct 07 22:00:03.086605 minikube kubelet[163154]: E1007 22:00:03.086580  163154 pod_workers.go:1338] "Error syncing pod, skipping" err="failed to \"StartContainer\" for \"worker\" with CrashLoopBackOff: \"back-off 40s restarting failed container=worker pod=work
Oct 07 21:59:34.903904 minikube kubelet[163154]: E1007 21:59:34.903880  163154 pod_workers.go:1338] "Error syncing pod, skipping" err="failed to \"StartContainer\" for \"worker\" with CrashLoopBackOff: \"back-off 20s restarting failed container=worker pod=work
Oct 07 21:59:21.810524 minikube kubelet[163154]: E1007 21:59:21.810494  163154 pod_workers.go:1338] "Error syncing pod, skipping" err="failed to \"StartContainer\" for \"worker\" with CrashLoopBackOff: \"back-off 10s restarting failed container=worker pod=work
```

Cet accès passe par la sous-ressource `nodes/proxy`, que le chapitre 43 a rangée parmi les permissions sensibles : ne la donnez qu'aux administrateurs du cluster.

## Ce que la descente a trouvé

| Symptôme observé | Couche | Outil décisif | Cause | Correction |
|---|---|---|---|---|
| 502, `Connection refused` vers l'adresse du Service | Service | `get endpointslices`, `--show-labels` | sélecteur `colis-api` au lieu de `api` | `patch svc` |
| point d'accès `ready: false`, `CrashLoopBackOff`, code 1 | conteneur, puis intérieur du Pod | `logs`, conteneur éphémère avec `nslookup` | hôte `base` au lieu de `postgres` | `set env` |
| `Error` en boucle, pas de processus à observer | conteneur, puis copie | `logs`, `debug --copy-to` | module `colis.travailleur` inexistant | `patch deploy` |
| DNS refusé, image sans shell | intérieur du Pod | conteneur éphémère avec `--target`, `ss` | port 53 imposé par le Corefile | ConfigMap et redémarrage |

Aucune de ces erreurs n'a produit de message clair à l'endroit où on l'aurait cherchée en premier. Le sélecteur faux est silencieux, le DNS se présente comme un incident passager, le module manquant tue le conteneur avant qu'on puisse y entrer, et le port d'écoute ne correspond pas à ce qu'annonce le manifeste. C'est le cas général, et la raison d'être de la méthode. Le chapitre 49 en fait un catalogue : les pannes qu'on rencontre le plus souvent, reproduites une à une, avec leur signature et leur correction.

## Exercices

:::exercice[Exercice 1 : le journal disparu]

Réinstallez la copie cassée (`installer.sh` dans un namespace neuf), attendez que le worker ait redémarré au moins trois fois, puis lancez `kubectl logs --previous` sur son Pod à plusieurs moments : juste après un arrêt (`STATUS` à `Error`) et pendant l'attente (`CrashLoopBackOff`). Quand obtenez-vous un journal, quand une erreur ? Comment l'expliquer ? Proposez une façon de ne plus jamais perdre ces journaux.

:::

<details>
<summary>Corrigé</summary>

Le kubelet n'a, à chaque instant, qu'un seul conteneur mort à proposer pour le worker. Juste après un arrêt, le conteneur « courant » est précisément ce conteneur mort : `kubectl logs` l'affiche, et `--previous` demande l'instance d'avant, déjà effacée, d'où le message `unable to retrieve container logs for containerd://…`. Le résultat de `--previous` dépend donc du moment exact, et du passage du ramasse-miettes du kubelet, qui s'exécute toutes les minutes. Le rejeu l'a obtenu ainsi :

```sortie
(logs)
/opt/venv/bin/python: No module named colis.travailleur
(logs --previous)
unable to retrieve container logs for containerd://c4dc230c145898d96346a8f10fb2ce62cff455ae6bbb3a72b29ec07b3bd38837
```

Ce que `--previous` garantit : quand un conteneur a été relancé et tourne de nouveau, l'instance qui a échoué reste lisible jusqu'au prochain arrêt. Pour ne plus rien perdre, il faut que les journaux quittent le nœud au fil de l'eau : un agent sur chaque nœud lit `/var/log/pods/` et les envoie vers un stockage central. C'est le sujet du chapitre 51 (Loki). À défaut, `terminationMessagePolicy: FallbackToLogsOnError` conserve la fin du journal dans le statut du Pod, tant que le Pod existe.

</details>

:::exercice[Exercice 2 : six codes de sortie]

Prévoyez la raison (`reason`) et le code de sortie de chacun de ces Pods, puis vérifiez :

```bash
kubectl -n ch48 run code-faute   --image=busybox:1.37 --restart=Never -- sh -c 'comand-introuvable'
kubectl -n ch48 run code-droits  --image=busybox:1.37 --restart=Never -- sh -c '/etc/passwd'
kubectl -n ch48 run code-binaire --image=busybox:1.37 --restart=Never --command -- /bin/introuvable
kubectl -n ch48 run code-dollar  --image=busybox:1.37 --restart=Never -- sh -c 'kill -KILL $$'
kubectl -n ch48 run code-pid1    --image=busybox:1.37 --restart=Never -- sh -c 'kill -KILL $$$$; echo "PID $$$$ toujours là, statut de kill : $?"'
kubectl -n ch48 run code-enfant  --image=busybox:1.37 --restart=Never -- sh -c 'sh -c "kill -KILL \$$$$"; echo "le shell enfant a fini avec le statut $?"; exit 137'
```

Deux d'entre eux surprennent. Expliquez-les avec leurs journaux.

:::

<details>
<summary>Corrigé</summary>

```bash
for nom in faute droits binaire pid1 enfant dollar; do
  printf '%-13s ' code-$nom
  kubectl -n ch48 get pod code-$nom -o jsonpath='{.status.containerStatuses[0].state.terminated}' | jq -c '{reason, exitCode}'
done
for nom in pid1 enfant dollar; do echo "\$ logs code-$nom"; kubectl -n ch48 logs code-$nom; done
```

```sortie
code-faute    {"reason":"Error","exitCode":127}
code-droits   {"reason":"Error","exitCode":126}
code-binaire  {"reason":"StartError","exitCode":128}
code-pid1     {"reason":"Completed","exitCode":0}
code-enfant   {"reason":"Error","exitCode":137}
code-dollar   {"reason":"Error","exitCode":1}
$ logs code-pid1
PID 1 toujours là, statut de kill : 0
$ logs code-enfant
Killed
le shell enfant a fini avec le statut 137
$ logs code-dollar
sh: invalid number '$'
```

Les trois premiers suivent le tableau : 127 quand le shell ne trouve pas la commande, 126 quand le fichier existe sans être exécutable, et `StartError` avec 128 quand c'est le runtime qui ne trouve pas le binaire, avant même qu'un processus existe. Le message complet de runc est dans le statut (`message`).

Première surprise, `code-dollar` : `sh: invalid number '$'`. Kubernetes remplace `$(VAR)` dans les commandes et les arguments des conteneurs, et `$$` est la façon d'écrire un `$` littéral[^dollar]. `$$` est donc arrivé au shell sous la forme `$`. Pour qu'un shell reçoive `$$`, il faut écrire `$$$$` dans le manifeste, comme dans les deux Pods suivants.

Seconde surprise, `code-pid1` : `kill -KILL` sur lui-même réussit (statut 0), et le shell continue. Le shell est le PID 1 de son espace de processus, et le noyau ne lui livre, depuis son propre espace, que les signaux pour lesquels il a installé un gestionnaire ; SIGKILL n'en admet aucun, il est donc ignoré[^pid1]. C'est la règle qui faisait attendre `docker stop` dix secondes aux chapitres 2 et 4. Le Pod se termine normalement : `Completed`, code 0. Dans `code-enfant`, le shell enfant n'est pas PID 1 : SIGKILL le tue (`Killed`, statut 137), et le shell parent sort avec 137, ce qui donne le code du Pod. La raison reste `Error` : seul le noyau, par le gestionnaire de mémoire, produit `OOMKilled`.

Le script de l'exercice 3 donne une piste pour chacun de ceux qui ont échoué (`code-pid1`, terminé avec succès, n'y figure pas) :

```sortie
ch48/code-binaire [code-binaire]  arrêté : StartError (128), 0 redémarrage(s)
    piste : le runtime n'a pas pu démarrer le conteneur (commande, montage)
ch48/code-dollar [code-dollar]  arrêté : Error (1), 0 redémarrage(s)
    piste : erreur de l'application : lire les journaux
ch48/code-droits [code-droits]  arrêté : Error (126), 0 redémarrage(s)
    piste : fichier trouvé mais non exécutable
ch48/code-enfant [code-enfant]  arrêté : Error (137), 0 redémarrage(s)
    piste : tué par SIGKILL (OOM, sonde de vie, ou kill)
ch48/code-faute [code-faute]  arrêté : Error (127), 0 redémarrage(s)
    piste : commande introuvable (dans le shell)
```

</details>

:::exercice[Exercice 3 : un résumé des Pods en panne (programmation)]

Écrivez un script Python qui lit `kubectl get pods -o json` et `kubectl get events -o json` (un namespace en argument, sinon tous) et affiche, pour chaque conteneur qui n'est pas prêt : son état courant, son nombre de redémarrages, la raison et le code de son dernier arrêt, une piste déduite du code ou de la raison, et le dernier avertissement émis sur son Pod. Les Pods terminés avec succès sont ignorés. Essayez-le sur la copie cassée, avant toute correction.

:::

<details>
<summary>Corrigé</summary>

Le corrigé, `corrige/etat-pods.py`, n'est pas dans l'archive. Sa logique tient en trois parties :

```python
PISTES = {1: "erreur de l'application : lire les journaux", 126: "fichier trouvé mais non exécutable",
          127: "commande introuvable (dans le shell)", 128: "le runtime n'a pas pu lancer le processus"}

def piste(code, raison):
    if raison in RAISONS:                 # OOMKilled, StartError, ImagePullBackOff...
        return RAISONS[raison]
    if code in PISTES:
        return PISTES[code]
    if code > 128:                        # tué par un signal : on retrouve son nom
        return f"tué par {signal.Signals(code - 128).name}"
    return "code propre à l'application"

# le dernier avertissement de chaque Pod, d'après lastTimestamp
for ev in kubectl("get", "events", *portee)["items"]:
    if ev.get("type") == "Warning" and ev["involvedObject"].get("kind") == "Pod":
        ...
# pour chaque conteneur non prêt : state, restartCount, lastState.terminated, piste, avertissement
```

Sur la copie cassée, juste après l'installation :

```sortie
ch48/api-67f478b5f6-hkfpg [api]  attend : CrashLoopBackOff, 3 redémarrage(s), dernier arrêt : Error (1)
    piste : erreur de l'application : lire les journaux
    dernier avertissement : BackOff : Back-off restarting failed container api in pod api-67f478b5f6-hkfpg_ch48(66ed58ec-b266-414b-a654-1cfce9d30128
ch48/worker-59555c986f-wfp5b [worker]  arrêté : Error (1), 3 redémarrage(s), dernier arrêt : Error (1)
    piste : erreur de l'application : lire les journaux
    dernier avertissement : BackOff : Back-off restarting failed container worker in pod worker-59555c986f-wfp5b_ch48(72f6c363-fa4d-453f-a3d6-394b60
```

Deux détails comptent. Un conteneur en `CrashLoopBackOff` n'a pas d'état `terminated` courant : la raison et le code sont dans `lastState`. Un Pod sans aucun `containerStatuses` (en attente de placement, image en cours de téléchargement) doit être traité à part, par ses conditions : le chapitre 49 en donne plusieurs exemples. Le script ne remplace pas la lecture des journaux : il dit par où commencer.

</details>

:::exercice[Exercice 4 : la copie qui disparaît]

Vous voulez essayer une autre version de l'image `web` derrière le même Service, sans toucher au Deployment. Première idée :

```bash
WEB=$(kubectl -n ch48 get pods -l app.kubernetes.io/name=web -o name | head -1)
kubectl -n ch48 debug $WEB --copy-to=web-essai --set-image=web=host.minikube.internal:5001/colis/web:1.1
kubectl -n ch48 get pod web-essai
```

La copie n'existe déjà plus. Que s'est-il passé ? Trouvez une façon d'obtenir une copie qui survive **et** reçoive du trafic du Service.

:::

<details>
<summary>Corrigé</summary>

```bash
kubectl -n ch48 get rs -l app.kubernetes.io/name=web -o jsonpath='{.items[0].spec.selector.matchLabels}'
kubectl -n ch48 get svc web -o jsonpath='{.spec.selector}'
kubectl -n ch48 get events --field-selector reason=SuccessfulDelete \
  -o custom-columns=OBJET:.involvedObject.name,MESSAGE:.message | grep -e OBJET -e essai
```

```sortie
{"app.kubernetes.io/name":"web","pod-template-hash":"66df747b46"}
{"app.kubernetes.io/name":"web"}
OBJET                MESSAGE
web-66df747b46       Deleted pod: web-essai
```

Quand on ne fait que changer d'image (`--set-image` seul), `kubectl debug` garde les étiquettes du Pod d'origine, malgré la valeur par défaut `--keep-labels=false` : ce chemin du code renvoie la copie avant d'appliquer le profil de débogage, qui est l'étape où les étiquettes, les sondes et le reste sont retirés[^kubectldebug]. La copie porte donc `pod-template-hash`, et correspond exactement au sélecteur du ReplicaSet. Le ReplicaSet l'**adopte** (il en devient propriétaire), compte deux Pods pour une réplique demandée, et supprime le plus récent : la copie.

La solution : passer par le chemin qui modifie un conteneur, qui retire les étiquettes, puis n'ajouter que celle que le Service sélectionne. Sans `pod-template-hash`, le ReplicaSet ne la reconnaît pas.

```bash
kubectl -n ch48 debug $WEB --copy-to=web-essai --container=web \
  --image=host.minikube.internal:5001/colis/web:1.1 --keep-readiness
kubectl -n ch48 get pod web-essai -o json | jq -c '{labels: .metadata.labels, owner: .metadata.ownerReferences,
  securityContext: .spec.containers[0].securityContext, readiness: (.spec.containers[0].readinessProbe != null)}'
kubectl -n ch48 label pod web-essai app.kubernetes.io/name=web
kubectl -n ch48 get endpointslices -l kubernetes.io/service-name=web -o json \
  | jq -r '.items[].endpoints[] | "\(.targetRef.name) \(.addresses[0]) prêt=\(.conditions.ready)"'
```

```sortie
{"labels":null,"owner":null,"securityContext":{"capabilities":{"add":["SYS_PTRACE"]}},"readiness":true}
pod/web-essai labeled
web-66df747b46-zvncx 10.244.0.210 prêt=true
web-essai 10.244.0.226 prêt=true
```

La copie reçoit maintenant sa part du trafic. Deux remarques. Le profil `general` a ajouté `SYS_PTRACE` au conteneur `web` de la copie : ce n'est pas tout à fait la configuration de production. Et `--keep-readiness` garde la sonde de disponibilité ; sans elle, la copie serait déclarée prête dès son démarrage et recevrait des requêtes avant que nginx écoute. Supprimez-la à la main quand l'essai est fini : rien ne le fera pour vous. Pour un vrai essai de version en production, on préfère un Deployment séparé derrière le même Service, ou les déploiements progressifs du chapitre 58.

</details>

## Nettoyer

```bash
kubectl delete namespace ch48
kubectl get pods -n default -o name | grep node-debugger    # Pods de debug node/ restés en place
```

Le réglage `enableSystemLogQuery` disparaît au prochain `minikube start`. La copie cassée de Colis ne sert pas à la suite : le chapitre 49 installe ses propres pannes.

[^cycle]: Kubernetes, « Pod Lifecycle », section « Container restarts » : délai de redémarrage exponentiel de 10 secondes, doublé à chaque échec jusqu'à 300 secondes, remis à zéro après 10 minutes sans incident ; états `Waiting`, `Running` et `Terminated` des conteneurs. [kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/)
[^events]: Kubernetes, « Event » (référence de l'API events.k8s.io/v1) : objets à durée limitée, agrégation par `series`, émission au mieux, à ne pas utiliser pour l'automatisation ; option `--event-ttl` de kube-apiserver, valeur par défaut `1h0m0s`. [kubernetes.io/docs/reference/kubernetes-api/cluster-resources/event-v1](https://kubernetes.io/docs/reference/kubernetes-api/cluster-resources/event-v1/) et [kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/)
[^gc]: Kubernetes, « Garbage Collection », section « Containers and images » : `MaxPerPodContainer`, nombre maximal de conteneurs morts conservés par conteneur de Pod, 1 par défaut, et `MaxContainers`. [kubernetes.io/docs/concepts/architecture/garbage-collection](https://kubernetes.io/docs/concepts/architecture/garbage-collection/)
[^terminaison]: Kubernetes, « Determine the Reason for Pod Failure » : `terminationMessagePath` (par défaut `/dev/termination-log`), `terminationMessagePolicy: FallbackToLogsOnError` (les 2048 derniers octets ou 80 dernières lignes du journal), message limité à 4096 octets par conteneur et 12 Kio par Pod. [kubernetes.io/docs/tasks/debug/debug-application/determine-reason-pod-failure](https://kubernetes.io/docs/tasks/debug/debug-application/determine-reason-pod-failure/)
[^ephemere]: Kubernetes, « Ephemeral Containers » (stables depuis 1.25 : ajoutés par la sous-ressource `ephemeralcontainers`, impossibles à retirer ou modifier, sans ports, sondes ni ressources, `targetContainerName` pour partager l'espace de processus) et « Debug Running Pods » (`kubectl debug`, `--copy-to`, `--set-image`, profils `general`, `baseline`, `restricted`, `netadmin`, `sysadmin`, débogage d'un nœud). [kubernetes.io/docs/concepts/workloads/pods/ephemeral-containers](https://kubernetes.io/docs/concepts/workloads/pods/ephemeral-containers/) et [kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod](https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/)
[^journaux]: Kubernetes, « Logging Architecture » : fichiers sous `/var/log/pods`, rotation par le kubelet, `containerLogMaxSize` (10 Mio) et `containerLogMaxFiles` (5) par défaut, `kubectl logs` limité au dernier fichier. [kubernetes.io/docs/concepts/cluster-administration/logging](https://kubernetes.io/docs/concepts/cluster-administration/logging/)
[^logquery]: Kubernetes, « System Logs », section « Log query » : porte de fonctionnalité `NodeLogQuery`, réglage `enableSystemLogQuery` du kubelet, paramètres `query`, `pattern`, `sinceTime`, `tailLines`. [kubernetes.io/docs/concepts/cluster-administration/system-logs](https://kubernetes.io/docs/concepts/cluster-administration/system-logs/)
[^dollar]: Kubernetes, « Define a Command and Arguments for a Container » et « Define Dependent Environment Variables » : les références `$(VAR_NAME)` sont remplacées, `$$` produit un `$` littéral. [kubernetes.io/docs/tasks/inject-data-application/define-interdependent-environment-variables](https://kubernetes.io/docs/tasks/inject-data-application/define-interdependent-environment-variables/)
[^kubectldebug]: kubectl, `pkg/cmd/debug/debug.go`, fonction `generatePodCopyWithDebugContainer` : la copie reprend étiquettes et annotations, et une invocation avec `--set-image` seul (« This was a --set-image only invocation ») renvoie la copie avant l'application du profil, qui retire étiquettes et sondes selon `--keep-labels`, `--keep-readiness`, etc. [github.com/kubernetes/kubectl/blob/master/pkg/cmd/debug/debug.go](https://github.com/kubernetes/kubectl/blob/master/pkg/cmd/debug/debug.go)
[^pid1]: Linux, page de manuel `pid_namespaces(7)` : le processus « init » d'un espace de PID ne reçoit, depuis son propre espace, que les signaux pour lesquels il a établi un gestionnaire ; SIGKILL et SIGSTOP envoyés par un processus de l'espace sont ignorés. [man7.org/linux/man-pages/man7/pid_namespaces.7.html](https://man7.org/linux/man-pages/man7/pid_namespaces.7.html)
