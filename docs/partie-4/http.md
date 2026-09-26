---
title: Exposer en HTTP
sidebar_label: 28. Exposer en HTTP
description: "Faire entrer le trafic HTTP et HTTPS dans le cluster par un point unique : l'Ingress et ses limites, la Gateway API (GatewayClass, Gateway, HTTPRoute), les rôles qu'elle sépare, le routage par chemin, par poids et par en-tête, les routes entre namespaces, puis TLS avec cert-manager, de l'autorité de certification au renouvellement."
partie: 4
chapitre: '28'
---

import gatewayRoles from '@site/src/figures/gateway-roles.svg';
import certManagerChaine from '@site/src/figures/cert-manager-chaine.svg';

Colis est joignable depuis le chapitre 24 à l'adresse `http://192.168.49.100/`, par un Service de type LoadBalancer. La copie du défi III a pris `192.168.49.101`. Une troisième application prendrait `.102`, et ainsi de suite : une adresse IP par application, alors que sur Internet on veut un seul point d'entrée, un nom de domaine par application, et HTTPS partout. Chez un fournisseur de cloud, chaque LoadBalancer est de plus un répartiteur de charge facturé à l'heure. Et un Service ne sait rien de HTTP : il transmet des connexions TCP, sans regarder quel site ou quel chemin le client demande, et ne sait pas déchiffrer TLS.

Il faut donc, devant les Services, un composant qui parle HTTP : un **proxy inverse**, qui reçoit toutes les requêtes sur une seule adresse, lit l'en-tête `Host` et le chemin, et choisit le Service à qui transmettre. C'est ce que fait nginx dans le Pod `web` de Colis pour `/api/`, mais pour une seule application. Kubernetes a deux API pour décrire ces règles de routage à l'échelle du cluster : l'**Ingress**, la première, figée depuis plusieurs années, et la **Gateway API**, qui lui succède. Ce chapitre les présente dans cet ordre, puis ajoute HTTPS avec cert-manager.

Les manifestes sont dans [l'archive http](pathname:///kits/http.tar.gz).

## L'Ingress, l'API historique

Un objet Ingress décrit des règles : tel nom d'hôte et tel chemin vont à tel Service. Il ne fait rien par lui-même. Il faut un **contrôleur d'Ingress**, un proxy qui lit ces objets et se configure en conséquence. Le plus répandu a longtemps été ingress-nginx, maintenu par le projet Kubernetes, que minikube installe comme addon :

```bash
minikube addons enable ingress
kubectl -n ingress-nginx get pods,svc
kubectl get ingressclass
```

```sortie
NAME                                           READY   STATUS      RESTARTS      AGE
pod/ingress-nginx-admission-create-ts6xx       0/1     Completed   0             13s
pod/ingress-nginx-admission-patch-mtstl        0/1     Completed   1 (12s ago)   13s
pod/ingress-nginx-controller-d7cd8c989-szzqn   1/1     Running     0             13s

NAME                                         TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)                      AGE
service/ingress-nginx-controller             NodePort    10.101.63.162   <none>        80:31645/TCP,443:32488/TCP   13s
service/ingress-nginx-controller-admission   ClusterIP   10.102.17.181   <none>        443/TCP                      13s
NAME              CONTROLLER             PARAMETERS   AGE
nginx (default)   k8s.io/ingress-nginx   <none>       13s
```

Le contrôleur est un Pod nginx, piloté par un programme qui surveille les Ingress. L'addon le fait écouter directement sur les ports 80 et 443 du nœud (`hostPort`), si bien qu'on le joint par l'adresse du nœud, `192.168.49.2`. L'IngressClass `nginx` dit quel contrôleur traite les Ingress qui la nomment. Un premier Ingress pour Colis :

```yaml title="ingress-colis.yaml"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: colis
  namespace: colis
spec:
  ingressClassName: nginx
  rules:
  - host: colis.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web
            port:
              number: 80
```

Le nom `colis.local` n'existe dans aucun DNS. Pour l'essayer, on envoie la requête à l'adresse du contrôleur en donnant nous-mêmes l'en-tête `Host`, c'est-à-dire exactement ce qu'un navigateur enverrait s'il avait trouvé cette adresse dans le DNS :

```bash
kubectl apply -f ingress-colis.yaml
curl -s -H 'Host: colis.local' http://192.168.49.2/ | grep -o '<title>.*</title>'
curl -s -H 'Host: colis.local' http://192.168.49.2/api/sante; echo
curl -s -o /dev/null -w 'autre hôte : %{http_code}\n' -H 'Host: autre.local' http://192.168.49.2/
```

```sortie
<title>Colis</title>
{"statut":"ok","version":"2.1.0","hote":"api-85cbf95c69-4m7ns"}
autre hôte : 404
```

Le site et l'API répondent (l'API par le relais du nginx de `web`, comme avant), et un autre nom d'hôte reçoit un 404 du contrôleur. Une seule adresse peut ainsi servir autant de sites qu'on veut.

### Les limites de l'Ingress

Faisons un pas de plus : envoyer `/api/...` directement à l'API, sans passer par le nginx de `web`, en retirant le préfixe `/api`, puisque l'API sert `/sante` et non `/api/sante`. L'API Ingress ne sait pas le dire : elle ne connaît que l'hôte, le chemin et le Service. Chaque contrôleur a donc ajouté ses propres **annotations**, qui n'ont de sens que pour lui :

