---
title: minikube et kubectl
sidebar_label: 16. minikube et kubectl
description: "Les deux outils du quotidien, vus de près : pilotes, profils et addons de minikube ; le kubeconfig, les contextes et l'identité de kubectl ; découvrir l'API avec api-resources et explain ; lire les objets sous toutes leurs formes."
partie: 3
chapitre: '16'
---

import kubeconfigFig from '@site/src/figures/kubeconfig.svg';
import cheminRequete from '@site/src/figures/chemin-requete.svg';

Un matin, `kubectl get pods` répond ceci :

```sortie
The connection to the server localhost:8080 was refused - did you specify the right host or port?
```

Rien n'a changé dans votre cluster, et pourtant kubectl cherche un serveur sur `localhost:8080`, une adresse qui n'a jamais été la sienne. Pour comprendre d'où vient cette adresse, et pour ne plus jamais taper une commande sur le mauvais cluster, il faut savoir ce que kubectl lit avant d'envoyer la moindre requête. C'est l'un des sujets de ce chapitre, qui prend le temps de regarder de près les deux outils que vous utiliserez à chaque page de la suite : minikube, qui fabrique le cluster, et kubectl, qui lui parle.

Le chapitre 0.2 a installé les deux et démarré un cluster. Vérifiez qu'il tourne, ou démarrez-le :

```bash
minikube start --driver=docker --cpus=2 --memory=4g --kubernetes-version=v1.37.0
```

## minikube, un cluster jetable

minikube n'est pas Kubernetes : c'est un outil qui fabrique, sur votre poste, une machine capable de faire tourner Kubernetes, puis installe Kubernetes dessus avec `kubeadm`, l'outil officiel d'installation[^minikube]. Cette « machine » peut prendre plusieurs formes, selon le **pilote** (*driver*) choisi :

```bash
minikube start --help | grep -A1 -E '^ *-d, --driver'
```

```sortie
    -d, --driver='':
	Driver is one of: virtualbox, kvm2, qemu2, qemu, vmware, none, docker, podman, ssh (defaults to auto-detect)
```

Les pilotes `virtualbox`, `kvm2`, `qemu2` et `vmware` créent une vraie machine virtuelle, avec son propre noyau : c'est l'isolation la plus proche d'un serveur réel, mais aussi la plus lourde. `docker` et `podman` créent un conteneur qui joue le rôle de machine, comme nous l'avons exploité au chapitre 11 : c'est rapide et économe, au prix d'un noyau partagé avec votre poste (le chapitre 12 a montré ce que cela interdit, les user namespaces des Pods par exemple). `none` installe Kubernetes directement sur votre machine, sans isolation, et `ssh` sur une machine distante. Ce cours utilise `docker` partout.

### Les profils

Un même minikube peut gérer plusieurs clusters, chacun dans un **profil** qui porte son nom. Le cluster par défaut s'appelle `minikube` ; le chapitre 15 en a créé un second, `deux-noeuds` :

```bash
minikube profile list
```

```sortie
┌─────────────┬────────┬────────────┬──────────────┬─────────┬─────────┬───────┬────────────────┬────────────────────┐
│   PROFILE   │ DRIVER │  RUNTIME   │      IP      │ VERSION │ STATUS  │ NODES │ ACTIVE PROFILE │ ACTIVE KUBECONTEXT │
├─────────────┼────────┼────────────┼──────────────┼─────────┼─────────┼───────┼────────────────┼────────────────────┤
│ deux-noeuds │ docker │ containerd │ 192.168.58.2 │ v1.37.0 │ Stopped │ 2     │                │                    │
│ minikube    │ docker │ containerd │ 192.168.49.2 │ v1.37.0 │ OK      │ 1     │ *              │ *                  │
└─────────────┴────────┴────────────┴──────────────┴─────────┴─────────┴───────┴────────────────┴────────────────────┘
```

