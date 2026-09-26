---
title: L'ordonnancement fin
sidebar_label: 32. L'ordonnancement fin
description: "Décider où tournent les Pods, sur un minikube de trois nœuds : sélecteurs et affinités de nœuds, affinités et anti-affinités entre Pods, taints et tolérances, contraintes de répartition entre zones, priorités et préemption, et un simulateur pour voir le scheduler filtrer et noter les nœuds."
partie: 4
chapitre: '32'
---

import cycleScheduler from '@site/src/figures/cycle-scheduler.svg';
import repartitionZones from '@site/src/figures/repartition-zones.svg';
import Ordonnanceur from '@site/src/components/Ordonnanceur';

Jusqu'ici, la question « sur quel nœud ce Pod va-t-il tourner ? » ne se posait pas : minikube n'avait qu'un nœud. Dans un vrai cluster, elle se pose sans arrêt, et la réponse par défaut du scheduler (le nœud qui a le plus de place) ne suffit pas toujours. Les trois répliques de l'API de Colis ne doivent pas se retrouver sur la même machine, sinon une panne de cette machine coupe tout. La base de données veut un nœud à disques rapides. Un nœud équipé d'un GPU coûteux doit être réservé aux calculs qui en ont besoin. Un service critique doit passer devant les tâches de fond quand la place manque.

Ce chapitre présente les outils qui permettent d'exprimer ces règles, dans l'ordre où le scheduler les applique (figure 32.1). Le scheduler fonctionne en trois temps pour chaque Pod en attente : il **filtre** les nœuds qui peuvent l'accueillir, il **note** ceux qui restent, et il **lie** le Pod au mieux noté en écrivant son `nodeName`[^framework]. La partie V ouvrira le scheduler lui-même ; ici, on apprend à le guider.

<Figure svg={cycleScheduler} num="32.1" alt="Le cycle du scheduler. Les Pods sans nodeName attendent dans une file. 1, le filtrage : quels nœuds le peuvent ? avec NodeAffinity (sélecteur, affinités), TaintToleration (taints), NodeUnschedulable (cordon), NodeResourcesFit (requests), InterPodAffinity, PodTopologySpread. Les nœuds retenus passent au 2, le score : lequel est le meilleur ? chaque extension note de 0 à 100, multipliée par son poids : place libre, affinités préférées, répartition, image déjà présente. Le plus haut passe au 3, la liaison : nodeName est écrit, le kubelet démarre le Pod. Si aucun nœud ne convient, le Pod reste Pending, avec le message 0/3 nodes are available, et, s'il est prioritaire, le scheduler peut préempter des Pods de priorité plus basse sur un nœud où cela suffit ; le Pod est réessayé plus tard, ou au cycle suivant.">
Les trois temps d'une décision du scheduler, et les extensions (<em>plugins</em>) qui interviennent à chacun. Chaque mécanisme de ce chapitre se branche à l'un de ces endroits.
</Figure>

## Un cluster de trois nœuds

Les manipulations se font sur le profil minikube `deux-noeuds` du chapitre 15, auquel on ajoute un troisième nœud. Pour rester sous 6 Gio, arrêtez d'abord le cluster principal (Colis s'arrête avec lui ; il repartira au `minikube start`) :

```bash
minikube stop
minikube start -p deux-noeuds
minikube node add -p deux-noeuds
kubectl create namespace ch32
kubectl config set-context --current --namespace=ch32
```

