---
title: ReplicaSet et Deployment
sidebar_label: 19. ReplicaSet et Deployment
description: "Maintenir des copies, changer de version sans interruption : le ReplicaSet et ses sélecteurs, le Deployment et ses révisions, la mise à jour progressive réglée par maxSurge et maxUnavailable, Recreate, les déploiements bloqués, l'historique et le retour arrière."
partie: 3
chapitre: '19'
---

import RollingUpdate from '@site/src/components/RollingUpdate';
import deploymentRs from '@site/src/figures/deployment-rs.svg';
import strategiesMaj from '@site/src/figures/strategies-maj.svg';

Mettre à jour une application qui ne doit jamais s'arrêter pose un problème simple à énoncer : il faut remplacer toutes les copies de l'ancienne version par des copies de la nouvelle, sans qu'il y ait un instant où aucune ne répond, et sans lancer tant de copies à la fois que les machines saturent. Et si la nouvelle version ne démarre pas, il faut s'en apercevoir avant d'avoir tout remplacé, puis revenir en arrière vite.

Avec Docker Compose, on arrêtait le conteneur et on relançait le nouveau : quelques secondes d'interruption. Kubernetes résout le problème avec deux objets emboîtés. Le **ReplicaSet** maintient un nombre donné de copies identiques d'un Pod ; le **Deployment** gère une succession de ReplicaSets, un par version, et passe progressivement de l'un à l'autre. Ce chapitre les fait travailler, mesure ce qui se passe pendant une mise à jour, et casse un déploiement pour apprendre à le réparer.

