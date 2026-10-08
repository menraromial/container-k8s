---
title: Catalogue de pannes
sidebar_label: 49. Catalogue de pannes
description: "Treize pannes courantes, reproduites puis corrigées une à une : Pending (ressources, sélecteur, volume), ContainerCreating, ImagePullBackOff, CreateContainerConfigError, OOMKilled, CrashLoopBackOff avec un code 0, sonde de vie impatiente, sonde de disponibilité fausse, DNS coupé, finaliseur bloqué. Pour chacune, la signature exacte à reconnaître, et un arbre de diagnostic interactif."
partie: 7
chapitre: '49'
---

import pannesEtapes from '@site/src/figures/pannes-etapes.svg';
import ArbreDiagnostic from '@site/src/components/ArbreDiagnostic';

Treize Pods, treize façons de ne pas marcher :

```bash
kubectl apply -f 00-namespace.yaml && kubectl apply -f .
kubectl -n ch49 get pods
```

```sortie
NAME                              READY   STATUS                       RESTARTS      AGE
cle-manquante                     0/1     CreateContainerConfigError   0             102s
client                            1/1     Running                      0             101s
configmap-absente                 0/1     ContainerCreating            0             101s
etiquette-absente                 0/1     ImagePullBackOff             0             102s
mauvais-noeud                     0/1     Pending                      0             102s
memoire-7797c58cb4-bnnwm          0/1     OOMKilled                    3 (80s ago)   101s
pas-prete-7b66ffdfd4-l5b2m        0/1     Running                      0             101s
pas-prete-7b66ffdfd4-x62dk        0/1     Running                      0             101s
registre-injoignable              0/1     ImagePullBackOff             0             102s
tache-finie-c9cc4789-9hg6m        0/1     Completed                    4 (62s ago)   101s
trop-gourmand                     0/1     Pending                      0             102s
vie-impatiente-869bcc8945-wflfw   0/1     CrashLoopBackOff             4 (6s ago)    101s
volume-introuvable                0/1     Pending                      0             102s
```