Les fichiers sont dans [l'archive ordonnancement](pathname:///kits/ordonnancement.tar.gz). Dans un cluster hébergé chez un fournisseur de cloud, chaque nœud porte l'étiquette `topology.kubernetes.io/zone`, qui dit dans quelle zone de disponibilité (quel bâtiment, en gros) il se trouve[^etiquettes]. Nos trois nœuds sont sur votre poste ; le script `zones.sh` leur donne une zone chacun, et une étiquette `disque=ssd` au troisième :

```bash
./zones.sh
kubectl get nodes -L topology.kubernetes.io/zone,disque
kubectl get nodes -o custom-columns=NOM:.metadata.name,CPU:.status.allocatable.cpu,MEMOIRE:.status.allocatable.memory
```

```sortie
NAME              STATUS   ROLES           AGE    VERSION   ZONE     DISQUE
deux-noeuds       Ready    control-plane   22h    v1.37.0   zone-a   
deux-noeuds-m02   Ready    <none>          22h    v1.37.0   zone-b   
deux-noeuds-m03   Ready    <none>          2m2s   v1.37.0   zone-c   ssd
NOM               CPU   MEMOIRE
deux-noeuds       22    15778000Ki
deux-noeuds-m02   22    15778000Ki
deux-noeuds-m03   22    15778000Ki
```

Chaque nœud annonce les 22 cœurs et les 15 Gio du poste (chapitre 23) : le scheduler croit disposer de trois fois plus qu'il n'y a. C'est sans conséquence pour les Pods minuscules de ce chapitre (l'image `pause`, qui ne fait rien), et on s'en servira pour la préemption.

## Choisir des nœuds

### Le sélecteur de nœud

La forme la plus simple : `nodeSelector` liste des étiquettes que le nœud doit porter, toutes.

```yaml title="selecteur.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: rapide
spec:
  nodeSelector:
    disque: ssd
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.10
```

Le Pod `introuvable` est le même avec `disque: nvme`, qu'aucun nœud ne porte :

```bash
kubectl apply -f selecteur.yaml -f introuvable.yaml
kubectl get pods -o wide
kubectl describe pod introuvable | sed -n '/^Events:/,$p'
```

```sortie
NAME          READY   STATUS    RESTARTS   AGE   IP            NODE             
introuvable   0/1     Pending   0          8s    <none>        <none>           
rapide        1/1     Running   0          8s    10.244.2.17   deux-noeuds-m03  
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  8s    default-scheduler  0/3 nodes are available: 3 node(s) didn't match Pod's node affinity/selector. preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.
```

Le message du scheduler est à lire attentivement, parce que c'est le premier outil de diagnostic de ce chapitre : `0/3 nodes are available` suivi, pour chaque raison, du nombre de nœuds écartés pour elle. Ici, les trois pour la même raison. La seconde partie parle de préemption : évincer d'autres Pods ne donnerait pas une étiquette à un nœud, donc elle n'aiderait pas. Le Pod attendra indéfiniment qu'un nœud porte `disque=nvme`.

### Les affinités de nœud

L'affinité de nœud dit la même chose avec plus de nuances. Ses expressions acceptent des opérateurs (`In`, `NotIn`, `Exists`, `DoesNotExist`, `Gt`, `Lt`), et elle vient en deux forces[^affinites]. `requiredDuringSchedulingIgnoredDuringExecution` est une obligation, comme le sélecteur. `preferredDuringSchedulingIgnoredDuringExecution` est une préférence, avec un poids de 1 à 100, qui intervient au moment du score : le Pod ira sur un nœud qui convient si possible, ailleurs sinon. Le suffixe `IgnoredDuringExecution` précise qu'une fois le Pod placé, retirer l'étiquette du nœud ne le fait pas partir.

```yaml title="preference.yaml (extrait)"
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            preference:
              matchExpressions:
              - key: disque
                operator: In
                values: [ssd]
```

```bash
kubectl apply -f preference.yaml
kubectl get pods -l app=preference -o custom-columns=POD:.metadata.name,NOEUD:.spec.nodeName --no-headers
```

```sortie
preference-7b6bf998f6-5zj6v   deux-noeuds-m03
preference-7b6bf998f6-mrzlt   deux-noeuds-m03
preference-7b6bf998f6-p69mc   deux-noeuds-m03
```

Les trois répliques sont allées sur le nœud SSD. C'est ce qu'on a demandé, et c'est aussi un risque : si ce nœud tombe, toutes les répliques tombent avec lui. Une préférence forte l'emporte sur la dispersion naturelle du scheduler ; on verra comment corriger cela plus loin.

## Placer les Pods les uns par rapport aux autres

### L'anti-affinité

