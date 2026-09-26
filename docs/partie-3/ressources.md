---
title: Les ressources
sidebar_label: 23. Les ressources
description: "Partager les machines : requests et limits, ce que le scheduler et le noyau en font, les classes de QoS, l'OOM et le bridage du processeur, l'éviction, puis LimitRange et ResourceQuota pour encadrer un namespace."
partie: 3
chapitre: '23'
---

import requestsLimits from '@site/src/figures/requests-limits.svg';
import classesQos from '@site/src/figures/classes-qos.svg';

Sur un cluster partagé par plusieurs équipes, une application qui fuit consomme peu à peu la mémoire de son nœud, jusqu'à ce que ses voisines soient tuées. Une autre, gourmande en calcul, ralentit tout ce qui tourne à côté d'elle. Et le scheduler, qui doit choisir un nœud pour chaque nouveau Pod, n'a aucun moyen de savoir lequel a de la place si personne ne lui dit ce dont les Pods ont besoin.

La partie II a montré les mécanismes du noyau : les cgroups limitent la mémoire et le processeur d'un groupe de processus (chapitre 9). Kubernetes les pilote à partir de deux indications que chaque conteneur peut donner, ses **requests** et ses **limits**. Ce chapitre montre qui les lit, ce qu'elles deviennent dans le noyau, ce qui arrive quand on les dépasse, et comment encadrer tout un namespace.

