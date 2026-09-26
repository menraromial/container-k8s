---
title: Les Services
sidebar_label: 20. Les Services
description: "Donner une adresse stable à des Pods éphémères : le Service ClusterIP et ses EndpointSlices, la répartition par kube-proxy, le DNS du cluster, NodePort, LoadBalancer avec MetalLB, les Services headless et ExternalName, et les deux pannes les plus courantes."
partie: 3
chapitre: '20'
---

import serviceClusterip from '@site/src/figures/service-clusterip.svg';
import typesService from '@site/src/figures/types-service.svg';

L'API de Colis a besoin de joindre PostgreSQL et Redis ; le site web a besoin de joindre l'API. Avec Compose, un nom suffisait : `postgres`, `api`. Dans Kubernetes, chaque Pod a sa propre adresse IP, mais cette adresse ne vaut que pour la vie du Pod. Qu'un Pod soit remplacé (après un plantage, une mise à jour, la chute d'un nœud), et son successeur reçoit une autre adresse. Et quand l'API tourne en trois copies, à laquelle faut-il s'adresser ?

Le **Service** répond à ces deux questions. Il donne à un groupe de Pods, désignés par un sélecteur, une adresse et un nom qui ne changent pas, et répartit les connexions entre eux. Ce chapitre montre comment il est construit, jusqu'aux règles réseau du nœud, et comment le rendre joignable depuis l'extérieur du cluster.

