---
title: Pourquoi un orchestrateur
sidebar_label: 15. Pourquoi un orchestrateur
description: "Ce que Compose ne sait pas faire, l'héritage de Borg, l'état désiré et les boucles de réconciliation, les composants d'un cluster Kubernetes, et ce qui se passe quand une machine tombe."
partie: 3
chapitre: '15'
---

import architectureCluster from '@site/src/figures/architecture-cluster.svg';
import sequenceDeployment from '@site/src/figures/sequence-deployment.svg';
import panneNoeud from '@site/src/figures/panne-noeud.svg';

Colis tourne sur votre poste avec Compose : une commande, cinq conteneurs, et `restart: unless-stopped` relance un programme qui plante. Imaginons maintenant qu'une vraie entreprise de livraison l'adopte. Le service doit rester joignable jour et nuit, y compris pendant les mises à jour. Le trafic triple chaque fin d'année, et une seule machine ne suffit plus : il en faut cinq, puis vingt. Et un jour, une de ces machines perd son alimentation.

Compose n'a aucune réponse à ces problèmes, parce qu'il ne connaît qu'une machine. Si elle s'éteint, personne n'est là pour relancer les conteneurs ailleurs, puisque le programme qui les surveillait s'est éteint avec elle. Répartir cinquante conteneurs sur vingt machines, en tenant compte de la mémoire libre de chacune, remplacer une version par une autre sans interruption, savoir à tout moment où tourne chaque copie de l'API pour lui envoyer du trafic : tout cela resterait à écrire. Ce travail a un nom, l'**orchestration**, et Kubernetes est aujourd'hui l'orchestrateur de conteneurs le plus répandu.

Ce chapitre ne cherche pas encore à vous faire écrire des manifestes. Il explique l'idée sur laquelle tout Kubernetes repose, l'état désiré et la réconciliation, la montre à l'œuvre sur votre cluster minikube, puis fait le tour des composants d'un cluster. Il se termine par une expérience qui résume tout : éteindre une machine et regarder le cluster s'en remettre.

## Un héritage : Borg

Kubernetes n'est pas sorti de nulle part. Depuis le début des années 2000, Google fait tourner l'essentiel de ses services, de la recherche à Gmail, sur un système interne appelé **Borg**. L'article qui l'a décrit publiquement en 2015 donne l'échelle : des centaines de milliers de tâches, issues de milliers d'applications différentes, réparties sur des grappes de machines (des *clusters*) qui comptent chacune jusqu'à des dizaines de milliers de serveurs[^borg]. Les développeurs de Google n'y choisissaient pas leurs machines : ils décrivaient leur tâche (ce programme, tant de copies, tant de mémoire et de processeur) et Borg décidait où la faire tourner, la relançait quand elle plantait et la déplaçait quand une machine tombait. Un second système, **Omega**, a ensuite exploré une architecture plus souple, où plusieurs ordonnanceurs partagent un même état du cluster[^omega].

En 2014, plusieurs ingénieurs de Google qui avaient travaillé sur Borg et Omega lancent un projet libre qui reprend leurs idées, pour les conteneurs Docker qui venaient de se populariser : **Kubernetes**, du grec *kubernétês*, le timonier[^k8s-nom]. Le premier *commit* date du 6 juin 2014, la version 1.0 sort en juillet 2015, et le projet est confié la même année à une fondation créée pour l'occasion, la **CNCF** (*Cloud Native Computing Foundation*), dont il devient en 2018 le premier projet « diplômé », c'est-à-dire jugé mûr et largement adopté[^k8s-10ans][^cncf]. L'abréviation **K8s** vient des huit lettres entre le K et le s.

Les auteurs de Borg ont résumé dans un article de 2016 les leçons qu'ils en ont tirées pour Kubernetes[^borg-omega-k8s]. On y retrouve presque tout ce que cette partie va vous faire manipuler : les étiquettes plutôt que des numéros pour regrouper les tâches (chapitre 18), une adresse IP par Pod plutôt que des ports partagés sur la machine (chapitre 20), et surtout l'idée qui fait l'objet de ce chapitre : décrire l'état voulu et laisser des boucles de contrôle le faire advenir.

## L'état désiré

Il y a deux façons de demander quelque chose à un système. La façon **impérative** donne des ordres : « lance trois conteneurs nginx ». Une fois les ordres exécutés, le système a fini son travail. Si un conteneur meurt une heure plus tard, rien ne se passe, parce que l'ordre a été exécuté. La façon **déclarative** décrit un résultat : « il doit y avoir trois conteneurs nginx ». Le système compare en permanence ce qui existe à ce qui est demandé, et agit pour réduire l'écart. Si un conteneur meurt, l'écart réapparaît, et le système le comble.

La documentation de Kubernetes compare ce fonctionnement à un thermostat[^controleur]. Vous réglez 20 °C : c'est l'**état désiré**. La température de la pièce est l'**état observé**. Le thermostat ne connaît pas la cause d'un écart (fenêtre ouverte, soleil, porte d'entrée) et n'a pas besoin de la connaître : il mesure, compare, allume ou éteint le chauffage, puis recommence. Kubernetes est fait de dizaines de thermostats de ce genre, qu'on appelle des **contrôleurs**, et leur travail de comparaison et de correction s'appelle la **réconciliation**.

Voyons-le. Démarrez minikube si ce n'est pas déjà fait, puis créez un espace de travail pour ce chapitre, un *namespace* (le chapitre 18 les détaille ; retenez qu'il sépare vos objets de ceux des autres chapitres) :

```bash
minikube start --driver=docker --cpus=2 --memory=4g --kubernetes-version=v1.37.0
kubectl create namespace ch15
kubectl config set-context --current --namespace=ch15
```

Demandons trois copies de nginx, sous le nom `vitrine` :