Les manifestes sont dans [l'archive ressources](pathname:///kits/ressources.tar.gz). metrics-server, activé au chapitre 16, doit tourner.

```bash
kubectl create namespace ch23
kubectl config set-context --current --namespace=ch23
```

## Requests et limits

Chaque conteneur peut déclarer, pour le processeur et la mémoire[^ressources] :

- une **request** : ce qu'il réserve. Le scheduler ne place un Pod que sur un nœud où la somme des requests déjà placées, plus la sienne, tient dans la capacité du nœud ;
- une **limit** : ce qu'il ne peut pas dépasser. Le noyau l'applique, par les cgroups du chapitre 9.

Les unités sont celles de Kubernetes. Le processeur se compte en cœurs, ou en millièmes de cœur : `250m` est un quart de cœur, `1` ou `1000m` un cœur entier. La mémoire se compte en octets, avec les suffixes binaires `Ki`, `Mi`, `Gi` (puissances de 1024) ou décimaux `k`, `M`, `G` (puissances de 1000). Attention au piège : `64M` fait 64 000 000 octets, `64Mi` en fait 67 108 864.

### Ce que voit le scheduler

Le scheduler compare les requests à l'**allouable** de chaque nœud, c'est-à-dire sa capacité moins ce que le système se réserve :

```bash
kubectl get node minikube -o jsonpath='capacité : {.status.capacity.cpu} CPU, {.status.capacity.memory}{"\n"}allouable : {.status.allocatable.cpu} CPU, {.status.allocatable.memory}{"\n"}'
kubectl describe node minikube | sed -n '/Allocated resources/,/Events/p'
```

```sortie
capacité : 22 CPU, 15778000Ki
allouable : 22 CPU, 15778000Ki
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests    Limits
  --------           --------    ------
  cpu                1150m (5%)  300m (1%)
  memory             620Mi (4%)  420Mi (2%)
  ephemeral-storage  0 (0%)      0 (0%)
  hugepages-1Gi      0 (0%)      0 (0%)
  hugepages-2Mi      0 (0%)      0 (0%)
Events:              <none>
```

Le chapitre 17 l'avait remarqué : le nœud minikube annonce les 22 cœurs et les 15 Gio de mémoire du poste, et non les limites données à `minikube start`. Les composants du cluster ont déjà réservé 1,15 cœur et 620 Mio. Déployons trois Pods qui demandent chacun 10 cœurs :

```yaml title="gros.yaml (extrait)"
        resources:
          requests:
            cpu: "10"
```

```bash
kubectl apply -f gros.yaml
sleep 8
kubectl get pods -l app=gros
kubectl describe pod gros-5d568889d8-b76wv | sed -n '/^Events:/,$p'
kubectl describe node minikube | sed -n '/Allocated resources/,/memory/p'
```

```sortie
NAME                    READY   STATUS    RESTARTS   AGE
gros-5d568889d8-b76wv   0/1     Pending   0          8s
gros-5d568889d8-fqgqc   1/1     Running   0          8s
gros-5d568889d8-nm7nc   1/1     Running   0          8s
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  8s    default-scheduler  0/1 nodes are available: 1 Insufficient cpu. preemption: 0/1 nodes are available: 1 No preemption victims found for incoming pod.
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests      Limits
  --------           --------      ------
  cpu                21150m (96%)  300m (1%)
  memory             620Mi (4%)    420Mi (2%)
```

Deux Pods sont placés, le troisième reste `Pending` : 21,15 cœurs sont réservés sur 22, il n'en reste pas 10. Et pourtant, ces Pods ne font que dormir, et n'utilisent presque rien. C'est l'essentiel à retenir : le scheduler raisonne **sur les requests, pas sur la consommation réelle**. Une request trop haute gaspille de la place ; une request trop basse laisse le scheduler entasser des Pods sur un nœud qui ne pourra pas tous les faire tourner. Sur minikube, le décalage est encore pire, puisque le nœud se croit plus grand qu'il n'est. Supprimez le Deployment : `kubectl delete -f gros.yaml`.

### Ce que voit le noyau

Trois Pods, trois réglages, dans `qos.yaml` : `garanti` (requests égales aux limits), `extensible` (requests plus basses que les limits, et pas de limite de processeur), `sans-garantie` (rien du tout). Regardons ce que Kubernetes a écrit dans leurs cgroups, lus depuis chaque conteneur :

```bash
kubectl apply -f qos.yaml
kubectl wait --for=condition=Ready pod/garanti pod/extensible pod/sans-garantie
for p in garanti extensible sans-garantie; do
  echo "$p : oom_score_adj=$(kubectl exec $p -- cat /proc/1/oom_score_adj) cpu.weight=$(kubectl exec $p -- cat /sys/fs/cgroup/cpu.weight) cpu.max=$(kubectl exec $p -- cat /sys/fs/cgroup/cpu.max) memory.max=$(kubectl exec $p -- cat /sys/fs/cgroup/memory.max)"
done
```

```sortie
garanti : oom_score_adj=-997 cpu.weight=35 cpu.max=25000 100000 memory.max=67108864
extensible : oom_score_adj=998 cpu.weight=17 cpu.max=max 100000 memory.max=134217728
sans-garantie : oom_score_adj=1000 cpu.weight=1 cpu.max=max 100000 memory.max=max
```

Chaque valeur a son origine :

- la **request de processeur** devient `cpu.weight`, le poids du cgroup quand plusieurs se disputent le processeur (chapitre 9) : 35 pour 250m, 17 pour 100m, 1 sans request. Elle ne limite rien quand le processeur est libre ;
- la **limit de processeur** devient `cpu.max` : 25 000 microsecondes de calcul par période de 100 000, soit un quart de cœur pour `garanti` ; `max` pour les deux autres, sans plafond ;
- la **limit de mémoire** devient `memory.max`, en octets : 64 Mio et 128 Mio ; `max` sans limite ;
- la **request de mémoire** n'apparaît pas dans le noyau : elle ne sert qu'au scheduler, et au calcul de `oom_score_adj` qu'on verra avec les classes de QoS.

<Figure svg={requestsLimits} num="23.1" alt="Les requests, ce que le Pod réserve, sont lues par le scheduler, qui place le Pod si la somme des requests tient dans l'allouable du nœud (22 CPU allouables : deux Pods de 10 CPU, le troisième Pending), et deviennent cpu.weight dans le cgroup, la part du processeur en cas de concurrence (250m donne 35, 100m donne 17, rien donne 1). Les limits, ce que le Pod ne peut dépasser, deviennent cpu.max, un quota par période de 100 ms qui bride le processus (200m donne 20000 100000, 425 périodes bridées sur 704), et memory.max, au-delà duquel le noyau tue (64Mi : OOMKilled, code 137).">
Qui lit les requests et les limits, et ce qu'elles deviennent. Valeurs relevées sur le cluster du cours.
</Figure>

## Dépasser ses limites

Le processeur et la mémoire ne se dépassent pas de la même façon. Ce Pod remplit 100 Mo de mémoire avec une limite de 64 Mio :

```yaml title="gourmand-memoire.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: gourmand-memoire
spec:
  restartPolicy: Never
  containers:
  - name: app
    image: busybox:1.37
    command: ["sh", "-c", "echo 'je remplis 100 Mo de mémoire'; x=$(head -c 100000000 /dev/zero | tr '\\0' a); echo 'fini'"]
    resources:
      limits:
        memory: 64Mi
```

```bash
kubectl apply -f gourmand-memoire.yaml
sleep 15
kubectl get pod gourmand-memoire
kubectl logs gourmand-memoire
kubectl get pod gourmand-memoire -o jsonpath='{.status.containerStatuses[0].state.terminated.reason} code={.status.containerStatuses[0].state.terminated.exitCode}{"\n"}'
```

```sortie
NAME               READY   STATUS      RESTARTS   AGE
gourmand-memoire   0/1     OOMKilled   0          15s
je remplis 100 Mo de mémoire
OOMKilled code=137
```

La mémoire ne se partage pas dans le temps : quand le conteneur atteint `memory.max`, le noyau ne peut pas le faire attendre, il le tue (chapitre 9). Kubernetes le signale par la raison `OOMKilled` et le code 137 (128 + 9, le numéro de SIGKILL). Avec la politique de redémarrage par défaut, `Always`, un conteneur qui manque de mémoire à chaque démarrage finit en `CrashLoopBackOff`, et `kubectl describe` affiche `Last State: Terminated, Reason: OOMKilled`.

Le processeur, lui, se partage dans le temps. Ce Pod tourne en boucle infinie, avec une limite de 200m :

```bash
kubectl apply -f gourmand-cpu.yaml
kubectl wait --for=condition=Ready pod/gourmand-cpu
sleep 70
kubectl top pod gourmand-cpu
kubectl exec gourmand-cpu -- sh -c 'cat /sys/fs/cgroup/cpu.max; grep -E "nr_periods|nr_throttled|throttled_usec" /sys/fs/cgroup/cpu.stat'
```

```sortie
NAME           CPU(cores)   MEMORY(bytes)
gourmand-cpu   200m         0Mi
20000 100000
nr_periods 704
nr_throttled 425
throttled_usec 30909038
```

Il consomme exactement 200m, et n'est pas tué : il est **bridé** (*throttled*). Sur les 704 périodes de 100 millisecondes écoulées, il a été stoppé dans 425, pour un total de 31 secondes d'attente forcée. Pour un programme en boucle, c'est sans conséquence ; pour un serveur web, c'est une latence qui grimpe sans aucun message d'erreur, et c'est pourquoi beaucoup d'équipes ne mettent pas de limite de processeur aux applications sensibles à la latence, en se contentant de requests justes. La mémoire, elle, doit toujours avoir une limite.

## Les classes de QoS

À partir des requests et des limits de ses conteneurs, Kubernetes range chaque Pod dans une des trois **classes de qualité de service** (QoS)[^qos] :

```bash
kubectl get pods -o custom-columns='NOM:.metadata.name,QOS:.status.qosClass'
```

```sortie
NOM             QOS
extensible      Burstable
garanti         Guaranteed
sans-garantie   BestEffort
```

- **Guaranteed** : chaque conteneur a des requests et des limits, égales, pour le processeur et la mémoire ;
- **Burstable** : au moins un conteneur a une request ou une limit, sans remplir les conditions de Guaranteed ;
- **BestEffort** : aucun conteneur n'a ni request ni limit.

La classe décide de deux choses. D'abord, de l'endroit où le Pod est rangé dans l'arbre des cgroups du nœud :

```bash
minikube ssh -- "cd /sys/fs/cgroup/kubepods.slice; ls -d kubepods-*"
```

```sortie
kubepods-besteffort.slice
kubepods-burstable.slice
kubepods-pod40e33145_f2ec_42a6_97cc_513df6ed27a6.slice
kubepods-pod654c8201_f65c_4456_a28f_7a0f9f45dabc.slice
kubepods-pod9d83bef2_adba_4495_ae7d_f2f5fc8b2f76.slice
kubepods-podfba3584a_a0e6_40e9_91b5_d3803e3e9b8f.slice
```

Les Pods Guaranteed ont chacun leur tranche directement sous `kubepods.slice` : celui de `garanti`, et ceux de kindnet et des deux Pods de MetalLB, les autres Pods Guaranteed du cluster. Les Burstable et les BestEffort sont regroupés dans leur tranche respective. Ensuite, et surtout, la classe décide de qui est sacrifié quand le nœud manque de mémoire. C'est la valeur `oom_score_adj` relevée plus haut, que le noyau ajoute au score de chaque processus quand il doit en tuer un : -997 pour un Pod Guaranteed (presque intouchable), 1000 pour un BestEffort (le premier tué), et pour un Burstable une valeur entre 2 et 999, d'autant plus basse que sa request de mémoire est grande par rapport à la mémoire du nœud. Ici, 998 : 32 Mio de request sur 15 Gio de nœud.

<Figure svg={classesQos} num="23.2" alt="Trois classes. Guaranteed : requests égales aux limits pour le CPU et la mémoire de chaque conteneur, rangé dans kubepods-pod-uid.slice, oom_score_adj -997. Burstable : au moins une request ou une limit, sans être Guaranteed, rangé dans kubepods-burstable.slice, oom_score_adj de 2 à 999 (998 ici). BestEffort : aucune request ni limit, rangé dans kubepods-besteffort.slice, oom_score_adj 1000. De gauche à droite, les Pods sont de plus en plus exposés quand la mémoire manque.">
Les trois classes de QoS, leur place dans les cgroups du nœud et leur exposition quand la mémoire manque. Valeurs relevées sur le cluster du cours.
</Figure>

## L'éviction

Avant d'en arriver là, le kubelet surveille lui-même les ressources de son nœud : mémoire disponible, espace disque, nombre d'inodes. Quand l'une passe sous un seuil, il **évince** des Pods, c'est-à-dire qu'il les arrête et les marque comme `Failed` avec la raison `Evicted`, en commençant par ceux qui consomment le plus au-delà de leurs requests[^eviction]. Un Pod évincé et géré par un Deployment est recréé ailleurs, ou sur le même nœud une fois la pression retombée.

Provoquer une pénurie de mémoire sur un nœud minikube n'est pas une bonne idée : le nœud se croit doté de 15 Gio alors que son conteneur est limité à 4 Go, et c'est l'OOM de Docker, pas le kubelet, qui interviendrait. Le kubelet applique aussi des limites de **stockage éphémère** (les fichiers écrits dans le conteneur et ses volumes `emptyDir`), qui se testent sans risque. Ce Pod écrit 80 Mo avec une limite de 50 Mio :

```yaml title="disque.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: disque
spec:
  restartPolicy: Never
  containers:
  - name: app
    image: busybox:1.37
    command: ["sh", "-c", "dd if=/dev/zero of=/tmp/gros bs=1M count=80; echo 'écrit'; sleep 3600"]
    resources:
      limits:
        ephemeral-storage: 50Mi
```

```bash
kubectl apply -f disque.yaml
sleep 40
kubectl get pod disque
kubectl get pod disque -o jsonpath='{.status.phase} {.status.reason}: {.status.message}{"\n"}'
```

```sortie
NAME     READY   STATUS   RESTARTS   AGE
disque   0/1     Error    0          40s
Failed Evicted: Pod ephemeral local storage usage exceeds the total limit of containers 50Mi.
```

L'écriture a réussi (le noyau ne limite pas l'espace disque d'un cgroup) ; c'est le kubelet qui, en mesurant périodiquement l'espace utilisé, a constaté le dépassement et évincé le Pod. La phase est `Failed`, la raison `Evicted`. Une application qui écrit des journaux ou des fichiers temporaires sans limite finit ainsi, ou, pire, remplit le disque du nœud et fait évincer ses voisins : un argument de plus pour écrire ses journaux sur la sortie standard (chapitre 2).

## Encadrer un namespace

Tout repose sur la bonne volonté de ceux qui écrivent les manifestes. Deux objets permettent à l'administrateur d'un namespace de l'imposer.

### LimitRange

Une **LimitRange** donne des valeurs par défaut aux conteneurs qui n'en déclarent pas, et des bornes à ceux qui en déclarent[^limitrange] :

```yaml title="limitrange.yaml"
apiVersion: v1
kind: LimitRange
metadata:
  name: bornes
spec:
  limits:
  - type: Container
    defaultRequest:
      cpu: 100m
      memory: 64Mi
    default:
      cpu: 500m
      memory: 128Mi
    max:
      cpu: "1"
      memory: 512Mi
```

```bash
kubectl create namespace ch23-quota
kubectl -n ch23-quota apply -f limitrange.yaml
kubectl -n ch23-quota run nu --image=busybox:1.37 -- sleep 3600
kubectl -n ch23-quota get pod nu -o jsonpath='{.spec.containers[0].resources}' | jq -c .
kubectl -n ch23-quota get pod nu -o jsonpath='{.metadata.annotations}' | jq -c .
kubectl -n ch23-quota run trop --image=busybox:1.37 --overrides='{"spec":{"containers":[{"name":"trop","image":"busybox:1.37","command":["sleep","3600"],"resources":{"limits":{"cpu":"2"}}}]}}'
```

```sortie
{"limits":{"cpu":"500m","memory":"128Mi"},"requests":{"cpu":"100m","memory":"64Mi"}}
{"kubernetes.io/limit-ranger":"LimitRanger plugin set: cpu, memory request for container nu; cpu, memory limit for container nu"}
Error from server (Forbidden): pods "trop" is forbidden: maximum cpu usage per Container is 1, but limit is 2
```

Le Pod `nu`, créé sans rien, a reçu les valeurs par défaut, et une annotation le signale. C'est le travail de l'étape d'**admission** du chapitre 16 : l'API server a modifié l'objet avant de l'enregistrer. Le Pod `trop`, qui dépasse le maximum, est refusé.

### ResourceQuota

Une **ResourceQuota** plafonne la consommation totale d'un namespace : la somme des requests et des limits, et le nombre d'objets[^quota].

```yaml title="quota.yaml"
apiVersion: v1
kind: ResourceQuota
metadata:
  name: plafond
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 512Mi
    limits.memory: 1Gi
    pods: "5"
```

```bash
kubectl -n ch23-quota apply -f quota.yaml
for i in 1 2 3 4 5 6; do kubectl -n ch23-quota run p$i --image=busybox:1.37 -- sleep 3600; done
kubectl -n ch23-quota describe resourcequota plafond
```

```sortie
pod/p1 created
pod/p2 created
pod/p3 created
pod/p4 created
Error from server (Forbidden): pods "p5" is forbidden: exceeded quota: plafond, requested: pods=1, used: pods=5, limited: pods=5
Error from server (Forbidden): pods "p6" is forbidden: exceeded quota: plafond, requested: pods=1, used: pods=5, limited: pods=5
...
Resource         Used   Hard
--------         ----   ----
limits.memory    640Mi  1Gi
pods             5      5
requests.cpu     500m   1
requests.memory  320Mi  512Mi
```

Le Pod `nu` comptait déjà : quatre de plus, et le cinquième est refusé. Chaque Pod a reçu les valeurs par défaut de la LimitRange, d'où les 500m et 320 Mio consommés. Avec un Deployment, le refus est plus discret, et c'est un piège classique :

```bash
kubectl -n ch23-quota delete pods --all
kubectl -n ch23-quota create deployment dix --image=busybox:1.37 --replicas=10 -- sleep 3600
sleep 8
kubectl -n ch23-quota get deployment dix
kubectl -n ch23-quota describe rs -l app=dix | grep -m2 FailedCreate
```

```sortie
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
dix    5/10    5            5           8s
  ReplicaFailure   True    FailedCreate
  Warning  FailedCreate      8s                replicaset-controller  Error creating: pods "dix-6f6bfc96f5-p2wd4" is forbidden: exceeded quota: plafond, requested: pods=1, used: pods=5, limited: pods=5
```

`kubectl create deployment` a réussi, sans erreur : c'est le **ReplicaSet**, en créant les Pods, qui se heurte au quota. Le Deployment reste à `5/10`, et l'explication n'apparaît que dans les événements du ReplicaSet. Quand un Deployment reste en dessous du nombre de répliques demandé sans Pod en erreur, regardez son ReplicaSet.

## Exercices

:::exercice[Exercice 1 : un quota sans valeurs par défaut]

Dans un namespace `ch23x`, créez une ResourceQuota sur `requests.cpu` et `requests.memory`, **sans** LimitRange, puis essayez d'y lancer un Pod sans requests. Que se passe-t-il, et pourquoi ?

:::

<details>
<summary>Corrigé</summary>

```bash
kubectl create namespace ch23x
kubectl -n ch23x create quota q --hard=requests.cpu=1,requests.memory=1Gi
kubectl -n ch23x run sans-requests --image=busybox:1.37 -- sleep 3600
```

```sortie
Error from server (Forbidden): pods "sans-requests" is forbidden: failed quota: q: must specify requests.cpu for: sans-requests; requests.memory for: sans-requests
```

Un quota sur une ressource oblige chaque Pod du namespace à déclarer cette ressource : sans cela, le quota ne pourrait pas compter. D'où l'association habituelle d'une ResourceQuota et d'une LimitRange, qui donne des valeurs par défaut aux Pods qui n'en ont pas. Supprimez le namespace ensuite.

</details>

:::exercice[Exercice 2 : une limite plus petite que la demande]

Que répond l'API server à un conteneur qui demande 256 Mio de mémoire avec une limite de 128 Mio ? Et à un conteneur qui a une request et une limit de processeur égales (200m), une request de mémoire de 64 Mio, mais pas de limite de mémoire : quelle est sa classe de QoS ?

:::

<details>
<summary>Corrigé</summary>

```sortie
The Pod "inverse" is invalid: spec.containers[0].resources.requests: Invalid value: "256Mi": must be less than or equal to memory limit of 128Mi
```

Une request supérieure à la limit n'a pas de sens (on réserverait ce qu'on n'a pas le droit d'utiliser), et l'API server refuse l'objet dès la validation. Pour le second conteneur :

