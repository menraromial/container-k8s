---
title: La disponibilité
sidebar_label: 33. La disponibilité
description: "Mettre un nœud en maintenance sans couper le service : perturbations volontaires et involontaires, cordon et drain, l'API d'éviction, le PodDisruptionBudget mesuré sous charge, ses pièges (une réplique unique, des Pods malades), et ce qu'il ne protège pas."
partie: 4
chapitre: '33'
---

import drainEviction from '@site/src/figures/drain-eviction.svg';
import drainPdb from '@site/src/figures/drain-pdb.svg';

Un nœud doit être redémarré : une mise à jour du noyau, une nouvelle version de Kubernetes, un disque à changer. Il faut d'abord en faire partir les Pods, qui seront recréés ailleurs. Le chapitre 32 a montré comment les faire partir (un taint `NoExecute`), mais pas comment le faire **sans couper le service** : si les trois répliques d'une application tournent sur ce nœud, les évincer d'un coup, c'est une panne, aussi courte soit-elle. C'est pourtant ce que font la plupart des opérations de maintenance quand personne ne leur dit ce qu'une application peut supporter.

Kubernetes distingue deux sortes de perturbations[^perturbations]. Les **involontaires** : un nœud qui tombe, un noyau qui panique, un Pod tué pour manque de mémoire. On ne peut pas les empêcher ; on s'y prépare, avec des répliques réparties (chapitre 32). Les **volontaires** : vider un nœud pour le maintenir, supprimer un Pod pour le déplacer, réduire un cluster. Celles-là passent par une porte que l'on peut surveiller, l'**API d'éviction**, et un objet permet de dire combien de répliques d'une application doivent rester debout pendant qu'elles ont lieu : le **PodDisruptionBudget** (PDB).