```yaml title="ingress-api.yaml"
metadata:
  name: colis-api
  namespace: colis
  annotations:
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  ingressClassName: nginx
  rules:
  - host: colis.local
    http:
      paths:
      - path: /api(/|$)(.*)
        pathType: ImplementationSpecific
        backend:
          service:
            name: api
            port:
              number: 8000
```

```bash
kubectl apply -f ingress-api.yaml
curl -s -i -H 'Host: colis.local' http://192.168.49.2/api/sante | grep -E '^HTTP'
kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=1
```

```sortie
HTTP/1.1 200 OK
192.168.49.1 - - [26/Sep/2026:13:33:14 +0000] "GET /api/sante HTTP/1.1" 200 63 "-" "curl/8.18.0" 84 0.004 [colis-api-8000] [] 10.244.0.24:8000 63 0.004 200 e436274735c5f5af46e6533c61ad8e71
```

Cela marche (le journal montre que la requête est partie vers `colis-api-8000`), mais le manifeste n'est plus portable : une expression régulière et deux annotations propres à nginx, que Traefik, HAProxy ou le contrôleur d'un fournisseur de cloud écriraient autrement. Les besoins courants d'un proxy (réécrire un chemin, répartir le trafic par poids, router sur un en-tête, rediriger vers HTTPS, régler un délai) ont tous fini en annotations, des centaines, sous forme de chaînes de caractères que l'API server ne vérifie pas. Et l'Ingress mêle dans un même objet ce qui relève de l'équipe qui gère le point d'entrée (les certificats, les ports) et ce qui relève de l'équipe qui déploie l'application (les chemins).

Ces annotations ont aussi été un problème de sécurité. En mars 2025, la faille CVE-2025-1974, surnommée IngressNightmare, permettait à quiconque pouvait joindre le webhook d'admission d'ingress-nginx de lui faire exécuter du code, en glissant des directives nginx dans un Ingress, et de lire tous les Secrets du cluster : le contrôleur avait le droit de les lire tous[^ingressnightmare]. En novembre 2025, le projet Kubernetes a annoncé l'arrêt de la maintenance d'ingress-nginx pour mars 2026 et recommandé de passer à la Gateway API[^retrait]. L'API Ingress elle-même est figée : elle ne recevra plus de nouvelles fonctions[^ingress]. Vous rencontrerez longtemps des Ingress dans les clusters existants ; les nouveaux projets partent sur la Gateway API. Retirez l'addon :

```bash
kubectl -n colis delete ingress colis colis-api
minikube addons disable ingress
```

## La Gateway API

La Gateway API est un ensemble de ressources, développées par le groupe SIG Network de Kubernetes, qui décrivent le routage du trafic entrant de façon plus riche et plus structurée que l'Ingress[^gateway]. Elle n'est pas intégrée au cœur de Kubernetes : ce sont des CRD, des définitions de ressources supplémentaires (la partie VIII en fera), qu'on installe dans le cluster. Et comme pour l'Ingress, il faut une implémentation, un contrôleur qui lit ces objets et configure un proxy. Il en existe une trentaine : Envoy Gateway, NGINX Gateway Fabric, Traefik, Istio, Cilium, celles des fournisseurs de cloud. Ce cours utilise **Envoy Gateway 1.9.1**, du projet Envoy, un proxy très répandu, qui est aussi au cœur du maillage de services Istio.

Son vocabulaire tient en trois ressources, pensées pour trois rôles[^roles] :

- la **GatewayClass** décrit une implémentation disponible, comme une StorageClass décrit un type de stockage (chapitre 25). C'est l'affaire du fournisseur de l'infrastructure ;
- la **Gateway** décrit un point d'entrée : des écouteurs (*listeners*), chacun avec un port, un protocole, éventuellement un nom d'hôte et un certificat, et la liste des namespaces autorisés à s'y attacher. C'est l'affaire de l'équipe qui gère la plateforme ;
- les **routes**, `HTTPRoute` pour HTTP, décrivent où envoyer quelles requêtes. C'est l'affaire de chaque équipe applicative, dans son namespace.

Cette séparation règle deux défauts de l'Ingress d'un coup. L'équipe de Colis n'a plus besoin de toucher au point d'entrée partagé pour publier une route, et l'équipe plateforme décide, dans la Gateway, qui a le droit de s'y attacher.

### Installer les CRD et Envoy Gateway

Les CRD de la Gateway API se publient en deux canaux : `standard`, les ressources stables, et `experimental`, qui ajoute celles en cours de conception. Installons le canal standard, en version 1.6.2 :

```bash
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.2/standard-install.yaml
kubectl get crd -o custom-columns=NOM:.metadata.name,VERSION:.metadata.annotations.gateway\\.networking\\.k8s\\.io/bundle-version,CANAL:.metadata.annotations.gateway\\.networking\\.k8s\\.io/channel | grep -E 'NOM|gateway'
```

```sortie
NOM                                              VERSION   CANAL
backendtlspolicies.gateway.networking.k8s.io     v1.6.2    standard
gatewayclasses.gateway.networking.k8s.io         v1.6.2    standard
gateways.gateway.networking.k8s.io               v1.6.2    standard
grpcroutes.gateway.networking.k8s.io             v1.6.2    standard
httproutes.gateway.networking.k8s.io             v1.6.2    standard
listenersets.gateway.networking.k8s.io           v1.6.2    standard
referencegrants.gateway.networking.k8s.io        v1.6.2    standard
tcproutes.gateway.networking.k8s.io              v1.6.2    standard
tlsroutes.gateway.networking.k8s.io              v1.6.2    standard
udproutes.gateway.networking.k8s.io              v1.6.2    standard
```

