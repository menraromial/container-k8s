---
title: Le réseau des Pods
sidebar_label: 39. Le réseau des Pods
description: "Le contrat réseau de Kubernetes et ceux qui le remplissent : l'interface CNI, puis trois réseaux réels sur des profils minikube de deux nœuds, kindnet (routage direct), Calico (blocs d'adresses, BGP, IP dans IP) et Cilium (eBPF, VXLAN, identités), chacun observé jusqu'au paquet capturé entre les nœuds."
partie: 5
chapitre: '39'
---

import reseauKindnet from '@site/src/figures/reseau-kindnet.svg';
import encapsulations from '@site/src/figures/encapsulations.svg';

Kubernetes ne sait pas faire circuler un paquet d'un Pod à un autre. Il ne crée aucune interface réseau, n'attribue lui-même aucune adresse de Pod, n'écrit aucune route. Voici un cluster à deux nœuds, dix-sept secondes après son démarrage, avant que le moindre réseau n'y soit installé :

```sortie
NAME         STATUS     ROLES           AGE   VERSION   INTERNAL-IP    EXTERNAL-IP   OS-IMAGE                         KERNEL-VERSION             CONTAINER-RUNTIME
calico       NotReady   control-plane   17s   v1.37.0   192.168.67.2   <none>        Debian GNU/Linux 12 (bookworm)   7.0.0-34-generic (amd64)   containerd://2.3.4
calico-m02   NotReady   <none>          1s    v1.37.0   192.168.67.3   <none>        Debian GNU/Linux 12 (bookworm)   7.0.0-34-generic (amd64)   containerd://2.3.4
```

Les deux nœuds sont `NotReady`. Rien n'est en panne : le kubelet signale simplement que le réseau des Pods n'est pas prêt, et tant qu'il ne l'est pas, le scheduler n'y place aucun Pod ordinaire. Kubernetes fixe un **contrat** que tout réseau de Pods doit respecter, et laisse à un programme extérieur, un **greffon réseau**, le soin de le remplir. Il en existe des dizaines, qui y parviennent de façons très différentes.

Ce chapitre en compare trois, sur de vrais clusters. **kindnet**, le réseau par défaut de minikube quand il y a plusieurs nœuds, qu'on utilise depuis le chapitre 15. **Calico**, l'un des plus répandus en production. **Cilium**, qui remplace une grande partie de la pile réseau du noyau par des programmes eBPF. Pour chacun, on suit le même paquet, un `ping` d'un Pod à un Pod de l'autre nœud, depuis l'interface du Pod jusqu'au fil qui relie les nœuds.

