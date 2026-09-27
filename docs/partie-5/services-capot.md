---
title: Les Services sous le capot
sidebar_label: 40. Les Services sous le capot
description: "Ce qui se cache derrière l'adresse d'un Service : EndpointSlices et kube-proxy, les règles iptables et leurs tirages, conntrack, le mode nftables, la fin annoncée d'IPVS, Cilium sans kube-proxy qui traduit l'adresse dès connect(), CoreDNS et le coût de ndots, et l'adresse du client derrière un NodePort."
partie: 5
chapitre: '40'
---

import serviceIptables from '@site/src/figures/service-iptables.svg';
import serviceTroisModes from '@site/src/figures/service-trois-modes.svg';
import ParcoursService from '@site/src/components/ParcoursService';

Depuis un Pod, envoyez un `ping` au Service `web`, puis la requête HTTP la plus simple :

```bash
kubectl -n ch40 exec client -- sh -c 'ping -c 3 -W 1 web; echo code $?; curl -s http://web/hostname; echo'
```

```sortie
PING web.ch40.svc.cluster.local (10.101.223.47) 56(84) bytes of data.

--- web.ch40.svc.cluster.local ping statistics ---
3 packets transmitted, 0 received, 100% packet loss, time 2077ms

code 1
web-cc9cbd757-8pbdt
```

Le `ping` se perd, et la requête HTTP reçoit une réponse, d'un Pod nommé `web-...-8pbdt`. Le nom se résout bien, l'adresse `10.101.223.47` est la même dans les deux cas. Si un routeur ou une machine portait cette adresse, il répondrait au moins au `ping`. C'est qu'aucune machine ne la porte : ni un nœud, ni un Pod, ni une interface. L'adresse d'un Service n'existe que sous la forme de **règles**, écrites sur chaque nœud, qui disent quoi faire d'un paquet TCP ou UDP adressé à tel port de cette adresse. Un paquet ICMP ne correspond à aucune règle, et n'a nulle part où aller.

Ce chapitre ouvre ces règles. On les lira telles que kube-proxy les écrit, dans ses trois modes (iptables, nftables, IPVS), puis on les verra disparaître au profit des programmes eBPF de Cilium, qui traduisent l'adresse avant même que le paquet ne soit construit. On finira par la première étape de toute requête vers un Service, qu'on oublie volontiers : la résolution du nom, par CoreDNS.

Deux clusters servent ici : le profil `deux-noeuds` (kindnet et kube-proxy), puis le profil `cilium` du chapitre 39. Le fichier `web.yaml` de [l'archive services-capot](pathname:///kits/services-capot.tar.gz) crée trois répliques d'un petit serveur qui répond par le nom de son Pod, leur Service, et un Pod `client` muni d'outils réseau (`curl`, `dig`, `tcpdump`), placé sur le nœud qui n'est pas le plan de contrôle.

```bash
minikube start -p deux-noeuds
kubectl create namespace ch40
kubectl -n ch40 apply -f web.yaml
```

## Un Service, deux objets, un agent par nœud

```bash
kubectl -n ch40 get svc web
kubectl -n ch40 get endpointslices -l kubernetes.io/service-name=web
kubectl -n ch40 get pods -o custom-columns=POD:.metadata.name,IP:.status.podIP,NOEUD:.spec.nodeName
```

```sortie
NAME   TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
web    ClusterIP   10.101.223.47   <none>        80/TCP    1s
NAME        ADDRESSTYPE   PORTS   ENDPOINTS                          AGE
web-c67jr   IPv4          8080    10.244.1.7,10.244.0.9,10.244.1.8   1s
POD                   IP           NOEUD
client                10.244.1.9   deux-noeuds-m02
web-cc9cbd757-7x8bd   10.244.1.8   deux-noeuds-m02
web-cc9cbd757-dhmtd   10.244.1.7   deux-noeuds-m02
web-cc9cbd757-ft499   10.244.0.9   deux-noeuds
```

Un Service est une promesse en deux objets. Le Service lui-même porte l'adresse virtuelle, la **ClusterIP**, tirée par l'API server dans une plage réservée (`10.96.0.0/12` sur minikube), et le port. Une **EndpointSlice**, tenue à jour par un contrôleur du gestionnaire de contrôleurs (chapitre 36), liste les adresses des Pods prêts qui correspondent au sélecteur, avec leur port réel, 8080. Quand un Pod devient prêt, s'arrête ou échoue à sa sonde, c'est cette tranche qui change, en quelques dizaines de millisecondes.

Reste à faire quelque chose de ces deux objets. C'est le rôle de **kube-proxy**, un DaemonSet dont chaque Pod surveille les Services et les EndpointSlices, et traduit leur contenu en règles du noyau de son nœud[^proxies]. Il n'est traversé par aucun paquet : malgré son nom, ce n'est pas un proxy (il l'a été, dans les toutes premières versions de Kubernetes). C'est un contrôleur, qui écrit des règles et laisse le noyau les appliquer.

## Le mode iptables

```bash
kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E '^mode'
KP=$(kubectl -n kube-system get pods -l k8s-app=kube-proxy --field-selector spec.nodeName=deux-noeuds-m02 -o name)
kubectl -n kube-system logs $KP | grep -E 'Using .* Proxier'
kubectl -n kube-system exec $KP -- iptables-nft-save -t nat | grep -E 'ch40/web'
```