```bash
kubectl create deployment vitrine --image=nginx:1.30-alpine --replicas=3
kubectl rollout status deployment/vitrine
kubectl get deployments,replicasets,pods -o wide
```

```sortie
deployment.apps/vitrine created
Waiting for deployment "vitrine" rollout to finish: 0 out of 3 new replicas have been updated...
Waiting for deployment "vitrine" rollout to finish: 0 of 3 updated replicas are available...
Waiting for deployment "vitrine" rollout to finish: 1 of 3 updated replicas are available...
Waiting for deployment "vitrine" rollout to finish: 2 of 3 updated replicas are available...
deployment "vitrine" successfully rolled out
NAME                      READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES              SELECTOR
deployment.apps/vitrine   3/3     3            3           1s    nginx        nginx:1.30-alpine   app=vitrine

NAME                                 DESIRED   CURRENT   READY   AGE   CONTAINERS   IMAGES              SELECTOR
replicaset.apps/vitrine-577cf576cf   3         3         3       1s    nginx        nginx:1.30-alpine   app=vitrine,pod-template-hash=577cf576cf

NAME                           READY   STATUS    RESTARTS   AGE   IP           NODE       NOMINATED NODE   READINESS GATES
pod/vitrine-577cf576cf-22mlc   1/1     Running   0          1s    10.244.0.4   minikube   <none>           <none>
pod/vitrine-577cf576cf-l6lmc   1/1     Running   0          1s    10.244.0.3   minikube   <none>           <none>
pod/vitrine-577cf576cf-zj9cm   1/1     Running   0          1s    10.244.0.5   minikube   <none>           <none>
```

Une seule commande a produit trois sortes d'objets. Le **Deployment** `vitrine` porte votre demande. Il a créé un **ReplicaSet**, dont le seul travail est de maintenir un nombre donné de copies identiques. Le ReplicaSet a créé trois **Pods**, l'unité de base de Kubernetes : un ou plusieurs conteneurs lancés ensemble sur une même machine, avec une adresse IP à eux (le chapitre 17 lui est consacré). Chaque Pod a été placé sur le nœud `minikube`, le seul du cluster.

Tout objet Kubernetes porte les deux moitiés du thermostat. Regardez le Deployment en YAML, en ne gardant que le début de sa partie `spec` et sa partie `status` :

```bash
kubectl get deployment vitrine -o yaml
```

```sortie
spec:
  progressDeadlineSeconds: 600
  replicas: 3
  revisionHistoryLimit: 10
  selector:
    matchLabels:
      app: vitrine
  strategy:
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 25%
    type: RollingUpdate
  template:
...
status:
  availableReplicas: 3
  conditions:
  - lastTransitionTime: "2026-09-25T16:26:36Z"
    lastUpdateTime: "2026-09-25T16:26:36Z"
    message: Deployment has minimum availability.
    reason: MinimumReplicasAvailable
    status: "True"
    type: Available
...
  observedGeneration: 1
  readyReplicas: 3
  replicas: 3
  terminatingReplicas: 0
  updatedReplicas: 3
```

`spec` est l'état désiré : trois répliques (`replicas: 3`), et beaucoup de valeurs par défaut que nous n'avons pas écrites. `status` est l'état observé, écrit par le contrôleur : trois répliques existent, trois sont prêtes, trois sont disponibles. Vous écrivez dans `spec` ; Kubernetes écrit dans `status`. Toute la mécanique consiste à faire converger le second vers le premier.

### Un Pod disparaît

Supprimons un Pod, en surveillant la liste avec `--watch`, qui affiche chaque changement au moment où il se produit. Lancez la surveillance dans un second terminal, ou en arrière-plan :

```bash
kubectl get pods --watch --output-watch-events &
kubectl delete pod vitrine-577cf576cf-22mlc
```

```sortie
EVENT      NAME                       READY   STATUS    RESTARTS   AGE
ADDED      vitrine-577cf576cf-22mlc   1/1     Running   0          1s
ADDED      vitrine-577cf576cf-l6lmc   1/1     Running   0          1s
ADDED      vitrine-577cf576cf-zj9cm   1/1     Running   0          1s
MODIFIED   vitrine-577cf576cf-22mlc   1/1     Terminating   0          2s
ADDED      vitrine-577cf576cf-szqf6   0/1     Pending       0          0s
MODIFIED   vitrine-577cf576cf-22mlc   1/1     Terminating   0          2s
MODIFIED   vitrine-577cf576cf-szqf6   0/1     Pending       0          0s
MODIFIED   vitrine-577cf576cf-szqf6   0/1     ContainerCreating   0          0s
MODIFIED   vitrine-577cf576cf-22mlc   0/1     Completed           0          2s
MODIFIED   vitrine-577cf576cf-szqf6   0/1     ContainerCreating   0          1s
MODIFIED   vitrine-577cf576cf-szqf6   1/1     Running             0          1s
MODIFIED   vitrine-577cf576cf-22mlc   0/1     Completed           0          3s
DELETED    vitrine-577cf576cf-22mlc   0/1     Completed           0          3s
```