Dix ressources : les trois déjà citées, des routes pour d'autres protocoles (gRPC, TCP, UDP, TLS), `ReferenceGrant` qu'on verra plus loin, et deux autres que ce chapitre n'utilise pas. Le chapitre 29 présentera Helm ; ici, on s'en sert simplement pour installer Envoy Gateway à partir de son paquet officiel.

:::panne[Helm refuse d'installer : conflit avec kubectl]

La commande qui semble évidente échoue :

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.9.1 -n envoy-gateway-system --create-namespace
```

```sortie
conflict occurred while applying object /httproutes.gateway.networking.k8s.io apiextensions.k8s.io/v1, Kind=CustomResourceDefinition: Apply failed with 3 conflicts: conflicts with "kubectl":
- .metadata.annotations.gateway.networking.k8s.io/bundle-version
- .metadata.annotations.gateway.networking.k8s.io/channel
- .spec.versions
```

Le paquet d'Envoy Gateway contient ses propres copies des CRD de la Gateway API, en version 1.6.1 et dans le canal expérimental. Helm 4 installe les CRD par *server-side apply* (chapitre 18), et l'API server refuse qu'il modifie des champs dont kubectl est le gestionnaire, puisque c'est kubectl qui a installé la version 1.6.2[^helm4]. C'est une protection : sans elle, Helm aurait remplacé en silence la version installée par l'équipe plateforme. L'installation échouée a tout de même laissé trois CRD expérimentales (`xbackends`, `xbackendtrafficpolicies`, `xmeshes`), à supprimer.

La solution documentée par Envoy Gateway est de n'installer, à part, que ses propres CRD, puis le contrôleur sans aucune CRD[^envoy] :

```bash
kubectl delete crd xbackends.gateway.networking.x-k8s.io xbackendtrafficpolicies.gateway.networking.x-k8s.io xmeshes.gateway.networking.x-k8s.io
helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm --version v1.9.1 \
  --set crds.envoyGateway.enabled=true | kubectl apply --server-side -f -
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.9.1 \
  -n envoy-gateway-system --create-namespace --skip-crds
```

:::

Une fois installé par la seconde méthode, le contrôleur est prêt en quelques secondes :

```bash
kubectl -n envoy-gateway-system get pods
```

```sortie
NAME                             READY   STATUS      RESTARTS   AGE
eg-gateway-helm-certgen-tgjpf    0/1     Completed   0          6s
envoy-gateway-5f8c9f5b6c-8x6qg   1/1     Running     0          2s
```

`envoy-gateway` est le contrôleur ; il ne traite aucune requête lui-même. Le Job `certgen` a créé les certificats qu'il utilise pour parler aux proxys.

### Une passerelle partagée

L'équipe plateforme déclare la classe et la passerelle :

```yaml title="passerelle.yaml"
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: v1
kind: Namespace
metadata:
  name: passerelle
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: principale
  namespace: passerelle
spec:
  gatewayClassName: envoy
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: Selector
        selector:
          matchLabels:
            passerelle: principale
```

La Gateway a un écouteur HTTP sur le port 80, et n'accepte que les routes des namespaces qui portent l'étiquette `passerelle: principale`. Les autres valeurs de `from` sont `Same`, la valeur par défaut (seulement le namespace de la Gateway), et `All`.

```bash
kubectl apply -f passerelle.yaml
kubectl -n passerelle wait --for=condition=Programmed gateway/principale
kubectl get gatewayclass
kubectl -n passerelle get gateway principale
kubectl -n envoy-gateway-system get pods,svc -l gateway.envoyproxy.io/owning-gateway-name=principale
```

```sortie
NAME    CONTROLLER                                      ACCEPTED   AGE
envoy   gateway.envoyproxy.io/gatewayclass-controller   True       12s
NAME         CLASS   ADDRESS          PROGRAMMED   AGE
principale   envoy   192.168.49.102   True         12s
NAME                                                        READY   STATUS    RESTARTS   AGE
pod/envoy-passerelle-principale-f06cdbcb-66d6bfcf7f-dcjxs   2/2     Running   0          11s

NAME                                           TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)        AGE
service/envoy-passerelle-principale-f06cdbcb   LoadBalancer   10.99.242.214   192.168.49.102   80:32330/TCP   11s
```

Pour cette Gateway, le contrôleur a créé un Deployment d'Envoy, le proxy qui traitera réellement les requêtes, et un Service LoadBalancer devant lui, à qui MetalLB a donné `192.168.49.102`. La Gateway est `Programmed` : le proxy a reçu sa configuration. Le contrôleur la lui envoie, et la lui renverra à chaque changement, par l'API de configuration dynamique d'Envoy, *xDS*, sans redémarrer le proxy.

### Une route pour Colis

L'équipe de Colis écrit sa route, dans son namespace :

```yaml title="colis/route.yaml"
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: colis
  namespace: colis
spec:
  parentRefs:
  - name: principale
    namespace: passerelle
  hostnames:
  - colis.local
  rules:
  - matches:                 # /api/... va directement à l'API, sans le préfixe
    - path:
        type: PathPrefix
        value: /api
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /
    backendRefs:
    - name: api
      port: 8000
  - matches:                 # tout le reste va au site
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: web
      port: 80