```sortie
mode: iptables
I0927 04:32:20.642870       1 server_linux.go:144] "Using iptables Proxier"
-A KUBE-SEP-5UXWIQPGM76JJN4E -s 10.244.0.9/32 -m comment --comment "ch40/web:http" -j KUBE-MARK-MASQ
-A KUBE-SEP-5UXWIQPGM76JJN4E -p tcp -m comment --comment "ch40/web:http" -m tcp -j DNAT --to-destination 10.244.0.9:8080
-A KUBE-SEP-6STEJ6R4P2SZLFDQ -s 10.244.1.8/32 -m comment --comment "ch40/web:http" -j KUBE-MARK-MASQ
-A KUBE-SEP-6STEJ6R4P2SZLFDQ -p tcp -m comment --comment "ch40/web:http" -m tcp -j DNAT --to-destination 10.244.1.8:8080
-A KUBE-SEP-ZEO37YB32KABCENC -s 10.244.1.7/32 -m comment --comment "ch40/web:http" -j KUBE-MARK-MASQ
-A KUBE-SEP-ZEO37YB32KABCENC -p tcp -m comment --comment "ch40/web:http" -m tcp -j DNAT --to-destination 10.244.1.7:8080
-A KUBE-SERVICES -d 10.101.223.47/32 -p tcp -m comment --comment "ch40/web:http cluster IP" -m tcp --dport 80 -j KUBE-SVC-LJMWSUCFDC3EU5W3
-A KUBE-SVC-LJMWSUCFDC3EU5W3 ! -s 10.244.0.0/16 -d 10.101.223.47/32 -p tcp -m comment --comment "ch40/web:http cluster IP" -m tcp --dport 80 -j KUBE-MARK-MASQ
-A KUBE-SVC-LJMWSUCFDC3EU5W3 -m comment --comment "ch40/web:http -> 10.244.0.9:8080" -m statistic --mode random --probability 0.33333333349 -j KUBE-SEP-5UXWIQPGM76JJN4E
-A KUBE-SVC-LJMWSUCFDC3EU5W3 -m comment --comment "ch40/web:http -> 10.244.1.7:8080" -m statistic --mode random --probability 0.50000000000 -j KUBE-SEP-ZEO37YB32KABCENC
-A KUBE-SVC-LJMWSUCFDC3EU5W3 -m comment --comment "ch40/web:http -> 10.244.1.8:8080" -j KUBE-SEP-6STEJ6R4P2SZLFDQ
```

(Le Pod kube-proxy contient les outils `iptables` ; on choisit `iptables-nft-save`, parce que le nœud porte aussi d'anciennes tables « legacy » laissées par Docker, que l'outil par défaut afficherait à la place.) Tout le Service tient dans ces onze règles de la table `nat`, qui agit sur le premier paquet de chaque connexion. On les lit dans l'ordre où un paquet les traverse, et la figure 40.1 les met en forme.

La chaîne `KUBE-SERVICES` reçoit tout ce qui sort des Pods ou arrive sur le nœud. Elle contient une règle par port de Service ; celle de `web` reconnaît la destination `10.101.223.47`, port 80, et saute vers la chaîne du Service, `KUBE-SVC-...`. Les noms de chaînes sont des empreintes, pour rester sous la limite de longueur d'iptables, mais les commentaires disent de quoi il s'agit.

La chaîne du Service choisit un point de terminaison, et c'est là que se trouve le détail le plus élégant. iptables ne sait pas tirer « un nombre entre 1 et 3 » ; il sait seulement qu'une règle s'applique avec une certaine probabilité. kube-proxy écrit donc une règle par Pod, avec des probabilités croissantes : la première s'applique une fois sur trois ; si elle ne s'est pas appliquée, la deuxième s'applique une fois sur deux ; sinon, la troisième s'applique toujours. Chaque Pod reçoit ainsi exactement un tiers des connexions : 1/3 pour le premier, 2/3 × 1/2 = 1/3 pour le deuxième, et le tiers restant pour le dernier. Avec n Pods, la i-ème règle tire avec la probabilité 1/(n - i + 1).

Chaque chaîne `KUBE-SEP-...` (*service endpoint*) fait enfin la traduction, `DNAT` : la destination `10.101.223.47:80` devient `10.244.0.9:8080`. La règle `KUBE-MARK-MASQ` qui la précède marque les rares paquets qui devront aussi changer d'adresse source : ceux d'un Pod qui s'appelle lui-même par son Service, ou ceux qui viennent de l'extérieur du réseau des Pods (la règle `! -s 10.244.0.0/16` de la chaîne du Service).

<Figure svg={serviceIptables} num="40.1" alt="Les règles iptables du Service ch40/web. 1, le Pod client, 10.244.1.9, envoie un SYN vers 10.101.223.47:80 ; la chaîne KUBE-SERVICES, qui a une règle par Service, reconnaît la destination 10.101.223.47/32 port 80 et saute vers KUBE-SVC-LJMWSUCFDC3EU5W3. 2, cette chaîne a trois règles : la première, avec une probabilité 0,333, vers le premier point de terminaison ; la deuxième, avec une probabilité 0,500, vers le deuxième ; la troisième, sans condition, vers le troisième. 3, les parts réelles sont 1/3, 2/3 fois 1/2, et le reste, 1/3. 4, chaque chaîne KUBE-SEP fait un DNAT : KUBE-SEP-5UXWIQPGM76JJN4E vers 10.244.0.9:8080, le Pod ft499, qui a reçu 88 connexions sur 300 ; KUBE-SEP-ZEO37YB32KABCENC vers 10.244.1.7:8080, le Pod dhmtd, 112 sur 300 ; KUBE-SEP-6STEJ6R4P2SZLFDQ vers 10.244.1.8:8080, le Pod 7x8bd, 100 sur 300. conntrack retient la traduction : les paquets suivants et la réponse ne repassent pas par les règles.">
Les règles de kube-proxy pour le Service `web`, lues dans l'ordre où un nouveau paquet les traverse. Les tirages successifs donnent à chaque Pod un tiers des connexions.
</Figure>