L'anti-affinité entre Pods interdit (ou déconseille) de placer un Pod dans le même **domaine** qu'un autre Pod qui porte certaines étiquettes. Le domaine est défini par une étiquette des nœuds, `topologyKey` : avec `kubernetes.io/hostname`, un domaine est un nœud ; avec `topology.kubernetes.io/zone`, c'est une zone.

```yaml title="dispersion.yaml (extrait)"
spec:
  replicas: 4
  template:
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels: {app: dispersion}
            topologyKey: kubernetes.io/hostname
```

Quatre répliques, jamais deux sur le même nœud, et trois nœuds :

```bash
kubectl apply -f dispersion.yaml
kubectl get pods -l app=dispersion -o custom-columns=POD:.metadata.name,NOEUD:.spec.nodeName,ETAT:.status.phase --no-headers
```

```sortie
dispersion-99d694f98-ssq6q   <none>            Pending
dispersion-99d694f98-flgmm   deux-noeuds       Running
dispersion-99d694f98-nf6m9   deux-noeuds-m02   Running
dispersion-99d694f98-6bbwf   deux-noeuds-m03   Running
```

```sortie
  Warning  FailedScheduling  12s   default-scheduler  0/3 nodes are available: 3 node(s) didn't match pod anti-affinity rules. preemption: 0/3 nodes are available: 3 No preemption victims found for incoming pod.
```

Une réplique par nœud, et la quatrième attend un quatrième nœud. C'est la bonne réponse pour une application qui ne supporte pas deux répliques sur la même machine (un nœud de base de données répliquée, par exemple), mais c'est rigide : un nœud en maintenance, et une réplique ne peut plus être placée. La forme `preferred` de l'anti-affinité, ou les contraintes de répartition plus bas, sont plus souples.

### L'affinité

À l'inverse, l'affinité entre Pods rapproche : un Pod qui lit beaucoup un cache local veut tourner sur le même nœud que lui.

```yaml title="voisin.yaml (extrait)"
      podAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels: {role: cache}
          topologyKey: kubernetes.io/hostname
```

```sortie
POD      NOEUD             ETAT
cache    deux-noeuds-m02   Running
voisin   deux-noeuds-m02   Running
```

Le Pod `cache` a été placé à la main sur `m02` (par `nodeName`, ce qui court-circuite le scheduler) ; `voisin` l'a suivi. Les affinités entre Pods sont les règles les plus coûteuses à évaluer pour le scheduler, puisqu'il faut examiner les Pods de chaque domaine : sur de grands clusters, la documentation déconseille d'en abuser[^affinites].

## Répartir entre les zones

Une contrainte de répartition (*topology spread constraint*) exprime directement ce qu'on veut le plus souvent : que les répliques soient réparties à peu près également entre les domaines. `maxSkew` est l'écart maximal toléré entre le domaine le plus chargé et le moins chargé[^repartition]. Reprenons les sept répliques qui préfèrent le SSD, sans contrainte et avec :

```yaml title="repartition.yaml (extrait)"
    spec:
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            preference:
              matchExpressions:
              - key: disque
                operator: In
                values: [ssd]
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: topology.kubernetes.io/zone
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels: {app: repartition}
```

```bash
kubectl apply -f sans-contrainte.yaml -f repartition.yaml
for a in sans-contrainte repartition; do echo "== $a"; kubectl get pods -l app=$a -o custom-columns=NOEUD:.spec.nodeName --no-headers | sort | uniq -c; done
```

```sortie
== sans-contrainte
      7 deux-noeuds-m03
== repartition
      2 deux-noeuds
      2 deux-noeuds-m02
      3 deux-noeuds-m03
```

<Figure svg={repartitionZones} num="32.2" alt="Deux répartitions mesurées de 7 répliques qui préfèrent le nœud SSD. Sans contrainte : aucune en zone-a, aucune en zone-b, 7 en zone-c (SSD) ; la préférence pour le SSD attire tout sur un seul nœud, qu'une panne emporterait. Avec maxSkew 1 : 2 en zone-a, 2 en zone-b, 3 en zone-c ; au plus une réplique d'écart entre zones, la préférence ne départage que le reste.">
Sept répliques qui préfèrent le SSD, sans et avec contrainte de répartition. Relevé sur le cluster du cours.
</Figure>