```

`parentRefs` dit à quelle Gateway s'attacher. La réécriture du préfixe, qui demandait une expression régulière et deux annotations avec l'Ingress, est ici un filtre `URLRewrite` de la spécification, que toutes les implémentations comprennent et que l'API server valide. Appliquons :

```bash
kubectl apply -f colis/route.yaml
kubectl -n colis get httproute colis -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: colis.local' http://192.168.49.102/
```

```sortie
Accepted=False NotAllowedByListeners: No listeners included by this parent ref allowed this attachment.
ResolvedRefs=True ResolvedRefs: Resolved all the Object references for the Route
404
```

La route est refusée : le namespace `colis` ne porte pas l'étiquette exigée par la Gateway. C'est l'équipe plateforme qui décide qui peut publier sur son point d'entrée. Remarquez aussi où se lit le diagnostic : dans le **statut** de la route, où chaque Gateway parente écrit ses conditions. C'est le premier endroit à regarder quand une route ne marche pas. Ajoutons l'étiquette :

```bash
kubectl label namespace colis passerelle=principale
kubectl -n colis get httproute colis -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
IP=192.168.49.102
curl -s -H 'Host: colis.local' http://$IP/ | grep -o '<title>.*</title>'
curl -s -i -H 'Host: colis.local' http://$IP/api/sante | grep -iE '^HTTP|^server|statut'
curl -s -o /dev/null -w 'autre hôte : %{http_code}\n' -H 'Host: autre.local' http://$IP/
```

```sortie
namespace/colis labeled
Accepted=True Accepted
ResolvedRefs=True ResolvedRefs
<title>Colis</title>
HTTP/1.1 200 OK
server: uvicorn
{"statut":"ok","version":"2.1.0","hote":"api-85cbf95c69-4m7ns"}
autre hôte : 404
```

La route est acceptée. `/api/sante` a été servie par `uvicorn`, le serveur de l'API, directement, sans le relais du nginx de `web`, et avec le préfixe retiré.

<Figure svg={gatewayRoles} num="28.1" alt="Trois niveaux d'objets, pour trois rôles. Le fournisseur : la GatewayClass envoy, dont le contrôleur est gateway.envoyproxy.io. L'équipe plateforme : la Gateway principale, dans le namespace passerelle, avec les écouteurs http:80 et https:443, qui accepte les routes des namespaces étiquetés passerelle=principale. Les équipes applicatives : la HTTPRoute colis du namespace colis, pour colis.local, qui envoie /api au Service api (poids 90) et au Service api-canari (poids 10), et / au Service web ; la HTTPRoute vitrine du namespace vitrine, pour vitrine.local, qui vise le Service web de Colis grâce à un ReferenceGrant. À droite, le chemin des requêtes : le client envoie Host: colis.local à 192.168.49.102, l'adresse du Service LoadBalancer donnée par MetalLB, qui mène au Pod Envoy ; le contrôleur envoy-gateway, qui lit les objets de l'API, a créé ce Pod et le configure par xDS ; Envoy transmet aux Pods.">
La Gateway API sur le cluster du cours : qui écrit quoi, et par où passent les requêtes. Le contrôleur ne voit jamais passer une requête ; il traduit les objets en configuration pour Envoy.
</Figure>

### Répartir par poids, router par en-tête

Ce que l'Ingress ne savait faire que par annotations, la Gateway API le dit dans la spécification. Déployons une seconde version de l'API, `api-canari` : la même image, mais qui se présente avec la version `2.1.0-canari`. Puis modifions la règle `/api` pour lui envoyer 10 % des requêtes, et toutes celles qui portent l'en-tête `X-Canari: oui` :

```yaml title="colis/route-canari.yaml (extrait)"
  rules:
  - matches:                 # les testeurs choisissent le canari par un en-tête
    - path:
        type: PathPrefix
        value: /api
      headers:
      - name: X-Canari
        value: oui
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /
    backendRefs:
    - name: api-canari
      port: 8000
  - matches:
    - path:
        type: PathPrefix
        value: /api
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /
    backendRefs:
    - name: api
      port: 8000
      weight: 90
    - name: api-canari
      port: 8000
      weight: 10
```

```bash
kubectl apply -f colis/api-canari.yaml -f colis/route-canari.yaml
for i in $(seq 1 200); do curl -s -H 'Host: colis.local' http://192.168.49.102/api/sante | jq -r .version; done | sort | uniq -c
for i in 1 2 3; do curl -s -H 'Host: colis.local' -H 'X-Canari: oui' http://192.168.49.102/api/sante | jq -r .version; done | uniq -c
```

```sortie
    181 2.1.0
     19 2.1.0-canari
      3 2.1.0-canari
```

Sur 200 requêtes, 19 sont allées au canari, près des 10 % demandés : le tirage est aléatoire, requête par requête. Avec l'en-tête, les trois sont allées au canari. Quand une requête correspond à plusieurs règles, la plus précise l'emporte : ici, celle qui exige un en-tête en plus du chemin[^httproute]. C'est la base d'un déploiement progressif : on augmente le poids du canari par étapes, en surveillant ses erreurs, ce que le chapitre 58 automatisera avec Argo Rollouts.

### Une route vers le Service d'un autre namespace

Une autre équipe, dans le namespace `vitrine`, veut publier le site de Colis sous un second nom, `vitrine.local`. Sa route vise le Service `web` du namespace `colis` :

```yaml title="vitrine.yaml (extrait)"
  rules:
  - backendRefs:
    - name: web
      namespace: colis
      port: 80