Vérifions la répartition, sur 300 connexions :

```bash
kubectl -n ch40 exec client -- sh -c 'for i in $(seq 1 300); do curl -s http://web/hostname; echo; done' | sort | uniq -c
```

```sortie
    100 web-cc9cbd757-7x8bd
    112 web-cc9cbd757-dhmtd
     88 web-cc9cbd757-ft499
```

100, 112 et 88 : ni une alternance régulière, ni un Pod favorisé, mais un tirage au hasard, avec les écarts qu'on attend de 300 tirages. Ce hasard porte sur les **connexions**, pas sur les requêtes : un client qui garde sa connexion ouverte, comme le font les clients HTTP/2 ou gRPC, parle toujours au même Pod, et un Service ne répartira pas sa charge. C'est une surprise fréquente quand on déploie un service gRPC derrière un Service ordinaire.

Pourquoi les paquets suivants d'une connexion ne sont-ils pas tirés au sort à leur tour ? Parce que les règles de la table `nat` ne voient que le premier. Le noyau enregistre la traduction décidée dans sa table de **suivi des connexions**, `conntrack`, et l'applique à tous les paquets suivants, dans les deux sens. Un Pod de débogage sur le nœud (chapitre 39) permet de la lire :

```bash
kubectl -n ch40 debug node/deux-noeuds-m02 --image=nicolaka/netshoot:v0.14 --profile=sysadmin -- sleep 3600
D=$(kubectl -n ch40 get pods -o name | grep node-debugger | cut -d/ -f2)
kubectl -n ch40 exec $D -- conntrack -L -p tcp --orig-dst 10.101.223.47
```

```sortie
tcp      6 115 TIME_WAIT src=10.244.1.9 dst=10.101.223.47 sport=41394 dport=80 src=10.244.1.8 dst=10.244.1.9 sport=8080 dport=41394 [ASSURED] mark=0 use=1
tcp      6 115 TIME_WAIT src=10.244.1.9 dst=10.101.223.47 sport=41164 dport=80 src=10.244.0.9 dst=10.244.1.9 sport=8080 dport=41164 [ASSURED] mark=0 use=1
tcp      6 117 TIME_WAIT src=10.244.1.9 dst=10.101.223.47 sport=55030 dport=80 src=10.244.1.7 dst=10.244.1.9 sport=8080 dport=55030 [ASSURED] mark=0 use=1
...
```

Chaque ligne contient deux quadruplets. Le premier est la connexion telle que le client l'a ouverte, vers `10.101.223.47:80` ; le second est la réponse attendue, qui viendra de `10.244.1.8:8080`. Quand la réponse arrive, le noyau la reconnaît dans cette table et lui rend l'adresse du Service comme source : le client ne voit jamais l'adresse du Pod. Une capture dans le Pod client montre d'où part le paquet :

```bash
kubectl -n ch40 exec client -- sh -c 'timeout 5 tcpdump -ni eth0 -c 1 "tcp[tcpflags] & tcp-syn != 0 and tcp[tcpflags] & tcp-ack == 0" & sleep 1; curl -s http://web/hostname; echo; wait'
```

```sortie
web-cc9cbd757-dhmtd
04:33:16.876150 IP 10.244.1.9.55282 > 10.101.223.47.80: Flags [S], seq 2647602473, win 64240, options [mss 1460,sackOK,TS val 3251590455 ecr 0,nop,wscale 10], length 0
```

Le SYN quitte le Pod adressé au Service. La traduction se fait ensuite, sur le nœud, dans les règles qu'on vient de lire.

Le défaut de ce mode tient à `KUBE-SERVICES` : ses règles sont lues les unes après les autres, et un cluster de 10 000 Services en a au moins autant. Chaque nouvelle connexion parcourt la liste jusqu'à trouver la sienne, et chaque changement d'un Service oblige kube-proxy à réécrire des tables entières. Ici, la table `nat` du nœud compte 49 règles ; sur les grands clusters, elle en compte des centaines de milliers, et la mise à jour se chiffre en secondes.

## Le mode nftables

nftables est le successeur d'iptables dans le noyau Linux, et son intérêt principal ici est de savoir faire une recherche dans une table au lieu de parcourir une liste. kube-proxy le prend en charge depuis Kubernetes 1.29, en version stable depuis la 1.33[^nftables]. Changeons de mode, en modifiant la configuration de kube-proxy puis en redémarrant ses Pods :

```bash
mode() {
  kubectl -n kube-system get cm kube-proxy -o json \
    | jq --arg m "$1" '.data["config.conf"] |= sub("\nmode: [a-z]*\n"; "\nmode: \($m)\n")' \
    | kubectl replace -f -
  kubectl -n kube-system rollout restart ds/kube-proxy
  kubectl -n kube-system rollout status ds/kube-proxy
}
mode nftables
```

```bash
kubectl -n kube-system logs $KP | grep -E 'Using .* Proxier'      # KP a changé : le relire comme plus haut
kubectl -n ch40 exec $D -- sh -c 'nft list table ip kube-proxy | sed -n "/map service-ips/,/^\t}/p"; nft list table ip kube-proxy | grep -A2 "chain service-.*ch40/web"'
```