Sans contrainte, la préférence a tout attiré sur `m03`, les sept répliques. Avec `maxSkew: 1`, la contrainte passe avant la préférence : aucune zone n'a plus d'une réplique de plus qu'une autre, et la préférence ne décide que de qui reçoit la réplique en trop (la septième, sur le SSD). Passé à 9 répliques, le Deployment donne 3/3/3. `whenUnsatisfiable: DoNotSchedule` fait de la contrainte une obligation (un filtre) ; `ScheduleAnyway` en fait une préférence (un score), qui laisse placer le Pod même si l'écart doit grandir, par exemple quand une zone entière est indisponible. Depuis Kubernetes 1.24, le scheduler applique de lui-même une répartition par défaut, souple, par nœud et par zone ; c'est pourquoi des répliques sans contrainte ni préférence se répartissent déjà d'elles-mêmes.

## Réserver des nœuds : taints et tolérances

Les affinités attirent les Pods vers des nœuds. Les **taints** font l'inverse : un taint, posé sur un nœud, repousse tous les Pods qui ne le **tolèrent** pas explicitement[^taints]. Un taint a une clé, une valeur, et un effet : `NoSchedule` (aucun nouveau Pod sans tolérance), `PreferNoSchedule` (à éviter si possible), ou `NoExecute` (et les Pods déjà présents sans tolérance sont évincés). Réservons le nœud SSD au calcul :

```bash
kubectl taint node deux-noeuds-m03 dedie=calcul:NoSchedule
kubectl describe node deux-noeuds-m03 | grep Taints
```

```sortie
node/deux-noeuds-m03 tainted
Taints:             dedie=calcul:NoSchedule
```

Un Pod qui demande le SSD sans tolérer le taint reste en attente, et un Pod qui le tolère (et qui demande aussi le SSD) passe :

```yaml title="dedie.yaml (extrait)"
spec:
  nodeSelector:
    disque: ssd
  tolerations:
  - key: dedie
    operator: Equal
    value: calcul
    effect: NoSchedule
```

```sortie
POD              NOEUD             ETAT
calcul           deux-noeuds-m03   Running
sans-tolerance   <none>            Pending
  Warning  FailedScheduling  8s    default-scheduler  0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 node(s) didn't match Pod's node affinity/selector. preemption: ...
```

Le message du scheduler donne les deux raisons, nœud par nœud : un nœud a un taint non toléré, deux n'ont pas l'étiquette. Notez que la tolérance seule ne suffit pas à réserver le nœud à `calcul` : elle **autorise** le Pod à aller sur `m03`, elle ne l'y **envoie** pas. Pour un nœud dédié, on combine les deux : un taint pour repousser les autres, une étiquette et un sélecteur (ou une affinité) pour attirer les siens. C'est la méthode des fournisseurs de cloud pour les nœuds à GPU.

### NoExecute : vider un nœud

Avec `NoExecute`, le taint agit aussi sur les Pods déjà en place. Sept répliques tournent sur les deux premiers nœuds (le troisième a toujours son taint `dedie`) ; posons un taint `NoExecute` sur `m02` :

```bash
kubectl apply -f sans-contrainte.yaml
kubectl get pods -l app=sans-contrainte -o custom-columns=NOEUD:.spec.nodeName --no-headers | sort | uniq -c
kubectl taint node deux-noeuds-m02 maintenance=oui:NoExecute
sleep 10
kubectl get pods -l app=sans-contrainte -o custom-columns=NOEUD:.spec.nodeName --no-headers | sort | uniq -c
kubectl get events --field-selector reason=TaintManagerEviction -o custom-columns=POD:.involvedObject.name,MESSAGE:.message | head -3
```

