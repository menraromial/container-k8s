---
title: Le stockage
sidebar_label: 25. Le stockage
description: "Donner aux Pods des données qui leur survivent : les volumes et leur durée de vie, PersistentVolume et PersistentVolumeClaim, StorageClass et provisionnement dynamique, modes d'accès, pilotes CSI, agrandissement et instantanés, puis le PostgreSQL de Colis sur un volume persistant."
partie: 4
chapitre: '25'
---

import pvPvcClasse from '@site/src/figures/pv-pvc-classe.svg';
import sequenceCsi from '@site/src/figures/sequence-csi.svg';

Au chapitre 24, il a suffi de supprimer le Pod de PostgreSQL pour que Colis perde tous ses colis. Le Deployment en a recréé un aussitôt, l'application est revenue, et la liste était vide. Rien d'anormal pourtant : un conteneur écrit dans sa couche inscriptible (chapitre 10), qui disparaît avec lui, et le volume `emptyDir` qu'on avait monté sur `/var/lib/postgresql` disparaît avec le Pod. Aucun des deux n'est fait pour garder des données.

Une base de données, un dépôt de fichiers envoyés par les utilisateurs, la file d'un courtier de messages ont besoin d'un stockage qui survive au Pod, qui le suive si le scheduler le place ailleurs, et qu'on puisse commander sans savoir de quel disque il s'agit. Kubernetes répond par une chaîne d'objets : le volume, déclaré dans le Pod ; la demande de stockage, `PersistentVolumeClaim`, écrite par celui qui déploie l'application ; le volume persistant, `PersistentVolume`, qui représente un vrai morceau de stockage ; la classe de stockage, `StorageClass`, qui sait en fabriquer à la demande ; et, derrière elle, un pilote qui parle au système de stockage réel. Ce chapitre les parcourt dans cet ordre, en regardant à chaque fois où les octets atterrissent sur le nœud.

