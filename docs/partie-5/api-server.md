---
title: L'API server
sidebar_label: 34. L'API server
description: "Ce que fait réellement kubectl : des requêtes HTTP vers l'API server. Groupes, versions et ressources, les verbes, curl avec trois identités, le watch, la pagination, le trajet d'une requête de l'authentification à etcd, les sous-ressources, l'agrégation et le server-side apply."
partie: 5
chapitre: '34'
---

import apiUrl from '@site/src/figures/api-url.svg';
import apiserverChaine from '@site/src/figures/apiserver-chaine.svg';

Ajoutez `-v=6` à la plus banale des commandes kubectl, et regardez ce qui sort :

```bash
kubectl -n ch34 get pods -v=6 2>&1 | grep -o 'verb=.*'
```

```sortie
verb="GET" url="https://192.168.49.2:8443/api?timeout=32s" status="200 OK" milliseconds=8
verb="GET" url="https://192.168.49.2:8443/apis?timeout=32s" status="200 OK" milliseconds=1
verb="GET" url="https://192.168.49.2:8443/api/v1/namespaces/ch34/pods?limit=500" status="200 OK" milliseconds=3
```

Trois requêtes HTTPS, et c'est tout. kubectl n'a aucun pouvoir sur le cluster : il ne lance pas de conteneurs, il ne lit aucun fichier sur le nœud, il ne connaît même pas la liste des sortes d'objets qui existent avant de l'avoir demandée (c'est l'objet des deux premières requêtes). Il fabrique des requêtes HTTP, les envoie à un seul programme, l'**API server** (`kube-apiserver`), et met en forme les réponses. Le scheduler, les contrôleurs, le kubelet de chaque nœud, KEDA, cert-manager, Helm : tous font exactement la même chose. Aucun composant de Kubernetes ne parle à un autre directement ; chacun lit et écrit des objets dans l'API, et réagit aux changements des objets qui l'intéressent.

C'est un choix d'architecture délibéré, et ses auteurs l'ont expliqué. Dans Omega, le successeur expérimental de Borg chez Google, les composants de confiance lisaient et écrivaient directement dans le magasin partagé. Kubernetes a fait l'inverse : l'état n'est accessible que par une API REST propre au domaine, qui se charge des versions, de la validation et des règles d'accès[^borg]. Un seul programme parle à etcd, et c'est l'API server. Tout le reste passe par lui.

Ce chapitre ouvre cette porte d'entrée. On va parler à l'API sans kubectl, avec `curl`, pour voir ce qui se cache derrière les commandes utilisées depuis la partie III. C'est aussi la meilleure préparation aux chapitres suivants : etcd, les contrôleurs et le scheduler ne se comprennent bien que si l'on sait ce qu'est un watch ou une `resourceVersion`.