Les manifestes sont dans [l'archive deployments](pathname:///kits/deployments.tar.gz). Créez le namespace du chapitre :

```bash
kubectl create namespace ch19
kubectl config set-context --current --namespace=ch19
```

## Le ReplicaSet

Un ReplicaSet contient trois choses : un nombre de répliques, un **sélecteur**, et un **modèle** de Pod (`template`), qui a exactement la forme d'un Pod du chapitre 17 sans `apiVersion` ni `kind`[^rs] :

```yaml title="replicaset.yaml"
apiVersion: apps/v1
kind: ReplicaSet
metadata:
  name: copies
spec:
  replicas: 3
  selector:
    matchLabels:
      app: copies
  template:
    metadata:
      labels:
        app: copies
    spec:
      containers:
      - name: nginx
        image: nginx:1.30-alpine
```

Le sélecteur dit quels Pods le ReplicaSet considère comme les siens ; le modèle dit comment fabriquer ceux qui manquent. Les étiquettes du modèle doivent donc satisfaire le sélecteur, sans quoi l'API server refuse l'objet. Le chapitre 15 l'a laissé entendre : le ReplicaSet compte ses Pods par leurs étiquettes, et rien d'autre. Vérifions-le en créant d'abord, à la main, un Pod qui porte déjà la bonne étiquette :

```bash
kubectl run orpheline --image=nginx:1.30-alpine --labels=app=copies
kubectl apply -f replicaset.yaml
sleep 5
kubectl get pods -l app=copies -o custom-columns='NOM:.metadata.name,PROPRIETAIRE:.metadata.ownerReferences[0].name'
```

```sortie
pod/orpheline created
replicaset.apps/copies created
NOM            PROPRIETAIRE
copies-779kt   copies
copies-mqjxf   copies
orpheline      copies
```

Trois répliques demandées, et seulement deux Pods créés : le ReplicaSet a **adopté** le Pod `orpheline`, qui correspondait à son sélecteur et n'avait pas de propriétaire, et en a fait l'un des siens (son `ownerReferences` pointe désormais vers `copies`). Adopter un Pod construit à la main, avec une autre image peut-être, est rarement ce qu'on veut : c'est une raison de choisir des étiquettes précises, qu'aucun autre objet ne porte par hasard.

Changeons maintenant l'image dans le modèle du ReplicaSet :

```bash
kubectl patch rs copies --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/image","value":"nginx:1.29-alpine"}]'
sleep 3
kubectl get pods -l app=copies -o custom-columns='NOM:.metadata.name,IMAGE:.spec.containers[0].image'
```

```sortie
replicaset.apps/copies patched
NOM            IMAGE
copies-779kt   nginx:1.30-alpine
copies-mqjxf   nginx:1.30-alpine
orpheline      nginx:1.30-alpine
```

Rien n'a changé. Le modèle ne sert qu'à fabriquer les Pods manquants ; les trois Pods existants sont en règle aux yeux du ReplicaSet, puisqu'ils sont trois et portent la bonne étiquette. Il faudrait les supprimer un par un pour qu'ils soient recréés avec la nouvelle image, et c'est justement ce travail que fait un Deployment. En pratique, on ne crée jamais de ReplicaSet directement. Supprimez-le : `kubectl delete rs copies`.

## Le Deployment

Un Deployment a les mêmes trois champs qu'un ReplicaSet, plus une **stratégie** de mise à jour et quelques réglages[^deploy] :

```yaml title="vitrine.yaml"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vitrine
  labels:
    app.kubernetes.io/name: vitrine
spec:
  replicas: 4
  minReadySeconds: 5
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app.kubernetes.io/name: vitrine
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 25%
  template:
    metadata:
      labels:
        app.kubernetes.io/name: vitrine
    spec:
      containers:
      - name: nginx
        image: nginx:1.29-alpine
```

`minReadySeconds: 5` demande qu'un nouveau Pod reste prêt cinq secondes avant d'être compté comme **disponible**. Sans ce délai, nginx serait disponible en une fraction de seconde et la mise à jour serait trop rapide pour qu'on la suive ; dans la vraie vie, il évite de considérer comme bon un Pod qui plante dix secondes après son démarrage. `revisionHistoryLimit` dit combien d'anciens ReplicaSets garder (10 par défaut). La stratégie reprend les valeurs par défaut, que nous allons faire varier.

```bash
kubectl apply -f vitrine.yaml
kubectl rollout status deployment/vitrine
kubectl get deployment,rs,pods
```

```sortie
deployment.apps/vitrine created
...
deployment "vitrine" successfully rolled out
NAME                      READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/vitrine   4/4     4            4           6s

NAME                                 DESIRED   CURRENT   READY   AGE
replicaset.apps/vitrine-7c56cd65dc   4         4         4       6s

NAME                           READY   STATUS    RESTARTS   AGE
pod/vitrine-7c56cd65dc-dl8f8   1/1     Running   0          6s
pod/vitrine-7c56cd65dc-gltnx   1/1     Running   0          6s
pod/vitrine-7c56cd65dc-hcncb   1/1     Running   0          6s
pod/vitrine-7c56cd65dc-knntq   1/1     Running   0          6s
```

Les colonnes du Deployment se lisent ainsi : `READY` compte les Pods prêts sur le nombre voulu, `UP-TO-DATE` ceux qui ont la version courante du modèle, `AVAILABLE` ceux qui sont disponibles au sens de `minReadySeconds`. Le ReplicaSet porte un suffixe, `7c56cd65dc`, que ses Pods reprennent : c'est l'empreinte du modèle de Pod (`pod-template-hash`), ajoutée aussi comme étiquette à chaque Pod pour que les ReplicaSets de versions différentes ne se disputent jamais les mêmes Pods.

## La mise à jour progressive

Passons à la version suivante de nginx, en suivant les ReplicaSets pendant la mise à jour. Le script `suivre.sh` du kit (rendez-le exécutable avec `chmod +x suivre.sh`) affiche, à chaque changement, pour chaque ReplicaSet, son image puis trois nombres : Pods voulus, prêts, disponibles.

```bash
kubectl set image deployment/vitrine nginx=nginx:1.30-alpine
./suivre.sh 45
```

```sortie
deployment.apps/vitrine image updated
t=  0.1 s : 1.29=3/3/3  1.30=2//
t=  0.9 s : 1.29=3/3/3  1.30=2/2/
t=  4.9 s : 1.29=1/1/1  1.30=4/2/2
t=  5.7 s : 1.29=1/1/1  1.30=4/4/2
t= 10.1 s : 1.29=0//  1.30=4/4/4
```

Le Deployment a créé un second ReplicaSet pour la version 1.30, puis a fait grandir l'un pendant que l'autre rétrécissait, en respectant deux bornes, calculées à partir des quatre répliques :

- **`maxSurge: 25%`** : au plus 25 % de Pods en plus des répliques voulues, arrondi au-dessus, soit 1. Il n'y aura jamais plus de 5 Pods en même temps ;
- **`maxUnavailable: 25%`** : au plus 25 % des répliques indisponibles, arrondi au-dessous, soit 1. Il y aura toujours au moins 3 Pods disponibles.

Dès le départ, le contrôleur crée un nouveau Pod (5 au total, la limite) et supprime un ancien (il en reste 3 disponibles, le minimum). Il recommence aussitôt : un deuxième nouveau Pod, puisqu'on est retombé à 4. Il ne peut plus rien supprimer, car les nouveaux ne sont pas encore disponibles. À 4,9 secondes, les deux premiers le deviennent : le contrôleur supprime deux anciens et crée les deux derniers nouveaux. À 10,1 secondes, tout est remplacé. Les anciens Pods ne sont jamais descendus sous 3 disponibles, et le total n'a jamais dépassé 5.

L'ancien ReplicaSet n'a pas disparu :

```bash
kubectl get rs -o wide
kubectl rollout history deployment/vitrine
```

```sortie
NAME                 DESIRED   CURRENT   READY   AGE   CONTAINERS   IMAGES              SELECTOR
vitrine-7c56cd65dc   0         0         0       51s   nginx        nginx:1.29-alpine   app.kubernetes.io/name=vitrine,pod-template-hash=7c56cd65dc
vitrine-7dfc8c89b5   4         4         4       45s   nginx        nginx:1.30-alpine   app.kubernetes.io/name=vitrine,pod-template-hash=7dfc8c89b5
deployment.apps/vitrine
REVISION  CHANGE-CAUSE
1         <none>
2         <none>
```

Il est gardé à zéro réplique, avec son modèle : c'est la **révision** 1, prête à resservir pour un retour arrière. Chaque changement du **modèle de Pod** crée une révision ; un changement du nombre de répliques n'en crée pas, car il ne touche pas au modèle (`kubectl scale` ne fait que modifier le ReplicaSet courant).

<Figure svg={deploymentRs} num="19.1" alt="Le Deployment vitrine, avec replicas 4, une stratégie et un modèle de Pod en image nginx:1.30-alpine, possède trois ReplicaSets. Le ReplicaSet 7c56cd65dc, révision précédente en nginx:1.29-alpine, a zéro réplique et est conservé pour rollout undo. Le ReplicaSet 7dfc8c89b5, révision courante en nginx:1.30-alpine, a quatre répliques et quatre Pods. Le ReplicaSet f77b5ccc4, tentative ratée en nginx:9.99-alpine, a zéro réplique et est conservé lui aussi, selon revisionHistoryLimit. Le suffixe des noms est une empreinte du modèle de Pod.">
Un Deployment et ses ReplicaSets, un par version du modèle de Pod, tels qu'on les trouve à la fin de ce chapitre.
</Figure>

### Régler maxSurge et maxUnavailable

Les deux bornes traduisent un compromis entre la vitesse, la capacité et le coût. Essayons deux réglages extrêmes. D'abord `maxSurge: 0` et `maxUnavailable: 1` : jamais un Pod de plus, un seul Pod en moins. C'est le réglage des clusters sans capacité de réserve :

```bash
kubectl patch deployment vitrine -p '{"spec":{"strategy":{"rollingUpdate":{"maxSurge":0,"maxUnavailable":1}}}}'
kubectl set image deployment/vitrine nginx=nginx:1.29-alpine
./suivre.sh 60
```

```sortie
deployment.apps/vitrine image updated
t=  0.1 s : 1.29=1//  1.30=3/3/3
t=  0.9 s : 1.29=1/1/  1.30=3/3/3
t=  5.7 s : 1.29=2/1/1  1.30=2/2/2
t=  6.5 s : 1.29=2/2/1  1.30=2/2/2
t= 10.6 s : 1.29=3/2/2  1.30=1/1/1
t= 11.4 s : 1.29=3/3/2  1.30=1/1/1
t= 15.8 s : 1.29=4/3/3  1.30=0//
t= 16.6 s : 1.29=4/4/3  1.30=0//
t= 20.6 s : 1.29=4/4/4  1.30=0//
```

(Retour à 1.29 : le Deployment a **réutilisé** l'ancien ReplicaSet, dont le modèle correspondait.) Un Pod à la fois : supprimer un ancien, attendre que son remplaçant soit disponible, recommencer. Le total ne dépasse jamais 4, mais la mise à jour prend deux fois plus de temps, et le service fonctionne pendant 20 secondes avec trois copies sur quatre.

À l'autre extrême, `maxSurge: 100%` et `maxUnavailable: 0` : toute la nouvelle version en plus de l'ancienne, et aucune perte de capacité :

```bash
kubectl patch deployment vitrine -p '{"spec":{"strategy":{"rollingUpdate":{"maxSurge":"100%","maxUnavailable":0}}}}'
kubectl set image deployment/vitrine nginx=nginx:1.30-alpine
./suivre.sh 30
```

```sortie
deployment.apps/vitrine image updated
t=  0.1 s : 1.29=4/4/4  1.30=4//
t=  0.9 s : 1.29=4/4/4  1.30=4/4/
t=  5.7 s : 1.29=0/4/4  1.30=4/4/4
t=  6.1 s : 1.29=0//  1.30=4/4/4
```

Huit Pods pendant cinq secondes, puis la bascule d'un coup. C'est le plus rapide et le plus sûr pour la disponibilité, et le plus coûteux : il faut de quoi faire tourner deux fois l'application. Ce motif ressemble au déploiement « bleu-vert », que le chapitre 58 fera proprement avec Argo Rollouts.

<Figure svg={strategiesMaj} num="19.2" alt="Trois séquences mesurées sur quatre répliques. Avec maxSurge 25 % et maxUnavailable 25 % : avant, quatre anciens ; à 0,1 s, trois anciens et deux nouveaux en attente ; à 4,9 s, un ancien, deux nouveaux disponibles et deux en attente ; à 10,1 s, quatre nouveaux. Avec maxSurge 0 et maxUnavailable 1 : un Pod remplacé à la fois, de 0,1 à 20,6 secondes. Avec maxSurge 100 % et maxUnavailable 0 : quatre nouveaux en plus des quatre anciens à 0,1 s, puis quatre nouveaux seuls à 6,1 s.">
Trois réglages de la mise à jour progressive, mesurés sur minikube avec quatre répliques et <code>minReadySeconds: 5</code>.
</Figure>

Le composant ci-dessous rejoue la logique du contrôleur pour n'importe quel réglage. Il suppose que tous les Pods créés ensemble deviennent disponibles ensemble ; sur un vrai cluster, ils arrivent en ordre dispersé, ce qui ajoute parfois des étapes intermédiaires (exercice 2). Essayez 10 répliques, ou `maxSurge: 0` avec `maxUnavailable: 0` :

<RollingUpdate />

### Recreate

La seconde stratégie, `Recreate`, supprime tous les anciens Pods avant de créer les nouveaux :

```bash
kubectl patch deployment vitrine --type=json -p '[{"op":"remove","path":"/spec/strategy/rollingUpdate"},{"op":"replace","path":"/spec/strategy/type","value":"Recreate"}]'
kubectl set image deployment/vitrine nginx=nginx:1.29-alpine
./suivre.sh 30
```

```sortie
deployment.apps/vitrine image updated
t=  0.1 s : 1.29=0//  1.30=0//
t=  0.5 s : 1.29=4//  1.30=0//
t=  1.3 s : 1.29=4/4/  1.30=0//
t=  5.7 s : 1.29=4/4/4  1.30=0//
```

À 0,1 seconde, les deux ReplicaSets sont à zéro : aucun Pod n'existe. Pendant plus d'une seconde, aucun n'est prêt, et pendant plus de cinq aucun n'est disponible : c'est une interruption de service, courte ici parce que nginx démarre vite. Pourquoi choisir `Recreate` ? Quand deux versions ne peuvent pas tourner en même temps : une application qui modifie le schéma de sa base de données au démarrage, ou un volume qui ne peut être monté que par un seul Pod à la fois (chapitre 25).

## Historique et retour arrière

Chaque révision peut porter une explication dans l'annotation `kubernetes.io/change-cause`, que `rollout history` affiche :

```bash
kubectl annotate deployment vitrine kubernetes.io/change-cause='retour en 1.29, stratégie Recreate'
kubectl rollout history deployment/vitrine
```

```sortie
deployment.apps/vitrine
REVISION  CHANGE-CAUSE
4         <none>
5         retour en 1.29, stratégie Recreate
```

Les révisions 1 à 3 ont disparu de la liste. Nous avons alterné entre deux modèles seulement (nginx 1.29 et 1.30) : à chaque retour à un modèle déjà connu, le Deployment a réutilisé son ReplicaSet et lui a donné le numéro de révision suivant. La liste contient une ligne par ReplicaSet conservé, avec son dernier numéro. `kubectl rollout undo` revient à la révision précédente :

```bash
kubectl rollout undo deployment/vitrine
kubectl rollout status deployment/vitrine
kubectl get deployment vitrine -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl rollout history deployment/vitrine
```

```sortie
Warning: resource deployments/vitrine was previously managed with 'kubectl apply'. Rolling back will not update the kubectl.kubernetes.io/last-applied-configuration annotation, which may cause unexpected behavior on future 'kubectl apply' calls.
deployment.apps/vitrine rolled back
...
deployment "vitrine" successfully rolled out
nginx:1.30-alpine
deployment.apps/vitrine
REVISION  CHANGE-CAUSE
5         retour en 1.29, stratégie Recreate
6         <none>
```

Un retour arrière n'est pas un voyage dans le temps : c'est une nouvelle révision, la 6, dont le modèle est celui de la 4. L'avertissement rappelle le chapitre 18 : `undo` modifie l'objet sans passer par le fichier, et le prochain `kubectl apply` remettra ce que dit le fichier. En production, on revient donc en arrière en urgence avec `undo`, puis on corrige le fichier dans Git.

### Un déploiement bloqué

Que se passe-t-il si la nouvelle version ne démarre jamais ? Revenons à une mise à jour progressive (un Pod en plus, un en moins), réduisons le délai de progression à 30 secondes, et demandons une image qui n'existe pas :

```bash
kubectl patch deployment vitrine --type=merge -p '{"spec":{"progressDeadlineSeconds":30,"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":1,"maxUnavailable":1}}}}'
kubectl set image deployment/vitrine nginx=nginx:9.99-alpine
kubectl rollout status deployment/vitrine --timeout=90s; echo code=$?
kubectl get deployment vitrine
kubectl get rs
kubectl get pods
kubectl get deployment vitrine -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
```

```sortie
deployment.apps/vitrine image updated
Waiting for deployment spec update to be observed...
Waiting for deployment "vitrine" rollout to finish: 1 out of 4 new replicas have been updated...
Waiting for deployment "vitrine" rollout to finish: 2 out of 4 new replicas have been updated...
error: deployment "vitrine" exceeded its progress deadline
code=1
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
vitrine   3/4     2            3           3m28s
NAME                 DESIRED   CURRENT   READY   AGE
vitrine-7c56cd65dc   0         0         0       3m28s
vitrine-7dfc8c89b5   3         3         3       3m22s
vitrine-f77b5ccc4    2         2         0       31s
NAME                       READY   STATUS         RESTARTS   AGE
vitrine-7dfc8c89b5-2lcxf   1/1     Running        0          37s
vitrine-7dfc8c89b5-42xvk   1/1     Running        0          37s
vitrine-7dfc8c89b5-pfhx9   1/1     Running        0          37s
vitrine-f77b5ccc4-8jdt9    0/1     ErrImagePull   0          31s
vitrine-f77b5ccc4-gzs7c    0/1     ErrImagePull   0          31s
Available=True MinimumReplicasAvailable: Deployment has minimum availability.
Progressing=False ProgressDeadlineExceeded: ReplicaSet "vitrine-f77b5ccc4" has timed out progressing.
```

La mise à jour s'est arrêtée d'elle-même : deux nouveaux Pods en `ErrImagePull`, et trois anciens qui continuent à servir. `maxUnavailable: 1` a protégé l'application : le contrôleur ne supprimera pas un ancien Pod de plus tant que les nouveaux ne sont pas disponibles, et ils ne le seront jamais. Au bout de `progressDeadlineSeconds` (600 secondes par défaut, 30 ici), la condition `Progressing` passe à `False` avec la raison `ProgressDeadlineExceeded`, et `kubectl rollout status` sort avec le code 1 : c'est ce signal qu'une chaîne de livraison surveille pour déclarer un déploiement raté. Kubernetes ne revient pas en arrière de lui-même ; il faut le demander :

```bash
kubectl rollout undo deployment/vitrine
kubectl rollout status deployment/vitrine
kubectl get pods
```

```sortie
deployment.apps/vitrine rolled back
...
deployment "vitrine" successfully rolled out
NAME                       READY   STATUS    RESTARTS   AGE
vitrine-7dfc8c89b5-2lcxf   1/1     Running   0          43s
vitrine-7dfc8c89b5-42xvk   1/1     Running   0          43s
vitrine-7dfc8c89b5-frm8n   1/1     Running   0          6s
vitrine-7dfc8c89b5-pfhx9   1/1     Running   0          43s
```

Les Pods en erreur ont disparu, et le quatrième Pod de la bonne version est revenu.

:::panne[exceeded its progress deadline]

`kubectl rollout status` sort en erreur, et `kubectl get deployment` montre `UP-TO-DATE` bloqué sous le nombre de répliques. La cause est presque toujours dans les nouveaux Pods : `kubectl get pods` les montre en `ErrImagePull`, `CrashLoopBackOff` ou `Pending`, et le chapitre 17 donne la méthode pour chacun. Le délai lui-même n'arrête rien : les anciens Pods continuent de tourner, et le Deployment continue d'essayer. Après correction, un nouveau `kubectl set image` ou `kubectl apply` relance la progression ; `kubectl rollout undo` revient à la version précédente.

:::

### Regrouper des changements

Chaque modification du modèle déclenche une mise à jour. Pour en faire plusieurs à la fois, on met le Deployment en pause :

```bash
kubectl rollout pause deployment/vitrine
kubectl set image deployment/vitrine nginx=nginx:1.29-alpine
kubectl set env deployment/vitrine MESSAGE=bonjour
kubectl get rs
kubectl rollout resume deployment/vitrine
kubectl rollout status deployment/vitrine
kubectl rollout history deployment/vitrine --revision=10
```

```sortie
deployment.apps/vitrine paused
deployment.apps/vitrine image updated
deployment.apps/vitrine env updated
NAME                 DESIRED   CURRENT   READY   AGE
vitrine-7c56cd65dc   0         0         0       3m39s
vitrine-7dfc8c89b5   4         4         4       3m33s
vitrine-f77b5ccc4    0         0         0       42s
deployment.apps/vitrine resumed
...
deployment "vitrine" successfully rolled out
deployment.apps/vitrine with revision #10
Pod Template:
  Labels:	app.kubernetes.io/name=vitrine
	pod-template-hash=79597b576c
  Containers:
   nginx:
    Image:	nginx:1.29-alpine
...
    Environment:
      MESSAGE:	bonjour
```

Pendant la pause, les deux modifications sont enregistrées sans rien lancer ; à la reprise, un seul ReplicaSet porte les deux, en une seule mise à jour. Enfin, `kubectl rollout restart` relance tous les Pods sans rien changer d'autre, en ajoutant au modèle une annotation datée (`kubectl.kubernetes.io/restartedAt`) : c'est la manière propre de redémarrer une application, par exemple pour qu'elle relise un fichier de configuration (chapitre 21).

:::panne[spec.selector: Invalid value ... field is immutable]

On ne peut pas changer le sélecteur d'un Deployment existant, même en changeant les étiquettes du modèle en même temps :

```sortie
The Deployment "vitrine" is invalid: spec.selector: Invalid value: {"matchLabels":{"app.kubernetes.io/name":"autre"}}: field is immutable
```

Un nouveau sélecteur laisserait les anciens ReplicaSets et leurs Pods sans propriétaire reconnaissable. Pour changer d'étiquettes, il faut créer un nouveau Deployment (sous un autre nom), le laisser démarrer, puis supprimer l'ancien. D'où l'intérêt de bien choisir ses étiquettes dès le départ (chapitre 18).

:::

## Exercices

:::exercice[Exercice 1 : revenir à une révision précise]

Créez un Deployment `revs` en nginx 1.28, puis mettez-le à jour en 1.29, puis en 1.30, en notant chaque version dans l'annotation `kubernetes.io/change-cause`. Revenez directement à la version 1.28. Que devient le numéro de la révision 1 ? Et son explication ?

:::

<details>
<summary>Corrigé</summary>

```bash
kubectl create deployment revs --image=nginx:1.28-alpine
kubectl annotate deployment revs kubernetes.io/change-cause="version 1.28"
for v in 1.29 1.30; do
  kubectl set image deployment/revs nginx=nginx:$v-alpine
  kubectl annotate deployment revs kubernetes.io/change-cause="version $v" --overwrite
  kubectl rollout status deployment/revs
done
kubectl rollout history deployment/revs
kubectl rollout undo deployment/revs --to-revision=1
kubectl get deployment revs -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl rollout history deployment/revs
```

```sortie
deployment.apps/revs
REVISION  CHANGE-CAUSE
1         version 1.28
2         version 1.29
3         version 1.30

deployment.apps/revs rolled back
nginx:1.28-alpine
deployment.apps/revs
REVISION  CHANGE-CAUSE
2         version 1.29
3         version 1.30
4         version 1.28
```

`--to-revision=1` réutilise le ReplicaSet de la révision 1, qui devient la révision 4 : le numéro 1 disparaît. L'explication suit, parce que l'annotation `change-cause` est recopiée sur chaque ReplicaSet au moment de sa révision, et que le Deployment la reprend du ReplicaSet réutilisé. Retenez qu'un numéro de révision désigne une position dans l'historique, pas une version : pour savoir ce qu'il contient, `kubectl rollout history --revision=N` affiche son modèle.

</details>

:::exercice[Exercice 2 : prévoir, puis mesurer]

Avec le composant du chapitre, prévoyez la séquence d'une mise à jour de 10 répliques avec `maxSurge: 3` et `maxUnavailable: 2`. Puis faites-la pour de vrai avec `vitrine.yaml` modifié et `suivre.sh`. Les deux séquences sont-elles identiques ?

:::

<details>
<summary>Corrigé</summary>

Le composant prévoit : au départ, 8 anciens et 5 nouveaux (13 Pods au plus, 8 disponibles au moins) ; quand les 5 nouveaux sont disponibles, 3 anciens et 10 nouveaux ; puis 0 ancien. Sur minikube, en partant de nginx 1.30 vers 1.29 :

```sortie
t=  0.1 s : 1.29=3//  1.30=8/10/10
t=  0.5 s : 1.29=5//  1.30=8/8/8
t=  0.9 s : 1.29=5/1/  1.30=8/8/8
t=  1.3 s : 1.29=5/5/  1.30=8/8/8
t=  5.7 s : 1.29=10/5/5  1.30=3/3/3
t=  6.5 s : 1.29=10/6/5  1.30=3/3/3
t=  6.9 s : 1.29=10/10/5  1.30=3/3/3
t= 10.9 s : 1.29=10/10/7  1.30=1/1/1
t= 11.7 s : 1.29=10/10/10  1.30=0//
```

Les grandes étapes sont celles du composant (8 et 5, puis 3 et 10, puis 0 et 10), avec deux différences. Au tout début, on surprend le contrôleur en pleine action : 3 nouveaux Pods créés, puis 5, les deux décisions arrivant à quelques dixièmes de seconde d'écart. Vers la fin, deux des cinq derniers Pods deviennent disponibles avant les trois autres : 7 disponibles, ce qui permet de supprimer 2 anciens de plus (il en reste 1), avant que les trois derniers arrivent. Le contrôleur ne raisonne pas par étapes : il réagit à chaque changement, et la séquence réelle dépend de l'ordre d'arrivée des Pods.

</details>

:::exercice[Exercice 3 : choisir une stratégie]

Pour chacune des applications suivantes, quelle stratégie et quels réglages choisiriez-vous ? L'API de Colis, qui tourne en 3 répliques sur un cluster presque plein ; un service de paiement critique, sur un cluster qui a de la réserve ; une application qui migre le schéma de sa base de données au démarrage et ne supporte pas que deux versions tournent ensemble.

:::

<details>
<summary>Corrigé</summary>

Pour l'API de Colis sur un cluster plein, `maxSurge: 0` et `maxUnavailable: 1` : aucun Pod supplémentaire à placer, un seul Pod en moins à la fois, donc deux copies sur trois pendant la mise à jour. Pour le paiement, `maxSurge` élevé (jusqu'à 100 %) et `maxUnavailable: 0` : la capacité ne baisse jamais, et la bascule est rapide ; on y ajoutera un `minReadySeconds` et des sondes de santé (chapitre 22), sans lesquelles « disponible » ne veut pas dire grand-chose. Pour l'application qui migre sa base, `Recreate`, en acceptant une courte interruption, ou mieux, une migration faite par un Job avant le déploiement (chapitre 27) et un code capable de tourner sur l'ancien et le nouveau schéma, ce qui permet de revenir à une mise à jour progressive.

</details>

## Nettoyer

```bash
kubectl delete namespace ch19
kubectl config set-context --current --namespace=default
```

[^rs]: Kubernetes, « ReplicaSet », sections *How a ReplicaSet works* et *Non-Template Pod acquisitions*. [kubernetes.io/docs/concepts/workloads/controllers/replicaset](https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/)

[^deploy]: Kubernetes, « Deployments », sections *Rolling Update Deployment* (arrondis de `maxSurge` et `maxUnavailable`), *Rolling Back a Deployment*, *Pausing and Resuming*, *Progress Deadline Seconds* et *Revision History Limit*. [kubernetes.io/docs/concepts/workloads/controllers/deployment](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/)