Les manifestes sont dans [l'archive services](pathname:///kits/services.tar.gz). Le serveur de démonstration est **agnhost**, une petite application de test publiée par le projet Kubernetes : lancée avec `netexec`, elle répond sur `/hostname` par le nom de son Pod, ce qui permet de voir quel Pod a répondu.

```bash
kubectl create namespace ch20
kubectl config set-context --current --namespace=ch20
```

## Des adresses qui ne durent pas

```yaml title="web.yaml"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: agnhost
        image: registry.k8s.io/e2e-test-images/agnhost:2.61
        args: ["netexec", "--http-port=8080"]
        ports:
        - name: http
          containerPort: 8080
```

Le port du conteneur porte un **nom**, `http`, dont nous allons nous servir. Lançons le Deployment, notons l'adresse d'un Pod, puis supprimons-le :

```bash
kubectl apply -f web.yaml
kubectl rollout status deployment/web
kubectl get pods -o wide
kubectl delete pod web-76d6787659-9zqx6
kubectl get pods -o wide
```

```sortie
NAME                   READY   STATUS    RESTARTS   AGE   IP             NODE
web-76d6787659-9zqx6   1/1     Running   0          1s    10.244.0.191   minikube
web-76d6787659-jdvns   1/1     Running   0          1s    10.244.0.193   minikube
web-76d6787659-lwj9v   1/1     Running   0          1s    10.244.0.192   minikube
pod "web-76d6787659-9zqx6" deleted from ch20 namespace
NAME                   READY   STATUS    RESTARTS   AGE   IP             NODE
web-76d6787659-jdvns   1/1     Running   0          3s    10.244.0.193   minikube
web-76d6787659-lwj9v   1/1     Running   0          3s    10.244.0.192   minikube
web-76d6787659-xztf2   1/1     Running   0          2s    10.244.0.194   minikube
```

(Sorties raccourcies aux premières colonnes.) Le remplaçant, `xztf2`, a reçu `10.244.0.194` : l'adresse `10.244.0.191` n'existe plus. Un programme qui l'aurait notée ne joindrait plus rien. Chaque Pod reçoit son adresse du plan d'adressage des Pods du cluster, ici `10.244.0.0/16`, découpé par nœud ; la partie V expliquera qui l'attribue et comment les paquets circulent d'un nœud à l'autre.

## Le Service ClusterIP

```yaml title="service.yaml"
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: web
  ports:
  - name: http
    port: 80
    targetPort: http
```

Un Service a un **sélecteur**, comme un ReplicaSet, et une liste de **ports**. `port` est le port du Service lui-même ; `targetPort` est le port des Pods vers lequel les connexions sont transmises, donné ici par son nom, `http`, ce qui permet de changer le numéro dans le Deployment sans toucher au Service[^service].

```bash
kubectl apply -f service.yaml
kubectl get service web
kubectl get endpointslices -l kubernetes.io/service-name=web
```

```sortie
service/web created
NAME   TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)   AGE
web    ClusterIP   10.104.228.232   <none>        80/TCP    0s
NAME        ADDRESSTYPE   PORTS   ENDPOINTS                                AGE
web-86cj4   IPv4          8080    10.244.0.192,10.244.0.193,10.244.0.194   0s
```

Le Service a reçu une adresse, `10.104.228.232`, prise dans une autre plage (`10.96.0.0/12`), réservée aux Services. C'est la **ClusterIP** : une adresse virtuelle, portée par aucune interface réseau, qui n'existe que dans les règles réseau des nœuds, et qui restera la même tant que le Service existe. Un second objet est apparu, créé par un contrôleur : une **EndpointSlice**, qui liste les adresses et les ports des Pods sélectionnés, les trois adresses actuelles des Pods `web`, sur le port 8080[^endpointslices].

```bash
kubectl get endpointslices -l kubernetes.io/service-name=web -o json | jq -r '.items[0].endpoints[] | "\(.addresses[0]) \(.targetRef.name) ready=\(.conditions.ready)"'
```

```sortie
10.244.0.192 web-76d6787659-lwj9v ready=true
10.244.0.193 web-76d6787659-jdvns ready=true
10.244.0.194 web-76d6787659-xztf2 ready=true
```

Chaque adresse est reliée à son Pod et porte une condition `ready` : un Pod qui n'est pas prêt (chapitres 17 et 22) reste listé, mais ne reçoit pas de trafic. La liste suit les Pods en continu. Réduisons le Deployment à un Pod, puis remontons à trois :

```bash
kubectl scale deployment web --replicas=1; sleep 5
kubectl get endpointslices -l kubernetes.io/service-name=web
kubectl scale deployment web --replicas=3
kubectl rollout status deployment/web
kubectl get endpointslices -l kubernetes.io/service-name=web
```

```sortie
deployment.apps/web scaled
NAME        ADDRESSTYPE   PORTS   ENDPOINTS      AGE
web-86cj4   IPv4          8080    10.244.0.194   9s
deployment.apps/web scaled
NAME        ADDRESSTYPE   PORTS   ENDPOINTS                                AGE
web-86cj4   IPv4          8080    10.244.0.194,10.244.0.198,10.244.0.197   12s
```

### Répartir les connexions

Lançons un Pod client, qui restera là pour tout le chapitre, et envoyons trente requêtes au Service, par son nom :

```bash
kubectl run client --image=busybox:1.37 --restart=Never -- sleep 3600
kubectl wait --for=condition=Ready pod/client
kubectl exec client -- sh -c 'for i in $(seq 1 30); do wget -q -O - http://web/hostname; echo; done' | sort | uniq -c
```

```sortie
      5 web-76d6787659-jdvns
     14 web-76d6787659-lwj9v
     11 web-76d6787659-xztf2
```

Les trente requêtes se sont réparties entre les trois Pods, pas à parts égales : chaque connexion est dirigée vers un Pod tiré **au hasard**. Sur un grand nombre de connexions, la répartition s'équilibre ; sur trente, elle reste inégale. Qui fait ce tirage ? Ni le Service, qui n'est qu'un objet dans etcd, ni un programme intermédiaire par lequel passeraient les paquets. C'est le noyau du nœud, programmé par **kube-proxy**, le composant du chapitre 15 qui tourne sur chaque nœud. Dans minikube, il utilise le mode `iptables` : il traduit chaque Service et chaque EndpointSlice en règles du pare-feu du noyau[^kube-proxy].

```bash
minikube ssh -- sudo iptables -t nat -S KUBE-SERVICES | grep 'ch20/web:http cluster IP'
minikube ssh -- sudo iptables -t nat -S KUBE-SVC-IFRSJQYNFWED4CMW
minikube ssh -- sudo iptables -t nat -S KUBE-SEP-NFL37PQ3XGPAYNBX
```

```sortie
-A KUBE-SERVICES -d 10.104.228.232/32 -p tcp -m comment --comment "ch20/web:http cluster IP" -m tcp --dport 80 -j KUBE-SVC-IFRSJQYNFWED4CMW
-N KUBE-SVC-IFRSJQYNFWED4CMW
-A KUBE-SVC-IFRSJQYNFWED4CMW ! -s 10.244.0.0/16 -d 10.104.228.232/32 -p tcp -m comment --comment "ch20/web:http cluster IP" -m tcp --dport 80 -j KUBE-MARK-MASQ
-A KUBE-SVC-IFRSJQYNFWED4CMW -m comment --comment "ch20/web:http -> 10.244.0.194:8080" -m statistic --mode random --probability 0.33333333349 -j KUBE-SEP-NFL37PQ3XGPAYNBX
-A KUBE-SVC-IFRSJQYNFWED4CMW -m comment --comment "ch20/web:http -> 10.244.0.197:8080" -m statistic --mode random --probability 0.50000000000 -j KUBE-SEP-FTGKIT7P7DXWRGHW
-A KUBE-SVC-IFRSJQYNFWED4CMW -m comment --comment "ch20/web:http -> 10.244.0.198:8080" -j KUBE-SEP-ISZXTUMJPVXGNQIY
-N KUBE-SEP-NFL37PQ3XGPAYNBX
-A KUBE-SEP-NFL37PQ3XGPAYNBX -s 10.244.0.194/32 -m comment --comment "ch20/web:http" -j KUBE-MARK-MASQ
-A KUBE-SEP-NFL37PQ3XGPAYNBX -p tcp -m comment --comment "ch20/web:http" -m tcp -j DNAT --to-destination 10.244.0.194:8080
```

(Les noms de chaînes sont des empreintes ; `kubectl` et `minikube ssh` les donnent en suivant la première ligne.) Les règles se lisent de haut en bas. Un paquet destiné à `10.104.228.232:80` est envoyé dans la chaîne du Service. Là, la première règle le dirige vers le premier Pod avec une probabilité de 1/3 ; sinon, la deuxième vers le deuxième avec une probabilité de 1/2 ; sinon, la troisième vers le dernier, sans condition. Chaque Pod reçoit donc un tiers des connexions (1/3, puis 2/3 × 1/2, puis 2/3 × 1/2). La chaîne d'un Pod (`KUBE-SEP-...`) réécrit enfin l'adresse de destination du paquet, par un **DNAT** (*destination NAT*), vers `10.244.0.194:8080`. Le tirage se fait à l'ouverture de chaque connexion TCP ; tous les paquets d'une même connexion vont ensuite au même Pod. La partie V comparera ce mode à `nftables` et `IPVS`.

<Figure svg={serviceClusterip} num="20.1" alt="Le Pod client fait wget http://web/. 1 il demande à CoreDNS, 10.96.0.10, l'adresse de web ; 2 CoreDNS répond 10.104.228.232. 3 la connexion vers 10.104.228.232:80 est interceptée par les règles iptables du nœud, écrites par kube-proxy. 4 un DNAT l'envoie vers un Pod tiré au hasard : xztf2 (10.244.0.194:8080) avec une probabilité d'un tiers, fpsd4 (10.244.0.197:8080) pour la moitié du reste, xxz2r (10.244.0.198:8080) pour le reste. kube-proxy suit l'EndpointSlice web-86cj4, qui liste les Pods prêts portant app=web, et qu'un contrôleur tient à jour.">
Le chemin d'une requête vers le Service <code>web</code>. Le Service n'existe que sous forme de règles dans le noyau de chaque nœud ; aucun programme ne relaie les paquets.
</Figure>

## Le DNS du cluster

Le client a écrit `http://web/`, et non une adresse. Un composant du cluster, **CoreDNS**, qui tourne dans `kube-system`, donne à chaque Service un nom de la forme `<service>.<namespace>.svc.cluster.local`[^dns]. Chaque Pod est configuré pour l'interroger :

```bash
kubectl exec client -- cat /etc/resolv.conf
```

```sortie
search ch20.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```

`nameserver` est la ClusterIP du Service de CoreDNS. La ligne `search` explique pourquoi le nom court `web` suffit : un nom qui compte moins de cinq points (`ndots:5`) est d'abord essayé avec chacun des suffixes, dans l'ordre. `web` devient `web.ch20.svc.cluster.local`, qui existe. La sortie de `nslookup` montre ces essais, que BusyBox lance en parallèle pour les adresses IPv4 et IPv6, d'où son désordre :

```bash
kubectl exec client -- nslookup web
```

```sortie
Server:		10.96.0.10
Address:	10.96.0.10:53

** server can't find web.cluster.local: NXDOMAIN

** server can't find web.svc.cluster.local: NXDOMAIN

** server can't find web.cluster.local: NXDOMAIN

Name:	web.ch20.svc.cluster.local
Address: 10.104.228.232

** server can't find web.svc.cluster.local: NXDOMAIN

command terminated with exit code 1
```

Le nom a été trouvé avec le premier suffixe, `ch20.svc.cluster.local` ; les autres essais ont échoué, ce qui donne à `nslookup` son code de sortie 1, sans conséquence. Le premier suffixe porte le namespace du Pod : le nom court ne fonctionne donc que **dans le même namespace**. Depuis `default`, il faut au moins le nom du namespace :

```bash
kubectl -n default run client2 --image=busybox:1.37 --restart=Never --rm -i -- \
  sh -c 'wget -q -T 3 -O - http://web/hostname; echo code=$?; wget -q -T 3 -O - http://web.ch20/hostname; echo; echo code=$?'
```

```sortie
wget: bad address 'web'
code=1
web-76d6787659-xztf2
code=0
```

`web.ch20` est essayé avec le suffixe `svc.cluster.local` du Pod de `default`, et devient `web.ch20.svc.cluster.local`. Dans une configuration d'application, préférez le nom le plus court qui fonctionne : `postgres` si l'application et la base sont dans le même namespace, ce qui permet de déployer la même configuration dans plusieurs namespaces.

Kubernetes injecte aussi, dans chaque conteneur, des variables d'environnement pour les Services qui existaient **avant** la création du Pod, héritées d'un vieux mécanisme de Docker :

```bash
kubectl exec client -- env | grep -E '^WEB_' | sort
```

```sortie
WEB_PORT=tcp://10.104.228.232:80
WEB_PORT_80_TCP=tcp://10.104.228.232:80
WEB_PORT_80_TCP_ADDR=10.104.228.232
WEB_PORT_80_TCP_PORT=80
WEB_PORT_80_TCP_PROTO=tcp
WEB_SERVICE_HOST=10.104.228.232
WEB_SERVICE_PORT=80
WEB_SERVICE_PORT_HTTP=80
```

Ne vous appuyez pas dessus : un Service créé après le Pod n'y figure pas. Le DNS n'a pas ce défaut.

## Deux pannes classiques

Un Service qui ne répond pas a presque toujours l'une de ces deux causes. La première, un sélecteur qui ne correspond à aucun Pod. Créons un Service dont le sélecteur contient une faute, `app: webb` :

```bash
kubectl create service clusterip web-faute --tcp=80:8080 --dry-run=client -o yaml | sed 's/app: web-faute/app: webb/' | kubectl apply -f -
kubectl get endpointslices -l kubernetes.io/service-name=web-faute
kubectl exec client -- wget -q -T 3 -O - http://web-faute/hostname; echo code=$?
kubectl describe service web-faute | grep -E 'Selector|Endpoints'
```

```sortie
service/web-faute created
NAME              ADDRESSTYPE   PORTS     ENDPOINTS   AGE
web-faute-d5hrh   IPv4          <unset>   <unset>     1s
wget: can't connect to remote host (10.101.74.135): Connection refused
command terminated with exit code 1
code=1
Selector:                 app=webb
Endpoints:                
```

Le nom se résout (le Service existe), mais la connexion est refusée : kube-proxy pose, pour un Service sans aucun Pod, une règle qui rejette les connexions. L'EndpointSlice vide (`<unset>`) donne le diagnostic en une commande.

La seconde, un `targetPort` qui ne correspond pas au port où l'application écoute. Ce Service envoie vers le port 9090, alors qu'agnhost écoute sur 8080 :

```bash
kubectl create service clusterip web-port --tcp=80:9090 --dry-run=client -o yaml | sed 's/app: web-port/app: web/' | kubectl apply -f -
kubectl get endpointslices -l kubernetes.io/service-name=web-port
kubectl exec client -- wget -q -T 3 -O - http://web-port/hostname; echo code=$?
```

```sortie
service/web-port created
NAME             ADDRESSTYPE   PORTS   ENDPOINTS                                AGE
web-port-2jnz8   IPv4          9090    10.244.0.198,10.244.0.197,10.244.0.194   0s
wget: download timed out
command terminated with exit code 1
code=1
```

Cette fois, l'EndpointSlice est bien remplie : le sélecteur est bon. Mais personne n'écoute sur le port 9090 des Pods. Selon l'application et le réseau, le symptôme est un refus de connexion ou, comme ici, une attente sans réponse.

:::panne[Un Service qui ne répond pas]

La méthode tient en trois questions, dans l'ordre. Le nom se résout-il ? (`nslookup` depuis un Pod du bon namespace ; sinon, un nom ou un namespace faux.) L'EndpointSlice contient-elle des adresses ? (`kubectl get endpointslices -l kubernetes.io/service-name=<nom>` ; sinon, comparez le sélecteur du Service, `kubectl describe service`, aux étiquettes des Pods, `kubectl get pods --show-labels`, et vérifiez que les Pods sont prêts.) Le port cible est-il le bon ? (Comparez `targetPort` au port où l'application écoute, et essayez directement l'adresse d'un Pod depuis le client : `wget -O - http://10.244.0.194:8080/`.)

:::

## Sortir du cluster : NodePort

Une ClusterIP n'est joignable que depuis le cluster : votre poste ne sait pas où envoyer un paquet vers `10.104.228.232`. Le type **NodePort** ajoute, sur **chaque** nœud, un port (pris par défaut entre 30000 et 32767) qui mène au Service :

```yaml title="nodeport.yaml"
apiVersion: v1
kind: Service
metadata:
  name: web-nodeport
spec:
  type: NodePort
  selector:
    app: web
  ports:
  - name: http
    port: 80
    targetPort: http
    nodePort: 30080
```

```bash
kubectl apply -f nodeport.yaml
sleep 3
kubectl get service web-nodeport
for i in 1 2 3; do curl -s http://$(minikube ip):30080/hostname; echo; done
minikube service web-nodeport -n ch20 --url
```

```sortie
service/web-nodeport created
NAME           TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
web-nodeport   NodePort   10.98.181.46   <none>        80:30080/TCP   3s
web-76d6787659-xztf2
web-76d6787659-xxz2r
web-76d6787659-xxz2r
http://192.168.49.2:30080
```

La colonne `PORT(S)` se lit `80:30080` : port 80 sur la ClusterIP, 30080 sur les nœuds. Le Service NodePort a **aussi** une ClusterIP : c'est un Service ClusterIP auquel on a ajouté un port sur les nœuds. Depuis votre poste, l'adresse du nœud minikube est joignable (le réseau Docker du chapitre 6), d'où le `curl` qui fonctionne. `minikube service --url` donne cette adresse. Si vous omettez `nodePort`, Kubernetes en choisit un libre dans la plage. Le `sleep 3` n'est pas décoratif : dans une première version de ce chapitre, `curl` lancé aussitôt après `apply` ne recevait rien, le temps que kube-proxy pose ses règles.

NodePort a deux défauts pour un vrai service : un port inhabituel, et une adresse de nœud qu'il faut connaître et qui peut disparaître avec le nœud.

## LoadBalancer

Le type **LoadBalancer** demande une adresse externe à l'infrastructure qui héberge le cluster. Chez un fournisseur de cloud, un contrôleur crée un répartiteur de charge du fournisseur (un *load balancer* AWS, Google Cloud, Azure), qui envoie le trafic vers les NodePorts du Service. Un Service LoadBalancer est donc un NodePort, lui-même ClusterIP, auquel s'ajoute une adresse externe.

```yaml title="loadbalancer.yaml"
apiVersion: v1
kind: Service
metadata:
  name: web-lb
spec:
  type: LoadBalancer
  selector:
    app: web
  ports:
  - name: http
    port: 80
    targetPort: http
```

Sur un poste, il n'y a pas de fournisseur de cloud, et la colonne `EXTERNAL-IP` d'un tel Service reste `<pending>`. minikube propose deux solutions[^minikube-lb]. `minikube tunnel`, lancé dans un terminal à part, attribue au Service sa ClusterIP comme adresse externe, et ajoute sur votre poste une route vers la plage des Services ; mais ajouter une route demande les droits d'administrateur, et la commande vous demandera votre mot de passe `sudo`. Sans terminal pour le saisir, elle échoue :

```sortie
		router: error adding Route: sudo: A terminal is required to authenticate
```

La seconde solution, que ce cours utilise, ne demande aucun droit particulier : l'addon **MetalLB**. MetalLB est un répartiteur de charge logiciel pour les clusters hors cloud[^metallb] ; en mode « couche 2 », il attribue aux Services des adresses prises dans une plage de votre réseau, et répond lui-même aux requêtes ARP pour ces adresses, comme le ferait une machine. L'addon installe une ancienne version de MetalLB, la 0.9.6, qui se configure par une ConfigMap ; les versions actuelles utilisent des objets dédiés, mais le principe est le même. On lui donne une plage libre du réseau Docker de minikube (`192.168.49.0/24`) :

```yaml title="metallb-plage.yaml"
# Plage d'adresses de MetalLB (addon minikube, MetalLB 0.9.6, configuré par cette ConfigMap).
# À réappliquer après chaque « minikube start », qui remet la plage à vide.
apiVersion: v1
kind: ConfigMap
metadata:
  name: config
  namespace: metallb-system
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - 192.168.49.100-192.168.49.120
```

```bash
minikube addons enable metallb
kubectl -n metallb-system rollout status deployment/controller
kubectl apply -f metallb-plage.yaml
```

minikube propose aussi `minikube addons configure metallb`, qui demande la première et la dernière adresse de la plage ; mais en préparant ce cours, la commande a cessé de modifier la ConfigMap après un redémarrage du cluster, alors que le fichier fonctionne toujours.

```bash
kubectl apply -f loadbalancer.yaml
sleep 8
kubectl get service web-lb
for i in 1 2 3 4; do curl -s http://192.168.49.100/hostname; echo; done
```

```sortie
service/web-lb created
NAME     TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)        AGE
web-lb   LoadBalancer   10.99.162.178   192.168.49.100   80:32023/TCP   8s
web-76d6787659-fpsd4
web-76d6787659-xxz2r
web-76d6787659-fpsd4
web-76d6787659-xztf2
```

Le Service a reçu `192.168.49.100`, joignable depuis votre poste sur le port 80, et il a aussi un NodePort (32023) et une ClusterIP.

:::panne[EXTERNAL-IP attribuée, mais l'adresse ne répond plus après minikube start]

`minikube start` réapplique la configuration d'origine de l'addon, avec une plage vide. Le Service garde son adresse, mais MetalLB ne l'annonce plus, et `curl` attend en vain. Les journaux de MetalLB le disent :

```bash
kubectl -n metallb-system logs ds/speaker --tail=2
```

```sortie
{"caller":"main.go:219","event":"noConfig","msg":"not processing, still waiting for config","service":"colis/web","ts":"2026-09-26T06:38:39.339677416Z"}
```

Réappliquez `metallb-plage.yaml` après chaque `minikube start`. Quelques secondes plus tard, les journaux affichent `service has IP, announcing`.

::: Pour Colis, c'est ainsi que le site web sera exposé au chapitre 24, en attendant l'Ingress et la Gateway API du chapitre 28, qui permettent de partager une seule adresse entre plusieurs applications HTTP.

<Figure svg={typesService} num="20.2" alt="Trois cadres emboîtés. Le plus grand, LoadBalancer, a une adresse externe 192.168.49.100 attribuée par MetalLB ; il contient le cadre NodePort, un port sur chaque nœud, 192.168.49.2:30080 ; qui contient le cadre ClusterIP, 10.104.228.232:80, avec trois Pods sur le port 8080. Votre poste atteint le Service par 192.168.49.100:80 ou par le port 30080 du nœud ; un Pod du cluster l'atteint par le nom web, port 80.">
Les trois types de Service s'emboîtent : chacun ajoute une façon d'entrer à celle du type précédent. Adresses relevées sur le cluster du cours.
</Figure>

## Deux Services particuliers

Un Service **headless** (« sans tête ») n'a pas de ClusterIP : `clusterIP: None`. kube-proxy l'ignore, et le DNS répond directement par les adresses des Pods :

```yaml title="headless.yaml"
apiVersion: v1
kind: Service
metadata:
  name: web-headless
spec:
  clusterIP: None
  selector:
    app: web
  ports:
  - name: http
    port: 8080
```

```bash
kubectl apply -f headless.yaml
kubectl get service web-headless
kubectl exec client -- nslookup web-headless
```

```sortie
service/web-headless created
NAME           TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)    AGE
web-headless   ClusterIP   None         <none>        8080/TCP   0s
...
Name:	web-headless.ch20.svc.cluster.local
Address: 10.244.0.197
Name:	web-headless.ch20.svc.cluster.local
Address: 10.244.0.194
Name:	web-headless.ch20.svc.cluster.local
Address: 10.244.0.198
...
```

Trois réponses, une par Pod. C'est au client de choisir, et de se reconnecter ailleurs si un Pod disparaît. On s'en sert quand chaque Pod doit être joint individuellement : les membres d'une base de données répliquée, qui ont chacun un rôle. Le chapitre 26 en fera le support des StatefulSets, qui donnent en plus à chaque Pod un nom DNS stable.

Un Service **ExternalName** n'a ni sélecteur ni Pods : c'est un alias DNS vers un nom extérieur au cluster.

```bash
kubectl create service externalname documentation --external-name=kubernetes.io
kubectl exec client -- nslookup documentation.ch20.svc.cluster.local.
```

```sortie
service/documentation created
Server:		10.96.0.10
Address:	10.96.0.10:53

documentation.ch20.svc.cluster.local	canonical name = kubernetes.io
Name:	kubernetes.io
Address: 15.197.167.90
Name:	kubernetes.io
Address: 3.33.186.135
```

(Le point final du nom demande à `nslookup` de ne pas essayer les suffixes de recherche.) CoreDNS répond par un alias (`CNAME`) vers `kubernetes.io`. Une application peut ainsi utiliser un nom interne, `documentation`, pour un service externe (une base de données hébergée, par exemple), et on changera la cible sans toucher à sa configuration.

Voici tous les Services du chapitre :

```bash
kubectl get services
```

```sortie
NAME            TYPE           CLUSTER-IP       EXTERNAL-IP      PORT(S)        AGE
documentation   ExternalName   <none>           kubernetes.io    <none>         0s
web             ClusterIP      10.104.228.232   <none>           80/TCP         34s
web-faute       ClusterIP      10.101.74.135    <none>           80/TCP         20s
web-headless    ClusterIP      None             <none>           8080/TCP       0s
web-lb          LoadBalancer   10.99.162.178    192.168.49.100   80:32023/TCP   9s
web-nodeport    NodePort       10.98.181.46     <none>           80:30080/TCP   15s
web-port        ClusterIP      10.99.23.216     <none>           80/TCP         18s
```

## Accès aux interfaces

Depuis votre poste, pendant que le namespace `ch20` existe :

- le Service NodePort : [http://192.168.49.2:30080/hostname](http://192.168.49.2:30080/hostname) (l'adresse du nœud est donnée par `minikube ip`) ;
- le Service LoadBalancer : [http://192.168.49.100/hostname](http://192.168.49.100/hostname).

## Exercices

:::exercice[Exercice 1 : kubectl expose]

Créez un second Service pour le Deployment `web` avec la commande impérative `kubectl expose`, sur le port 80 vers le port 8080 des Pods. Comparez l'objet obtenu à `service.yaml` : d'où `kubectl expose` a-t-il tiré le sélecteur ?

:::

<details>
<summary>Corrigé</summary>

```bash
kubectl expose deployment web --name=web2 --port=80 --target-port=8080
kubectl get service web2 -o yaml
```

```sortie
service/web2 exposed
spec:
  clusterIP: 10.101.37.29
  ports:
  - port: 80
    protocol: TCP
    targetPort: 8080
  selector:
    app: web
  sessionAffinity: None
  type: ClusterIP
```

(Extrait de la `spec`.) `kubectl expose` a recopié le sélecteur du Deployment, `app: web`. Le Service est équivalent à celui du fichier, à deux détails près : son port n'a pas de nom, et `targetPort` est un numéro plutôt que le nom `http`. C'est pratique pour un essai ; pour une application qu'on garde, on écrit le manifeste, ou on le génère avec `--dry-run=client -o yaml` (chapitre 18).

</details>

:::exercice[Exercice 2 : les noms qui marchent]

Depuis un Pod du namespace `default`, essayez de joindre le Service `web` de `ch20` sous les noms `web`, `web.ch20`, `web.ch20.svc` et `web.ch20.svc.cluster.local`. Lesquels fonctionnent, et pourquoi ?

:::

<details>
<summary>Corrigé</summary>

```bash
kubectl -n default run dnsx --image=busybox:1.37 --restart=Never -- sleep 300
for n in web web.ch20 web.ch20.svc web.ch20.svc.cluster.local; do
  echo "$n -> $(kubectl -n default exec dnsx -- wget -q -T 3 -O - http://$n/hostname 2>&1)"
done
kubectl -n default delete pod dnsx
```

```sortie
web -> wget: bad address 'web'
command terminated with exit code 1
web.ch20 -> web-76d6787659-fpsd4
web.ch20.svc -> web-76d6787659-xxz2r
web.ch20.svc.cluster.local -> web-76d6787659-fpsd4
```

Le Pod de `default` a pour liste de recherche `default.svc.cluster.local svc.cluster.local cluster.local`. `web` devient `web.default.svc.cluster.local`, puis `web.svc.cluster.local`, puis `web.cluster.local` : aucun n'existe. `web.ch20` devient `web.ch20.svc.cluster.local` avec le deuxième suffixe, et `web.ch20.svc` avec le troisième. Le nom complet fonctionne toujours, mais passe d'abord par les suffixes, puisqu'il compte moins de cinq points : ajouter un point final (`web.ch20.svc.cluster.local.`) évite ces requêtes inutiles, ce qui compte pour une application qui fait beaucoup de requêtes vers l'extérieur.

</details>

:::exercice[Exercice 3 : toujours le même Pod]

Certaines applications gardent un état en mémoire pour chaque client et veulent que ses requêtes arrivent toujours au même Pod. Cherchez avec `kubectl explain service.spec` le champ qui le permet, activez-le sur le Service `web`, et vérifiez avec vingt requêtes du Pod `client`. Quelle est la limite de ce mécanisme ?

:::

<details>
<summary>Corrigé</summary>

```bash
kubectl patch service web -p '{"spec":{"sessionAffinity":"ClientIP"}}'
kubectl exec client -- sh -c 'for i in $(seq 1 20); do wget -q -O - http://web/hostname; echo; done' | sort | uniq -c
kubectl patch service web -p '{"spec":{"sessionAffinity":"None"}}'
```

```sortie
service/web patched
     20 web-76d6787659-fpsd4
```

`sessionAffinity: ClientIP` fait envoyer toutes les connexions d'une même adresse IP source au même Pod, pendant trois heures par défaut (`sessionAffinityConfig.clientIP.timeoutSeconds`). kube-proxy l'implémente avec le module `recent` d'iptables. Les limites : l'affinité porte sur l'adresse du client, et tous les clients derrière un même proxy ou une même passerelle arrivent sur le même Pod ; et si ce Pod disparaît, l'état qu'il gardait disparaît avec lui. La bonne solution reste une application sans état, qui range ses sessions dans Redis ou dans la base.

</details>

:::exercice[Exercice 4 : port-forward vers un Service]

Lancez `kubectl port-forward service/web 8088:80`, puis envoyez dix requêtes à `localhost:8088/hostname` depuis votre poste. Combien de Pods répondent ? Qu'en concluez-vous sur ce que fait réellement `port-forward` ?

:::

<details>
<summary>Corrigé</summary>

```bash
kubectl port-forward service/web 8088:80 &
for i in $(seq 1 10); do curl -s localhost:8088/hostname; echo; done | sort | uniq -c
kill %1
```

```sortie
     10 web-76d6787659-xztf2
```

Un seul Pod. `kubectl port-forward service/web` ne passe pas par le Service : il choisit **un** Pod du Service au moment où la commande démarre, et ouvre un tunnel vers lui à travers l'API server et le kubelet (chapitre 16). Il n'y a ni répartition, ni reprise si ce Pod disparaît. C'est un outil de dépannage, pas un moyen d'exposer une application : pour cela, NodePort, LoadBalancer ou, plus tard, Ingress.

</details>

## Nettoyer

```bash
kubectl delete namespace ch20
kubectl config set-context --current --namespace=default
```

Laissez l'addon MetalLB actif : le chapitre 24 s'en servira. Il se désactive avec `minikube addons disable metallb`.

[^service]: Kubernetes, « Service », sections *Defining a Service*, *Port definitions* et *Service type*. [kubernetes.io/docs/concepts/services-networking/service](https://kubernetes.io/docs/concepts/services-networking/service/)

[^endpointslices]: Kubernetes, « EndpointSlices ». [kubernetes.io/docs/concepts/services-networking/endpoint-slices](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/)

[^kube-proxy]: Kubernetes, « Virtual IPs and Service Proxies », section *iptables proxy mode*. [kubernetes.io/docs/reference/networking/virtual-ips](https://kubernetes.io/docs/reference/networking/virtual-ips/)

[^dns]: Kubernetes, « DNS for Services and Pods ». [kubernetes.io/docs/concepts/services-networking/dns-pod-service](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)

[^minikube-lb]: minikube, « Accessing apps », sections *NodePort* et *LoadBalancer access*. [minikube.sigs.k8s.io/docs/handbook/accessing](https://minikube.sigs.k8s.io/docs/handbook/accessing/)

[^metallb]: MetalLB, « MetalLB, bare metal load-balancer for Kubernetes », section *Layer 2 mode*. [metallb.io/concepts/layer2](https://metallb.io/concepts/layer2/)
