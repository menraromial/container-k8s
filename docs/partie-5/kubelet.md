---
title: Le kubelet et le CRI
sidebar_label: 38. Le kubelet et le CRI
description: "De l'objet Pod aux processus sur le nœud : la configuration du kubelet, l'interface CRI et crictl, le bac à sable et le conteneur pause, les espaces de noms partagés, les cgroups qui portent requests et limits, le redémarrage d'un conteneur, les Pods statiques, et un nœud privé de son kubelet."
partie: 5
chapitre: '38'
---

import kubeletChaine from '@site/src/figures/kubelet-chaine.svg';
import noeudInjoignable from '@site/src/figures/noeud-injoignable.svg';

Un nœud passe `NotReady`, ou `Unknown`. Dans le tableau de bord, ses Pods deviennent non prêts les uns après les autres. Faut-il en conclure que les applications de ce nœud sont tombées ? La plupart des gens répondent oui, et ce n'est presque jamais le cas. Le plus souvent, c'est le **kubelet** qui ne donne plus de nouvelles : l'agent de Kubernetes sur ce nœud s'est arrêté, ou ne joint plus l'API server. Les conteneurs, eux, continuent de tourner, et de servir leurs clients. On le vérifiera en fin de chapitre, en arrêtant le kubelet d'un nœud pendant une minute.

Pour comprendre pourquoi, il faut suivre le chemin qui mène d'un objet Pod, dans l'API, à des processus Linux, sur un nœud. Le kubelet est au début de ce chemin, mais il n'est pas le parent des processus qu'il fait naître : il demande à un **runtime de conteneurs** de les créer, par une interface appelée **CRI**, et ce runtime s'appuie sur les mécanismes de la partie II : les espaces de noms (chapitre 8), les cgroups (chapitre 9) et runc (chapitre 11). Ce chapitre descend ce chemin, avec `crictl`, l'outil qui parle au runtime comme le fait le kubelet.