Ce chapitre se fait sur le cluster à trois nœuds du chapitre 32, avec ses zones et son étiquette `disque=ssd` sur `m03`. Les manifestes sont dans [l'archive disponibilite](pathname:///kits/disponibilite.tar.gz).

```bash
kubectl create namespace ch33
kubectl config set-context --current --namespace=ch33
```

## Une vitrine sous surveillance

La vitrine est une petite application web de trois répliques, qui mettent 5 secondes à devenir prêtes. Elles préfèrent le nœud SSD, si bien qu'elles s'y retrouvent toutes les trois, comme au chapitre 32 : c'est le pire cas pour une maintenance, et il n'a rien d'exceptionnel. Un Pod client interroge la vitrine dix fois par seconde, et écrit chaque seconde le nombre de réussites et d'échecs :

```yaml title="client.yaml (extrait)"
    - |
      while true; do
        ok=0; ko=0
        for i in 1 2 3 4 5 6 7 8 9 10; do
          if wget -q -T 1 -O /dev/null http://vitrine/hostname; then ok=$((ok+1)); else ko=$((ko+1)); fi
          sleep 0.1
        done
        echo "$(date -u +%T) ok=$ok echecs=$ko"
      done
```

```bash
kubectl apply -f vitrine.yaml -f client.yaml
kubectl get pods -o custom-columns=POD:.metadata.name,NOEUD:.spec.nodeName,PRET:.status.containerStatuses[0].ready
kubectl logs client --tail=1
```

```sortie
POD                        NOEUD             PRET
client                     deux-noeuds-m02   true
vitrine-74857bd979-lm2mm   deux-noeuds-m03   true
vitrine-74857bd979-mncmk   deux-noeuds-m03   true
vitrine-74857bd979-xdz2z   deux-noeuds-m03   true
16:33:13 ok=10 echecs=0
```

## cordon et drain

Deux commandes préparent un nœud à la maintenance. `kubectl cordon` le marque **non planifiable** : le scheduler n'y place plus de nouveaux Pods (chapitre 32), mais ceux qui y tournent restent. `kubectl drain` fait un `cordon`, puis évince un à un les Pods du nœud, par l'API d'éviction, et attend qu'ils soient partis[^drain]. Deux options reviennent presque toujours : `--ignore-daemonsets`, parce que les Pods d'un DaemonSet n'ont pas d'autre nœud où aller (et seraient recréés aussitôt, chapitre 27), et `--delete-emptydir-data`, pour accepter de perdre le contenu des `emptyDir` (chapitre 25).

Vidons `m03`, sans autre précaution :

```bash
kubectl drain deux-noeuds-m03 --ignore-daemonsets --delete-emptydir-data
```

```sortie
node/deux-noeuds-m03 cordoned
evicting pod ch33/vitrine-74857bd979-xdz2z
evicting pod ch33/vitrine-74857bd979-lm2mm
evicting pod ch33/vitrine-74857bd979-mncmk
pod/vitrine-74857bd979-xdz2z evicted
pod/vitrine-74857bd979-lm2mm evicted
pod/vitrine-74857bd979-mncmk evicted
node/deux-noeuds-m03 drained
```

Quatre secondes, et le nœud est vide. Côté client, les lignes qui ne sont pas parfaites :

```bash
kubectl logs client --since=1m | grep -v '^wget' | grep -v 'echecs=0'
kubectl get events --field-selector reason=Pulled --sort-by=.lastTimestamp | grep vitrine | tail -2
```

```sortie
16:33:17 ok=9 echecs=1
16:33:27 ok=0 echecs=10
16:33:34 ok=4 echecs=6
11s         Normal   Pulled   pod/vitrine-74857bd979-vmbzq   Successfully pulled image "registry.k8s.io/e2e-test-images/agnhost:2.61" in 13.016s (13.016s including waiting). Image size: 5702...
11s         Normal   Pulled   pod/vitrine-74857bd979-z64bp   Successfully pulled image "registry.k8s.io/e2e-test-images/agnhost:2.61" in 1.066s (12.405s including waiting). Image size: 57024...
```

Dix-sept requêtes en échec, étalées sur une vingtaine de secondes (quand les requêtes échouent, chaque essai attend sa seconde de délai, et les lignes s'espacent). Les trois répliques ont été évincées en même temps, et leurs remplaçantes, placées sur les deux autres nœuds, ont dû tirer leur image, que ces nœuds n'avaient jamais vue : 13 secondes, puis 5 secondes de démarrage. Lors d'un premier essai, le tirage avait pris 25 secondes, et la coupure une trentaine. Rien d'anormal dans tout cela : le drain a fait exactement ce qu'on lui a demandé.

## Le PodDisruptionBudget

Un PDB dit, pour les Pods désignés par son sélecteur, combien doivent rester disponibles pendant les perturbations volontaires. Il s'exprime par un minimum (`minAvailable`) ou par un maximum d'absents (`maxUnavailable`), en nombre ou en pourcentage[^pdb] :

```yaml title="pdb.yaml"
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: vitrine
spec:
  minAvailable: 2
  selector:
    matchLabels: {app: vitrine}
```

Remettons `m03` en service, replaçons-y les trois répliques, et appliquons le PDB :

```bash
kubectl uncordon deux-noeuds-m03
kubectl rollout restart deploy/vitrine
kubectl apply -f pdb.yaml
kubectl get pdb vitrine
```

```sortie
NAME      MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
vitrine   2               N/A               1                     3s
```

`ALLOWED DISRUPTIONS` est calculé en permanence par un contrôleur : trois répliques prêtes, deux exigées, donc une perturbation permise. Le même drain :

```bash
kubectl drain deux-noeuds-m03 --ignore-daemonsets --delete-emptydir-data
```

```sortie
node/deux-noeuds-m03 cordoned
evicting pod ch33/vitrine-55bf8b4fb7-xzzjf
evicting pod ch33/vitrine-55bf8b4fb7-8q5j4
evicting pod ch33/vitrine-55bf8b4fb7-9n4cc
error when evicting pods/"vitrine-55bf8b4fb7-8q5j4" -n "ch33" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
error when evicting pods/"vitrine-55bf8b4fb7-9n4cc" -n "ch33" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
pod/vitrine-55bf8b4fb7-xzzjf evicted
evicting pod ch33/vitrine-55bf8b4fb7-8q5j4
...
pod/vitrine-55bf8b4fb7-8q5j4 evicted
...
pod/vitrine-55bf8b4fb7-9n4cc evicted
node/deux-noeuds-m03 drained
```

Le drain a demandé les trois évictions ; l'API server en a accepté une, et refusé les deux autres, en répondant que le budget serait dépassé. `kubectl drain` réessaie toutes les cinq secondes. Dès que la remplaçante de la première réplique est prête, le budget remonte à une perturbation, et la deuxième éviction passe ; puis la troisième. Le drain a pris 24 secondes au lieu de 4, et le client n'a vu **aucun** échec : jamais moins de deux répliques prêtes.

<Figure svg={drainEviction} num="33.1" alt="Ce que fait kubectl drain deux-noeuds-m03. 1, il marque le nœud unschedulable, comme cordon. 2, pour chaque Pod, il appelle l'API d'éviction, POST .../pods/nom/eviction. L'API server consulte le PodDisruptionBudget : disruptionsAllowed est-il supérieur à 0 ? Si oui, le Pod est supprimé, avec son délai de grâce et son preStop, et le contrôleur en recrée un ailleurs. Sinon, l'éviction est refusée avec le message Cannot evict pod as it would violate the pod's disruption budget, et drain réessaie toutes les 5 secondes. kubectl delete pod, la panne d'un nœud ou un OOM ne passent pas par cette porte : le PDB n'est pas consulté.">
Le PDB n'est pas un objet que le drain lit : c'est l'API server qui le consulte, à chaque demande d'éviction, quel que soit l'outil qui la fait.
</Figure>

<Figure svg={drainPdb} num="33.2" alt="Le même drain, deux fois. Sans PodDisruptionBudget, drain en 4 secondes : les trois répliques sont absentes en même temps pendant environ 18 secondes (image tirée en 13 secondes, démarrage en 5 secondes), et le client voit 17 requêtes en échec pendant environ 17 secondes. Avec minAvailable 2, drain en 24 secondes : les répliques sont remplacées l'une après l'autre, chaque remplaçante étant prête avant que la suivante parte ; le client ne voit aucune requête en échec, et il n'y a jamais moins de 2 répliques prêtes.">
Le même drain, sans et avec PDB. Schéma construit à partir des durées mesurées sur le cluster du cours ; au second essai, l'image était déjà sur les autres nœuds.
</Figure>

Le PDB n'est pas lu par `kubectl drain` en particulier : c'est l'API server qui l'applique à chaque demande d'éviction. Tous les outils qui passent par cette API le respectent donc : le *cluster autoscaler* qui retire des nœuds sous-utilisés, les mises à jour de nœuds des clusters gérés, les outils de rééquilibrage, et le scheduler lui-même quand il choisit des victimes à préempter (chapitre 32), dans la mesure du possible. C'est la raison d'être de l'objet : une application déclare une fois ce qu'elle supporte, et tous les outils de maintenance en tiennent compte.

### Ce que le PDB ne protège pas

Le PDB ne s'applique qu'aux évictions. Trois perturbations lui échappent. Les **pannes**, par définition : si `m03` avait perdu son alimentation, les trois répliques seraient tombées ensemble, PDB ou pas, et seule une meilleure répartition (chapitre 32) aurait aidé. La **suppression directe** d'un Pod, qui n'est pas une éviction : `kubectl delete pod` ne demande l'avis de personne, l'exemple de la réplique unique plus bas le montre. Et les **mises à jour d'un Deployment**, que le Deployment règle lui-même, avec `maxUnavailable` et `maxSurge` (chapitre 19). Un PDB qui n'autorise aucune perturbation ne bloque pas un `rollout` :

```bash
sed 's/minAvailable: 2/minAvailable: 3/' pdb.yaml | kubectl apply -f -
kubectl get pdb vitrine
kubectl rollout restart deploy/vitrine
kubectl rollout status deploy/vitrine
```

```sortie
NAME      MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
vitrine   3               N/A               0                     4s
deployment.apps/vitrine restarted
deployment "vitrine" successfully rolled out
```

La mise à jour a duré 17 secondes, sans se soucier du PDB. Les deux mécanismes se complètent : la stratégie de mise à jour protège pendant les déploiements, le PDB pendant les maintenances.

## Deux pièges

### Un PDB qui bloque tout

L'application `solo` n'a qu'une réplique, sur `m03`, et un PDB qui exige qu'elle reste disponible :

```yaml title="solo.yaml (extrait)"
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: solo
spec:
  minAvailable: 1
  selector:
    matchLabels: {app: solo}
```

```bash
kubectl get pdb solo
kubectl drain deux-noeuds-m03 --ignore-daemonsets --delete-emptydir-data
```

```sortie
NAME   MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
solo   1               N/A               0                     1s
node/deux-noeuds-m03 cordoned
evicting pod ch33/solo-5fb977c8f7-lsxlv
error when evicting pods/"solo-5fb977c8f7-lsxlv" -n "ch33" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
evicting pod ch33/solo-5fb977c8f7-lsxlv
...
```

Aucune perturbation n'est jamais permise : pour évincer la seule réplique, il faudrait qu'une autre soit prête, et il n'y en a pas d'autre. Le drain réessaie indéfiniment, et le nœud reste `SchedulingDisabled`. Avec `--timeout`, il abandonne proprement :

```sortie
error when evicting pods/"solo-5fb977c8f7-lsxlv" -n "ch33": global timeout reached: 15s
```

C'est l'une des causes les plus fréquentes de mises à jour de clusters gérés bloquées : un PDB posé par précaution sur une application à une réplique. La bonne réponse dépend de l'application. Si elle supporte une courte coupure, pas de PDB, ou `maxUnavailable: 1`. Sinon, il lui faut deux répliques, réparties sur deux nœuds. La tentation est de supprimer le Pod à la main, ce qui marche, puisque la suppression ne passe pas par l'API d'éviction :

```bash
kubectl delete pod solo-5fb977c8f7-lsxlv
kubectl get pods -l app=solo
```

```sortie
pod "solo-5fb977c8f7-lsxlv" deleted from ch33 namespace
NAME                    READY   STATUS    RESTARTS   AGE
solo-5fb977c8f7-zw6hp   0/1     Pending   0          4s
  Warning  FailedScheduling  4s    default-scheduler  0/3 nodes are available: 1 node(s) were unschedulable, 2 node(s) didn't match Pod's node affinity/selector. ...
```

Mais c'est exactement la coupure que le PDB voulait éviter, et ici elle dure : le remplaçant exige le SSD, et le seul nœud SSD est en maintenance. Il attendra le `kubectl uncordon`.

### Des Pods malades qui bloquent le drain

Le PDB compte les Pods **prêts**. Que se passe-t-il si les répliques ne le sont pas, par exemple après une mise à jour ratée ? Cassons la sonde readiness de la vitrine (elle interroge un port où rien n'écoute) :

```sortie
vitrine-56dcc9688b-nwn5h   deux-noeuds-m03   false
vitrine-56dcc9688b-prqdh   deux-noeuds-m03   false
vitrine-56dcc9688b-qr7lr   deux-noeuds-m03   false
NAME      MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
vitrine   2               N/A               0                     110s
```

Aucune réplique prête, donc zéro perturbation permise, et le drain est bloqué, alors que ces Pods ne servent à rien :

```sortie
error when evicting pods/"vitrine-56dcc9688b-qr7lr" -n "ch33" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
```

C'est le comportement par défaut, `unhealthyPodEvictionPolicy: IfHealthyBudget` : un Pod malade ne peut être évincé que si l'application a déjà assez de Pods sains. La politique `AlwaysAllow` permet d'évincer les Pods qui ne sont pas prêts, quel que soit le budget[^pdb] :

```bash
kubectl patch pdb vitrine --type merge -p '{"spec":{"unhealthyPodEvictionPolicy":"AlwaysAllow"}}'
kubectl drain deux-noeuds-m03 --ignore-daemonsets --timeout=60s
```

```sortie
poddisruptionbudget.policy/vitrine patched
pod/vitrine-56dcc9688b-qr7lr evicted
pod/vitrine-56dcc9688b-nwn5h evicted
pod/vitrine-56dcc9688b-prqdh evicted
node/deux-noeuds-m03 drained
```

Trois secondes. Pour la plupart des applications, `AlwaysAllow` est le bon réglage : protéger des Pods qui ne répondent pas n'apporte rien et bloque la maintenance. On garde `IfHealthyBudget` pour les applications dont un Pod pas encore prêt peut contenir des données précieuses, par exemple une base qui rattrape son retard de réplication.

## La maintenance d'un nœud, en résumé

```bash
kubectl drain <nœud> --ignore-daemonsets --delete-emptydir-data --timeout=10m
# ... redémarrage, mise à jour, changement de disque ...
kubectl uncordon <nœud>
```

Avant de lancer le drain, `kubectl get pdb -A` montre les budgets du cluster, et une colonne `ALLOWED DISRUPTIONS` à 0 annonce un blocage. Après l'`uncordon`, les Pods ne reviennent pas d'eux-mêmes sur le nœud : le scheduler n'y place que les nouveaux Pods. Pour rééquilibrer, on attend les prochains déploiements, ou on utilise un outil comme le *descheduler*, qui évince (par l'API d'éviction, donc en respectant les PDB) les Pods mal placés.

## Exercices

:::exercice[Exercice 1 : des budgets pour Colis]

Proposez un PDB pour chaque composant de Colis tel qu'il est à la fin du chapitre 31 : l'API (2 à 6 répliques, gérées par le HPA), le worker (0 à 5 répliques, gérées par KEDA), PostgreSQL (un StatefulSet d'une réplique), Redis (un Deployment d'une réplique), le site (2 répliques).

:::

<details>
<summary>Corrigé</summary>

- API : `maxUnavailable: 1`. Avec un nombre de répliques qui varie de 2 à 6, un maximum d'absents s'adapte mieux qu'un minimum fixe : `minAvailable: 2` bloquerait tout quand le HPA est à 2.
- Site : `maxUnavailable: 1`, pour la même raison, avec ses deux répliques ; un drain les remplace une par une.
- Worker : pas de PDB, ou `maxUnavailable: 100%`. Ses tâches sont dans la file Redis ; un worker évincé en pleine estimation laisse un colis non estimé, que le suivant reprendra. Et avec zéro réplique la plupart du temps, un PDB n'a rien à protéger.
- PostgreSQL et Redis : une seule réplique, donc le choix du piège ci-dessus. Un `minAvailable: 1` bloquerait toute maintenance du nœud qui les héberge. Tant qu'ils n'ont qu'une réplique, mieux vaut pas de PDB, en planifiant la maintenance de ce nœud à une heure creuse ; la vraie réponse est une base répliquée, avec un opérateur (chapitre 56), qui sait basculer le primaire avant l'éviction.

</details>

:::exercice[Exercice 2 : des pourcentages]

La vitrine a trois répliques. Combien de perturbations un PDB autorise-t-il avec `minAvailable: 50%` ? avec `maxUnavailable: 50%` ? avec `maxUnavailable: 34%` ? Prédisez, puis vérifiez.

:::

<details>
<summary>Corrigé</summary>

```sortie
minAvailable: 50% -> 2 répliques voulues, 1 perturbation(s) autorisée(s)
maxUnavailable: 50% -> 1 répliques voulues, 2 perturbation(s) autorisée(s)
maxUnavailable: 34% -> 1 répliques voulues, 2 perturbation(s) autorisée(s)
```

Kubernetes arrondit les pourcentages **vers le haut**, pour `minAvailable` comme pour `maxUnavailable`[^pdb]. 50 % de 3, c'est 1,5 : `minAvailable` exige 2 répliques (une perturbation permise), mais `maxUnavailable` en laisse partir 2. Et 34 % de 3, c'est 1,02, arrondi à 2 : on pensait autoriser une réplique absente, on en autorise deux. Avec peu de répliques, les pourcentages surprennent ; un nombre entier dit exactement ce qu'on veut. Les pourcentages ont leur intérêt quand le nombre de répliques varie beaucoup, avec un HPA par exemple, et de préférence avec `minAvailable`, dont l'arrondi est prudent.

</details>

:::exercice[Exercice 3 : une maintenance qui ne finit pas]

Un collègue lance `kubectl drain` sur un nœud avant de partir le soir. Le lendemain matin, la commande tourne toujours, et affiche en boucle `Cannot evict pod as it would violate the pod's disruption budget`. Comment trouver le coupable, et quelles sont les options ?

:::

<details>
<summary>Corrigé</summary>

Le message nomme le Pod ; `kubectl get pdb -A` montre les budgets, et celui qui le concerne a `ALLOWED DISRUPTIONS` à 0. Trois causes possibles, vues dans ce chapitre : une application à une seule réplique avec `minAvailable: 1` (ou `maxUnavailable: 0`) ; des Pods malades protégés par `IfHealthyBudget` ; ou des remplaçants qui ne deviennent jamais prêts, parce qu'ils ne trouvent pas de nœud (un sélecteur qui ne vise que le nœud en maintenance, comme `solo`, ou un cluster plein), ce que montrent les Pods `Pending` et leurs événements. Les options, de la plus propre à la plus brutale : corriger la cause (ajouter une réplique ailleurs, réparer les Pods malades, passer à `AlwaysAllow`) ; assouplir temporairement le PDB, en prévenant l'équipe propriétaire ; en dernier recours, `kubectl drain --disable-eviction`, qui supprime les Pods au lieu de les évincer, et contourne donc tous les PDB, en acceptant la coupure. Et pour éviter de découvrir le problème le lendemain : toujours un `--timeout` sur un drain lancé sans surveillance.

</details>

## Nettoyer

```bash
kubectl delete namespace ch33
kubectl uncordon deux-noeuds deux-noeuds-m02 deux-noeuds-m03
kubectl config set-context --current --namespace=default
```

La partie IV n'a plus besoin du cluster à trois nœuds. Pour retirer le troisième nœud, arrêter le profil et revenir au cluster principal :

```bash
minikube node delete m03 -p deux-noeuds
minikube stop -p deux-noeuds
minikube start
kubectl apply -f metallb-plage.yaml
```

[^perturbations]: Kubernetes, « Disruptions », sections *Voluntary and involuntary disruptions* et *Pod disruption budgets*. [kubernetes.io/docs/concepts/workloads/pods/disruptions](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/)

[^drain]: Kubernetes, « Safely Drain a Node », et « API-initiated Eviction ». [kubernetes.io/docs/tasks/administer-cluster/safely-drain-node](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/)

[^pdb]: Kubernetes, « Specifying a Disruption Budget for your Application », sections *Rounding logic when specifying percentages* et *Unhealthy Pod Eviction Policy*. [kubernetes.io/docs/tasks/run-application/configure-pdb](https://kubernetes.io/docs/tasks/run-application/configure-pdb/)