(Terminez la surveillance avec `kill %1`, ou Ctrl-C dans l'autre terminal.) Dès que le Pod `22mlc` est passé en `Terminating`, un nouveau Pod, `szqf6`, a été créé, avant même que l'ancien ait fini de s'arrêter. Personne n'a demandé de remplacement : le ReplicaSet a simplement constaté qu'il n'y avait plus que deux Pods valides pour trois demandés. Une seconde plus tard, le nouveau Pod tournait. On ne « répare » pas un Pod dans Kubernetes : on le laisse remplacer.

### Un conteneur plante

Autre panne : le programme lui-même s'arrête, sans que personne ne supprime le Pod. Simulons-la en arrêtant le conteneur nginx directement dans le nœud, avec `crictl`, l'outil du chapitre 11 qui parle au runtime :

```bash
P=vitrine-577cf576cf-l6lmc
C=$(minikube ssh -- sudo crictl ps --name nginx --label io.kubernetes.pod.name=$P -q | tr -d '\r')
minikube ssh -- sudo crictl stop $C
sleep 6
kubectl get pod $P
```

```sortie
NAME                       READY   STATUS    RESTARTS     AGE
vitrine-577cf576cf-l6lmc   1/1     Running   1 (6s ago)   17s
```

Le même Pod est toujours là, avec `RESTARTS 1`. Ce n'est pas le ReplicaSet qui a agi, mais une autre boucle, dans le **kubelet**, l'agent Kubernetes qui tourne sur chaque nœud : il surveille les conteneurs des Pods qui lui sont confiés et relance ceux qui s'arrêtent, selon la politique de redémarrage du Pod (chapitre 17). Deux niveaux de réparation, donc : le kubelet relance les conteneurs d'un Pod sur place, le ReplicaSet remplace les Pods qui disparaissent.

### Changer d'avis

L'état désiré se modifie à tout moment, et le cluster suit :

```bash
kubectl scale deployment vitrine --replicas=5
kubectl rollout status deployment/vitrine
kubectl get pods
kubectl scale deployment vitrine --replicas=2
sleep 3
kubectl get pods
```

```sortie
deployment.apps/vitrine scaled
...
deployment "vitrine" successfully rolled out
NAME                       READY   STATUS    RESTARTS     AGE
vitrine-577cf576cf-4sb5g   1/1     Running   0            0s
vitrine-577cf576cf-l6lmc   1/1     Running   1 (7s ago)   18s
vitrine-577cf576cf-szqf6   1/1     Running   0            16s
vitrine-577cf576cf-xc2rh   1/1     Running   0            1s
vitrine-577cf576cf-zj9cm   1/1     Running   0            18s
deployment.apps/vitrine scaled
NAME                       READY   STATUS    RESTARTS   AGE
vitrine-577cf576cf-szqf6   1/1     Running   0          19s
vitrine-577cf576cf-zj9cm   1/1     Running   0          21s
```

`kubectl scale` n'a lancé ni arrêté aucun conteneur : il a modifié le champ `spec.replicas` du Deployment. Le reste a suivi. C'est la différence essentielle avec `docker compose up --scale` : avec Compose, la commande fait le travail puis s'arrête ; avec Kubernetes, la commande change une consigne, et le travail est fait par des programmes qui ne s'arrêtent jamais.

## Qui fait quoi dans un cluster

Qui sont ces « programmes qui ne s'arrêtent jamais » ? Les événements du cluster le disent. Créons un Deployment d'un seul Pod, `sonde`, et listons ses événements dans l'ordre où ils ont été enregistrés, avec le composant qui en est l'auteur :

```bash
kubectl create deployment sonde --image=nginx:1.30-alpine
kubectl rollout status deployment/sonde
kubectl get events -o json | jq -r '[.items[] | select(.involvedObject.name|startswith("sonde"))]
  | sort_by(.metadata.resourceVersion|tonumber) | .[]
  | [(.eventTime // .firstTimestamp)[11:23], .involvedObject.kind, .reason, (.reportingComponent // .source.component), .message[0:70]]
  | @tsv' | column -t -s "$(printf '\t')"
kubectl delete deployment sonde
```

```sortie
16:28:22Z     Deployment  ScalingReplicaSet  deployment-controller  Scaled up replica set sonde-56bb858ff9 from 0 to 1
16:28:22Z     ReplicaSet  SuccessfulCreate   replicaset-controller  Created pod: sonde-56bb858ff9-p7n5d
16:28:22.973  Pod         Scheduled          default-scheduler      Successfully assigned ch15/sonde-56bb858ff9-p7n5d to minikube
16:28:23Z     Pod         Pulled             kubelet                Container image "nginx:1.30-alpine" already present on machine and can
16:28:23Z     Pod         Created            kubelet                Container created
16:28:23Z     Pod         Started            kubelet                Container started
```

Quatre acteurs se passent le relais en une seconde. Le **contrôleur de Deployment** a vu un nouveau Deployment et créé son ReplicaSet. Le **contrôleur de ReplicaSet** a vu un ReplicaSet sans Pod et créé le Pod. Le **scheduler** a vu un Pod sans nœud et lui en a attribué un. Le **kubelet** du nœud `minikube` a vu un Pod qui lui était destiné, a demandé au runtime (containerd, chapitre 11) de créer et de démarrer le conteneur, puis a mis à jour le statut du Pod.

Ce qui frappe, c'est qu'aucun de ces acteurs ne s'adresse aux autres. Chacun ne fait qu'une chose : il **observe** une sorte d'objet, et quand il voit un écart entre ce qui est demandé et ce qui existe, il **écrit** un nouvel objet ou une modification. Tous passent par un intermédiaire unique, l'**API server**.

<Figure svg={sequenceDeployment} num="15.1" alt="Diagramme de séquence entre six acteurs : kubectl, l'API server avec etcd, le contrôleur de Deployment, le contrôleur de ReplicaSet, le scheduler et le kubelet avec containerd. 1 kubectl crée un Deployment. 2 l'API server signale le nouveau Deployment au contrôleur de Deployment. 3 celui-ci crée un ReplicaSet. 4 l'API server le signale au contrôleur de ReplicaSet. 5 celui-ci crée un Pod sans nœud. 6 l'API server signale le Pod à placer au scheduler. 7 le scheduler écrit nodeName = minikube. 8 l'API server signale au kubelet un Pod pour son nœud. 9 le kubelet, après Pulled, Created et Started, écrit le statut Running.">
Ce qui se passe après <code>kubectl create deployment</code>. Chaque acteur observe l'API server et y écrit ; aucun ne parle directement à un autre. Les événements relevés sur le cluster du cours suivent exactement cet ordre.
</Figure>

### L'API server, seule porte d'entrée

kubectl lui-même n'est qu'un client de cette API. L'option `-v=6` affiche les requêtes HTTP qu'il envoie :

```bash
kubectl get pods -v=6 2>&1 | grep Response
```

```sortie
"Response" verb="GET" url="https://192.168.49.2:8443/api/v1/namespaces/ch15/pods?limit=500" status="200 OK" milliseconds=8
```

Une requête `GET` en HTTPS sur l'adresse du nœud minikube, port 8443, chemin `/api/v1/namespaces/ch15/pods`. Tout objet Kubernetes a ainsi une adresse dans une API REST : lire, c'est `GET` ; créer, `POST` ; modifier, `PUT` ou `PATCH` ; supprimer, `DELETE`. Mais les contrôleurs ne passent pas leur temps à redemander la liste des Pods : ils ouvrent une requête de **surveillance** (*watch*), que l'API server garde ouverte et dans laquelle il envoie chaque changement au moment où il se produit. On peut l'ouvrir à la main :

```bash
kubectl get --raw '/api/v1/namespaces/ch15/pods?watch=1&labelSelector=app=vitrine' > watch.json &
kubectl delete pod vitrine-577cf576cf-szqf6 --wait=false
sleep 9; kill %1
jq -r '[.type, .object.metadata.name, .object.status.phase, (.object.metadata.deletionTimestamp // "-")] | @tsv' watch.json
```

```sortie
ADDED	vitrine-577cf576cf-szqf6	Running	-
ADDED	vitrine-577cf576cf-zj9cm	Running	-
MODIFIED	vitrine-577cf576cf-szqf6	Running	2026-09-25T16:27:28Z
ADDED	vitrine-577cf576cf-7pfgr	Pending	-
MODIFIED	vitrine-577cf576cf-szqf6	Running	2026-09-25T16:27:28Z
MODIFIED	vitrine-577cf576cf-7pfgr	Pending	-
MODIFIED	vitrine-577cf576cf-7pfgr	Pending	-
MODIFIED	vitrine-577cf576cf-szqf6	Succeeded	2026-09-25T16:26:58Z
MODIFIED	vitrine-577cf576cf-7pfgr	Pending	-
MODIFIED	vitrine-577cf576cf-szqf6	Succeeded	2026-09-25T16:26:58Z
DELETED	vitrine-577cf576cf-szqf6	Succeeded	2026-09-25T16:26:58Z
MODIFIED	vitrine-577cf576cf-7pfgr	Running	-
```

Chaque ligne est un objet JSON complet envoyé par l'API server : d'abord l'état initial (`ADDED` pour chaque Pod existant), puis chaque modification. La suppression se lit en deux temps : le Pod reçoit une date de suppression (`deletionTimestamp`) et reste visible le temps de s'arrêter proprement (chapitre 22), puis il disparaît (`DELETED`). C'est ce flux que suivent le ReplicaSet, le scheduler et le kubelet, et c'est lui qui rend le cluster si réactif : un contrôleur apprend un changement en quelques millisecondes, sans interroger personne.

### etcd, la mémoire du cluster

Où l'API server garde-t-il tous ces objets ? Dans **etcd**, une base de données clé-valeur distribuée, conçue pour ne jamais perdre une écriture confirmée, même quand une machine tombe (la partie V montrera comment). L'API server est le seul composant qui lui parle. Dans minikube, etcd tourne dans un Pod du namespace `kube-system`, et son client `etcdctl` permet de lister les clés :

```bash
kubectl exec -n kube-system etcd-minikube -- etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/var/lib/minikube/certs/etcd/ca.crt --cert=/var/lib/minikube/certs/etcd/server.crt \
  --key=/var/lib/minikube/certs/etcd/server.key \
  get --prefix /registry/ --keys-only | grep '/ch15/' | grep -v events
```

```sortie
/registry/configmaps/ch15/kube-root-ca.crt
/registry/deployments/ch15/vitrine
/registry/pods/ch15/vitrine-577cf576cf-fsz9f
/registry/pods/ch15/vitrine-577cf576cf-z9fzr
/registry/replicasets/ch15/vitrine-577cf576cf
/registry/serviceaccounts/ch15/default
```

Chaque objet est une clé, rangée par type, puis par namespace, puis par nom. Le Deployment, son ReplicaSet, ses deux Pods ; et deux objets que le namespace a reçus automatiquement, un certificat et un compte de service (partie VI). Sur ce cluster, etcd contient en tout 685 clés, dont 363 événements, qui expirent au bout d'une heure. Tout l'état du cluster est là : si etcd était perdu sans sauvegarde, le cluster oublierait tout ce qu'il doit faire tourner. C'est pourquoi la partie VII apprendra à le sauvegarder.

### Les composants d'un cluster

On peut maintenant dessiner le cluster entier. Il se divise en deux : le **plan de contrôle** (*control plane*), qui décide, et les **nœuds**, qui exécutent[^composants].

Le plan de contrôle compte quatre composants :

- **kube-apiserver** expose l'API, vérifie l'identité et les droits de qui l'appelle, valide les objets et les range dans etcd ;
- **etcd** garde l'état du cluster ;
- **kube-scheduler** choisit un nœud pour chaque Pod qui n'en a pas, selon les ressources demandées et libres, et une foule de contraintes (chapitre 32 ; son fonctionnement interne à la partie V) ;
- **kube-controller-manager** fait tourner les contrôleurs intégrés à Kubernetes. Ses journaux en énumèrent le démarrage : sur minikube, `kubectl logs -n kube-system kube-controller-manager-minikube` en montre une trentaine (celui des Deployments, des ReplicaSets, des Jobs, des nœuds, des namespaces, des quotas...).

Chaque nœud fait tourner trois programmes :

- le **kubelet**, qui surveille les Pods attribués à son nœud et les fait exister par l'intermédiaire du runtime ;
- le **runtime de conteneurs**, containerd dans minikube, qui crée les conteneurs avec runc (chapitre 11) ;
- **kube-proxy**, qui programme les règles réseau des Services (chapitre 20).

Dans minikube, tout cela est rassemblé sur une seule machine, le conteneur `minikube`. Les composants du plan de contrôle y tournent eux-mêmes dans des Pods, décrits par des fichiers que le kubelet lit directement sur le disque, sans passer par l'API server : ce sont des **Pods statiques**, le moyen de démarrer l'API server alors qu'il n'y a pas encore d'API server.

```bash
minikube ssh -- ls -l /etc/kubernetes/manifests
kubectl get --raw='/readyz?verbose' | tail -2
```

```sortie
total 20
-rw------- 1 root root 2655 Sep 25 09:02 etcd.yaml
-rw------- 1 root root 4171 Sep 25 09:02 kube-apiserver.yaml
-rw------- 1 root root 3254 Sep 25 09:02 kube-controller-manager.yaml
-rw------- 1 root root 1727 Sep 25 09:02 kube-scheduler.yaml
[+]shutdown ok
readyz check passed
```

Dans un cluster de production, le plan de contrôle tourne sur trois machines ou plus, pour survivre à la perte de l'une d'elles, et les applications tournent sur d'autres nœuds.

<Figure svg={architectureCluster} num="15.2" alt="kubectl parle en HTTPS à kube-apiserver, au centre du plan de contrôle. kube-scheduler et kube-controller-manager surveillent l'API server par des watch. L'API server est le seul à parler à etcd, qui garde l'état du cluster. Deux nœuds, chacun avec un kubelet, kube-proxy, containerd et des Pods ; chaque kubelet surveille l'API server et y écrit le statut des Pods.">
Les composants d'un cluster Kubernetes. Tout passe par l'API server ; chaque composant observe les objets qui le concernent et y écrit.
</Figure>

## Quand une machine tombe

Revenons au problème du début. Il faut au moins deux machines pour voir un orchestrateur déplacer des Pods, et minikube sait en simuler plusieurs : chaque nœud est alors un conteneur Docker. Arrêtez d'abord le cluster principal pour libérer de la mémoire, puis créez un cluster de deux nœuds, dans un **profil** séparé nommé `deux-noeuds` (le chapitre 16 revient sur les profils) :

```bash
minikube stop
minikube start -p deux-noeuds --driver=docker --nodes=2 --cpus=2 --memory=2g --kubernetes-version=v1.37.0
kubectl wait --for=condition=Ready nodes --all --timeout=180s
kubectl get nodes -o wide
```

```sortie
NAME              STATUS   ROLES           AGE   VERSION   INTERNAL-IP    EXTERNAL-IP   OS-IMAGE
deux-noeuds       Ready    control-plane   46s   v1.37.0   192.168.58.2   <none>        Debian GNU/Linux 12 (bookworm)
deux-noeuds-m02   Ready    <none>          30s   v1.37.0   192.168.58.3   <none>        Debian GNU/Linux 12 (bookworm)
```

Le premier nœud porte le plan de contrôle ; le second, `deux-noeuds-m02`, n'accueille que des applications. `minikube start` a basculé kubectl sur ce nouveau cluster. Déployons quatre copies de `vitrine` :

```bash
kubectl create deployment vitrine --image=nginx:1.30-alpine --replicas=4
kubectl rollout status deployment/vitrine
kubectl get pods -o wide
```

```sortie
NAME                      STATUS   NODE
vitrine-577cf576cf-4xkbz  Running  deux-noeuds
vitrine-577cf576cf-bcp22  Running  deux-noeuds-m02
vitrine-577cf576cf-hw7hs  Running  deux-noeuds
vitrine-577cf576cf-ttgnt  Running  deux-noeuds-m02
```

(La sortie est réduite à trois colonnes.) Le scheduler a réparti les Pods, deux par nœud. Maintenant, débranchons le second nœud, sans prévenir personne : `docker stop` éteint son conteneur, comme une coupure de courant éteindrait une machine. Pour suivre ce qui se passe, une petite boucle affiche l'état du nœud, ses *taints* (des marques posées sur un nœud, que le chapitre 32 détaillera) et la répartition des Pods, chaque fois que quelque chose change :

```bash
t0=$(date +%s); docker stop deux-noeuds-m02; last=''
while [ $(( $(date +%s)-t0 )) -lt 480 ]; do
  e=$(( $(date +%s)-t0 ))
  n=$(kubectl get node deux-noeuds-m02 --no-headers | awk '{print $2}')
  t=$(kubectl get node deux-noeuds-m02 -o jsonpath='{range .spec.taints[*]}{.key}:{.effect} {end}')
  p=$(kubectl get pods -o wide --no-headers | awk '{print $3"@"$7}' | sort | uniq -c | tr -s ' ' | tr '\n' ';')
  cur="noeud=$n | taints=$t | pods=$p"
  [ "$cur" != "$last" ] && echo "t=$e s : $cur" && last=$cur
  sleep 3
done
```

```sortie
t=0 s : noeud=Ready | taints= | pods= 2 Running@deux-noeuds; 2 Running@deux-noeuds-m02;
t=49 s : noeud=NotReady | taints=node.kubernetes.io/unreachable:NoSchedule node.kubernetes.io/unreachable:NoExecute  | pods= 2 Running@deux-noeuds; 2 Running@deux-noeuds-m02;
t=348 s : noeud=NotReady | taints=node.kubernetes.io/unreachable:NoSchedule node.kubernetes.io/unreachable:NoExecute  | pods= 4 Running@deux-noeuds; 2 Terminating@deux-noeuds-m02;
```

Trois instants seulement, mais chacun a une explication précise.

**De 0 à 49 secondes, rien ne change.** Le nœud est éteint, mais le cluster le croit encore `Ready`, et ses deux Pods encore `Running`. Le plan de contrôle ne peut pas voir une machine s'éteindre : il ne sait que ce que le kubelet lui dit. Or le kubelet signale sa présence en renouvelant un bail (un objet *Lease*) toutes les dix secondes environ[^heartbeat]. Le contrôleur des nœuds attend un certain délai sans nouvelles, `--node-monitor-grace-period`, de 50 secondes par défaut[^kcm], avant de conclure que le nœud est injoignable. Un délai plus court provoquerait de fausses alertes à chaque ralentissement du réseau.

**À 49 secondes, le nœud passe `NotReady`.** Le contrôleur des nœuds lui pose deux taints `node.kubernetes.io/unreachable`. `NoSchedule` interdit d'y placer de nouveaux Pods. `NoExecute` demande d'en chasser les Pods qui s'y trouvent, mais pas tout de suite.

**À 348 secondes, les Pods sont remplacés.** Chaque Pod porte, par défaut, une tolérance à ces taints, limitée à 300 secondes :

```bash
kubectl get pods -o json | jq -r '.items[0].spec.tolerations[] | select(.key|test("node.kubernetes.io")) | "\(.key) \(.effect) \(.tolerationSeconds)"'
```

```sortie
node.kubernetes.io/not-ready NoExecute 300
node.kubernetes.io/unreachable NoExecute 300
```

Kubernetes ajoute ces tolérances à tous les Pods qui n'en déclarent pas d'autres[^taint-evict]. Pendant cinq minutes, il suppose que le nœud va revenir : une machine qui redémarre, un câble réseau débranché par erreur ne doivent pas provoquer le déplacement de toutes ses applications. 49 + 300 = 349 : au bout de ce délai, les deux Pods sont marqués pour suppression, et le ReplicaSet, qui ne compte plus que deux Pods valides, en crée deux autres, que le scheduler place sur le seul nœud disponible. Les anciens restent affichés `Terminating` : pour confirmer leur arrêt, il faudrait que le kubelet du nœud éteint réponde.

<Figure svg={panneNoeud} num="15.3" alt="Chronologie de 0 à 400 secondes. À 0 s, docker stop éteint le nœud 2 ; jusqu'à 49 s, il est encore Ready pour l'API. À 49 s, plus de nouvelles du kubelet : NotReady, taint unreachable NoExecute. Les deux Pods du nœud 2 restent Running pour l'API jusqu'à 348 s, puis Terminating. À 348 s, soit 49 plus 300 secondes de tolérance, des remplaçants sont créés sur le nœud 1.">
Chronologie réelle d'une panne de nœud sur un cluster minikube à deux nœuds. Pendant presque six minutes, deux des quatre copies de l'application sont perdues sans que l'API le sache.
</Figure>

Six minutes, c'est long pour un service qui doit rester joignable. Deux enseignements en découlent. D'abord, on ne compte pas sur le remplacement des Pods pour la disponibilité : on fait tourner assez de copies, réparties sur plusieurs nœuds, pour que la perte d'une machine ne se remarque pas (la partie IV montrera comment l'exiger). Ensuite, ces délais sont des réglages : un Pod peut déclarer une tolérance plus courte, s'il vaut mieux le déplacer vite que risquer une fausse alerte.