```sortie
I0927 04:33:19.837986       1 server_linux.go:231] "Using nftables Proxier"
	map service-ips {
		type ipv4_addr . inet_proto . inet_service : verdict
		comment "ClusterIP, ExternalIP and LoadBalancer IP traffic"
		elements = { 10.96.0.10 . tcp . 53 : goto service-NWBZK7IH-kube-system/kube-dns/tcp/dns-tcp,
			     10.96.0.10 . udp . 53 : goto service-FY5PMXPG-kube-system/kube-dns/udp/dns,
			     10.101.223.47 . tcp . 80 : goto service-KQQRD225-ch40/web/tcp/http,
			     10.96.0.1 . tcp . 443 : goto service-2QRHZV4L-default/kubernetes/tcp/https,
			     10.96.0.10 . tcp . 9153 : goto service-AS2KJYAD-kube-system/kube-dns/tcp/metrics }
	}
	chain service-KQQRD225-ch40/web/tcp/http {
		meta l4proto tcp dnat ip to numgen random mod 3 map { 0 : 10.244.0.9 . 8080, 1 : 10.244.1.7 . 8080, 2 : 10.244.1.8 . 8080 }
	}
```

Toute la cascade de la figure 40.1 se réduit à deux étapes. La table `service-ips` associe à chaque triplet « adresse, protocole, port » la chaîne de son Service : une seule recherche, aussi rapide pour 5 Services que pour 50 000. La chaîne du Service tient en une ligne : `numgen random mod 3` tire un nombre entre 0 et 2, et une petite table donne la destination correspondante. La traduction, et le suivi des connexions qui la retient, restent les mêmes. kube-proxy a aussi effacé les règles iptables de l'ancien mode :

```bash
echo "règles KUBE-SVC iptables restantes : $(kubectl -n kube-system exec $KP -- iptables-nft-save -t nat | grep -c KUBE-SVC)"
kubectl -n ch40 exec client -- sh -c 'for i in $(seq 1 30); do curl -s http://web/hostname; echo; done' | sort | uniq -c
```

```sortie
règles KUBE-SVC iptables restantes : 0
      8 web-cc9cbd757-7x8bd
      7 web-cc9cbd757-dhmtd
     15 web-cc9cbd757-ft499
```

(Sur 30 connexions seulement, les écarts du hasard sont plus marqués.)

## Et IPVS ?

Il existe un troisième mode, IPVS, qui confie la répartition au répartiteur de charge intégré au noyau. Il a longtemps été conseillé pour les gros clusters, justement parce qu'il évite la liste d'iptables. Essayons-le :

```bash
mode ipvs
kubectl -n kube-system logs $KP | grep -E 'Using .* Proxier|deprecated'
kubectl -n ch40 exec $D -- ipvsadm -Ln -t 10.101.223.47:80
```

```sortie
I0927 04:33:27.872797       1 server_linux.go:191] "Using ipvs Proxier"
E0927 04:33:27.872809       1 server_linux.go:193] "The ipvs proxier has been deprecated and will be disabled by default in Kubernetes 1.40 and removed in Kubernetes 1.43. Migrate to the 'nftables' proxier instead."
Prot LocalAddress:Port Scheduler Flags
  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
TCP  10.101.223.47:80 rr
  -> 10.244.0.9:8080              Masq    1      0          0         
  -> 10.244.1.7:8080              Masq    1      0          0         
  -> 10.244.1.8:8080              Masq    1      0          0         
```

kube-proxy répond lui-même : le mode IPVS est déprécié, il sera désactivé par défaut en 1.40 et retiré en 1.43, et nftables est son successeur désigné. Un cluster qui l'utilise encore a donc quelques versions devant lui pour migrer. Le répartiteur `rr` (*round robin*) sert les Pods à tour de rôle, 10, 10 et 10 sur 30 connexions. Revenons au mode par défaut pour la suite :

```bash
mode iptables
```

## Sans kube-proxy : Cilium

Les trois modes de kube-proxy traduisent l'adresse **sur le chemin** du paquet, dans le nœud. Cilium, qui a déjà remplacé les routes par des programmes eBPF au chapitre 39, sait aussi remplacer kube-proxy, et le fait plus tôt encore. Passons sur le profil `cilium`, où minikube l'a installé avec kube-proxy à côté :

```bash
minikube stop -p deux-noeuds
minikube start -p cilium
kubectl create namespace ch40
kubectl -n ch40 apply -f web.yaml
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -E '^KubeProxyReplacement'
kubectl -n ch40 exec client -- sh -c 'timeout 5 tcpdump -ni eth0 -c 1 "tcp[tcpflags] & tcp-syn != 0 and tcp[tcpflags] & tcp-ack == 0" & sleep 1; curl -s http://web/hostname; echo; wait'
```

```sortie
KubeProxyReplacement:    False   
web-cc9cbd757-zrt22
04:37:01.756170 IP 10.244.0.46.43336 > 10.102.39.104.80: Flags [S], seq 593624381, win 64860, options [mss 1410,sackOK,TS val 760402145 ecr 0,nop,wscale 10], length 0
```

Même tableau qu'avec kindnet : le SYN part vers l'adresse du Service. Le script `cilium-sans-kube-proxy.sh` de l'archive fait la bascule en suivant la procédure de la documentation de Cilium[^kpr] : il configure Cilium pour qu'il gère les Services, supprime kube-proxy et les règles qu'il a laissées sur chaque nœud, puis redémarre les agents.

```bash
./cilium-sans-kube-proxy.sh
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -E '^KubeProxyReplacement'
```

```sortie
configmap/cilium-config patched
daemonset.apps/cilium replaced
deployment.apps/cilium-operator replaced
daemonset.apps "kube-proxy" deleted from kube-system namespace
configmap "kube-proxy" deleted from kube-system namespace
daemonset.apps/cilium restarted
deployment.apps/cilium-operator restarted
daemon set "cilium" successfully rolled out
KubeProxyReplacement:    True   [eth0  192.168.76.3 (Direct Routing)]
```

:::panne[Après le retrait de kube-proxy, les Pods de Cilium restent en Init:Error]