Chaque profil a son pilote, son runtime, son réseau Docker (d'où deux adresses différentes, `192.168.49.2` et `192.168.58.2`), sa version de Kubernetes et son nombre de nœuds. Toutes les commandes minikube acceptent `-p <profil>` ; sans cette option, elles visent le profil actif. Les commandes les plus utiles au quotidien sont courtes :

```bash
minikube status
minikube ip
minikube ssh -- uptime
```

```sortie
minikube
type: Control Plane
host: Running
kubelet: Running
apiserver: Running
kubeconfig: Configured

192.168.49.2
 04:56:01 up 1 day, 12:23,  0 user,  load average: 0.94, 0.96, 0.71
```

`status` vérifie les quatre étages : la machine (`host`), le kubelet, l'API server, et la configuration de kubectl (`kubeconfig`). `ip` donne l'adresse du nœud, et `ssh` y ouvre un terminal, ou y exécute une commande : c'est ainsi que les chapitres 11 et 15 sont allés lire les fichiers du nœud. L'`uptime` est celui du noyau de votre poste, puisque le nœud est un conteneur.

### Les addons

Un cluster Kubernetes nu ne contient que le strict nécessaire. minikube propose une quarantaine de composants optionnels, les **addons**, qui s'installent en une commande :

```bash
minikube addons list -o json | jq 'length'
minikube addons list -o json | jq -r 'to_entries[] | select(.key|test("^(dashboard|headlamp|metrics-server|registry|ingress|default-storageclass|storage-provisioner)$")) | "\(.key)\t\(.value.Status)"'
```

```sortie
40
dashboard	disabled
default-storageclass	enabled
headlamp	disabled
ingress	disabled
metrics-server	enabled
registry	disabled
storage-provisioner	enabled
```

Deux sont actifs par défaut, `storage-provisioner` et `default-storageclass`, qui fournissent du stockage aux applications (chapitre 25). `headlamp` est l'interface graphique du chapitre 0.2 ; `dashboard`, l'ancienne interface officielle de Kubernetes, n'est plus maintenue. `ingress` et `registry` serviront plus tard. Activons-en un tout de suite, `metrics-server`, qui mesure la consommation de processeur et de mémoire des nœuds et des Pods :

```bash
minikube addons enable metrics-server
kubectl wait -n kube-system --for=condition=Available deployment/metrics-server --timeout=120s
sleep 60
kubectl top nodes
kubectl top pods -n kube-system --sort-by=memory
```

```sortie
  - Utilisation de l'image registry.k8s.io/metrics-server/metrics-server:v0.9.0
* Le module 'metrics-server' est activé
deployment.apps/metrics-server condition met
NAME       CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
minikube   186m         0%       668Mi           4%
NAME                               CPU(cores)   MEMORY(bytes)
kube-apiserver-minikube            44m          234Mi
etcd-minikube                      25m          55Mi
kube-controller-manager-minikube   22m          50Mi
kube-scheduler-minikube            9m           26Mi
metrics-server-768f9f6999-mdqmk    3m           21Mi
kube-proxy-n9tb4                   1m           17Mi
coredns-559f6c778d-h7h7j           3m           14Mi
storage-provisioner                2m           10Mi
kindnet-rq5t5                      1m           9Mi
```

Il faut attendre une minute après l'activation : metrics-server interroge chaque kubelet à intervalles réguliers, et n'a rien à montrer avant sa première collecte. Les chiffres sont éclairants. Le cluster au repos consomme 668 Mio et 186 millièmes de processeur (`186m`, soit 0,186 cœur ; le chapitre 23 revient sur cette unité). L'API server, à lui seul, en utilise plus d'un tiers : c'est lui qui garde en mémoire les objets les plus demandés, pour ne pas solliciter etcd à chaque lecture. Gardez metrics-server actif : le chapitre 23 et l'autoscaling de la partie IV en ont besoin.

## Ce que kubectl lit avant de parler

Revenons à la question du début. kubectl ne devine rien : il lit un fichier, le **kubeconfig**, par défaut `~/.kube/config`, qui lui dit où est le cluster, comment le joindre et sous quelle identité se présenter. `minikube start` l'a rempli pour vous. L'option `--minify` n'en affiche que ce qui concerne le contexte courant :

```bash
kubectl config view --minify
```

```sortie
apiVersion: v1
clusters:
- cluster:
    certificate-authority: /home/romial/.minikube/ca.crt
    extensions:
    - extension:
        last-update: Fri, 25 Sep 2026 18:48:42 CEST
        provider: minikube.sigs.k8s.io
        version: v1.39.0
      name: cluster_info
    server: https://192.168.49.2:8443
  name: minikube
contexts:
- context:
    cluster: minikube
    extensions:
    - extension:
        last-update: Fri, 25 Sep 2026 18:48:42 CEST
        provider: minikube.sigs.k8s.io
        version: v1.39.0
      name: context_info
    namespace: default
    user: minikube
  name: minikube
current-context: minikube
kind: Config
users:
- name: minikube
  user:
    client-certificate: /home/romial/.minikube/profiles/minikube/client.crt
    client-key: /home/romial/.minikube/profiles/minikube/client.key
```

Le fichier contient trois listes et un choix[^kubeconfig] :

- `clusters` dit **où** : l'adresse de l'API server (`https://192.168.49.2:8443`) et le certificat de l'autorité qui a signé celui du serveur, pour que kubectl puisse vérifier qu'il parle au bon ;
- `users` dit **qui** : ici, un certificat client et sa clé privée, que kubectl présente pour prouver son identité ;
- `contexts` associe un cluster, un utilisateur et, facultativement, un namespace par défaut, sous un nom ;
- `current-context` désigne le contexte utilisé quand on ne précise rien.

(Les blocs `extensions` sont des notes que minikube laisse pour lui-même.) Le même fichier peut décrire autant de clusters qu'on veut. Sur le poste du cours, `kubectl config get-contexts` en liste plusieurs, dont certains sans rapport avec le cours :

```bash
kubectl config get-contexts
```

```sortie
CURRENT   NAME                          CLUSTER        AUTHINFO           NAMESPACE
          kind-listify                  kind-listify   kind-listify
*         minikube                      minikube       minikube           default
```

L'astérisque marque le contexte courant. `kubectl config use-context kind-listify` changerait de cluster ; `kubectl --context kind-listify get pods` viserait l'autre cluster pour une seule commande. Et `kubectl config set-context --current --namespace=ch15`, que le chapitre 15 a utilisé, modifie le namespace par défaut du contexte courant, sans toucher au cluster.

<Figure svg={kubeconfigFig} num="16.1" alt="Trois colonnes de blocs. Les clusters, qui disent où : minikube, avec son adresse https://192.168.49.2:8443 et son autorité de certification, et kind-listify. Les users, qui disent qui : minikube, avec son certificat client et sa clé, et kind-listify. Les contexts associent un cluster et un utilisateur : le contexte minikube pointe vers le cluster minikube et l'utilisateur minikube, avec le namespace default. current-context: minikube choisit ce contexte.">
La structure d'un kubeconfig. Un contexte est un couple (cluster, utilisateur), plus un namespace par défaut ; <code>current-context</code> désigne celui que kubectl utilise.
</Figure>

:::panne[The connection to the server localhost:8080 was refused]

C'est le message du début du chapitre. Quand kubectl ne trouve aucun contexte courant, il se rabat sur une vieille valeur par défaut, `localhost:8080`, héritée des premières versions de Kubernetes où l'API server écoutait sans chiffrement sur ce port. Le cas le plus fréquent avec minikube : `minikube stop` retire le contexte courant du kubeconfig.

```bash
minikube stop
kubectl config current-context; echo code=$?
grep '^current-context' ~/.kube/config
```

```sortie
* 1 nœud arrêté.
error: current-context is not set
code=1
current-context: ""
```

`minikube start` le remet en place. Les autres causes : une variable `KUBECONFIG` qui pointe vers un fichier vide ou absent, ou un kubeconfig écrasé par un autre outil. `kubectl config current-context` et `kubectl config get-contexts` sont les deux premières commandes à taper.

:::

### Plusieurs fichiers

La variable d'environnement `KUBECONFIG` indique un autre fichier, ou plusieurs, séparés par `:`. kubectl les **fusionne** alors, comme s'il n'y en avait qu'un. C'est la façon propre de garder un fichier par cluster, par exemple celui que vous donne un hébergeur, sans le mélanger à votre `~/.kube/config` (exercice 1).

### Qui êtes-vous pour le cluster ?

Le certificat client de minikube dit qui vous êtes. `openssl` le lit, et kubectl sait aussi demander au cluster comment il vous voit :

```bash
openssl x509 -in ~/.minikube/profiles/minikube/client.crt -noout -subject -issuer -dates
kubectl auth whoami
```

```sortie
subject=O=system:masters, CN=minikube-user
issuer=CN=minikubeCA
notBefore=Sep 24 09:02:40 2026 GMT
notAfter=Sep 24 09:02:40 2029 GMT
ATTRIBUTE                                           VALUE
Username                                            minikube-user
Groups                                              [system:masters system:authenticated]
Extra: authentication.kubernetes.io/credential-id   [X509SHA256=0b8d95e654e81a949a0a1f2ce9648149dbbff3d985bb2b03b7e0441ca349ae2b]
```

Kubernetes n'a pas de base d'utilisateurs : il fait confiance à tout certificat signé par l'autorité du cluster (ici `minikubeCA`), et en tire l'identité. Le champ `CN` (*common name*) devient le nom d'utilisateur, `minikube-user` ; chaque champ `O` (*organization*) devient un groupe, ici `system:masters`[^authn]. Or `system:masters` est un groupe spécial, auquel Kubernetes accorde tous les droits sans même consulter ses règles d'autorisation. Avec minikube, vous êtes donc administrateur absolu du cluster, pour trois ans : c'est commode pour apprendre, et c'est précisément ce qu'on évite en production (partie VI).

Toute requête suit le même chemin dans l'API server. Il vérifie **qui** vous êtes (authentification), puis **si vous en avez le droit** (autorisation, par des règles RBAC que le chapitre 43 détaillera), puis si l'objet envoyé est **acceptable** (admission : c'est à cette étape que Kubernetes a ajouté aux Pods du chapitre 15 leurs tolérances de 300 secondes). Seulement alors, l'objet est écrit dans etcd.

<Figure svg={cheminRequete} num="16.2" alt="kubectl lit le kubeconfig et envoie une requête HTTPS avec un certificat client au kube-apiserver. Dans l'API server, la requête passe par trois étapes : l'authentification, qui lit le CN et le O du certificat (minikube-user, groupe system:masters) ; l'autorisation par RBAC (system:masters a tous les droits) ; l'admission, qui ajoute des valeurs par défaut, des tolérances, vérifie les quotas. Puis l'objet est enregistré dans etcd.">
Le chemin d'une requête kubectl. Le kubeconfig fournit l'adresse et le certificat ; l'API server authentifie, autorise, admet, puis écrit dans etcd.
</Figure>

## Découvrir l'API depuis le terminal

Personne ne connaît par cœur les centaines de champs des objets Kubernetes. Deux commandes permettent de les retrouver sans quitter le terminal, et sans risquer de lire la documentation d'une autre version.

### Quels objets existent ?

```bash
kubectl api-resources | head -12
kubectl api-resources | grep -E '^(deployments|pods|services|nodes|namespaces) '
kubectl api-resources --no-headers | wc -l
kubectl api-resources --namespaced=false --no-headers | wc -l
```

```sortie
NAME                                SHORTNAMES   APIVERSION                        NAMESPACED   KIND
bindings                                         v1                                true         Binding
componentstatuses                   cs           v1                                false        ComponentStatus
configmaps                          cm           v1                                true         ConfigMap
endpoints                           ep           v1                                true         Endpoints
events                              ev           v1                                true         Event
limitranges                         limits       v1                                true         LimitRange
namespaces                          ns           v1                                false        Namespace
nodes                               no           v1                                false        Node
persistentvolumeclaims              pvc          v1                                true         PersistentVolumeClaim
persistentvolumes                   pv           v1                                false        PersistentVolume
pods                                po           v1                                true         Pod
namespaces                          ns           v1                                false        Namespace
nodes                               no           v1                                false        Node
pods                                po           v1                                true         Pod
services                            svc          v1                                true         Service
deployments                         deploy       apps/v1                           true         Deployment
nodes                                            metrics.k8s.io/v1beta1            false        NodeMetrics
pods                                             metrics.k8s.io/v1beta1            true         PodMetrics
73
38
```

73 types d'objets sur ce cluster, dont 38 n'appartiennent à aucun namespace (les nœuds, les namespaces eux-mêmes, les volumes persistants...). Chaque ligne donne le nom à utiliser avec kubectl, son abréviation (`po`, `deploy`, `svc` : `kubectl get deploy` équivaut à `kubectl get deployments`), et son **groupe d'API** avec sa version. Les objets historiques sont dans le groupe principal, noté `v1` ; les autres dans des groupes nommés, comme `apps/v1` pour les Deployments. Remarquez les deux dernières lignes : `metrics-server` a ajouté ses propres types, `NodeMetrics` et `PodMetrics`, dans un groupe `metrics.k8s.io`. L'API de Kubernetes s'étend, et la partie VIII apprendra à y ajouter vos propres types.

### Que contient un objet ?

`kubectl explain` donne la documentation d'un champ, tirée du schéma que l'API server publie :

```bash
kubectl explain deployment.spec.replicas
kubectl explain pod.spec.containers.imagePullPolicy
```

```sortie
GROUP:      apps
KIND:       Deployment
VERSION:    v1

FIELD: replicas <integer>


DESCRIPTION:
    Number of desired pods. This is a pointer to distinguish between explicit
    zero and not specified. Defaults to 1.

KIND:       Pod
VERSION:    v1

FIELD: imagePullPolicy <string>
ENUM:
    Always
    IfNotPresent
    Never

DESCRIPTION:
    Image pull policy. One of Always, Never, IfNotPresent. Defaults to Always if
    :latest tag is specified, or IfNotPresent otherwise. Cannot be updated. More
    info: https://kubernetes.io/docs/concepts/containers/images#updating-images
...
```

Le type du champ, ses valeurs possibles, sa valeur par défaut, et même ce qu'on ne peut pas modifier (`Cannot be updated`). La seconde réponse contient une information qui évite bien des surprises : une image étiquetée `:latest` est retéléchargée à chaque démarrage de conteneur, les autres seulement si elles manquent sur le nœud. Avec `--recursive`, `explain` affiche l'arborescence complète des sous-champs :

```bash
kubectl explain deployment.spec.strategy --recursive
```

```sortie
GROUP:      apps
KIND:       Deployment
VERSION:    v1

FIELD: strategy <DeploymentStrategy>


DESCRIPTION:
    The deployment strategy to use to replace existing pods with new ones.
    DeploymentStrategy describes how to replace existing pods with new ones.

FIELDS:
  rollingUpdate	<RollingUpdateDeployment>
    maxSurge	<IntOrString>
    maxUnavailable	<IntOrString>
  type	<string>
  enum: Recreate, RollingUpdate
```

Ce sont les champs que le chapitre 19 réglera. Prenez l'habitude : avant d'écrire un champ dans un manifeste, `kubectl explain` vous dit s'il existe, où il se place et ce qu'il accepte.

## Lire les objets sous toutes leurs formes

Créons de quoi regarder, dans le namespace `default` :

```bash
kubectl create deployment essai --image=nginx:1.30-alpine --replicas=2
kubectl rollout status deployment/essai
```

`kubectl get` sait présenter le même résultat de bien des façons. Le format par défaut résume ; `-o wide` ajoute quelques colonnes, dont le nœud et l'adresse IP ; `--show-labels` affiche les étiquettes ; `-o name` ne garde que les noms, sous une forme directement réutilisable par d'autres commandes :

```bash
kubectl get pods -o wide
kubectl get pods --show-labels
kubectl get pods -o name
```

```sortie
NAME                   READY   STATUS    RESTARTS   AGE   IP           NODE       NOMINATED NODE   READINESS GATES
essai-7f455f55-bsg8h   1/1     Running   0          0s    10.244.0.7   minikube   <none>           <none>
essai-7f455f55-fltsx   1/1     Running   0          0s    10.244.0.6   minikube   <none>           <none>
NAME                   READY   STATUS    RESTARTS   AGE   LABELS
essai-7f455f55-bsg8h   1/1     Running   0          0s    app=essai,pod-template-hash=7f455f55
essai-7f455f55-fltsx   1/1     Running   0          0s    app=essai,pod-template-hash=7f455f55
pod/essai-7f455f55-bsg8h
pod/essai-7f455f55-fltsx
```

Pour extraire exactement les champs qu'on veut, deux formats prennent un chemin dans l'objet. **JSONPath** produit du texte libre, pratique dans un script ; **custom-columns** produit un tableau avec vos propres titres :

```bash
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.status.podIP}{"\n"}{end}'
kubectl get pods -o custom-columns='NOM:.metadata.name,NOEUD:.spec.nodeName,IMAGE:.spec.containers[0].image,DEMARRE:.status.startTime'
```

```sortie
essai-7f455f55-bsg8h  10.244.0.7
essai-7f455f55-fltsx  10.244.0.6
NOM                    NOEUD      IMAGE               DEMARRE
essai-7f455f55-bsg8h   minikube   nginx:1.30-alpine   2026-09-26T04:50:18Z
essai-7f455f55-fltsx   minikube   nginx:1.30-alpine   2026-09-26T04:50:18Z
```

Les chemins s'écrivent comme dans le YAML de l'objet, avec des crochets pour les listes. Pour savoir quel chemin écrire, rien ne vaut l'objet complet, `-o yaml` (ou `-o json`, que `jq` sait traiter) :

```bash
kubectl get deployment essai -o yaml | head -40
```

```sortie
apiVersion: apps/v1
kind: Deployment
metadata:
  annotations:
    deployment.kubernetes.io/revision: "1"
  creationTimestamp: "2026-09-26T04:50:17Z"
  generation: 1
  labels:
    app: essai
  name: essai
  namespace: default
  resourceVersion: "5947"
  uid: e2c69a0a-0d6f-4641-bf5f-494c753b19cf
spec:
  progressDeadlineSeconds: 600
  replicas: 2
  revisionHistoryLimit: 10
  selector:
    matchLabels:
      app: essai
  strategy:
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 25%
    type: RollingUpdate
  template:
    metadata:
      labels:
        app: essai
    spec:
      containers:
      - image: nginx:1.30-alpine
        imagePullPolicy: IfNotPresent
        name: nginx
        resources: {}
        terminationMessagePath: /dev/termination-log
        terminationMessagePolicy: File
      dnsPolicy: ClusterFirst
      restartPolicy: Always
      schedulerName: default-scheduler
```

Tout objet a la même forme : `apiVersion` et `kind` disent ce qu'il est, `metadata` porte son identité (nom, namespace, étiquettes, un identifiant unique `uid`, et `resourceVersion`, le numéro de version que l'exercice 2 du chapitre 15 a vu passer dans une surveillance), `spec` l'état désiré, `status` l'état observé. Une commande d'une ligne a produit un objet de 62 lignes, dont la plupart sont des valeurs par défaut. Le vrai objet stocké en contient même 140 : kubectl masque par défaut les `managedFields`, qui notent quel outil a écrit quel champ, et que `--show-managed-fields` fait apparaître (le chapitre 18 en montrera l'utilité).

