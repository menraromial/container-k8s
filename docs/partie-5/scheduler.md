---
title: Le scheduler
sidebar_label: 37. Le scheduler
description: "Le scheduler vu de l'intérieur : un contrôleur qui ne remplit qu'un champ, le Binding fait à la main, la configuration par défaut et le poids des plugins, les files d'attente et le cycle d'ordonnancement, un second scheduler qui tasse les Pods, la lecture des scores dans ses journaux, les Pods impossibles à placer et leur réveil."
partie: 5
chapitre: '37'
---

import ordonnanceurCycle from '@site/src/figures/ordonnanceur-cycle.svg';
import scoresNoeuds from '@site/src/figures/scores-noeuds.svg';

En préparant ce chapitre, j'ai voulu montrer un second scheduler, configuré pour **tasser** les Pods sur les nœuds déjà occupés au lieu de les étaler. C'est un réglage courant pour faire des économies : moins de nœuds remplis, plus de nœuds qu'on peut éteindre. J'ai changé la stratégie de notation, lancé ce second scheduler, et lui ai confié quatre Pods identiques, pendant que le scheduler par défaut en plaçait quatre autres :

```sortie
POD                     NOEUD
etale-868f7c466-2qqxm   deux-noeuds-m02
etale-868f7c466-mx426   deux-noeuds
etale-868f7c466-rjqhr   deux-noeuds
etale-868f7c466-vx5mb   deux-noeuds-m02
serre-cffb66f79-bhj8q   deux-noeuds
serre-cffb66f79-bzt2z   deux-noeuds
serre-cffb66f79-f5n6n   deux-noeuds-m02
serre-cffb66f79-lt6pq   deux-noeuds-m02
```

Deux et deux, dans les deux cas. Mon scheduler « serré » avait étalé les Pods exactement comme l'autre. Je n'avais pas fait d'erreur de configuration : le réglage était bien pris en compte. Mais le scheduler ne suit pas une règle, il **additionne des notes**, une par critère, chacune avec son poids, et la note que j'avais changée pesait trop peu face aux autres. Comprendre pourquoi demande d'ouvrir le scheduler, de lire sa configuration et ses calculs. C'est le programme de ce chapitre, qui prolonge le chapitre 32 : celui-là disait comment **influencer** le placement (affinités, taints, répartition, priorités) ; celui-ci montre comment le scheduler **décide**.