```

```bash
kubectl apply -f vitrine.yaml
kubectl -n vitrine get httproute vitrine -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: vitrine.local' http://192.168.49.102/
```

```sortie
Accepted=True Accepted: Route is accepted
ResolvedRefs=False RefNotPermitted: Failed to process route rule 0 backendRef 0: Backend ref to Service colis/web not permitted by any ReferenceGrant.
500
```

La route est acceptée par la Gateway, mais sa référence au Service est refusée, et la passerelle répond 500. Si n'importe quelle route pouvait viser n'importe quel Service, une équipe pourrait publier sur Internet un service interne d'une autre équipe. La Gateway API exige donc que le propriétaire de la cible donne son accord, par un **ReferenceGrant** placé dans **son** namespace[^referencegrant] :

```yaml title="colis/autorisation-vitrine.yaml"
apiVersion: gateway.networking.k8s.io/v1
kind: ReferenceGrant
metadata:
  name: vitrine
  namespace: colis
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: vitrine
  to:
  - group: ""
    kind: Service
    name: web
```

```bash
kubectl apply -f colis/autorisation-vitrine.yaml
kubectl -n vitrine get httproute vitrine -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
curl -s -H 'Host: vitrine.local' http://192.168.49.102/ | grep -o '<title>.*</title>'
```

```sortie
Accepted=True Accepted
ResolvedRefs=True ResolvedRefs
<title>Colis</title>
```

L'équipe de Colis a autorisé précisément les HTTPRoute du namespace `vitrine` à viser précisément le Service `web`, et rien d'autre. Le même mécanisme sert quand une Gateway utilise un certificat rangé dans un autre namespace.

:::panne[Une route qui ne marche pas]

Commencez toujours par le statut de la route, condition par condition, et lisez la raison :

- `Accepted=False` avec `NotAllowedByListeners` : la Gateway n'accepte pas les routes de ce namespace (voyez `allowedRoutes`), ou le port, le protocole ou le nom d'hôte ne correspondent à aucun écouteur ;
- `ResolvedRefs=False` avec `RefNotPermitted` : il manque un ReferenceGrant ;
- `ResolvedRefs=False` avec `PortNotFound` ou `BackendNotFound` : le Service ou son port n'existent pas, par exemple `TCP Port 8080 not found on Service colis/api` ;
- aucune condition du tout : `parentRefs` nomme une Gateway qui n'existe pas, ou que personne ne gère (vérifiez la GatewayClass, colonne `ACCEPTED`).

Un 404 de la passerelle veut dire qu'aucune route ne correspond à l'hôte ou au chemin ; un 500, qu'une route correspond mais que sa cible est inutilisable.

:::

## HTTPS avec cert-manager

Il reste à chiffrer. Un écouteur HTTPS a besoin d'un certificat pour le nom `colis.local`, signé par une autorité de certification que les clients connaissent, et renouvelé avant son expiration. Faire tout cela à la main, pour chaque nom, tous les trois mois, est la meilleure façon de se retrouver un matin avec un site en panne pour cause de certificat expiré, un incident qui a touché à peu près toutes les grandes entreprises au moins une fois. **cert-manager** automatise le cycle de vie des certificats dans Kubernetes : il les demande à une autorité, les range dans des Secrets, et les renouvelle[^certmanager].

Sur Internet, l'autorité serait le plus souvent Let's Encrypt, gratuite, qui vérifie par le protocole ACME que vous contrôlez bien le nom de domaine, en venant lire une réponse sur votre site. Un cluster minikube n'est pas joignable depuis Internet, et `colis.local` n'est pas un domaine public : nous allons donc créer notre propre autorité de certification, gérée elle aussi par cert-manager. Le fonctionnement pour le reste est le même.

```yaml title="cert-manager-valeurs.yaml"
crds:
  enabled: true
config:
  apiVersion: controller.config.cert-manager.io/v1alpha1
  kind: ControllerConfiguration
  enableGatewayAPI: true
```

```bash
helm install cert-manager oci://quay.io/jetstack/charts/cert-manager --version v1.21.2 \
  -n cert-manager --create-namespace -f cert-manager-valeurs.yaml
kubectl -n cert-manager get pods
kubectl -n cert-manager logs deploy/cert-manager | grep -m1 'certificate-shim'
```

```sortie
NAME                                       READY   STATUS    RESTARTS   AGE
cert-manager-7cbdfd77b7-nbhrb              1/1     Running   0          81s
cert-manager-cainjector-8677bbdb7f-5sn5x   1/1     Running   0          81s
cert-manager-webhook-55b94f85b4-xd8fq      1/1     Running   0          81s
I0926 13:34:26.939875       1 options.go:296] "enabling the sig-network Gateway API certificate-shim and HTTP-01 solver" logger="cert-manager"
```

Trois composants : le contrôleur, un webhook qui valide les objets de cert-manager, et `cainjector`, qui injecte des certificats d'autorité dans d'autres ressources. L'option `enableGatewayAPI` active le *certificate-shim* : cert-manager surveille les Gateway et crée lui-même les certificats de leurs écouteurs HTTPS.

### Une autorité de certification locale

cert-manager ne signe rien lui-même : il s'adresse à un **émetteur** (*Issuer*, limité à un namespace, ou *ClusterIssuer*, pour tout le cluster). Notre autorité se construit en deux étages : un émetteur `autosigne` fabrique un certificat racine, qui se signe lui-même ; puis un émetteur de type `ca` signe les certificats des sites avec la clé de cette racine.

```yaml title="autorite.yaml"
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: autosigne
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: colis-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: Autorite de certification du cours
  secretName: colis-ca
  duration: 87600h          # dix ans
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: autosigne
    kind: ClusterIssuer
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: colis-ca
spec:
  ca:
    secretName: colis-ca    # lu dans le namespace de cert-manager