Chacun reproduit une panne que vous rencontrerez tôt ou tard, sur ce cluster ou ailleurs. Prises une à une, elles n'ont rien de mystérieux. Ce qui les rend pénibles, c'est qu'on les découvre en général un vendredi soir, sous une forme moins nette, et sans savoir laquelle on a sous les yeux. Ce chapitre les passe en revue avec la même grille : la reproduire, observer ce que Kubernetes en dit, retenir la **signature** (le message exact qui permet de la reconnaître la prochaine fois), corriger, vérifier. Les manifestes sont dans [l'archive pannes](pathname:///kits/pannes.tar.gz), numérotés comme dans le texte.

La colonne `STATUS` dit à quelle étape de sa vie chaque Pod s'est arrêté. La figure 49.1 range les treize pannes selon cette étape, et c'est aussi l'ordre du chapitre.

<Figure svg={pannesEtapes} num="49.1" alt="Huit étapes en deux rangées, chacune avec le composant responsable, ce qu'affiche STATUS et les pannes qui l'y bloquent. 1, placement, par le scheduler, Pending : requests trop grosses, nodeSelector sans nœud, PVC non liée. 2, volumes, par le kubelet, ContainerCreating : ConfigMap absente. 3, image, par le kubelet et le runtime, ErrImagePull et ImagePullBackOff : étiquette inexistante, registre injoignable. 4, configuration, par le kubelet, CreateContainerConfigError : clé absente du Secret. 5, exécution, par le runtime, le noyau et le kubelet, Running puis CrashLoopBackOff : limite de mémoire, programme qui se termine, sonde de vie impatiente. 6, disponibilité, par le kubelet et les EndpointSlices, Running READY 0/1 : sonde de disponibilité fausse. 7, service rendu, par l'application, Running READY 1/1 : DNS bloqué par une NetworkPolicy. 8, suppression, par les contrôleurs, Terminating : finaliseur jamais retiré.">
Les étapes de la vie d'un Pod, ce que <code>STATUS</code> affiche à chacune, et les pannes du chapitre qui l'y arrêtent. Plus l'étape est tardive, moins Kubernetes peut vous aider.
</Figure>

La dernière phrase de la légende résume le chapitre. Une panne de placement produit un message très clair, rédigé par le scheduler. Une panne d'application, à l'étape 7, ne produit rien du tout côté Kubernetes : le Pod est `Running`, prêt, sans redémarrage, et il ne rend pas le service.

## Le Pod n'est pas placé

Un Pod `Pending` n'a pas encore de nœud. Tant que c'est le cas, le kubelet n'en a jamais entendu parler : la seule source d'information est le scheduler, qui l'écrit à deux endroits, la condition `PodScheduled` du Pod et un événement `FailedScheduling`.

### 1. Des requests trop grosses

```bash
kubectl -n ch49 get pod trop-gourmand -o jsonpath='{.status.conditions[0]}' | jq -c '{type, status, reason, message}'
kubectl -n ch49 events --for pod/trop-gourmand
```

```sortie
{"type":"PodScheduled","status":"False","reason":"Unschedulable","message":"0/1 nodes are available: 1 Insufficient memory. preemption: 0/1 nodes are available: 1 Preemption is not helpful for scheduling."}
LAST SEEN   TYPE      REASON             OBJECT              MESSAGE
102s        Warning   FailedScheduling   Pod/trop-gourmand   0/1 nodes are available: 1 Insufficient memory. preemption: 0/1 nodes are available: 1 Preemption is not helpful for scheduling.
```

**Signature : `Insufficient memory`** (ou `cpu`). Le message se lit en deux temps. `0/1 nodes are available: 1 Insufficient memory` : sur un nœud, aucun ne convient, et voici pourquoi. `preemption: … not helpful` : le scheduler a aussi cherché s'il pouvait faire de la place en évinçant des Pods de priorité plus basse (chapitre 32), sans succès. Sur un cluster de cinquante nœuds, le message compte les nœuds par raison : `3 Insufficient cpu, 47 node(s) didn't match…`, ce qui suffit souvent à comprendre.

Le scheduler compare les **requests** à ce que le nœud annonce comme allouable, moins les requests des Pods déjà placés. Il ne regarde jamais la consommation réelle[^ordonnancement] :

```bash
kubectl get node minikube -o json | jq -c '{capacite: .status.capacity | {cpu, memory, pods}, allouable: .status.allocatable | {cpu, memory}}'
kubectl describe node minikube | sed -n '/^Allocated resources:/,/^Events:/p' | head -9
```

```sortie
{"capacite":{"cpu":"22","memory":"15777996Ki","pods":"110"},"allouable":{"cpu":"22","memory":"15777996Ki"}}
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests      Limits
  --------           --------      ------
  cpu                2110m (9%)    3300m (15%)
  memory             2392Mi (15%)  5596Mi (36%)
  ephemeral-storage  0 (0%)        0 (0%)
  hugepages-1Gi      0 (0%)        0 (0%)
  hugepages-2Mi      0 (0%)        0 (0%)
```

:::panne[Le nœud minikube annonce 22 processeurs et 15 Gio, alors qu'il n'en a que 4]

Avec le pilote Docker, le nœud voit les ressources du poste entier, pas la limite du conteneur `minikube` (4 Gio ici, et aucune limite de processeur, comme le chapitre 27 l'a mesuré). Le scheduler placera donc sans broncher des Pods dont les requests totalisent 10 Gio, et c'est le noyau, en tuant des processus, qui rappellera la vraie limite. Sur un vrai cluster, l'allouable est la capacité de la machine moins les réservations du système et du kubelet (`systemReserved`, `kubeReserved`), et ce problème n'existe pas. Ici, `docker stats minikube` donne la vérité.

:::

La correction consiste à demander ce dont le programme a besoin, mesuré et pas deviné (chapitre 23). Les requests d'un Pod nu ne se modifient pas toutes après création ; on le recrée :

```bash
sed 's/memory: 64Gi/memory: 192Mi/' 01-trop-gourmand.yaml > trop-gourmand.yaml
kubectl -n ch49 delete pod trop-gourmand
```

```bash
kubectl apply -f trop-gourmand.yaml
kubectl -n ch49 wait --for=condition=Ready pod/trop-gourmand
```

```sortie
pod/trop-gourmand created
pod/trop-gourmand condition met
```

### 2. Un nœud qui n'existe pas

```bash
kubectl -n ch49 events --for pod/mauvais-noeud
kubectl get node minikube --show-labels | tr ',' '\n' | grep -E 'disque|kubernetes.io/hostname|topology'
```

```sortie
LAST SEEN   TYPE      REASON             OBJECT              MESSAGE
103s        Warning   FailedScheduling   Pod/mauvais-noeud   0/1 nodes are available: 1 node(s) didn't match Pod's node affinity/selector. preemption: 0/1 nodes are available: 1 Preemption is not helpful for scheduling.
kubernetes.io/hostname=minikube
topology.hostpath.csi/node=minikube
```

**Signature : `didn't match Pod's node affinity/selector`.** Le Pod exige `disque=nvme`, et aucun nœud ne porte cette étiquette. Le message ne dit pas laquelle manque : il faut comparer le `nodeSelector` (ou l'affinité) du Pod avec `--show-labels`. Deux corrections possibles, selon qui a raison. Si le Pod se trompe, on corrige son modèle. Si c'est le nœud, on l'étiquette, et le scheduler, qui garde les Pods non placés dans une file et les réexamine quand un nœud change, le place dans la seconde :

```bash
kubectl label node minikube disque=nvme
kubectl -n ch49 wait --for=condition=Ready pod/mauvais-noeud
kubectl -n ch49 events --for pod/mauvais-noeud | tail -4
kubectl label node minikube disque-
```

```sortie
node/minikube labeled
pod/mauvais-noeud condition met
1s          Normal    Scheduled          Pod/mauvais-noeud   Successfully assigned ch49/mauvais-noeud to minikube
0s          Normal    Pulled             Pod/mauvais-noeud   Container image "host.minikube.internal:5001/colis/api:2.1" already present on machine and can be accessed by the pod
0s          Normal    Created            Pod/mauvais-noeud   Container created
0s          Normal    Started            Pod/mauvais-noeud   Container started
node/minikube unlabeled
```

Retirer l'étiquette ensuite ne déplace pas le Pod : le sélecteur ne compte qu'au moment du placement (`requiredDuringSchedulingIgnoredDuringExecution`, dit le nom de l'affinité équivalente).

### 3. Un volume qui ne vient pas

```bash
kubectl -n ch49 events --for pod/volume-introuvable
kubectl -n ch49 get pvc donnees
kubectl -n ch49 events --for pvc/donnees
kubectl get storageclass
```

```sortie
LAST SEEN           TYPE      REASON             OBJECT                   MESSAGE
0s (x3 over 104s)   Warning   FailedScheduling   Pod/volume-introuvable   0/1 nodes are available: pod has unbound immediate PersistentVolumeClaims. not found
NAME      STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
donnees   Pending                                      rapide         <unset>                 105s
LAST SEEN           TYPE      REASON               OBJECT                          MESSAGE
5s (x8 over 105s)   Warning   ProvisioningFailed   PersistentVolumeClaim/donnees   storageclass.storage.k8s.io "rapide" not found
NAME                 PROVISIONER                RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
csi-attente          hostpath.csi.k8s.io        Delete          WaitForFirstConsumer   true                   11d
csi-hostpath-sc      hostpath.csi.k8s.io        Delete          Immediate              false                  11d
standard (default)   k8s.io/minikube-hostpath   Delete          Immediate              false                  12d
standard-garde       k8s.io/minikube-hostpath   Retain          Immediate              false                  11d
```

**Signature : `pod has unbound immediate PersistentVolumeClaims`** côté Pod, et la vraie cause côté PVC : `ProvisioningFailed … storageclass "rapide" not found`. C'est un cas typique où l'événement du Pod ne suffit pas : le scheduler sait seulement que la réclamation n'est pas liée, c'est le contrôleur des volumes qui sait pourquoi. Remontez toujours vers l'objet dont dépend celui qui bloque.

La classe de stockage d'une PVC ne se change pas après création :

```bash
kubectl -n ch49 patch pvc donnees --type=merge -p '{"spec":{"storageClassName":"standard"}}'
```

```sortie
The PersistentVolumeClaim "donnees" is invalid: spec: Forbidden: spec is immutable after creation except resources.requests and volumeAttributesClassName for bound claims
@@ -10,7 +10,7 @@
   }
  },
  "VolumeName": "",
- "StorageClassName": "rapide",
+ "StorageClassName": "standard",
  "VolumeMode": "Filesystem",
  "DataSource": null,
  "DataSourceRef": null,