Il faut plusieurs nœuds pour que la question se pose. On reprend le profil `deux-noeuds` des chapitres 32 et 33, avec deux nœuds, après avoir arrêté le profil principal pour rester dans les limites de mémoire. Les fichiers sont dans [l'archive scheduler](pathname:///kits/scheduler.tar.gz).

```bash
minikube stop
minikube start -p deux-noeuds
kubectl create namespace ch37
kubectl config set-context --current --namespace=ch37
```

## Un contrôleur qui ne remplit qu'un champ

Le scheduler est un contrôleur, au sens du chapitre 36, avec un travail d'une étroitesse remarquable : il surveille les Pods dont le champ `spec.nodeName` est vide, choisit un nœud pour chacun, et écrit ce choix. Il ne lance rien, ne contacte aucun nœud, et ne vérifie pas que le Pod démarre. C'est le kubelet du nœud choisi qui, voyant apparaître un Pod à son nom, s'en charge (chapitre 38).

Le moyen le plus direct de le vérifier est de s'en passer. Tout Pod désigne son scheduler par le champ `schedulerName`, `default-scheduler` si on ne dit rien. Confions un Pod à un scheduler qui n'existe pas :

```yaml title="sans-scheduler.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: orphelin
spec:
  schedulerName: personne
  containers:
  - {name: c, image: registry.k8s.io/e2e-test-images/agnhost:2.61, args: [pause]}
```

```bash
kubectl apply -f sans-scheduler.yaml
sleep 5; kubectl get pod orphelin -o custom-columns=POD:.metadata.name,STATUT:.status.phase,NOEUD:.spec.nodeName
```

```sortie
pod/orphelin created
POD        STATUT    NOEUD
orphelin   Pending   <none>
```

Le Pod attendra indéfiniment. Faisons le travail du scheduler à sa place. Choisir un nœud, c'est créer un objet `Binding`, par un `POST` sur la sous-ressource `binding` du Pod (chapitre 34) :

```json title="binding.json"
{
  "apiVersion": "v1",
  "kind": "Binding",
  "metadata": {"name": "orphelin"},
  "target": {"apiVersion": "v1", "kind": "Node", "name": "deux-noeuds-m02"}
}
```

```bash
kubectl create --raw /api/v1/namespaces/ch37/pods/orphelin/binding -f binding.json
sleep 3; kubectl get pod orphelin -o custom-columns=POD:.metadata.name,STATUT:.status.phase,NOEUD:.spec.nodeName
kubectl get events --field-selector involvedObject.name=orphelin -o custom-columns=RAISON:.reason,COMPOSANT:.reportingComponent --no-headers
kubectl create --raw /api/v1/namespaces/ch37/pods/orphelin/binding -f binding.json
```

```sortie
{"kind":"Status","apiVersion":"v1","metadata":{},"status":"Success","code":201}
POD        STATUT    NOEUD
orphelin   Running   deux-noeuds-m02
Pulled    kubelet
Created   kubelet
Started   kubelet
Error from server (Conflict): Operation cannot be fulfilled on pods/binding "orphelin": pod orphelin is already assigned to node "deux-noeuds-m02"
```

Trois secondes après, le Pod tourne sur le nœud choisi. Les événements ne viennent que du kubelet : il manque le `Scheduled` habituel, que le scheduler écrit lui-même après avoir placé un Pod, et que personne n'a écrit ici. La seconde tentative est refusée : un Pod ne se place qu'une fois, et ne change jamais de nœud. S'il faut le déplacer, on le supprime et son contrôleur en crée un autre, que le scheduler placera à nouveau.

:::panne[Un Pod reste Pending sans aucun événement]

Un Pod que le scheduler n'arrive pas à placer porte toujours un événement `FailedScheduling` qui dit pourquoi. S'il n'y en a **aucun**, c'est qu'aucun scheduler ne s'est penché sur lui. Deux causes : un `schedulerName` mal orthographié, ou qui désigne un scheduler supplémentaire arrêté ; ou le scheduler par défaut lui-même en panne, ce qui se voit dans `kube-system` et se traduit par des Pods `Pending` dans tout le cluster. `kubectl get pod <nom> -o jsonpath='{.spec.schedulerName}'` tranche la première question en une commande.

:::

## La configuration par défaut

Le scheduler de minikube tourne avec presque aucune option, et en particulier sans fichier de configuration. Il utilise donc sa configuration par défaut. Le binaire sait l'écrire, avec l'option `--write-config-to` ; lançons-le une fois dans un Pod pour la lire[^config] :

```bash
kubectl run config-defaut --image=registry.k8s.io/kube-scheduler:v1.37.0 --restart=Never --command -- kube-scheduler --write-config-to=/dev/stdout
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/config-defaut
kubectl logs config-defaut | sed -n '/^apiVersion/,$p' > config.yaml
grep -E 'percentageOfNodesToScore|podInitialBackoffSeconds|podMaxBackoffSeconds|schedulerName' config.yaml
sed -n '/multiPoint:/,/permit:/p' config.yaml | grep -E 'name:|weight:' | paste - - | awk '{print $3, "poids", $5}'
```

```sortie
percentageOfNodesToScore: 0
podInitialBackoffSeconds: 1
podMaxBackoffSeconds: 10
  schedulerName: default-scheduler
SchedulingGates poids 0
PrioritySort poids 0
NodeName poids 0
NodeUnschedulable poids 0
TaintToleration poids 3
NodeAffinity poids 2
NodePorts poids 0
NodeResourcesFit poids 1
VolumeRestrictions poids 0
NodeVolumeLimits poids 0
VolumeBinding poids 0
VolumeZone poids 0
PodTopologySpread poids 2
InterPodAffinity poids 2
DynamicResources poids 2
DefaultPreemption poids 0
NodeResourcesBalancedAllocation poids 1
ImageLocality poids 1
DefaultBinder poids 0
NodeDeclaredFeatures poids 0
```

Tout le scheduler est là : une vingtaine de **plugins**, chacun responsable d'un critère, et un poids pour ceux qui notent. On reconnaît les mécanismes du chapitre 32 : `NodeAffinity` pour les sélecteurs et affinités de nœuds, `TaintToleration`, `PodTopologySpread`, `InterPodAffinity`, `DefaultPreemption`. D'autres sont nouveaux : `NodeName` écarte tous les nœuds sauf celui que le Pod désignerait déjà, `NodePorts` ceux où le `hostPort` demandé est pris, `NodeResourcesFit` ceux qui n'ont plus assez de processeur ou de mémoire (c'est lui qui écrit `Insufficient cpu`), les plugins de volumes ceux où le volume demandé ne peut pas être attaché. `ImageLocality` préfère les nœuds qui ont déjà l'image. Un poids de 0 signifie que le plugin ne note pas : il filtre, trie ou lie, mais ne participe pas au choix entre les nœuds admissibles.

Trois réglages généraux complètent le tableau. `podInitialBackoffSeconds` et `podMaxBackoffSeconds` bornent l'attente avant de réessayer un Pod qui a échoué : 1 seconde, puis 2, 4, 8, et jamais plus de 10. `percentageOfNodesToScore` limite le nombre de nœuds que le scheduler évalue : à 0, il choisit lui-même, 50 % des nœuds pour un cluster de 100, 10 % pour un cluster de 5000, jamais moins de 5 % ni moins de 100 nœuds[^perf]. Sur un grand cluster, le scheduler ne cherche donc pas le **meilleur** nœud, mais un bon nœud parmi un échantillon suffisant ; c'est ce qui lui permet de placer des centaines de Pods par seconde.

Pour les plugins, la section `pluginConfig` précise les réglages. Celui qui nous intéresse :

```bash
sed -n '/NodeResourcesFitArgs/,/type:/p' config.yaml
```