On reste sur le profil `deux-noeuds` du chapitre 37, et l'on travaille sur le nœud de travail, `deux-noeuds-m02`. Les fichiers sont dans [l'archive kubelet](pathname:///kits/kubelet.tar.gz).

```bash
kubectl create namespace ch38
kubectl config set-context --current --namespace=ch38
```

## Un agent par nœud

Le kubelet est un programme ordinaire, lancé par systemd sur chaque nœud. Il n'est pas dans un conteneur, puisque c'est lui qui les fait démarrer. Sa configuration est dans un fichier, `/var/lib/kubelet/config.yaml`, et on peut la lire sans se connecter au nœud : l'API server relaie vers chaque kubelet des requêtes sous le chemin `/api/v1/nodes/<nœud>/proxy/`, et le kubelet expose sa configuration effective sous `configz`.

```bash
minikube ssh -p deux-noeuds -n deux-noeuds-m02 -- ps -o pid,rss,args -C kubelet | cut -c1-80
kubectl get --raw /api/v1/nodes/deux-noeuds-m02/proxy/configz | jq '.kubeletconfig | {staticPodPath, fileCheckFrequency, syncFrequency, nodeStatusUpdateFrequency, cgroupDriver, containerRuntimeEndpoint, maxPods, evictionHard}'
```

```sortie
    PID   RSS COMMAND
  32248 86020 /var/lib/minikube/binaries/v1.37.0/kubelet --bootstrap-kubeconfig=
{
  "staticPodPath": "/etc/kubernetes/manifests",
  "fileCheckFrequency": "20s",
  "syncFrequency": "1m0s",
  "nodeStatusUpdateFrequency": "10s",
  "cgroupDriver": "systemd",
  "containerRuntimeEndpoint": "unix:///run/containerd/containerd.sock",
  "maxPods": 110,
  "evictionHard": {
    "imagefs.available": "0%",
    "nodefs.available": "0%",
    "nodefs.inodesFree": "0%"
  }
}
```

84 Mio de mémoire pour le kubelet, et une configuration dont chaque ligne sera utile dans ce chapitre. `containerRuntimeEndpoint` est la prise par laquelle il parle au runtime, containerd. `cgroupDriver: systemd` dit qu'il range les cgroups des Pods sous l'arborescence gérée par systemd. `staticPodPath` et `fileCheckFrequency` concernent les Pods statiques, plus bas. `nodeStatusUpdateFrequency` règle la fréquence de ses nouvelles. `maxPods` limite à 110 le nombre de Pods du nœud, une limite que le scheduler respecte. Et `evictionHard` à 0 % est un choix de minikube : sur un vrai nœud, le kubelet commence à évincer des Pods quand le disque passe sous 10 % d'espace libre, ou la mémoire sous 100 Mio ; minikube désactive les seuils de disque, pour ne pas vider un nœud de TP dès que le disque du poste se remplit[^eviction].

Le kubelet est lui aussi un contrôleur, au sens du chapitre 36. Il surveille les Pods dont `spec.nodeName` est son propre nœud, compare leur description à ce qui tourne réellement, et agit pour réduire l'écart : démarrer un conteneur absent, en arrêter un qui ne devrait plus être là, redémarrer celui qui s'est arrêté. Sa vue du monde, il l'expose aussi :

```bash
kubectl get --raw /api/v1/nodes/deux-noeuds-m02/proxy/pods | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)"'
```

```sortie
kube-system/kube-proxy-qcrvg
kube-system/kindnet-f6lz9
ch38/suivi
```

Trois Pods sur ce nœud : les deux DaemonSets du réseau (chapitres 39 et 40), et le Pod `suivi` de la section suivante (j'ai lancé cette commande une fois ce Pod créé), qu'on va suivre jusqu'au bout.

## L'interface CRI

Pendant ses premières années, Kubernetes parlait directement à Docker. Puis d'autres runtimes sont apparus (rkt, CRI-O, containerd seul), et plutôt que d'écrire du code pour chacun dans le kubelet, Kubernetes a défini en 2016 une interface, la **Container Runtime Interface** : un service gRPC, que tout runtime peut implémenter, et que le kubelet appelle sans savoir qui répond. Docker, qui ne l'implémentait pas, est resté branché par un adaptateur intégré au kubelet, le *dockershim*, jusqu'à son retrait dans Kubernetes 1.24, en 2022[^dockershim]. Les nœuds de minikube utilisent containerd, qui implémente la CRI par un greffon intégré.

`crictl` est un client de cette interface, fait pour le diagnostic. Il envoie au runtime les mêmes appels que le kubelet, ce qui en fait l'outil idéal pour voir ce que le kubelet voit :

```bash
minikube ssh -p deux-noeuds -n deux-noeuds-m02 -- sudo crictl version
```

```sortie
Version:  0.1.0
RuntimeName:  containerd
RuntimeVersion:  v2.3.4
RuntimeApiVersion:  v1
```

Les appels de la CRI se lisent comme une recette[^cri]. `RunPodSandbox` crée le **bac à sable** du Pod : ses espaces de noms partagés, son réseau, son cgroup. `PullImage` tire une image. `CreateContainer` et `StartContainer` créent puis lancent chaque conteneur dans le bac à sable. `StopPodSandbox` et `RemovePodSandbox` font le chemin inverse. C'est ce vocabulaire qu'on retrouve dans `crictl` : `crictl pods` liste les bacs à sable, `crictl ps` les conteneurs.

## Du Pod aux processus

Le Pod à suivre est épinglé sur le nœud de travail, avec des requests et des limits dont on retrouvera la trace :

```yaml title="suivi.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: suivi
spec:
  nodeSelector: {kubernetes.io/hostname: deux-noeuds-m02}
  containers:
  - name: web
    image: registry.k8s.io/e2e-test-images/agnhost:2.61
    args: [netexec, --http-port=8080]
    resources:
      requests: {cpu: 100m, memory: 32Mi}
      limits: {cpu: 200m, memory: 64Mi}
```

Le plus simple, pour les commandes sur le nœud, est de se donner un raccourci :

```bash
N() { minikube ssh -p deux-noeuds -n deux-noeuds-m02 -- "$@" 2>/dev/null | tr -d '\r'; }
kubectl apply -f suivi.yaml
kubectl wait --for=condition=Ready pod/suivi >/dev/null
kubectl get pod suivi -o jsonpath='uid du Pod : {.metadata.uid}{"\n"}'
N 'sudo crictl pods --name suivi --state ready'
N 'sudo crictl ps --name web --pod $(sudo crictl pods --name suivi --state ready -q)'
```

```sortie
pod/suivi created
uid du Pod : 360bb2ad-193e-4b6e-9c6d-61107fb0a803
POD ID              CREATED                  STATE               NAME                NAMESPACE           ATTEMPT             RUNTIME
bb31783846e28       Less than a second ago   Ready               suivi               ch38                0                   (default)
CONTAINER           IMAGE               CREATED                  STATE               NAME                ATTEMPT             POD ID              POD                 NAMESPACE
3d5c4895f4eae       fa5778c85a0bd       Less than a second ago   Running             web                 0                   bb31783846e28       suivi               ch38
```

Pour le runtime, le Pod `suivi` est un bac à sable, `bb31783846e28`, qui contient un conteneur, `web`. Que contient ce bac à sable ?

```bash
S=$(N 'sudo crictl pods --name suivi --state ready -q')
N "sudo crictl inspectp $S" | jq '{image: .info.image, pid: .info.pid, netns: (.info.runtimeSpec.linux.namespaces[] | select(.type=="network") | .path), cgroupsPath: .info.runtimeSpec.linux.cgroupsPath}'
```

```sortie
{
  "image": "registry.k8s.io/pause:3.10.2",
  "pid": 41686,
  "netns": "/var/run/netns/cni-38bcbbab-6b25-5da9-bdaa-5535d28d23b3",
  "cgroupsPath": "kubepods-burstable-pod360bb2ad_193e_4b6e_9c6d_61107fb0a803.slice:cri-containerd:bb31783846e28d9d56a503af69fbbea3683d0030280451bb48f8f469aaeb59dc"
}
```

Un bac à sable a lui aussi une image, `pause`, et un processus, le PID 41686. Il a un espace de noms réseau, créé par le greffon CNI du nœud (chapitre 39), et un cgroup dont le nom contient l'`uid` du Pod. Regardons les processus, et comparons les espaces de noms de `pause` et de notre application :

```bash
C=$(N "sudo crictl ps --name web --pod $S -q")
PP=$(N "sudo crictl inspectp $S" | jq -r .info.pid); PC=$(N "sudo crictl inspect $C" | jq -r .info.pid)
N "ps -o pid,ppid,user,rss,args -p $PP,$PC,\$(ps -o ppid= -p $PP | tr -d ' ')" | cut -c1-80
N "for t in net ipc uts pid mnt; do printf '%-4s pause=%s web=%s\n' \$t \$(sudo readlink /proc/$PP/ns/\$t) \$(sudo readlink /proc/$PC/ns/\$t); done"
```

```sortie
    PID    PPID USER       RSS COMMAND
  41661       1 root     11764 /usr/bin/containerd-shim-runc-v2 -namespace k8s.i
  41686   41661 65535      732 /pause
  41710   41661 root     30932 /agnhost netexec --http-port=8080
net  pause=net:[4026533194] web=net:[4026533194]
ipc  pause=ipc:[4026534005] web=ipc:[4026534005]
uts  pause=uts:[4026534003] web=uts:[4026534003]
pid  pause=pid:[4026534011] web=pid:[4026534456]
mnt  pause=mnt:[4026533998] web=mnt:[4026534012]
```

Trois processus, et aucun n'est un enfant du kubelet. Le parent des deux conteneurs est `containerd-shim-runc-v2`, un petit processus que containerd lance pour chaque Pod, et qui a lui-même été rattaché au PID 1 du nœud. C'est lui qui a appelé runc pour créer chaque conteneur (chapitre 11), qui garde leurs entrées et sorties, et qui recueillera leur code de sortie. Le kubelet et containerd peuvent redémarrer sans que les conteneurs s'en aperçoivent : ce détail explique toute la dernière section.

Les espaces de noms racontent le rôle de `pause`. `web` partage avec lui son réseau, son IPC et son nom d'hôte (UTS), mais a ses propres espaces de PID et de montage. `pause` ne fait rien d'autre qu'exister, sous l'utilisateur 65535 (« personne »), en occupant 732 Kio : il **détient** les espaces de noms du Pod. Les conteneurs de l'application viennent s'y joindre. Si `web` plante et redémarre, il retrouve le même réseau, donc la même adresse IP ; si le Pod avait deux conteneurs, ils se joindraient par `localhost`, puisqu'ils partagent la même pile réseau. La figure 38.1 récapitule la chaîne.

<Figure svg={kubeletChaine} num="38.1" alt="Du Pod aux processus sur le nœud deux-noeuds-m02. 1, le kubelet reçoit par un watch le Pod ch38/suivi, dont le nodeName est deux-noeuds-m02. 2, il appelle containerd par la CRI, en gRPC, sur /run/containerd/containerd.sock : RunPodSandbox, PullImage, CreateContainer, StartContainer. 3, containerd appelle le greffon CNI (commande ADD), qui crée l'adresse, l'interface et l'espace de noms réseau cni-38bc... 4, containerd démarre containerd-shim-runc-v2, un par Pod, qui lance les conteneurs avec runc. Dans le cgroup kubepods-burstable-pod360bb2ad...slice tournent /pause, PID 41686, 732 Kio, qui détient les espaces de noms net, ipc et uts, et /agnhost netexec, PID 41710, dont le cpu.max vaut 20000 100000. 5, le kubelet renvoie le statut du Pod et renouvelle le bail du nœud auprès de l'API server.">
De l'objet Pod aux processus. Le kubelet ne crée rien lui-même : il décrit ce qu'il veut au runtime par la CRI, et le runtime s'appuie sur le greffon CNI et sur runc.
</Figure>

## Les cgroups du Pod

Les requests et les limits du chapitre 23 finissent, elles aussi, dans des fichiers. Le cgroup du conteneur `web` se lit dans `/proc` :

```bash
CG=$(N "cat /proc/$PC/cgroup"); echo "$CG"; D=${CG#0::}
for f in cpu.max cpu.weight memory.max memory.current; do echo "$f : $(N "cat /sys/fs/cgroup$D/$f")"; done
N 'ls -d /sys/fs/cgroup/kubepods.slice/*.slice' | sed 's|/sys/fs/cgroup/||'
```

```sortie
0::/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod360bb2ad_193e_4b6e_9c6d_61107fb0a803.slice/cri-containerd-3d5c4895f4eaeb3ea20389a1685e4f40efdc18cf43012b0776dac669ea6fd0c7.scope
cpu.max : 20000 100000
cpu.weight : 17
memory.max : 67108864
memory.current : 5877760
kubepods.slice/kubepods-besteffort.slice
kubepods.slice/kubepods-burstable.slice
kubepods.slice/kubepods-pode5fae65e_9d78_497d_a205_358740851e44.slice
```

Tout y est, dans l'arborescence et dans les valeurs. Le chemin suit les classes de qualité de service : le Pod `suivi`, dont les requests sont inférieures aux limits, est `Burstable`, et son cgroup est rangé sous `kubepods-burstable.slice`. Les Pods `BestEffort` vont sous la tranche voisine. Les Pods `Guaranteed` n'ont pas de tranche de classe : ils sont directement sous `kubepods.slice`, comme ce `kubepods-pode5fae65e...` qui appartient à un des DaemonSets du nœud. Chaque niveau peut recevoir ses propres réglages, ce qui permet au kubelet de protéger les Pods garantis des autres.

La limite de processeur, 200 millicœurs, est devenue `cpu.max : 20000 100000` : 20 ms de processeur toutes les 100 ms, soit un cinquième de cœur. La limite de mémoire, 64 Mio, est devenue `memory.max`, exactement 67 108 864 octets : c'est ce seuil que le noyau fait respecter en tuant le processus qui le franchit, avec le `OOMKilled` du chapitre 23. La request de processeur, elle, n'est pas une limite : elle devient un **poids**, `cpu.weight`, qui ne compte que lorsque plusieurs cgroups se disputent le processeur. Le runtime a converti les 100 millicœurs demandés en un poids de 17, sur une échelle qui va de 1 à 10 000. Et `memory.current` dit ce que le conteneur utilise vraiment : 5,6 Mio.

## Redémarrer un conteneur

Un conteneur de Pod dont le processus s'arrête est redémarré par le kubelet, selon la `restartPolicy` du Pod (`Always` par défaut). Tuons le processus de `web` sans prévenir, avec `SIGKILL`, directement sur le nœud :

```bash
t0=$(date +%s.%N); N "sudo kill -9 $PC"
until [ "$(kubectl get pod suivi -o jsonpath='{.status.containerStatuses[0].restartCount}')" = 1 ]; do sleep 0.2; done
printf 'restartCount passé à 1 en %.1f s\n' $(echo "$(date +%s.%N)-$t0" | bc)
kubectl get pod suivi -o jsonpath='{.status.containerStatuses[0].lastState}{"\n"}' | jq -c .
N "sudo crictl ps -a --pod $S"
```

```sortie
restartCount passé à 1 en 1.1 s
{"terminated":{"containerID":"containerd://3d5c4895f4eaeb3ea20389a1685e4f40efdc18cf43012b0776dac669ea6fd0c7","exitCode":137,"finishedAt":"2026-09-26T18:32:40Z","reason":"Error","startedAt":"2026-09-26T18:32:31Z"}}
CONTAINER           IMAGE               CREATED                  STATE               NAME                ATTEMPT             POD ID              POD                 NAMESPACE
4e46c26d7bb7a       fa5778c85a0bd       Less than a second ago   Running             web                 1                   bb31783846e28       suivi               ch38
3d5c4895f4eae       fa5778c85a0bd       10 seconds ago           Exited              web                 0                   bb31783846e28       suivi               ch38
```

Un peu plus d'une seconde, et un nouveau conteneur tourne. Le code de sortie, 137, se lit comme au chapitre 2 : 128 + 9, tué par le signal 9. Le shim a recueilli ce code et l'a transmis à containerd ; le kubelet l'a appris par un évènement du runtime, a constaté l'écart avec ce que décrit le Pod, et a demandé un nouveau conteneur (`ATTEMPT 1`), **dans le même bac à sable** (`POD ID` inchangé). Le Pod garde donc son adresse IP. L'ancien conteneur n'est pas supprimé tout de suite : le kubelet garde le dernier conteneur arrêté de chaque conteneur de Pod, ce qui permet à `kubectl logs --previous` de retrouver ses journaux (exercice 3). Si le conteneur s'arrêtait à chaque redémarrage, le kubelet espacerait les tentatives, 10 s, 20 s, 40 s, jusqu'à 5 minutes : c'est l'état `CrashLoopBackOff` du chapitre 17.

## Les Pods statiques

Tout Pod passe par l'API server, sauf un. Le kubelet surveille aussi un dossier du nœud, `staticPodPath`, et lance tout Pod dont il y trouve la description, sans rien demander à personne. C'est ainsi que démarre le plan de contrôle lui-même : l'API server, etcd, le scheduler et le gestionnaire de contrôleurs de minikube sont des fichiers de `/etc/kubernetes/manifests` sur le nœud de contrôle, et c'est en déplaçant l'un d'eux qu'on a arrêté le gestionnaire au chapitre 36. Il faut bien que quelque chose démarre l'API server avant qu'on puisse lui parler.

Déposons un Pod statique sur le nœud de travail :

```yaml title="statique.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: statique
  namespace: ch38
  labels: {app: statique}
spec:
  containers:
  - name: web
    image: registry.k8s.io/e2e-test-images/agnhost:2.61
    args: [netexec, --http-port=8080]
```

```bash
minikube cp -p deux-noeuds statique.yaml deux-noeuds-m02:/etc/kubernetes/manifests/statique.yaml
kubectl get pods -o wide | grep -E 'NAME|statique'
kubectl get pod statique-deux-noeuds-m02 -o json | jq '{annotations: .metadata.annotations, ownerReferences: .metadata.ownerReferences}'
```

```sortie
NAME                       READY   STATUS    RESTARTS     AGE   IP            NODE              NOMINATED NODE
statique-deux-noeuds-m02   1/1     Running   0            4s    10.244.1.57   deux-noeuds-m02   <none>
{
  "annotations": {
    "kubernetes.io/config.hash": "c51796b24d9189bcb2a13b824486a2c8",
    "kubernetes.io/config.mirror": "c51796b24d9189bcb2a13b824486a2c8",
    "kubernetes.io/config.seen": "2026-09-26T18:32:42.337957806Z",
    "kubernetes.io/config.source": "file"
  },
  "ownerReferences": [
    {
      "apiVersion": "v1",
      "controller": true,
      "kind": "Node",
      "name": "deux-noeuds-m02",
      "uid": "aade9e7b-a7a2-4920-b364-0810e9a0bd01"
    }
  ]
}
```

Le Pod est apparu dans l'API, sous un nom suffixé par celui du nœud. Mais ce n'est qu'un reflet : un **Pod miroir**, que le kubelet publie pour que le Pod soit visible avec `kubectl`. L'annotation `config.source: file` dit d'où vient la vraie description, et `config.hash` en est une empreinte. Le propriétaire est le nœud lui-même. Que se passe-t-il si l'on supprime ce reflet ?

```bash
S1=$(N 'sudo crictl pods --name statique --state ready -q')
kubectl delete pod statique-deux-noeuds-m02
sleep 3; kubectl get pods | grep -E 'NAME|statique'
S2=$(N 'sudo crictl pods --name statique --state ready -q')
echo "bac à sable avant : ${S1:0:13}, après : ${S2:0:13}"
```

```sortie
pod "statique-deux-noeuds-m02" deleted from ch38 namespace
NAME                       READY   STATUS    RESTARTS      AGE
statique-deux-noeuds-m02   0/1     Pending   0             3s
bac à sable avant : 736c298cc8de0, après : 736c298cc8de0
```

Le miroir est revenu aussitôt, et le bac à sable sur le nœud est le même : le conteneur n'a pas été touché. Le miroir affiche brièvement `Pending` et `0/1`, le temps que le kubelet y recopie le statut réel. Supprimer un Pod statique par l'API ne sert donc à rien. Le seul moyen est de retirer le fichier :

```bash
N 'sudo rm /etc/kubernetes/manifests/statique.yaml'
kubectl get pods | grep statique || echo 'plus de Pod statique'
```

```sortie
plus de Pod statique
```

## Un nœud sans kubelet

Revenons à la question du début. Le kubelet donne des nouvelles de deux façons. Il met à jour le statut de son objet `Node` (ses conditions, ses ressources) ; et, toutes les 10 secondes, il renouvelle un **bail**, un objet `Lease` du namespace `kube-node-lease`, qui ne sert qu'à dire « je suis vivant ». Le bail est un petit objet, bon marché à réécrire, ce qui permet des signes de vie fréquents sans alourdir etcd avec le statut complet du nœud[^baux]. Arrêtons le kubelet du nœud de travail pendant une minute, et relevons toutes les dix secondes l'état du nœud et celui du Pod `suivi` :

```bash
etat() { echo "+$(( $(date +%s)-t0 )) s : nœud $(kubectl get node deux-noeuds-m02 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'), taints $(kubectl get node deux-noeuds-m02 -o jsonpath='{.spec.taints[*].key}'), Pod suivi $(kubectl get pod suivi -o jsonpath='{.status.phase}/{.status.conditions[?(@.type=="Ready")].status}')"; }
IP=$(kubectl get pod suivi -o jsonpath='{.status.podIP}')
kubectl -n kube-node-lease get lease deux-noeuds-m02 -o jsonpath='bail renouvelé à {.spec.renewTime}, durée {.spec.leaseDurationSeconds} s{"\n"}'
t0=$(date +%s); N 'sudo systemctl stop kubelet'; echo "kubelet arrêté à $(date -u +%T)"
for i in 1 2 3 4 5 6 7; do etat; sleep 10; done
```

```sortie
bail renouvelé à 2026-09-26T18:34:07.122073Z, durée 40 s
kubelet arrêté à 18:34:11
+0 s : nœud True, taints , Pod suivi Running/True
+10 s : nœud True, taints , Pod suivi Running/True
+20 s : nœud True, taints , Pod suivi Running/True
+31 s : nœud True, taints , Pod suivi Running/True
+41 s : nœud True, taints , Pod suivi Running/True
+51 s : nœud Unknown, taints node.kubernetes.io/unreachable node.kubernetes.io/unreachable, Pod suivi Running/False
+61 s : nœud Unknown, taints node.kubernetes.io/unreachable node.kubernetes.io/unreachable, Pod suivi Running/False
```

La fonction `etat` affiche la condition `Ready` du nœud, ses taints, puis la phase et la condition `Ready` du Pod. Pendant plus de quarante secondes, rien ne change : l'API server ne peut pas savoir que le kubelet s'est tu. C'est le **contrôleur du cycle de vie des nœuds**, dans le gestionnaire de contrôleurs, qui s'en aperçoit, en constatant que le bail n'a pas été renouvelé depuis trop longtemps (un délai de grâce d'une cinquantaine de secondes). Il fait alors trois choses : il passe les conditions du nœud à `Unknown`, pose les taints `node.kubernetes.io/unreachable` (en `NoSchedule` et en `NoExecute`, d'où les deux mentions), et marque les Pods du nœud comme non prêts, ce qui les retire des Services. Voici ce qu'il a écrit :

```bash
kubectl -n kube-node-lease get lease deux-noeuds-m02 -o jsonpath='bail renouvelé à {.spec.renewTime}{"\n"}'
kubectl get node deux-noeuds-m02 -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
```

```sortie
bail renouvelé à 2026-09-26T18:34:07.122073Z
MemoryPressure=Unknown (NodeStatusUnknown)
DiskPressure=Unknown (NodeStatusUnknown)
PIDPressure=Unknown (NodeStatusUnknown)
Ready=Unknown (NodeStatusUnknown)
```

Et sur le nœud lui-même ?

```bash
N 'sudo crictl ps --name web --state running' | grep suivi | cut -c1-120
N "curl -s -m 2 http://$IP:8080/hostname"; echo
```

```sortie
4e46c26d7bb7a       fa5778c85a0bd       2 minutes ago       Running             web                 1
suivi
```

Le conteneur tourne, et répond. Pour le cluster, le Pod `suivi` n'est plus prêt ; pour ses clients directs, rien n'a changé. C'est la réponse à la question du début, et la figure 38.2 la met en images.

<Figure svg={noeudInjoignable} num="38.2" alt="Une ligne de temps, en secondes depuis l'arrêt du kubelet. Le dernier renouvellement du bail du nœud a lieu 4 secondes avant l'arrêt, avec une durée de 40 secondes, et plus rien ensuite. Le kubelet est actif, puis arrêté de 0 à 62 secondes, puis relancé. L'état du nœud reste Ready=True jusqu'à environ 51 secondes, parce que personne ne sait encore, puis passe à Unknown, avec les taints unreachable et le Pod Ready=False, puis redevient True après la relance. Le conteneur tourne et répond sans interruption pendant toute la période. Si le nœud était resté injoignable, les Pods, qui tolèrent unreachable pendant 300 secondes, auraient été évincés et recréés ailleurs, alors même que leurs conteneurs tournaient encore.">
Un nœud dont le kubelet s'arrête. Le plan de contrôle ne le remarque qu'au bout d'une cinquantaine de secondes, et le conteneur, lui, ne remarque rien.
</Figure>

Relançons le kubelet :

```bash
t1=$(date +%s); N 'sudo systemctl start kubelet'
kubectl wait --for=condition=Ready node/deux-noeuds-m02 >/dev/null; echo "nœud Ready $(( $(date +%s)-t1 )) s après le redémarrage"
sleep 10; t0=$t1; etat
kubectl get pod suivi -o jsonpath='restartCount={.status.containerStatuses[0].restartCount}{"\n"}'
```

```sortie
nœud Ready 0 s après le redémarrage
+10 s : nœud True, taints , Pod suivi Running/True
restartCount=1
```

Le nœud redevient prêt dès le premier renouvellement du bail, les taints disparaissent, le Pod redevient prêt, et le compteur de redémarrages n'a pas bougé : le conteneur n'a jamais été interrompu. Le kubelet a retrouvé ses conteneurs en interrogeant le runtime, qui les avait gardés.

Que se serait-il passé si le kubelet était resté arrêté ? Le chapitre 34 a montré que chaque Pod reçoit une tolérance de 300 secondes pour le taint `unreachable`. Au bout de ces cinq minutes, le contrôleur des nœuds aurait **évincé** les Pods, et leurs contrôleurs en auraient recréé ailleurs. Mais, faute de kubelet pour les arrêter, les anciens conteneurs auraient continué de tourner sur le nœud isolé. Pour un Deployment sans état, c'est sans conséquence. Pour une base de données en StatefulSet, deux copies qui se croient chacune la seule peuvent corrompre les données ; c'est pourquoi le contrôleur des StatefulSets ne recrée pas un Pod tant que l'ancien n'a pas été confirmé arrêté, quitte à attendre qu'un humain le fasse.

:::panne[Un nœud passe NotReady ou Unknown]

`Unknown` signifie « pas de nouvelles » : le kubelet est arrêté, bloqué, ou ne joint plus l'API server. `NotReady` signifie que le kubelet répond, mais se déclare en mauvais état : runtime de conteneurs injoignable, réseau des Pods pas prêt (greffon CNI absent, chapitre 39), pression sur la mémoire ou le disque. Dans les deux cas, le diagnostic commence sur le nœud, pas dans l'API : `systemctl status kubelet` et `journalctl -u kubelet` pour l'agent, `crictl info` pour le runtime. Et avant de redémarrer quoi que ce soit, vérifiez si les applications répondent encore : c'est souvent le cas, et un redémarrage précipité fait plus de dégâts que le problème lui-même.

:::

## Exercices

:::exercice[Exercice 1 : lire les statistiques du kubelet]

Le kubelet publie, sous `/stats/summary`, la consommation de son nœud et de chaque Pod, mesurée à partir des cgroups ; c'est de là que metrics-server tire les chiffres de `kubectl top`. Écrivez en Python, avec la bibliothèque standard et `kubectl proxy --port=8011`, un programme qui affiche la mémoire utilisée et le processeur de chaque Pod d'un nœud, du plus gourmand au plus sobre.

:::

<details>
<summary>Corrigé</summary>

```python title="stats.py"
noeud = sys.argv[1]
url = f"http://127.0.0.1:8011/api/v1/nodes/{noeud}/proxy/stats/summary"
with urllib.request.urlopen(url) as r:
    resume = json.load(r)

n = resume["node"]
print(f"nœud {noeud} : {n['memory']['workingSetBytes'] / 2**20:.0f} Mio de mémoire utilisée, "
      f"{n['cpu']['usageNanoCores'] / 1e6:.0f} millicœurs")
lignes = []
for pod in resume["pods"]:
    ref = pod["podRef"]
    memoire = pod.get("memory", {}).get("workingSetBytes", 0) / 2**20
    cpu = pod.get("cpu", {}).get("usageNanoCores", 0) / 1e6
    lignes.append((memoire, f"{ref['namespace']}/{ref['name']}", cpu))
for memoire, nom, cpu in sorted(lignes, reverse=True):
    print(f"  {memoire:6.1f} Mio  {cpu:6.1f} m  {nom}")
```

```sortie
nœud deux-noeuds-m02 : 231 Mio de mémoire utilisée, 32 millicœurs
    16.0 Mio     2.1 m  kube-system/kindnet-f6lz9
    15.6 Mio     0.0 m  kube-system/kube-proxy-qcrvg
     6.6 Mio     0.0 m  ch38/suivi
```

La mémoire « utilisée » est le *working set* : la mémoire du cgroup moins les pages de cache que le noyau peut récupérer à tout moment. C'est ce chiffre que le kubelet compare aux seuils d'éviction, et que `kubectl top` affiche. Les 6,6 Mio de `suivi` correspondent au `memory.current` lu plus haut dans son cgroup, à la mise en cache près. La mémoire du nœud (231 Mio) est bien plus que la somme des Pods : elle compte aussi le kubelet, containerd et le système du nœud.

</details>

:::exercice[Exercice 2 : modifier un Pod statique]

Redéposez `statique.yaml` sur le nœud de travail, notez le `config.hash` et l'`uid` du Pod miroir, puis modifiez le fichier **sur le nœud** (par exemple, remplacez le port 8080 par 9090 avec `sed`). Combien de temps faut-il pour que le changement soit pris en compte ? Le conteneur a-t-il été redémarré, ou le Pod remplacé ?

:::

<details>
<summary>Corrigé</summary>

```sortie
hash c51796b24d9189bcb2a13b824486a2c8, args ["netexec","--http-port=8080"], uid a6196019-8cc1-4249-96b1-aabedd629ca2
nouvelle version visible après 13 s
hash 7f1b3ad017c37528b01f0fc614f21a80, args ["netexec","--http-port=9090"], uid c2f07c1c-523d-4267-859d-b8130ce72a6e
POD ID              CREATED             STATE               NAME                       NAMESPACE           ATTEMPT             RUNTIME
f217881920f58       4 seconds ago       Ready               statique-deux-noeuds-m02   ch38                0                   (default)
86332f9ccf1d6       22 seconds ago      NotReady            statique-deux-noeuds-m02   ch38                1                   (default)
```

Le kubelet relit son dossier toutes les 20 secondes (`fileCheckFrequency`) : le changement est vu en 13 s ici, au plus 20 s en général. L'empreinte du fichier a changé, et avec elle l'`uid` du Pod : pour le kubelet, c'est un **autre** Pod. Il a arrêté l'ancien bac à sable (`NotReady`) et en a créé un nouveau, avec une nouvelle adresse. C'est exactement ce qui se passe quand on modifie le manifeste de l'API server ou d'etcd sur un nœud de contrôle : le composant redémarre entièrement. Pensez à retirer le fichier ensuite.

</details>

:::exercice[Exercice 3 : où sont les journaux ?]

Le conteneur `web` du Pod `suivi` a été tué une fois. Retrouvez les journaux de sa première vie de deux façons : avec `kubectl logs --previous`, puis directement sur le nœud, sous `/var/log/pods`. Qui écrit ces fichiers ?

:::

<details>
<summary>Corrigé</summary>

```bash
UID1=$(kubectl get pod suivi -o jsonpath='{.metadata.uid}')
N "sudo ls /var/log/pods/ch38_suivi_$UID1/web/"
kubectl logs suivi --previous | tail -2
N "sudo tail -2 /var/log/pods/ch38_suivi_$UID1/web/0.log"
```

```sortie
0.log  1.log
I0926 18:32:31.166281       1 log.go:244] Started HTTP server on port 8080
I0926 18:32:31.166778       1 log.go:244] Started UDP server on port  8081
2026-09-26T18:32:31.166655881Z stderr F I0926 18:32:31.166281       1 log.go:244] Started HTTP server on port 8080
2026-09-26T18:32:31.166810348Z stderr F I0926 18:32:31.166778       1 log.go:244] Started UDP server on port  8081
```

Un dossier par Pod (`<namespace>_<nom>_<uid>`), un sous-dossier par conteneur, un fichier par vie du conteneur : `0.log` pour la première, `1.log` pour la seconde. C'est le runtime (containerd, par le shim) qui écrit ces fichiers, en ajoutant à chaque ligne un horodatage, le flux d'origine (`stderr`) et une marque de ligne complète (`F`). `kubectl logs` passe par l'API server, qui demande au kubelet de lire ce fichier et d'enlever ces préfixes ; `--previous` lit le fichier de la vie précédente. Ce format est celui de la CRI, et c'est aussi ce que lisent les collecteurs de journaux du chapitre 51, déployés en DaemonSet avec ce dossier monté.

</details>

:::exercice[Exercice 4 : tuer pause]

Au lieu du processus de `web`, tuez avec `SIGKILL` le processus `pause` du Pod `suivi`. Prédisez ce qui va arriver au conteneur `web`, au bac à sable et à l'adresse IP du Pod, puis vérifiez.

:::

<details>
<summary>Corrigé</summary>

```sortie
avant : bac à sable bb31783846e28, IP 10.244.1.56, restartCount 1
après : bac à sable 9d71310a75424, IP 10.244.1.60, restartCount 2
SandboxChanged         Pod sandbox changed, it will be killed and re-created.
Killing                Stopping container web
```

Sans `pause`, le bac à sable n'a plus de processus pour détenir ses espaces de noms : il est mort, même si `web` tournait encore. Le kubelet le constate (`SandboxChanged`), arrête `web`, supprime le bac à sable, et recrée tout : un nouveau bac à sable, donc un nouvel espace de noms réseau et une nouvelle adresse IP, attribuée par le greffon CNI, et un nouveau conteneur `web` (le compteur de redémarrages passe à 2). C'est la différence entre les deux redémarrages de ce chapitre : un conteneur qui plante garde l'identité réseau du Pod ; un bac à sable qui meurt la perd. Pour les clients qui passent par un Service, le changement d'adresse est transparent, puisque l'EndpointSlice suit (chapitre 40) ; pour ceux qui avaient noté l'adresse du Pod, il ne l'est pas.

</details>

## Nettoyer

```bash
kubectl delete namespace ch38
kubectl config set-context --current --namespace=default
N 'sudo rm -f /etc/kubernetes/manifests/statique.yaml'
```

Vérifiez que le kubelet du nœud de travail tourne bien, si vous l'avez arrêté vous-même :

```bash
N 'systemctl is-active kubelet'
kubectl get nodes
```

Les chapitres 39 à 41 démarrent leurs propres profils minikube. Pour libérer la mémoire, arrêtez celui-ci :

```bash
minikube stop -p deux-noeuds
```

[^eviction]: Kubernetes, « Node-pressure Eviction », section *Hard eviction thresholds*, pour les seuils par défaut (`memory.available<100Mi`, `nodefs.available<10%`...). [kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/)

[^dockershim]: Kubernetes Blog, « Kubernetes is Moving on From Dockershim: Commitments and Next Steps », 7 janvier 2022 ; et « Introducing Container Runtime Interface (CRI) in Kubernetes », 19 décembre 2016. [kubernetes.io/blog/2022/01/07/kubernetes-is-moving-on-from-dockershim](https://kubernetes.io/blog/2022/01/07/kubernetes-is-moving-on-from-dockershim/), [kubernetes.io/blog/2016/12/container-runtime-interface-cri-in-kubernetes](https://kubernetes.io/blog/2016/12/container-runtime-interface-cri-in-kubernetes/)

[^cri]: Kubernetes, « Container Runtime Interface (CRI) », et la définition du service dans `cri-api` (`RunPodSandbox`, `CreateContainer`, `StartContainer`...). [kubernetes.io/docs/concepts/architecture/cri](https://kubernetes.io/docs/concepts/architecture/cri/), [github.com/kubernetes/cri-api](https://github.com/kubernetes/cri-api)

[^baux]: Kubernetes, « Nodes », section *Heartbeats*, et « Leases », section *Node heartbeats*. [kubernetes.io/docs/concepts/architecture/nodes](https://kubernetes.io/docs/concepts/architecture/nodes/), [kubernetes.io/docs/concepts/architecture/leases](https://kubernetes.io/docs/concepts/architecture/leases/)