Les manifestes sont dans [l'archive stockage](pathname:///kits/stockage.tar.gz).

```bash
kubectl create namespace ch25
kubectl config set-context --current --namespace=ch25
```

## Les volumes d'un Pod

Un volume est un répertoire accessible aux conteneurs d'un Pod. On le déclare une fois, dans `spec.volumes`, puis chaque conteneur qui en a besoin le monte à l'endroit de son choix, avec `volumeMounts`[^volumes]. Vous en avez déjà croisé deux sortes : les ConfigMaps et les Secrets montés en fichiers (chapitre 21), et le volume `projected` que Kubernetes ajoute à chaque Pod pour son jeton d'accès à l'API. Ce qui distingue les sortes de volumes, c'est d'où vient leur contenu et combien de temps il vit.

### emptyDir : le brouillon du Pod

Un `emptyDir` naît vide quand le Pod est placé sur un nœud, et disparaît quand le Pod est supprimé. Il sert de brouillon partagé entre les conteneurs d'un même Pod : un cache, des fichiers intermédiaires, une socket. Le Pod `brouillon` a deux conteneurs : l'un ajoute l'heure à un journal toutes les cinq secondes, l'autre monte le même volume en lecture seule, ailleurs.

```yaml title="brouillon.yaml"
spec:
  terminationGracePeriodSeconds: 2   # busybox en PID 1 ignore SIGTERM (chapitre 22)
  containers:
  - name: ecrivain
    image: busybox:1.37
    command: ["sh", "-c", "while [ ! -f /brouillon/stop ]; do date -u +%T >> /brouillon/journal.txt; sleep 5; done; rm /brouillon/stop; exit 1"]
    volumeMounts:
    - name: brouillon
      mountPath: /brouillon
  - name: lecteur
    image: busybox:1.37
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: brouillon
      mountPath: /lecture
      readOnly: true
  volumes:
  - name: brouillon
    emptyDir:
      sizeLimit: 50Mi
```

```bash
kubectl apply -f brouillon.yaml
kubectl wait --for=condition=Ready pod/brouillon
sleep 12
kubectl exec brouillon -c lecteur -- cat /lecture/journal.txt
kubectl exec brouillon -c lecteur -- sh -c 'echo test > /lecture/essai'
```

```sortie
11:34:01
11:34:06
11:34:11
sh: can't create /lecture/essai: Read-only file system
command terminated with exit code 1
```

Le lecteur voit ce que l'écrivain écrit, sous un autre chemin, et ne peut pas y écrire. Où se trouve ce répertoire ? Sur le nœud, le kubelet range les volumes de chaque Pod dans un dossier qui porte l'identifiant unique du Pod, son `uid` :

```bash
U=$(kubectl get pod brouillon -o jsonpath='{.metadata.uid}')
minikube ssh -- "sudo ls -l /var/lib/kubelet/pods/$U/volumes/ /var/lib/kubelet/pods/$U/volumes/kubernetes.io~empty-dir/brouillon"
kubectl exec brouillon -c ecrivain -- sh -c 'mount | grep brouillon'
```

```sortie
/var/lib/kubelet/pods/b090d92c-1a3c-4ab4-af85-4e288c6b0498/volumes/:
total 8
drwxr-xr-x 3 root root 4096 Sep 26 11:34 kubernetes.io~empty-dir
drwxr-xr-x 3 root root 4096 Sep 26 11:34 kubernetes.io~projected

/var/lib/kubelet/pods/b090d92c-1a3c-4ab4-af85-4e288c6b0498/volumes/kubernetes.io~empty-dir/brouillon:
total 4
-rw-r--r-- 1 root root 27 Sep 26 11:34 journal.txt
/dev/mapper/ubuntu--vg-ubuntu--lv on /brouillon type ext4 (rw,relatime)
```

Un `emptyDir` n'est rien d'autre qu'un dossier du nœud, monté dans les conteneurs par un montage *bind* (chapitre 8). Il est sur le disque du nœud, ici un volume logique de votre poste, puisque le nœud minikube est lui-même un conteneur Docker. Il survit au redémarrage d'un conteneur. Le script de l'écrivain s'arrête avec le code 1 quand il trouve un fichier `stop`, ce qui provoque un redémarrage :

```bash
kubectl exec brouillon -c ecrivain -- touch /brouillon/stop
sleep 8
kubectl get pod brouillon
kubectl exec brouillon -c lecteur -- sh -c 'wc -l < /lecture/journal.txt; head -2 /lecture/journal.txt'
```

```sortie
NAME        READY   STATUS    RESTARTS     AGE
brouillon   2/2     Running   1 (6s ago)   22s
5
11:34:01
11:34:06
```

Le conteneur a redémarré, et le journal a gardé ses premières lignes. Le `sizeLimit` de 50 Mio, lui, n'est pas une limite du système de fichiers : rien n'empêche d'écrire au-delà. C'est le kubelet qui mesure régulièrement la place occupée et qui expulse le Pod s'il dépasse :

```bash
kubectl exec brouillon -c ecrivain -- dd if=/dev/zero of=/brouillon/gros bs=1M count=60
sleep 60; kubectl get pod brouillon
```

```sortie
62914560 bytes (60.0MB) copied, 0.039335 seconds, 1.5GB/s
NAME        READY   STATUS   RESTARTS      AGE
brouillon   0/2     Error    1 (44s ago)   60s
```

```bash
kubectl get pod brouillon -o jsonpath='{.status.reason}{": "}{.status.message}{"\n"}'
```

```sortie
Evicted: Usage of EmptyDir volume "brouillon" exceeds the limit "50Mi".
```

L'écriture a réussi, et le Pod a été expulsé 37 secondes plus tard (entre 30 et 75 secondes selon les essais : le kubelet ne mesure pas en continu). Ses conteneurs sont arrêtés, le dossier du volume est déjà vidé, et le Pod reste là, en `Error`, pour qu'on puisse lire la raison. Si c'était un Pod d'un Deployment, le ReplicaSet en créerait un autre, avec un brouillon vide. Quand on supprime enfin le Pod, le kubelet efface tout son dossier `/var/lib/kubelet/pods/<uid>` :

```bash
kubectl delete pod brouillon
minikube ssh -- "sudo test -d /var/lib/kubelet/pods/$U && echo toujours là || echo dossier du Pod supprimé"
```

```sortie
pod "brouillon" deleted from ch25 namespace
dossier du Pod supprimé
```

### emptyDir en mémoire

Avec `medium: Memory`, l'`emptyDir` devient un système de fichiers en mémoire, un `tmpfs`. Les lectures et les écritures y sont bien plus rapides, et rien n'est écrit sur le disque, ce qui compte pour des fichiers sensibles. Mais cette mémoire n'est pas gratuite : ce qu'on y écrit est compté dans la mémoire du conteneur qui l'écrit, et donc dans sa limite (chapitre 23). Le Pod `memoire` a une limite de 64 Mio :

```bash
kubectl apply -f memoire.yaml
kubectl exec memoire -- df -h /rapide
kubectl exec memoire -- dd if=/dev/zero of=/rapide/a bs=1M count=40
kubectl exec memoire -- dd if=/dev/zero of=/rapide/b bs=1M count=40; echo "code $?"
kubectl get pod memoire
kubectl get pod memoire -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'
kubectl exec memoire -- ls -l /rapide
```

```sortie
Filesystem                Size      Used Available Use% Mounted on
tmpfs                    64.0M         0     64.0M   0% /rapide
41943040 bytes (40.0MB) copied, 0.018711 seconds, 2.1GB/s
command terminated with exit code 137
code 137
NAME      READY   STATUS    RESTARTS     AGE
memoire   1/1     Running   1 (3s ago)   4s
OOMKilled
total 60456
-rw-r--r--    1 root     root      41943040 Sep 26 11:35 a
-rw-r--r--    1 root     root      19963904 Sep 26 11:35 b
```

Le `tmpfs` a pris la taille de la limite du conteneur, 64 Mio. Le premier fichier de 40 Mio est passé ; le second a fait dépasser la limite, et le noyau a tué le conteneur (code 137, `OOMKilled`). Le conteneur a redémarré, mais le volume, lui, appartient au Pod : les 60 Mio sont toujours là, toujours comptés, et le nouveau conteneur n'a plus que 4 Mio de marge. Un cache en mémoire mal surveillé peut ainsi faire tomber son Pod en boucle.

```bash
kubectl delete pod memoire
```

### hostPath : le dossier du nœud, et ses dangers

Un volume `hostPath` monte un chemin choisi du système de fichiers du nœud. Il sert aux composants système qui doivent lire le nœud : un collecteur de journaux lit `/var/log`, un pilote de stockage manipule `/var/lib/kubelet`. Pour une application, c'est presque toujours une mauvaise idée : les données restent sur un nœud précis, que le Pod quittera au prochain déplacement, et surtout, le Pod accède au nœud lui-même. Voyez ce que donne un Pod ordinaire qui monte la racine du nœud :

```yaml title="hote.yaml"
  volumes:
  - name: racine
    hostPath:
      path: /
      type: Directory
```

```bash
kubectl apply -f hote.yaml
kubectl exec hote -- cat /hote/etc/hostname
kubectl exec hote -- head -3 /hote/etc/shadow
kubectl exec hote -- sh -c 'ls /hote/var/lib/kubelet/pods | wc -l'
```

```sortie
minikube
root:*:20647:0:99999:7:::
daemon:*:20647:0:99999:7:::
bin:*:20647:0:99999:7:::
35
```

Le conteneur tourne en `root`, et lit le fichier des mots de passe du nœud, les dossiers des 35 Pods que ce nœud a hébergés, avec leurs volumes et leurs Secrets montés. Il pourrait aussi y écrire. Un `hostPath` donne à qui peut créer un Pod les clés du nœud : c'est pourquoi les règles de sécurité des Pods (partie VI) l'interdisent dans les namespaces ordinaires.

```bash
kubectl delete pod hote
```

## PersistentVolume et PersistentVolumeClaim

Pour des données qui doivent survivre au Pod, il faut un stockage dont la vie ne dépende pas du Pod. Kubernetes sépare deux rôles[^pv]. Celui qui administre le cluster sait quels disques existent : il les décrit par des objets `PersistentVolume` (PV), qui appartiennent au cluster entier, sans namespace. Celui qui déploie une application sait de quoi elle a besoin : il écrit une `PersistentVolumeClaim` (PVC), une demande, dans le namespace de l'application. Un contrôleur de l'API server, le contrôleur des volumes persistants, cherche un PV qui convient à chaque demande et lie les deux. Le Pod, enfin, ne nomme que la demande.

Cette séparation a le même but que celle du Deployment et du Pod : le manifeste de l'application ne dit pas « le disque `sdb` de telle machine », il dit « 500 Mio en lecture-écriture », et reste le même d'un cluster à l'autre.

### Un volume créé à la main

Jouons d'abord l'administrateur. Le PV `disque-1` décrit 1 Gio de stockage, qui est ici un simple dossier du nœud minikube, `/data/disque-1` (minikube conserve `/data` d'un redémarrage à l'autre[^minikube-pv]) :

```yaml title="pv-statique.yaml"
apiVersion: v1
kind: PersistentVolume
metadata:
  name: disque-1
spec:
  capacity:
    storage: 1Gi
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath:
    path: /data/disque-1
    type: DirectoryOrCreate
```

Puis le développeur, avec une demande de 500 Mio :

```yaml title="pvc-statique.yaml"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: donnees
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 500Mi
  storageClassName: ""
```

Le `storageClassName: ""` vide, des deux côtés, a un sens précis : « pas de classe, ne te lie qu'à un PV existant ». Sans cette ligne, la demande recevrait la classe par défaut du cluster et ferait créer un volume neuf, comme on le verra plus loin.

```bash
kubectl apply -f pv-statique.yaml
kubectl get pv disque-1
kubectl apply -f pvc-statique.yaml
kubectl get pvc donnees
kubectl get pv disque-1
kubectl get pv disque-1 -o jsonpath='{.spec.claimRef}'; echo
```

```sortie
persistentvolume/disque-1 created
NAME       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      CLAIM   STORAGECLASS   VOLUMEATTRIBUTESCLASS   REASON   AGE
disque-1   1Gi        RWO            Retain           Available                          <unset>                          0s
persistentvolumeclaim/donnees created
NAME      STATUS   VOLUME     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
donnees   Bound    disque-1   1Gi        RWO                           <unset>                 2s
NAME       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM          STORAGECLASS   VOLUMEATTRIBUTESCLASS   REASON   AGE
disque-1   1Gi        RWO            Retain           Bound    ch25/donnees                  <unset>                          2s
{"apiVersion":"v1","kind":"PersistentVolumeClaim","name":"donnees","namespace":"ch25","resourceVersion":"47155","uid":"1d3dcc88-31a2-4521-8444-c83cfe886d17"}
```

La demande est liée (`Bound`) en moins de deux secondes. Notez sa capacité : 1 Gio, et non les 500 Mio demandés. Le contrôleur choisit le plus petit PV qui satisfait la demande, et la demande reçoit tout le PV : un PV n'est jamais partagé entre deux demandes. Le lien est inscrit des deux côtés : `spec.volumeName` dans la PVC, et `spec.claimRef` dans le PV, avec l'`uid` de la demande. C'est un lien exclusif et durable, qui ne se défait pas tout seul.

Le Pod `carnet` monte la demande, ajoute une ligne à un carnet et l'affiche :

```yaml title="carnet.yaml"
  volumes:
  - name: donnees
    persistentVolumeClaim:
      claimName: donnees
```

```bash
kubectl apply -f carnet.yaml
kubectl delete pod carnet
kubectl apply -f carnet.yaml
kubectl logs carnet
minikube ssh -- 'ls -l /data/disque-1'
```

```sortie
11:35:19 carnet
11:35:23 carnet
total 4
-rw-r--r-- 1 root root 32 Sep 26 11:35 carnet.txt
```

Le second Pod a trouvé la ligne du premier. Cette fois, les données ne sont plus dans le dossier du Pod, mais dans `/data/disque-1`, que la suppression du Pod n'a pas touché.

<Figure svg={pvPvcClasse} num="25.1" alt="Deux colonnes. À gauche, le provisionnement statique : dans le namespace ch25, le Pod carnet nomme la PVC donnees (500Mi, RWO, classe vide) ; à l'échelle du cluster, l'administrateur a créé le PV disque-1 (1Gi, RWO, Retain), que le contrôleur des volumes lie à la PVC ; le PV désigne le dossier du nœud /data/disque-1. À droite, le provisionnement dynamique : le Pod remplisseur nomme la PVC petit (10Mi, RWO, classe standard) ; 1, la PVC nomme la StorageClass standard, dont le provisioner est k8s.io/minikube-hostpath ; 2, le provisioner crée le PV pvc-7a75f93a (10Mi, RWO, Delete) ; 3, le PV est lié à la PVC ; il désigne le dossier /tmp/hostpath-provisioner/ch25/petit.">
Les deux façons d'obtenir un volume persistant. Le Pod et la demande vivent dans le namespace de l'application ; le PV et la StorageClass appartiennent au cluster. Objets et chemins relevés sur le cluster du cours.
</Figure>

### Supprimer la demande

Que devient le PV quand on n'a plus besoin de la demande ? Supprimons-la pendant que le Pod l'utilise encore :

```bash
kubectl delete pvc donnees --wait=false
kubectl get pvc donnees
kubectl get pvc donnees -o jsonpath='{.metadata.finalizers}{"\n"}'
```

```sortie
persistentvolumeclaim "donnees" deleted from ch25 namespace
NAME      STATUS        VOLUME     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
donnees   Terminating   disque-1   1Gi        RWO                           <unset>                 10s
["kubernetes.io/pvc-protection"]
```

La demande est marquée pour suppression, mais reste là, en `Terminating`. Un *finalizer*, `kubernetes.io/pvc-protection`, la retient : tant qu'un Pod l'utilise, un contrôleur refuse de la laisser partir, pour que la suppression d'une demande n'arrache pas un volume à une base de données en marche. La partie V montrera comment fonctionnent les finalizers ; retenez ici le symptôme, une PVC bloquée en `Terminating`, et sa cause, un Pod qui l'utilise encore. Supprimez le Pod :

```bash
kubectl delete pod carnet
kubectl get pvc donnees
kubectl get pv disque-1
```

```sortie
pod "carnet" deleted from ch25 namespace
Error from server (NotFound): persistentvolumeclaims "donnees" not found
NAME       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS     CLAIM          STORAGECLASS   VOLUMEATTRIBUTESCLASS   REASON   AGE
disque-1   1Gi        RWO            Retain           Released   ch25/donnees                  <unset>                          17s
```

La demande est partie. Le PV, lui, est `Released` : libéré, mais pas disponible. Sa politique de récupération, `persistentVolumeReclaimPolicy: Retain`, dit de garder le volume et son contenu ; il reste attaché, par son `claimRef`, à une demande qui n'existe plus. C'est une sécurité : ce volume contient peut-être les données d'une autre équipe, et Kubernetes ne le donnera pas à la première demande venue. Recréez la même demande :

```bash
kubectl apply -f pvc-statique.yaml
kubectl get pvc donnees
kubectl describe pvc donnees | sed -n '/^Events:/,$p'
```

```sortie
persistentvolumeclaim/donnees created
NAME      STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
donnees   Pending                                                     <unset>                 5s
Events:
  Type    Reason         Age              From                         Message
  ----    ------         ----             ----                         -------
  Normal  FailedBinding  2s (x2 over 5s)  persistentvolume-controller  no persistent volumes available for this claim and no storage class is set
```

Même nom, même namespace, mais un autre `uid` : pour le contrôleur, c'est une autre demande, et `disque-1` n'est pas disponible. C'est à l'administrateur de décider que le volume peut resservir, en effaçant le lien :

```bash
kubectl patch pv disque-1 --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'
kubectl get pvc donnees -w
```

```sortie
persistentvolume/disque-1 patched
```

```sortie
NAME      STATUS   VOLUME     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
donnees   Bound    disque-1   1Gi        RWO                           <unset>                 20s
```

Le PV est redevenu `Available`, et la demande en attente s'y est liée 14 secondes plus tard : le contrôleur réexamine les demandes en attente à intervalle régulier, pas à chaque changement. Le carnet a gardé ses lignes :

```bash
kubectl apply -f carnet.yaml
kubectl logs carnet
```

```sortie
11:35:19 carnet
11:35:23 carnet
11:35:53 carnet
```

L'autre politique, `Delete`, supprime le volume et ses données avec la demande. On la rencontre partout dans la suite, car c'est celle des volumes créés à la demande. La troisième, `Recycle`, qui effaçait le contenu pour rendre le volume réutilisable, est dépréciée.

### Les modes d'accès

Une demande précise comment elle compte utiliser le volume. Quatre modes existent[^pv] :

| Mode | Abréviation | Sens |
|---|---|---|
| `ReadWriteOnce` | RWO | lecture-écriture, par les Pods d'**un seul nœud** à la fois |
| `ReadOnlyMany` | ROX | lecture seule, par plusieurs nœuds |
| `ReadWriteMany` | RWX | lecture-écriture, par plusieurs nœuds |
| `ReadWriteOncePod` | RWOP | lecture-écriture, par **un seul Pod** du cluster |

Ce que le mode peut valoir dépend du stockage. Un disque en mode bloc (un disque de machine virtuelle dans un nuage, un volume iSCSI) ne s'attache qu'à une machine à la fois : il offre RWO et RWOP. Un système de fichiers en réseau (NFS, CephFS) peut offrir RWX. Le piège est dans le mot « Once » : RWO limite à **un nœud**, pas à un Pod. Deux Pods placés sur le même nœud peuvent monter le même volume RWO et y écrire ensemble, ce que la section sur CSI vérifiera. Pour garantir un seul Pod, il faut RWOP, disponible depuis Kubernetes 1.29 pour les volumes CSI[^rwop].

### Les pannes courantes

:::panne[Une PVC reste Pending]

`kubectl describe pvc` donne la raison dans ses événements. Les trois plus fréquentes : aucun PV ne convient à une demande sans classe (`no persistent volumes available for this claim and no storage class is set` : capacité trop grande, mode d'accès ou classe différents) ; la classe nommée n'existe pas (`storageclass.storage.k8s.io "rapide" not found`, voir plus loin) ; ou la classe attend un Pod avant de créer le volume (`waiting for first consumer to be created before binding`), ce qui est normal et se règle en créant le Pod.

:::

:::panne[Une PVC reste Terminating]

Un Pod utilise encore la demande. `kubectl get pods -o json | jq -r '.items[] | select(.spec.volumes[]?.persistentVolumeClaim.claimName=="donnees") | .metadata.name'` le trouve. Supprimez le Pod, ou le Deployment qui le recrée, et la demande part. Retirer le finalizer à la main « marche » aussi, mais arrache le volume à un Pod qui s'en sert.

:::

## Les StorageClasses et le provisionnement dynamique

Créer des PV à la main ne tient pas longtemps. Il faudrait deviner à l'avance combien de volumes de quelle taille les équipes vont demander, et un administrateur passerait ses journées à en créer. Le provisionnement dynamique renverse le problème : la demande nomme une classe de stockage, et un programme, le *provisioner* de cette classe, crée un volume sur mesure pour elle[^classes].

minikube installe une classe, `standard`, marquée comme classe par défaut :

```bash
kubectl get storageclass
kubectl get storageclass standard -o jsonpath='{.provisioner} {.reclaimPolicy} {.volumeBindingMode}{"\n"}'
```

```sortie
NAME                 PROVISIONER                RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION   AGE
standard (default)   k8s.io/minikube-hostpath   Delete          Immediate           false                  26h
k8s.io/minikube-hostpath Delete Immediate
```

Une StorageClass tient en quelques champs. Le `provisioner` nomme le programme qui crée les volumes : ici, le petit provisioner de minikube, qui tourne dans le Pod `storage-provisioner` de `kube-system` et crée des dossiers sur le nœud. La `reclaimPolicy` sera celle des PV créés : `Delete`. Le `volumeBindingMode` dit quand créer le volume : `Immediate`, dès que la demande apparaît. Les `parameters`, absents ici, se transmettent au provisioner (type de disque, nombre de réplicas, système de fichiers...), et chaque provisioner a les siens. Sur un cluster géré dans un nuage, vous trouverez des classes nommées d'après le type de disque, SSD ou non, répliqué ou non ; c'est tout l'intérêt de la classe : la demande dit « du rapide » ou « du bon marché », sans rien savoir du reste.

Une demande de 10 Mio dans la classe `standard` :

```yaml title="pvc-dynamique.yaml"
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 10Mi
  storageClassName: standard
```

```bash
kubectl apply -f pvc-dynamique.yaml
kubectl get pvc petit
kubectl get pv $(kubectl get pvc petit -o jsonpath='{.spec.volumeName}')
kubectl get pv $(kubectl get pvc petit -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.hostPath.path}{"\n"}'
```

```sortie
NAME    STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
petit   Bound    pvc-7a75f93a-a079-49ac-8ac4-a6eeb86afe75   10Mi       RWO            standard       <unset>                 3s
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM        STORAGECLASS   VOLUMEATTRIBUTESCLASS   REASON   AGE
pvc-7a75f93a-a079-49ac-8ac4-a6eeb86afe75   10Mi       RWO            Delete           Bound    ch25/petit   standard       <unset>                          3s
/tmp/hostpath-provisioner/ch25/petit
```

Personne n'a écrit de PV : le provisioner en a créé un, nommé d'après l'`uid` de la demande, exactement à la taille demandée, avec la politique `Delete` de sa classe, et un dossier `/tmp/hostpath-provisioner/<namespace>/<demande>` sur le nœud. Comme `/data`, ce dossier survit aux redémarrages de minikube.

Ce provisioner est fait pour apprendre, pas pour la production, et le Pod `remplisseur` montre sa principale limite. Il écrit 100 Mio dans ce volume de 10 Mio :

```bash
kubectl apply -f remplisseur.yaml
kubectl logs remplisseur
```

```sortie
100+0 records in
100+0 records out
104857600 bytes (100.0MB) copied, 0.126482 seconds, 790.6MB/s
total 102400
-rw-r--r--    1 root     root     104857600 Sep 26 11:35 gros
```

Rien ne l'en empêche : un dossier n'a pas de taille. La capacité d'un PV est une étiquette que Kubernetes compare aux demandes ; c'est le stockage réel qui l'applique, ou non. Un vrai disque de 10 Gio refusera d'écrire le onzième gigaoctet, un dossier `hostPath` le laissera faire jusqu'à remplir le disque du nœud. Supprimons maintenant la demande :

```bash
kubectl delete pod remplisseur
kubectl delete pvc petit
kubectl get pv pvc-7a75f93a-a079-49ac-8ac4-a6eeb86afe75
minikube ssh -- 'ls /tmp/hostpath-provisioner/ch25/'
```

```sortie
pod "remplisseur" deleted from ch25 namespace
persistentvolumeclaim "petit" deleted from ch25 namespace
Error from server (NotFound): persistentvolumes "pvc-7a75f93a-a079-49ac-8ac4-a6eeb86afe75" not found
```

Avec la politique `Delete`, le PV a disparu, et le provisioner a effacé le dossier : `ls` ne trouve plus rien. Les 100 Mio sont perdus, comme le seraient les données d'une base. C'est la valeur par défaut des classes dynamiques ; l'exercice 1 montre comment garder les volumes.

### La classe par défaut, et la classe qui n'existe pas

Une demande sans `storageClassName` reçoit la classe marquée par l'annotation `storageclass.kubernetes.io/is-default-class: "true"`, ici `standard`. C'est commode, et c'est un piège pour qui voulait se lier à un PV créé à la main : il faut alors écrire `storageClassName: ""`, comme plus haut. Une demande qui nomme une classe inexistante, elle, attend indéfiniment, et le Pod qui l'utilise aussi :

```bash
kubectl apply -f pvc-rapide.yaml
kubectl describe pvc rapide | sed -n '/^Events:/,$p'
```

```sortie
Events:
  Type     Reason              Age              From                         Message
  ----     ------              ----             ----                         -------
  Warning  ProvisioningFailed  5s (x2 over 5s)  persistentvolume-controller  storageclass.storage.k8s.io "rapide" not found
```

Le Pod `attente`, qui utilise cette demande, reste `Pending`, et le scheduler dit pourquoi :

```sortie
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  5s    default-scheduler  0/1 nodes are available: pod has unbound immediate PersistentVolumeClaims. not found
```

Le message du scheduler ne parle que d'une demande non liée ; c'est l'événement de la demande qui donne la vraie cause. Quand un Pod attend à cause d'un volume, remontez toujours jusqu'à la PVC.

```bash
kubectl delete pod attente
kubectl delete pvc rapide
```

## CSI, l'interface des pilotes de stockage

Les premières versions de Kubernetes contenaient, dans leur propre code, un pilote pour chaque système de stockage : disques AWS, GCE, Azure, Cinder, iSCSI, Ceph, Portworx... Chaque correction d'un pilote attendait une version de Kubernetes, et chaque fournisseur devait faire entrer son code dans le projet. La *Container Storage Interface* (CSI), publiée en 2017 et commune à Kubernetes, Mesos et Cloud Foundry, a sorti les pilotes du cœur : elle définit un petit ensemble d'appels gRPC (`CreateVolume`, `DeleteVolume`, `ControllerPublishVolume`, `NodePublishVolume`, `CreateSnapshot`...) qu'un pilote implémente dans ses propres conteneurs[^csi]. Kubernetes a ensuite migré ses anciens pilotes intégrés vers leurs équivalents CSI, puis les a retirés de son code[^migration]. Aujourd'hui, tout stockage sérieux passe par un pilote CSI.

minikube fournit un pilote CSI de démonstration, qui crée lui aussi des dossiers sur le nœud, mais par le vrai chemin CSI, avec les instantanés et l'agrandissement[^minikube-csi]. Activez-le, avec le contrôleur d'instantanés :

```bash
minikube addons enable volumesnapshots
minikube addons enable csi-hostpath-driver
kubectl -n kube-system get pods | grep -E 'csi|snapshot'
```

```sortie
csi-hostpath-attacher-0                1/1     Running   0                9m26s
csi-hostpath-resizer-0                 1/1     Running   0                9m26s
csi-hostpathplugin-57xs6               6/6     Running   0                9m26s
snapshot-controller-7d8dd4dd5d-wmk9b   1/1     Running   0                9m30s
snapshot-controller-7d8dd4dd5d-wvt42   1/1     Running   0                9m30s
```

Les deux addons ajoutent environ 320 Mio au cluster. Le Pod `csi-hostpathplugin` réunit six conteneurs :

```bash
kubectl -n kube-system get pod -l app.kubernetes.io/name=csi-hostpathplugin -o jsonpath='{range .items[0].spec.containers[*]}{.name}{"\n"}{end}'
```

```sortie
csi-external-health-monitor-controller
node-driver-registrar
hostpath
liveness-probe
csi-provisioner
csi-snapshotter
```

Un seul, `hostpath`, est le pilote proprement dit : il implémente les appels CSI et ne connaît rien de Kubernetes. Les autres sont des *sidecars* génériques, écrits par le projet Kubernetes et réutilisés par tous les pilotes : ils surveillent l'API server et traduisent ce qu'ils y voient en appels CSI. `csi-provisioner` surveille les PVC de ses classes et appelle `CreateVolume` ; `csi-snapshotter` fait de même pour les instantanés ; les Pods `csi-hostpath-attacher` et `csi-hostpath-resizer` portent les sidecars qui attachent et agrandissent les volumes. `node-driver-registrar` annonce le pilote au kubelet du nœud. Tous parlent au pilote par une socket Unix, rangée dans un dossier du nœud que le kubelet connaît :

```bash
kubectl get csidriver
kubectl get csinode minikube -o jsonpath='{.spec.drivers[*].name}{"\n"}'
minikube ssh -- 'sudo ls /var/lib/kubelet/plugins/csi-hostpath /var/lib/kubelet/plugins_registry'
```

```sortie
NAME                  ATTACHREQUIRED   PODINFOONMOUNT   STORAGECAPACITY   TOKENREQUESTS   REQUIRESREPUBLISH   MODES                  AGE
hostpath.csi.k8s.io   false            true             true              <unset>         false               Persistent,Ephemeral   9m26s
hostpath.csi.k8s.io
/var/lib/kubelet/plugins/csi-hostpath:
csi.sock

/var/lib/kubelet/plugins_registry:
hostpath.csi.k8s.io-reg.sock
```

L'objet `CSIDriver` décrit le pilote au cluster ; `ATTACHREQUIRED false` dit qu'il n'y a pas d'étape d'attachement (un dossier ne s'attache pas à une machine, contrairement à un disque réseau). L'objet `CSINode` liste les pilotes présents sur chaque nœud.

### Un volume créé à la première utilisation

Pour ce pilote, créons une classe à nous, avec deux réglages que la classe de l'addon n'a pas :

```yaml title="classe-csi.yaml"
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: csi-attente
provisioner: hostpath.csi.k8s.io
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

`WaitForFirstConsumer` retarde la création du volume jusqu'à ce qu'un Pod l'utilise. Sur un cluster de plusieurs nœuds répartis dans plusieurs zones, c'est indispensable : un disque créé tout de suite, en `Immediate`, pourrait l'être dans une zone où le Pod ne peut pas aller ; en attendant le Pod, le volume est créé là où le scheduler l'a placé. Appliquez la classe, puis la demande seule :

```bash
kubectl apply -f classe-csi.yaml
sed -n '1,/^---/p' journal.yaml | head -n -1 | kubectl apply -f -
kubectl get pvc journal
kubectl describe pvc journal | sed -n '/^Events:/,$p'
```

```sortie
NAME      STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
journal   Pending                                      csi-attente    <unset>                 4s
Events:
  Type    Reason                Age   From                         Message
  ----    ------                ----  ----                         -------
  Normal  WaitForFirstConsumer  4s    persistentvolume-controller  waiting for first consumer to be created before binding
```

La demande attend, et c'est normal. Ajoutez le Pod, puis relisez les événements des deux objets, qui portent le même nom, dans l'ordre où ils ont été écrits :

```bash
kubectl apply -f journal.yaml
kubectl get pvc journal
kubectl get events --field-selector involvedObject.name=journal --sort-by=.metadata.resourceVersion \
  -o custom-columns=OBJET:.involvedObject.kind,RAISON:.reason,SOURCE:.source.component
kubectl get pvc journal -o jsonpath='{.metadata.annotations.volume\.kubernetes\.io/selected-node}{"\n"}'
```

```sortie
NAME      STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
journal   Bound    pvc-d705110b-af10-4597-851d-87ce3e0a6d15   100Mi      RWO            csi-attente    <unset>                 6s
OBJET                   RAISON                  SOURCE
PersistentVolumeClaim   WaitForFirstConsumer    persistentvolume-controller
PersistentVolumeClaim   Provisioning            hostpath.csi.k8s.io
PersistentVolumeClaim   ExternalProvisioning    persistentvolume-controller
PersistentVolumeClaim   ProvisioningSucceeded   hostpath.csi.k8s.io
Pod                     Scheduled               <none>
Pod                     Pulled                  kubelet
Pod                     Created                 kubelet
Pod                     Started                 kubelet
minikube
```

Le déroulé est celui de la figure 25.2. Le scheduler a choisi un nœud pour le Pod, mais au lieu de l'y affecter, il a inscrit son choix sur la demande, dans l'annotation `volume.kubernetes.io/selected-node`. Le sidecar `csi-provisioner` l'a vue, a appelé `CreateVolume` sur la socket du pilote, puis a créé le PV. Une fois la demande liée, le scheduler a affecté le Pod (`Scheduled`), et le kubelet a démarré le conteneur. Entre-temps, le kubelet a demandé au pilote, par l'appel `NodePublishVolume`, de monter le volume dans le dossier du Pod : un montage *bind* de `/var/lib/csi-hostpath-data/<identifiant>` sur `/var/lib/kubelet/pods/<uid>/volumes/kubernetes.io~csi/<pv>/mount`, qui est ensuite monté dans le conteneur. Tout a pris deux secondes.

<Figure svg={sequenceCsi} num="25.2" alt="Diagramme de séquence entre kubectl, l'API server, le scheduler, le sidecar csi-provisioner, le pilote hostpath (ces deux derniers dans le Pod csi-hostpathplugin) et le kubelet. 1, kubectl crée la PVC journal puis le Pod journal. 2, l'API server transmet le Pod à placer au scheduler. 3, le scheduler inscrit selected-node=minikube sur la PVC. 4, le csi-provisioner voit la PVC à provisionner. 5, il appelle CreateVolume sur le pilote. 6, il crée le PV, lié à la PVC. 7, le scheduler écrit nodeName = minikube. 8, le kubelet reçoit le Pod pour son nœud. 9, il appelle NodePublishVolume sur le pilote, qui monte le volume dans /var/lib/kubelet/pods/uid/volumes/kubernetes.io~csi/, puis le conteneur démarre. Les appels au pilote passent en gRPC par la socket /var/lib/kubelet/plugins/csi-hostpath/csi.sock.">
Un volume CSI en mode <code>WaitForFirstConsumer</code>, du Pod au montage. Le pilote ne parle jamais à l'API server : les sidecars et le kubelet font l'intermédiaire. Ordre tiré des événements du cluster du cours.
</Figure>

### RWO n'est pas « un seul Pod »

Le Pod `journal-bis` monte la même demande `journal`, en `ReadWriteOnce`, et ajoute sa ligne :

```bash
kubectl apply -f journal-bis.yaml
kubectl get pods journal journal-bis -o wide
kubectl exec journal -- cat /journal/journal.txt
```

```sortie
NAME          READY   STATUS    RESTARTS   AGE   IP             NODE       NOMINATED NODE 
journal       1/1     Running   0          4s    10.244.0.195   minikube   <none>         
journal-bis   1/1     Running   0          1s    10.244.0.196   minikube   <none>         
11:36:21 première ligne
11:36:23 ligne du second Pod
```

Deux Pods, sur le même nœud, écrivent dans le même volume RWO. Pour un fichier journal, passe encore ; pour deux serveurs PostgreSQL, ce serait la corruption assurée. Avec `ReadWriteOncePod`, le second Pod ne démarre pas :

```bash
kubectl apply -f unique.yaml
kubectl get pods premier second
kubectl describe pod second | sed -n '/^Events:/,$p'
```

```sortie
NAME      READY   STATUS    RESTARTS   AGE
premier   1/1     Running   0          10s
second    0/1     Pending   0          10s
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  10s   default-scheduler  0/1 nodes are available: 1 node(s) unavailable due to PersistentVolumeClaim with ReadWriteOncePod access mode already in-use by another pod. preemption: 0/1 nodes are available: 1 No preemption victims found for incoming pod.
```

C'est le scheduler qui applique la règle, avant même de chercher un nœud. `second` démarrera dès que `premier` sera supprimé.

### Agrandir un volume

Un volume trop petit peut grandir si sa classe l'autorise (`allowVolumeExpansion: true`). On modifie la demande, jamais le PV :

```bash
kubectl patch pvc journal -p '{"spec":{"resources":{"requests":{"storage":"200Mi"}}}}'
kubectl get pvc journal -w
```

```sortie
NAME      STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
journal   Bound    pvc-d705110b-af10-4597-851d-87ce3e0a6d15   200Mi      RWO            csi-attente    <unset>                 71s
```

```bash
kubectl get events --field-selector involvedObject.kind=PersistentVolumeClaim,involvedObject.name=journal \
  --sort-by=.metadata.resourceVersion -o custom-columns=RAISON:.reason,MESSAGE:.message | tail -4
```

```sortie
ExternalExpanding            waiting for an external controller to expand this PVC
VolumeResizeFailed           Mark PVC "ch25/journal" as file system resize required failed: can't patch status of  PVC ch25/journal with Operation cannot be ful...
Resizing                     External resizer is resizing volume pvc-d705110b-af10-4597-851d-87ce3e0a6d15
FileSystemResizeSuccessful   MountVolume.NodeExpandVolume succeeded for volume "pvc-d705110b-af10-4597-851d-87ce3e0a6d15" minikube
```

L'agrandissement se fait en deux temps : le sidecar `csi-resizer` agrandit le volume côté stockage (`ControllerExpandVolume`), puis le kubelet agrandit le système de fichiers sur le nœud (`NodeExpandVolume`), et c'est seulement alors que la capacité de la demande passe à 200 Mio. Ici, il a fallu 53 secondes, dont un échec en chemin : le sidecar a voulu modifier la demande en même temps qu'un autre composant, a perdu la course (`Operation cannot be fulfilled`, la concurrence optimiste que la partie V détaillera) et a réessayé. On ne rétrécit jamais un volume : Kubernetes refuse une demande plus petite que la capacité actuelle.

### Les instantanés

Un instantané (*VolumeSnapshot*) fige le contenu d'un volume à un instant donné, et permet d'en créer un volume neuf[^instantanes]. C'est la base des sauvegardes et des copies de données pour les tests. Trois objets suivent le même schéma que les volumes : `VolumeSnapshot` (la demande, dans le namespace), `VolumeSnapshotContent` (l'instantané réel, à l'échelle du cluster) et `VolumeSnapshotClass` (qui dit quel pilote le fait). L'addon a créé la classe `csi-hostpath-snapclass`.

```yaml title="instantane.yaml"
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: journal-1
spec:
  volumeSnapshotClassName: csi-hostpath-snapclass
  source:
    persistentVolumeClaimName: journal
```

Ajoutons une ligne avant l'instantané, et une après :

```bash
kubectl exec journal -- sh -c 'echo "$(date -u +%T) avant instantané" >> /journal/journal.txt'
kubectl apply -f instantane.yaml
kubectl wait --for=jsonpath='{.status.readyToUse}'=true volumesnapshot/journal-1
kubectl get volumesnapshot journal-1
kubectl exec journal -- sh -c 'echo "$(date -u +%T) après instantané" >> /journal/journal.txt'
minikube ssh -- 'sudo ls /var/lib/csi-hostpath-data/'
```

```sortie
NAME        READYTOUSE   SOURCEPVC   SOURCESNAPSHOTCONTENT   RESTORESIZE   SNAPSHOTCLASS            SNAPSHOTCONTENT                                    CREATIONTIME   AGE
journal-1   true         journal                             200Mi         csi-hostpath-snapclass   snapcontent-1aa9a3c9-e8e4-4c85-8d22-f6406422f8aa   0s             0s
7e1e18a1-b99e-11f1-b442-66d737fa4c2b  a60fe347-b99e-11f1-b442-66d737fa4c2b.snap
80631ee0-b99e-11f1-b442-66d737fa4c2b  state.json
```

Pour ce pilote, un instantané est une archive du dossier, le fichier `.snap`. Sur un vrai système de stockage, c'est en général une copie à la volée (*copy-on-write*) prise en une fraction de seconde, quelle que soit la taille du volume. On restaure en créant une demande dont la source de données, `dataSource`, est l'instantané :

```yaml title="restaure.yaml"
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 200Mi   # au moins la taille de l'instantané (RESTORESIZE)
  storageClassName: csi-attente
  dataSource:
    apiGroup: snapshot.storage.k8s.io
    kind: VolumeSnapshot
    name: journal-1
```

```bash
kubectl apply -f restaure.yaml
kubectl logs lecteur-restaure
```

```sortie
11:36:21 première ligne
11:36:23 ligne du second Pod
11:37:26 avant instantané
```

Le volume restauré contient le journal tel qu'il était à l'instant de l'instantané : la ligne « après instantané » n'y est pas.

:::panne[Restaurer un instantané dans une demande trop petite]

La demande de restauration doit être au moins aussi grande que le volume au moment de l'instantané, sa colonne `RESTORESIZE`. Le volume avait été agrandi à 200 Mio ; une demande de 100 Mio reste `Pending`, et le provisioner s'en explique :

```sortie
failed to provision volume with StorageClass "csi-attente": error getting handle for DataSource Type VolumeSnapshot by Name journal-1: requested volume size 104857600 is less than the size 209715200 for the source snapshot journal-1
```

Supprimez la demande et recréez-la avec la bonne taille : une demande liée ne change pas de source.

:::

## PostgreSQL de Colis sur un volume persistant

Revenons au problème du début. Le kit contient une nouvelle version de `20-postgres.yaml` pour Colis : une demande de 1 Gio dans la classe `standard`, et le Deployment qui la monte à la place de l'`emptyDir`.

```yaml title="colis/20-postgres.yaml"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-donnees
  namespace: colis
  labels:
    app.kubernetes.io/name: postgres
    app.kubernetes.io/part-of: colis
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: standard
---
# ... le Deployment, inchangé, sauf son volume :
      volumes:
      - name: donnees
        persistentVolumeClaim:
          claimName: postgres-donnees
```

La stratégie `Recreate` du Deployment prend ici tout son sens. Avec la stratégie progressive, le nouveau Pod démarrerait pendant que l'ancien tourne encore, et deux serveurs PostgreSQL ouvriraient les mêmes fichiers : le volume est RWO, et les deux Pods seraient sur le même nœud, donc rien ne l'empêcherait.

```bash
kubectl apply -f colis/20-postgres.yaml
kubectl -n colis rollout status deployment/postgres
kubectl -n colis get pvc
```

```sortie
persistentvolumeclaim/postgres-donnees created
deployment.apps/postgres configured
service/postgres unchanged
deployment "postgres" successfully rolled out
NAME               STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
postgres-donnees   Bound    pvc-9f4ca66d-071e-4fc4-bf6a-73de70bd44e6   1Gi        RWO            standard       <unset>                 6s
```

Ce changement a remplacé le Pod de PostgreSQL, et le nouveau est parti d'un volume vide : les colis de l'ancien `emptyDir` sont perdus une dernière fois. Et, comme au chapitre 24, l'API et le worker ont perdu leur connexion à la base sans savoir en ouvrir une autre. Il faut les redémarrer :

```bash
kubectl -n colis rollout restart deployment/api deployment/worker
kubectl -n colis rollout status deployment/api
```

Enregistrez un colis, puis rejouez la panne du chapitre 24 :

```bash
IP=192.168.49.100
curl -s -X POST http://$IP/api/colis -H 'Content-Type: application/json' \
  -d '{"destinataire":"Margaret Hamilton","depart":"Nantes","arrivee":"Strasbourg","poids_kg":3.1}' >/dev/null
sleep 4; curl -s http://$IP/api/colis | jq -c '[.[] | {id, destinataire, statut}]'
kubectl -n colis delete pod -l app.kubernetes.io/name=postgres
kubectl -n colis rollout status deployment/postgres
kubectl -n colis rollout restart deployment/api deployment/worker
kubectl -n colis rollout status deployment/api
sleep 5; curl -s http://$IP/api/colis | jq -c '[.[] | {id, destinataire, statut}]'
```

```sortie
[{"id":1,"destinataire":"Margaret Hamilton","statut":"estimé"}]
pod "postgres-6558546766-5p5ql" deleted from colis namespace
deployment "postgres" successfully rolled out
deployment.apps/api restarted
deployment.apps/worker restarted
deployment "api" successfully rolled out
[{"id":1,"destinataire":"Margaret Hamilton","statut":"estimé"}]
```

Le colis a survécu à la perte du Pod. Le nouveau PostgreSQL a retrouvé ses fichiers dans le dossier du volume :

```bash
minikube ssh -- 'sudo du -sh /tmp/hostpath-provisioner/colis/postgres-donnees; sudo ls /tmp/hostpath-provisioner/colis/postgres-donnees/18/docker | head -4'
```

```sortie
47M	/tmp/hostpath-provisioner/colis/postgres-donnees
PG_VERSION
base
global
pg_commit_ts
```

Deux faiblesses demeurent. L'application ne sait toujours pas rouvrir sa connexion, et il faut redémarrer l'API après chaque redémarrage de la base ; juste après ce redémarrage, une requête peut même tomber sur un ancien Pod de l'API, dont la connexion est morte, et recevoir une erreur 500. Et un Deployment ne convient pas vraiment à une base : si on lui demandait deux répliques, les deux monteraient le même volume. Le chapitre 26 passe PostgreSQL dans un StatefulSet, fait pour cela.

## Exercices

:::exercice[Exercice 1 : garder les volumes dynamiques]

Créez une StorageClass `standard-garde`, identique à `standard` mais qui garde les volumes quand on supprime la demande. Créez une demande dans cette classe, écrivez un fichier dans le volume, supprimez la demande : que deviennent le PV et le fichier ? Comment redonner ce volume à une nouvelle demande ?

:::

<details>
<summary>Corrigé</summary>

```yaml title="standard-garde.yaml"
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: standard-garde
provisioner: k8s.io/minikube-hostpath
reclaimPolicy: Retain
```

Avec une demande `garde` de 10 Mio dans cette classe, un Pod qui écrit `précieux` dans le volume, puis la suppression du Pod et de la demande :

```sortie
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS     CLAIM        STORAGECLASS     VOLUMEATTRIBUTESCLASS   REASON   AGE
pvc-309ded3a-9d5e-4d72-ac21-46cbf9c53544   10Mi       RWO            Retain           Released   ch25/garde   standard-garde   <unset>                          9s
```

```bash
minikube ssh -- 'cat /tmp/hostpath-provisioner/ch25/garde/fichier'
```

```sortie
précieux
```

Le PV reste, `Released`, avec ses données. On ne peut pas changer la politique d'une classe existante (ses champs sont immuables), mais on peut changer celle d'un PV déjà créé : `kubectl patch pv <nom> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'` protège un volume précieux avant une opération risquée. Pour redonner le volume, il faut, comme pour `disque-1`, retirer son `claimRef`, puis créer une demande de la même classe et d'une taille compatible ; pour la lier à ce PV précisément, et pas à un volume neuf, la demande peut le nommer dans `spec.volumeName`. Une fois le volume inutile, c'est à vous de supprimer le PV **et** le dossier : `kubectl delete pv` ne touche pas aux données d'un volume `Retain`.

</details>

:::exercice[Exercice 2 : quel volume pour quel usage ?]

Pour chacun de ces besoins, quel type de volume choisiriez-vous, et pourquoi ?
1. les vignettes d'images que l'API recalcule si elles manquent ;
2. une socket Unix par laquelle un conteneur principal parle à un sidecar ;
3. les données de Redis, si la file ne doit pas perdre ses messages ;
4. un fichier de configuration de nginx ;
5. un agent qui lit les journaux de tous les conteneurs d'un nœud.

:::

<details>
<summary>Corrigé</summary>

1. Un `emptyDir`, éventuellement avec un `sizeLimit` : c'est un cache, qu'on peut perdre sans dommage. En mémoire (`medium: Memory`) si la vitesse compte, en l'incluant dans la limite mémoire du conteneur.
2. Un `emptyDir`, partagé par les deux conteneurs du Pod : c'est son usage type.
3. Une PVC, en `ReadWriteOnce` (ou `ReadWriteOncePod` avec un pilote CSI), dans un StatefulSet (chapitre 26), avec la persistance de Redis activée : sans elle, Redis ne garde ses données qu'en mémoire, et le volume ne sert à rien.
4. Une ConfigMap montée en fichier (chapitre 21).
5. Un `hostPath` en lecture seule sur `/var/log`, dans un DaemonSet (chapitre 27) pour avoir un agent par nœud. C'est l'un des rares usages légitimes de `hostPath`, réservé à des namespaces système.

</details>

:::exercice[Exercice 3 : un instantané de la base de Colis]

Avant une migration risquée, on veut prendre un instantané du volume `postgres-donnees` de Colis avec la classe `csi-hostpath-snapclass`. Écrivez le manifeste, appliquez-le, et expliquez le résultat. Que faudrait-il changer pour que cela fonctionne ?

:::

<details>
<summary>Corrigé</summary>

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: postgres-1
  namespace: colis
spec:
  volumeSnapshotClassName: csi-hostpath-snapclass
  source:
    persistentVolumeClaimName: postgres-donnees
```

```bash
kubectl -n colis get volumesnapshot postgres-1
kubectl -n colis get volumesnapshot postgres-1 -o jsonpath='{.status.error.message}{"\n"}'
```

```sortie
NAME         READYTOUSE   SOURCEPVC          SOURCESNAPSHOTCONTENT   RESTORESIZE   SNAPSHOTCLASS            SNAPSHOTCONTENT   CREATIONTIME   AGE
postgres-1   false        postgres-donnees                                         csi-hostpath-snapclass                                    8s
Failed to create snapshot content with error cannot find CSI PersistentVolumeSource for volume pvc-9f4ca66d-071e-4fc4-bf6a-73de70bd44e6
```

L'instantané ne sera jamais prêt : le volume de Colis a été créé par le provisioner `k8s.io/minikube-hostpath`, qui n'est pas un pilote CSI, et le contrôleur d'instantanés ne sait prendre des instantanés que de volumes CSI. Un instantané est toujours pris par le pilote qui gère le volume. Il faudrait que la demande de Colis utilise une classe CSI, `csi-hostpath-sc` ou `csi-attente`, ce qui impose de recréer le volume et d'y recopier les données (un `pg_dump` puis un `pg_restore`, par exemple). Supprimez l'instantané en échec : `kubectl -n colis delete volumesnapshot postgres-1`.

Notez aussi qu'un instantané d'un volume de base de données pris pendant que la base écrit n'est cohérent qu'au sens d'une coupure de courant : PostgreSQL saura le rejouer, mais les outils de sauvegarde propres à la base, ou un opérateur comme CloudNativePG (partie VIII), font mieux.

</details>

## Nettoyer

Les objets du chapitre vivent dans le namespace `ch25`, sauf le PV `disque-1`, les classes `csi-attente` et `standard-garde`, et le PV gardé par l'exercice 1, qui appartiennent au cluster. Les volumes `Retain` gardent leurs dossiers sur le nœud : il faut les effacer à la main.

```bash
kubectl delete namespace ch25
kubectl delete pv disque-1
kubectl get pv -o json | jq -r '.items[] | select(.spec.storageClassName=="standard-garde") | .metadata.name' | xargs -r kubectl delete pv
kubectl delete storageclass csi-attente standard-garde
minikube ssh -- 'sudo rm -rf /data/disque-1 /tmp/hostpath-provisioner/ch25'
kubectl config set-context --current --namespace=default
```

Gardez Colis avec sa nouvelle demande : le chapitre 26 part de là. Les addons `csi-hostpath-driver` et `volumesnapshots` peuvent rester ; pour libérer leurs 320 Mio :

```bash
minikube addons disable csi-hostpath-driver
minikube addons disable volumesnapshots
```

[^volumes]: Kubernetes, « Volumes », sections *emptyDir*, *hostPath* et *emptyDir configuration example*. [kubernetes.io/docs/concepts/storage/volumes](https://kubernetes.io/docs/concepts/storage/volumes/)

[^pv]: Kubernetes, « Persistent Volumes », sections *Lifecycle of a volume and claim*, *Reclaiming*, *Access Modes* et *Storage Object in Use Protection*. [kubernetes.io/docs/concepts/storage/persistent-volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)

[^minikube-pv]: minikube, « Persistent Volumes », qui liste les dossiers conservés d'un redémarrage à l'autre (`/data`, `/tmp/hostpath-provisioner`...). [minikube.sigs.k8s.io/docs/handbook/persistent_volumes](https://minikube.sigs.k8s.io/docs/handbook/persistent_volumes/)

[^rwop]: Kubernetes Enhancement Proposal 2485, « ReadWriteOncePod PersistentVolume Access Mode », stable depuis Kubernetes 1.29. [github.com/kubernetes/enhancements/tree/master/keps/sig-storage/2485-read-write-once-pod-pv-access-mode](https://github.com/kubernetes/enhancements/tree/master/keps/sig-storage/2485-read-write-once-pod-pv-access-mode)

[^classes]: Kubernetes, « Storage Classes » et « Dynamic Volume Provisioning », sections *Volume binding mode* et *Allow volume expansion*. [kubernetes.io/docs/concepts/storage/storage-classes](https://kubernetes.io/docs/concepts/storage/storage-classes/)

[^csi]: Container Storage Interface, spécification. [github.com/container-storage-interface/spec/blob/master/spec.md](https://github.com/container-storage-interface/spec/blob/master/spec.md) ; et la documentation des développeurs de pilotes, qui décrit les sidecars. [kubernetes-csi.github.io/docs](https://kubernetes-csi.github.io/docs/)

[^migration]: Kubernetes Blog, « Kubernetes 1.23: Kubernetes In-Tree to CSI Volume Migration Status Update », 10 décembre 2021. [kubernetes.io/blog/2021/12/10/storage-in-tree-to-csi-migration-status-update](https://kubernetes.io/blog/2021/12/10/storage-in-tree-to-csi-migration-status-update/)

[^minikube-csi]: minikube, « CSI Driver and Volume Snapshots ». [minikube.sigs.k8s.io/docs/tutorials/volume_snapshots_and_csi](https://minikube.sigs.k8s.io/docs/tutorials/volume_snapshots_and_csi/)

[^instantanes]: Kubernetes, « Volume Snapshots ». [kubernetes.io/docs/concepts/storage/volume-snapshots](https://kubernetes.io/docs/concepts/storage/volume-snapshots/)