Chaque réseau demande son propre cluster, et la mémoire limite à un profil de deux nœuds à la fois. On passe donc d'un profil à l'autre : `deux-noeuds` (kindnet), puis `calico`, puis `cilium`, en arrêtant le précédent chaque fois. Les fichiers sont dans [l'archive reseau](pathname:///kits/reseau.tar.gz) ; `pods.sh` crée, dans le namespace `ch39`, un Pod `agnhost` par nœud, nommé d'après son nœud.

## Le contrat

La documentation de Kubernetes énonce le modèle réseau en quelques règles[^modele]. Chaque Pod a sa propre adresse IP, unique dans tout le cluster. Tous les Pods peuvent joindre tous les autres Pods, quel que soit leur nœud, **sans traduction d'adresse** : l'adresse que voit le destinataire est l'adresse réelle de l'émetteur. Et les agents d'un nœud, dont le kubelet, peuvent joindre tous les Pods de ce nœud. Les conteneurs d'un même Pod partagent l'adresse du Pod, puisqu'ils partagent son espace de noms réseau (le bac à sable du chapitre 38).

Ce contrat est ce qui rend Kubernetes si simple à utiliser : un programme dans un Pod n'a jamais à se soucier de ports publiés ni de traductions, comme avec `docker run -p` au chapitre 6. Il est aussi ce qui le rend exigeant à mettre en place : il faut une adresse par Pod, des milliers parfois, et un moyen pour chaque nœud d'atteindre les adresses de tous les autres.

Le greffon réseau s'insère au moment précis qu'on a vu au chapitre 38 : quand le runtime crée le bac à sable d'un Pod, il appelle le greffon, selon l'interface **CNI** (*Container Network Interface*)[^cni]. Le protocole est d'une simplicité étonnante. La configuration est un fichier JSON du dossier `/etc/cni/net.d` ; les greffons sont des exécutables du dossier `/opt/cni/bin`. Pour brancher un Pod, le runtime exécute le greffon avec la commande `ADD`, en lui passant le chemin de l'espace de noms réseau du bac à sable, et le greffon répond, sur sa sortie standard, par l'adresse qu'il a attribuée. Pour le débrancher, la commande `DEL`. Tout le reste, les routes entre nœuds, les tunnels, les politiques, est l'affaire de programmes qui tournent à côté, le plus souvent en DaemonSet.

## kindnet : du routage, et rien d'autre

```bash
minikube start -p deux-noeuds
./pods.sh
kubectl get nodes -o custom-columns=NOEUD:.metadata.name,IP:.status.addresses[0].address,PODCIDR:.spec.podCIDR
```

```sortie
NAME                READY   STATUS    RESTARTS   AGE   IP           NODE              NOMINATED NODE   READINESS GATES
p-deux-noeuds       1/1     Running   0          1s    10.244.0.8   deux-noeuds       <none>           <none>
p-deux-noeuds-m02   1/1     Running   0          1s    10.244.1.2   deux-noeuds-m02   <none>           <none>
NOEUD             IP             PODCIDR
deux-noeuds       192.168.58.2   10.244.0.0/24
deux-noeuds-m02   192.168.58.3   10.244.1.0/24
```

Chaque nœud a reçu du gestionnaire de contrôleurs un bloc d'adresses, son `podCIDR` : `10.244.0.0/24` pour le premier, `10.244.1.0/24` pour le second, 254 adresses chacun. Les Pods prennent leur adresse dans le bloc de leur nœud. C'est kindnet qui a écrit la configuration CNI du nœud :

```bash
N() { minikube ssh -p deux-noeuds -n $1 -- "${@:2}" 2>/dev/null | tr -d '\r'; }
N deux-noeuds-m02 'ls /etc/cni/net.d/; ls /opt/cni/bin/ | tr "\n" " "; echo; sudo cat /etc/cni/net.d/10-kindnet.conflist'
```

```sortie
10-crio-bridge.conflist.disabled.mk_disabled
10-kindnet.conflist
87-podman-bridge.conflist.mk_disabled
cni.lock
LICENSE README.md bandwidth bridge dhcp dummy firewall host-device host-local ipvlan loopback macvlan portmap ptp sbr static tap tuning vlan vrf

{
	"cniVersion": "0.3.1",
	"name": "kindnet",
	"plugins": [
	{
		"type": "ptp",
		"ipMasq": false,
		"ipam": {
			"type": "host-local",
			"dataDir": "/run/cni-ipam-state",
			"routes": [
				{ "dst": "0.0.0.0/0" }
			],
			"ranges": [
				[ { "subnet": "10.244.1.0/24" } ]
			]
		}
		,
		"mtu": 1500
	},
	{
		"type": "portmap",
		"capabilities": {
			"portMappings": true
		}
	}
	]
}
```

(J'ai retiré les lignes vides du fichier.) Minikube a désactivé les deux autres configurations en les renommant, et le dossier `/opt/cni/bin` contient les greffons de référence du projet CNI, dont kindnet n'utilise que trois. `ptp` (*point à point*) crée, pour chaque Pod, une **paire veth** : deux interfaces reliées comme par un câble, l'une dans le Pod, l'autre sur l'hôte. `host-local` distribue les adresses du bloc du nœud, en notant celles qu'il a données dans des fichiers. `portmap` sert aux rares Pods qui publient un `hostPort`. Regardons le Pod du second nœud, de l'intérieur :

```bash
kubectl -n ch39 exec p-deux-noeuds-m02 -- ip addr show eth0
kubectl -n ch39 exec p-deux-noeuds-m02 -- ip route
```

```sortie
3: eth0@if4: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    link/ether 06:c9:cc:72:43:61 brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 10.244.1.2/24 brd 10.244.1.255 scope global eth0
       valid_lft forever preferred_lft forever
    inet6 fe80::4c9:ccff:fe72:4361/64 scope link tentative proto kernel_ll 
       valid_lft forever preferred_lft forever
default via 10.244.1.1 dev eth0 
10.244.1.0/24 via 10.244.1.1 dev eth0 src 10.244.1.2 
10.244.1.1 dev eth0 scope link src 10.244.1.2 
```

Le Pod a une interface `eth0`, l'adresse `10.244.1.2`, et envoie tout vers la passerelle `10.244.1.1`, même le trafic destiné aux autres Pods de son propre bloc. Le suffixe `@if4` dit que l'autre bout de sa paire veth est l'interface numéro 4 de l'hôte. Allons voir de l'autre côté :

```bash
N deux-noeuds-m02 'ip -br link | grep veth; ip route'
N deux-noeuds-m02 'ip -d link show veth64277a88 | head -2; ip addr show veth64277a88 | grep inet'
```

```sortie
veth64277a88@if3 UP             92:48:62:f9:f4:1c <BROADCAST,MULTICAST,UP,LOWER_UP> 
default via 192.168.58.1 dev eth0 
10.244.0.0/24 via 192.168.58.2 dev eth0 
10.244.1.2 dev veth64277a88 scope host 
192.168.58.0/24 dev eth0 proto kernel scope link src 192.168.58.3 
4: veth64277a88@if3: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP mode DEFAULT group default 
    link/ether 92:48:62:f9:f4:1c brd ff:ff:ff:ff:ff:ff link-netns cni-0fbdd6c5-3f78-a8b0-b3f9-550caaebd579 promiscuity 0  allmulti 0 minmtu 68 maxmtu 65535 
    inet 10.244.1.1/32 scope global veth64277a88
```

L'interface 4 de l'hôte, `veth64277a88`, porte l'adresse `10.244.1.1` : c'est la passerelle du Pod. Chaque veth côté hôte reçoit cette même adresse, en `/32`, ce qui suffit pour répondre aux Pods sans former de réseau commun : il n'y a ici aucun pont (*bridge*), seulement des liaisons point à point. La table de routage de l'hôte fait le reste, avec deux sortes de routes. Une route par Pod local, `10.244.1.2 dev veth64277a88`, posée par le greffon `ptp` au branchement. Et une route vers le bloc de l'autre nœud, `10.244.0.0/24 via 192.168.58.2`, posée par le démon kindnet, qui surveille les objets `Node` et leurs `podCIDR`.

Le greffon `host-local` garde la trace de ses attributions, un fichier par adresse :

```bash
N deux-noeuds-m02 'sudo ls /run/cni-ipam-state/kindnet/; for f in /run/cni-ipam-state/kindnet/10.*; do echo "$f : $(sudo cat $f | tr "\n" " ")"; done'
echo "bac à sable : $(N deux-noeuds-m02 'sudo crictl pods --name p-deux-noeuds-m02 --state ready -q')"
```

```sortie
10.244.1.2  last_reserved_ip.0	lock
/run/cni-ipam-state/kindnet/10.244.1.2 : 7e163807be718d11be0b879be0850b9931d87c6f0a27774d98a6fcb455a0eb77 eth0
bac à sable : 7e163807be718d11be0b879be0850b9931d87c6f0a27774d98a6fcb455a0eb77
```

Le fichier `10.244.1.2` contient l'identifiant du bac à sable qui détient l'adresse, et le nom de l'interface. C'est la preuve que l'adresse appartient au bac à sable, et non au conteneur de l'application : c'est pourquoi un conteneur qui redémarre la garde, et un bac à sable recréé en change (chapitre 38, exercice 4).

Il reste à suivre le paquet. Les nœuds de minikube n'ont pas `tcpdump` ; `kubectl debug node` lance un Pod qui partage le réseau du nœud, avec une image d'outils réseau, `netshoot`, qui servira aussi au chapitre 40 :

```bash
kubectl -n ch39 debug node/deux-noeuds-m02 --image=nicolaka/netshoot:v0.14 --profile=sysadmin -- sleep 3600
D=$(kubectl -n ch39 get pods -o name | grep node-debugger | cut -d/ -f2)
kubectl -n ch39 exec $D -- timeout 6 tcpdump -ni eth0 -c 4 icmp &
kubectl -n ch39 exec p-deux-noeuds-m02 -- ping -c 2 10.244.0.8
```

```sortie
PING 10.244.0.8 (10.244.0.8): 56 data bytes
64 bytes from 10.244.0.8: seq=0 ttl=62 time=0.237 ms
64 bytes from 10.244.0.8: seq=1 ttl=62 time=0.212 ms
19:10:20.474277 IP 10.244.1.2 > 10.244.0.8: ICMP echo request, id 27, seq 0, length 64
19:10:20.474374 IP 10.244.0.8 > 10.244.1.2: ICMP echo reply, id 27, seq 0, length 64
19:10:21.474530 IP 10.244.1.2 > 10.244.0.8: ICMP echo request, id 27, seq 1, length 64
19:10:21.474608 IP 10.244.0.8 > 10.244.1.2: ICMP echo reply, id 27, seq 1, length 64
```

Sur l'interface physique du nœud, `eth0`, le paquet circule avec les adresses des deux Pods, telles quelles. Pas d'en-tête ajouté, pas de traduction : c'est le contrat, rempli de la façon la plus directe qui soit. Le TTL de 62 dit que le paquet a traversé deux routeurs, les deux nœuds eux-mêmes. La figure 39.1 retrace le chemin.

<Figure svg={reseauKindnet} num="39.1" alt="Un paquet entre deux Pods de deux nœuds avec kindnet. Sur le nœud deux-noeuds-m02, le Pod p-deux-noeuds-m02, d'interface eth0@if4 et d'adresse 10.244.1.2/24, avec la passerelle 10.244.1.1, est relié par une paire veth à l'interface veth64277a88 de l'hôte, d'index 4 et d'adresse 10.244.1.1/32. 1, le paquet arrive sur l'hôte ; 2, la table de routage de l'hôte, qui contient 10.244.1.2 dev veth64277a88 et 10.244.0.0/24 via 192.168.58.2 dev eth0, l'envoie par eth0, 192.168.58.3 ; 3, sur le réseau des nœuds 192.168.58.0/24, le paquet garde ses adresses de Pods, 10.244.1.2 vers 10.244.0.8, sans en-tête ajouté ni traduction ; 4, il arrive sur eth0 du nœud deux-noeuds, 192.168.58.2, dont la table contient 10.244.0.8 dev veth... et 10.244.1.0/24 via 192.168.58.3 ; 5, il est remis par la veth côté hôte au Pod p-deux-noeuds, 10.244.0.8.">
Un paquet entre deux Pods avec kindnet. Deux paires veth et deux tables de routage suffisent : le réseau des nœuds transporte les adresses des Pods sans les modifier.
</Figure>

Cette simplicité a une condition : il faut que les nœuds puissent se transmettre directement des paquets adressés à des Pods. C'est le cas ici, où tous les nœuds sont sur le même réseau Docker. Sur un réseau d'entreprise ou chez un fournisseur de cloud, les routeurs situés entre les nœuds ne connaissent pas les blocs `10.244.x.0/24`, et jetteraient ces paquets. Il faut alors leur apprendre les routes, ou cacher les adresses des Pods. Les deux réseaux suivants savent faire l'un et l'autre.

## Calico : des blocs, BGP et un tunnel

```bash
minikube stop -p deux-noeuds
minikube start -p calico --nodes=2 --memory=2g --cpus=2 --cni=calico
kubectl -n kube-system get ds calico-node -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl get ippools.crd.projectcalico.org -o yaml | grep -E ' cidr:|ipipMode|vxlanMode|natOutgoing|blockSize'
kubectl get blockaffinities.crd.projectcalico.org -o custom-columns=NOEUD:.spec.node,BLOC:.spec.cidr,ETAT:.spec.state
```

```sortie
quay.io/calico/node:v3.32.2
    blockSize: 26
    cidr: 10.244.0.0/16
    ipipMode: Always
    natOutgoing: true
    vxlanMode: Never
NOEUD        BLOC               ETAT
calico       10.244.15.192/26   confirmed
calico-m02   10.244.228.0/26    confirmed
```

Calico ne se sert pas du `podCIDR` des nœuds. Il gère lui-même ses adresses, dans des objets de l'API qu'il a ajoutés par des CRD : un **pool**, `10.244.0.0/16`, découpé en **blocs** de 64 adresses (`blockSize: 26`), attribués aux nœuds à la demande. Chaque nœud en a reçu un pour commencer ; s'il en remplit un, il en demande un autre. Le pool précise aussi comment les paquets passent d'un nœud à l'autre : `ipipMode: Always`, encapsulés dans un second en-tête IP. `natOutgoing` traduit les adresses des Pods quand ils sortent du cluster, vers Internet par exemple.

```bash
./pods.sh
kubectl -n ch39 exec p-calico-m02 -- ip addr show eth0 | grep -E 'eth0|inet '
kubectl -n ch39 exec p-calico-m02 -- ip route
```

```sortie
NAME           READY   STATUS    RESTARTS   AGE   IP              NODE         NOMINATED NODE   READINESS GATES
p-calico       1/1     Running   0          2s    10.244.15.203   calico       <none>           <none>
p-calico-m02   1/1     Running   0          1s    10.244.228.3    calico-m02   <none>           <none>
3: eth0@if6: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1480 qdisc noqueue state UP group default qlen 1000
    inet 10.244.228.3/32 scope global eth0
default via 169.254.1.1 dev eth0 
169.254.1.1 dev eth0 scope link 
```

Trois différences avec kindnet, dès l'intérieur du Pod. L'adresse est en `/32` : le Pod ne se croit sur aucun réseau local, et envoie tout à sa passerelle. Cette passerelle, `169.254.1.1`, n'existe nulle part : c'est une adresse de lien local choisie par convention, à laquelle l'hôte répond par *proxy ARP*, en donnant sa propre adresse MAC pour toutes les requêtes[^calico-faq]. Et le MTU est de 1480 au lieu de 1500, on verra pourquoi. Côté hôte :

```bash
N() { minikube ssh -p calico -n $1 -- "${@:2}" 2>/dev/null | tr -d '\r'; }
N calico-m02 'ip -br link | grep -E "cali|tunl"; ip route | grep -v docker'
kubectl -n kube-system exec ds/calico-node -c calico-node -- birdcl show protocols
```

```sortie
tunl0@NONE       UNKNOWN        0.0.0.0 <NOARP,UP,LOWER_UP> 
cali828c5377299@if3 UP             ee:ee:ee:ee:ee:ee <BROADCAST,MULTICAST,UP,LOWER_UP> 
default via 192.168.67.1 dev eth0 
10.244.15.192/26 via 192.168.67.2 dev tunl0 proto bird metric 1024 onlink 
blackhole 10.244.228.0/26 proto bird 
10.244.228.3 dev cali828c5377299 scope link metric 1024 
192.168.67.0/24 dev eth0 proto kernel scope link src 192.168.67.3 
BIRD v0.3.3+birdv1.6.8 ready.
name     proto    table    state  since       info
static1  Static   master   up     19:11:19    
kernel1  Kernel   master   up     19:11:19    
device1  Device   master   up     19:11:19    
direct1  Direct   master   up     19:11:19    
Mesh_192_168_67_3 BGP      master   up     19:11:33    Established   
```

L'interface `cali...` est le bout hôte de la paire veth, avec l'adresse MAC fantaisiste `ee:ee:ee:ee:ee:ee` que Calico donne à toutes. Les routes, elles, ont une origine nouvelle : `proto bird`. **BIRD** est un démon de routage, embarqué dans le Pod `calico-node` de chaque nœud, qui parle **BGP**, le protocole qu'utilisent les opérateurs d'Internet pour s'annoncer leurs réseaux. Chaque nœud annonce à ses voisins les blocs qu'il détient ; ici, les deux nœuds forment un maillage complet (`Mesh_...`, session `Established`). C'est ainsi que `calico-m02` a appris que le bloc `10.244.15.192/26` est chez `192.168.67.2`. La route `blackhole` rejette les adresses de son propre bloc qui ne correspondent à aucun Pod, au lieu de les renvoyer vers la route par défaut. Et parce que BGP est le langage des routeurs, un nœud Calico peut aussi annoncer ses blocs aux routeurs physiques du centre de données, qui sauront alors joindre les Pods sans aucun tunnel.

Ici, le pool demande un tunnel, et la route passe par `tunl0`. La capture le montre, en mode détaillé :

```bash
kubectl -n ch39 debug node/calico-m02 --image=nicolaka/netshoot:v0.14 --profile=sysadmin -- sleep 3600
D=$(kubectl -n ch39 get pods -o name | grep node-debugger | cut -d/ -f2)
kubectl -n ch39 exec $D -- timeout 6 tcpdump -ni eth0 -c 1 -v ip proto 4 &
kubectl -n ch39 exec p-calico-m02 -- ping -c 1 10.244.15.203
```

```sortie
PING 10.244.15.203 (10.244.15.203): 56 data bytes
64 bytes from 10.244.15.203: seq=0 ttl=62 time=0.421 ms
19:11:46.794785 IP (tos 0x0, ttl 63, id 10500, offset 0, flags [DF], proto IPIP (4), length 104)
    192.168.67.3 > 192.168.67.2: IP (tos 0x0, ttl 63, id 47680, offset 0, flags [DF], proto ICMP (1), length 84)
    10.244.228.3 > 10.244.15.203: ICMP echo request, id 29, seq 0, length 64
```

Deux en-têtes IP l'un dans l'autre. L'en-tête extérieur va d'un nœud à l'autre (`192.168.67.3 > 192.168.67.2`), avec le protocole 4, « IP dans IP » ; l'en-tête intérieur est le paquet d'origine, de Pod à Pod. Le paquet extérieur fait 104 octets, l'intérieur 84 : l'encapsulation coûte 20 octets par paquet. D'où le MTU de 1480 dans le Pod : un paquet de 1480 octets, une fois encapsulé, remplit exactement les 1500 octets du réseau des nœuds. Pour les routeurs situés entre les nœuds, ce n'est qu'un paquet ordinaire entre deux machines qu'ils connaissent.

## Cilium : l'eBPF à la place des routes

```bash
minikube stop -p calico
minikube start -p cilium --nodes=2 --memory=2g --cpus=2 --cni=cilium
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -E '^(Kubernetes|KubeProxyReplacement|Cilium|IPAM|Routing|Device Mode|Masquerading):'
```

```sortie
Kubernetes:              Ok         1.37 (v1.37.0) [linux/amd64]
KubeProxyReplacement:    False   
Cilium:                  Ok   1.20.1 (v1.20.1-7d68cfb3)
IPAM:                    IPv4: 2/254 allocated from 10.244.0.0/24, 
Routing:                 Network: Tunnel [vxlan]   Host: Legacy
Device Mode:             veth
Masquerading:            IPTables [IPv4: Enabled, IPv6: Disabled]
```

Cilium 1.20, dans la configuration que minikube installe : un tunnel **VXLAN** entre les nœuds, et kube-proxy toujours présent (`KubeProxyReplacement: False`), ce qu'on changera au chapitre 40. Cilium distribue lui-même les adresses, un bloc par nœud.

```bash
./pods.sh
kubectl -n ch39 exec p-cilium-m02 -- ip addr show eth0 | grep -E 'eth0|inet '
kubectl -n ch39 exec p-cilium-m02 -- ip route
N() { minikube ssh -p cilium -n $1 -- "${@:2}" 2>/dev/null | tr -d '\r'; }
N cilium-m02 'ip -br link | grep -E "lxc|cilium"; ip route | grep -v docker'
```

```sortie
NAME           READY   STATUS    RESTARTS   AGE   IP             NODE         NOMINATED NODE   READINESS GATES
p-cilium       1/1     Running   0          3s    10.244.0.132   cilium       <none>           <none>
p-cilium-m02   1/1     Running   0          3s    10.244.1.87    cilium-m02   <none>           <none>
11: eth0@if12: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default 
    inet 10.244.1.87/32 scope global eth0
default via 10.244.1.99 dev eth0 mtu 1450 
10.244.1.99 dev eth0 scope link 
cilium_net@cilium_host UP             22:c3:72:e9:4b:c1 <BROADCAST,MULTICAST,NOARP,UP,LOWER_UP> 
cilium_host@cilium_net UP             12:c4:6c:80:13:7f <BROADCAST,MULTICAST,NOARP,UP,LOWER_UP> 
cilium_vxlan     UNKNOWN        ae:cf:6d:0e:fc:fb <BROADCAST,MULTICAST,UP,LOWER_UP> 
lxc_health@if7   UP             ba:61:e6:d7:02:e3 <BROADCAST,MULTICAST,UP,LOWER_UP> 
lxc3abbad62b70e@if9 UP             b6:4d:e2:32:01:28 <BROADCAST,MULTICAST,UP,LOWER_UP> 
lxcf51203b3acca@if11 UP             36:4d:f7:a2:b9:04 <BROADCAST,MULTICAST,UP,LOWER_UP> 
default via 192.168.76.1 dev eth0 
10.244.0.0/24 via 10.244.1.99 dev cilium_host proto kernel src 10.244.1.99 mtu 1450 
10.244.1.0/24 via 10.244.1.99 dev cilium_host proto kernel src 10.244.1.99 
10.244.1.99 dev cilium_host proto kernel scope link 
192.168.76.0/24 dev eth0 proto kernel scope link src 192.168.76.3 
```

Le Pod a encore une adresse en `/32` et une passerelle, `10.244.1.99`, qui est l'adresse de l'interface `cilium_host` de l'hôte. Le MTU de 1450 est posé sur la route. Les paires veth s'appellent ici `lxc...`. Mais regardez la table de routage de l'hôte : il n'y a **aucune route vers les Pods locaux**. kindnet et Calico en avaient une par Pod ; Cilium n'en a pas besoin, parce que les paquets ne traversent presque pas la pile de routage du noyau. Cilium attache des programmes **eBPF** aux interfaces `lxc...` et au tunnel : de petits programmes, vérifiés par le noyau avant d'être chargés, qui s'exécutent à chaque paquet et décident eux-mêmes où l'envoyer. Leurs décisions s'appuient sur des tables en mémoire du noyau, les *maps*, que l'agent Cilium tient à jour et que `cilium-dbg` sait lire :

```bash
A=$(kubectl -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName=cilium-m02 -o name)
kubectl -n kube-system exec $A -c cilium-agent -- cilium-dbg bpf endpoint list | grep -E 'IP ADDRESS|^10.244.1.87:'
kubectl -n kube-system exec $A -c cilium-agent -- cilium-dbg bpf ipcache list | grep -E 'PREFIX|^10.244.0.132/|^10.244.1.87/|^10.244.0.0/24'
```

```sortie
IP ADDRESS       LOCAL ENDPOINT INFO
10.244.1.87:0    id=1478  sec_id=22446 flags=0x0000 ifindex=12  mac=4E:03:9F:4E:C1:30 nodemac=36:4D:F7:A2:B9:04 parent_ifindex=0   rt_info:0   
IP PREFIX/ADDRESS   IDENTITY
10.244.0.132/32     identity=13837 encryptkey=0 tunnelendpoint=192.168.76.2 flags=hastunnel   
10.244.1.87/32      identity=22446 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>           
10.244.0.0/24       identity=2 encryptkey=0 tunnelendpoint=192.168.76.2 flags=hastunnel       
```

La table des points de terminaison (*endpoints*) remplace les routes locales : l'adresse `10.244.1.87` est l'interface d'index 12, avec telle adresse MAC. La table `ipcache` remplace les routes vers les autres nœuds : l'adresse `10.244.0.132`, et plus largement le bloc `10.244.0.0/24`, se joignent par un tunnel vers `192.168.76.2`. Et chaque adresse porte une **identité** : un numéro que Cilium attribue à chaque combinaison d'étiquettes de Pods (tous les Pods qui ont les mêmes étiquettes et le même namespace partagent la même identité). C'est sur ces identités, et non sur les adresses, que Cilium appliquera les politiques réseau du chapitre 41. La capture montre où elles voyagent :

```bash
kubectl -n ch39 debug node/cilium-m02 --image=nicolaka/netshoot:v0.14 --profile=sysadmin -- sleep 3600
D=$(kubectl -n ch39 get pods -o name | grep node-debugger | cut -d/ -f2)
kubectl -n ch39 exec $D -- timeout 8 tcpdump -ni eth0 -c 40 udp port 8472 > td.txt &
timeout 8 kubectl -n kube-system exec $A -c cilium-agent -- cilium-dbg monitor --type trace > mon.txt &
kubectl -n ch39 exec p-cilium-m02 -- ping -c 1 10.244.0.132
grep -B1 ICMP td.txt; grep icmp mon.txt
```

```sortie
PING 10.244.0.132 (10.244.0.132): 56 data bytes
64 bytes from 10.244.0.132: seq=0 ttl=63 time=0.369 ms
19:07:35.425287 IP 192.168.76.3.36121 > 192.168.76.2.8472: OTV, flags [I] (0x08), overlay 0, instance 22446
IP 10.244.1.87 > 10.244.0.132: ICMP echo request, id 29, seq 0, length 64
19:07:35.425463 IP 192.168.76.2.36121 > 192.168.76.3.8472: OTV, flags [I] (0x08), overlay 0, instance 13837
IP 10.244.0.132 > 10.244.1.87: ICMP echo reply, id 29, seq 0, length 64
-> overlay flow 0x0 , identity 22446->13837 state new ifindex cilium_vxlan orig-ip 0.0.0.0: 10.244.1.87 -> 10.244.0.132 icmp EchoRequest
-> endpoint 1478 flow 0x0 , identity 13837->22446 state reply ifindex lxcf51203b3acca orig-ip 10.244.0.132: 10.244.0.132 -> 10.244.1.87 icmp EchoReply
```

(On filtre sur `ICMP`, parce que le tunnel transporte aussi les vérifications de santé que les agents Cilium s'échangent en permanence.) Le paquet part vers le port UDP 8472 de l'autre nœud, le port VXLAN que Cilium utilise ; `tcpdump` le décode sous le nom d'un autre protocole qui partage ce port, `OTV`, mais l'intérieur est bien notre `ping`. Le champ `instance` est l'identifiant de réseau VXLAN (VNI), et sa valeur n'est pas un hasard : **22446**, l'identité du Pod émetteur, et **13837** pour la réponse. Cilium transporte l'identité de l'émetteur dans l'en-tête du tunnel, pour que le nœud d'arrivée sache qui parle sans avoir à la déduire de l'adresse. Le `TTL` de 63, au lieu de 62 avec kindnet et Calico, montre que le paquet n'a été compté qu'une fois comme routé : les programmes eBPF court-circuitent une partie de la pile de routage du noyau. Et `cilium-dbg monitor` raconte la même histoire vue par les programmes eBPF : la requête part dans le tunnel (`-> overlay`), la réponse est remise directement au point de terminaison 1478, le Pod.

La figure 39.2 compare les trois formes du même paquet.

<Figure svg={encapsulations} num="39.2" alt="Le même paquet entre deux Pods sous trois réseaux. Avec kindnet, routage direct, pas d'encapsulation : Ethernet, puis IP du Pod 10.244.1.x vers le Pod 10.244.0.x, puis ICMP ou TCP ; MTU du Pod 1500, et le réseau des nœuds doit savoir router les adresses des Pods. Avec Calico, IP dans IP, un en-tête IP de plus : Ethernet, IP du nœud 192.168.67.3 vers le nœud .2 avec le protocole 4, IP de Pod à Pod, ICMP ou TCP ; MTU 1480, soit 20 octets de plus. Avec Cilium, VXLAN, une trame entière dans un datagramme UDP : Ethernet, IP de nœud à nœud, UDP 8472, VXLAN dont le VNI est l'identité, Ethernet interne, IP de Pod à Pod, ICMP ; MTU 1450, soit 50 octets. Les encapsulations laissent passer le trafic des Pods sur n'importe quel réseau de nœuds, au prix de quelques octets par paquet ; le MTU des Pods est réduit d'autant.">
Le même `ping` sous trois réseaux. Plus l'encapsulation est lourde, plus le MTU laissé aux Pods est petit.
</Figure>

## Trois réseaux, trois choix

| | kindnet | Calico | Cilium |
|---|---|---|---|
| Adresses des Pods | `podCIDR` du nœud (`host-local`) | blocs de 64 adresses, pool de Calico | bloc par nœud, IPAM de Cilium |
| Livraison sur le nœud | une route par Pod | une route par Pod | programmes eBPF, table des points de terminaison |
| Entre les nœuds | routage direct | BGP, avec ou sans tunnel IP dans IP | tunnel VXLAN, ou routage direct |
| MTU des Pods (ici) | 1500 | 1480 | 1450 |
| Politiques réseau | selon la version (chapitre 41) | oui, par iptables ou eBPF | oui, par identités, en eBPF |

La dernière ligne compte : tous les greffons n'appliquent pas les NetworkPolicies du chapitre 41. Une politique créée sur un cluster dont le greffon les ignore est acceptée par l'API, puis reste sans effet, sans le moindre avertissement. Le chapitre 41 vérifiera ce qu'en fait chacun de nos trois réseaux.

:::panne[Les petites requêtes passent, les grosses restent bloquées]

C'est le symptôme typique d'un MTU mal réglé. Si le MTU des Pods ne laisse pas la place de l'encapsulation, les paquets pleins, une fois encapsulés, dépassent la taille permise sur le réseau des nœuds. Ils devraient être fragmentés ou signalés trop grands à l'émetteur, mais les paquets marqués « ne pas fragmenter » (le cas de presque tout TCP) sont alors jetés, et le message d'erreur ICMP qui devrait prévenir l'émetteur est souvent filtré en route. Résultat : un `ping`, une requête DNS, l'ouverture d'une connexion passent ; le transfert d'une page un peu lourde ou d'un fichier reste suspendu. Le diagnostic se fait avec un `ping` de taille croissante et l'interdiction de fragmenter, entre deux Pods de nœuds différents. La correction est de régler le MTU du greffon d'après celui du réseau des nœuds et le coût de l'encapsulation choisie, ce que Calico et Cilium font automatiquement quand ils détectent correctement l'interface des nœuds[^mtu].

:::

## Exercices

:::exercice[Exercice 1 : de quel Pod est cette veth ?]

Sur un nœud kindnet, `ip -br link` liste des dizaines d'interfaces `veth...`. Donnez deux méthodes pour savoir quelle veth appartient à quel Pod, l'une partant du Pod, l'autre de l'hôte.

:::

<details>
<summary>Corrigé</summary>

Depuis le Pod : `ip addr show eth0` donne `eth0@if4`, l'index de l'autre bout de la paire sur l'hôte ; `ip -d link` sur l'hôte montre l'interface d'index 4, `veth64277a88`. Depuis l'hôte : la table de routage contient une route par Pod, `10.244.1.2 dev veth64277a88`, et l'adresse mène au Pod par `kubectl get pods -o wide`. On peut aussi comparer l'attribut `link-netns` de la veth (`cni-0fbdd6c5-...`) à l'espace de noms réseau du bac à sable donné par `crictl inspectp` (chapitre 38). Avec Calico, les deux premières méthodes marchent de la même façon ; avec Cilium, il n'y a plus de route par Pod, mais `cilium-dbg bpf endpoint list` donne directement, pour chaque adresse, l'index de l'interface `lxc...`.

</details>

:::exercice[Exercice 2 : les adresses et les blocs des nœuds]

Écrivez en Python, avec la bibliothèque standard et `kubectl proxy --port=8011`, un programme qui vérifie que l'adresse de chaque Pod (hors Pods du réseau de l'hôte) appartient au `podCIDR` de son nœud. Faites-le tourner sur les trois profils. Qu'observez-vous avec Calico, et pourquoi ?

:::

<details>
<summary>Corrigé</summary>

```python title="adresses.py (extrait)"
blocs = {n["metadata"]["name"]: ipaddress.ip_network(n["spec"]["podCIDR"])
         for n in lire("/nodes")["items"] if n["spec"].get("podCIDR")}
for p in lire("/pods")["items"]:
    s = p["spec"]
    if s.get("hostNetwork") or not p["status"].get("podIP"):
        continue                                    # les Pods du réseau de l'hôte ont l'adresse du nœud
    ip = ipaddress.ip_address(p["status"]["podIP"])
    verdict = "oui" if ip in blocs[s["nodeName"]] else "NON"
```

Avec kindnet :

```sortie
deux-noeuds  podCIDR 10.244.0.0/24
deux-noeuds-m02 podCIDR 10.244.1.0/24
  ch39/p-deux-noeuds                            deux-noeuds  10.244.0.8      oui
  ch39/p-deux-noeuds-m02                        deux-noeuds-m02 10.244.1.2      oui
  default/vitrine-577cf576cf-4xkbz              deux-noeuds  10.244.0.4      oui
  ...
  kube-system/coredns-559f6c778d-s8277          deux-noeuds  10.244.0.2      oui
```

Avec Calico :

```sortie
calico       podCIDR 10.244.0.0/24
calico-m02   podCIDR 10.244.1.0/24
  ch39/p-calico                                 calico       10.244.15.203   NON
  ch39/p-calico-m02                             calico-m02   10.244.228.3    NON
  kube-system/calico-kube-controllers-db57f7644-bv86v calico       10.244.15.200   NON
  kube-system/coredns-559f6c778d-4wlmp          calico       10.244.15.201   NON
```

Avec Cilium, toutes les réponses sont `oui`. Le gestionnaire de contrôleurs attribue un `podCIDR` à chaque nœud dans tous les cas, mais c'est le greffon qui décide de s'en servir. kindnet l'utilise tel quel ; Cilium, dans son mode `cluster-pool`, découpe le même espace `10.244.0.0/16` en blocs de 256 adresses, et tombe ici sur les mêmes. Calico l'ignore complètement et prend ses adresses dans ses propres blocs de 64. Il n'y a là aucune erreur : le `podCIDR` n'est qu'une suggestion. Mais un outil qui en déduirait le nœud d'un Pod à partir de son adresse se tromperait sur un cluster Calico.

</details>

:::exercice[Exercice 3 : le compte des octets]

L'encapsulation IP dans IP coûte 20 octets, et Calico règle le MTU des Pods à 1480. VXLAN coûte 50 octets, et Cilium règle le MTU à 1450. Détaillez ces 50 octets. Que deviendraient ces valeurs si le réseau des nœuds acceptait des trames de 9000 octets (*jumbo frames*), et pourquoi est-ce intéressant ?

:::

<details>
<summary>Corrigé</summary>

VXLAN transporte une trame Ethernet entière : l'en-tête Ethernet intérieur (14 octets), dans un en-tête VXLAN (8 octets), dans un datagramme UDP (8 octets), dans un paquet IP entre les nœuds (20 octets), soit 14 + 8 + 8 + 20 = 50 octets de plus que le paquet IP du Pod. L'en-tête Ethernet extérieur ne compte pas, puisque le MTU se mesure au niveau IP. IP dans IP n'ajoute qu'un en-tête IP, 20 octets. Avec un réseau de nœuds à 9000 octets, les MTU des Pods passeraient à 8980 et 8950. L'intérêt est double : le coût relatif de l'encapsulation devient négligeable (50 octets sur 9000, au lieu de 50 sur 1500, soit 0,6 % au lieu de 3,3 %), et chaque paquet transporte six fois plus de données, ce qui réduit d'autant le nombre de paquets à traiter pour un même débit.

</details>

:::exercice[Exercice 4 : une identité dans le tunnel]

Dans la capture VXLAN, le champ `instance` vaut 22446 à l'aller et 13837 au retour. Retrouvez, dans les sorties de `cilium-dbg`, à quoi correspondent ces deux nombres. Que se passerait-il pour ces numéros si l'on créait un second Pod avec exactement les mêmes étiquettes que `p-cilium-m02`, dans le même namespace ?

:::

<details>
<summary>Corrigé</summary>

22446 est l'identité de `10.244.1.87`, le Pod `p-cilium-m02` (champ `sec_id` de la table des points de terminaison, et `identity` dans l'`ipcache`) ; 13837 est celle de `10.244.0.132`, le Pod `p-cilium`. Cilium attribue une identité par combinaison d'étiquettes de sécurité (les étiquettes du Pod, son namespace, son ServiceAccount), pas par Pod : un second Pod avec les mêmes étiquettes, dans le même namespace et avec le même ServiceAccount, recevrait la même identité, 22446. C'est ce qui rend les politiques de Cilium économes : une règle « les Pods `web` peuvent parler aux Pods `api` » se traduit en quelques identités, quel que soit le nombre de répliques, et ne change pas quand un Pod est recréé avec une autre adresse. Les identités 1 à 255 sont réservées : 1 pour l'hôte, 2 pour tout ce qui est hors du cluster (`world`, celle du bloc de l'autre nœud dans l'`ipcache`), 4 pour les sondes de santé.

</details>

## Nettoyer

Dans chacun des trois profils, le namespace `ch39` contient les Pods de test et le Pod de débogage :

```bash
kubectl delete namespace ch39
```

Les profils `calico` et `cilium` resserviront au chapitre 41, et le profil `cilium` dès le chapitre 40. Pour libérer la mémoire en attendant, arrêtez celui qui tourne :

```bash
minikube stop -p cilium
```

Pour les supprimer définitivement, avec leurs disques, quand vous n'en aurez plus besoin : `minikube delete -p calico` et `minikube delete -p cilium`. L'image `netshoot` (208 Mo) est dans chacun des nœuds de ces profils, et disparaîtra avec eux.

[^modele]: Kubernetes, « Services, Load Balancing, and Networking », section *The Kubernetes network model*, et « Cluster Networking ». [kubernetes.io/docs/concepts/services-networking](https://kubernetes.io/docs/concepts/services-networking/), [kubernetes.io/docs/concepts/cluster-administration/networking](https://kubernetes.io/docs/concepts/cluster-administration/networking/)

[^cni]: Container Network Interface, « CNI Specification » : configuration, commandes `ADD`, `DEL` et `CHECK`, résultat. [github.com/containernetworking/cni/blob/main/SPEC.md](https://github.com/containernetworking/cni/blob/main/SPEC.md)

[^calico-faq]: Calico, « Frequently asked questions », *Why does my container have a route to 169.254.1.1?* ; et « Overlay networking » pour les modes IP dans IP et VXLAN. [docs.tigera.io/calico/latest/reference/faq](https://docs.tigera.io/calico/latest/reference/faq), [docs.tigera.io/calico/latest/networking/configuring/vxlan-ipip](https://docs.tigera.io/calico/latest/networking/configuring/vxlan-ipip)

[^mtu]: Calico, « Configure MTU to maximize network performance » ; Cilium, « Routing », section *Encapsulation*. [docs.tigera.io/calico/latest/networking/configuring/mtu](https://docs.tigera.io/calico/latest/networking/configuring/mtu), [docs.cilium.io/en/stable/network/concepts/routing](https://docs.cilium.io/en/stable/network/concepts/routing/)