```

On supprime donc le Pod puis la PVC (dans cet ordre, sinon la protection `pvc-protection` fait attendre la suppression de la PVC), et on recrée les deux avec une classe qui existe :

```bash
kubectl -n ch49 delete pod volume-introuvable && kubectl -n ch49 delete pvc donnees
```

```bash
sed 's/storageClassName: rapide/storageClassName: standard/' 03-volume-introuvable.yaml | kubectl apply -f -
kubectl -n ch49 wait --for=condition=Ready pod/volume-introuvable
kubectl -n ch49 get pvc donnees
```

```sortie
persistentvolumeclaim/donnees created
pod/volume-introuvable created
pod/volume-introuvable condition met
NAME      STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
donnees   Bound    pvc-acbf800e-d174-4a63-b101-843d14a7c4b1   1Gi        RWO            standard       <unset>                 1s
```

## Le conteneur n'est pas créé

Une fois le Pod placé, le kubelet du nœud prend le relais : il monte les volumes, tire les images, prépare la configuration de chaque conteneur, puis demande au runtime de le lancer. Chaque étape a son état d'attente, et le kubelet réessaie chacune indéfiniment, en espaçant les essais. Conséquence utile : dans les trois pannes qui suivent, réparer la cause suffit, sans toucher au Pod.

### 4. Une étiquette qui n'existe pas

```bash
kubectl -n ch49 get pod etiquette-absente -o jsonpath='{.status.containerStatuses[0].state.waiting}' | jq -c '{reason, message}'
curl -s http://localhost:5001/v2/colis/api/tags/list
```

```sortie
{"reason":"ImagePullBackOff","message":"Back-off pulling image \"host.minikube.internal:5001/colis/api:2.9\": ErrImagePull: rpc error: code = NotFound desc = failed to pull and unpack image \"host.minikube.internal:5001/colis/api:2.9\": failed to resolve reference \"host.minikube.internal:5001/colis/api:2.9\": host.minikube.internal:5001/colis/api:2.9: not found"}
{"name":"colis/api","tags":["2.0","2.1","sha256-413c694aa81eff89e4d644e55d1b98e4cda7918ace9a80c5a040c27fb3f4aaa6","sha256-ade99a611b6a907ceacc9deb10f1a7cc21a1f49f7f4395d5d5b5a145205ad3a5","sha256-ade99a611b6a907ceacc9deb10f1a7cc21a1f49f7f4395d5d5b5a145205ad3a5.att","sha256-ade99a611b6a907ceacc9deb10f1a7cc21a1f49f7f4395d5d5b5a145205ad3a5.sig","sha256-b399d3cb7cef96a206f301352f32bb40ed97edfd08a4bde55acf4cc5cb9c133a","sha256-efc1540bde769e70ef66b3bb86125e1762e8de389f9df22dfe5ecd0c3138cdbc"]}
```

**Signature : `ErrImagePull`, puis `ImagePullBackOff`, avec `not found`** dans le message. `ErrImagePull` est l'état juste après un échec ; `ImagePullBackOff` celui de l'attente avant le prochain essai, qui double à chaque fois jusqu'à 5 minutes, comme pour les redémarrages[^images]. Le registre répond, et c'est le point important : la connexion marche, seule l'étiquette manque. La liste des étiquettes du dépôt le confirme : `2.0` et `2.1` existent, pas `2.9`. Les étiquettes `sha256-…` sont les signatures et attestations du chapitre 47.

Le champ `image` est l'un des rares champs modifiables d'un Pod existant :

```bash
kubectl -n ch49 set image pod/etiquette-absente api=host.minikube.internal:5001/colis/api:2.1
kubectl -n ch49 wait --for=condition=Ready pod/etiquette-absente
```

```sortie
pod/etiquette-absente image updated
pod/etiquette-absente condition met
```

### 5. Un registre injoignable

```bash
kubectl -n ch49 events --for pod/registre-injoignable -o json \
  | jq -r '[.items[] | select(.reason=="Failed")][0].message'
```

```sortie
Failed to pull image "host.minikube.internal:5010/colis/api:2.1": failed to pull and unpack image "host.minikube.internal:5010/colis/api:2.1": failed to resolve reference "host.minikube.internal:5010/colis/api:2.1": failed to do request: Head "https://host.minikube.internal:5010/v2/colis/api/manifests/2.1": dial tcp 192.168.49.1:5010: connect: connection refused
```

**Signature : un message réseau, `dial tcp … connection refused`** (ou `no such host`, `i/o timeout`) : cette fois, le nœud n'a même pas parlé au registre. Le message dit aussi que containerd a essayé en `https://` : seul le port 5001 a reçu, au chapitre 24, le fichier `hosts.toml` qui autorise le HTTP simple. Une faute de frappe dans le port, et l'on perd à la fois le bon serveur et le bon protocole. Même correction que la précédente :

```bash
kubectl -n ch49 set image pod/registre-injoignable api=host.minikube.internal:5001/colis/api:2.1
kubectl -n ch49 wait --for=condition=Ready pod/registre-injoignable
```

```sortie
pod/registre-injoignable image updated
pod/registre-injoignable condition met
```

### 6. Une clé absente

```bash
kubectl -n ch49 get pod cle-manquante -o jsonpath='{.status.containerStatuses[0].state.waiting}' | jq -c '{reason, message}'
kubectl -n ch49 get secret colis-db -o json | jq -c '.data | keys'
```

```sortie
{"reason":"CreateContainerConfigError","message":"couldn't find key POSTGRES_MOT_DE_PASSE in Secret ch49/colis-db"}
["POSTGRES_PASSWORD"]
```

**Signature : `CreateContainerConfigError`, `couldn't find key … in Secret`.** Le Pod demande la clé `POSTGRES_MOT_DE_PASSE`, le Secret ne contient que `POSTGRES_PASSWORD`. La même erreur apparaît si le Secret ou la ConfigMap entière manque (`secret "x" not found`). Le kubelet réessaie : ajouter la clé suffit, et le conteneur démarre seul, ici en 3 secondes.

```bash
date +%T
kubectl -n ch49 patch secret colis-db --type=merge -p '{"stringData":{"POSTGRES_MOT_DE_PASSE":"mot-de-passe-d-essai"}}'
kubectl -n ch49 wait --for=condition=Ready pod/cle-manquante
date +%T
```

```sortie
23:22:18
secret/colis-db patched
pod/cle-manquante condition met
23:22:21
NAME            READY   STATUS    RESTARTS   AGE
cle-manquante   1/1     Running   0          110s
```

Dans la vraie vie, la bonne correction est plutôt l'inverse : rectifier le nom de la clé dans le modèle du Deployment. Ajouter une clé au Secret pour faire plaisir à une faute de frappe, c'est la retrouver dans six mois sans savoir d'où elle vient.

### 7. Une ConfigMap absente

```bash
kubectl -n ch49 events --for pod/configmap-absente
```

```sortie
LAST SEEN            TYPE      REASON        OBJECT                  MESSAGE
109s                 Normal    Scheduled     Pod/configmap-absente   Successfully assigned ch49/configmap-absente to minikube
45s (x8 over 109s)   Warning   FailedMount   Pod/configmap-absente   MountVolume.SetUp failed for volume "config" : configmap "colis-regles" not found
```

**Signature : `ContainerCreating` qui dure, avec `FailedMount … configmap "colis-regles" not found`.** Différence avec la panne précédente : la ConfigMap est montée comme volume, et non lue dans une variable. Le kubelet bloque donc à l'étape des volumes, avant même de regarder l'image, et `STATUS` reste sur `ContainerCreating`, qui ressemble à une attente normale. Seul l'événement `FailedMount`, répété, signale une panne. On crée la ConfigMap :

```bash
date +%T
kubectl -n ch49 create configmap colis-regles --from-literal=tarif=4.90
kubectl -n ch49 wait --for=condition=Ready pod/configmap-absente
date +%T
kubectl -n ch49 logs configmap-absente
```

```sortie
23:22:21
configmap/colis-regles created
pod/configmap-absente condition met
23:22:52
tarif : 4.90
```

Cette fois, 31 secondes : le kubelet réessaie les montages en échec avec une attente qui s'allonge, et elle avait déjà atteint plusieurs secondes. Si le volume est facultatif pour le programme, `configMap.optional: true` permet de démarrer sans lui[^configmap].

## Le conteneur s'arrête

Le conteneur a démarré, puis il s'arrête. Le chapitre 48 a donné la méthode générale : raison et code du dernier arrêt, puis journaux. Trois cas méritent d'être reconnus d'un coup d'œil.

### 8. La limite de mémoire

```bash
M=$(kubectl -n ch49 get pods -l app=memoire -o name | head -1)
kubectl -n ch49 get $M
kubectl -n ch49 get $M -o jsonpath='{.status.containerStatuses[0].lastState.terminated}' | jq -c '{reason, exitCode, startedAt, finishedAt}'
kubectl -n ch49 logs $M --tail=3
minikube ssh -- 'sudo dmesg | grep "Memory cgroup out of memory" | tail -1'
```

