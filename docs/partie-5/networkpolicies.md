---
title: Les NetworkPolicies
sidebar_label: 41. Les NetworkPolicies
description: "Un cluster où tout parle à tout, et comment le cloisonner : le refus par défaut et ce qu'il casse, les politiques d'entrée et de sortie de Colis flux par flux, le piège du tiret de trop, la façon dont kindnet les applique, et Cilium qui filtre jusqu'aux requêtes HTTP."
partie: 5
chapitre: '41'
---

import politiquesColis from '@site/src/figures/politiques-colis.svg';
import etOu from '@site/src/figures/et-ou.svg';

Supposons qu'une faille, dans une bibliothèque de l'application de vitrine d'une autre équipe, permette à un attaquant d'exécuter des commandes dans l'un de ses conteneurs. La vitrine n'a rien à voir avec Colis : autre namespace, autre équipe, aucune raison d'échanger quoi que ce soit. Que peut atteindre l'attaquant ? Le Pod `intrus` du fichier `intrus.yaml` joue son rôle, dans le namespace `vitrine`, avec quelques outils réseau :

```bash
kubectl apply -f intrus.yaml
kubectl -n vitrine exec intrus -- sh -c 'nc -z -w 2 postgres.colis.svc.cluster.local 5432 && echo ouvert'
kubectl -n vitrine exec intrus -- sh -c 'printf "PING\r\nLLEN colis:a-estimer\r\n" | nc -w 2 redis.colis.svc.cluster.local 6379'
```

```sortie
ouvert
+PONG
:0
```

Le port de PostgreSQL est ouvert, et Redis répond à qui le lui demande : il accepte les commandes, et dit que la file de travail de Colis est vide pour l'instant. Redis n'a pas de mot de passe dans Colis ; l'attaquant pourrait y déposer de faux travaux, ou tout effacer. PostgreSQL en a un, mais son port est à portée de n'importe quelle tentative. Rien de tout cela n'est un défaut de Colis ni de la vitrine : c'est le contrat du chapitre 39. Tous les Pods peuvent joindre tous les autres, dans tous les namespaces, et un namespace n'est pas une frontière réseau.

