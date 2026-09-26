---
title: L'autoscaling
sidebar_label: 31. L'autoscaling
description: "Suivre la charge sans intervenir : le HorizontalPodAutoscaler qui ajuste le nombre de répliques de l'API de Colis selon le processeur, le VerticalPodAutoscaler qui recommande et ajuste les ressources d'un Pod, jusqu'au redimensionnement en place, et KEDA qui fait passer le worker de zéro à cinq selon la longueur de la file Redis."
partie: 4
chapitre: '31'
---

import autoscalers from '@site/src/figures/autoscalers.svg';
import kedaRafale from '@site/src/figures/keda-rafale.svg';

L'API de Colis tourne avec deux répliques depuis le chapitre 24. C'est trop la nuit, quand personne n'envoie de colis, et trop peu le lundi matin, quand les commerçants enregistrent les envois du week-end. Le worker, lui, a une réplique : les jours de rafale, les colis attendent leur date de livraison dans la file Redis ; les jours calmes, il tourne pour rien. Fixer ces nombres à la main, c'est choisir entre gaspiller et saturer.

Kubernetes sait ajuster automatiquement la taille des charges de travail. Trois mécanismes répondent à trois questions différentes. Le **HorizontalPodAutoscaler** (HPA) décide **combien** de Pods faire tourner, selon une mesure comme le processeur. Le **VerticalPodAutoscaler** (VPA) décide **quelles ressources** donner à chaque Pod, selon ce qu'il consomme vraiment. Et **KEDA** fait varier le nombre de Pods selon des événements extérieurs au cluster, comme la longueur d'une file, jusqu'à zéro quand il n'y a rien à faire. Ce chapitre les applique à Colis, sous une charge réelle.

