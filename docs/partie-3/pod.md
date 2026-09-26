---
title: Le Pod
sidebar_label: 17. Le Pod
description: "L'unité de base de Kubernetes : son premier manifeste, ses phases et ses conditions, les états de ses conteneurs, les politiques de redémarrage et le recul exponentiel, les Pods à plusieurs conteneurs, les init containers et les sidecars natifs."
partie: 3
chapitre: '17'
---

import cyclePod from '@site/src/figures/cycle-pod.svg';
import reculCrash from '@site/src/figures/recul-crash.svg';
import anatomiePod from '@site/src/figures/anatomie-pod.svg';

Le statut le plus redouté de Kubernetes tient en un mot : `CrashLoopBackOff`. On le rencontre dès la première semaine, sur un Pod qui affiche `RESTARTS 6` et qu'on n'arrive pas à « réparer ». Pour le comprendre, et pour lire tous les autres (`Pending`, `ImagePullBackOff`, `Init:0/1`, `Completed`), il faut savoir ce qu'est un Pod, par quelles étapes il passe et qui décide de le relancer.

Le chapitre 15 a défini le **Pod** comme l'unité de base de Kubernetes : un ou plusieurs conteneurs lancés ensemble sur un même nœud, qui partagent une adresse IP. On ne lance jamais un conteneur seul dans Kubernetes ; on lance un Pod qui en contient un ou plusieurs. Ce chapitre écrit ses premiers manifestes, les lance, et les fait échouer de toutes les manières courantes.