Tout se fait sur le cluster principal, dans un namespace à part. Les fichiers sont dans [l'archive api](pathname:///kits/api.tar.gz).

```bash
kubectl create namespace ch34
kubectl config set-context --current --namespace=ch34
```

## Des adresses, pas des commandes

Dans la troisième requête ci-dessus, l'URL dit tout ce que kubectl voulait : la liste des Pods (`pods`) du namespace `ch34`, dans la version `v1` de l'API. Chaque objet du cluster a ainsi une adresse, et chaque sorte d'objet un chemin. La figure 34.1 décompose deux de ces adresses.

<Figure svg={apiUrl} num="34.1" alt="Deux URL de l'API décomposées. La première, https://192.168.49.2:8443/apis/apps/v1/namespaces/ch34/deployments/vitrine/scale : l'adresse de l'API server, le préfixe /apis des groupes nommés, le groupe apps, la version v1, le namespace ch34 (absent pour un objet de tout le cluster), la ressource deployments (au pluriel, en minuscules), le nom vitrine (absent pour une liste) et la sous-ressource scale. La seconde, https://192.168.49.2:8443/api/v1/namespaces/ch34/configmaps?watch=true&fieldSelector=..., pour le groupe noyau, qui s'écrit /api sans nom de groupe, suivie de paramètres comme watch, limit, continue, labelSelector, fieldSelector ou dryRun.">
L'anatomie d'une URL de l'API. Le groupe noyau, celui des Pods, des Services et des ConfigMaps, n'a pas de nom : il vit sous `/api/v1`, les autres sous `/apis/<groupe>/<version>`.
</Figure>

Quatre mots reviennent sans cesse, et il vaut la peine de les distinguer une fois pour toutes. Un **groupe** rassemble des sortes d'objets apparentées : `apps` pour les Deployments, les StatefulSets et les DaemonSets, `batch` pour les Jobs, `networking.k8s.io` pour les NetworkPolicies. Une **version** (`v1`, `v2`, `v1beta1`) est une forme donnée de l'API d'un groupe. Une **ressource** est le nom, au pluriel et en minuscules, qui apparaît dans l'URL : `deployments`. Le **kind** est le nom du type de l'objet, avec une majuscule, celui que vous écrivez dans vos manifestes : `Deployment`. Le champ `apiVersion: apps/v1` d'un manifeste, c'est donc le groupe et la version, collés par une barre oblique ; pour le groupe noyau, il ne reste que la version, d'où `apiVersion: v1`.

`kubectl api-resources` récite ce que l'API server sait servir. C'est le contenu des deux premières requêtes de tout à l'heure : `/api` et `/apis` renvoient d'un bloc la liste des groupes, de leurs versions et de leurs ressources, ce qu'on appelle la **découverte** :

```bash
kubectl api-resources | wc -l
kubectl api-resources | head -4
kubectl api-resources | grep -E '^(pods|deployments|events|leases|httproutes|scaledobjects) '
```

```sortie
109
NAME                                SHORTNAMES               APIVERSION                        NAMESPACED   KIND
bindings                                                     v1                                true         Binding
componentstatuses                   cs                       v1                                false        ComponentStatus
configmaps                          cm                       v1                                true         ConfigMap
events                              ev                       v1                                true         Event
pods                                po                       v1                                true         Pod
deployments                         deploy                   apps/v1                           true         Deployment
leases                                                       coordination.k8s.io/v1            true         Lease
events                              ev                       events.k8s.io/v1                  true         Event
httproutes                                                   gateway.networking.k8s.io/v1      true         HTTPRoute
scaledobjects                       so                       keda.sh/v1alpha1                  true         ScaledObject
pods                                                         metrics.k8s.io/v1beta1            true         PodMetrics
```

108 ressources sur ce cluster (la première ligne est l'en-tête). Votre nombre sera différent : il dépend de ce que vous avez installé depuis la partie IV. Deux curiosités dans cet extrait. `events` apparaît deux fois, dans le groupe noyau et dans `events.k8s.io` : c'est le même objet, servi sous deux formes, l'ancienne gardée pour ne casser personne. Et `pods` existe aussi dans `metrics.k8s.io`, où il désigne tout autre chose : la consommation mesurée des Pods, que `kubectl top` affiche. Le nom seul ne suffit donc pas ; c'est le couple groupe et ressource qui identifie une sorte d'objet, et quand il y a ambiguïté, on peut l'écrire en entier, comme `kubectl get pods.metrics.k8s.io`.

La colonne `NAMESPACED` sépare les objets qui vivent dans un namespace (Pods, Services, Deployments) de ceux qui appartiennent à tout le cluster (nœuds, PersistentVolumes, StorageClasses, namespaces eux-mêmes). Pour ces derniers, le segment `/namespaces/<nom>` disparaît simplement de l'URL.

Comptons les ressources par groupe :

```bash
kubectl api-resources --no-headers -o name | awk -F. '{ if (NF==1) g="(noyau)"; else {g=$2; for(i=3;i<=NF;i++) g=g"."$i}; c[g]++} END{for(g in c) print c[g], g}' | sort -k2 | column -t
```

```sortie
17  (noyau)
2   acme.cert-manager.io
6   admissionregistration.k8s.io
1   apiextensions.k8s.io
1   apiregistration.k8s.io
5   apps
...
4   cert-manager.io
...
8   gateway.envoyproxy.io
10  gateway.networking.k8s.io
4   keda.sh
2   metrics.k8s.io
...
3   snapshot.storage.k8s.io
6   storage.k8s.io
1   storagemigration.k8s.io
```

Un Kubernetes nu n'a qu'une grosse vingtaine de groupes. Ceux qui ne finissent pas par `k8s.io`, et quelques autres, ont été ajoutés par les composants installés dans la partie IV : cert-manager, Envoy Gateway, KEDA, le pilote CSI et ses instantanés. Ils l'ont fait par des Custom Resource Definitions, qu'on écrira nous-mêmes au chapitre 54. Pour l'API server, un `ScaledObject` de KEDA est une ressource comme une autre : même forme d'URL, mêmes verbes, même stockage.

## Une ressource, plusieurs versions

Une API publique ne peut pas changer du jour au lendemain : des milliers de manifestes, de scripts et de programmes l'utilisent. Kubernetes fait donc vivre plusieurs versions d'un même groupe côte à côte, avec des promesses différentes[^versions]. Une version `alpha` (`v1alpha1`) peut disparaître sans préavis, et est désactivée par défaut. Une version `beta` est activée pour les plus anciennes, mais pas pour les nouvelles depuis Kubernetes 1.24, et elle doit rester servie un certain temps après avoir été dépréciée. Une version stable (`v1`, `v2`) ne disparaît pas tant que la version majeure de l'API ne change pas.

Le point important, c'est que deux versions d'un groupe ne sont pas deux objets distincts : ce sont **deux vues du même objet**. L'API server stocke chaque objet une seule fois, dans une version dite « de stockage », et le convertit à la volée dans la version demandée. Le HPA de l'API de Colis, créé au chapitre 31 en `autoscaling/v2`, se lit tout aussi bien en `v1` :

```bash
kubectl get --raw /apis | jq -c '[.groups[] | select(.name=="autoscaling")] | .[0] | {name, versions: [.versions[].version], preferred: .preferredVersion.version}'
kubectl get --raw /apis/autoscaling/v2/namespaces/colis/horizontalpodautoscalers/api | jq -c '{apiVersion, metrics: .spec.metrics}'
kubectl get --raw /apis/autoscaling/v1/namespaces/colis/horizontalpodautoscalers/api | jq -c '{apiVersion, targetCPUUtilizationPercentage: .spec.targetCPUUtilizationPercentage}'
```

```sortie
{"name":"autoscaling","versions":["v2","v1"],"preferred":"v2"}
{"apiVersion":"autoscaling/v2","metrics":[{"type":"Resource","resource":{"name":"cpu","target":{"type":"Utilization","averageUtilization":50}}}]}
{"apiVersion":"autoscaling/v1","targetCPUUtilizationPercentage":50}
```

`kubectl get --raw` envoie un `GET` sur le chemin donné, avec votre identité, et affiche la réponse telle quelle : c'est l'outil idéal pour explorer. En `v2`, la cible est une liste de métriques, où l'on peut mettre la mémoire, une métrique externe ou plusieurs à la fois. En `v1`, qui date d'avant ces possibilités, il n'existe qu'un champ, `targetCPUUtilizationPercentage`. L'API server a traduit l'une dans l'autre. Ce qui ne rentre pas dans la vieille forme n'est pas perdu : il est rangé dans des annotations `autoscaling.alpha.kubernetes.io/...`, que vous verrez en affichant l'objet `v1` en entier. La « version préférée », `v2`, est celle que kubectl choisit quand vous ne précisez rien.

Quand une version bêta est enfin retirée, les manifestes qui l'utilisent cessent de fonctionner. Le cas le plus célèbre est Kubernetes 1.16, en 2019, qui a retiré d'un coup les Deployments, DaemonSets, ReplicaSets et NetworkPolicies du groupe `extensions/v1beta1`, où ils vivaient depuis les débuts[^v116]. Des charts Helm par centaines ont cessé de s'installer du jour au lendemain. Un manifeste de cette époque, appliqué aujourd'hui :

```yaml title="ancien.yaml"
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: ancien
...
```

```bash
kubectl apply -f ancien.yaml
```

```sortie
error: resource mapping not found for name: "ancien" namespace: "" from "ancien.yaml": no matches for kind "Deployment" in version "extensions/v1beta1"
ensure CRDs are installed first
```

:::panne[no matches for kind "Deployment" in version "extensions/v1beta1"]

Le message vient de kubectl, pas de l'API server : avant d'envoyer quoi que ce soit, kubectl cherche dans la liste des ressources celle qui correspond au couple `apiVersion` et `kind`, et n'en trouve pas. Il y a deux causes, et la suggestion qui suit (`ensure CRDs are installed first`) ne concerne que la seconde. Soit la version a été retirée, comme ici : il faut passer à la version stable (`apps/v1` pour un Deployment), en vérifiant les champs qui ont changé entre-temps ; pour un Deployment, `spec.selector` est devenu obligatoire. Soit la ressource vient d'une CRD qui n'est pas encore installée, ce qui arrive quand on applique d'un bloc un opérateur et ses premiers objets. `kubectl api-resources | grep <kind>` tranche en une seconde.

:::

## Parler à l'API sans kubectl

Le chemin le plus simple vers l'API, sans s'occuper d'identité, est `kubectl proxy`. Il ouvre un port local, et relaie vers l'API server chaque requête qu'il reçoit, en y ajoutant les informations d'identité de votre kubeconfig :

```bash
kubectl proxy --port=8011 &
curl -s localhost:8011/api/v1/namespaces/ch34/configmaps
```

```sortie
{
  "kind": "ConfigMapList",
  "apiVersion": "v1",
  "metadata": {
    "resourceVersion": "94117"
  },
  "items": [
    {
      "metadata": {
        "name": "kube-root-ca.crt",
        "namespace": "ch34",
...
```

La réponse est du JSON, et c'est déjà instructif : une liste a elle-même un `kind` (`ConfigMapList`), et une `resourceVersion` sur laquelle on reviendra. Le ConfigMap `kube-root-ca.crt` a été créé automatiquement dans le namespace par un contrôleur ; il contient le certificat de l'autorité du cluster, que les Pods utilisent pour vérifier l'API server.

Le proxy est pratique, mais il cache l'essentiel : la question de savoir **qui** parle. Arrêtez-le (`kill %1`), et parlons à l'API server directement, à l'adresse que donne le kubeconfig. Le fichier `acces.sh` de l'archive la retrouve, ainsi que les fichiers d'identité que minikube a écrits pour kubectl :

```bash title="acces.sh"
PROFIL=${1:-minikube}
API=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
M=~/.minikube
ID=(--cacert $M/ca.crt --cert $M/profiles/$PROFIL/client.crt --key $M/profiles/$PROFIL/client.key)
echo "API server : $API"
```

Posons la même question, « la liste des ConfigMaps de `ch34` », quatre fois, en changeant seulement d'identité. Sans rien (et sans vérifier le certificat du serveur, `-k`) ; avec un jeton inventé ; avec le jeton d'un ServiceAccount du namespace ; avec le certificat client de kubectl :

```bash
source acces.sh
U=$API/api/v1/namespaces/ch34/configmaps
curl -s -k $U | jq -c '{code, reason, message}'
curl -s --cacert ~/.minikube/ca.crt -H 'Authorization: Bearer abc' $U | jq -c '{code, reason, message}'
T=$(kubectl create token default)
curl -s --cacert ~/.minikube/ca.crt -H "Authorization: Bearer $T" $U | jq -c '{code, reason, message}'
curl -s "${ID[@]}" $U | jq -c '{kind, n: (.items|length), noms: [.items[].metadata.name]}'
```

```sortie
API server : https://192.168.49.2:8443
{"code":403,"reason":"Forbidden","message":"configmaps is forbidden: User \"system:anonymous\" cannot list resource \"configmaps\" in API group \"\" in the namespace \"ch34\""}
{"code":401,"reason":"Unauthorized","message":"Unauthorized"}
{"code":403,"reason":"Forbidden","message":"configmaps is forbidden: User \"system:serviceaccount:ch34:default\" cannot list resource \"configmaps\" in API group \"\" in the namespace \"ch34\""}
{"kind":"ConfigMapList","n":1,"noms":["kube-root-ca.crt"]}
```

Quatre réponses, et trois codes différents. Elles méritent qu'on s'y arrête, parce qu'elles montrent les deux premières questions que l'API server se pose sur toute requête.

La première est « **qui êtes-vous ?** », l'authentification. Sans aucune pièce d'identité, la requête n'est pas rejetée : elle est attribuée à un utilisateur spécial, `system:anonymous`, que la configuration de minikube accepte. Avec un jeton que personne n'a émis, en revanche, l'API server refuse d'aller plus loin : `401 Unauthorized`, sans autre explication, car on ne donne pas d'indices à quelqu'un qui présente une fausse pièce. Le jeton produit par `kubectl create token` est signé par le cluster : il est reconnu, et identifie le ServiceAccount `default` du namespace `ch34`, sous le nom `system:serviceaccount:ch34:default`.

La seconde question est « **avez-vous le droit ?** », l'autorisation. L'anonyme et le ServiceAccount sont bien identifiés, mais aucune règle ne leur permet de lister des ConfigMaps : `403 Forbidden`, avec un message précis, qui nomme l'utilisateur, le verbe (`list`), la ressource, le groupe (vide pour le noyau) et le namespace. Ce sont exactement les quatre éléments sur lesquels portent les règles RBAC du chapitre 43. Seul le certificat de kubectl passe les deux étapes. Qui est-il ?

```bash
openssl x509 -in ~/.minikube/profiles/minikube/client.crt -noout -subject
kubectl auth whoami
```

```sortie
subject=O=system:masters, CN=minikube-user
ATTRIBUTE                                           VALUE
Username                                            minikube-user
Groups                                              [system:masters system:authenticated]
```

Dans un certificat client, le `CN` devient le nom d'utilisateur, et chaque `O` un groupe. Vous êtes donc `minikube-user`, membre de `system:masters`, un groupe auquel Kubernetes accorde tous les droits sans même consulter les règles RBAC. C'est commode sur un poste de TP ; c'est aussi la raison pour laquelle un tel certificat ne doit jamais sortir d'un cluster de production. On y reviendra en partie VI.

## Cinq méthodes HTTP, huit verbes

Kubernetes ne parle pas de méthodes HTTP mais de **verbes**, et la correspondance n'est pas tout à fait un à un[^concepts] :

| Méthode HTTP | Sur un objet | Sur une collection |
|---|---|---|
| `GET` | `get` | `list`, ou `watch` avec `?watch=true` |
| `POST` | | `create` |
| `PUT` | `update` (remplacement complet) | |
| `PATCH` | `patch` (modification partielle) | |
| `DELETE` | `delete` | `deletecollection` |

C'est avec ces huit verbes que s'écrivent les règles d'autorisation, et c'est pourquoi le message de tout à l'heure disait `cannot list`, pas `cannot GET`. Essayons-les tous sur un petit ConfigMap, décrit dans `reglages.json`. Pour voir ce que l'API annonce aux autres pendant ce temps, on lance d'abord, en arrière-plan, un watch sur cet objet ; on y reviendra juste après.

```bash
curl -sN "${ID[@]}" "$U?watch=true&fieldSelector=metadata.name=reglages" > watch.txt &
```

On crée le ConfigMap par un `POST` sur la collection, puis on recommence :

```bash
curl -s "${ID[@]}" -X POST $U -H 'Content-Type: application/json' -d @reglages.json | jq -c '{kind, rv: .metadata.resourceVersion, uid: .metadata.uid}'
curl -s "${ID[@]}" -X POST $U -H 'Content-Type: application/json' -d @reglages.json | jq -c '{code, reason, message}'
```

```sortie
{"kind":"ConfigMap","rv":"94123","uid":"d0ca1edd-d6c3-42e5-8fa8-28fc0b72c0a7"}
{"code":409,"reason":"AlreadyExists","message":"configmaps \"reglages\" already exists"}
```

La création renvoie l'objet tel qu'il a été enregistré, avec deux champs que personne n'a fournis : un `uid`, identifiant unique qui ne sera jamais réutilisé, même si l'on recrée un objet du même nom, et une `resourceVersion`. La seconde création échoue avec `409 AlreadyExists` : `POST` crée, il ne remplace pas. C'est toute la différence avec `kubectl apply`, qui commence par regarder si l'objet existe.

Modifions-le, de deux façons différentes. Un **merge patch** (RFC 7386) est un morceau de JSON qui se superpose à l'objet : les champs présents remplacent les anciens, les autres ne bougent pas. Un **JSON patch** (RFC 6902) est une liste d'opérations, avec un chemin précis pour chacune[^patch] :

```bash
curl -s "${ID[@]}" -X PATCH $U/reglages -H 'Content-Type: application/merge-patch+json' \
  -d '{"data":{"taille":"grande"}}' | jq -c '{rv: .metadata.resourceVersion, data}'
curl -s "${ID[@]}" -X PATCH $U/reglages -H 'Content-Type: application/json-patch+json' \
  -d '[{"op":"replace","path":"/data/couleur","value":"vert"}]' | jq -c '{rv: .metadata.resourceVersion, data}'
```

```sortie
{"rv":"94124","data":{"couleur":"bleu","taille":"grande"}}
{"rv":"94125","data":{"couleur":"vert","taille":"grande"}}
```

C'est l'en-tête `Content-Type` qui dit à l'API server comment lire le corps. Il en existe deux autres. Le **strategic merge patch** est propre à Kubernetes : c'est un merge patch qui sait que la liste `containers` d'un Pod se fusionne par le champ `name`, au lieu d'être remplacée en bloc ; c'est le format par défaut de `kubectl patch`. Et l'**apply patch**, qu'on verra à la fin du chapitre. À chaque modification, la `resourceVersion` a augmenté.

Un `PUT` remplace l'objet entier. Envoyons un remplacement qui prétend partir de la version `1` de l'objet :

```bash
curl -s "${ID[@]}" -X PUT $U/reglages -H 'Content-Type: application/json' \
  -d '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"reglages","resourceVersion":"1"},"data":{"couleur":"rouge"}}' | jq -c '{code, reason, message}'
```

```sortie
{"code":409,"reason":"Conflict","message":"Operation cannot be fulfilled on configmaps \"reglages\": the object has been modified; please apply your changes to the latest version and try again"}
```

Refusé. C'est la **concurrence optimiste** : quand une écriture porte une `resourceVersion`, l'API server ne l'accepte que si l'objet n'a pas changé depuis cette version. Deux programmes qui lisent le même objet, le modifient chacun de leur côté et le réécrivent ne peuvent donc pas s'écraser l'un l'autre sans le savoir : le second reçoit un `409`, relit l'objet et recommence. Aucun verrou, aucune attente : on suppose que les conflits sont rares, et on les détecte au lieu de les empêcher. Le chapitre 35 montrera d'où vient ce numéro, et comment etcd fait respecter la règle.

:::panne[the object has been modified; please apply your changes to the latest version and try again]

Ce message apparaît dans les journaux d'un contrôleur, d'un opérateur, ou d'un script qui fait lire, modifier, écrire. Ce n'est pas une panne, c'est le mécanisme qui fonctionne : quelqu'un d'autre a modifié l'objet entre la lecture et l'écriture. Un contrôleur bien écrit relit et réessaie, et le message disparaît au passage suivant. S'il revient en boucle sur le même objet, deux programmes se disputent un champ, chacun défaisant ce que fait l'autre ; le server-side apply, à la fin du chapitre, permet de trouver lequel. Dans un script, préférez un `PATCH` (ou `kubectl patch`), qui ne porte pas de `resourceVersion` et ne touche que les champs nommés, à un `GET` suivi d'un `PUT`.

:::

Il reste à supprimer le ConfigMap, et à regarder ce que le watch a reçu pendant tout ce temps :

```bash
curl -s "${ID[@]}" -X DELETE $U/reglages | jq -c '{kind, status, details}'
kill %1
jq -c '{type, rv: .object.metadata.resourceVersion, data: .object.data}' watch.txt
```

```sortie
{"kind":"Status","status":"Success","details":{"name":"reglages","kind":"configmaps","uid":"d0ca1edd-d6c3-42e5-8fa8-28fc0b72c0a7"}}
{"type":"ADDED","rv":"94123","data":{"couleur":"bleu"}}
{"type":"MODIFIED","rv":"94124","data":{"couleur":"bleu","taille":"grande"}}
{"type":"MODIFIED","rv":"94125","data":{"couleur":"vert","taille":"grande"}}
{"type":"DELETED","rv":"94126","data":{"couleur":"vert","taille":"grande"}}
```

## Suivre les changements : le watch

Cette dernière sortie est probablement la plus importante du chapitre. Un `GET` avec `?watch=true` ne renvoie pas une réponse, mais un **flux** : la connexion HTTP reste ouverte, et l'API server y écrit une ligne JSON à chaque changement d'un objet qui correspond à la demande. Chaque événement a un type (`ADDED`, `MODIFIED`, `DELETED`) et contient l'objet **entier**, dans son nouvel état, avec sa `resourceVersion`. Les deux écritures refusées, elles, n'ont rien produit : il ne s'est rien passé.

C'est sur ce mécanisme que repose tout Kubernetes. Le scheduler ne demande pas toutes les secondes s'il y a de nouveaux Pods à placer : il garde un watch ouvert sur les Pods sans nœud. Le kubelet garde un watch sur les Pods de son nœud. Le contrôleur des Deployments garde un watch sur les Deployments et les ReplicaSets. Un changement dans l'API se propage ainsi en quelques millisecondes à tous ceux qu'il concerne, sans qu'aucun d'eux n'ait à interroger l'API en boucle.

`kubectl get -w` fait la même chose, et `-v=6` le montre :

```bash
kubectl get deploy vitrine -w -v=6 &
kubectl scale deploy vitrine --replicas=3
```

```sortie
verb="GET" url="https://192.168.49.2:8443/apis/apps/v1/namespaces/ch34/deployments/vitrine" status="200 OK" milliseconds=2
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
vitrine   2/2     2            2           1s
verb="GET" url="https://192.168.49.2:8443/apis/apps/v1/namespaces/ch34/deployments?fieldSelector=metadata.name%3Dvitrine&resourceVersion=0&watch=true" status="200 OK" milliseconds=0
vitrine   2/3     2            2           3s
vitrine   2/3     2            2           3s
vitrine   2/3     2            2           3s
vitrine   2/3     3            2           3s
vitrine   3/3     3            3           4s
```

Un `GET` pour l'état initial, puis un watch, et cinq événements pour une seule commande : `scale` a modifié `spec.replicas`, puis le contrôleur des Deployments a mis à jour le statut à plusieurs reprises, au fil de la création du troisième Pod. Chaque ligne affichée est un `MODIFIED`. Remarquez que le watch porte sur une collection (`deployments`), filtrée par un `fieldSelector` sur le nom : on ne peut pas « regarder » un objet seul, seulement une collection, éventuellement réduite à un élément.

Un watch reprend à partir d'une `resourceVersion` : « tout ce qui a changé après la version N ». Mais l'API server ne garde pas l'historique indéfiniment. Demandons les changements depuis la version 10 :

```bash
timeout 3 curl -sN "${ID[@]}" "$U?watch=true&resourceVersion=10" | jq -c '{type, code: .object.code, reason: .object.reason, message: .object.message}'
```

```sortie
{"type":"ERROR","code":410,"reason":"Expired","message":"too old resource version: 10 (83935)"}
```

`410 Expired` (on dit aussi « Gone ») : la version 10 est trop ancienne, et l'API server indique entre parenthèses la plus ancienne qu'il peut encore servir. Un client qui reçoit cette réponse n'a qu'une chose à faire : relister toute la collection pour repartir d'un état complet, puis rouvrir un watch à partir de la `resourceVersion` de cette liste. C'est le schéma « list puis watch », que les contrôleurs appliquent tous, et que le chapitre 36 démontera en détail.

## Les longues listes

Revenons à la toute première sortie du chapitre : kubectl demandait `pods?limit=500`. Sur un gros cluster, une liste de dizaines de milliers de Pods pèse des centaines de mégaoctets ; la renvoyer d'un bloc coûte cher à l'API server comme au client. L'API permet donc de lister **par pages**[^concepts]. Créons sept ConfigMaps et demandons-les trois par trois :

```bash
for i in 1 2 3 4 5 6 7; do kubectl create configmap carton-$i --from-literal=n=$i; done
R=$(curl -s "${ID[@]}" "$U?limit=3")
echo "$R" | jq -c '{rv: .metadata.resourceVersion, reste: .metadata.remainingItemCount, noms: [.items[].metadata.name]}'
C=$(echo "$R" | jq -r .metadata.continue); echo "$C"; echo "$C" | base64 -d; echo
curl -s "${ID[@]}" "$U?limit=3&continue=$C" | jq -c '{reste: .metadata.remainingItemCount, noms: [.items[].metadata.name]}'
```

```sortie
{"rv":"94137","reste":5,"noms":["carton-1","carton-2","carton-3"]}
eyJ2IjoibWV0YS5rOHMuaW8vdjEiLCJydiI6OTQxMzcsInN0YXJ0IjoiL2NhcnRvbi0zXHUwMDAwIn0
{"v":"meta.k8s.io/v1","rv":94137,"start":"/carton-3\u0000"}
{"reste":2,"noms":["carton-4","carton-5","carton-6"]}
```

La première page contient trois objets, et annonce qu'il en reste cinq (les quatre derniers cartons et `kube-root-ca.crt`). Elle fournit aussi un jeton `continue`, à renvoyer pour obtenir la suite. Ce jeton n'a rien de secret : c'est du JSON encodé en base64, qui contient la `resourceVersion` de la liste et la clé à partir de laquelle reprendre. D'où une propriété précieuse : toutes les pages sont lues **à la même version**, 94137. Si quelqu'un crée ou supprime un ConfigMap entre deux pages, vous ne le verrez pas, et vous ne verrez pas non plus un objet deux fois ; la liste complète est une photographie cohérente, même découpée. Le prix de cette cohérence : l'API server doit pouvoir relire cette version ancienne, ce qu'il ne peut faire que quelques minutes, jusqu'au prochain compactage d'etcd (toutes les 5 minutes par défaut). Un jeton trop vieux reçoit, lui aussi, un `410`.

kubectl pagine de lui-même, par pages de 500. Avec `--chunk-size=3`, on le voit suivre les jetons :

```bash
kubectl get cm --chunk-size=3 -v=6 2>&1 | grep -o 'url="[^"]*configmaps[^"]*"' | sed 's/continue=[^&]*/continue=.../'
```

```sortie
url="https://192.168.49.2:8443/api/v1/namespaces/ch34/configmaps?limit=3"
url="https://192.168.49.2:8443/api/v1/namespaces/ch34/configmaps?continue=...&limit=3"
url="https://192.168.49.2:8443/api/v1/namespaces/ch34/configmaps?continue=...&limit=3"
```

Une dernière remarque sur les listes, qui explique un mystère. Comment kubectl sait-il quelles colonnes afficher pour un `ScaledObject`, une ressource qu'il ne connaît pas ? Il ne le sait pas : il demande à l'API server de préparer le tableau. C'est l'en-tête `Accept` de la requête, que `-v=8` révèle :

```sortie
Accept: application/json;as=Table;v=v1;g=meta.k8s.io,application/json;as=Table;v=v1beta1;g=meta.k8s.io,application/json
```

« Donnez-moi un `Table` si vous savez faire, sinon du JSON ordinaire. » Avec le même en-tête, `curl` reçoit ceci :

```bash
curl -s "${ID[@]}" -H 'Accept: application/json;as=Table;v=v1;g=meta.k8s.io' "$U?limit=2" | jq -c '{kind, colonnes: [.columnDefinitions[].name], lignes: [.rows[].cells]}'
```

```sortie
{"kind":"Table","colonnes":["Name","Data","Age"],"lignes":[["carton-1",1,"0s"],["carton-2",1,"0s"]]}
```

Les colonnes `NAME`, `DATA`, `AGE` de `kubectl get cm` viennent donc du serveur. Pour une ressource ajoutée par une CRD, c'est la CRD qui les déclare (`additionalPrinterColumns`), et c'est ce qu'on fera au chapitre 54.

## Ce que l'API server fait d'une requête

Entre le moment où une requête arrive et celui où l'objet est enregistré, l'API server lui fait traverser une série d'étages, dans un ordre fixe[^acces]. Chacun peut la refuser, avec un code d'erreur qui lui est propre. On en a déjà rencontré plusieurs ; la figure 34.2 les remet dans l'ordre.

<Figure svg={apiserverChaine} num="34.2" alt="Le trajet d'une requête d'écriture dans l'API server, en huit étapes. 1, authentification : qui êtes-vous ? certificat client, jeton, sinon system:anonymous ; échec : 401 Unauthorized. 2, autorisation : avez-vous le droit ? modules Node et RBAC, selon le verbe, la ressource et le namespace ; échec : 403 Forbidden. 3, décodage du JSON, YAML ou protobuf vers l'objet, et valeurs par défaut ; échec : 400 BadRequest. 4, admission mutante : ServiceAccount, DefaultTolerationSeconds, webhooks mutants ; un webhook peut refuser. 5, validation du schéma : noms, types, champs obligatoires ; échec : 422 Invalid. 6, admission validante : ResourceQuota, NamespaceLifecycle, webhooks, politiques CEL ; échec : 403 Forbidden, par exemple pour un quota dépassé ou un namespace en cours de suppression. 7, écriture dans etcd si la resourceVersion n'a pas bougé, avec une nouvelle resourceVersion ; échec : 409 Conflict ou 409 AlreadyExists. La réponse, l'objet tel qu'enregistré, revient au client. 8, les watchers, comme kubectl get -w, les contrôleurs et le scheduler, reçoivent l'événement MODIFIED.">
Le trajet d'une requête d'écriture dans l'API server, et le code d'erreur de chaque étage. Une lecture s'arrête après l'autorisation et va chercher l'objet, le plus souvent dans le cache de l'API server plutôt que dans etcd.
</Figure>

L'API server de minikube est un Pod du namespace `kube-system`, lancé par le kubelet à partir d'un fichier posé sur le nœud (on verra ce mécanisme au chapitre 38). Ses options disent comment certains de ces étages sont configurés :

```bash
kubectl -n kube-system get pod kube-apiserver-minikube -o jsonpath='{range .spec.containers[0].command[*]}{@}{"\n"}{end}' | grep -E 'admission|authorization-mode|etcd-servers|^kube-apiserver|secure-port'
```

```sortie
kube-apiserver
--authorization-mode=Node,RBAC
--etcd-servers=https://127.0.0.1:2379
--secure-port=8443
--enable-admission-plugins=NamespaceLifecycle,LimitRanger,ServiceAccount,DefaultStorageClass,DefaultTolerationSeconds,NodeRestriction,MutatingAdmissionWebhook,ValidatingAdmissionWebhook,ResourceQuota
```

Deux modules d'autorisation, consultés dans l'ordre : `Node`, qui limite chaque kubelet aux objets de son propre nœud, puis `RBAC`. Le port 8443 qu'on interroge depuis le début. etcd, joint en local sur le port 2379, puisqu'il tourne sur le même nœud. Et la liste des **contrôleurs d'admission** activés en plus de ceux qui le sont par défaut[^admission].

L'admission est l'étage le moins visible, et le plus surprenant. Pour la voir travailler, prenons le Pod le plus dépouillé possible :

```yaml title="pod-nu.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: nu
spec:
  containers:
  - name: c
    image: registry.k8s.io/e2e-test-images/agnhost:2.61
```

et demandons à l'API server ce qu'il en ferait, sans rien créer. `--dry-run=server` envoie la requête avec le paramètre `dryRun=All` : elle traverse tous les étages, admission comprise, mais s'arrête juste avant etcd.

```bash
wc -l < pod-nu.yaml
kubectl apply -f pod-nu.yaml --dry-run=server -o yaml > rendu.yaml
wc -l < rendu.yaml
sed -n '/^spec:/,$p' rendu.yaml
kubectl get pod nu
```

```sortie
9
64
spec:
  containers:
  - image: registry.k8s.io/e2e-test-images/agnhost:2.61
    imagePullPolicy: IfNotPresent
    name: c
    resources: {}
    terminationMessagePath: /dev/termination-log
    terminationMessagePolicy: File
    volumeMounts:
    - mountPath: /var/run/secrets/kubernetes.io/serviceaccount
      name: kube-api-access-75xck
      readOnly: true
  dnsPolicy: ClusterFirst
  enableServiceLinks: true
  preemptionPolicy: PreemptLowerPriority
  priority: 0
  restartPolicy: Always
  schedulerName: default-scheduler
  securityContext: {}
  serviceAccount: default
  serviceAccountName: default
  terminationGracePeriodSeconds: 30
  tolerations:
  - effect: NoExecute
    key: node.kubernetes.io/not-ready
    operator: Exists
    tolerationSeconds: 300
  - effect: NoExecute
    key: node.kubernetes.io/unreachable
    operator: Exists
    tolerationSeconds: 300
  volumes:
  - name: kube-api-access-75xck
    projected:
      defaultMode: 420
      sources:
      - serviceAccountToken:
          expirationSeconds: 3607
          path: token
      - configMap:
          items:
          - key: ca.crt
            path: ca.crt
          name: kube-root-ca.crt
      - downwardAPI:
          items:
          - fieldRef:
              apiVersion: v1
              fieldPath: metadata.namespace
            path: namespace
status:
  phase: Pending
  qosClass: BestEffort
Error from server (NotFound): pods "nu" not found
```

De 9 lignes à 64, et aucun Pod créé. Tout ce qui a été ajouté l'a été par l'API server, et l'on peut attribuer chaque ajout à un étage précis.

Une bonne partie vient des **valeurs par défaut**, appliquées au décodage (étage 3) : `restartPolicy: Always`, `dnsPolicy: ClusterFirst`, `schedulerName: default-scheduler` (on peut écrire son propre scheduler, et le désigner ici), `terminationGracePeriodSeconds: 30`, le fichier `/dev/termination-log` où un conteneur peut écrire la raison de sa mort. `imagePullPolicy: IfNotPresent` est une valeur par défaut calculée : ce serait `Always` si l'image avait le tag `latest`, ou pas de tag du tout.

Le reste vient de l'**admission**. Le contrôleur `ServiceAccount` a rattaché le Pod au ServiceAccount `default`, et lui a monté un volume `kube-api-access-...` qui contient trois fichiers : un jeton valable une heure, renouvelé par le kubelet, le certificat de l'autorité du cluster, et le nom du namespace. Ce sont exactement les trois choses dont un programme a besoin pour parler à l'API server depuis un Pod, comme on l'a fait avec `curl` tout à l'heure. Le contrôleur `DefaultTolerationSeconds` a ajouté deux tolérances de 300 secondes : si le nœud du Pod devient injoignable, le Pod y reste cinq minutes avant d'être évincé (le taint `NoExecute` du chapitre 32). Le contrôleur `Priority`, actif par défaut, a fixé la priorité à 0, faute de `priorityClassName`. Enfin, le statut `qosClass: BestEffort` a été calculé à la création, puisque le conteneur ne déclare ni request ni limit (chapitre 23).

Il manque un ajout, dans la partie `metadata` qu'on n'a pas affichée : l'annotation `kubectl.kubernetes.io/last-applied-configuration`. Celle-là ne vient pas de l'API server, mais de kubectl lui-même, et on la retrouvera dans la dernière section.

L'étage de validation, lui, se voit dès qu'on lui donne un nom interdit :

```bash
kubectl create configmap Reglages_1 --from-literal=a=b
```

```sortie
error: failed to create configmap: ConfigMap "Reglages_1" is invalid: metadata.name: Invalid value: "Reglages_1": a lowercase RFC 1123 subdomain must consist of lower case alphanumeric characters, '-' or '.', and must start and end with an alphanumeric character (e.g. 'example.com', regex used for validation is '[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*')
```

C'est un `422 Invalid`. Le message est long, mais il dit tout, jusqu'à l'expression régulière appliquée : un nom d'objet doit pouvoir servir de nom DNS, parce que beaucoup en deviennent un (un Service s'appelle comme son nom dans le DNS du cluster).

Les contrôleurs d'admission sont compilés dans l'API server, mais deux d'entre eux, `MutatingAdmissionWebhook` et `ValidatingAdmissionWebhook`, servent de prises : ils appellent des services web extérieurs, déclarés par des objets de l'API, qui peuvent modifier ou refuser les requêtes à leur tour. cert-manager en a installé un au chapitre 28, pour valider ses `Certificate`. C'est aussi par là que passent les outils de politique comme Kyverno, sujet du chapitre 45.

## Les sous-ressources

Certaines URL ont un segment de plus après le nom de l'objet. Ce sont les **sous-ressources**, et les Pods en ont beaucoup :

```bash
kubectl get --raw /api/v1 | jq -r '.resources[].name' | grep '^pods'
```

```sortie
pods
pods/attach
pods/binding
pods/ephemeralcontainers
pods/eviction
pods/exec
pods/log
pods/portforward
pods/proxy
pods/resize
pods/status
```

Vous en utilisez la plupart sans le savoir. `kubectl logs` lit `pods/log`, `kubectl exec` ouvre une connexion sur `pods/exec`, `kubectl drain` appelle `pods/eviction` (chapitre 33). Le scheduler, quand il a choisi un nœud, ne modifie pas le Pod : il crée un objet `Binding` en envoyant un `POST` sur `pods/binding`. Et `pods/resize` est la porte par laquelle le VPA du chapitre 31 modifie les ressources d'un Pod en marche.

Pourquoi ne pas tout faire sur l'objet lui-même ? Parce qu'une sous-ressource est une porte distincte, avec ses propres droits. On peut autoriser quelqu'un à lire les journaux d'un Pod (`get` sur `pods/log`) sans lui permettre d'y exécuter une commande (`create` sur `pods/exec`), ce qui est une toute autre affaire. De même, `status` sépare ce que l'utilisateur demande (`spec`) de ce que le système constate (`status`) : une écriture sur l'objet ignore le statut, une écriture sur `status` ignore tout le reste. Chacun écrit sa moitié, sans marcher sur celle de l'autre.

La sous-ressource `scale` mérite un exemple. Elle existe pour les Deployments, les StatefulSets, les ReplicaSets, et toute CRD qui la déclare, et présente chacun de ces objets sous une même forme réduite :

```bash
kubectl get --raw /apis/apps/v1/namespaces/ch34/deployments/vitrine/scale | jq -c '{kind, apiVersion, spec, status}'
```

```sortie
{"kind":"Scale","apiVersion":"autoscaling/v1","spec":{"replicas":2},"status":{"replicas":2,"selector":"app=vitrine"}}
```

Un objet `Scale`, du groupe `autoscaling`, qui ne contient que le nombre de répliques voulu, le nombre réel, et le sélecteur des Pods. C'est tout ce dont le HPA a besoin, et c'est exactement ce qu'il utilise : grâce à cette forme commune, il sait mettre à l'échelle n'importe quelle ressource qui la propose, y compris celles qui n'existaient pas quand il a été écrit.

## Des API servies par d'autres

Les métriques de `kubectl top`, qu'on a vues dans `metrics.k8s.io`, ne sont pas stockées dans etcd, et l'API server ne les calcule pas. Il les demande à un autre serveur. C'est la **couche d'agrégation**[^agregation] : un objet `APIService` déclare qu'un groupe et une version sont servis par un Service du cluster, et l'API server relaie vers lui toutes les requêtes qui les concernent, après les avoir authentifiées et autorisées.

```bash
kubectl get apiservices | grep -v Local
kubectl get --raw /apis/metrics.k8s.io/v1beta1/namespaces/colis/pods | jq -c '.items[] | {pod: .metadata.name, cpu: .containers[0].usage.cpu, memoire: .containers[0].usage.memory}' | head -3
```

```sortie
NAME                                SERVICE                                AVAILABLE   AGE
v1beta1.external.metrics.k8s.io     keda/keda-operator-metrics-apiserver   True        149m
v1beta1.metrics.k8s.io              kube-system/metrics-server             True        24h
{"pod":"api-85cbf95c69-4m7ns","cpu":"3242827n","memoire":"57644Ki"}
{"pod":"api-85cbf95c69-99p9p","cpu":"3475649n","memoire":"53548Ki"}
{"pod":"api-canari-799c55878f-zsjwx","cpu":"3339524n","memoire":"54700Ki"}
```

Les `APIService` marqués `Local` sont servis par l'API server lui-même ; on ne garde que les deux autres. `metrics.k8s.io` est servi par metrics-server, activé au chapitre 16 ; `external.metrics.k8s.io` par KEDA, qui y publie la longueur de la file Redis pour que le HPA qu'il a créé puisse la lire (chapitre 31). Les valeurs de processeur sont en nanocœurs : 3242827n, c'est environ 3,2 millicœurs. Pour un client, rien ne distingue ces API des autres : même forme d'URL, même authentification, même `kubectl get --raw`. Si metrics-server tombe, en revanche, `AVAILABLE` passe à `False`, et kubectl se met à afficher des avertissements sur la découverte à chaque commande.

## Qui possède ce champ ?

Revenons sur le `apply` qu'on utilise depuis la partie III. Dans sa forme classique, il se fait **côté client** : kubectl lit l'objet existant, le compare à votre fichier et à la dernière version de ce fichier qu'il a appliquée, calcule un patch et l'envoie. Cette dernière version, il faut bien la garder quelque part : c'est l'annotation `last-applied-configuration` aperçue sur le Pod `nu`. Le procédé marche, mais il a deux défauts. La logique est dans kubectl, si bien que chaque outil (Helm, un opérateur, un script Python) doit la réécrire. Et il ne connaît que deux points de vue, le vôtre et celui de l'objet, alors que plusieurs acteurs écrivent souvent dans le même objet.

Le **server-side apply** (SSA) déplace cette logique dans l'API server, et répond à une question que l'apply classique ne se pose pas : **qui gère quel champ**[^ssa] ? On l'active avec `--server-side`, en donnant un nom de gestionnaire :

```bash
kubectl apply --server-side --field-manager=equipe-web -f vitrine.yaml
kubectl get deploy vitrine --show-managed-fields -o yaml | sed -n '/managedFields:/,/time:/p'
```

```sortie
deployment.apps/vitrine serverside-applied
  managedFields:
  - apiVersion: apps/v1
    fieldsType: FieldsV1
    fieldsV1:
      f:spec:
        f:replicas: {}
        f:selector: {}
        f:template:
          f:metadata:
            f:labels:
              f:app: {}
          f:spec:
            f:containers:
              k:{"name":"web"}:
                .: {}
                f:args: {}
                f:image: {}
                f:name: {}
                f:resources:
                  f:requests:
                    f:cpu: {}
                    f:memory: {}
    manager: equipe-web
    operation: Apply
    time: "2026-09-26T17:17:28Z"
```

L'API server a noté, dans `metadata.managedFields`, la liste exacte des champs que `equipe-web` a fixés : ceux de son fichier, et aucun autre. La notation `k:{"name":"web"}` désigne l'élément de la liste `containers` dont le nom est `web`, ce qui permet à deux gestionnaires de posséder chacun un conteneur du même Pod. Les autres gestionnaires de l'objet apparaissent aussi (kubectl les masque par défaut, d'où `--show-managed-fields`) :

```bash
kubectl scale deploy vitrine --replicas=4
kubectl get deploy vitrine --show-managed-fields -o json | jq -c '.metadata.managedFields[] | {manager, operation, subresource}'
```

```sortie
deployment.apps/vitrine scaled
{"manager":"equipe-web","operation":"Apply","subresource":null}
{"manager":"kubectl","operation":"Update","subresource":"scale"}
{"manager":"kube-controller-manager","operation":"Update","subresource":"status"}
```

Trois gestionnaires : l'équipe, par un `Apply` ; `kubectl scale`, par une écriture ordinaire (`Update`) sur la sous-ressource `scale`, qui lui a pris la propriété de `spec.replicas` ; et le contrôleur des Deployments, qui écrit le statut. Que se passe-t-il si l'équipe réapplique son fichier, qui dit toujours `replicas: 2` ?

```bash
kubectl apply --server-side --field-manager=equipe-web -f vitrine.yaml
```

```sortie
error: Apply failed with 1 conflict: conflict with "kubectl" with subresource "scale" using apps/v1: .spec.replicas
Please review the fields above--they currently have other managers. Here
are the ways you can resolve this warning:
* If you intend to manage all of these fields, please re-run the apply
  command with the `--force-conflicts` flag.
* If you do not intend to manage all of the fields, please edit your
  manifest to remove references to the fields that should keep their
  current managers.
* You may co-own fields by updating your manifest to match the existing
  value; in this case, you'll become the manager if the other manager(s)
  stop managing the field (remove it from their configuration).
See https://kubernetes.io/docs/reference/using-api/server-side-apply/#conflicts
```

Un **conflit**, et c'est tout l'intérêt. Avec l'apply classique, le fichier aurait silencieusement remis 2 répliques, et le HPA ou la personne qui avait mis à l'échelle aurait vu son choix défait sans comprendre pourquoi : c'est exactement la dispute entre un manifeste et un HPA décrite au chapitre 31. Ici, l'API server refuse, nomme le champ et son propriétaire, et propose trois issues. Imposer sa valeur, avec `--force-conflicts`, ce qui reprend la propriété du champ :

```bash
kubectl apply --server-side --field-manager=equipe-web --force-conflicts -f vitrine.yaml
kubectl get deploy vitrine -o jsonpath='{.spec.replicas}{"\n"}'
kubectl get deploy vitrine --show-managed-fields -o json | jq -c '.metadata.managedFields[] | {manager, operation, subresource}'
```

```sortie
deployment.apps/vitrine serverside-applied
2
{"manager":"equipe-web","operation":"Apply","subresource":null}
{"manager":"kube-controller-manager","operation":"Update","subresource":"status"}
```

Ou bien retirer le champ de son fichier, pour le laisser à qui le gère : c'est la bonne réponse quand un HPA s'en occupe, et l'exercice 3 montre qu'il faut s'y prendre dans le bon ordre. La troisième issue, reprendre la même valeur que le propriétaire actuel, fait des deux gestionnaires des copropriétaires du champ.

C'est parce qu'il règle ces cohabitations que le SSA s'est imposé. Helm 4 applique ses charts de cette façon (chapitre 29), les contrôleurs récents aussi, et Argo CD sait s'en servir pour ne pas écraser ce que d'autres ont écrit (chapitre 57).

## L'API server se surveille aussi

Comme tout programme qui tourne dans un cluster, l'API server expose des points de santé et des métriques[^sante]. `/livez` dit s'il est vivant, `/readyz` s'il est prêt à servir, et le paramètre `verbose` détaille chacune des vérifications :

```bash
kubectl get --raw '/readyz?verbose' | head -5
kubectl get --raw '/readyz?verbose' | tail -2
```

```sortie
[+]ping ok
[+]log ok
[+]etcd ok
[+]etcd-readiness ok
[+]informer-sync ok
[+]shutdown ok
readyz check passed
```

La vérification `etcd` est la plus parlante : un API server qui ne joint plus etcd se déclare non prêt, et un répartiteur de charge placé devant plusieurs API servers cesse de lui envoyer des requêtes.

`/metrics` expose des centaines de compteurs au format de Prometheus, qu'on exploitera au chapitre 50. L'un d'eux compte les requêtes par verbe, ressource et code de réponse. Les nôtres y sont (sortie raccourcie) :

```bash
kubectl get --raw /metrics | grep -E '^apiserver_request_total\{' | grep 'resource="configmaps"' | grep -E 'code="(201|409|422)"'
```

```sortie
apiserver_request_total{code="201",...,resource="configmaps",scope="resource",subresource="",verb="APPLY",version="v1"} 3
apiserver_request_total{code="201",...,resource="configmaps",scope="resource",subresource="",verb="POST",version="v1"} 50
apiserver_request_total{code="409",...,resource="configmaps",scope="resource",subresource="",verb="POST",version="v1"} 5
apiserver_request_total{code="409",...,resource="configmaps",scope="resource",subresource="",verb="PUT",version="v1"} 5
apiserver_request_total{code="422",...,resource="configmaps",scope="resource",subresource="",verb="POST",version="v1"} 5
```

Les compteurs courent depuis le démarrage de l'API server, et j'ai rejoué ce chapitre cinq fois pour le valider : voilà nos cinq `AlreadyExists`, nos cinq `PUT` en conflit et nos cinq noms invalides. Sur un vrai cluster, une montée soudaine des `409` signale souvent deux contrôleurs qui se battent pour un objet, et une montée des `429` (trop de requêtes) un client qui inonde l'API server. Car celui-ci se protège : son mécanisme d'équité, *API Priority and Fairness*, range les requêtes en files par priorité, pour qu'un contrôleur emballé ne puisse pas empêcher le kubelet ou le scheduler d'être servis[^apf].

## Exercices

:::exercice[Exercice 1 : ce que cachent logs et delete]

Sans lire la suite, prédisez les requêtes HTTP qu'envoient `kubectl logs <pod> --tail=1` et `kubectl delete pod <pod>`. Vérifiez ensuite avec `-v=6` sur un Pod de votre namespace (par exemple `kubectl run bavard --image=registry.k8s.io/e2e-test-images/agnhost:2.61 --restart=Never -- netexec`). Qu'est-ce qui vous surprend dans la seconde ?

:::

<details>
<summary>Corrigé</summary>

```sortie
verb="GET" url="https://192.168.49.2:8443/api/v1/namespaces/ch34/pods/bavard" status="200 OK" milliseconds=2
verb="GET" url="https://192.168.49.2:8443/api/v1/namespaces/ch34/pods/bavard/log?container=bavard&tailLines=1" status="200 OK" milliseconds=8

verb="DELETE" url="https://192.168.49.2:8443/api/v1/namespaces/ch34/pods/bavard" status="200 OK" milliseconds=12
verb="GET" url="https://192.168.49.2:8443/api/v1/namespaces/ch34/pods/bavard" status="200 OK" milliseconds=2
verb="GET" url="https://192.168.49.2:8443/api/v1/namespaces/ch34/pods?allowWatchBookmarks=true&fieldSelector=metadata.name%3Dbavard&resourceVersionMatch=NotOlderThan&sendInitialEvents=true&timeoutSeconds=409&watch=true" status="200 OK" milliseconds=1
```

(Les deux requêtes de découverte, `/api` et `/apis`, précèdent chaque commande ; je les ai retirées.) `logs` lit d'abord le Pod, pour savoir quel conteneur choisir, puis la sous-ressource `log`, avec le conteneur et `tailLines` en paramètres. `delete` envoie bien un `DELETE`, qui répond `200`, mais le Pod n'a pas disparu pour autant : le `GET` suivant le trouve encore. Une suppression de Pod n'est qu'une demande ; le Pod reste présent, avec une date de suppression, le temps que le kubelet arrête ses conteneurs (le délai de grâce du chapitre 22). kubectl ouvre donc un watch sur ce seul Pod, pour attendre l'événement `DELETED` et ne rendre la main qu'à ce moment. Les paramètres `sendInitialEvents=true` et `resourceVersionMatch=NotOlderThan` sont ceux des « listes en flux », où le watch commence par envoyer l'état actuel au lieu d'exiger une liste préalable[^concepts]. Pour un Deployment, `-v=8` montre enfin le corps de la requête `DELETE` : `{"propagationPolicy":"Background"}`. La suppression des ReplicaSets et des Pods qui en dépendent est laissée à un contrôleur, le ramasse-miettes, qu'on verra au chapitre 36.

</details>

:::exercice[Exercice 2 : mettre à l'échelle avec curl]

Avec `curl` et les variables de `acces.sh`, passez la vitrine à trois répliques sans toucher au Deployment lui-même, en passant par sa sous-ressource `scale`. Quel `Content-Type` choisir, et que contient la réponse ?

:::

<details>
<summary>Corrigé</summary>

```bash
curl -s "${ID[@]}" -X PATCH "$API/apis/apps/v1/namespaces/ch34/deployments/vitrine/scale" \
  -H 'Content-Type: application/merge-patch+json' -d '{"spec":{"replicas":3}}' | jq -c '{kind, spec}'
kubectl get deploy vitrine
```

```sortie
{"kind":"Scale","spec":{"replicas":3}}
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
vitrine   3/3     3            3           7s
```

Un merge patch est le plus simple : on n'envoie que le champ à changer. La réponse est l'objet `Scale` mis à jour, pas le Deployment. C'est ainsi que procède le HPA, et c'est pour cette raison qu'une règle RBAC peut autoriser un outil à mettre un Deployment à l'échelle (`patch` sur `deployments/scale`) sans lui permettre d'en changer l'image. Un `PUT` sur la même adresse marcherait aussi, avec un objet `Scale` complet, mais il faudrait alors fournir la `resourceVersion` courante, ou accepter de risquer d'écraser une écriture concurrente.

</details>

:::exercice[Exercice 3 : rendre le champ replicas]

L'équipe `equipe-web` gère la vitrine par server-side apply, avec `replicas: 2` dans son fichier. On veut désormais laisser le nombre de répliques à quelqu'un d'autre, un HPA par exemple. Le fichier `vitrine-sans-replicas.yaml` de l'archive est le même, sans ce champ. Prédisez la valeur de `spec.replicas` après l'avoir appliqué (avec `--server-side --field-manager=equipe-web`) dans deux situations : (a) juste après un `kubectl scale deploy vitrine --replicas=4` ; (b) sur un Deployment fraîchement créé par l'équipe, que personne d'autre n'a touché. Vérifiez.

:::

<details>
<summary>Corrigé</summary>

```sortie
cas 1 : replicas=4
cas 2 avant : replicas=2
cas 2 après : replicas=1
```

Dans le cas (a), `kubectl scale` a pris la propriété du champ. En le retirant de son fichier, l'équipe renonce à un champ qu'elle ne possédait déjà plus : rien ne change, et les 4 répliques restent. Dans le cas (b), l'équipe est la seule propriétaire de `replicas`. En le retirant de son fichier, elle dit « je ne veux plus de ce champ », et comme personne d'autre ne le réclame, l'API server le supprime ; la valeur par défaut s'applique alors, et le Deployment tombe à **une** réplique. C'est le piège classique de l'arrivée d'un HPA : retirer `replicas` du manifeste trop tôt fait brièvement chuter l'application à une réplique. La documentation recommande donc de laisser d'abord le nouveau gestionnaire prendre le champ (le HPA le fait dès qu'il écrit dans `scale`, ou bien un `kubectl scale` à la valeur actuelle), puis seulement de retirer le champ du fichier[^ssa].

</details>

:::exercice[Exercice 4 : écrire un client de watch]

Écrivez, en Python et avec la seule bibliothèque standard, un programme qui affiche l'état initial des ConfigMaps d'un namespace, puis chacun de leurs changements, avec le type d'événement, le nom et la `resourceVersion`. Passez par `kubectl proxy --port=8011` pour ne pas avoir à gérer l'identité. Faites-le tourner pendant que vous créez, étiquetez puis supprimez un ConfigMap. Les `resourceVersion` affichées se suivent-elles ?

:::

<details>
<summary>Corrigé</summary>

```python title="surveiller.py"
import json
import sys
import urllib.request

ns = sys.argv[1] if len(sys.argv) > 1 else "default"
base = f"http://127.0.0.1:8011/api/v1/namespaces/{ns}/configmaps"

# 1. une liste, pour connaître l'état actuel et sa resourceVersion
with urllib.request.urlopen(base) as r:
    liste = json.load(r)
rv = liste["metadata"]["resourceVersion"]
print(f"{len(liste['items'])} ConfigMap(s) à la version {rv}", flush=True)

# 2. un watch à partir de cette version : une ligne JSON par événement
with urllib.request.urlopen(f"{base}?watch=true&resourceVersion={rv}") as flux:
    for ligne in flux:
        ev = json.loads(ligne)
        obj = ev["object"]
        print(ev["type"], obj["metadata"]["name"], obj["metadata"].get("resourceVersion"), flush=True)
```

```bash
kubectl proxy --port=8011 &
python3 surveiller.py ch34 &
kubectl create configmap essai --from-literal=a=1
kubectl label configmap essai vu=oui
kubectl delete configmap essai
```

```sortie
8 ConfigMap(s) à la version 94476
ADDED essai 94484
MODIFIED essai 94485
DELETED essai 94486
```

C'est, en vingt lignes, le schéma « list puis watch » de tous les contrôleurs : une liste pour l'état complet, un watch qui repart de la version de cette liste, pour ne manquer aucun changement survenu entre les deux. Les trois événements se suivent (94484, 94485, 94486), mais il y a un trou entre la liste (94476) et la création (94484). Ces huit versions n'ont pas été perdues : elles ont servi à d'autres objets, ailleurs dans le cluster. La `resourceVersion` n'est pas un compteur propre à chaque objet, mais un compteur **global**, qui avance à chaque écriture dans tout le cluster (renouvellement d'un bail, statut d'un Pod, événement). Le chapitre 35 montre qu'il s'agit du numéro de révision d'etcd. Il manque à ce client ce qui en ferait un vrai : reprendre le watch quand la connexion se coupe (l'API server la ferme au bout de quelques minutes), et tout relister s'il reçoit un `410`. C'est exactement ce que font les informers de client-go, au chapitre 36.

</details>

## Nettoyer

```bash
kill %1 %2 2>/dev/null    # kubectl proxy et le client Python, s'ils tournent encore
kubectl delete namespace ch34
kubectl config set-context --current --namespace=default
```

Le chapitre n'a rien installé d'autre : tout le reste était des requêtes.

[^borg]: Brendan Burns, Brian Grant, David Oppenheimer, Eric Brewer et John Wilkes, « Borg, Omega, and Kubernetes », *ACM Queue*, vol. 14, n° 1, 2016, section consacrée à Kubernetes et à son API. [queue.acm.org/detail.cfm?id=2898444](https://queue.acm.org/detail.cfm?id=2898444)

[^versions]: Kubernetes, « API Overview », section *API versioning*, et « Kubernetes Deprecation Policy ». [kubernetes.io/docs/reference/using-api](https://kubernetes.io/docs/reference/using-api/), [kubernetes.io/docs/reference/using-api/deprecation-policy](https://kubernetes.io/docs/reference/using-api/deprecation-policy/)

[^v116]: Kubernetes Blog, « Deprecated APIs Removed In 1.16: Here's What You Need To Know », 18 juillet 2019. [kubernetes.io/blog/2019/07/18/api-deprecations-in-1-16](https://kubernetes.io/blog/2019/07/18/api-deprecations-in-1-16/)

[^concepts]: Kubernetes, « Kubernetes API Concepts » : verbes, watch et code 410, *Retrieving large results sets in chunks*, *Receiving resources as Tables*, *Streaming lists*. [kubernetes.io/docs/reference/using-api/api-concepts](https://kubernetes.io/docs/reference/using-api/api-concepts/)

[^patch]: IETF, RFC 7386, « JSON Merge Patch », 2014, et RFC 6902, « JavaScript Object Notation (JSON) Patch », 2013 ; Kubernetes, « Update API Objects in Place Using kubectl patch », pour le strategic merge patch. [rfc-editor.org/rfc/rfc7386](https://www.rfc-editor.org/rfc/rfc7386), [rfc-editor.org/rfc/rfc6902](https://www.rfc-editor.org/rfc/rfc6902), [kubernetes.io/docs/tasks/manage-kubernetes-objects/update-api-object-kubectl-patch](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/update-api-object-kubectl-patch/)

[^acces]: Kubernetes, « Controlling Access to the Kubernetes API ». [kubernetes.io/docs/concepts/security/controlling-access](https://kubernetes.io/docs/concepts/security/controlling-access/)

[^admission]: Kubernetes, « Admission Control in Kubernetes », qui décrit chaque contrôleur d'admission et donne la liste de ceux activés par défaut. [kubernetes.io/docs/reference/access-authn-authz/admission-controllers](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/)

[^agregation]: Kubernetes, « Kubernetes API Aggregation Layer ». [kubernetes.io/docs/concepts/extend-kubernetes/api-extension/apiserver-aggregation](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/apiserver-aggregation/)

[^ssa]: Kubernetes, « Server-Side Apply », sections *Field management*, *Conflicts* et *Transferring ownership* ; proposition d'origine : KEP-555, « Server-side apply ». [kubernetes.io/docs/reference/using-api/server-side-apply](https://kubernetes.io/docs/reference/using-api/server-side-apply/), [github.com/kubernetes/enhancements/tree/master/keps/sig-api-machinery/555-server-side-apply](https://github.com/kubernetes/enhancements/tree/master/keps/sig-api-machinery/555-server-side-apply)

[^sante]: Kubernetes, « Kubernetes API health endpoints ». [kubernetes.io/docs/reference/using-api/health-checks](https://kubernetes.io/docs/reference/using-api/health-checks/)

[^apf]: Kubernetes, « API Priority and Fairness ». [kubernetes.io/docs/concepts/cluster-administration/flow-control](https://kubernetes.io/docs/concepts/cluster-administration/flow-control/)