```sortie
NAME                       READY   STATUS      RESTARTS      AGE
memoire-7797c58cb4-bnnwm   0/1     OOMKilled   4 (92s ago)   2m20s
{"reason":"OOMKilled","exitCode":137,"startedAt":"2026-10-07T22:21:18Z","finishedAt":"2026-10-07T22:21:20Z"}
100 Mio
110 Mio
120 Mio
[52898.760748] Memory cgroup out of memory: Killed process 625442 (python) total-vm:144296kB, anon-rss:130232kB, file-rss:5516kB, shmem-rss:0kB, UID:10001 pgtables:316kB oom_score_adj:996
```

**Signature : `OOMKilled`, code 137.** Le programme réserve 10 Mio toutes les 200 millisecondes, et meurt après avoir annoncé 120 Mio, deux secondes après son démarrage : avec l'interpréteur Python, il approche de la limite de 128 Mio. Ce n'est pas Kubernetes qui l'a tué, mais le noyau. La limite est une valeur du cgroup du conteneur (chapitre 9) ; quand le groupe la dépasse, le noyau choisit un processus du groupe et le tue. Sa trace dans le journal du noyau donne le détail : 130 232 Kio de mémoire résidente, utilisateur 10001, celui de l'image. Le kubelet ne fait que constater l'arrêt et en lire la cause[^memoire].

Avant de relever la limite, demandez-vous si la consommation est normale. Une fuite de mémoire relevée à 512 Mio sera de nouveau tuée, juste plus tard. Ici, le programme a besoin de ses 300 Mio :

```bash
kubectl -n ch49 set resources deploy/memoire --limits=memory=512Mi --requests=memory=320Mi
kubectl -n ch49 rollout status deploy/memoire
kubectl -n ch49 get pods -l app=memoire
kubectl -n ch49 logs deploy/memoire --tail=1
```

```sortie
deployment.apps/memoire resource requirements updated
Waiting for deployment "memoire" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "memoire" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "memoire" rollout to finish: 1 old replicas are pending termination...
deployment "memoire" successfully rolled out
NAME                       READY   STATUS    RESTARTS   AGE
memoire-55cf699895-kvdbk   1/1     Running   0          11s
300 Mio
```

Deux variantes à connaître. Un Pod sans limite peut être tué quand c'est le **nœud** qui manque de mémoire : soit par le noyau, qui choisit alors dans tout le système en tenant compte d'un score qui dépend de la classe de qualité de service (chapitre 23), soit par le kubelet, qui **évince** des Pods avant d'en arriver là (`Evicted`, avec la raison `The node was low on resource: memory`)[^eviction]. Et depuis Kubernetes 1.35, on peut changer les ressources d'un conteneur sans recréer le Pod, par la sous-ressource `resize`[^resize] ; un Deployment, lui, recrée de toute façon ses Pods quand son modèle change.

### 9. Un programme qui se termine

```bash
T=$(kubectl -n ch49 get pods -l app=tache-finie -o name | head -1)
kubectl -n ch49 get $T
kubectl -n ch49 get $T -o jsonpath='{.status.containerStatuses[0].lastState.terminated}' | jq -c '{reason, exitCode}'
kubectl -n ch49 logs $T
```

```sortie
NAME                         READY   STATUS      RESTARTS       AGE
tache-finie-c9cc4789-9hg6m   0/1     Completed   4 (113s ago)   2m32s
{"reason":"Completed","exitCode":0}
purge des colis de plus de 30 jours
0 colis supprimé
```

**Signature : `Completed`, code 0, et pourtant `CrashLoopBackOff` par moments.** Le programme fait son travail et se termine proprement. Mais un Deployment impose `restartPolicy: Always` : le kubelet relance tout conteneur qui s'arrête, avec succès ou non, et applique le même délai croissant[^redemarrage]. Rien n'est cassé dans le programme ; c'est l'objet qui est mal choisi. Un traitement qui a une fin relève d'un Job, ou d'un CronJob s'il revient régulièrement (chapitre 27) :

```bash
kubectl -n ch49 delete deploy tache-finie
kubectl -n ch49 create job purge --image=busybox:1.37 -- sh -c 'echo purge des colis de plus de 30 jours; echo 0 colis supprimé'
kubectl -n ch49 wait --for=condition=Complete job/purge
kubectl -n ch49 get job purge
```

```sortie
deployment.apps "tache-finie" deleted from ch49 namespace
job.batch/purge created
job.batch/purge condition met
NAME    STATUS     COMPLETIONS   DURATION   AGE
purge   Complete   1/1           4s         4s
```

### 10. Une sonde de vie impatiente

Cette panne est la plus sournoise du chapitre. Dans la toute première vue, le Pod `vie-impatiente` était en `CrashLoopBackOff`, avec 4 redémarrages. Une minute plus tard, le même Pod a l'air guéri :

```bash
V=$(kubectl -n ch49 get pods -l app=vie-impatiente -o name | head -1)
kubectl -n ch49 get $V
kubectl -n ch49 describe $V | sed -n '/^    State:/,/^    Ready:/p'
kubectl -n ch49 events --for $V | grep -E 'Unhealthy|Killing|BackOff'
```

```sortie
NAME                              READY   STATUS    RESTARTS      AGE
vie-impatiente-869bcc8945-wflfw   1/1     Running   5 (61s ago)   2m36s
    State:          Running
      Started:      Wed, 07 Oct 2026 23:22:59 +0100
    Last State:     Terminated
      Reason:       Error
      Exit Code:    137
      Started:      Wed, 07 Oct 2026 23:21:54 +0100
      Finished:     Wed, 07 Oct 2026 23:22:07 +0100
    Ready:          True
60s (x4 over 96s)     Warning   BackOff     Pod/vie-impatiente-869bcc8945-wflfw   Back-off restarting failed container api in pod vie-impatiente-869bcc8945-wflfw_ch49(19bcdb23-6f43-4de6-865a-c9abb36502bb)
1s (x12 over 2m31s)   Warning   Unhealthy   Pod/vie-impatiente-869bcc8945-wflfw   Liveness probe failed: Get "http://10.244.0.19:8000/sante": dial tcp 10.244.0.19:8000: connect: connection refused
1s (x6 over 2m26s)    Normal    Killing     Pod/vie-impatiente-869bcc8945-wflfw   Container api failed liveness probe, will be restarted
```

**Signature : `Killing … failed liveness probe, will be restarted`**, un code 137, et un nombre de redémarrages qui grimpe pendant que le Pod a l'air sain la moitié du temps : `Running`, `1/1`, `Ready: True`, jusqu'au prochain coup de la sonde. Le programme met 20 secondes à démarrer (un préchauffage simulé par `sleep 20`). La sonde de vie interroge `/sante` toutes les 5 secondes et tue le conteneur après 2 échecs : il meurt au bout de 10 à 15 secondes, avant d'avoir jamais écouté. Pourquoi 137 et pas 143 ? Le kubelet envoie SIGTERM, que le shell en PID 1 ignore (exercice 2 du chapitre 48) ; au bout du délai de grâce de 5 secondes, il envoie SIGKILL. Le Pod affichait `1/1` parce qu'il n'a pas de sonde de disponibilité : sans elle, un conteneur démarré est déclaré prêt.