```

```bash
kubectl apply -f autorite.yaml
kubectl get clusterissuer
```

```sortie
NAME        READY   AGE
autosigne   True    0s
colis-ca    True    0s
```

### L'écouteur HTTPS

La Gateway reçoit un second écouteur, sur le port 443, pour le nom `colis.local`, avec un certificat rangé dans le Secret `colis-tls`, et une annotation qui dit à cert-manager quel émetteur utiliser :

```yaml title="passerelle-tls.yaml (extrait)"
metadata:
  name: principale
  namespace: passerelle
  annotations:
    cert-manager.io/cluster-issuer: colis-ca
spec:
  gatewayClassName: envoy
  listeners:
  # ... l'écouteur http, inchangé
  - name: https
    protocol: HTTPS
    port: 443
    hostname: colis.local
    tls:
      mode: Terminate
      certificateRefs:
      - name: colis-tls       # créé par cert-manager, dans le namespace de la passerelle
    allowedRoutes:
      namespaces:
        from: Selector
        selector:
          matchLabels:
            passerelle: principale
```

`mode: Terminate` veut dire qu'Envoy déchiffre : il parle HTTPS au client et HTTP aux Services. La route de Colis s'attache désormais au seul écouteur HTTPS, par `sectionName: https`, et une seconde route, sur l'écouteur HTTP, redirige tout vers HTTPS :

```yaml title="colis/route-tls.yaml (extrait)"
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: colis-redirection
  namespace: colis
spec:
  parentRefs:
  - name: principale
    namespace: passerelle
    sectionName: http
  hostnames:
  - colis.local
  rules:
  - filters:
    - type: RequestRedirect
      requestRedirect:
        scheme: https
        statusCode: 301
```

```bash
kubectl apply -f passerelle-tls.yaml -f colis/route-tls.yaml
kubectl -n passerelle wait --for=condition=Ready certificate/colis-tls
kubectl -n passerelle get certificate,certificaterequest
kubectl -n passerelle get certificate colis-tls -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}{.status.notBefore} {.status.notAfter} {.status.renewalTime}{"\n"}'
```

```sortie
certificate.cert-manager.io/colis-tls condition met
NAME                                    READY   SECRET      AGE
certificate.cert-manager.io/colis-tls   True    colis-tls   1s

NAME                                             APPROVED   DENIED   READY   ISSUER     REQUESTER                                         AGE
certificaterequest.cert-manager.io/colis-tls-1   True                True    colis-ca   system:serviceaccount:cert-manager:cert-manager   1s
Gateway/principale
2026-09-26T13:35:49Z 2026-12-25T13:35:49Z 2026-11-25T13:35:49Z
```

Personne n'a écrit d'objet `Certificate` pour le site : cert-manager l'a créé à partir de l'écouteur de la Gateway, qui en est le propriétaire. Il a produit une clé privée, fait une demande de signature (`CertificateRequest`), que l'émetteur `colis-ca` a signée, et rangé le tout dans le Secret `colis-tls`, en une seconde. Le certificat vaut 90 jours, et sera renouvelé le 25 novembre, aux deux tiers de sa durée, la valeur par défaut de cert-manager. La figure 28.2 résume la chaîne.

<Figure svg={certManagerChaine} num="28.2" alt="Cinq étapes. 1, la Gateway principale, qui porte l'annotation cert-manager.io/cluster-issuer, fait créer le Certificate colis-tls, pour colis.local, valable 90 jours. 2, le Certificate crée la CertificateRequest colis-tls-1. 3, elle est transmise au ClusterIssuer colis-ca, qui signe avec la clé du Secret colis-ca ; cette clé vient du Certificate colis-ca, la racine, isCA, valable 10 ans, émise par l'émetteur autosigne. 4, l'émetteur écrit le Secret colis-tls, de type kubernetes.io/tls, dans le namespace passerelle. 5, Envoy charge ce Secret et présente le certificat aux clients. Le renouvellement a lieu aux deux tiers de la durée, ici le 25 novembre : le Secret est réécrit sur place, et Envoy prend le nouveau certificat sans redémarrer ni perdre de requête.">
Du Gateway au certificat servi : cert-manager fabrique les objets intermédiaires et range le résultat dans un Secret, que la passerelle charge. Noms, dates et délais relevés sur le cluster du cours.
</Figure>

Essayons. Les clients doivent faire confiance à notre autorité : on extrait son certificat, et on le donne à `curl`. `--resolve` associe le nom `colis.local` à l'adresse de la passerelle, ce qui permet à `curl` d'envoyer le bon nom au serveur pendant la négociation TLS (l'extension SNI), là où `-H 'Host: ...'` ne suffit plus :

```bash
kubectl -n cert-manager get secret colis-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
IP=192.168.49.102
curl -s -i -H 'Host: colis.local' http://$IP/api/sante | head -2
curl -s --cacert ca.crt --resolve colis.local:443:$IP https://colis.local/api/sante; echo
curl -sS --resolve colis.local:443:$IP https://colis.local/ 2>&1 | head -1
echo | openssl s_client -connect $IP:443 -servername colis.local 2>/dev/null | openssl x509 -noout -issuer -dates -ext subjectAltName
```

```sortie
HTTP/1.1 301 Moved Permanently
location: https://colis.local/api/sante
{"statut":"ok","version":"2.1.0","hote":"api-85cbf95c69-99p9p"}
curl: (60) SSL certificate OpenSSL verify result: unable to get local issuer certificate (20)
issuer=CN=Autorite de certification du cours
notBefore=Sep 26 13:35:49 2026 GMT
notAfter=Dec 25 13:35:49 2026 GMT
X509v3 Subject Alternative Name: critical
    DNS:colis.local