```sortie
      kind: NodeResourcesFitArgs
      scoringStrategy:
        resources:
        - name: cpu
          weight: 1
        - name: memory
          weight: 1
        type: LeastAllocated
```

`LeastAllocated` : `NodeResourcesFit` note mieux les nœuds les **moins** remplis, en processeur et en mémoire, avec le même poids. C'est ce qui étale les Pods par défaut. Les autres stratégies sont `MostAllocated`, l'inverse, et `RequestedToCapacityRatio`, une courbe sur mesure.

## Un cycle, deux étapes

Les plugins ne sont pas appelés dans le désordre. Le scheduler est bâti sur un **cadre** (*scheduling framework*) qui définit une suite de points d'extension, chacun avec son rôle, et les plugins s'y inscrivent[^cadre]. La figure 37.1 en suit le parcours.

<Figure svg={ordonnanceurCycle} num="37.1" alt="Le parcours d'un Pod dans le scheduler. À gauche, quatre files : gated, pour les Pods qui ont encore des portes ; active, triée par priorité ; backoff, pour les Pods qui attendent 1, 2, jusqu'à 10 secondes avant un nouvel essai ; unschedulable, pour les Pods qui attendent un événement utile. Un Pod de la file active passe par PreEnqueue et QueueSort, puis entre dans le cycle d'ordonnancement, un Pod à la fois : PreFilter et Filter donnent les nœuds possibles ; s'il n'y en a aucun, PostFilter tente la préemption, et en cas d'échec le Pod reçoit FailedScheduling et part dans la file unschedulable, d'où un événement utile le ramène dans la file active ; s'il y en a au moins un, PreScore et Score notent chaque nœud, score fois poids, puis Reserve et Permit retiennent le nœud. Vient ensuite le cycle de liaison, en parallèle : PreBind pour les volumes, Bind qui fait le POST sur la sous-ressource binding, PostBind qui écrit l'événement Scheduled. Une porte retirée fait passer un Pod de la file gated à la file active.">
Le parcours d'un Pod dans le scheduler. Le cycle d'ordonnancement traite un Pod à la fois ; le cycle de liaison se fait en parallèle, pour ne pas le ralentir.
</Figure>

Les Pods à placer attendent dans des **files**. La file active est triée par priorité (le plugin `PrioritySort`, au point `QueueSort`), ce qui fait passer les Pods d'une `PriorityClass` élevée avant les autres. Le scheduler en prend un, et entre dans le **cycle d'ordonnancement**, qui traite un seul Pod à la fois : c'est ce qui garantit que deux Pods ne se voient pas attribuer la même dernière place libre. Les plugins de filtrage (`Filter`) éliminent les nœuds impossibles. S'il n'en reste aucun, `PostFilter` tente la préemption du chapitre 32. S'il en reste plusieurs, chaque plugin de notation (`Score`) donne à chaque nœud une note entre 0 et 100, multipliée par son poids ; le nœud qui a la plus grosse somme l'emporte. `Reserve` le réserve dans le cache du scheduler, pour que le Pod suivant voie la place comme prise.

Le **cycle de liaison** se fait ensuite en parallèle, dans une autre tâche, parce qu'il peut être lent : `PreBind` attend, si besoin, que le volume du Pod soit provisionné ; `Bind` fait le `POST` qu'on a fait à la main tout à l'heure. Pendant ce temps, le cycle d'ordonnancement passe déjà au Pod suivant.

Les Kubernetes récents ajoutent d'autres points d'extension, qu'on aperçoit dans la configuration complète (`placementGenerate`, `podGroupPostFilter`...) : ils servent à placer des **groupes** de Pods qui doivent démarrer ensemble, comme les tâches de calcul distribué ou d'apprentissage automatique. Le principe reste le même.

## Lire une décision

Pour voir les notes, il faut un scheduler bavard. Le scheduler par défaut de minikube est un Pod statique qu'on préfère ne pas toucher ; lançons plutôt un **second scheduler**, dans notre namespace, avec son propre profil et ses propres journaux au niveau de détail maximal (`-v=10`). Kubernetes accepte autant de schedulers qu'on veut ; chacun ne s'occupe que des Pods qui le désignent par leur `schedulerName`[^plusieurs]. Le fichier `ordonnanceur-serre.yaml` contient les droits dont il a besoin (ceux du scheduler par défaut, par les ClusterRoles `system:kube-scheduler` et `system:volume-scheduler`), sa configuration et son Deployment :

```yaml title="ordonnanceur-serre.yaml (extrait)"
  config.yaml: |
    apiVersion: kubescheduler.config.k8s.io/v1
    kind: KubeSchedulerConfiguration
    leaderElection:
      leaderElect: false
    profiles:
    - schedulerName: ordonnanceur-serre
      pluginConfig:
      - name: NodeResourcesFit
        args:
          scoringStrategy:
            type: MostAllocated
            resources:
            - {name: cpu, weight: 1}
            - {name: memory, weight: 1}
...
      containers:
      - name: kube-scheduler
        image: registry.k8s.io/kube-scheduler:v1.37.0
        command: [kube-scheduler, --config=/etc/ordonnanceur/config.yaml, -v=10]
```