La correction est une **sonde de démarrage** (chapitre 22) : tant qu'elle n'a pas réussi, la sonde de vie ne s'exécute pas[^sondes]. Ici, jusqu'à 12 essais espacés de 5 secondes, soit une minute de marge :

```bash
kubectl -n ch49 patch deploy vie-impatiente --type=json -p '[{"op":"add",
  "path":"/spec/template/spec/containers/0/startupProbe",
  "value":{"httpGet":{"path":"/sante","port":"http"},"periodSeconds":5,"failureThreshold":12}}]'
kubectl -n ch49 rollout status deploy/vie-impatiente
kubectl -n ch49 get pods -l app=vie-impatiente     # une minute plus tard
```

```sortie
deployment.apps/vie-impatiente patched
Waiting for deployment "vie-impatiente" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "vie-impatiente" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "vie-impatiente" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "vie-impatiente" rollout to finish: 1 old replicas are pending termination...
deployment "vie-impatiente" successfully rolled out
NAME                              READY   STATUS    RESTARTS   AGE
vie-impatiente-86df7c669d-tzk24   1/1     Running   0          66s
```

## Le Pod tourne, mais le service n'est pas rendu

### 11. Une sonde de disponibilité fausse

```bash
kubectl -n ch49 get deploy pas-prete
kubectl -n ch49 get endpointslices -l kubernetes.io/service-name=pas-prete -o json \
  | jq -c '[.items[].endpoints[] | {ip: .addresses[0], ready: .conditions.ready}]'
P=$(kubectl -n ch49 get pods -l app=pas-prete -o name | head -1)
kubectl -n ch49 events --for $P | grep Unhealthy
kubectl -n ch49 exec $P -- python -c "import urllib.request as u
for c in ('/prete', '/pret'):
    try: print(c, u.urlopen('http://localhost:8000' + c).status)
    except Exception as e: print(c, e)"
```

```sortie
NAME        READY   UP-TO-DATE   AVAILABLE   AGE
pas-prete   0/2     2            0           3m42s
[{"ip":"10.244.0.24","ready":false},{"ip":"10.244.0.21","ready":false}]
3m40s (x2 over 3m41s)   Warning   Unhealthy   Pod/pas-prete-7b66ffdfd4-l5b2m   Readiness probe failed: Get "http://10.244.0.21:8000/prete": dial tcp 10.244.0.21:8000: connect: connection refused
106s (x23 over 3m35s)   Warning   Unhealthy   Pod/pas-prete-7b66ffdfd4-l5b2m   Readiness probe failed: HTTP probe failed with statuscode: 404
/prete HTTP Error 404: Not Found
/pret 200
```

**Signature : `Running`, `0/1`, aucun redémarrage, et `HTTP probe failed with statuscode: 404`.** Un 404 est une réponse : l'application tourne, écoute, et ne connaît pas le chemin demandé. La sonde vise `/prete`, l'API expose `/pret`. Comparez avec les deux premières lignes d'événements, `connection refused` pendant la première seconde : ça, c'était le démarrage normal. Les Pods ne sont pas tués, puisque c'est une sonde de disponibilité, mais ils restent hors du Service, qui n'a aucun point d'accès prêt. Un Deployment dans cet état bloque aussi tout déploiement suivant, qui attend des Pods disponibles (chapitre 19).

```bash
kubectl -n ch49 patch deploy pas-prete --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/pret"}]'
kubectl -n ch49 rollout status deploy/pas-prete
kubectl -n ch49 get deploy pas-prete
```

```sortie
deployment.apps/pas-prete patched
Waiting for deployment "pas-prete" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "pas-prete" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "pas-prete" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "pas-prete" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "pas-prete" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "pas-prete" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "pas-prete" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "pas-prete" rollout to finish: 1 old replicas are pending termination...
deployment "pas-prete" successfully rolled out
NAME        READY   UP-TO-DATE   AVAILABLE   AGE
pas-prete   2/2     2            2           3m55s
```

### 12. Le DNS coupé

Le Pod `client` est `Running`, `1/1`, et n'a jamais redémarré. Il ne joint pourtant personne par son nom :

```bash
kubectl -n ch49 exec client -- nslookup -timeout=3 pas-prete.ch49.svc.cluster.local
kubectl -n ch49 exec client -- wget -q -T 3 -O - http://pas-prete:8000/sante
SVC=$(kubectl -n ch49 get svc pas-prete -o jsonpath='{.spec.clusterIP}')
kubectl -n ch49 exec client -- wget -q -T 3 -O - http://$SVC:8000/sante
kubectl -n ch49 get networkpolicy refus-sortie -o jsonpath='{.spec}' | jq -c .
```

```sortie
;; connection timed out; no servers could be reached

command terminated with exit code 1
wget: bad address 'pas-prete:8000'
command terminated with exit code 1
{"statut":"ok","version":"1.0.0","hote":"pas-prete-f86dd79d7-tvk4w"}
{"egress":[{"to":[{"podSelector":{}}]}],"podSelector":{"matchLabels":{"app":"client"}},"policyTypes":["Egress"]}
```

**Signature : `connection timed out; no servers could be reached`** pour le DNS (ou `bad address`, `Try again`, `Temporary failure in name resolution` selon la bibliothèque), alors que la même destination jointe par son adresse répond. Une attente qui expire, et non un refus : c'est la marque d'une NetworkPolicy, qui laisse tomber les paquets en silence (chapitre 41). La politique `refus-sortie` autorise les sorties vers les Pods du namespace, et rien d'autre. Or le serveur DNS du cluster vit dans `kube-system`. C'est l'erreur classique du « refus par défaut » posé sans son exception DNS[^netpol], et elle passe inaperçue tant qu'on ne teste qu'avec des adresses.

```bash
cat > dns.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: dns
  namespace: ch49
spec:
  podSelector:
    matchLabels:
      app: client
  policyTypes: [Egress]
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
EOF
kubectl apply -f dns.yaml
kubectl -n ch49 exec client -- nslookup pas-prete.ch49.svc.cluster.local
kubectl -n ch49 exec client -- wget -q -T 3 -O - http://pas-prete:8000/sante
```

```sortie
networkpolicy.networking.k8s.io/dns created
Server:		10.96.0.10
Address:	10.96.0.10:53

Name:	pas-prete.ch49.svc.cluster.local
Address: 10.102.101.209


{"statut":"ok","version":"1.0.0","hote":"pas-prete-f86dd79d7-tvk4w"}
```

Le DNS passe par UDP et, pour les longues réponses, par TCP : autorisez les deux.

## L'objet ne disparaît pas

```bash
kubectl -n ch49 delete cm regles-tarifaires --wait=false
kubectl -n ch49 get cm regles-tarifaires -o json \
  | jq -c '{nom: .metadata.name, suppression: .metadata.deletionTimestamp, finaliseurs: .metadata.finalizers}'
timeout 10 kubectl -n ch49 delete cm regles-tarifaires; echo "code de retour : $?"
```