```sortie
      3 deux-noeuds
      4 deux-noeuds-m02
node/deux-noeuds-m02 tainted
      7 deux-noeuds
POD                             MESSAGE
sans-contrainte-874f79d-7m9nh   Marking for deletion Pod ch32/sans-contrainte-874f79d-7m9nh
sans-contrainte-874f79d-g8v99   Marking for deletion Pod ch32/sans-contrainte-874f79d-g8v99
```

Les quatre Pods de `m02` ont été évincés par le contrôleur des taints, et le Deployment les a recréés sur le seul nœud restant. Les Pods système, eux, sont restés :

```bash
kubectl -n kube-system get pods -o wide --field-selector spec.nodeName=deux-noeuds-m02
kubectl -n kube-system get ds kube-proxy -o jsonpath='{.spec.template.spec.tolerations}{"\n"}'
```

```sortie
NAME               READY   STATUS    RESTARTS        AGE   IP         
kube-proxy-qcrvg   1/1     Running   3 (5m42s ago)   22h   192.168.58.
[{"operator":"Exists"}]
```

La tolérance `operator: Exists` sans clé tolère tous les taints : kube-proxy doit tourner sur chaque nœud, quoi qu'il arrive. C'est aussi par des taints `NoExecute` que Kubernetes vide un nœud qui ne répond plus (`node.kubernetes.io/unreachable`, chapitre 15), et le délai de cinq minutes avant l'éviction est le `tolerationSeconds: 300` que chaque Pod reçoit par défaut. Retirez les deux taints :

```bash
kubectl taint node deux-noeuds-m02 maintenance-
kubectl taint node deux-noeuds-m03 dedie-
```

## Priorités et préemption

Quand la place manque, qui passe en premier ? Une **PriorityClass** donne un nombre à des Pods : plus il est grand, plus ils sont prioritaires[^priorite]. Le scheduler place les Pods prioritaires d'abord, et, si aucun nœud n'a la place pour un Pod, il peut **préempter**, c'est-à-dire évincer des Pods de priorité plus basse pour lui faire de la place.

```yaml title="priorites.yaml"
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: fond
value: 1000
description: "Tâches de fond, préemptables"
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: critique
value: 100000
description: "Services qui passent avant tout"
```

```bash
kubectl apply -f priorites.yaml
kubectl get priorityclass
```

```sortie
NAME                      VALUE        GLOBAL-DEFAULT   AGE   PREEMPTIONPOLICY
critique                  100000       false            0s    PreemptLowerPriority
fond                      1000         false            0s    PreemptLowerPriority
system-cluster-critical   2000000000   false            22h   PreemptLowerPriority
system-node-critical      2000001000   false            22h   PreemptLowerPriority
```

Les deux classes système, deux milliards, protègent les composants du cluster (CoreDNS, kube-proxy, le réseau) : aucun Pod applicatif ne peut les préempter. Remplissons le cluster avec six Pods de fond qui demandent chacun 10 cœurs, puis envoyons un Pod critique qui en demande 5 :

```bash
kubectl apply -f remplissage.yaml
for n in deux-noeuds deux-noeuds-m02 deux-noeuds-m03; do echo "$n : $(kubectl describe node $n | grep -A5 'Allocated resources' | grep cpu | awk '{print $2, $3}')"; done
kubectl apply -f urgent.yaml
kubectl get pods -o custom-columns=POD:.metadata.name,NOEUD:.spec.nodeName,ETAT:.status.phase,PRIORITE:.spec.priority --sort-by=.metadata.creationTimestamp
```

```sortie
deux-noeuds : 20850m (94%)
deux-noeuds-m02 : 20100m (91%)
deux-noeuds-m03 : 20100m (91%)
```

```sortie
POD                            NOEUD             ETAT      PRIORITE
remplissage-66fddb4c5b-55jqq   deux-noeuds       Running   1000
remplissage-66fddb4c5b-5f5nc   deux-noeuds-m03   Running   1000
remplissage-66fddb4c5b-9tggt   deux-noeuds-m03   Running   1000
remplissage-66fddb4c5b-jc7pv   deux-noeuds-m02   Running   1000
remplissage-66fddb4c5b-zrp74   deux-noeuds       Running   1000
remplissage-66fddb4c5b-8jlcv   <none>            Pending   1000
urgent                         deux-noeuds-m02   Running   100000
```