Un seul changement par rapport au défaut : la stratégie `MostAllocated`. Le fichier `pods-test.yaml` décrit deux Deployments identiques de quatre Pods, qui demandent chacun un cœur ; `etale` est confié au scheduler par défaut, `serre` au nôtre. C'est l'expérience du début. Avant de lire les journaux, regardons les nœuds :

```bash
kubectl get nodes -o custom-columns=NOEUD:.metadata.name,CPU:.status.allocatable.cpu,MEMOIRE:.status.allocatable.memory
```

```sortie
NOEUD             CPU   MEMOIRE
deux-noeuds       22    15778000Ki
deux-noeuds-m02   22    15778000Ki
```

Chaque nœud annonce 22 cœurs et 15 Gio : ceux du poste entier, puisque minikube, avec le pilote Docker, ne limite pas ses nœuds (chapitre 0.2). C'est un détail qui va compter. Voici ce qu'a écrit notre scheduler pour les deux premiers Pods de `serre`, réduit aux lignes utiles :

```bash
for P in $(kubectl logs deploy/ordonnanceur-serre | grep -o 'Attempting to schedule pod" pod="ch37/serre-[a-z0-9-]*' | head -2 | sed 's/.*ch37\///'); do
  echo "# Pod $P"
  kubectl logs deploy/ordonnanceur-serre | grep "pod=\"ch37/$P\"" | grep -E 'Plugin scored|final score|Attempting to bind'
done
```

```sortie
# Pod serre-cffb66f79-bzt2z
"Plugin scored node for pod" plugin="TaintToleration" node="deux-noeuds" score=300
"Plugin scored node for pod" plugin="NodeResourcesFit" node="deux-noeuds" score=17
"Plugin scored node for pod" plugin="VolumeBinding" node="deux-noeuds" score=0
"Plugin scored node for pod" plugin="PodTopologySpread" node="deux-noeuds" score=200
"Plugin scored node for pod" plugin="DynamicResources" node="deux-noeuds" score=0
"Plugin scored node for pod" plugin="NodeResourcesBalancedAllocation" node="deux-noeuds" score=74
"Plugin scored node for pod" plugin="ImageLocality" node="deux-noeuds" score=3
"Plugin scored node for pod" plugin="TaintToleration" node="deux-noeuds-m02" score=300
"Plugin scored node for pod" plugin="NodeResourcesFit" node="deux-noeuds-m02" score=11
"Plugin scored node for pod" plugin="VolumeBinding" node="deux-noeuds-m02" score=0
"Plugin scored node for pod" plugin="PodTopologySpread" node="deux-noeuds-m02" score=200
"Plugin scored node for pod" plugin="DynamicResources" node="deux-noeuds-m02" score=0
"Plugin scored node for pod" plugin="NodeResourcesBalancedAllocation" node="deux-noeuds-m02" score=74
"Plugin scored node for pod" plugin="ImageLocality" node="deux-noeuds-m02" score=3
"Calculated node's final score for pod" node="deux-noeuds" score=594
"Calculated node's final score for pod" node="deux-noeuds-m02" score=588
"Attempting to bind pod to node" node="deux-noeuds"
# Pod serre-cffb66f79-f5n6n
"Plugin scored node for pod" plugin="TaintToleration" node="deux-noeuds" score=300
"Plugin scored node for pod" plugin="NodeResourcesFit" node="deux-noeuds" score=20
...
"Plugin scored node for pod" plugin="PodTopologySpread" node="deux-noeuds" score=132
...
"Plugin scored node for pod" plugin="PodTopologySpread" node="deux-noeuds-m02" score=200
...
"Calculated node's final score for pod" node="deux-noeuds" score=529
"Calculated node's final score for pod" node="deux-noeuds-m02" score=588
"Attempting to bind pod to node" node="deux-noeuds-m02"
```

(J'ai retiré des lignes l'horodatage et le nom du Pod, et, pour le second Pod, les notes identiques sur les deux nœuds.) Les notes affichées sont déjà multipliées par le poids du plugin : 300 pour `TaintToleration`, c'est la note maximale, 100, fois 3. On peut refaire l'addition : 300 + 17 + 0 + 200 + 0 + 74 + 3 = 594. La figure 37.2 met les trois décisions de cette section côte à côte.

<Figure svg={scoresNoeuds} num="37.2" alt="Des barres empilées des notes pondérées, par plugin, pour chaque nœud. Version 1, premier Pod : deux-noeuds, 300 pour TaintToleration, 17 pour NodeResourcesFit, 200 pour PodTopologySpread, 74 pour BalancedAllocation, 3 pour ImageLocality, total 594 ; deux-noeuds-m02, 300, 11, 200, 74 et 3, total 588 : deux-noeuds l'emporte de 6 points. Version 1, deuxième Pod : deux-noeuds, 300, 20, 132, 74, 3, total 529 ; deux-noeuds-m02, 300, 11, 200, 74, 3, total 588 : la répartition renvoie vers m02. Version 2, sans répartition, avec NodeResourcesFit pesant 5 : deux-noeuds, 300, 110, 73, 3, total 486 ; deux-noeuds-m02, 300, 75, 74, 3, total 452 : le nœud le plus rempli gagne.">
Les notes pondérées relevées dans les journaux d'`ordonnanceur-serre`. Seul `NodeResourcesFit` exprime la stratégie choisie ; dans la version 1, il pèse trop peu pour l'emporter sur la répartition.
</Figure>