### describe, logs, exec, port-forward

`kubectl describe` assemble un résumé lisible d'un objet et, surtout, les **événements** qui le concernent :

```bash
kubectl describe $(kubectl get pods -l app=essai -o name | head -1)
```

```sortie
Name:             essai-7f455f55-bsg8h
Namespace:        default
Priority:         0
Service Account:  default
Node:             minikube/192.168.49.2
Start Time:       Sat, 26 Sep 2026 06:50:18 +0200
Labels:           app=essai
                  pod-template-hash=7f455f55
Annotations:      <none>
Status:           Running
IP:               10.244.0.7
...
Events:
  Type    Reason     Age   From               Message
  ----    ------     ----  ----               -------
  Normal  Scheduled  1s    default-scheduler  Successfully assigned default/essai-7f455f55-bsg8h to minikube
  Normal  Pulled     1s    kubelet            spec.containers{nginx}: Container image "nginx:1.30-alpine" already present on machine and can be accessed by the pod
  Normal  Created    1s    kubelet            spec.containers{nginx}: Container created
  Normal  Started    1s    kubelet            spec.containers{nginx}: Container started
```

C'est la première commande à taper quand un Pod ne démarre pas : un conteneur qui ne trouve pas son image, un Pod qu'aucun nœud ne peut accueillir, tout se lit dans les événements. Trois autres commandes reprennent ce que Docker vous a appris, pour un Pod :