Les manifestes sont dans [l'archive autoscaling](pathname:///kits/autoscaling.tar.gz).

:::panne[Faire de la place avant de commencer]

Ce chapitre installe des composants et fait monter l'API jusqu'à six répliques. Si vous avez gardé les copies de Colis des chapitres précédents (défi III, `colis-helm`, `colis-dev`), le nœud de 4 Gio sera juste. Mettez-les en sommeil sans rien supprimer :

```bash
for ns in colis-defi colis-helm colis-dev; do kubectl -n $ns scale deploy,sts --all --replicas=0; done
```

Leurs volumes persistants restent ; `--replicas=1` (ou 2) les réveillera. Attention au défi III : sa base est dans un `emptyDir` (chapitre 24), et ses données disparaissent avec son Pod.

:::

```bash
kubectl create namespace ch31
```

## Le HorizontalPodAutoscaler

Un HPA surveille une mesure et modifie le champ `replicas` de sa cible, un Deployment ou un StatefulSet, pour que la mesure reste proche d'une valeur visée. La mesure la plus courante est l'utilisation du processeur, exprimée en pourcentage de la **request** (chapitre 23) : c'est metrics-server, activé au chapitre 16, qui la fournit.

```yaml title="hpa-api.yaml"
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api
  namespace: colis
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api
  minReplicas: 2
  maxReplicas: 6
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 60     # 300 par défaut ; raccourci pour la démonstration
```

L'API demande `cpu: 100m` ; viser 50 % veut dire garder chaque Pod autour de 50m. L'algorithme est simple : toutes les 15 secondes, le contrôleur calcule le nombre de répliques qui ramènerait la mesure à la cible, `répliques voulues = ⌈répliques actuelles × utilisation mesurée / utilisation visée⌉`, dans les bornes `minReplicas` et `maxReplicas`, en ignorant les écarts de moins de 10 %[^hpa].

```bash
kubectl apply -f hpa-api.yaml
kubectl -n colis get hpa api
kubectl -n colis top pod -l app.kubernetes.io/name=api
```

```sortie
NAME   REFERENCE        TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
api    Deployment/api   cpu: 4%/50%   2         6         2          45s
NAME                   CPU(cores)   MEMORY(bytes)   
api-85cbf95c69-4m7ns   4m           55Mi            
api-85cbf95c69-99p9p   4m           53Mi            
```

Au repos, 4 % : l'API ne fait presque rien. Envoyons-lui de la charge avec **fortio**, un générateur de charge HTTP, lancé dans un Job : 20 connexions en parallèle, aussi vite que possible, pendant trois minutes, sur la liste des colis.

```yaml title="charge.yaml (extrait)"
      containers:
      - name: fortio
        image: fortio/fortio:1.75.3
        args: ["load", "-c", "20", "-qps", "0", "-t", "180s", "-timeout", "5s", "http://api.colis:8000/colis"]
```

```bash
kubectl apply -f charge.yaml
# toutes les 10 secondes :
kubectl -n colis get hpa api -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}% {.status.currentReplicas}{"\n"}'
```

```sortie
t=0s utilisation=4% répliques=2
t=11s utilisation=4% répliques=2
t=21s utilisation=95% répliques=2
t=31s utilisation=95% répliques=2
t=41s utilisation=95% répliques=4
t=51s utilisation=95% répliques=4
t=62s utilisation=95% répliques=4
t=72s utilisation=95% répliques=4
t=82s utilisation=1111% répliques=4
t=92s utilisation=1111% répliques=4
t=102s utilisation=1111% répliques=6
t=112s utilisation=1111% répliques=6
...
t=194s utilisation=557% répliques=6
```

À 95 % d'utilisation, soit près du double de la cible, le HPA a doublé les répliques : 2 × 95 / 50 = 3,8, arrondi à 4. La mesure est ensuite montée à 1 111 % (chaque Pod consommait plus d'un cœur, pour une request d'un dixième de cœur), et le HPA est allé à 6, son maximum. Il y serait resté même avec plus de charge : `maxReplicas` est une limite de sécurité, qui protège le cluster d'un emballement.

Notez le rythme de la colonne d'utilisation : elle ne change qu'une fois par minute environ. metrics-server ne mesure pas en continu ; il collecte l'usage des nœuds à intervalle régulier, et le HPA décide sur la dernière mesure. Entre la montée de la charge et l'arrivée des nouveaux Pods, il s'est écoulé 40 secondes. Un autoscaler rattrape la charge ; il ne l'anticipe pas. Pour un pic qui dure dix secondes, il arrive trop tard, et ce sont les répliques minimales qui encaissent.

La charge terminée, redescente :

```sortie
t=0s après la fin de la charge : utilisation=319% répliques=6
...
t=51s après la fin de la charge : utilisation=319% répliques=6
t=61s après la fin de la charge : utilisation=4% répliques=6
...
t=112s après la fin de la charge : utilisation=4% répliques=6
t=122s après la fin de la charge : utilisation=4% répliques=2
```

```bash
kubectl -n colis describe hpa api | sed -n '/^Events:/,$p'
```

```sortie
Events:
  Type    Reason             Age    From                       Message
  ----    ------             ----   ----                       -------
  Normal  SuccessfulRescale  5m29s  horizontal-pod-autoscaler  New size: 4; reason: cpu resource utilization (percentage of request) above target
  Normal  SuccessfulRescale  4m29s  horizontal-pod-autoscaler  New size: 6; reason: cpu resource utilization (percentage of request) above target
  Normal  SuccessfulRescale  44s    horizontal-pod-autoscaler  New size: 2; reason: All metrics below target
```

La mesure a mis une minute à retomber, puis le HPA a attendu la fenêtre de stabilisation (60 secondes ici) avant de revenir à 2. Cette fenêtre est volontairement asymétrique : on monte vite, parce que manquer de capacité coûte des requêtes perdues, et on descend lentement, parce qu'une charge qui oscille ferait créer et détruire des Pods en boucle. Par défaut, la descente attend cinq minutes. Côté client, fortio a envoyé 197 234 requêtes en trois minutes (1 096 par seconde), toutes réussies (`Code 200 : 197234 (100.0 %)`), avec une latence médiane de 18 ms et un 99<sup>e</sup> centile de 30 ms.

:::panne[Le HPA et le champ replicas se disputent]

Le manifeste de l'API, appliqué depuis le chapitre 26, contient `replicas: 2`. Tant que le HPA veut 2 répliques, rien ne se voit. Mais s'il en veut 3 (par exemple avec `minReplicas: 3`), réappliquer le manifeste remet 2, et le HPA remet 3 :

```sortie
deployment.apps/api configured
14:51:39 spec.replicas=2 prêts=2
14:51:44 spec.replicas=3 prêts=2
14:51:49 spec.replicas=3 prêts=3
```

Un Pod a été arrêté puis recréé, pour rien ; en pleine charge, avec 6 répliques voulues, le même `apply` en arrêterait quatre d'un coup. Quand un HPA gère une charge de travail, retirez `replicas` du manifeste, et laissez le HPA seul maître du champ[^migration]. C'est ce que fait KEDA plus bas, et ce que le chart Helm du chapitre 29 devrait faire quand un autoscaler est activé.

:::

Le processeur n'est pas la seule mesure possible. L'API `autoscaling/v2` accepte la mémoire (rarement pertinente : un programme ne libère pas sa mémoire parce qu'on ajoute des répliques), plusieurs mesures à la fois (le HPA prend le maximum des répliques demandées), et des mesures personnalisées, comme le nombre de requêtes par seconde, fournies par un adaptateur de métriques comme celui de Prometheus (chapitre 50) ou celui de KEDA, qu'on verra plus loin.

## Le VerticalPodAutoscaler

Le HPA suppose que chaque Pod est bien dimensionné. Au chapitre 23, les requests de l'API avaient été choisies à partir d'une mesure faite une fois, à la main. Le **VPA** fait cette mesure en continu, et en déduit des recommandations, qu'il peut appliquer lui-même[^vpa]. Il ne fait pas partie de Kubernetes : c'est un projet du groupe SIG Autoscaling, en trois composants, le *recommender*, qui observe la consommation, l'*updater*, qui applique les recommandations aux Pods en marche, et un webhook d'admission, qui ajuste les nouveaux Pods à leur création. On l'installe avec son chart officiel, en version 1.8.0, avec une réplique de chaque composant au lieu de deux :

```yaml title="vpa-valeurs.yaml"
admissionController:
  replicas: 1
recommender:
  replicas: 1
updater:
  replicas: 1
```

```bash
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm install vpa autoscaler/vertical-pod-autoscaler --version 0.13.0 -n vpa --create-namespace -f vpa-valeurs.yaml --wait
kubectl -n vpa get pods
```

```sortie
NAME                                                              READY   STATUS    RESTARTS   AGE
vpa-vertical-pod-autoscaler-admission-controller-5c9b86dddhq59t   1/1     Running   0          6s
vpa-vertical-pod-autoscaler-recommender-99b7fb99-56fc8            1/1     Running   0          6s
vpa-vertical-pod-autoscaler-updater-675648c866-fx2kf              1/1     Running   0          6s
```

Commençons prudemment, avec un VPA en mode `Off` sur le worker de Colis : il recommande, mais ne touche à rien.

```yaml title="vpa-worker.yaml"
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: worker
  namespace: colis
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: worker
  updatePolicy:
    updateMode: "Off"
```

```bash
kubectl apply -f vpa-worker.yaml
sleep 90
kubectl -n colis get vpa worker
kubectl -n colis get vpa worker -o jsonpath='{.status.recommendation}' | jq -c .
kubectl -n colis top pod -l app.kubernetes.io/name=worker
```

```sortie
NAME     MODE   CPU   MEM     PROVIDED   AGE
worker   Off    25m   250Mi   True       90s
{"containerRecommendations":[{"containerName":"worker","lowerBound":{"cpu":"25m","memory":"250Mi"},"target":{"cpu":"25m","memory":"250Mi"},"uncappedTarget":{"cpu":"25m","memory":"250Mi"},"upperBound":{"cpu":"100G","memory":"97656250000Ki"}}]}
NAME                     CPU(cores)   MEMORY(bytes)   
worker-594df4b89-rnxbf   1m           37Mi            
```

La recommandation mérite qu'on la lise de près. Le worker consomme 1m de processeur et 37 Mio, et le VPA recommande 25m et 250 Mio. Ce sont les **planchers** du recommender, qui par défaut ne recommande jamais moins de 25m et 250 Mio par Pod (ses options `--pod-recommendation-min-cpu-millicores` et `--pod-recommendation-min-memory-mb`), pour ne pas étrangler un programme qu'il connaît mal. Et la borne haute, 100 000 cœurs, dit la même chose autrement : après 90 secondes, le VPA n'a presque aucune donnée, et son intervalle de confiance est immense. Il affine avec le temps, sur un historique qui compte en jours ; ses recommandations deviennent utiles après une semaine de trafic représentatif, week-end compris.

### Appliquer les recommandations, en place

En mode `Recreate`, l'updater applique ses recommandations en **évinçant** les Pods trop éloignés de la cible : le contrôleur en recrée, que le webhook ajuste à leur naissance. Chaque ajustement coûte un redémarrage. Le mode `InPlaceOrRecreate` utilise le **redimensionnement en place** des Pods, stable depuis Kubernetes 1.35[^enplace] : le kubelet modifie les limites des cgroups du conteneur (chapitre 9) sans le redémarrer, et ne recrée le Pod que si c'est impossible.

```bash
kubectl -n colis patch vpa worker --type merge -p '{"spec":{"updatePolicy":{"updateMode":"InPlaceOrRecreate"}}}'
kubectl -n colis get pods -l app.kubernetes.io/name=worker -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.uid} restarts={.status.containerStatuses[0].restartCount}{"\n"}{.spec.containers[0].resources}{"\n"}{end}'
kubectl -n colis get events --field-selector involvedObject.kind=Pod --sort-by=.lastTimestamp | grep -E 'InPlaceResizedByVPA|ResizeCompleted'
kubectl -n colis get deploy worker -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
```

```sortie
worker-594df4b89-rnxbf 2cfc02fe-e7b7-4bb8-b59d-e007df21bba7 restarts=0
{"limits":{"memory":"500Mi"},"requests":{"cpu":"25m","memory":"250Mi"}}
5s          Normal    InPlaceResizedByVPA   pod/worker-594df4b89-rnxbf   Pod was resized in place by VPA Updater.
5s          Normal    ResizeCompleted       pod/worker-594df4b89-rnxbf   Pod resize completed: {"containers":[{"name":"worker","resources":{"limits":{"memory":"...
{"limits":{"memory":"192Mi"},"requests":{"cpu":"50m","memory":"96Mi"}}
```

Trente secondes plus tard, le Pod avait été redimensionné : même Pod (même `uid`), aucun redémarrage, et de nouvelles ressources, 250 Mio de request et 500 Mio de limite. Le VPA a gardé le rapport entre limite et request que le manifeste avait fixé (192/96 = 2). Deux remarques. Le Deployment n'a pas changé : le VPA agit sur les Pods, pas sur leur modèle, et c'est son webhook qui ajustera les prochains Pods. Et le résultat, ici, n'est pas une amélioration : 250 Mio réservés pour 37 consommés, à cause des planchers et du manque d'historique. Un VPA se met en mode `Off` d'abord, et ne passe en mode automatique qu'une fois ses recommandations vérifiées ; on peut aussi les borner par `resourcePolicy` (`minAllowed`, `maxAllowed`). Repassons en `Off` :

```bash
kubectl -n colis patch vpa worker --type merge -p '{"spec":{"updatePolicy":{"updateMode":"Off"}}}'
```

Le HPA et le VPA ne doivent pas agir sur la même mesure de la même charge de travail : si le VPA augmente la request de processeur, l'utilisation en pourcentage baisse, et le HPA retire des répliques, qui chargent davantage les autres... L'exercice 1 propose un partage des rôles.

<Figure svg={autoscalers} num="31.1" alt="Trois mécanismes. HPA, combien de Pods : metrics-server (CPU, mémoire), toutes les 15 secondes, alimente le HPA api (cible : 50 % de la request de CPU), qui modifie le Deployment api (replicas de 2 à 6). VPA, quelles ressources par Pod : le recommender (historique d'usage) écrit dans le VPA worker sa recommandation (target et bornes), lue par l'updater, qui redimensionne en place ou évince les Pods worker (requests, limits) ; en plus, un webhook d'admission fait naître les nouveaux Pods ajustés. KEDA, de zéro à N selon un événement extérieur : Redis (LLEN colis:a-estimer), interrogé toutes les 5 secondes par l'opérateur KEDA (ScaledObject worker, 1 worker pour 5 colis), qui crée et nourrit un HPA keda-hpa-worker (de 1 à 5), qui modifie le Deployment worker (replicas de 0 à 5) ; le passage de 0 à 1 est fait par l'opérateur lui-même.">
Ce que chaque autoscaler lit, et ce qu'il modifie. Les trois finissent par écrire dans des objets ordinaires : le nombre de répliques, ou les ressources des Pods.
</Figure>

## KEDA : des workers selon la longueur de la file

Le worker de Colis n'a que faire du processeur : quand la file Redis est vide, il attend ; quand elle déborde, chaque worker traite un colis toutes les demi-secondes, et c'est le nombre de colis en attente qui dit combien de workers il faudrait. Le HPA ne connaît pas Redis, et ne descend jamais sous une réplique. **KEDA** (*Kubernetes Event-driven Autoscaling*), projet diplômé de la CNCF, comble ces deux manques : il sait interroger des dizaines de sources (files Redis, Kafka, RabbitMQ, bases de données, métriques Prometheus...), et il sait faire passer une charge de travail de zéro à une réplique et inversement[^keda]. Au-delà d'une réplique, il délègue à un HPA ordinaire, qu'il crée et alimente lui-même.

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm install keda kedacore/keda --version 2.21.0 -n keda --create-namespace --wait
kubectl -n keda get pods
```

```sortie
NAME                                               READY   STATUS    RESTARTS      AGE
keda-admission-webhooks-6c974699d8-qlfn4           1/1     Running   0             26s
keda-operator-577d8b5b4b-qs4qd                     1/1     Running   1 (24s ago)   26s
keda-operator-metrics-apiserver-6d56b644bb-wkvb6   1/1     Running   0             26s
```

L'opérateur surveille les sources ; le serveur de métriques les présente à l'API server sous forme de métriques externes, que les HPA savent lire. Un objet `ScaledObject` décrit la règle :

```yaml title="keda-worker.yaml"
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: worker
  namespace: colis
spec:
  scaleTargetRef:
    name: worker
  minReplicaCount: 0
  maxReplicaCount: 5
  pollingInterval: 5          # interroger Redis toutes les 5 secondes
  cooldownPeriod: 30          # attendre 30 s de file vide avant de passer à zéro
  triggers:
  - type: redis
    metadata:
      address: redis.colis.svc.cluster.local:6379
      listName: colis:a-estimer
      listLength: "5"
```

`colis:a-estimer` est le nom de la liste Redis où l'API dépose les colis (dans `colis/file.py`). `listLength: "5"` fixe la cible : un worker pour cinq colis en attente.

```bash
kubectl apply -f keda-worker.yaml
kubectl -n colis get scaledobject worker
kubectl -n colis get hpa
kubectl -n colis get deploy worker
```

```sortie
NAME     SCALETARGETKIND      SCALETARGETNAME   MIN   MAX   READY   ACTIVE   FALLBACK   PAUSED   TRIGGERS   AUTHENTICATIONS   AGE
worker   apps/v1.Deployment   worker            0     5     True    False    False      False    redis                        45s
NAME              REFERENCE           TARGETS             MINPODS   MAXPODS   REPLICAS   AGE
api               Deployment/api      cpu: 4%/50%         2         6         2          9m58s
keda-hpa-worker   Deployment/worker   <unknown>/5 (avg)   1         5         0          45s
NAME     READY   UP-TO-DATE   AVAILABLE   AGE
worker   0/0     0            0           7h35m
```

La file était vide : KEDA a ramené le worker à **zéro** réplique. Il a créé un HPA `keda-hpa-worker`, de 1 à 5, qui prendra le relais au-dessus d'une réplique. Envoyons une rafale de 100 colis, et suivons la file et les workers :

```bash
seq 1 100 | xargs -P 10 -I{} curl -s -o /dev/null -X POST http://192.168.49.100/api/colis \
  -H 'Content-Type: application/json' -d '{"destinataire":"Lot {}","depart":"Paris","arrivee":"Lyon","poids_kg":1}'
# toutes les 5 secondes :
kubectl -n colis exec deploy/redis -- redis-cli LLEN colis:a-estimer
kubectl -n colis get deploy worker -o jsonpath='{.status.readyReplicas}/{.spec.replicas}{"\n"}'
```

```sortie
100 colis créés en 0 s
t=0s file=100 workers=0/0
t=6s file=100 workers=0/1
t=11s file=92 workers=1/1
t=16s file=81 workers=1/4
t=22s file=50 workers=4/4
t=27s file=6 workers=4/4
t=32s file=0 workers=5/5
t=38s file=0 workers=5/5
...
t=54s file=0 workers=5/5
t=59s file=0 workers=0/0
```

```bash
kubectl -n colis get events --field-selector involvedObject.name=worker --sort-by=.lastTimestamp | grep -E 'KEDAScaleTarget|ScalingReplicaSet'
```

```sortie
54s         Normal    KEDAScaleTargetActivated     scaledobject/worker   Scaled apps/v1.Deployment colis/worker from 0 to 1, triggered by s0-redis-colis-a-estim
54s         Normal    ScalingReplicaSet            deployment/worker     Scaled up replica set worker-594df4b89 from 0 to 1
43s         Normal    ScalingReplicaSet            deployment/worker     Scaled up replica set worker-594df4b89 from 1 to 4
28s         Normal    ScalingReplicaSet            deployment/worker     Scaled up replica set worker-594df4b89 from 4 to 5
4s          Normal    ScalingReplicaSet            deployment/worker     Scaled down replica set worker-594df4b89 from 5 to 0
```

<Figure svg={kedaRafale} num="31.2" alt="Chronologie mesurée, sur 60 secondes. La file compte 100 colis de 0 à 6 secondes, puis 92 à 11 secondes, 81 à 16, 50 à 22, 6 à 27 et 0 à 32 secondes. Les workers demandés passent de 0 à 1 à 6 secondes (réveil), de 1 à 4 à 16 secondes, de 4 à 5 à 32 secondes, alors que la file est déjà vide (métriques en retard), puis de 5 à 0 à 59 secondes, après 30 secondes sans colis (cooldownPeriod).">
Une rafale de 100 colis, et les workers que KEDA a demandés. Relevé toutes les cinq secondes sur le cluster du cours.
</Figure>

La figure 31.2 montre le déroulé. En 6 secondes, KEDA a vu la file et réveillé un worker (0 → 1, l'étape qu'il fait lui-même). Le HPA a pris le relais, et a porté le worker à 4 répliques, puis à 5, son maximum. La file s'est vidée en 32 secondes ; un worker seul y aurait mis plus d'une minute. Mais le cinquième worker est arrivé quand la file était déjà vide : le HPA décide sur des métriques qui ont quelques secondes de retard, et un autoscaler dépasse souvent un peu à la fin d'une rafale. Enfin, 30 secondes après le dernier colis (`cooldownPeriod`), KEDA a tout ramené à zéro. Entre deux rafales, le worker ne consomme plus rien, et le premier colis d'une rafale attend quelques secondes de plus, le temps du réveil : c'est le compromis du *scale to zero*.

## Exercices

:::exercice[Exercice 1 : HPA et VPA ensemble]

On veut que l'API de Colis suive la charge en nombre de répliques, **et** que sa request de mémoire suive sa consommation réelle. Proposez un couple HPA et VPA qui ne se marchent pas dessus.

:::

<details>
<summary>Corrigé</summary>

Le HPA garde le processeur, le VPA ne s'occupe que de la mémoire, grâce à `controlledResources` :

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: api
  namespace: colis
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api
  updatePolicy:
    updateMode: "Off"
  resourcePolicy:
    containerPolicies:
    - containerName: api
      controlledResources: ["memory"]
      minAllowed:
        memory: 128Mi
      maxAllowed:
        memory: 512Mi
```

```bash
kubectl apply --dry-run=server -f vpa-api.yaml
```

```sortie
verticalpodautoscaler.autoscaling.k8s.io/api created (server dry run)
```

Le VPA ne touchera jamais à la request de processeur, sur laquelle le HPA calcule son pourcentage : les deux boucles restent indépendantes. `minAllowed` et `maxAllowed` bornent ce que le VPA pourra décider, contre ses planchers d'un côté et un emballement de l'autre. On le laisse en `Off` le temps de vérifier ses recommandations sur quelques jours, avant de passer en `InPlaceOrRecreate`.

</details>

:::exercice[Exercice 2 : combien de workers ?]

Avec `listLength: "5"` et `maxReplicaCount: 5`, combien de workers KEDA demande-t-il pour 12 colis en attente ? Pour 400 ? Le worker traite un colis toutes les 0,5 seconde : combien de temps faut-il pour vider une file de 400 colis ? Que changeriez-vous si les colis devaient être estimés en moins de 20 secondes ?

:::

<details>
<summary>Corrigé</summary>

Le HPA de KEDA vise 5 colis par worker : pour 12 colis, ⌈12 / 5⌉ = 3 workers ; pour 400, ⌈400 / 5⌉ = 80, plafonnés à `maxReplicaCount`, soit 5. Cinq workers traitent 10 colis par seconde : 400 colis prennent 40 secondes, plus les quelques secondes du réveil et de la montée en charge, soit près d'une minute pour le dernier colis. Pour tenir 20 secondes, il faut 20 colis par seconde, donc 10 workers au moins : relever `maxReplicaCount` à 10 ou plus, en vérifiant que le nœud a la place (chaque worker demande 96 Mio de mémoire, et le HPA ne crée pas de Pod là où le scheduler n'en place pas). On peut aussi baisser `listLength`, pour que les workers arrivent plus tôt dans la rafale, ou garder `minReplicaCount: 1` pour supprimer le délai de réveil. À l'autre bout, PostgreSQL et Redis doivent suivre : dix workers, c'est dix fois plus de requêtes sur la base, et un autoscaler ne fait que déplacer le goulet d'étranglement s'il existe ailleurs.

</details>

:::exercice[Exercice 3 : pourquoi pas le processeur ?]

Pourquoi ne pas simplement mettre un HPA sur le processeur du worker, comme sur l'API ?

:::

<details>
<summary>Corrigé</summary>

Parce que le processeur du worker ne dit rien de la file. Le worker passe l'essentiel de son temps à attendre, dans `BLPOP` (la file) ou dans le `sleep` qui simule le calcul : 1m de processeur au repos comme en pleine rafale. Un HPA sur le processeur ne verrait jamais de charge, et laisserait les colis s'accumuler. C'est le cas de beaucoup de programmes qui dépendent d'entrées/sorties : leur « charge » se mesure à ce qui les attend (messages en file, requêtes en cours, retard d'un consommateur Kafka), pas à leur processeur. Et un HPA ne descend pas à zéro : même au calme, il garderait au moins un worker. KEDA règle les deux points.

</details>

## Nettoyer

HPA, VPA et KEDA peuvent rester : le défi IV s'en sert. Pour les retirer :

```bash
kubectl -n colis delete scaledobject worker
kubectl -n colis scale deploy worker --replicas=1
kubectl -n colis delete vpa worker
kubectl -n colis delete hpa api
helm -n keda uninstall keda
helm -n vpa uninstall vpa
kubectl delete namespace keda vpa ch31
```

Supprimer le `ScaledObject` laisse le worker au nombre de répliques du moment, éventuellement zéro : d'où le `scale`. Pour réveiller les copies de Colis mises en sommeil au début du chapitre, remettez leurs répliques (1 ou 2 selon les composants).

[^hpa]: Kubernetes, « Horizontal Pod Autoscaling », sections *Algorithm details*, *Stabilization window* et *Default behavior*. [kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)

[^migration]: Kubernetes, « Horizontal Pod Autoscaling », section *Migrating Deployments and StatefulSets to horizontal autoscaling*. [kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/#migrating-deployments-and-statefulsets-to-horizontal-autoscaling)

[^vpa]: Kubernetes SIG Autoscaling, « Vertical Pod Autoscaler », dont les modes de mise à jour et les options du recommender. [github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler](https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler)

[^enplace]: Kubernetes, « Resize CPU and Memory Resources assigned to Containers », et Kubernetes Enhancement Proposal 1287, « In-Place Update of Pod Resources ». [kubernetes.io/docs/tasks/configure-pod-container/resize-container-resources](https://kubernetes.io/docs/tasks/configure-pod-container/resize-container-resources/)

[^keda]: KEDA, documentation 2.21, « Scaling Deployments, StatefulSets & Custom Resources » et « Redis Lists scaler ». [keda.sh/docs/2.21/scalers/redis-lists](https://keda.sh/docs/2.21/scalers/redis-lists/)