Tout s'explique. Notre stratégie `MostAllocated` a bien joué : `NodeResourcesFit` note mieux `deux-noeuds`, le plus rempli (17 contre 11). Mais sur des nœuds de 22 cœurs, un Pod d'un cœur ne remplit presque rien, et l'écart reste de quelques points. Pour le premier Pod, il suffit à départager deux nœuds par ailleurs à égalité. Pour le second, un autre plugin se réveille : `PodTopologySpread`. On n'a pourtant déclaré aucune contrainte de répartition. C'est que le scheduler en applique **par défaut** à tout Pod sélectionné par un ReplicaSet (donc un Deployment), un StatefulSet ou un Service : étaler les Pods de ce groupe entre les nœuds (écart toléré de 3) et entre les zones (écart de 5), en préférence seulement[^repartition]. Le premier Pod étant sur `deux-noeuds`, ce nœud perd 68 points de répartition, que les 9 points d'écart sur les ressources ne compensent pas. Ce qui avait l'air d'une règle (« tasser ») n'était qu'une voix parmi d'autres, et pas la plus forte.

La correction se fait donc sur les voix. Dans `ordonnanceur-serre-v2.yaml`, deux changements : plus de contraintes de répartition implicites, et un poids de 5 pour `NodeResourcesFit` :

```yaml title="ordonnanceur-serre-v2.yaml (extrait)"
      - name: PodTopologySpread
        args:
          defaultingType: List        # pas de contraintes de répartition implicites
      plugins:
        score:
          enabled:
          - {name: NodeResourcesFit, weight: 5}
```

```bash
kubectl apply -f ordonnanceur-serre-v2.yaml
kubectl rollout restart deploy/ordonnanceur-serre
kubectl rollout restart deploy/serre
kubectl get pods -l app=serre -o custom-columns=POD:.metadata.name,NOEUD:.spec.nodeName --sort-by=.metadata.name
```

```sortie
POD                      NOEUD
serre-85cc8bc97d-cgvbm   deux-noeuds
serre-85cc8bc97d-cm9qc   deux-noeuds
serre-85cc8bc97d-mxgqv   deux-noeuds
serre-85cc8bc97d-whxf2   deux-noeuds
```

Les quatre Pods sont tassés sur le même nœud. Les journaux du premier montrent `NodeResourcesFit` à 110 contre 75 (22 et 15, fois 5), et plus de `PodTopologySpread` : 486 contre 452. La leçon dépasse l'exemple. Pour prévoir où ira un Pod, il ne suffit pas de lire ses contraintes : il faut savoir quels plugins notent, avec quels poids, et quels réglages s'appliquent sans avoir été écrits. Les journaux à `-v=10` d'un scheduler de test sont le moyen le plus sûr de le savoir.

## Quand aucun nœud ne convient

Le fichier `attente.yaml` contient trois Pods que le scheduler ne peut pas placer tout de suite, chacun pour une raison différente : `exigeant` veut un nœud étiqueté `disque=ssd`, qui n'existe pas encore sur ce cluster ; `glouton` demande 50 cœurs ; `retenu` porte une **porte d'ordonnancement** (*scheduling gate*), un nom dans son champ `schedulingGates`.

```bash
kubectl apply -f attente.yaml
sleep 5; kubectl get pods exigeant glouton retenu
kubectl get events --field-selector reason=FailedScheduling -o custom-columns=POD:.involvedObject.name,MESSAGE:.message --no-headers
```

```sortie
pod/exigeant created
pod/glouton created
pod/retenu created
NAME       READY   STATUS            RESTARTS   AGE
exigeant   0/1     Pending           0          5s
glouton    0/1     Pending           0          5s
retenu     0/1     SchedulingGated   0          5s
exigeant   0/2 nodes are available: 2 node(s) didn't match Pod's node affinity/selector. preemption: 0/2 nodes are available: 2 Preemption is not helpful for scheduling.
glouton    0/2 nodes are available: 2 Insufficient cpu. preemption: 0/2 nodes are available: 2 Preemption is not helpful for scheduling.
```

Chaque message de `FailedScheduling` a deux parties. La première est le bilan du filtrage, un compte par raison, la même forme que dans le simulateur du chapitre 32. La seconde est le bilan de `PostFilter` : la préemption « n'aiderait pas », parce qu'évincer des Pods ne crée ni une étiquette, ni 50 cœurs sur une machine qui en a 22. `retenu`, lui, n'a pas d'événement : le scheduler ne l'a même pas examiné, et son statut dit pourquoi, `SchedulingGated`.

Où sont ces Pods, pour le scheduler ? Ses métriques le disent. Comme celles du gestionnaire de contrôleurs au chapitre 36, elles demandent un jeton autorisé à lire `/metrics` :