```sortie
Burstable
{"limits":{"cpu":"200m"},"requests":{"cpu":"200m","memory":"64Mi"}}
```

Burstable : pour être Guaranteed, il faut des requests et des limits égales **pour le processeur et pour la mémoire**, dans chaque conteneur du Pod. Il suffit d'une limite de mémoire absente pour descendre d'une classe.

</details>

:::exercice[Exercice 3 : dimensionner l'API de Colis]

Mesurée pendant une semaine, l'API de Colis consomme au repos 60 Mio et 20m, et monte à 180 Mio et 400m lors des pics. Quelles requests et limits lui donner ? Quelle classe de QoS en résulte, et quels risques prend-on ?

:::

<details>
<summary>Corrigé</summary>

Une proposition raisonnable : `requests: {cpu: 100m, memory: 192Mi}` et `limits: {memory: 256Mi}`, sans limite de processeur. La request de mémoire couvre le pic mesuré, pour que le scheduler réserve de quoi le tenir, et la limite laisse une marge au-dessus avant l'OOM ; comme la mémoire ne se reprend pas, on dimensionne sur le pic. La request de processeur couvre l'usage courant sans réserver le pic : si le processeur est libre, l'API en prendra davantage ; s'il est disputé, elle aura au moins sa part. L'absence de limite de processeur évite le bridage pendant les pics. La classe est Burstable. Le risque : lors d'une pénurie de mémoire sur le nœud, un Pod Burstable qui dépasse sa request est évincé avant un Guaranteed ; et un nœud rempli de Pods sans limite de processeur peut voir ses Pods se ralentir mutuellement. Ces valeurs sont un point de départ : l'autoscaling vertical (chapitre 31) sait les recalculer à partir de la consommation réelle.

</details>

## Nettoyer

```bash
kubectl delete namespace ch23 ch23-quota
kubectl config set-context --current --namespace=default
```

[^ressources]: Kubernetes, « Resource Management for Pods and Containers », sections *Requests and limits*, *Resource units in Kubernetes* et *Local ephemeral storage*. [kubernetes.io/docs/concepts/configuration/manage-resources-containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)

[^qos]: Kubernetes, « Pod Quality of Service Classes », et « Node-pressure Eviction », section *Node out of memory behavior* (valeurs de `oom_score_adj`). [kubernetes.io/docs/concepts/workloads/pods/pod-qos](https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/)

[^eviction]: Kubernetes, « Node-pressure Eviction ». [kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/)

[^limitrange]: Kubernetes, « Limit Ranges ». [kubernetes.io/docs/concepts/policy/limit-range](https://kubernetes.io/docs/concepts/policy/limit-range/)

[^quota]: Kubernetes, « Resource Quotas ». [kubernetes.io/docs/concepts/policy/resource-quotas](https://kubernetes.io/docs/concepts/policy/resource-quotas/)