C'est le problème de la poule et de l'œuf, et je l'ai rencontré en préparant ce chapitre. Ma première bascule se contentait de dire à Cilium, dans sa configuration, l'adresse réelle de l'API server. Mais les Pods de Cilium redémarrés restaient en `Init:Error`, et le journal de leur premier conteneur d'initialisation disait :

```sortie
level=fatal msg="Build config failed" subsys=cilium-dbg error="failed to start: Get \"https://10.96.0.1:443/api/v1/namespaces/kube-system\": dial tcp 10.96.0.1:443: i/o timeout"
```

Tout Pod reçoit l'adresse de l'API server sous la forme d'un Service, `kubernetes`, à l'adresse `10.96.0.1`, par les variables d'environnement `KUBERNETES_SERVICE_HOST` et `KUBERNETES_SERVICE_PORT`. Sans kube-proxy, cette adresse n'est plus traduite par personne, tant que Cilium n'a pas démarré ; et Cilium ne démarre pas, puisqu'il ne joint pas l'API server. La sortie est de donner à tous les conteneurs de Cilium, conteneurs d'initialisation compris, l'adresse réelle du nœud de contrôle dans ces deux variables. C'est ce que fait le script, et ce que fait le chart Helm de Cilium quand on lui donne `k8sServiceHost` et `k8sServicePort`.

:::

Où sont passés les Services ? Dans des tables eBPF, que l'agent de chaque nœud remplit :

```bash
A=$(kubectl -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName=cilium-m02 -o name)
kubectl -n kube-system exec $A -c cilium-agent -- cilium-dbg service list | grep -A2 -E '^ID|10.102.39.104'
kubectl -n ch40 get pods -l app=web -o custom-columns=POD:.metadata.name,IP:.status.podIP
kubectl -n kube-system exec $A -c cilium-agent -- cilium-dbg status --verbose | sed -n '/KubeProxyReplacement Details/,/Session Affinity/p'
```

```sortie
ID   Frontend                 Service Type   Backend                               
1    10.111.189.143:443/TCP   ClusterIP      1 => 192.168.76.3:4244/TCP (active)   
2    10.96.0.10:53/TCP        ClusterIP      1 => 10.244.0.100:53/TCP (active)     
6    10.102.39.104:80/TCP     ClusterIP      1 => 10.244.0.42:8080/TCP (active)    
                                             2 => 10.244.0.44:8080/TCP (active)    
                                             3 => 10.244.1.177:8080/TCP (active)   
POD                   IP
web-cc9cbd757-5kkrh   10.244.0.44
web-cc9cbd757-jv8vt   10.244.1.177
web-cc9cbd757-zrt22   10.244.0.42
KubeProxyReplacement Details:
  Status:               True
  Socket LB:            Enabled
  Socket LB Tracing:    Enabled
  Socket LB Coverage:   Full
  Devices:              eth0  192.168.76.3 (Direct Routing)
  Mode:                 SNAT
  Backend Selection:    Random
  Session Affinity:     Enabled
```

Le Service `web`, son adresse et ses trois Pods, dans une table que les programmes eBPF consultent en une recherche, comme la table `service-ips` de nftables. Mais une ligne change tout : `Socket LB: Enabled`. Cilium attache aussi un programme eBPF aux **appels système** qui ouvrent les connexions. Quand un programme d'un Pod appelle `connect()` vers `10.102.39.104:80`, ce programme intercepte l'appel, tire un Pod au hasard et réécrit la destination, avant que le noyau ne construise le moindre paquet. La même capture que tout à l'heure le montre :

```bash
kubectl -n ch40 exec client -- sh -c 'timeout 5 tcpdump -ni eth0 -c 1 "tcp[tcpflags] & tcp-syn != 0 and tcp[tcpflags] & tcp-ack == 0" & sleep 1; curl -s http://web/hostname; echo; wait'
```

```sortie
web-cc9cbd757-jv8vt
04:37:50.573723 IP 10.244.0.46.56574 > 10.244.1.177.8080: Flags [S], seq 578408368, win 64860, options [mss 1410,sackOK,TS val 405254911 ecr 0,nop,wscale 10], length 0
```

Le SYN quitte le Pod client **déjà adressé au Pod** `10.244.1.177:8080`. Il n'y aura pas de traduction en route, ni d'entrée dans la table `conntrack` du nœud pour cette traduction : pour le réseau, c'est une connexion ordinaire de Pod à Pod, comme au chapitre 39. L'application, elle, n'en sait rien : `getpeername()` lui rendrait l'adresse du Service, que Cilium garde en mémoire pour elle. Et il ne reste rien des chaînes de kube-proxy dans les tables du nœud :

```sortie
règles des chaînes de kube-proxy : 0
chaînes KUBE restantes : :KUBE-FIREWALL :KUBE-IPTABLES-HINT :KUBE-KUBELET-CANARY 
```

Les trois chaînes restantes appartiennent au kubelet, pas à kube-proxy. La figure 40.2 résume les trois façons de faire.

<Figure svg={serviceTroisModes} num="40.2" alt="Où l'adresse du Service est traduite, selon le mode. Avec kube-proxy en mode iptables, une chaîne de règles est parcourue à la première connexion : le Pod client envoie un SYN vers la ClusterIP, puis KUBE-SERVICES, une règle par Service lues dans l'ordre, puis KUBE-SVC avec ses tirages 1/3 et 1/2, puis KUBE-SEP, DNAT vers le Pod, retenu par conntrack. Avec kube-proxy en mode nftables, une recherche dans une table, quel que soit le nombre de Services : le SYN vers la ClusterIP, la table service-ips qui associe adresse, protocole et port à une chaîne, puis numgen random mod 3 et le DNAT vers le Pod choisi, retenu par conntrack. Avec Cilium sans kube-proxy, la destination est réécrite avant même que le paquet existe : le connect() du Pod client vers la ClusterIP est intercepté par un programme eBPF, et le SYN part déjà adressé au Pod, sans traduction en route.">
Où l'adresse d'un Service devient l'adresse d'un Pod. Plus on descend, plus la traduction a lieu tôt, et moins elle coûte.
</Figure>