```bash
kubectl create sa lecteur-metriques
kubectl create clusterrole cours-lecture-metriques --verb=get --non-resource-url=/metrics
kubectl create clusterrolebinding cours-lecture-metriques-ch37 --clusterrole=cours-lecture-metriques --serviceaccount=ch37:lecteur-metriques
T=$(kubectl create token lecteur-metriques)
minikube ssh -p deux-noeuds -- "curl -sk -H 'Authorization: Bearer $T' https://127.0.0.1:10259/metrics" | grep -E '^scheduler_pending_pods|^scheduler_schedule_attempts_total'
```

```sortie
scheduler_pending_pods{queue="active"} 0
scheduler_pending_pods{queue="backoff"} 0
scheduler_pending_pods{queue="gated"} 1
scheduler_pending_pods{queue="incomplete"} 0
scheduler_pending_pods{queue="pending"} 0
scheduler_pending_pods{queue="unschedulable"} 2
scheduler_schedule_attempts_total{profile="default-scheduler",result="scheduled"} 25
scheduler_schedule_attempts_total{profile="default-scheduler",result="unschedulable"} 8
```

Un Pod dans la file `gated`, deux dans la file `unschedulable`, et la file active vide : le scheduler ne tourne pas en boucle sur des Pods qu'il sait impossibles. Il ne les réessaie pas non plus toutes les dix secondes. Un Pod de la file `unschedulable` n'en sort que lorsqu'un événement du cluster pourrait changer la réponse : un nœud ajouté ou modifié, un Pod supprimé qui libère de la place. Et depuis Kubernetes 1.32, chaque plugin dit précisément quels événements le concernent (les *queueing hints*[^indices]) : `NodeAffinity` ne réveille un Pod que si une étiquette de nœud change, `NodeResourcesFit` que si de la place se libère. Posons l'étiquette qui manque :

```bash
t0=$(date +%s.%N); kubectl label node deux-noeuds-m02 disque=ssd
kubectl wait --for=condition=PodScheduled pod/exigeant --timeout=30s
printf 'placé %.2f s après la pose de l étiquette\n' $(echo "$(date +%s.%N)-$t0" | bc)
```

```sortie
node/deux-noeuds-m02 labeled
pod/exigeant condition met
placé 0.29 s après la pose de l étiquette
```

Moins d'un tiers de seconde, commande kubectl comprise. Le scheduler a vu la modification du nœud par son watch, `NodeAffinity` a jugé qu'elle pouvait intéresser `exigeant`, le Pod est repassé dans la file active et a été placé aussitôt. `glouton`, lui, est resté où il était : un changement d'étiquette ne lui apporte pas de processeur. Par précaution, le scheduler finit tout de même par réessayer les Pods de la file `unschedulable` qui y restent longtemps, au bout de cinq minutes par défaut.

La porte, enfin, se lève en retirant son nom de la liste :

```bash
kubectl get pod retenu -o jsonpath='{.status.conditions[0].reason} : {.status.conditions[0].message}{"\n"}'
kubectl patch pod retenu --type=json -p '[{"op":"remove","path":"/spec/schedulingGates"}]'
sleep 3; kubectl get pod retenu -o custom-columns=POD:.metadata.name,STATUT:.status.phase,NOEUD:.spec.nodeName
```

```sortie
SchedulingGated : Scheduling is blocked due to non-empty scheduling gates
pod/retenu patched
POD      STATUT    NOEUD
retenu   Running   deux-noeuds-m02
```

Les portes servent à un contrôleur extérieur qui doit préparer quelque chose avant que le Pod ne soit placé : réserver un quota, attendre qu'un groupe de Pods soit complet, obtenir une ressource rare[^portes]. Tant qu'elles sont là, le Pod ne coûte rien au scheduler. Seul le retrait est permis : on ne peut pas ajouter de porte à un Pod existant.

## Exercices