Les événements racontent la préemption :

```sortie
FailedScheduling       urgent                          0/3 nodes are available: 3 Insufficient cpu. preemption: found a potential placement for pod on node deux-noeuds-m02, preempting 1 victims
Preempted              remplissage-66fddb4c5b-pck4m    Preempted by pod 1c23a7ad-cbf0-45fc-8d00-ed39941021a5 on node deux-noeuds-m02
FailedScheduling       remplissage-66fddb4c5b-8jlcv    0/3 nodes are available: 3 Insufficient cpu. preemption: 0/3 nodes are available: 3 Insufficient cpu.
Scheduled              urgent                          Successfully assigned ch32/urgent to deux-noeuds-m02
```

Aucun nœud n'avait 5 cœurs libres. Le scheduler a cherché un nœud où évincer le moins de Pods possible, de la plus basse priorité possible, suffirait : un seul Pod de fond sur `m02`. Il l'a évincé (avec son délai de grâce, chapitre 22), puis a placé `urgent` au cycle suivant. Le ReplicaSet de `remplissage` a aussitôt recréé le Pod évincé, qui attend à son tour : il n'y a plus de place pour lui, et il ne peut préempter personne de moins prioritaire que lui. En production, la préemption protège les services importants quand le cluster est plein ; elle se combine avec le PodDisruptionBudget (chapitre 33), que le scheduler essaie de respecter en choisissant ses victimes.

## Le simulateur

Le composant ci-dessous reprend les trois nœuds du chapitre et fait, en réduit, le travail du scheduler : pour chaque nœud, le filtrage, avec la raison d'un éventuel refus, puis le score des nœuds retenus. Essayez de retrouver les résultats du chapitre : le sélecteur SSD seul, puis avec le taint, puis avec la tolérance ; l'anti-affinité ; les nœuds chargés avec un Pod de 5 cœurs, avec et sans priorité.

<Ordonnanceur />

## Exercices