Les manifestes de ce chapitre sont dans [l'archive pods](pathname:///kits/pods.tar.gz). Créez un namespace de travail :

```bash
kubectl create namespace ch17
kubectl config set-context --current --namespace=ch17
```

## Un premier manifeste

Jusqu'ici, `kubectl create deployment` fabriquait les objets à notre place. Un **manifeste** décrit un objet dans un fichier YAML, qu'on envoie à l'API server avec `kubectl apply -f`. Le chapitre 18 étudiera cette façon de travailler ; pour l'instant, retenez qu'un manifeste a toujours les quatre parties vues au chapitre 16 : `apiVersion`, `kind`, `metadata`, `spec`. Voici le Pod le plus simple :

```yaml title="simple.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: simple
  labels:
    app: simple
spec:
  containers:
  - name: nginx
    image: nginx:1.30-alpine
    ports:
    - containerPort: 80
```

Un Pod appartient au groupe principal (`v1`). Sa `spec` contient une liste de conteneurs, chacun avec un nom, unique dans le Pod, et une image. `ports` est purement déclaratif, comme `EXPOSE` dans un Dockerfile (chapitre 4) : il documente le port, sans rien ouvrir. Envoyons-le, et regardons-le démarrer :

```bash
kubectl apply -f simple.yaml
kubectl get pod simple -o wide --watch
```

```sortie
pod/simple created
NAME     READY   STATUS              RESTARTS   AGE   IP       NODE       NOMINATED NODE   READINESS GATES
simple   0/1     ContainerCreating   0          0s    <none>   minikube   <none>           <none>
simple   0/1     ContainerCreating   0          1s    <none>   minikube   <none>           <none>
simple   1/1     Running             0          1s    10.244.0.7   minikube   <none>           <none>
```

(Ctrl-C pour arrêter la surveillance.) En une seconde, le Pod a reçu un nœud, une adresse IP, et son conteneur tourne. La colonne `READY` compte les conteneurs prêts sur le nombre total : `1/1`.

## Phases et conditions

La colonne `STATUS` de `kubectl get` est un résumé fabriqué par kubectl à partir de plusieurs champs. Le statut réel du Pod est plus riche. Il a d'abord une **phase**, un seul mot qui situe le Pod dans sa vie[^cycle] :

- `Pending` : le Pod est accepté, mais au moins un conteneur n'a pas encore démarré (il attend un nœud, une image, ou la fin de ses init containers) ;
- `Running` : le Pod a un nœud, et au moins un conteneur tourne ou redémarre ;
- `Succeeded` : tous les conteneurs se sont terminés avec succès, et ne seront pas relancés ;
- `Failed` : tous les conteneurs se sont terminés, et au moins un en échec ;
- `Unknown` : le nœud ne donne plus de nouvelles (le chapitre 15 l'a frôlé).

Il a ensuite des **conditions**, des affirmations vraies ou fausses, avec la date de leur dernier changement :

```bash
kubectl get pod simple -o jsonpath='{.status.phase}{"\n"}{range .status.conditions[*]}{.type}={.status} {.lastTransitionTime}{"\n"}{end}'
```

```sortie
Running
PodReadyToStartContainers=True 2026-09-26T04:57:20Z
Initialized=True 2026-09-26T04:57:19Z
Ready=True 2026-09-26T04:57:20Z
ContainersReady=True 2026-09-26T04:57:20Z
PodScheduled=True 2026-09-26T04:57:19Z
```

Dans l'ordre chronologique : le Pod a reçu un nœud (`PodScheduled`), ses init containers sont terminés (`Initialized`, vrai tout de suite puisqu'il n'en a pas), son environnement réseau est prêt (`PodReadyToStartContainers` : le conteneur `pause` du chapitre 11 existe), ses conteneurs sont prêts (`ContainersReady`), et le Pod lui-même est prêt à recevoir du trafic (`Ready`). La condition `Ready` est celle qui comptera le plus : au chapitre 20, un Service n'envoie de requêtes qu'aux Pods `Ready`, et le chapitre 22 montrera comment une sonde de santé la rend fausse.

Chaque conteneur a enfin son propre **état**, dans `status.containerStatuses` : `waiting` (avec une raison), `running` (avec une date de démarrage) ou `terminated` (avec un code de sortie). Voyons chacun de ces cas.

## Un Pod qui se termine

Tous les Pods ne sont pas des serveurs. Voici une tâche qui calcule puis s'arrête :

```yaml title="tache.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: tache
spec:
  restartPolicy: Never
  containers:
  - name: calcul
    image: busybox:1.37
    command: ["sh", "-c", "echo 'calcul en cours'; sleep 3; echo 'terminé'"]
```

`command` remplace l'`ENTRYPOINT` de l'image, comme `docker run --entrypoint` ; `args`, que nous n'utilisons pas ici, remplacerait son `CMD`. La ligne importante est `restartPolicy: Never`.

```bash
kubectl apply -f tache.yaml
sleep 12
kubectl get pod tache
kubectl logs tache
kubectl get pod tache -o jsonpath='{.status.phase} {.status.containerStatuses[0].state.terminated.exitCode} {.status.containerStatuses[0].state.terminated.reason}{"\n"}'
```

```sortie
pod/tache created
NAME    READY   STATUS      RESTARTS   AGE
tache   0/1     Completed   0          12s
calcul en cours
terminé
Succeeded 0 Completed
```

Phase `Succeeded`, conteneur terminé avec le code 0. Le Pod reste visible, avec ses journaux, jusqu'à ce qu'on le supprime. Le même Pod qui échoue :

```yaml title="echec.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: echec
spec:
  restartPolicy: Never
  containers:
  - name: calcul
    image: busybox:1.37
    command: ["sh", "-c", "echo 'fichier introuvable' >&2; exit 3"]
```

```bash
kubectl apply -f echec.yaml
sleep 8
kubectl get pod echec
kubectl logs echec
kubectl get pod echec -o jsonpath='{.status.phase} {.status.containerStatuses[0].state.terminated.exitCode} {.status.containerStatuses[0].state.terminated.reason}{"\n"}'
```

```sortie
pod/echec created
NAME    READY   STATUS   RESTARTS   AGE
echec   0/1     Error    0          8s
fichier introuvable
Failed 3 Error
```

Phase `Failed`, code de sortie 3, conservé tel quel : c'est le même code que `docker ps -a` afficherait (chapitre 2). `kubectl logs` restitue aussi la sortie d'erreur du programme.

## La politique de redémarrage

`restartPolicy` décide de ce que fait le kubelet quand un conteneur s'arrête. Elle vaut pour tous les conteneurs du Pod et prend trois valeurs[^cycle] :

- `Always`, la valeur par défaut, relance le conteneur quelle que soit sa façon de s'arrêter. C'est celle des serveurs, et celle qu'imposent les Deployments ;
- `OnFailure` ne le relance que s'il s'est arrêté avec un code non nul. C'est celle des tâches qui doivent aboutir (exercice 1) ;
- `Never` ne le relance jamais.

Voici un serveur qui plante au démarrage, parce qu'il ne joint pas sa base de données. Il n'indique pas de `restartPolicy`, donc `Always` :

```yaml title="plantage.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: plantage
spec:
  containers:
  - name: api
    image: busybox:1.37
    command: ["sh", "-c", "date; echo 'connexion à la base impossible' >&2; exit 1"]
```

Lançons-le, et relevons pendant sept minutes chaque changement de son nombre de redémarrages et de l'état de son conteneur :

```bash
kubectl apply -f plantage.yaml
T0=$(date +%s); last=''
while [ $(( $(date +%s)-T0 )) -lt 420 ]; do
  s=$(kubectl get pod plantage -o jsonpath='{.status.containerStatuses[0].restartCount} {.status.containerStatuses[0].state.waiting.reason}{.status.containerStatuses[0].state.running.startedAt}{.status.containerStatuses[0].state.terminated.reason}')
  [ "$s" != "$last" ] && echo "t=$(( $(date +%s)-T0 )) s : $s" && last=$s
  sleep 1
done
```

```sortie
t=0 s : 0 ContainerCreating
t=3 s : 1 2026-09-26T04:57:22Z
t=4 s : 1 Error
t=5 s : 1 CrashLoopBackOff
t=16 s : 2 Error
t=39 s : 3 2026-09-26T04:57:57Z
t=40 s : 3 Error
t=92 s : 4 Error
t=167 s : 4 CrashLoopBackOff
t=172 s : 5 2026-09-26T05:00:11Z
t=174 s : 5 Error
t=248 s : 5 CrashLoopBackOff
t=333 s : 6 Error
```

(Une interrogation par seconde ne voit pas tous les états intermédiaires : un conteneur qui vit une fraction de seconde passe parfois de `Error` à `Error` sans qu'on le voie tourner.) Les redémarrages ont lieu à 3, 16, 39, 92, 172 et 333 secondes. Les intervalles, 13, 23, 53, 80 et 161 secondes, trahissent la règle : après chaque échec, le kubelet attend avant de relancer, et **double** son attente à chaque fois, 10, 20, 40, 80, 160 secondes, jusqu'à un plafond de cinq minutes. C'est le **recul exponentiel** (*exponential back-off*), et `CrashLoopBackOff` n'est rien d'autre que l'état d'un conteneur qui attend la fin de ce délai. Le compteur n'est remis à zéro qu'après dix minutes de fonctionnement sans plantage[^cycle].

<Figure svg={reculCrash} num="17.1" alt="Frise de 0 à 360 secondes. Six traits marquent les démarrages du conteneur, à 3, 16, 39, 92, 172 et 333 secondes. Entre eux, des bandes marquent l'attente imposée par le kubelet : environ 10, 20, 40, 80 puis 160 secondes, qui double à chaque échec jusqu'à 300 secondes.">
Les redémarrages mesurés du Pod <code>plantage</code>. Le kubelet double son attente après chaque échec : 10, 20, 40, 80, 160 secondes, jusqu'à cinq minutes.
</Figure>

Pourquoi attendre ? Parce qu'un conteneur qui plante aussitôt relancé consommerait du processeur pour rien et inonderait les journaux. Si la cause est passagère (une base de données qui redémarre), le conteneur finira par se relancer au bon moment ; si elle est permanente, il vaut mieux relancer de moins en moins souvent. La phase du Pod, elle, reste `Running` pendant tout ce temps, puisque le kubelet n'a pas renoncé.

:::panne[CrashLoopBackOff]

Ce statut ne dit pas pourquoi le conteneur s'arrête, seulement qu'il s'arrête sans cesse. La cause est dans les journaux du **dernier** conteneur arrêté, que `--previous` va chercher, et dans l'état qu'a laissé ce conteneur :

```bash
kubectl logs plantage --previous
kubectl describe pod plantage | sed -n '/Last State/,/Restart Count/p'
```

```sortie
Sat Sep 26 05:08:04 UTC 2026
connexion à la base impossible
    Last State:     Terminated
      Reason:       Error
      Exit Code:    1
      Started:      Sat, 26 Sep 2026 07:08:04 +0200
      Finished:     Sat, 26 Sep 2026 07:08:04 +0200
    Ready:          False
    Restart Count:  7
```

Un code 1 avec un message d'erreur dans les journaux : le programme lui-même a abandonné, et c'est lui qu'il faut corriger (configuration, dépendance absente). Un code 137 signale un processus tué, souvent par manque de mémoire (chapitre 23) ; un code 127, une commande introuvable dans l'image. Pendant le `CrashLoopBackOff`, `kubectl logs plantage` sans `--previous` donne en général la même chose, puisqu'aucun conteneur ne tourne ; mais dès qu'une nouvelle tentative démarre, seul `--previous` montre les journaux de l'échec précédent.

:::

## Quand le Pod ne démarre pas

Deux autres statuts viennent d'un Pod dont le conteneur n'a jamais démarré. Le premier, une image qui n'existe pas :

```yaml title="image-absente.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: image-absente
spec:
  containers:
  - name: web
    image: nginx:9.99-alpine
```

```bash
kubectl apply -f image-absente.yaml
sleep 25
kubectl get pod image-absente
kubectl describe pod image-absente | sed -n '/^Events:/,$p'
```

```sortie
pod/image-absente created
NAME            READY   STATUS             RESTARTS   AGE
image-absente   0/1     ImagePullBackOff   0          25s
Events:
  Type     Reason     Age                From               Message
  ----     ------     ----               ----               -------
  Normal   Scheduled  25s                default-scheduler  Successfully assigned ch17/image-absente to minikube
  Normal   BackOff    23s                kubelet            spec.containers{web}: Back-off pulling image "nginx:9.99-alpine"
  Warning  Failed     23s                kubelet            spec.containers{web}: Error: ImagePullBackOff
  Normal   Pulling    12s (x2 over 24s)  kubelet            spec.containers{web}: Pulling image "nginx:9.99-alpine"
  Warning  Failed     11s (x2 over 24s)  kubelet            spec.containers{web}: Failed to pull image "nginx:9.99-alpine": rpc error: code = NotFound desc = failed to pull and unpack image "docker.io/library/nginx:9.99-alpine": ...
  Warning  Failed     11s (x2 over 24s)  kubelet            spec.containers{web}: Error: ErrImagePull
```

`ErrImagePull` signale l'échec d'un téléchargement ; `ImagePullBackOff`, l'attente avant le suivant, avec le même recul exponentiel. Le message complet donne la cause : `NotFound`, l'étiquette n'existe pas sur Docker Hub. Les autres causes courantes sont un nom de registre mal écrit, un registre privé qui demande une authentification, ou une limite de téléchargements atteinte. `RESTARTS` reste à 0 : le conteneur n'a jamais existé.

Le second : un Pod qu'aucun nœud ne peut accueillir. Ce Pod demande 100 processeurs (le chapitre 23 détaillera ces demandes de ressources) :

```yaml title="trop-gros.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: trop-gros
spec:
  containers:
  - name: web
    image: nginx:1.30-alpine
    resources:
      requests:
        cpu: "100"
```

```bash
kubectl apply -f trop-gros.yaml
sleep 5
kubectl get pod trop-gros
kubectl describe pod trop-gros | sed -n '/^Events:/,$p'
```

```sortie
pod/trop-gros created
NAME        READY   STATUS    RESTARTS   AGE
trop-gros   0/1     Pending   0          5s
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  5s    default-scheduler  0/1 nodes are available: 1 Insufficient cpu. preemption: 0/1 nodes are available: 1 Preemption is not helpful for scheduling.
```

Le scheduler a examiné le seul nœud et l'a écarté pour manque de processeur. Le Pod restera `Pending`, et le scheduler réessaiera chaque fois que la situation du cluster change, par exemple quand un nœud est ajouté. La condition `PodScheduled` vaut `False`, avec la raison `Unschedulable`.

Pourquoi 100 processeurs, et pas 10 ? En préparant ce chapitre, une première version en demandait 10, et le Pod a démarré sans difficulté. `kubectl get node minikube -o jsonpath='{.status.capacity.cpu}'` répond `22` : avec le pilote `docker`, le nœud minikube annonce au scheduler tous les cœurs et toute la mémoire du poste (`15778000Ki` ici), et non les deux processeurs et les 4 Go donnés à `minikube start`. Ces limites s'appliquent bien au conteneur du nœud, mais le kubelet ne les voit pas. Retenez-le pour la suite : minikube placera des Pods que votre poste ne pourra pas vraiment faire tourner.

<Figure svg={cyclePod} num="17.2" alt="Quatre phases. Pending, avec ses causes : pas de nœud (FailedScheduling), image introuvable (ErrImagePull, ImagePullBackOff), init containers en cours (Init:0/1). Quand un nœud est choisi et les conteneurs lancés, la phase passe à Running ; un conteneur relancé (CrashLoopBackOff, RESTARTS) laisse la phase à Running. De Running, le Pod passe à Succeeded quand tous les conteneurs se terminent avec le code 0 (exemple : tache, Completed) ou à Failed avec un code non nul (exemple : echec, Error, code 3), seulement si restartPolicy n'est pas Always.">
Les phases d'un Pod et les statuts que <code>kubectl get</code> affiche en chemin, avec les exemples de ce chapitre.
</Figure>

## Plusieurs conteneurs dans un Pod

Pourquoi un Pod peut-il contenir plusieurs conteneurs ? Parce que certains programmes n'ont de sens qu'ensemble, sur la même machine, et doivent partager des fichiers ou se parler par `localhost`. Voici un serveur nginx accompagné d'un petit programme qui l'interroge toutes les cinq secondes et compte les requêtes dans son journal :

```yaml title="duo.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: duo
spec:
  volumes:
  - name: journaux
    emptyDir: {}
  containers:
  - name: web
    image: nginx:1.30-alpine
    volumeMounts:
    - name: journaux
      mountPath: /var/log/nginx
  - name: compteur
    image: busybox:1.37
    command: ["sh", "-c", "while true; do wget -q -O /dev/null http://localhost/; echo \"$(date +%T) requêtes servies : $(grep -c GET /journaux/access.log)\"; sleep 5; done"]
    volumeMounts:
    - name: journaux
      mountPath: /journaux
```

Le volume `journaux` est de type **emptyDir** : un dossier vide créé sur le nœud à la naissance du Pod, supprimé avec lui, et monté dans les deux conteneurs, à des endroits différents[^emptydir]. nginx y écrit son `access.log`, que le compteur lit.

```bash
kubectl apply -f duo.yaml
kubectl wait --for=condition=Ready pod/duo --timeout=90s
sleep 16
kubectl get pod duo -o wide
kubectl logs duo -c compteur | tail -3
kubectl exec duo -c web -- sh -c 'hostname; ip -4 addr show eth0 | grep inet'
kubectl exec duo -c compteur -- sh -c 'hostname; ip -4 addr show eth0 | grep inet'
```

```sortie
pod/duo created
pod/duo condition met
NAME   READY   STATUS    RESTARTS   AGE   IP            NODE       NOMINATED NODE   READINESS GATES
duo    2/2     Running   0          17s   10.244.0.12   minikube   <none>           <none>
04:58:23 requêtes servies : 2
04:58:28 requêtes servies : 3
04:58:33 requêtes servies : 4
duo
    inet 10.244.0.12/24 brd 10.244.0.255 scope global eth0
duo
    inet 10.244.0.12/24 brd 10.244.0.255 scope global eth0
```

`READY 2/2`. Les deux conteneurs ont le même nom de machine et la même adresse IP : ils partagent les namespaces réseau et UTS du conteneur `pause`, exactement comme au chapitre 11. C'est pourquoi le compteur joint nginx par `localhost`. Avec plusieurs conteneurs, `kubectl logs` et `kubectl exec` demandent l'option `-c` ; sans elle, kubectl choisit le premier et le signale : `Defaulted container "web" out of: web, compteur`. Dans le nœud, le runtime voit bien un seul Pod et deux conteneurs :

```bash
minikube ssh -- sudo crictl pods --namespace ch17 --name duo
```

```sortie
POD ID              CREATED              STATE               NAME                NAMESPACE           ATTEMPT             RUNTIME
f816d12f738bc       About a minute ago   Ready               duo                 ch17                0                   (default)
```

Quand mettre deux conteneurs dans un Pod ? Seulement quand ils doivent vivre et mourir ensemble, sur la même machine : un programme principal et son assistant. Un serveur web et sa base de données n'ont rien à faire dans le même Pod : on voudra en lancer trois copies pour l'un et une seule pour l'autre, les mettre à jour séparément, les placer sur des nœuds différents. Chacun aura son Pod, et ils se parleront par le réseau (chapitre 20).

## Préparer le terrain : les init containers

Un **init container** s'exécute avant les conteneurs principaux, jusqu'à son terme ; s'il y en a plusieurs, ils s'exécutent l'un après l'autre, et chacun doit réussir pour que le suivant démarre[^init]. On s'en sert pour préparer ce dont le programme principal a besoin : attendre qu'une dépendance réponde, télécharger une configuration, créer des fichiers. Celui-ci fabrique la page d'accueil de nginx, en prenant son temps :

```yaml title="init.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: init
spec:
  volumes:
  - name: site
    emptyDir: {}
  initContainers:
  - name: preparer
    image: busybox:1.37
    command: ["sh", "-c", "sleep 8; echo \"<h1>Préparé par l'init container à $(date +%T)</h1>\" > /site/index.html"]
    volumeMounts:
    - name: site
      mountPath: /site
  containers:
  - name: web
    image: nginx:1.30-alpine
    volumeMounts:
    - name: site
      mountPath: /usr/share/nginx/html
```

```bash
kubectl apply -f init.yaml
for i in 1 2 3 4 5 6; do kubectl get pod init --no-headers; sleep 2; done
kubectl exec init -- wget -q -O - http://localhost/
```

```sortie
pod/init created
init   0/1   Init:0/1   0     0s
init   0/1   Init:0/1   0     3s
init   0/1   Init:0/1   0     5s
init   0/1   Init:0/1   0     7s
init   0/1   Init:0/1   0     9s
init   1/1   Running   0     11s
Defaulted container "web" out of: web, preparer (init)
<h1>Préparé par l'init container à 04:58:43</h1>
```

`Init:0/1` : zéro init container terminé sur un. Pendant ce temps, la phase est `Pending` et nginx n'existe pas encore. Une fois la page écrite, nginx démarre et la sert. Si l'init container échoue, il est relancé selon la politique du Pod, et le statut devient `Init:Error` puis `Init:CrashLoopBackOff` (exercice 3).

## Les sidecars natifs

Revenons au Pod `duo`. Son compteur est ce qu'on appelle un **sidecar** (side-car, en français : le panier d'une moto) : un conteneur d'appui qui accompagne le programme principal pendant toute sa vie, pour expédier ses journaux, chiffrer son trafic, rafraîchir ses certificats. Pendant des années, Kubernetes n'a pas eu de notion de sidecar : c'étaient des conteneurs ordinaires. Cela pose un problème dès que le programme principal est une tâche qui se termine. Voici une tâche qui écrit trois lignes, accompagnée d'un « expéditeur » qui les lit :

```yaml title="sidecar-ancien.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: sidecar-ancien
spec:
  restartPolicy: Never
  volumes:
  - name: partage
    emptyDir: {}
  containers:
  - name: tache
    image: busybox:1.37
    command: ["sh", "-c", "for i in 1 2 3; do echo \"ligne $i\" >> /partage/sortie.log; sleep 2; done"]
    volumeMounts:
    - name: partage
      mountPath: /partage
  - name: expediteur
    image: busybox:1.37
    command: ["sh", "-c", "touch /partage/sortie.log; tail -f /partage/sortie.log"]
    volumeMounts:
    - name: partage
      mountPath: /partage
```

```bash
kubectl apply -f sidecar-ancien.yaml
sleep 20
kubectl get pod sidecar-ancien
kubectl get pod sidecar-ancien -o jsonpath='{range .status.containerStatuses[*]}{.name}: {.state}{"\n"}{end}'
```

```sortie
pod/sidecar-ancien created
NAME             READY   STATUS     RESTARTS   AGE
sidecar-ancien   1/2     NotReady   0          20s
expediteur: {"running":{"startedAt":"2026-09-26T04:58:48Z"}}
tache: {"terminated":{"containerID":"containerd://538350e2cd1023949ec553bc8170f3d1bf448e2ae19e6328543b6e9a92d53fb3","exitCode":0,"finishedAt":"2026-09-26T04:58:54Z","reason":"Completed","startedAt":"2026-09-26T04:58:48Z"}}
```

La tâche a fini au bout de six secondes, mais le Pod ne se termine jamais : l'expéditeur tourne pour toujours, puisque `tail -f` n'a aucune raison de s'arrêter, et un Pod n'est `Succeeded` que quand **tous** ses conteneurs sont terminés. Le Pod restera `NotReady` jusqu'à ce qu'on le supprime. Pour un Job (chapitre 27), c'est un Job qui ne finit jamais.

Depuis Kubernetes 1.28, un sidecar se déclare autrement : dans la liste `initContainers`, avec `restartPolicy: Always` sur le conteneur lui-même[^sidecar]. La fonction est activée par défaut depuis la version 1.29 et stable depuis la 1.33. Un tel conteneur démarre avant les conteneurs principaux, comme un init container, mais il n'a pas besoin de se terminer pour que les suivants démarrent ; il est relancé s'il s'arrête ; et surtout, il est arrêté automatiquement quand les conteneurs principaux ont fini.

```yaml title="sidecar-natif.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: sidecar-natif
spec:
  restartPolicy: Never
  volumes:
  - name: partage
    emptyDir: {}
  initContainers:
  - name: expediteur
    image: busybox:1.37
    restartPolicy: Always
    command: ["sh", "-c", "touch /partage/sortie.log; tail -f /partage/sortie.log"]
    volumeMounts:
    - name: partage
      mountPath: /partage
  containers:
  - name: tache
    image: busybox:1.37
    command: ["sh", "-c", "for i in 1 2 3; do echo \"ligne $i\" >> /partage/sortie.log; sleep 2; done"]
    volumeMounts:
    - name: partage
      mountPath: /partage
```

```bash
kubectl apply -f sidecar-natif.yaml
for i in 1 2 3 4 5 6; do kubectl get pod sidecar-natif --no-headers; sleep 2; done
kubectl logs sidecar-natif -c expediteur
```

```sortie
pod/sidecar-natif created
sidecar-natif   0/2   Init:0/1   0     0s
sidecar-natif   2/2   Running   0     2s
sidecar-natif   2/2   Running   0     4s
sidecar-natif   2/2   Running   0     6s
sidecar-natif   1/2   Completed   0     8s
sidecar-natif   1/2   Completed   0     10s
ligne 1
ligne 2
ligne 3
```

L'expéditeur a démarré en premier (`Init:0/1`), la tâche ensuite (`2/2`), et quand la tâche a fini, le Pod est passé en `Completed` : le kubelet a arrêté l'expéditeur de lui-même, après qu'il a transmis les trois lignes. C'est la bonne façon d'écrire un sidecar, et le chapitre 59 la retrouvera avec les proxys d'un maillage de services.

<Figure svg={anatomiePod} num="17.3" alt="Un Pod, avec une adresse IP 10.244.0.12, un nom de machine et des volumes. Un init container, preparer, s'exécute puis s'arrête, puis vient le conteneur web (nginx, port 80). Un sidecar natif, déclaré dans initContainers avec restartPolicy Always, démarre avant et s'arrête après le conteneur principal. Le conteneur compteur interroge web par localhost. web écrit access.log dans un volume emptyDir journaux, que compteur lit. En bas, le conteneur pause, qui garde les namespaces réseau, UTS et IPC partagés par tous les conteneurs du Pod.">
Ce qu'un Pod réunit : des init containers qui s'exécutent d'abord, des conteneurs principaux qui partagent une adresse et se parlent par <code>localhost</code>, des volumes partagés, des sidecars natifs, et le conteneur <code>pause</code> qui tient le tout.
</Figure>

## Un Pod n'est pas fait pour être créé à la main

Tous les Pods de ce chapitre ont un défaut : si on les supprime, ou si leur nœud tombe, personne ne les recrée. Le chapitre 15 l'a montré : c'est le ReplicaSet qui remplace les Pods disparus. En pratique, on ne crée presque jamais un Pod directement. On crée un Deployment (chapitre 19) pour les serveurs, un Job pour les tâches, un DaemonSet pour un agent par nœud (chapitre 27), et ce sont eux qui créent les Pods, à partir d'un modèle qui a exactement la forme de la `spec` d'un Pod. Tout ce que ce chapitre a montré (conteneurs, volumes, init containers, sidecars, politique de redémarrage) se retrouvera tel quel dans ces modèles.

## Exercices

:::exercice[Exercice 1 : réussir au troisième essai]

Écrivez un Pod `troisieme` avec `restartPolicy: OnFailure`, dont le conteneur échoue aux deux premiers essais et réussit au troisième. Comment un conteneur peut-il savoir combien de fois il a déjà été lancé ? Quelle est la phase finale du Pod, et combien de redémarrages affiche-t-il ?

:::

<details>
<summary>Corrigé</summary>

Un conteneur relancé repart de son image, sans rien garder. En revanche, un volume `emptyDir` survit aux redémarrages des conteneurs : il appartient au Pod. On y range un compteur.

```yaml title="troisieme.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: troisieme
spec:
  restartPolicy: OnFailure
  volumes:
  - name: compteur
    emptyDir: {}
  containers:
  - name: essai
    image: busybox:1.37
    command: ["sh", "-c", "n=$(cat /c/n 2>/dev/null || echo 0); n=$((n+1)); echo $n > /c/n; echo \"essai $n\"; [ $n -ge 3 ]"]
    volumeMounts:
    - name: compteur
      mountPath: /c
```

```bash
kubectl apply -f troisieme.yaml
sleep 45
kubectl get pod troisieme
kubectl logs troisieme
kubectl get pod troisieme -o jsonpath='{.status.phase} restarts={.status.containerStatuses[0].restartCount}{"\n"}'
```

```sortie
NAME        READY   STATUS      RESTARTS      AGE
troisieme   0/1     Completed   2 (43s ago)   45s
essai 3
Succeeded restarts=2
```

La dernière commande du script, `[ $n -ge 3 ]`, donne son code de sortie au conteneur : 1 tant que `n` est inférieur à 3, puis 0. Deux redémarrages, espacés de 10 puis 20 secondes par le recul exponentiel, et le Pod finit `Succeeded`. Avec `Never`, il se serait arrêté `Failed` dès le premier essai ; avec `Always`, il aurait été relancé même après son succès, indéfiniment.

</details>

:::exercice[Exercice 2 : deux serveurs, un seul port]

Écrivez un Pod qui contient deux conteneurs `nginx:1.30-alpine`, sans rien configurer d'autre. Que se passe-t-il ? Pourquoi, alors que deux conteneurs Docker lancés séparément fonctionneraient ?

:::

<details>
<summary>Corrigé</summary>

```yaml title="deux-nginx.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: deux-nginx
spec:
  containers:
  - name: premier
    image: nginx:1.30-alpine
  - name: second
    image: nginx:1.30-alpine
```

```bash
kubectl apply -f deux-nginx.yaml
sleep 70
kubectl get pod deux-nginx
kubectl logs deux-nginx -c second | grep emerg | head -2
```

```sortie
NAME         READY   STATUS   RESTARTS      AGE
deux-nginx   1/2     Error    3 (49s ago)   70s
2026/09/26 05:06:23 [emerg] 1#1: bind() to 0.0.0.0:80 failed (98: Address in use)
nginx: [emerg] bind() to 0.0.0.0:80 failed (98: Address in use)
```

Le second nginx ne peut pas écouter sur le port 80 : le premier l'occupe déjà, dans le **même** namespace réseau. Deux conteneurs Docker séparés ont chacun leur namespace réseau, donc chacun son port 80 ; deux conteneurs d'un même Pod partagent le leur, comme deux programmes sur une même machine. Le second plante, redémarre, replante : `RESTARTS` augmente, et le statut alterne entre `Error`, `CrashLoopBackOff` et, brièvement, `Running`, car nginx réessaie quelques secondes avant d'abandonner. Dans un Pod, chaque conteneur doit écouter sur un port différent.

</details>

:::exercice[Exercice 3 : attendre une dépendance qui n'existe pas]

Beaucoup d'applications utilisent un init container pour attendre que leur base de données soit joignable. Écrivez un Pod dont l'init container cherche le nom `base-inexistante.ch17.svc.cluster.local` avec `nslookup` et échoue s'il ne le trouve pas. Quel statut affiche le Pod ? Le conteneur principal démarre-t-il ?

:::

<details>
<summary>Corrigé</summary>

```yaml title="init-rate.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: init-rate
spec:
  initContainers:
  - name: attendre-base
    image: busybox:1.37
    command: ["sh", "-c", "nslookup base-inexistante.ch17.svc.cluster.local || exit 1"]
  containers:
  - name: api
    image: nginx:1.30-alpine
```

```bash
kubectl apply -f init-rate.yaml
sleep 40
kubectl get pod init-rate
kubectl logs init-rate -c attendre-base | tail -2
kubectl get pod init-rate -o jsonpath='{.status.phase} {.status.containerStatuses[0].state}{"\n"}'
```

```sortie
NAME        READY   STATUS       RESTARTS      AGE
init-rate   0/1     Init:Error   3 (27s ago)   40s
** server can't find base-inexistante.ch17.svc.cluster.local: NXDOMAIN
Pending {"waiting":{"reason":"PodInitializing"}}
```

Le nom est inconnu du DNS du cluster (le chapitre 20 expliquera ces noms en `.svc.cluster.local`), l'init container sort avec le code 1, et il est relancé selon la politique du Pod (`Always` par défaut), avec le recul exponentiel : le statut alterne entre `Init:Error` et `Init:CrashLoopBackOff`. Le conteneur `api` reste en attente (`PodInitializing`), et le Pod reste `Pending`. Dès que le Service `base-inexistante` existera, l'init container réussira à sa prochaine tentative, et l'application démarrera d'elle-même. C'est l'intérêt du motif : on n'a pas besoin d'ordonner le démarrage des composants, chacun attend ce dont il a besoin.

</details>

## Nettoyer

```bash
kubectl delete namespace ch17
kubectl config set-context --current --namespace=default
```

[^cycle]: Kubernetes, « Pod Lifecycle », sections *Pod phase*, *Pod conditions*, *Container states* et *Container restart policy*. [kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/)

[^emptydir]: Kubernetes, « Volumes », section *emptyDir*. [kubernetes.io/docs/concepts/storage/volumes/#emptydir](https://kubernetes.io/docs/concepts/storage/volumes/#emptydir)

[^init]: Kubernetes, « Init Containers ». [kubernetes.io/docs/concepts/workloads/pods/init-containers](https://kubernetes.io/docs/concepts/workloads/pods/init-containers/)

[^sidecar]: Kubernetes, « Sidecar Containers ». [kubernetes.io/docs/concepts/workloads/pods/sidecar-containers](https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/)