Le composant ci-dessous rejoue les trois trajets avec les valeurs de ce chapitre. Envoyez une connexion pour en suivre les étapes, ou 300 pour voir la répartition se former.

<ParcoursService />

## Le nom avant l'adresse : CoreDNS

Avant tout cela, il a fallu que le client transforme `web` en `10.101.223.47`. De retour sur le profil `deux-noeuds`, regardons ce que Kubernetes a mis dans le fichier de configuration du résolveur de chaque Pod :

```bash
kubectl -n ch40 exec client -- cat /etc/resolv.conf
kubectl -n kube-system get deploy coredns -o jsonpath='{.spec.template.spec.containers[0].image}, {.spec.replicas} réplique(s){"\n"}'
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'
```

```sortie
search ch40.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
registry.k8s.io/coredns/coredns:v1.14.6, 1 réplique(s)
.:53 {
    log
    errors
    health {
       lameduck 5s
    }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    prometheus :9153
    hosts {
       192.168.58.1 host.minikube.internal
       fallthrough
    }
    forward . /etc/resolv.conf {
       max_concurrent 1000
    }
    cache 30 {
       disable success cluster.local
       disable denial cluster.local
    }
    loop
    reload
    loadbalance
}
```

Le serveur de noms, `10.96.0.10`, est lui-même un Service, celui de CoreDNS, qui passe par les mêmes règles que `web`. La configuration de CoreDNS est une suite de greffons, appliqués dans un ordre fixe. `kubernetes` répond aux noms en `cluster.local` à partir des Services et des EndpointSlices qu'il surveille, comme kube-proxy. `hosts` ajoute le nom `host.minikube.internal`, qui désigne le poste hôte (chapitre 24). `forward` transmet tout le reste au serveur de noms du nœud. `cache` garde les réponses 30 secondes, sauf celles du cluster, qui changent trop vite. Et minikube active `log`, qui écrit chaque requête dans le journal de CoreDNS[^coredns].

Les deux autres lignes du fichier du résolveur sont celles qui comptent. `search` donne trois domaines à essayer derrière un nom incomplet ; c'est ce qui permet d'écrire `web` au lieu de `web.ch40.svc.cluster.local`. Et `options ndots:5` dit quand les essayer : tout nom qui contient **moins de cinq points** est d'abord complété par chacun des domaines de recherche, avant d'être essayé tel quel[^resolv]. Le journal de CoreDNS montre ce que cela donne, pour trois requêtes HTTP du Pod client :

```bash
IP=$(kubectl -n ch40 get pod client -o jsonpath='{.status.podIP}')
for u in http://example.com/ http://example.com./ http://web/hostname; do
  T=$(date -u +%Y-%m-%dT%H:%M:%SZ); sleep 1
  kubectl -n ch40 exec client -- curl -s -m 5 -o /dev/null -w "$u : %{http_code}\n" $u
  sleep 1; kubectl -n kube-system logs deploy/coredns --since-time=$T | grep "$IP" | sed -E 's/^\[INFO\] //' | cut -c1-150
done
```

```sortie
http://example.com/ : 200
10.244.1.9:59021 - 43698 "AAAA IN example.com.ch40.svc.cluster.local. udp 75 false 1232" NXDOMAIN qr,aa,rd 145 0.000384109s
10.244.1.9:59021 - 48142 "A IN example.com.ch40.svc.cluster.local. udp 75 false 1232" NXDOMAIN qr,aa,rd 145 0.000439778s
10.244.1.9:59021 - 51306 "A IN example.com.svc.cluster.local. udp 58 false 1232" NXDOMAIN qr,aa,rd 140 0.000185978s
10.244.1.9:59021 - 51285 "AAAA IN example.com.svc.cluster.local. udp 58 false 1232" NXDOMAIN qr,aa,rd 140 0.000173281s
10.244.1.9:59021 - 754 "A IN example.com.cluster.local. udp 54 false 1232" NXDOMAIN qr,aa,rd 136 0.000162519s
10.244.1.9:59021 - 25594 "AAAA IN example.com.cluster.local. udp 54 false 1232" NXDOMAIN qr,aa,rd 136 0.000181573s
10.244.1.9:59021 - 31124 "A IN example.com. udp 40 false 1232" NOERROR qr,rd,ra 83 0.010630818s
10.244.1.9:59021 - 23890 "AAAA IN example.com. udp 40 false 1232" NOERROR qr,rd,ra 107 0.010758659s
http://example.com./ : 200
10.244.1.9:36487 - 9921 "AAAA IN example.com. udp 52 false 1232" NOERROR qr,aa,rd,ra 107 0.000219247s
10.244.1.9:36487 - 37928 "A IN example.com. udp 52 false 1232" NOERROR qr,aa,rd,ra 83 0.000203854s
http://web/hostname : 200
10.244.1.9:58726 - 39705 "A IN web.ch40.svc.cluster.local. udp 67 false 1232" NOERROR qr,aa,rd 86 0.000353295s
10.244.1.9:58726 - 45457 "AAAA IN web.ch40.svc.cluster.local. udp 67 false 1232" NOERROR qr,aa,rd 137 0.00054453s
```