```bash
P=$(kubectl get pods -l app=essai -o name | head -1)
kubectl logs $P | tail -3
kubectl exec $P -- nginx -v
kubectl port-forward $P 8090:80 &
curl -s localhost:8090 | grep -o '<title>.*</title>'
kill %1
```

```sortie
2026/09/26 04:50:18 [notice] 1#1: start worker process 49
2026/09/26 04:50:18 [notice] 1#1: start worker process 50
2026/09/26 04:50:18 [notice] 1#1: start worker process 51
nginx version: nginx/1.30.5
Forwarding from 127.0.0.1:8090 -> 80
Forwarding from [::1]:8090 -> 80
Handling connection for 8090
<title>Welcome to nginx!</title>
```

`kubectl logs` lit la sortie du conteneur, que le kubelet conserve sur le nœud ; `kubectl exec` lance une commande dans le conteneur, comme `docker exec` ; `kubectl port-forward` ouvre sur votre poste un port relié à celui du Pod, à travers l'API server et le kubelet. Ce dernier est un outil de dépannage : il ne dure que le temps de la commande, et le chapitre 20 montrera comment exposer une application pour de bon.

:::panne[error: the server doesn't have a resource type "deploymnt"]

Une faute de frappe dans un type d'objet ne donne pas une suggestion, mais ce message, qui peut faire croire à un problème de cluster. `kubectl api-resources | grep -i deploy` retrouve le bon nom. De même, `kubectl config use-context inexistant` répond `error: no context exists with the name: "inexistant"` : `kubectl config get-contexts` liste les noms valides.

:::

## Exercices

:::exercice[Exercice 1 : un kubeconfig écrit à la main]

Sans éditer de fichier, avec les commandes `kubectl config set-cluster`, `set-credentials`, `set-context` et `use-context` et l'option `--kubeconfig=mon.conf`, fabriquez un kubeconfig qui donne accès au cluster minikube sous le nom de contexte `labo`, avec `kube-system` comme namespace par défaut. Utilisez-le avec `KUBECONFIG`, puis affichez les contextes de votre kubeconfig habituel et de celui-ci fusionnés.

:::

<details>
<summary>Corrigé</summary>

```bash
C=mon.conf
kubectl --kubeconfig=$C config set-cluster labo --server=https://$(minikube ip):8443 --certificate-authority=$HOME/.minikube/ca.crt
kubectl --kubeconfig=$C config set-credentials moi --client-certificate=$HOME/.minikube/profiles/minikube/client.crt --client-key=$HOME/.minikube/profiles/minikube/client.key
kubectl --kubeconfig=$C config set-context labo --cluster=labo --user=moi --namespace=kube-system
kubectl --kubeconfig=$C config use-context labo
KUBECONFIG=$PWD/$C kubectl get pods | head -3
KUBECONFIG=$HOME/.kube/config:$PWD/$C kubectl config get-contexts
```

```sortie
Cluster "labo" set.
User "moi" set.
Context "labo" created.
Switched to context "labo".
NAME                               READY   STATUS    RESTARTS       AGE
coredns-559f6c778d-h7h7j           1/1     Running   5 (2m ago)     19h
etcd-minikube                      1/1     Running   6 (2m ago)     19h
CURRENT   NAME                          CLUSTER        AUTHINFO           NAMESPACE
          labo                          labo           moi                kube-system
*         minikube                      minikube       minikube           default
```

Le fichier produit (`cat mon.conf`) a exactement la structure de la figure 16.1, avec vos noms. `kubectl get pods`, sans `-n`, liste les Pods de `kube-system`, le namespace de votre contexte. Lors d'une fusion, le contexte courant est celui du premier fichier qui en définit un : ici, `minikube`. Rien n'oblige le nom du cluster, de l'utilisateur et du contexte à se ressembler ; minikube leur donne le même nom par commodité.

</details>

:::exercice[Exercice 2 : trente secondes]

Quand on supprime un Pod, ses conteneurs ont un certain temps pour s'arrêter proprement avant d'être tués. Trouvez avec `kubectl explain` le nom et la valeur par défaut de ce délai, et où il se règle.

:::

<details>
<summary>Corrigé</summary>

```bash
kubectl explain pod.spec.terminationGracePeriodSeconds
```

```sortie
DESCRIPTION:
    Optional duration in seconds the pod needs to terminate gracefully. May be
    decreased in delete request. Value must be non-negative integer. The value
    zero indicates stop immediately via the kill signal (no opportunity to shut
    down). If this value is nil, the default grace period will be used instead.
    The grace period is the duration in seconds after the processes running in
    the pod are sent a termination signal and the time when the processes are
    forcibly halted with a kill signal. Set this value longer than the expected
    cleanup time for your process. Defaults to 30 seconds.
```

Le champ `terminationGracePeriodSeconds` se règle au niveau du Pod (`pod.spec`), pas du conteneur, et vaut 30 secondes par défaut. C'est l'équivalent du délai de dix secondes de `docker stop` (chapitre 2), en plus long. La description ajoute qu'on peut le raccourcir au moment de la suppression : c'est l'option `kubectl delete --grace-period`. Le chapitre 22 s'en servira.

</details>

:::exercice[Exercice 3 : qui redémarre le plus ?]

Affichez les Pods de tous les namespaces avec, pour chacun, son namespace, son nom, son nœud et le nombre de redémarrages de son premier conteneur, triés par nombre de redémarrages.

:::

<details>
<summary>Corrigé</summary>

```bash
kubectl get pods -A --sort-by='.status.containerStatuses[0].restartCount' \
  -o custom-columns='NS:.metadata.namespace,NOM:.metadata.name,NOEUD:.spec.nodeName,REDEMARRAGES:.status.containerStatuses[0].restartCount' | tail -6
```

```sortie
kube-system   kindnet-rq5t5                      minikube   6
kube-system   kube-apiserver-minikube            minikube   6
kube-system   kube-controller-manager-minikube   minikube   6
kube-system   kube-proxy-n9tb4                   minikube   6
kube-system   kube-scheduler-minikube            minikube   6
kube-system   storage-provisioner                minikube   11
```

`-A` (ou `--all-namespaces`) élargit la requête à tout le cluster, et `--sort-by` trie selon un chemin JSONPath. Sur le poste du cours, les composants du plan de contrôle comptent six redémarrages : un par arrêt et redémarrage de minikube, pas des plantages. `storage-provisioner` en compte davantage : `kubectl logs -n kube-system storage-provisioner --previous` montre qu'il s'arrête avec une erreur fatale (`error getting server version ... i/o timeout`) quand il démarre avant que l'API server soit joignable, puis le kubelet le relance. Un compteur de redémarrages ne dit rien à lui seul : il faut `kubectl describe` et `kubectl logs --previous` (chapitre 17) pour en connaître la cause.

</details>

:::exercice[Exercice 4 : l'API sans kubectl]

Lisez le Deployment `essai` avec `kubectl get --raw` en donnant vous-même le chemin de l'API. Puis lancez `kubectl proxy --port=8011` et lisez la liste des Pods de `default` et la version du serveur avec `curl`. Que fait `kubectl proxy` pour que `curl` n'ait besoin d'aucun certificat ?

:::

<details>
<summary>Corrigé</summary>

```bash
kubectl get --raw /apis/apps/v1/namespaces/default/deployments/essai | jq '{kind, name: .metadata.name, replicas: .spec.replicas, ready: .status.readyReplicas}'
kubectl proxy --port=8011 &
curl -s localhost:8011/api/v1/namespaces/default/pods | jq -r '.items[].metadata.name'
curl -s localhost:8011/version | jq -r .gitVersion
kill %1
```

```sortie
{
  "kind": "Deployment",
  "name": "essai",
  "replicas": 2,
  "ready": 2
}
Starting to serve on 127.0.0.1:8011
essai-7f455f55-bsg8h
essai-7f455f55-fltsx
v1.37.0
```

Le chemin suit toujours le même schéma : `/apis/<groupe>/<version>/namespaces/<namespace>/<type>/<nom>`, ou `/api/v1/...` pour le groupe principal. `kubectl proxy` écoute en HTTP sur `127.0.0.1` et relaie chaque requête vers l'API server en HTTPS, en y ajoutant l'identité du kubeconfig. `curl` hérite donc de vos droits d'administrateur, sans certificat. C'est pratique pour explorer l'API, et c'est aussi pourquoi le proxy n'écoute que sur `127.0.0.1` par défaut : ouvert sur le réseau, il donnerait ces droits à n'importe qui.

</details>

:::exercice[Exercice 5 : ce que fait minikube stop]

Relevez le contexte courant, arrêtez minikube, relevez-le de nouveau, puis regardez la ligne `current-context` de `~/.kube/config`. Redémarrez minikube. Qu'en déduisez-vous pour un script qui lance des commandes kubectl juste après `minikube stop` ?

:::

<details>
<summary>Corrigé</summary>

```bash
kubectl config current-context
minikube stop
kubectl config current-context; echo code=$?
grep -E '^current-context' ~/.kube/config
minikube start
kubectl config current-context
```

```sortie
minikube
* 1 nœud arrêté.
error: current-context is not set
code=1
current-context: ""
* Terminé ! kubectl est maintenant configuré pour utiliser "minikube" cluster et espace de noms "default" par défaut.
minikube
```

`minikube stop` vide le contexte courant, sans supprimer le contexte lui-même, et `minikube start` le rétablit. Un script qui enchaînerait `kubectl` après un arrêt ne viserait donc aucun cluster, et tomberait sur `localhost:8080`. Si vous travaillez avec plusieurs clusters, c'est même une protection : aucune commande ne part par erreur vers un autre cluster. Dans un script, préférez toujours `--context minikube` explicite, ce qui rend la commande indépendante de l'état du kubeconfig.

</details>

## Nettoyer

```bash
kubectl delete deployment essai
rm -f mon.conf
```

Laissez metrics-server actif ; il se désactive avec `minikube addons disable metrics-server`.

[^minikube]: minikube, « Welcome! », et « Drivers ». [minikube.sigs.k8s.io/docs/drivers](https://minikube.sigs.k8s.io/docs/drivers/)

[^kubeconfig]: Kubernetes, « Organizing Cluster Access Using kubeconfig Files ». [kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/)

[^authn]: Kubernetes, « Authenticating », section *X509 client certificates*. [kubernetes.io/docs/reference/access-authn-authz/authentication](https://kubernetes.io/docs/reference/access-authn-authz/authentication/#x509-client-certificates)