:::exercice[Exercice 1 : refaire l'addition]

Dans les journaux de la version 1, le deuxième Pod reçoit 529 points sur `deux-noeuds` et 588 sur `deux-noeuds-m02`. Retrouvez ces deux totaux à partir des notes de chaque plugin, et dites quel plugin a fait la différence. Pourquoi la note de `NodeResourcesFit` sur `deux-noeuds` est-elle passée de 17 pour le premier Pod à 20 pour le second ?

:::

<details>
<summary>Corrigé</summary>

Sur `deux-noeuds` : 300 (TaintToleration) + 20 (NodeResourcesFit) + 0 (VolumeBinding) + 132 (PodTopologySpread) + 0 (DynamicResources) + 74 (BalancedAllocation) + 3 (ImageLocality) = 529. Sur `deux-noeuds-m02` : 300 + 11 + 0 + 200 + 0 + 74 + 3 = 588. Tous les plugins donnent presque la même note aux deux nœuds, sauf `PodTopologySpread` : 132 contre 200. Le premier Pod de `serre` est sur `deux-noeuds`, et la contrainte de répartition implicite pénalise ce nœud ; la différence de 68 points dépasse largement les 9 points d'avance que `MostAllocated` donne à `deux-noeuds`. Quant au passage de 17 à 20, c'est `Reserve` qui l'explique : dès que le premier Pod a été retenu pour `deux-noeuds`, le scheduler a compté son cœur comme occupé dans son cache, avant même la liaison. Le nœud est donc un peu plus rempli pour le second Pod, et `MostAllocated` l'en note un peu mieux.

</details>

:::exercice[Exercice 2 : un nœud interdit]

Marquez `deux-noeuds-m02` non planifiable (`kubectl cordon`), puis créez le Pod de `direct.yaml`, qui désigne lui-même ce nœud par `spec.nodeName`. Le Pod démarre-t-il ? Qui a écrit ses événements ? Qu'en concluez-vous sur la portée de `cordon` ? N'oubliez pas `kubectl uncordon` ensuite.

:::

<details>
<summary>Corrigé</summary>

```sortie
node/deux-noeuds-m02 cordoned
pod/direct created
POD      STATUT    NOEUD
direct   Running   deux-noeuds-m02
Pulled    kubelet
Created   kubelet
Started   kubelet
NAME              STATUS                     ROLES    AGE   VERSION
deux-noeuds-m02   Ready,SchedulingDisabled   <none>   25h   v1.37.0
```

Le Pod tourne, sur un nœud marqué `SchedulingDisabled`. Un Pod qui arrive avec `nodeName` déjà rempli ne passe jamais par le scheduler : il n'y a rien à décider. Le kubelet du nœud voit un Pod à son nom et le lance ; il vérifie seulement qu'il a les ressources nécessaires (sinon, le Pod échoue avec une raison comme `OutOfcpu`), mais il ne regarde ni le marquage `unschedulable`, ni les taints `NoSchedule`, qui sont des consignes pour le scheduler. `cordon` n'est donc pas une barrière : c'est une préférence que seul le scheduler respecte. Remplir `nodeName` à la main est une façon de court-circuiter toutes les règles du chapitre 32 ; les DaemonSets l'ont longtemps fait, avant de passer, eux aussi, par le scheduler et une affinité de nœud.

</details>

:::exercice[Exercice 3 : le glouton oublié]

Après avoir posé l'étiquette `disque=ssd` et levé la porte, relevez de nouveau les métriques des files du scheduler. Où est `glouton` ? Le scheduler va-t-il le réessayer toutes les dix secondes, puisque c'est le délai maximal de `backoff` ? Que faudrait-il pour qu'il soit placé ?

:::

<details>
<summary>Corrigé</summary>

```sortie
scheduler_pending_pods{queue="active"} 0
scheduler_pending_pods{queue="backoff"} 0
scheduler_pending_pods{queue="gated"} 0
scheduler_pending_pods{queue="incomplete"} 0
scheduler_pending_pods{queue="pending"} 0
scheduler_pending_pods{queue="unschedulable"} 1
scheduler_schedule_attempts_total{profile="default-scheduler",result="scheduled"} 27
scheduler_schedule_attempts_total{profile="default-scheduler",result="unschedulable"} 9
```

`glouton` est seul dans la file `unschedulable`. Le délai de `backoff` ne s'applique qu'aux Pods qui **peuvent** être réessayés ; un Pod jugé impossible attend, lui, un événement susceptible de changer la réponse, ou le réessai de précaution au bout de cinq minutes. Le compteur `unschedulable` a pris un point de plus depuis la dernière mesure : un des événements de l'intervalle (la modification de `deux-noeuds-m02`) a été jugé digne d'un nouvel essai, qui a échoué. Pour que `glouton` soit placé, il faudrait un nœud d'au moins 50 cœurs allouables : en ajouter un, ou recréer le Pod avec une demande plus raisonnable. Sur un vrai cluster, c'est précisément le signal qu'attend un **autoscaler de cluster** : des Pods `Pending` pour manque de ressources, auxquels il répond en ajoutant des nœuds. minikube n'en a pas.

</details>

:::exercice[Exercice 4 : écrire un scheduler]

Écrivez, en Python et avec la bibliothèque standard, un scheduler qui place **au hasard**, sur un nœud prêt et planifiable, chaque Pod dont le `schedulerName` est `hasard`. Passez par `kubectl proxy --port=8011`. Testez-le avec le Deployment de `hasard.yaml` (six répliques). Quelles vérifications du vrai scheduler votre programme oublie-t-il ?

:::

<details>
<summary>Corrigé</summary>

```python title="ordonnanceur-hasard.py (extrait)"
def placer(pod):
    ns, nom = pod["metadata"]["namespace"], pod["metadata"]["name"]
    noeud = random.choice(noeuds_prets())
    requete("POST", f"/namespaces/{ns}/pods/{nom}/binding",
            {"apiVersion": "v1", "kind": "Binding", "metadata": {"name": nom},
             "target": {"apiVersion": "v1", "kind": "Node", "name": noeud}})
    print(f"{time.strftime('%H:%M:%S')} {ns}/{nom} -> {noeud}", flush=True)


# les Pods qui nous sont confiés et qui n'ont pas encore de nœud
selecteur = "fieldSelector=spec.schedulerName%3Dhasard,spec.nodeName%3D"
liste = requete("GET", f"/pods?{selecteur}")
for pod in liste["items"]:
    placer(pod)
with urllib.request.urlopen(f"{API}/pods?{selecteur}&watch=true"
                            f"&resourceVersion={liste['metadata']['resourceVersion']}") as flux:
    for ligne in flux:
        ev = json.loads(ligne)
        if ev["type"] == "ADDED":
            placer(ev["object"])
```

La fonction `noeuds_prets` liste les nœuds dont la condition `Ready` est vraie et qui ne sont pas marqués `unschedulable`. Le sélecteur de champs `spec.nodeName=` (vide) fait que l'API ne renvoie que les Pods pas encore placés.

```sortie
20:09:10 ch37/hasard-8f9fdc569-gz5fx -> deux-noeuds
20:09:10 ch37/hasard-8f9fdc569-vsp8j -> deux-noeuds-m02
20:09:10 ch37/hasard-8f9fdc569-r7wdw -> deux-noeuds
20:09:10 ch37/hasard-8f9fdc569-mczm2 -> deux-noeuds-m02
20:09:10 ch37/hasard-8f9fdc569-vscr6 -> deux-noeuds
20:09:10 ch37/hasard-8f9fdc569-chvnw -> deux-noeuds
```

Six Pods placés en une seconde, quatre d'un côté, deux de l'autre, par le hasard. Ce scheduler ne fait aucun filtrage : il ignore les requests (il placerait `glouton` sur un nœud trop petit, où le kubelet le refuserait avec `OutOfcpu`), les taints et les tolérances, les sélecteurs et les affinités, les ports d'hôte, les volumes. Il n'écrit pas d'événement `Scheduled`. Il ne tient pas de cache des places réservées, et ne gère ni les échecs (un `409` si le Pod a été placé entre-temps) ni la reprise du watch. Tout cela, c'est la vingtaine de plugins de la configuration par défaut. Des schedulers sur mesure existent pourtant bel et bien, pour des besoins que le scheduler par défaut couvre mal, comme le placement groupé de tâches de calcul ; ils s'écrivent aujourd'hui presque toujours comme des plugins du cadre de la figure 37.1 plutôt que de zéro.

</details>

## Nettoyer

```bash
kill %1 2>/dev/null        # kubectl proxy, s'il tourne encore
kubectl delete namespace ch37
kubectl delete clusterrolebinding cours-ordonnanceur-serre cours-ordonnanceur-serre-volumes cours-lecture-metriques-ch37
kubectl delete clusterrole cours-lecture-metriques
kubectl -n kube-system delete rolebinding cours-ordonnanceur-serre
kubectl label node deux-noeuds-m02 disque-
kubectl config set-context --current --namespace=default
```

Le chapitre 38 se fait sur ce même cluster à deux nœuds : laissez-le tourner si vous enchaînez. Pour revenir au cluster principal :

```bash
minikube stop -p deux-noeuds
minikube start
kubectl apply -f metallb-plage.yaml
```

[^config]: Kubernetes, « Scheduler Configuration » : profils, plugins activés par défaut, points d'extension et `pluginConfig`. [kubernetes.io/docs/reference/scheduling/config](https://kubernetes.io/docs/reference/scheduling/config/)

[^perf]: Kubernetes, « Scheduler Performance Tuning », section *Percentage of Nodes to Score*. [kubernetes.io/docs/concepts/scheduling-eviction/scheduler-perf-tuning](https://kubernetes.io/docs/concepts/scheduling-eviction/scheduler-perf-tuning/)

[^cadre]: Kubernetes, « Scheduling Framework » : cycle d'ordonnancement, cycle de liaison et points d'extension. [kubernetes.io/docs/concepts/scheduling-eviction/scheduling-framework](https://kubernetes.io/docs/concepts/scheduling-eviction/scheduling-framework/)

[^plusieurs]: Kubernetes, « Configure Multiple Schedulers ». [kubernetes.io/docs/tasks/extend-kubernetes/configure-multiple-schedulers](https://kubernetes.io/docs/tasks/extend-kubernetes/configure-multiple-schedulers/)

[^repartition]: Kubernetes, « Pod Topology Spread Constraints », section *Cluster-level default constraints* : contraintes implicites sur `kubernetes.io/hostname` (écart 3) et `topology.kubernetes.io/zone` (écart 5), en `ScheduleAnyway`. [kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/)

[^indices]: Kubernetes Enhancement Proposal 4247, « Per-plugin callback functions for efficient requeueing in the scheduling queue » (QueueingHint), activé par défaut depuis Kubernetes 1.32. [github.com/kubernetes/enhancements/tree/master/keps/sig-scheduling/4247-queueinghint](https://github.com/kubernetes/enhancements/tree/master/keps/sig-scheduling/4247-queueinghint)

[^portes]: Kubernetes, « Pod Scheduling Readiness ». [kubernetes.io/docs/concepts/scheduling-eviction/pod-scheduling-readiness](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-scheduling-readiness/)