```

En HTTP, la passerelle redirige vers HTTPS. En HTTPS, avec notre autorité, l'API répond. Sans elle, `curl` refuse la connexion : il ne connaît pas l'émetteur, exactement ce qu'afficherait un navigateur. Pour que votre navigateur accepte `https://colis.local/`, il faudrait ajouter `ca.crt` à ses autorités de confiance et `192.168.49.102 colis.local` à votre fichier `/etc/hosts` ; c'est faisable, mais réservez-le à une autorité que vous contrôlez, comme celle-ci.

### Le renouvellement

Le jour du renouvellement, cert-manager refait une demande de signature et réécrit le Secret sur place. Envoy Gateway surveille le Secret et envoie le nouveau certificat au proxy, par xDS. Provoquons un renouvellement tout de suite, comme le fait la commande `cmctl renew` de cert-manager, en ajoutant la condition `Issuing` au statut du certificat, pendant que des requêtes HTTPS arrivent dix fois par seconde. Le script du chapitre, `outils/rejeu-ch28.sh` dans le dépôt, lance ces requêtes en parallèle et relève le numéro de série du certificat servi avant et après :

```bash
kubectl -n passerelle patch certificate colis-tls --subresource=status --type=merge -p '{"status":{"conditions":[
  {"type":"Ready","status":"True","reason":"Ready","message":"Certificate is up to date and has not expired","lastTransitionTime":"2026-09-26T13:36:30Z"},
  {"type":"Issuing","status":"True","reason":"ManuallyTriggered","message":"Certificate re-issuance manually triggered","lastTransitionTime":"2026-09-26T13:36:30Z"}]}}'
```

```sortie
avant : serial=371B8D7F241D43BB6FDE6D3DA78E3AA5968EB88A
certificate.cert-manager.io/colis-tls patched
pendant le renouvellement : 145 réussies, 0 échouées
après : serial=76577C754017A4038C78E9427C8A6FBAF9080F58
révision 2
```

Le numéro de série a changé : c'est un nouveau certificat, servi sans aucune requête perdue, et sans que le Pod d'Envoy redémarre. Supprimer le Secret, en revanche, n'est pas une bonne façon de forcer un renouvellement. L'essai le montre : pendant 2,6 secondes, le temps que cert-manager recrée le Secret, Envoy n'avait plus de certificat à présenter, et toutes les connexions HTTPS échouaient.

## Exercices

:::exercice[Exercice 1 : un en-tête de sécurité]

Maintenant que Colis est servi en HTTPS, on veut que les navigateurs refusent de revenir en HTTP pendant un an. C'est le rôle de l'en-tête de réponse `Strict-Transport-Security` (HSTS). Ajoutez-le aux réponses du site, sans toucher au code de Colis ni au nginx de `web`.

:::

<details>
<summary>Corrigé</summary>

Un filtre `ResponseHeaderModifier` dans la règle `/` de la route HTTPS :

```yaml
  - matches:                 # tout le reste va au site
    - path:
        type: PathPrefix
        value: /
    filters:
    - type: ResponseHeaderModifier
      responseHeaderModifier:
        add:
        - name: Strict-Transport-Security
          value: max-age=31536000
    backendRefs:
    - name: web
      port: 80
```

```bash
curl -s -I --cacert ca.crt --resolve colis.local:443:192.168.49.102 https://colis.local/ | grep -iE '^HTTP|strict'
```

```sortie
HTTP/2 200 
strict-transport-security: max-age=31536000
```

L'en-tête est ajouté par la passerelle. Notez au passage `HTTP/2` : Envoy a négocié HTTP/2 avec `curl` pendant la négociation TLS, alors que le nginx de `web` ne parle que HTTP/1.1 ; la passerelle fait la traduction. On mettrait de même un filtre `RequestHeaderModifier` pour ajouter un en-tête aux requêtes transmises. HSTS ne s'envoie que sur HTTPS, et avec prudence : une fois qu'un navigateur l'a reçu, il refusera le site en HTTP pendant toute la durée indiquée.

</details>

:::exercice[Exercice 2 : diagnostiquer une route]

Une collègue a publié une route pour `port.local` qui renvoie `/api` à l'API, et obtient une erreur 500. Voici le statut de sa route. Quelle est la cause, et comment la corriger ?

```sortie
Accepted=True Accepted: Route is accepted
ResolvedRefs=False PortNotFound: Failed to process route rule 0 backendRef 0: TCP Port 8080 not found on Service colis/api.
```

:::

<details>
<summary>Corrigé</summary>