Rallumons le nœud :

```bash
minikube node stop m02 -p deux-noeuds
minikube node start m02 -p deux-noeuds
kubectl get nodes
kubectl get pods -o wide
```

```sortie
NAME              STATUS   ROLES           AGE   VERSION
deux-noeuds       Ready    control-plane   12m   v1.37.0
deux-noeuds-m02   Ready    <none>          12m   v1.37.0
NAME                      STATUS   NODE
vitrine-577cf576cf-4xkbz  Running  deux-noeuds
vitrine-577cf576cf-5f2f5  Running  deux-noeuds
vitrine-577cf576cf-hw7hs  Running  deux-noeuds
vitrine-577cf576cf-vfw26  Running  deux-noeuds
```

:::panne[Le nœud reste NotReady après un docker start]

Rallumer le conteneur du nœud avec `docker start deux-noeuds-m02` ne suffit pas : le nœud reste `NotReady`, et les journaux de son kubelet (`minikube ssh -p deux-noeuds -n deux-noeuds-m02 -- sudo journalctl -u kubelet -n 5`) répètent `Unable to register mirror pod because node is not registered yet`. Le conteneur a redémarré, mais pas la configuration que minikube applique à chaque démarrage d'un nœud. Passez toujours par minikube : `minikube node stop m02 -p deux-noeuds`, puis `minikube node start m02 -p deux-noeuds`. Un simple `minikube node start` sur un nœud dont le conteneur tourne déjà répond `m02 est déjà en cours d'exécution` et ne fait rien.

:::

Le nœud est revenu, les anciens Pods ont enfin disparu, et les quatre copies restent sur le premier nœud. Kubernetes ne rééquilibre pas de lui-même : il a atteint l'état désiré (quatre Pods), et la répartition n'en fait pas partie tant qu'on ne la demande pas. Supprimer quelques Pods suffirait à les faire replacer, cette fois sur les deux nœuds.

Arrêtez ce cluster, qui resservira au chapitre 32, et revenez au cluster principal :

```bash
minikube stop -p deux-noeuds
minikube start
kubectl config set-context --current --namespace=ch15
```

## Ce qu'un orchestrateur ne fait pas

Kubernetes relance, remplace, répartit. Il ne rend pas une application fiable si elle ne l'est pas : un programme qui plante à chaque requête plantera sur toutes les machines, et Kubernetes le relancera indéfiniment (c'est le fameux `CrashLoopBackOff` du chapitre 17). Il ne sauvegarde pas vos données : une base de données dans un Pod perd tout si son stockage n'est pas prévu pour durer (partie IV). Et il ajoute sa propre complexité : un cluster est un système distribué, avec ses délais, ses états intermédiaires, ses composants qui peuvent eux-mêmes tomber en panne. Pour une application qui tient sur une machine et peut s'arrêter quelques minutes, Compose reste un choix raisonnable.

Le reste de cette partie apprend à exprimer l'état désiré d'une vraie application, Colis, avec les objets de Kubernetes : des Pods, des Deployments, des Services, de la configuration, des sondes de santé et des limites de ressources.

## Exercices

:::exercice[Exercice 1 : supprimer le ReplicaSet]

Dans le namespace `ch15`, remettez `vitrine` à trois répliques, puis supprimez son ReplicaSet (`kubectl get rs` donne son nom). Que deviennent les Pods ? Que se passe-t-il ensuite, et quel composant agit ? Comparez les noms du ReplicaSet et des Pods avant et après.

:::

<details>
<summary>Corrigé</summary>

```bash
kubectl scale deployment vitrine --replicas=3
kubectl delete replicaset vitrine-577cf576cf
sleep 5
kubectl get rs
kubectl get pods --no-headers | awk '{print $1, $5}'
```

```sortie
replicaset.apps "vitrine-577cf576cf" deleted from ch15x namespace
NAME                 DESIRED   CURRENT   READY   AGE
vitrine-577cf576cf   3         3         3       5s
vitrine-577cf576cf-8hzk8 5s
vitrine-577cf576cf-r8q8b 5s
vitrine-577cf576cf-rbfd5 5s
```

(Sortie relevée dans un namespace d'essai, `ch15x`.) Supprimer le ReplicaSet supprime ses Pods : ils lui appartiennent, et Kubernetes supprime en cascade les objets dont le propriétaire disparaît. Mais le contrôleur de Deployment constate aussitôt qu'il n'existe plus de ReplicaSet correspondant à son modèle, et en recrée un. Il porte **le même nom**, `vitrine-577cf576cf`, parce que ce suffixe est une empreinte du modèle de Pod (`pod-template-hash`) : même modèle, même empreinte. Le nouveau ReplicaSet crée trois nouveaux Pods, aux noms nouveaux. Deux niveaux de réconciliation ont joué l'un après l'autre.

</details>

:::exercice[Exercice 2 : surveiller plutôt que demander]

Lancez `kubectl get pods -w -v=6` pendant quelques secondes, puis arrêtez-le. Combien de requêtes HTTP kubectl a-t-il envoyées ? Qu'ont-elles de différent ? Pourquoi est-ce important pour un cluster de milliers de nœuds ?

:::

<details>
<summary>Corrigé</summary>

```bash
kubectl get pods -w -v=6 2>&1 | grep -oE 'verb="GET" url="[^"]*"'
```

```sortie
verb="GET" url="https://192.168.49.2:8443/api/v1/namespaces/ch15x/pods?limit=500"
verb="GET" url="https://192.168.49.2:8443/api/v1/namespaces/ch15x/pods?resourceVersion=3312&watch=true"
```

Deux requêtes seulement, quelle que soit la durée de la surveillance. La première lit la liste. La seconde ouvre une surveillance à partir de la version de la liste qu'il vient de recevoir (`resourceVersion=3312`), pour ne manquer aucun changement survenu entre les deux. Ensuite, c'est l'API server qui envoie les changements, sur la même connexion. Si chaque kubelet d'un cluster de 5 000 nœuds redemandait la liste de ses Pods toutes les secondes, l'API server et etcd crouleraient sous des réponses presque toujours identiques ; avec des surveillances, ils n'envoient que ce qui change.

</details>

:::exercice[Exercice 3 : ce que le ReplicaSet surveille vraiment]

Prenez un Pod de `vitrine` et changez son image à la main avec `kubectl set image pod/<nom> nginx=nginx:1.29-alpine`. Le ReplicaSet remet-il la bonne image ? Changez ensuite l'étiquette `app` de ce Pod en `orphelin`. Que se passe-t-il ? Qu'en concluez-vous sur la façon dont un ReplicaSet reconnaît « ses » Pods ?

:::

<details>
<summary>Corrigé</summary>

```bash
P=$(kubectl get pods -o jsonpath='{.items[0].metadata.name}')
kubectl set image pod/$P nginx=nginx:1.29-alpine
kubectl label pod $P app=orphelin --overwrite
kubectl get pods -o 'custom-columns=NOM:.metadata.name,APP:.metadata.labels.app,PROPRIETAIRE:.metadata.ownerReferences[0].name,IMAGE:.spec.containers[0].image'
```

```sortie
NOM                        APP        PROPRIETAIRE         IMAGE
vitrine-577cf576cf-6xmjt   vitrine    vitrine-577cf576cf   nginx:1.30-alpine
vitrine-577cf576cf-8hzk8   orphelin   <none>               nginx:1.29-alpine
vitrine-577cf576cf-r8q8b   vitrine    vitrine-577cf576cf   nginx:1.30-alpine
vitrine-577cf576cf-rbfd5   vitrine    vitrine-577cf576cf   nginx:1.30-alpine
```

Après le changement d'image, le kubelet a redémarré le conteneur avec `nginx:1.29-alpine` (`RESTARTS 1`), et le ReplicaSet n'a rien fait : il ne compare pas le contenu des Pods à son modèle, il les **compte**. Après le changement d'étiquette, le Pod ne correspond plus au sélecteur `app=vitrine` : le ReplicaSet l'abandonne (plus de propriétaire), n'en compte plus que deux, et en crée un quatrième. Le Pod orphelin continue de tourner, mais plus personne ne le surveille. Un ReplicaSet reconnaît ses Pods par leurs étiquettes, et c'est tout. Le chapitre 19 montrera que c'est le Deployment, et non le ReplicaSet, qui gère les changements de modèle ; et c'est une bonne raison de ne jamais modifier un Pod géré à la main. Supprimez l'orphelin : `kubectl delete pod -l app=orphelin`.

</details>

:::exercice[Exercice 4 : le bail du kubelet]

Le nœud `minikube` renouvelle un bail dans le namespace `kube-node-lease`. Relevez trois fois son champ `spec.renewTime` à dix secondes d'intervalle, ainsi que `spec.leaseDurationSeconds`. Que se passerait-il, d'après ce chapitre, si le kubelet cessait de le renouveler ?

:::

<details>
<summary>Corrigé</summary>

```bash
kubectl get lease -n kube-node-lease
for i in 1 2 3; do kubectl get lease minikube -n kube-node-lease -o jsonpath='{.spec.renewTime}{"\n"}'; sleep 10; done
kubectl get lease minikube -n kube-node-lease -o jsonpath='{.spec.leaseDurationSeconds}{"\n"}'
```

```sortie
NAME       HOLDER     AGE
minikube   minikube   7h47m
2026-09-25T16:49:56.958924Z
2026-09-25T16:50:07.036298Z
2026-09-25T16:50:17.205859Z
40
```

Le bail est renouvelé toutes les dix secondes environ, pour une durée de validité de 40 secondes. C'est le « battement de cœur » du nœud : un petit objet qu'on met à jour, plutôt que le statut complet du nœud, beaucoup plus volumineux, ce qui ménage l'API server et etcd. Si le kubelet cessait de le renouveler, le contrôleur des nœuds attendrait le délai de grâce (50 secondes par défaut), passerait le nœud `NotReady`, lui poserait les taints `unreachable`, et cinq minutes plus tard les Pods seraient recréés ailleurs : exactement la chronologie de la figure 15.3. Sur un cluster d'un seul nœud, il n'y aurait simplement nulle part où les recréer.

</details>

## Nettoyer

Supprimez le namespace du chapitre, ce qui supprime tout ce qu'il contient, et revenez au namespace par défaut :

```bash
kubectl delete namespace ch15
kubectl config set-context --current --namespace=default
```

Le cluster `deux-noeuds` est arrêté ; il se supprime avec `minikube delete -p deux-noeuds` si vous ne comptez pas suivre le chapitre 32 tout de suite. Laissez le cluster principal tourner pour le chapitre 16, ou arrêtez-le avec `minikube stop`.

[^borg]: Abhishek Verma, Luis Pedrosa, Madhukar Korupolu, David Oppenheimer, Eric Tune, John Wilkes, « Large-scale cluster management at Google with Borg », *EuroSys 2015*. [research.google/pubs/large-scale-cluster-management-at-google-with-borg](https://research.google/pubs/large-scale-cluster-management-at-google-with-borg/)

[^omega]: Malte Schwarzkopf, Andy Konwinski, Michael Abd-El-Malek, John Wilkes, « Omega: flexible, scalable schedulers for large compute clusters », *EuroSys 2013*. [research.google/pubs/omega-flexible-scalable-schedulers-for-large-compute-clusters](https://research.google/pubs/omega-flexible-scalable-schedulers-for-large-compute-clusters/)

[^k8s-nom]: Kubernetes, « Overview », sur l'origine du nom et l'abréviation K8s. [kubernetes.io/docs/concepts/overview](https://kubernetes.io/docs/concepts/overview/)

[^k8s-10ans]: Kubernetes Blog, « 10 Years of Kubernetes », 6 juin 2024. [kubernetes.io/blog/2024/06/06/10-years-of-kubernetes](https://kubernetes.io/blog/2024/06/06/10-years-of-kubernetes/)

[^cncf]: Cloud Native Computing Foundation, « Cloud Native Computing Foundation Announces Kubernetes is First Project to Graduate », 6 mars 2018. [cncf.io/announcements/2018/03/06/cloud-native-computing-foundation-announces-kubernetes-first-graduated-project](https://www.cncf.io/announcements/2018/03/06/cloud-native-computing-foundation-announces-kubernetes-first-graduated-project/)

[^borg-omega-k8s]: Brendan Burns, Brian Grant, David Oppenheimer, Eric Brewer, John Wilkes, « Borg, Omega, and Kubernetes », *ACM Queue*, vol. 14, n° 1, 2016. [queue.acm.org/detail.cfm?id=2898444](https://queue.acm.org/detail.cfm?id=2898444)

[^controleur]: Kubernetes, « Controllers », section *Controller pattern*. [kubernetes.io/docs/concepts/architecture/controller](https://kubernetes.io/docs/concepts/architecture/controller/)

[^composants]: Kubernetes, « Kubernetes Components ». [kubernetes.io/docs/concepts/overview/components](https://kubernetes.io/docs/concepts/overview/components/)

[^heartbeat]: Kubernetes, « Nodes », section *Node heartbeats*. [kubernetes.io/docs/concepts/architecture/nodes/#node-heartbeats](https://kubernetes.io/docs/concepts/architecture/nodes/#node-heartbeats)

[^kcm]: Kubernetes, « kube-controller-manager », référence de l'option `--node-monitor-grace-period`. [kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/)

[^taint-evict]: Kubernetes, « Taints and Tolerations », section *Taint based Evictions*. [kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/#taint-based-evictions](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/#taint-based-evictions)