Huit requêtes pour `example.com` : le nom n'a qu'un point, moins de cinq, et le résolveur essaie donc d'abord `example.com.ch40.svc.cluster.local`, puis `example.com.svc.cluster.local`, puis `example.com.cluster.local`, chaque fois en IPv4 (`A`) et en IPv6 (`AAAA`), et reçoit six refus (`NXDOMAIN`) avant de demander enfin le vrai nom. Avec un point final, `example.com.`, le nom est complet, et deux requêtes suffisent. Pour `web`, le premier domaine de recherche est le bon, et deux requêtes suffisent aussi. Les refus sont rapides, un tiers de milliseconde chacun, mais un service qui appelle des API extérieures à chaque requête multiplie par quatre la charge de CoreDNS, et c'est une cause classique de latences inexpliquées et de CoreDNS saturés. Le réglage de `ndots` est l'objet de l'exercice 3.

Enfin, un Service n'a pas toujours d'adresse. Un Service **headless** (`clusterIP: None`, chapitre 26) n'a ni ClusterIP ni règles de kube-proxy ; le DNS renvoie directement les adresses des Pods. Les enregistrements `SRV` donnent, en plus, les ports :

```bash
kubectl -n ch40 apply -f web-headless.yaml
kubectl -n ch40 exec client -- dig +short web-headless.ch40.svc.cluster.local
kubectl -n ch40 exec client -- dig +short SRV _http._tcp.web.ch40.svc.cluster.local
kubectl -n ch40 exec client -- dig +short SRV _http._tcp.web-headless.ch40.svc.cluster.local
```

```sortie
10.244.0.9
10.244.1.7
10.244.1.8
0 100 80 web.ch40.svc.cluster.local.
0 33 8080 10-244-0-9.web-headless.ch40.svc.cluster.local.
0 33 8080 10-244-1-7.web-headless.ch40.svc.cluster.local.
0 33 8080 10-244-1-8.web-headless.ch40.svc.cluster.local.
```

Pour le Service ordinaire, un seul enregistrement : le port 80 du Service. Pour le Service headless, un par Pod, avec son port réel, 8080, et un nom construit à partir de son adresse. C'est le client qui choisit, ce qui convient aux bases de données répliquées ou aux clients gRPC qui veulent répartir eux-mêmes leurs requêtes.

## Depuis l'extérieur : l'adresse du client

Un Service de type NodePort ouvre le même port sur tous les nœuds (chapitre 20). Le fichier `web-nodeport.yaml` publie `web` sur le port 30080. Le Pod de débogage, qui partage le réseau du nœud `192.168.58.3`, joue le client extérieur, et interroge le nœud `192.168.58.2`. Le serveur `agnhost` répond, sous `/clientip`, par l'adresse d'où il voit venir la requête :

```bash
kubectl -n ch40 apply -f web-nodeport.yaml
kubectl -n ch40 exec $D -- sh -c 'for i in 1 2 3 4 5 6; do curl -s http://192.168.58.2:30080/clientip; echo; done' | sort
kubectl -n ch40 patch svc web-nodeport -p '{"spec":{"externalTrafficPolicy":"Local"}}'
kubectl -n ch40 exec $D -- sh -c 'for i in 1 2 3 4 5 6; do curl -s -m 2 http://192.168.58.2:30080/clientip; echo; done' | sort
```

```sortie
# externalTrafficPolicy: Cluster
10.244.0.1:1849
192.168.58.2:12157
192.168.58.2:25287
192.168.58.2:33786
192.168.58.2:50993
192.168.58.2:60386
# externalTrafficPolicy: Local
192.168.58.3:50792
192.168.58.3:50796
192.168.58.3:50810
192.168.58.3:50816
192.168.58.3:50818
192.168.58.3:50822
```

Avec la politique par défaut, `Cluster`, le nœud qui reçoit la connexion peut l'envoyer à un Pod de n'importe quel nœud. Pour que la réponse revienne par lui, et soit retraduite par son `conntrack`, il doit aussi remplacer l'adresse source par la sienne : le Pod voit `192.168.58.2` (ou `10.244.0.1`, l'adresse du nœud du côté de la veth, quand le Pod choisi est sur ce nœud), jamais `192.168.58.3`, le vrai client. Avec `Local`, le nœud n'envoie qu'à ses propres Pods, n'a plus besoin de traduire la source, et le Pod voit l'adresse réelle du client. Le prix : un nœud sans Pod local refuse les connexions, et la charge se répartit par nœud, pas par Pod. C'est le compromis à connaître quand une application doit journaliser ou filtrer les adresses de ses clients[^proxies].

## Exercices

:::exercice[Exercice 1 : quatre Pods]

Passez `web` à quatre répliques. Quelles probabilités kube-proxy va-t-il écrire dans la chaîne du Service ? Écrivez en Python un programme qui lit la sortie de `iptables-nft-save -t nat` et calcule, pour chaque Service, la part réelle de connexions qu'il envoie à chaque point de terminaison, puis vérifiez votre prédiction.

:::

<details>
<summary>Corrigé</summary>

Avec n = 4, la i-ème règle tire avec 1/(n - i + 1) : 1/4, 1/3, 1/2, puis la dernière sans condition. Le programme parcourt les règles des chaînes `KUBE-SVC-...` et reporte la probabilité d'arriver jusqu'à chaque règle :

```python title="probabilites.py (extrait)"
for (chaine, service), liste in sorted(regles.items(), key=lambda x: x[0][1]):
    print(f"{service} ({len(liste)} points de terminaison)")
    reste = 1.0                     # probabilité d'arriver jusqu'à cette règle
    for p, destination in liste:
        part = reste * (p if p is not None else 1.0)
        print(f"  {destination:22} tirage {p if p is not None else '(dernière)':>14}  part réelle {part:.3f}")
        reste -= part
```