```sortie
configmap "regles-tarifaires" deleted from ch49 namespace
{"nom":"regles-tarifaires","suppression":"2026-10-07T22:24:55Z","finaliseurs":["cours.exemple/archivage"]}
configmap "regles-tarifaires" deleted from ch49 namespace
code de retour : 124
```

**Signature : `deletionTimestamp` rempli, `finalizers` non vide, et une commande `delete` qui ne rend jamais la main.** Un finaliseur est une étiquette posée par un contrôleur pour dire « avant de supprimer cet objet, laissez-moi faire mon ménage » (chapitre 36) : libérer un disque chez un fournisseur de nuage, retirer une entrée DNS, sauvegarder des données. L'API server marque l'objet comme en cours de suppression et attend que la liste des finaliseurs soit vide[^finaliseurs]. Si le contrôleur concerné a été désinstallé, ou ne fonctionne plus, personne ne la videra. Ici, `cours.exemple/archivage` n'appartient à aucun contrôleur. Le code 124 est celui de `timeout`, qui a interrompu l'attente.

La bonne correction est de réparer le contrôleur. Quand il n'existe plus, on retire le finaliseur à la main, en acceptant que son ménage n'ait jamais lieu :

```bash
kubectl -n ch49 patch cm regles-tarifaires --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
kubectl -n ch49 get cm regles-tarifaires
```

```sortie
configmap/regles-tarifaires patched
Error from server (NotFound): configmaps "regles-tarifaires" not found
```

C'est aussi la cause habituelle d'un **namespace** bloqué en `Terminating` : un objet à l'intérieur porte un finaliseur que personne ne retire. L'exercice 4 montre comment le trouver.

## Par où commencer ?

Les treize signatures tiennent dans un arbre de décision. Partez de ce qu'affiche `kubectl get pods`, répondez aux questions, et l'arbre propose une cause probable, la commande qui la confirme, la correction et la section du chapitre qui en parle :

<ArbreDiagnostic />

L'arbre couvre aussi quelques pannes voisines, traitées ailleurs dans le cours : teinte non tolérée, bac à sable réseau, registre qui demande une authentification, image qui tourne en root dans un namespace qui l'interdit. Il ne remplace pas la méthode du chapitre 48 : il dit seulement par quelle couche commencer.

## Exercices

:::exercice[Exercice 1 : le Deployment sans Pod]

Dans un namespace neuf, posez un quota sur la mémoire, puis créez un Deployment qui ne déclare aucune ressource :

```bash
kubectl create ns ch49-quota
kubectl -n ch49-quota create quota memoire --hard=requests.memory=512Mi,limits.memory=1Gi
kubectl -n ch49-quota create deployment api --image=host.minikube.internal:5001/colis/api:2.1 --replicas=2
```

Combien de Pods voyez-vous ? Où se trouve l'explication ? Corrigez, puis passez à 3 répliques : que se passe-t-il ?

:::

<details>
<summary>Corrigé</summary>

```bash
kubectl -n ch49-quota get deploy,rs,pods
kubectl -n ch49-quota events --types=Warning
kubectl -n ch49-quota get deploy api -o json | jq -c '.status.conditions[] | {type, status, reason}'
```

```sortie
NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/api   0/2     0            0           8s

NAME                             DESIRED   CURRENT   READY   AGE
replicaset.apps/api-764bff6f46   2         0         0       8s
LAST SEEN         TYPE      REASON         OBJECT                      MESSAGE
8s                Warning   FailedCreate   ReplicaSet/api-764bff6f46   Error creating: pods "api-764bff6f46-srfff" is forbidden: failed quota: memoire: must specify limits.memory for: api; requests.memory for: api
8s                Warning   FailedCreate   ReplicaSet/api-764bff6f46   Error creating: pods "api-764bff6f46-fgzhw" is forbidden: failed quota: memoire: must specify limits.memory for: api; requests.memory for: api
8s                Warning   FailedCreate   ReplicaSet/api-764bff6f46   Error creating: pods "api-764bff6f46-2szpg" is forbidden: failed quota: memoire: must specify limits.memory for: api; requests.memory for: api
8s                Warning   FailedCreate   ReplicaSet/api-764bff6f46   Error creating: pods "api-764bff6f46-272bb" is forbidden: failed quota: memoire: must specify limits.memory for: api; requests.memory for: api
8s                Warning   FailedCreate   ReplicaSet/api-764bff6f46   Error creating: pods "api-764bff6f46-wg4vz" is forbidden: failed quota: memoire: must specify limits.memory for: api; requests.memory for: api
8s                Warning   FailedCreate   ReplicaSet/api-764bff6f46   Error creating: pods "api-764bff6f46-qml9n" is forbidden: failed quota: memoire: must specify limits.memory for: api; requests.memory for: api
8s                Warning   FailedCreate   ReplicaSet/api-764bff6f46   Error creating: pods "api-764bff6f46-lpgcr" is forbidden: failed quota: memoire: must specify limits.memory for: api; requests.memory for: api
7s                Warning   FailedCreate   ReplicaSet/api-764bff6f46   Error creating: pods "api-764bff6f46-96r5x" is forbidden: failed quota: memoire: must specify limits.memory for: api; requests.memory for: api
7s                Warning   FailedCreate   ReplicaSet/api-764bff6f46   Error creating: pods "api-764bff6f46-wszdk" is forbidden: failed quota: memoire: must specify limits.memory for: api; requests.memory for: api
3s (x2 over 5s)   Warning   FailedCreate   ReplicaSet/api-764bff6f46   (combined from similar events): Error creating: pods "api-764bff6f46-hktgf" is forbidden: failed quota: memoire: must specify limits.memory for: api; requests.memory for: api
{"type":"Progressing","status":"True","reason":"NewReplicaSetCreated"}
{"type":"Available","status":"False","reason":"MinimumReplicasUnavailable"}
{"type":"ReplicaFailure","status":"True","reason":"FailedCreate"}
```

Aucun Pod, et donc aucun Pod à décrire : c'est ce qui rend cette panne déroutante. L'explication est sur le **ReplicaSet**, qui a tenté de créer les Pods et s'est vu refuser chaque création. Un quota sur `requests.memory` et `limits.memory` oblige chaque Pod du namespace à déclarer ces deux valeurs[^quota] ; sans elle, l'admission refuse. Le Deployment, lui, se contente de `ReplicaFailure` dans ses conditions. Avec des ressources déclarées, les deux Pods passent ; une troisième réplique dépasserait le quota :

```bash
kubectl -n ch49-quota set resources deploy/api --requests=memory=192Mi --limits=memory=256Mi
kubectl -n ch49-quota rollout status deploy/api
kubectl -n ch49-quota scale deploy/api --replicas=3
kubectl -n ch49-quota get deploy api
kubectl -n ch49-quota describe quota memoire | tail -4
kubectl -n ch49-quota events --types=Warning | tail -1
```

```sortie
deployment.apps/api resource requirements updated
Waiting for deployment "api" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "api" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "api" rollout to finish: 1 of 2 updated replicas are available...
deployment "api" successfully rolled out
deployment.apps/api scaled
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
api    2/3     2            2           16s
Resource         Used   Hard
--------         ----   ----
limits.memory    512Mi  1Gi
requests.memory  384Mi  512Mi
1s (x2 over 3s)    Warning   FailedCreate   ReplicaSet/api-84679c44f5   (combined from similar events): Error creating: pods "api-84679c44f5-kvr9j" is forbidden: exceeded quota: memoire, requested: requests.memory=192Mi, used: requests.memory=384Mi, limited: r
```