La route est acceptée par la Gateway, donc le namespace, l'écouteur et le nom d'hôte conviennent. C'est la cible qui pose problème : la route vise le port 8080 du Service `api`, qui n'expose que le port 8000. `backendRefs.port` est le port du **Service**, pas celui du conteneur (même s'ils coïncident souvent). La correction : `port: 8000`. La passerelle répond 500, et non 404, parce qu'une route correspond bien à la requête ; c'est sa cible qui est inutilisable. `kubectl -n colis get service api -o jsonpath='{.spec.ports}'` donne les ports disponibles.

</details>

:::exercice[Exercice 3 : Ingress ou Gateway API ?]

Votre équipe hérite d'un cluster qui a trente Ingress pour ingress-nginx, dont la moitié utilisent des annotations `nginx.ingress.kubernetes.io/...`. Quels risques prend-elle en restant ainsi ? Comment organiser la migration vers la Gateway API ?

:::

<details>
<summary>Corrigé</summary>

Le premier risque est la sécurité : ingress-nginx ne reçoit plus de correctifs depuis mars 2026, et le contrôleur, qui voit tout le trafic entrant et, dans sa configuration habituelle, peut lire tous les Secrets du cluster, est une cible de choix, comme l'a montré IngressNightmare. Le deuxième est la compatibilité : les versions futures de Kubernetes ne seront plus testées avec lui. Le troisième tient aux annotations, qui n'existent que pour ce contrôleur : impossible de changer de contrôleur sans les réécrire.

La migration peut se faire sans coupure, parce que les deux mondes cohabitent : on installe une implémentation de la Gateway API à côté d'ingress-nginx, avec sa propre adresse ; on traduit les Ingress en HTTPRoute, application par application (le projet Gateway API fournit l'outil `ingress2gateway`, qui traduit les cas courants et signale les annotations qu'il ne sait pas traduire) ; on teste chaque route sur la nouvelle adresse, avec `curl --resolve` comme dans ce chapitre ; puis on bascule le DNS, nom par nom, en gardant l'ancien contrôleur le temps de revenir en arrière. Les annotations sans équivalent dans la spécification se traduisent en filtres standard quand c'est possible, sinon en ressources propres à l'implémentation choisie (pour Envoy Gateway, des `BackendTrafficPolicy` ou `SecurityPolicy`), qu'il faut alors documenter comme telles.

</details>

## Accéder à Colis, et nettoyer

La passerelle reste en place : les chapitres suivants s'en servent. Colis est servi en HTTPS :

```bash
curl --cacert ca.crt --resolve colis.local:443:192.168.49.102 https://colis.local/
```

Pour votre navigateur, ajoutez `192.168.49.102 colis.local` à `/etc/hosts` et importez `ca.crt` dans ses autorités (ou acceptez l'avertissement). Après un `minikube start`, réappliquez la plage de MetalLB, comme d'habitude.

Pour retirer ce que le chapitre a ajouté, dans l'ordre inverse :

```bash
kubectl delete namespace vitrine
kubectl -n colis delete -f colis/route-tls.yaml -f colis/api-canari.yaml -f colis/autorisation-vitrine.yaml
kubectl label namespace colis passerelle-
kubectl delete namespace passerelle
kubectl delete gatewayclass envoy
kubectl delete clusterissuer autosigne colis-ca
helm uninstall cert-manager -n cert-manager
helm uninstall eg -n envoy-gateway-system
kubectl delete namespace cert-manager envoy-gateway-system
```

Les CRD restent installées après `helm uninstall` : c'est voulu, les supprimer supprimerait aussi tous les objets de ces types dans le cluster. Pour les retirer quand même : `kubectl get crd -o name | grep -E 'gateway.networking.k8s.io|gateway.envoyproxy.io|cert-manager.io' | xargs kubectl delete`. Envoy Gateway et cert-manager consomment ensemble environ 170 Mio (51 Mio pour le contrôleur d'Envoy Gateway, 44 Mio pour le proxy, 73 Mio pour cert-manager).

[^ingress]: Kubernetes, « Ingress », encadré en tête de page : l'API Ingress est figée, et le projet recommande la Gateway API. [kubernetes.io/docs/concepts/services-networking/ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/)

[^ingressnightmare]: Kubernetes, « Ingress-nginx CVE-2025-1974: What You Need to Know », blog, 24 mars 2025. [kubernetes.io/blog/2025/03/24/ingress-nginx-cve-2025-1974](https://kubernetes.io/blog/2025/03/24/ingress-nginx-cve-2025-1974/)

[^retrait]: Kubernetes, « Ingress NGINX Retirement: What You Need to Know », blog, 11 novembre 2025. [kubernetes.io/blog/2025/11/11/ingress-nginx-retirement](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/)

[^gateway]: Gateway API, documentation officielle, et liste des implémentations. [gateway-api.sigs.k8s.io](https://gateway-api.sigs.k8s.io/)

[^roles]: Gateway API, « Roles and Personas ». [gateway-api.sigs.k8s.io/concepts/roles-and-personas](https://gateway-api.sigs.k8s.io/concepts/roles-and-personas/)

[^helm4]: Helm, notes de version de Helm 4.0.0, sur l'utilisation du *server-side apply*. [github.com/helm/helm/releases/tag/v4.0.0](https://github.com/helm/helm/releases/tag/v4.0.0)

[^envoy]: Envoy Gateway, « Install with Helm », section sur l'installation séparée des CRD. [gateway.envoyproxy.io/docs/install/install-helm](https://gateway.envoyproxy.io/docs/install/install-helm/)

[^httproute]: Gateway API, « HTTPRoute », sections *Matches* (ordre de priorité entre règles) et *BackendRefs* (poids). [gateway-api.sigs.k8s.io/api-types/httproute](https://gateway-api.sigs.k8s.io/api-types/httproute/)

[^referencegrant]: Gateway API, « ReferenceGrant ». [gateway-api.sigs.k8s.io/api-types/referencegrant](https://gateway-api.sigs.k8s.io/api-types/referencegrant/)

[^certmanager]: cert-manager, « Annotated Gateway resource », « CA » et « Certificate resource », section *Renewal* (renouvellement aux deux tiers de la durée par défaut). [cert-manager.io/docs/usage/gateway](https://cert-manager.io/docs/usage/gateway/)