Ce chapitre installe cette frontière, avec les **NetworkPolicies** : des objets de l'API qui disent quels Pods peuvent parler à quels autres, et que le greffon réseau applique. On le fera sur le vrai Colis, dans le namespace `colis` du cluster principal, en commençant par tout fermer, puis en rouvrant exactement ce qu'il faut, flux par flux. Les politiques sont dans [l'archive politiques](pathname:///kits/politiques.tar.gz).

Une précaution d'abord : une NetworkPolicy n'a d'effet que si le greffon réseau la met en œuvre. Le cluster principal utilise kindnet, et on a vérifié au chapitre 39 que sa version actuelle le fait. Sur un cluster que vous ne connaissez pas, faites toujours l'essai d'une politique de refus avant de vous fier aux autres : une politique ignorée est acceptée par l'API sans le moindre avertissement.

## Tout fermer

Une NetworkPolicy choisit des Pods, par un sélecteur d'étiquettes, et décrit ce qui a le droit d'y entrer (`ingress`), d'en sortir (`egress`), ou les deux. Le principe qui la gouverne tient en deux phrases[^np]. Un Pod qu'aucune politique ne choisit est ouvert à tout, dans les deux sens : c'est l'état par défaut. Dès qu'une politique le choisit pour un sens, il devient **isolé** dans ce sens, et seul passe ce qu'une politique autorise explicitement ; les politiques s'additionnent, aucune ne retire ce qu'une autre permet.

La politique la plus utile est donc aussi la plus courte :

```yaml title="00-refus-par-defaut.yaml"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: refus-par-defaut
  namespace: colis
spec:
  podSelector: {}                 # tous les Pods du namespace
  policyTypes: [Ingress, Egress]  # aucune règle : tout est refusé, dans les deux sens
```

Elle choisit tous les Pods de `colis`, les isole dans les deux sens, et n'autorise rien. Voyons ce qu'il reste, avec une petite série de vérifications qui reviendra plusieurs fois : le site par son adresse de LoadBalancer, l'API à travers le site, l'API à travers la passerelle HTTPS du chapitre 28, et l'intrus.

```bash
kubectl apply -f 00-refus-par-defaut.yaml
```

```sortie
networkpolicy.networking.k8s.io/refus-par-defaut created
  site (LoadBalancer)       : 000
  API par le site           : 
  API par la passerelle     : 
  intrus vers PostgreSQL    : fermé
  intrus vers Redis         : (pas de réponse) 
```

L'intrus est arrêté, et Colis avec lui. Plus rien n'entre, pas même les visiteurs du site. Mais le plus instructif est ce qui ne sort plus :

```bash
kubectl -n colis exec deploy/web -- wget -qO- -T 3 http://api:8000/pret
```

```sortie
wget: bad address 'api:8000'
command terminated with exit code 1
```

`bad address` : le site ne trouve même plus l'adresse de l'API. Le refus s'applique aussi à la sortie vers CoreDNS, dans `kube-system`, et sans résolution de noms, plus aucun nom de Service ne fonctionne. C'est la première surprise de tout cloisonnement, et la raison pour laquelle la politique suivante porte sur le DNS.

La seconde surprise se lit dans l'état des Pods :

```bash
kubectl -n colis get pods -o custom-columns=POD:.metadata.name,PRET:.status.containerStatuses[0].ready --no-headers
```

```sortie
api-85cbf95c69-2669v          false
api-85cbf95c69-2h9kz          false
api-85cbf95c69-4c276          true
api-85cbf95c69-4m7ns          true
api-85cbf95c69-7cc84          false
api-85cbf95c69-99p9p          true
api-canari-799c55878f-zsjwx   true
postgres-0                    true
redis-578785659c-48lq8        true
web-599d986bdf-md86x          true
web-599d986bdf-vx59k          true
```

(Le HPA du chapitre 31 avait porté l'API à six répliques pendant mes essais.) Les sondes du kubelet, elles, passent toujours : la spécification exige que le trafic entre un nœud et ses propres Pods soit toujours permis[^np], et la plupart des Pods restent prêts. Mais trois Pods de l'API ne le sont pas. L'exercice 2 explique lesquels, et pourquoi.

## Rouvrir, flux par flux

Pour rouvrir juste ce qu'il faut, il faut d'abord savoir ce qui parle à quoi dans Colis. La figure 41.1 en fait l'inventaire, et c'est la partie la plus longue du travail : le site et la passerelle appellent l'API ; l'API, le worker et la purge vont à PostgreSQL ; l'API et le worker vont à Redis ; et un acteur qu'on oublie facilement, l'opérateur de KEDA, lit la longueur de la file dans Redis depuis son namespace (chapitre 31).

<Figure svg={politiquesColis} num="41.1" alt="Les flux que les politiques de Colis laissent passer, dans le namespace colis en refus par défaut. Tout client, par le LoadBalancer, vers web sur le port 80 ; web vers api et api-canari sur le port 8000 ; envoy, dans le namespace envoy-gateway-system, vers api ; api vers postgres, port 5432, et vers redis, port 6379 ; worker vers postgres et redis ; purge vers postgres ; keda-operator, dans le namespace keda, vers redis ; tous les Pods vers CoreDNS, dans kube-system, port 53. L'intrus du namespace vitrine est refusé à la frontière du namespace.">
Les flux de Colis, et rien d'autre. Chaque flèche correspond à une règle d'entrée sur le Pod de destination et, le cas échéant, à une règle de sortie sur le Pod de départ.
</Figure>

Une connexion ne passe que si les deux bouts sont d'accord : la sortie doit être autorisée côté émetteur s'il est isolé en sortie, et l'entrée côté destinataire s'il est isolé en entrée. Avec un refus par défaut dans les deux sens, chaque flèche de la figure demande donc deux autorisations. On commence par le DNS, pour tous :

```yaml title="10-dns.yaml"
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
  - to:
    - namespaceSelector:
        matchLabels: {kubernetes.io/metadata.name: kube-system}
      podSelector:
        matchLabels: {k8s-app: kube-dns}
    ports:
    - {protocol: UDP, port: 53}
    - {protocol: TCP, port: 53}
```

Une destination hors du namespace se désigne par un `namespaceSelector`. Chaque namespace porte automatiquement l'étiquette `kubernetes.io/metadata.name` avec son nom, ce qui permet de le viser sans rien ajouter. Le `podSelector` écrit **dans le même élément** restreint aux Pods de CoreDNS dans ce namespace ; on reviendra longuement sur ce « même élément ». Vient ensuite le site :

```yaml title="20-web.yaml"
spec:
  podSelector:
    matchLabels: {app.kubernetes.io/name: web}
  policyTypes: [Ingress, Egress]
  ingress:
  - ports:
    - {port: http}                # aucune clause from : n'importe quelle source
  egress:
  - to:
    - podSelector:
        matchLabels: {app.kubernetes.io/name: api}
    ports:
    - {port: 8000}
```

Une règle d'entrée sans `from` accepte n'importe quelle source, mais seulement sur le port nommé `http` du conteneur. C'est ce qu'il faut pour un site public, dont les visiteurs arrivent par le LoadBalancer, avec une adresse traduite par le nœud (chapitre 40). En sortie, le site ne peut joindre que les Pods de l'API, sur leur port 8000. La politique de l'API ouvre son entrée au site et à la passerelle, et sa sortie à PostgreSQL et Redis :

```yaml title="30-api.yaml (extrait)"
  podSelector:
    matchExpressions:
    - {key: app.kubernetes.io/name, operator: In, values: [api, api-canari]}
  ingress:
  - from:
    - podSelector:
        matchLabels: {app.kubernetes.io/name: web}
    - namespaceSelector:          # le même élément de liste que podSelector : les deux conditions à la fois
        matchLabels: {kubernetes.io/metadata.name: envoy-gateway-system}
      podSelector:
        matchLabels: {app.kubernetes.io/name: envoy}
    ports:
    - {port: http}
```

Les fichiers 40 à 60 font de même pour PostgreSQL, Redis (avec l'opérateur de KEDA), le worker et la purge. Appliquons tout, et relançons les vérifications :

```bash
kubectl apply -f 10-dns.yaml -f 20-web.yaml -f 30-api.yaml -f 40-postgres.yaml -f 50-redis.yaml -f 60-worker-purge.yaml
kubectl -n colis get networkpolicy
```

```sortie
  site (LoadBalancer)       : 200
  API par le site           : {"stockage":"postgres","file":"redis","pret":true}
  API par la passerelle     : {"stockage":"postgres","file":"redis","pret":true}
  intrus vers PostgreSQL    : fermé
  intrus vers Redis         : (pas de réponse) 
NAME               POD-SELECTOR                                 AGE
api                app.kubernetes.io/name in (api,api-canari)   9s
dns                <none>                                       9s
postgres           app.kubernetes.io/name=postgres              9s
purge              app.kubernetes.io/name=purge                 9s
redis              app.kubernetes.io/name=redis                 9s
refus-par-defaut   <none>                                       33s
web                app.kubernetes.io/name=web                   9s
worker             app.kubernetes.io/name=worker                9s
```

Colis répond de nouveau, par ses deux entrées, et l'intrus reste dehors. Mais une page qui s'affiche ne prouve pas que tout marche : le worker, la purge et KEDA ne se voient pas depuis le site. Envoyons douze colis, qui doivent réveiller le worker par KEDA, puis être estimés par lui ; lançons la purge à la main ; et essayons de faire sortir l'API vers Internet :

```bash
for i in $(seq 1 12); do curl -s -o /dev/null -X POST http://192.168.49.100/api/colis -H 'Content-Type: application/json' -d "{\"destinataire\":\"Essai $i\",\"depart\":\"Paris\",\"arrivee\":\"Lyon\",\"poids_kg\":1}"; done
kubectl -n colis create job purge-essai --from=cronjob/purge
kubectl -n colis exec deploy/api -- python3 -c "import urllib.request; urllib.request.urlopen('http://example.com', timeout=4)"
```

(Le script de rejeu du chapitre attend ensuite le réveil du worker, compte les colis estimés et affiche la fin du journal de la purge ; voici ses lignes utiles.)

```sortie
worker réveillé par KEDA après 4 s
file : 0
36 colis d essai, 36 estimés
job.batch/purge-essai condition met
purge : 0 colis livrés depuis plus de 30 jours supprimés
# l API vers Internet
urllib.error.URLError: <urlopen error [Errno 101] Network unreachable>
```

(Trente-six colis d'essai, parce que ce rejeu est le troisième ; tous sont estimés.) KEDA a lu la file et réveillé le worker, qui a joint Redis et PostgreSQL ; la purge a joint PostgreSQL ; l'API ne sort pas du cluster. C'est l'étape qu'on saute trop souvent : les flux secondaires (tâches planifiées, opérateurs, sondes extérieures, sauvegardes) sont ceux qu'une politique oublie, et on ne s'en aperçoit que la nuit où la purge échoue.

`kubectl describe` rend une politique plus lisible que son YAML, et c'est le meilleur moyen de relire ce qu'on a écrit :

```bash
kubectl -n colis describe networkpolicy api
```

```sortie
Spec:
  PodSelector:     app.kubernetes.io/name in (api,api-canari)
  Allowing ingress traffic:
    To Port: http/TCP
    From:
      PodSelector: app.kubernetes.io/name=web
    From:
      NamespaceSelector: kubernetes.io/metadata.name=envoy-gateway-system
      PodSelector: app.kubernetes.io/name=envoy
  Allowing egress traffic:
    To Port: 5432/TCP
    To:
      PodSelector: app.kubernetes.io/name=postgres
    ----------
    To Port: 6379/TCP
    To:
      PodSelector: app.kubernetes.io/name=redis
  Policy Types: Ingress, Egress
```

Deux sources distinctes (`From:` répété), dont la seconde réunit deux conditions ; deux règles de sortie (séparées par les tirets), chacune avec son port.

## Un tiret de trop

La règle d'entrée de Redis doit laisser passer l'opérateur de KEDA, et lui seul, depuis le namespace `keda`. Elle s'écrit avec un `namespaceSelector` et un `podSelector` **dans le même élément** de la liste `from`. Voici la même règle avec un tiret de plus, l'erreur la plus classique qu'on puisse faire en écrivant une NetworkPolicy :

```yaml title="50-redis-erreur.yaml (extrait)"
  ingress:
  - from:
    - podSelector:
        matchExpressions:
        - {key: app.kubernetes.io/name, operator: In, values: [api, api-canari, worker]}
    - namespaceSelector:
        matchLabels: {kubernetes.io/metadata.name: keda}
    - podSelector:
        matchLabels: {app.kubernetes.io/name: keda-operator}
```

Un tiret ouvre un nouvel élément, et chaque élément est une source autorisée à lui seul. La règle dit maintenant : l'API et le worker, **ou** n'importe quel Pod du namespace `keda`, **ou** un Pod de `colis` étiqueté `keda-operator`. Le fichier `curieux.yaml` crée un Pod quelconque dans le namespace `keda` ; voyons ce qu'il obtient de Redis avec la bonne politique, la mauvaise, puis la bonne de nouveau :

```bash
kubectl apply -f curieux.yaml
t() { kubectl -n keda exec curieux -- sh -c 'printf "PING\r\n" | nc -w 2 redis.colis.svc.cluster.local 6379 || echo "(pas de réponse)"' | tr -d '\r' | tail -1; }
echo "politique correcte : $(t)"
kubectl apply -f 50-redis-erreur.yaml; echo "politique erronée   : $(t)"
kubectl apply -f 50-redis.yaml; echo "politique corrigée  : $(t)"
```

```sortie
politique correcte : (pas de réponse)
networkpolicy.networking.k8s.io/redis configured
politique erronée   : +PONG
networkpolicy.networking.k8s.io/redis configured
politique corrigée  : (pas de réponse)
```

La politique erronée a été acceptée sans un mot : elle est parfaitement valide, elle dit simplement autre chose. La documentation de Kubernetes consacre un paragraphe entier à cette différence[^np], et la figure 41.2 la met côte à côte. Deux réflexes évitent le piège : relire chaque politique avec `kubectl describe`, où les deux formes se distinguent nettement ; et tester le refus, pas seulement l'accès, avec un Pod qui ne devrait pas passer.

<Figure svg={etOu} num="41.2" alt="À gauche, un seul élément dans la liste from : namespaceSelector keda et podSelector keda-operator dans le même élément, donc les deux conditions à la fois ; seul l'opérateur de KEDA est autorisé, et le Pod curieux du namespace keda n'obtient pas de réponse. À droite, deux éléments, le second commençant par un tiret devant podSelector : l'une ou l'autre condition suffit ; tout Pod du namespace keda est autorisé, ainsi que tout Pod de colis étiqueté keda-operator, et le Pod curieux reçoit +PONG.">
Le même bloc, avec et sans un tiret. À gauche, une source qui remplit deux conditions ; à droite, deux sources indépendantes.
</Figure>

## Comment kindnet applique les politiques

L'API ne fait que stocker les NetworkPolicies ; c'est le greffon réseau qui les traduit en règles. kindnet embarque pour cela le projet `kube-network-policies` de Kubernetes[^knp], et on peut regarder son travail sur le nœud :

```bash
minikube ssh -- sudo nft list table inet kindnet-network-policies | sed -n '/set podips-v4/,/}/p;/chain postrouting/,/}/p'
kubectl -n colis get pods -o custom-columns=POD:.metadata.name,IP:.status.podIP --no-headers | grep -v '<none>'
```

```sortie
	set podips-v4 {
		type ipv4_addr
		elements = { 10.244.0.7, 10.244.0.10,
			     10.244.0.11, 10.244.0.14,
			     10.244.0.18, 10.244.0.22,
			     10.244.0.32, 10.244.0.48,
			     10.244.0.53, 10.244.0.54,
			     10.244.0.55, 10.244.0.56,
			     10.244.0.57 }
	chain postrouting {
		type filter hook postrouting priority srcnat - 5; policy accept;
		udp dport 53 accept
		...
		meta skuid 0 counter packets 3324 bytes 780984 accept
		ct label 28 ct state established,related counter packets 135 bytes 12251 accept
		ip saddr @podips-v4 queue flags bypass to 101
		ip daddr @podips-v4 queue flags bypass to 101
		...
		ct label set 28
	}
api-85cbf95c69-2669v          10.244.0.55
api-85cbf95c69-2h9kz          10.244.0.54
...
web-599d986bdf-vx59k          10.244.0.32
worker-594df4b89-txh2q        10.244.0.56
```

Le fonctionnement est original. L'ensemble `podips-v4` contient les adresses des Pods qu'une politique choisit : ici, les treize Pods de `colis`. Tout paquet de ces Pods ou vers eux, s'il n'appartient pas déjà à une connexion acceptée, est envoyé par `queue ... to 101` dans une **file NFQUEUE** : le noyau le met de côté et le confie à un programme ordinaire, le démon kindnet, qui compare la connexion aux politiques et rend son verdict. Si elle est acceptée, le noyau pose sur la connexion une marque dans son suivi (`ct label 28`), et tous les paquets suivants passent par la règle `ct label 28 ct state established,related ... accept` sans plus consulter personne. Seul le premier paquet de chaque connexion fait le détour par l'espace utilisateur. Deux règles de la chaîne répondent aussi à des questions de ce chapitre. `udp dport 53 accept` n'ouvre pas le DNS aux Pods isolés : leurs requêtes DNS sont examinées plus tôt, dans une chaîne `prerouting` qu'on n'a pas affichée, et c'est là que le refus par défaut les a arrêtées. Et `meta skuid 0 ... accept` accepte ce qu'envoient les processus de l'utilisateur root **du nœud**, dont les sondes du kubelet.

Les autres greffons font autrement : Calico traduit les politiques en règles iptables ou en programmes eBPF, Cilium en identités (chapitre 39), et c'est avec lui qu'on peut aller plus loin.

## Plus loin avec Cilium : filtrer les requêtes

Une NetworkPolicy s'arrête aux adresses et aux ports. Elle peut autoriser un client à joindre le port 8080 d'un serveur, pas à y faire seulement des `GET` sur `/hostname`. Cilium, qui a son propre type de politique (`CiliumNetworkPolicy`), sait descendre jusqu'aux requêtes HTTP, en faisant passer le trafic concerné par un proxy Envoy intégré à son agent[^l7]. Sur le profil `cilium`, le fichier `cilium-l7.yaml` crée, dans le namespace `ch41`, un serveur, un client étiqueté `app=client` et un autre étiqueté `app=autre` :

```yaml title="cilium-politique.yaml"
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: serveur-l7
  namespace: ch41
spec:
  endpointSelector:
    matchLabels: {app: serveur}
  ingress:
  - fromEndpoints:
    - matchLabels: {app: client}
    toPorts:
    - ports:
      - {port: "8080", protocol: TCP}
      rules:
        http:
        - {method: GET, path: "/hostname"}
```

```bash
minikube stop
minikube start -p cilium
kubectl apply -f cilium-l7.yaml
kubectl apply -f cilium-politique.yaml
```

Avant, puis après la politique, `client` et `autre` interrogent le serveur par `curl` (le code HTTP entre crochets, puis le code de retour de `curl` quand il échoue) :

```sortie
  client GET /hostname     : serveur [200]
  client GET /echo?msg=x   : x [200]
  autre  GET /hostname     : serveur [200] code 0
ciliumnetworkpolicy.cilium.io/serveur-l7 created
  client GET /hostname     : serveur [200]
  client GET /echo?msg=x   : Access denied [403]
  autre  GET /hostname     :  [000] code 28
```

Trois verdicts différents, de trois niveaux différents. `autre` n'est pas autorisé du tout : ses paquets sont jetés, et `curl` expire (code 28). `client` est autorisé à se connecter, mais sa requête vers `/echo` est refusée par le proxy, qui répond lui-même par un `403 Access denied`. Et sa requête vers `/hostname` passe. `cilium-dbg monitor` montre les deux refus, chacun à son étage :

```bash
S=$(kubectl -n ch41 get pod serveur -o jsonpath='{.spec.nodeName}')
A=$(kubectl -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName=$S -o name)
kubectl -n kube-system exec $A -c cilium-agent -- cilium-dbg monitor --type drop --type l7
```

```sortie
xx drop (Policy denied) flow 0x212a8a66 to endpoint 1762, ifindex 5, file bpf_lxc.c:2412, , identity 21595->37925: 10.244.1.200:49484 -> 10.244.0.113:8080 tcp SYN
<- Request http from 478 ([k8s:app=client ...]) to 1762 ([k8s:app=serveur ...]), identity 56878->37925, verdict Denied GET http://serveur/echo?msg=x => 0
<- Response http to 478 ([k8s:app=client ...]) from 1762 ([k8s:app=serveur ...]), identity 37925->56878, verdict Forwarded GET http://serveur/echo?msg=x => 403
```

La première ligne est un paquet `SYN` jeté par un programme eBPF (`bpf_lxc.c`), parce que l'identité de la source, 21595 (`app=autre`), n'est pas dans la liste de celles que le point de terminaison accepte. Le filtrage ne regarde pas l'adresse : il compare des identités, comme on l'a annoncé au chapitre 39. Les deux lignes suivantes viennent du proxy : la requête `GET /echo` de l'identité 56878 (`app=client`) est refusée, et la réponse 403 renvoyée. Ce niveau de contrôle a un coût, puisque le trafic concerné passe par un proxy en espace utilisateur, et on le réserve aux flux qui le justifient ; la partie VIII reviendra sur ces questions avec un maillage de services.

## Exercices

:::exercice[Exercice 1 : qui peut parler à qui ?]

Écrivez en Python, avec la bibliothèque standard et `kubectl proxy --port=8011`, un programme qui lit les NetworkPolicies d'un namespace et affiche, sous forme de tableau, quels groupes de Pods (valeurs de l'étiquette `app.kubernetes.io/name`) peuvent ouvrir une connexion vers quels autres, dans ce namespace. N'oubliez pas qu'il faut l'accord des deux côtés. Faites-le tourner sur `colis`, et comparez avec la figure 41.1.

:::

<details>
<summary>Corrigé</summary>

Le cœur du programme est la fonction qui dit si un Pod accepte un pair dans un sens donné :

```python title="matrice.py (extrait)"
def autorise(pols, pod, pair, sens):
    """sens = 'ingress' (pair est la source) ou 'egress' (pair est la destination)."""
    concernees = [p for p in pols if choisit(p["spec"]["podSelector"], pod)
                  and (sens.capitalize() in p["spec"].get("policyTypes", ["Ingress"]))]
    if not concernees:
        return True                                 # aucune politique : tout est permis dans ce sens
    for p in concernees:
        for regle in p["spec"].get(sens) or []:
            pairs = regle.get("from" if sens == "ingress" else "to")
            if pairs is None:
                return True                         # règle sans from/to : toute source ou destination
            for x in pairs:
                if "podSelector" in x and "namespaceSelector" not in x and "ipBlock" not in x \
                        and choisit(x["podSelector"], pair):
                    return True
    return False
```

Une connexion de `s` vers `d` passe si `autorise(pols, s, d, "egress")` et `autorise(pols, d, s, "ingress")`. Les groupes sont lus dans les gabarits des Deployments, StatefulSets et CronJobs, pour compter aussi le worker quand KEDA l'a ramené à zéro.

```sortie
8 politiques dans colis ; ligne = source, colonne = destination
                    api api-canari   postgres      purge      redis        web     worker
api                   .          .        oui          .        oui          .          .
api-canari            .          .        oui          .        oui          .          .
postgres              .          .          .          .          .          .          .
purge                 .          .        oui          .          .          .          .
redis                 .          .          .          .          .          .          .
web                 oui          .          .          .          .          .          .
worker                .          .        oui          .        oui          .          .
```

C'est la figure 41.1, restreinte au namespace. Une case attire l'attention : `web` vers `api-canari` vaut `.`, alors que `api-canari` accepte le site en entrée. C'est la politique de sortie du site qui ne vise que `app.kubernetes.io/name=api`. Elle n'empêche rien d'utile, puisque la version canari ne reçoit son trafic que par la passerelle (chapitre 28), mais c'est typiquement le genre d'écart qu'un tel tableau révèle. Le programme ignore les ports et les sources des autres namespaces ; les outils d'analyse de politiques dignes de ce nom les prennent en compte.

</details>

:::exercice[Exercice 2 : trois Pods non prêts]

Sous la seule politique de refus par défaut, trois des six Pods de l'API sont passés non prêts, les trois autres sont restés prêts. Pourtant ils ont la même image, la même configuration, et les sondes du kubelet passent toujours. Pourquoi cette différence ?

:::

<details>
<summary>Corrigé</summary>

La sonde de disponibilité de l'API interroge `/pret`, qui vérifie que l'API peut joindre PostgreSQL et Redis (chapitre 22). Le kubelet joint bien le Pod : c'est le trafic du nœud, toujours permis. Mais la sortie de l'API vers PostgreSQL et Redis est refusée. Les trois Pods restés prêts sont les plus anciens : ils avaient ouvert leurs connexions à PostgreSQL et Redis **avant** la politique, et ces connexions établies continuent de passer (la règle `ct state established,related` de kindnet, et le même principe chez les autres greffons : une politique ne coupe pas les connexions existantes). Les trois autres ont été créés par le HPA peu avant ; ils n'avaient pas encore de connexion ouverte, ou l'ont perdue, et ne peuvent plus en ouvrir. Deux leçons : un test de politique juste après son application peut être trompeur, puisque les connexions existantes y échappent ; et les sondes qui vérifient les dépendances sont un excellent détecteur de politiques trop strictes.

</details>

:::exercice[Exercice 3 : sortir vers une API extérieure]

Colis doit un jour appeler un service HTTPS extérieur (une API de transporteur, par exemple). Écrivez une politique qui permet à l'API, et à elle seule, de sortir vers n'importe quelle adresse extérieure au cluster sur le port 443, sans lui ouvrir les autres Pods ni les réseaux privés. Vérifiez avec `https://example.com` et `http://example.com`.

:::

<details>
<summary>Corrigé</summary>

```yaml title="api-https-sortant.yaml"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-https-sortant
  namespace: colis
spec:
  podSelector:
    matchExpressions:
    - {key: app.kubernetes.io/name, operator: In, values: [api, api-canari]}
  policyTypes: [Egress]
  egress:
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16]   # ni les Pods, ni les Services, ni les réseaux privés
    ports:
    - {protocol: TCP, port: 443}
```

```sortie
# avant
https://example.com <urlopen error [Errno 101] Network unreachable>
http://example.com <urlopen error [Errno 101] Network unreachable>
networkpolicy.networking.k8s.io/api-https-sortant created
# après
https://example.com 200
http://example.com <urlopen error [Errno 101] Network unreachable>
```

Les politiques s'additionnent : celle-ci ajoute une sortie à celles que l'API avait déjà, sans rien retirer. Un `ipBlock` désigne des adresses, pas des Pods ; les exceptions empêchent de s'en servir pour joindre les Pods, les Services ou les machines du réseau interne. On ne peut pas, avec une NetworkPolicy, écrire « vers `api.transporteur.example` » : les politiques ne connaissent pas les noms, et l'adresse d'un service extérieur change. Cilium sait filtrer par nom de domaine (`toFQDNs`), en observant les réponses DNS ; avec les politiques standard, on se contente du port, ou de la plage d'adresses publiée par le fournisseur. Je retire cette politique ensuite : Colis n'en a pas besoin aujourd'hui.

</details>

## Nettoyer

Les politiques de Colis peuvent rester en place : elles laissent passer tout ce dont Colis a besoin, et c'est la configuration qu'on gardera pour la suite. Les Pods d'essai, en revanche, n'ont plus rien à faire là :

```bash
kubectl -n vitrine delete pod intrus
kubectl -n keda delete pod curieux --ignore-not-found
kubectl -n colis delete job purge-essai
```

Pour retirer toutes les politiques de Colis et revenir au réseau ouvert : `kubectl -n colis delete networkpolicy --all`. Sur le profil `cilium`, `kubectl delete namespace ch41`.

[^np]: Kubernetes, « Network Policies », sections *The two sorts of pod isolation*, *Behavior of to and from selectors* (la différence entre un et deux éléments) et *What you can't do with network policies* ; la même page précise que le trafic entre un nœud et ses Pods est toujours permis. [kubernetes.io/docs/concepts/services-networking/network-policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)

[^knp]: Kubernetes SIGs, « kube-network-policies », mise en œuvre des NetworkPolicies par NFQUEUE, utilisée par kindnet. [github.com/kubernetes-sigs/kube-network-policies](https://github.com/kubernetes-sigs/kube-network-policies)

[^l7]: Cilium, « Layer 7 Examples » et « Policy Language », pour les règles HTTP et `toFQDNs`. [docs.cilium.io/en/stable/security/policy/language](https://docs.cilium.io/en/stable/security/policy/language/)