:::exercice[Exercice 1 : placer l'API de Colis]

Écrivez la partie « placement » d'un Deployment de l'API de Colis à trois répliques, pour qu'une panne de zone n'emporte jamais plus d'une réplique, sans que les répliques se retrouvent bloquées si l'on en demande plus que de zones. Vérifiez avec 3, puis 6 répliques.

:::

<details>
<summary>Corrigé</summary>

Deux contraintes de répartition : une obligatoire par zone, une souple par nœud (le kit contient `api-repartie.yaml`, avec l'image `pause` à la place de l'API) :

```yaml
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: topology.kubernetes.io/zone
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels: {app: api-repartie}
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: ScheduleAnyway
        labelSelector:
          matchLabels: {app: api-repartie}
```

```sortie
      1 deux-noeuds
      1 deux-noeuds-m02
      1 deux-noeuds-m03
6 répliques :
      2 deux-noeuds
      2 deux-noeuds-m02
      2 deux-noeuds-m03
```

Une réplique par zone avec trois répliques ; deux par zone avec six, sans blocage. Une anti-affinité obligatoire par nœud aurait bloqué la quatrième réplique, comme `dispersion` plus haut. La contrainte par zone en `DoNotSchedule` a son revers : si une zone entière devient indisponible, les nouvelles répliques ne pourront plus être placées dans les autres au-delà d'un écart d'une réplique. Pour un service qui doit survivre à la perte d'une zone, beaucoup d'équipes préfèrent donc `ScheduleAnyway` aussi pour la zone, en acceptant un déséquilibre temporaire.

</details>

:::exercice[Exercice 2 : PreferNoSchedule]

Remplacez le taint `dedie=calcul:NoSchedule` de `m03` par `dedie=calcul:PreferNoSchedule`, puis déployez sept répliques sans tolérance ni préférence. Où vont-elles ? Dans quel cas iraient-elles quand même sur `m03` ?

:::

<details>
<summary>Corrigé</summary>

```bash
kubectl taint node deux-noeuds-m03 dedie=calcul:PreferNoSchedule
```

```sortie
node/deux-noeuds-m03 tainted
      3 deux-noeuds
      4 deux-noeuds-m02
```

Aucune sur `m03` : `PreferNoSchedule` intervient au moment du score (l'extension `TaintToleration` note mal les nœuds dont le Pod ne tolère pas les taints `PreferNoSchedule`), et les deux autres nœuds avaient la place. Si les deux premiers nœuds étaient pleins, ou exclus par une autre règle, les Pods iraient sur `m03` plutôt que de rester en attente. C'est un réglage pour « garder ce nœud libre autant que possible », par exemple un nœud qu'on s'apprête à retirer, pas pour le réserver.

</details>

:::exercice[Exercice 3 : lire un message du scheduler]

Un Pod reste `Pending` avec ce message. Que signifie-t-il, nœud par nœud, et que faudrait-il changer pour qu'il soit placé ?

```sortie
0/3 nodes are available: 1 Insufficient cpu, 1 node(s) had untolerated taint(s), 1 node(s) were unschedulable. preemption: 0/3 nodes are available: 1 No preemption victims found for incoming pod, 2 Preemption is not helpful for scheduling.
```

:::

<details>
<summary>Corrigé</summary>

Chaque nœud a été écarté pour une raison différente. Un nœud porte un taint que le Pod ne tolère pas ; un nœud est marqué non planifiable (`kubectl cordon`, chapitre 33) ; le troisième n'a pas assez de processeur pour la request du Pod. Les raisons sont listées par ordre alphabétique, pas dans l'ordre des nœuds. La partie « preemption » dit ce qu'une préemption pourrait donner : rien sur deux nœuds (évincer des Pods ne retire ni un taint ni un `cordon`), et, sur le nœud qui manque de processeur, aucune victime possible : les seuls Pods qui y tournent sont des Pods système, de priorité plus haute. Ce message a été obtenu sur le cluster du chapitre avec un taint sur `m03`, un `cordon` sur `m02` et un Pod qui demande 21,5 cœurs. Les remèdes possibles, du plus simple au plus lourd : réduire la request de processeur si elle est surévaluée (chapitre 23), ajouter la tolérance si ce Pod a sa place sur ce nœud, remettre le deuxième nœud en service (`kubectl uncordon`), ou ajouter un nœud. Le simulateur de ce chapitre donne la même première partie si l'on combine le taint, le `cordon` et des nœuds chargés avec un Pod de 5 cœurs.

</details>

## Nettoyer

```bash
kubectl delete namespace ch32
kubectl delete priorityclass fond critique
kubectl label nodes --all disque- topology.kubernetes.io/zone-
kubectl taint nodes --all dedie- maintenance- 2>/dev/null
```

Le chapitre 33 se fait sur le même cluster à trois nœuds : gardez-le. Pour revenir ensuite au cluster principal :

```bash
minikube stop -p deux-noeuds
minikube start
kubectl apply -f metallb-plage.yaml
```

[^framework]: Kubernetes, « Scheduling Framework », et « Kubernetes Scheduler », section *Scheduling with kube-scheduler*. [kubernetes.io/docs/concepts/scheduling-eviction/scheduling-framework](https://kubernetes.io/docs/concepts/scheduling-eviction/scheduling-framework/)

[^etiquettes]: Kubernetes, « Well-Known Labels, Annotations and Taints », section *topology.kubernetes.io/zone*. [kubernetes.io/docs/reference/labels-annotations-taints](https://kubernetes.io/docs/reference/labels-annotations-taints/)

[^affinites]: Kubernetes, « Assigning Pods to Nodes », sections *nodeSelector*, *Affinity and anti-affinity* et *Inter-pod affinity and anti-affinity*. [kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/)

[^repartition]: Kubernetes, « Pod Topology Spread Constraints », sections *Spread constraint definition* et *Cluster-level default constraints*. [kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/)

[^taints]: Kubernetes, « Taints and Tolerations », sections *Taint based Evictions* et *tolerationSeconds*. [kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/)

[^priorite]: Kubernetes, « Pod Priority and Preemption ». [kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/)