Trois fois 192 Mio font 576 Mio, au-delà des 512 Mio permis : le Deployment reste à 2 sur 3, et le refus est de nouveau sur le ReplicaSet. Retenez le réflexe : un Deployment en dessous de son nombre de répliques sans Pod en échec, on regarde les événements de son ReplicaSet (chapitre 44 pour la même situation avec Pod Security).

</details>

:::exercice[Exercice 2 : les conteneurs d'initialisation]

Créez ces deux Pods dans un namespace `ch49-init`, et observez-les pendant une minute. Quels `STATUS` affichent-ils ? Comment lire les journaux du conteneur qui pose problème ? Lequel des deux est une panne, et lequel pourrait être un fonctionnement normal ?

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: migration-ratee
spec:
  initContainers:
  - name: migration
    image: busybox:1.37
    command: ["sh", "-c", "echo application des migrations; echo 'table colis : colonne poids_kg déjà présente' >&2; exit 2"]
  containers:
  - name: api
    image: host.minikube.internal:5001/colis/api:2.1
---
apiVersion: v1
kind: Pod
metadata:
  name: attente-base
spec:
  initContainers:
  - name: attendre-postgres
    image: busybox:1.37
    command: ["sh", "-c", "until nc -z -w 2 postgres 5432; do echo 'postgres pas encore joignable'; sleep 5; done"]
  containers:
  - name: api
    image: host.minikube.internal:5001/colis/api:2.1
```

:::

<details>
<summary>Corrigé</summary>

```bash
kubectl -n ch49-init get pods
kubectl -n ch49-init logs migration-ratee -c migration
kubectl -n ch49-init get pod migration-ratee -o jsonpath='{.status.initContainerStatuses[0].lastState.terminated}' | jq -c '{reason, exitCode}'
kubectl -n ch49-init logs attente-base -c attendre-postgres --tail=2
kubectl -n ch49-init events --for pod/attente-base | tail -3
```

```sortie
NAME              READY   STATUS       RESTARTS      AGE
attente-base      0/1     Init:0/1     0             46s
migration-ratee   0/1     Init:Error   3 (29s ago)   46s
application des migrations
table colis : colonne poids_kg déjà présente
{"reason":"Error","exitCode":2}
nc: bad address 'postgres'
postgres pas encore joignable
45s         Normal   Pulled      Pod/attente-base   Container image "busybox:1.37" already present on machine and can be accessed by the pod
45s         Normal   Created     Pod/attente-base   Container created
45s         Normal   Started     Pod/attente-base   Container started
```

Les conteneurs d'initialisation s'exécutent un par un[^init], avant les conteneurs principaux, et chacun doit réussir. `Init:CrashLoopBackOff` (ou `Init:Error` juste après un échec) : le premier échoue avec le code 2, et le kubelet le relance en boucle. `Init:0/1` : le premier tourne encore, sans fin. Pour lire leur journal, il faut nommer le conteneur avec `-c`, sinon `kubectl logs` vise le conteneur principal, qui n'a jamais démarré. Les statuts sont dans `initContainerStatuses`, pas dans `containerStatuses`.

`migration-ratee` est une panne : la migration échoue et échouera toujours. `attente-base` peut être normal au déploiement, le temps que PostgreSQL démarre ; ici, il n'existe aucun Service `postgres` dans ce namespace, et le Pod attendra toujours, sans un seul événement d'avertissement. Un conteneur d'attente sans limite de durée cache les pannes : préférez une application qui réessaie elle-même (comme l'API 2.1 au chapitre 26), ou au moins un compteur d'essais dans la boucle.

</details>

:::exercice[Exercice 3 : le palmarès des avertissements (programmation)]

Sur un cluster réel, les événements `Warning` se comptent par centaines, et beaucoup ne diffèrent que par un nom de Pod ou une adresse. Écrivez un script Python qui lit `kubectl get events -o json` (un namespace en argument, sinon tous), garde les avertissements, **normalise** leurs messages (adresses IP, identifiants, nombres et noms de Pods générés remplacés par des jetons), les regroupe par raison et message normalisé, et affiche les plus fréquents avec le nombre total d'occurrences (champ `count` ou `series.count`) et le nombre d'objets concernés. Essayez-le sur le namespace `ch49` juste après avoir appliqué les treize pannes.

:::

<details>
<summary>Corrigé</summary>

Le corrigé, `corrige/palmares.py`, n'est pas dans l'archive. Son cœur est une liste de substitutions, appliquées dans l'ordre (du plus spécifique au plus général) :

```python
VARIABLES = [
    (re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"), "<uid>"),
    (re.compile(r"\b(\d{1,3}\.){3}\d{1,3}(:\d+)?\b"), "<ip>"),
    (re.compile(r"\b[0-9a-f]{12,64}\b"), "<id>"),
    (re.compile(r"\b[a-z0-9-]+-[a-z0-9]{8,10}-[a-z0-9]{5}(?![a-z0-9-])"), "<pod>"),  # Pod d'un Deployment
    (re.compile(r"\b\d+(\.\d+)?(ms|s|m|h|Mi|Gi|Ki)?\b"), "<n>"),
]

def occurrences(ev):
    serie = ev.get("series") or {}
    return serie.get("count") or ev.get("count") or 1
```

```bash
python3 palmares.py ch49 --top 12
```

```sortie
  NB OBJ  RAISON : MESSAGE
  40   2  Unhealthy : Readiness probe failed: HTTP probe failed with statuscode: <n>
  11   2  Failed : Error: ImagePullBackOff
  10   1  Unhealthy : Liveness probe failed: Get "http://<ip>/sante": dial tcp <ip>: connect: connection refused
   9   1  Failed : Error: couldn't find key POSTGRES_MOT_DE_PASSE in Secret ch49/colis-db
   8   1  FailedMount : MountVolume.SetUp failed for volume "config" : configmap "colis-regles" not found
   8   1  ProvisioningFailed : storageclass.storage.k8s.io "rapide" not found
   8   2  Failed : Error: ErrImagePull
   4   1  Failed : Failed to pull image "host.minikube.internal:<n>/colis/api:<n>": rpc error: code = NotFound desc = failed to pull and un
   4   2  Unhealthy : Readiness probe failed: Get "http://<ip>/prete": dial tcp <ip>: connect: connection refused
   4   1  Failed : Failed to pull image "host.minikube.internal:<n>/colis/api:<n>": failed to pull and unpack image "host.minikube.internal
   4   1  BackOff : Back-off restarting failed container purge in pod <pod>_ch49(<uid>)
   3   1  BackOff : Back-off restarting failed container calcul in pod <pod>_ch49(<uid>)
```

Le classement fait ressortir ce qui se répète : les sondes et les relances en boucle, qui produisent un événement à chaque essai, viennent en tête, tandis que les pannes de placement n'en produisent qu'un ou deux. C'est un biais à garder en tête : la panne la plus bruyante n'est pas forcément la plus grave. Trois Pods `Pending` silencieux peuvent compter davantage qu'une sonde qui échoue en boucle sur un Pod de test. L'ordre des substitutions compte : appliquer celle des nombres en premier découperait les adresses IP et les identifiants en morceaux.

</details>

:::exercice[Exercice 4 : le namespace qui ne meurt pas]

```bash
kubectl create ns ch49-fin
kubectl -n ch49-fin create configmap archive --from-literal=a=1
kubectl -n ch49-fin patch cm archive --type=merge -p '{"metadata":{"finalizers":["cours.exemple/archivage"]}}'
kubectl delete ns ch49-fin --wait=false
```

Le namespace reste `Terminating`. Sans connaître à l'avance le coupable, comment le trouver ? Débloquez-le proprement, sans toucher au namespace lui-même.

:::

<details>
<summary>Corrigé</summary>

```bash
kubectl get ns ch49-fin
kubectl get ns ch49-fin -o json | jq -c '.status.conditions[] | select(.status == "True") | {type, reason, message}'
kubectl api-resources --verbs=list --namespaced -o name \
  | xargs -n1 kubectl -n ch49-fin get --ignore-not-found -o name
```

```sortie
NAME       STATUS        AGE
ch49-fin   Terminating   9s
{"type":"NamespaceContentRemaining","reason":"SomeResourcesRemain","message":"Some resources are remaining: configmaps. has 1 resource instances"}
{"type":"NamespaceFinalizersRemaining","reason":"SomeFinalizersRemain","message":"Some content in the namespace has finalizers remaining: cours.exemple/archivage in 1 resource instances"}
configmap/archive
```

Les conditions du namespace disent ce qui bloque[^namespace] : il reste des objets (`NamespaceContentRemaining`), et ils ont des finaliseurs (`NamespaceFinalizersRemaining`), avec le nom du finaliseur. La boucle sur `api-resources` liste tout ce qui reste dans le namespace, tous types confondus, ce que `kubectl get all` ne fait pas (il ignore les ConfigMaps, les Secrets et les ressources personnalisées). On retire le finaliseur de l'objet en cause, et le contrôleur des namespaces termine seul :

```bash
kubectl -n ch49-fin patch cm archive --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
kubectl get ns ch49-fin
```

```sortie
configmap/archive patched
Error from server (NotFound): namespaces "ch49-fin" not found
```

On trouve sur Internet une recette qui retire le finaliseur `kubernetes` du namespace lui-même, par la sous-ressource `finalize`. Elle fait disparaître le namespace, mais laisse les objets orphelins dans etcd, avec leurs finaliseurs, invisibles et toujours là. Ne l'utilisez pas : réglez la cause, objet par objet.

</details>

## Nettoyer

```bash
kubectl delete namespace ch49 ch49-quota ch49-init
```

Si vous avez interrompu le chapitre avant la panne 13, retirez d'abord le finaliseur de `regles-tarifaires` (section précédente), sinon le namespace `ch49` restera bloqué, exactement comme dans l'exercice 4. L'étiquette `disque=nvme` a déjà été retirée du nœud.

[^ordonnancement]: Kubernetes, « Resource Management for Pods and Containers » : le scheduler s'assure que la somme des requests des conteneurs placés reste inférieure à la capacité allouable du nœud, quelle que soit la consommation réelle ; limites de mémoire appliquées par le noyau (OOM). [kubernetes.io/docs/concepts/configuration/manage-resources-containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
[^images]: Kubernetes, « Images », section « ImagePullBackOff » : délai croissant entre les tentatives de téléchargement, plafonné à 5 minutes. [kubernetes.io/docs/concepts/containers/images](https://kubernetes.io/docs/concepts/containers/images/)
[^configmap]: Kubernetes, « ConfigMaps » : une ConfigMap référencée par un volume ou une variable doit exister avant le démarrage du Pod, sauf si la référence est marquée `optional`. [kubernetes.io/docs/concepts/configuration/configmap](https://kubernetes.io/docs/concepts/configuration/configmap/)
[^memoire]: Kubernetes, « Assign Memory Resources to Containers and Pods » : un conteneur qui dépasse sa limite de mémoire devient candidat à l'arrêt, raison `OOMKilled` ; exemple avec `stress` et une limite de 100 Mio. [kubernetes.io/docs/tasks/configure-pod-container/assign-memory-resource](https://kubernetes.io/docs/tasks/configure-pod-container/assign-memory-resource/)
[^eviction]: Kubernetes, « Node-pressure Eviction » : seuils d'éviction du kubelet (`memory.available`), ordre d'éviction selon la consommation par rapport aux requests et la priorité, et interaction avec l'OOM killer du noyau. [kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/)
[^resize]: Kubernetes, « Resize CPU and Memory Resources assigned to Containers » : redimensionnement en place par la sous-ressource `resize`, `resizePolicy` par ressource. [kubernetes.io/docs/tasks/configure-pod-container/resize-container-resources](https://kubernetes.io/docs/tasks/configure-pod-container/resize-container-resources/)
[^redemarrage]: Kubernetes, « Pod Lifecycle », sections « Container restart policy » et « Container restarts » : `restartPolicy` Always, OnFailure ou Never ; les Pods d'un Deployment n'admettent que Always. [kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/)
[^sondes]: Kubernetes, « Configure Liveness, Readiness and Startup Probes » : la sonde de démarrage désactive les deux autres jusqu'à son premier succès ; `failureThreshold` × `periodSeconds` donne le temps de démarrage maximal. [kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)
[^netpol]: Kubernetes, « Network Policies » : une politique `Egress` qui sélectionne un Pod n'autorise que les sorties listées, y compris vers le DNS du cluster. [kubernetes.io/docs/concepts/services-networking/network-policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
[^finaliseurs]: Kubernetes, « Finalizers » : `deletionTimestamp`, suppression effective quand le champ `finalizers` est vide, risques de la suppression manuelle d'un finaliseur. [kubernetes.io/docs/concepts/overview/working-with-objects/finalizers](https://kubernetes.io/docs/concepts/overview/working-with-objects/finalizers/)
[^namespace]: Kubernetes, référence de l'API `Namespace` : conditions `NamespaceDeletionDiscoveryFailure`, `NamespaceDeletionContentFailure`, `NamespaceContentRemaining`, `NamespaceFinalizersRemaining`. [kubernetes.io/docs/reference/kubernetes-api/cluster-resources/namespace-v1](https://kubernetes.io/docs/reference/kubernetes-api/cluster-resources/namespace-v1/)
[^quota]: Kubernetes, « Resource Quotas » : avec un quota sur `requests.memory` ou `limits.memory`, chaque nouveau Pod doit déclarer la valeur correspondante, sinon sa création est refusée. [kubernetes.io/docs/concepts/policy/resource-quotas](https://kubernetes.io/docs/concepts/policy/resource-quotas/)
[^init]: Kubernetes, « Init Containers » : exécution séquentielle, chacun devant réussir ; en cas d'échec, relance selon la `restartPolicy` du Pod ; états `Init:N/M`, `Init:Error`, `Init:CrashLoopBackOff`. [kubernetes.io/docs/concepts/workloads/pods/init-containers](https://kubernetes.io/docs/concepts/workloads/pods/init-containers/)