```bash
kubectl -n ch40 scale deploy web --replicas=4
kubectl -n kube-system exec $KP -- iptables-nft-save -t nat | python3 probabilites.py
```

```sortie
ch40/web:http (4 points de terminaison)
  10.244.0.10:8080       tirage           0.25  part réelle 0.250
  10.244.0.9:8080        tirage  0.33333333349  part réelle 0.250
  10.244.1.7:8080        tirage            0.5  part réelle 0.250
  10.244.1.8:8080        tirage     (dernière)  part réelle 0.250
```

(J'ai gardé le bloc du Service `web` ; le programme affiche aussi `web-nodeport`, qui a les mêmes Pods.) Un quart chacun. kube-proxy réécrit toutes les probabilités à chaque ajout ou retrait d'un Pod, ce qui fait partie du coût de ce mode sur les gros Services.

</details>

:::exercice[Exercice 2 : plus aucun Pod]

Passez `web` à zéro réplique, attendez que les Pods aient disparu, puis appelez le Service depuis le client. Que répond `curl`, en combien de temps, et pourquoi ? Cherchez la règle responsable dans `iptables-nft-save` (sans `-t nat`).

:::

<details>
<summary>Corrigé</summary>

```bash
kubectl -n ch40 scale deploy web --replicas=0
kubectl -n ch40 wait --for=delete pod -l app=web
kubectl -n kube-system exec $KP -- iptables-nft-save | grep 'ch40/web:http has no endpoints'
kubectl -n ch40 exec client -- curl -sS -m 3 http://web/hostname; echo "code $?"
```

```sortie
-A KUBE-SERVICES -d 10.101.223.47/32 -p tcp -m comment --comment "ch40/web:http has no endpoints" -m tcp --dport 80 -j REJECT --reject-with icmp-port-unreachable
curl: (7) Failed to connect to web port 80 after 1 ms: Could not connect to server
code 7
```

Refus en une milliseconde. Quand un Service n'a plus de point de terminaison prêt, kube-proxy remplace ses règles de traduction par une règle de la table `filter` qui rejette la connexion avec un message ICMP « port injoignable » : le client échoue tout de suite, au lieu d'attendre l'expiration d'un délai. La différence est précieuse en panne : un client qui reçoit un refus immédiat peut basculer ou réessayer ; un client qui attend trente secondes bloque ses propres appelants. Attendez bien la disparition des Pods : pendant qu'ils s'arrêtent, la situation est plus confuse, et la première fois que j'ai fait l'essai, cinq secondes seulement après le `scale`, `curl` a attendu son délai au lieu d'être refusé.

</details>

:::exercice[Exercice 3 : moins de requêtes DNS]

Le fichier `ndots.yaml` crée un Pod client identique, mais avec `options ndots:1` dans sa configuration DNS (champ `dnsConfig` du Pod). Combien de requêtes DNS provoquent maintenant `http://example.com/` et `http://web/hostname` ? Quel est le risque de ce réglage ?

:::

<details>
<summary>Corrigé</summary>

```sortie
options ndots:1
http://example.com/ : 200
requêtes DNS : 2
http://web/hostname : 200
requêtes DNS : 2
```

Avec `ndots:1`, un nom qui contient au moins un point est essayé tel quel d'abord : `example.com` ne coûte plus que deux requêtes au lieu de huit. `web`, qui n'a aucun point, passe toujours par les domaines de recherche, et se résout comme avant. Le risque concerne les noms courts à un point, comme `web.ch40` (un Service d'un autre namespace) : ils seraient d'abord cherchés sur Internet, comme un domaine `ch40` qui n'existe pas, avant d'être complétés. Deux parades plus sûres, pour les appels extérieurs : terminer les noms par un point (`example.com.`), ou écrire les noms internes en entier. Kubernetes a choisi 5 par défaut pour que `web.ch40.svc` et même `web.ch40.svc.cluster` se résolvent toujours dans le cluster[^resolv].

</details>

## Nettoyer

Sur chacun des deux profils :

```bash
kubectl delete namespace ch40
```

Sur `deux-noeuds`, vérifiez que kube-proxy est bien revenu en mode `iptables` (`mode iptables` si vous vous êtes arrêté en route). Le profil `cilium` fonctionne désormais sans kube-proxy : c'est ainsi qu'il servira au chapitre 41. Pour retrouver un profil `cilium` d'origine, supprimez-le et recréez-le (`minikube delete -p cilium`, puis la commande du chapitre 39).

[^proxies]: Kubernetes, « Virtual IPs and Service Proxies » : modes de kube-proxy, sessions, `externalTrafficPolicy` et adresse source. [kubernetes.io/docs/reference/networking/virtual-ips](https://kubernetes.io/docs/reference/networking/virtual-ips/)

[^nftables]: Kubernetes Blog, « NFTables mode for kube-proxy », 28 février 2025. [kubernetes.io/blog/2025/02/28/nftables-kube-proxy](https://kubernetes.io/blog/2025/02/28/nftables-kube-proxy/)

[^kpr]: Cilium, « Kubernetes Without kube-proxy », sections *Quick-Start* et *Socket LoadBalancer Bypass in Pod Namespace*. [docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/)

[^coredns]: CoreDNS, documentation des greffons `kubernetes`, `forward`, `cache` et `log`. [coredns.io/plugins](https://coredns.io/plugins/)

[^resolv]: Kubernetes, « DNS for Services and Pods », sections *Pod's DNS Config* et *Namespaces of Services* ; et la page de manuel `resolv.conf(5)`, option `ndots`. [kubernetes.io/docs/concepts/services-networking/dns-pod-service](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/), [man7.org/linux/man-pages/man5/resolv.conf.5.html](https://man7.org/linux/man-pages/man5/resolv.conf.5.html)
