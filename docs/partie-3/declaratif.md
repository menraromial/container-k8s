---
title: Décrire plutôt qu'ordonner
sidebar_label: 18. Décrire plutôt qu'ordonner
description: "Le YAML et ses pièges, les trois façons de gérer des objets, kubectl apply et sa comparaison à trois voies, diff et dry-run, le server-side apply et ses conflits ; les étiquettes et les sélecteurs, les annotations, les namespaces."
partie: 3
chapitre: '18'
---

import applyTroisVoies from '@site/src/figures/apply-trois-voies.svg';
import selecteurs from '@site/src/figures/selecteurs.svg';

Un vendredi soir, une application ralentit, et quelqu'un de l'équipe tape `kubectl scale deployment api --replicas=10`. Le problème se calme. Le lundi, une autre personne déploie une nouvelle version depuis le dépôt Git, où le fichier dit toujours `replicas: 3`. Que devient le correctif du vendredi ? Et comment l'aurait-on su ?

Toute la question est de savoir où se trouve la vérité sur ce qui doit tourner : dans la mémoire de ceux qui ont tapé des commandes, ou dans des fichiers qu'on peut relire, comparer et versionner. Kubernetes permet les deux, mais il a été pensé pour la seconde. Ce chapitre apprend à écrire l'état désiré dans des fichiers, à le faire appliquer par `kubectl apply`, et à organiser les objets avec des étiquettes et des namespaces.

Les fichiers du chapitre sont dans [l'archive manifestes](pathname:///kits/manifestes.tar.gz). Travaillez dans une copie : certains exemples modifient les fichiers.

## Le YAML sans douleur

Un manifeste est écrit en **YAML**, un format de données pensé pour être lu par des humains. kubectl le convertit en JSON avant de l'envoyer à l'API server, et c'est sous cette forme que l'objet est validé. Tout ce qu'il faut savoir du YAML pour Kubernetes tient en quatre règles :

- l'**indentation** donne la structure : deux espaces par niveau, jamais de tabulation ;
- `clé: valeur` définit un champ ; une valeur peut être un texte, un nombre, un booléen, ou un bloc indenté en dessous ;
- un tiret `- ` en début de ligne marque un élément de liste ;
- `---` sépare plusieurs objets dans un même fichier.

Chaque règle a son piège, et chaque piège son message d'erreur. Le kit en contient cinq, dans le dossier `pieges`. Essayez-les tous :

```bash
kubectl create namespace ch18p
for f in tabulation nombre booleen faute indentation; do
  echo "--- $f"; kubectl -n ch18p apply -f pieges/$f.yaml
done
```

```sortie
--- tabulation
error: error parsing tabulation.yaml: error converting YAML to JSON: yaml: line 7: found character that cannot start any token
--- nombre
Error from server (BadRequest): error when creating "nombre.yaml": Pod in version "v1" cannot be handled as a Pod: json: cannot unmarshal number into Go struct field EnvVar.spec.containers.env.value of type string
--- booleen
error: unable to decode "booleen.yaml": json: cannot unmarshal bool into Go struct field ObjectMeta.metadata.labels of type string
--- faute
Error from server (BadRequest): error when creating "faute.yaml": Pod in version "v1" cannot be handled as a Pod: strict decoding error: unknown field "spec.containers[0].imagee"
--- indentation
Error from server (BadRequest): error when creating "indentation.yaml": Pod in version "v1" cannot be handled as a Pod: strict decoding error: unknown field "spec.image"
```

Cinq échecs, et aucun objet créé. Les messages sont moins obscurs qu'il n'y paraît :

- **`found character that cannot start any token`** : une tabulation à la ligne 7. Le YAML les interdit pour l'indentation[^yaml]. Un éditeur configuré pour insérer des espaces règle le problème une fois pour toutes ;
- **`cannot unmarshal number ... of type string`** : `value: 1.30` a été lu comme le nombre 1,3, alors que la valeur d'une variable d'environnement doit être un texte. Il fallait écrire `value: "1.30"` ;
- **`cannot unmarshal bool ... labels of type string`** : l'étiquette `expose: yes`. Dans la version 1.1 du YAML, que la bibliothèque utilisée par Kubernetes suit sur ce point, `yes`, `no`, `on` et `off` sont des booléens[^yaml-bool]. Les valeurs d'étiquettes doivent être des textes : `expose: "yes"` ;
- **`unknown field "spec.containers[0].imagee"`** : une faute de frappe. Depuis Kubernetes 1.27, kubectl demande par défaut à l'API server une validation stricte (`strict decoding`) : un champ inconnu fait refuser l'objet, alors qu'il était autrefois ignoré en silence, si bien qu'une faute de frappe sur un champ facultatif passait inaperçue ;
- **`unknown field "spec.image"`** : le plus trompeur. La ligne `image:` est indentée au niveau de `- name: web` au lieu d'être sous lui : elle est devenue un champ de `spec`, pas du conteneur. Le chemin du champ inconnu dit où l'API server l'a trouvé ; c'est le premier indice pour une erreur d'indentation.

Remarquez que deux erreurs viennent de kubectl (`error:` au début), qui n'a même pas pu lire le fichier, et trois de l'API server (`Error from server`). `kubectl explain` du chapitre 16 et l'option `--dry-run=server`, plus bas, permettent de les attraper avant d'agir pour de bon.

## Trois façons de gérer des objets

Kubernetes distingue trois manières de créer et de modifier des objets[^gestion] :

- les **commandes impératives** : `kubectl create deployment`, `kubectl scale`, `kubectl set image`. Rapides, pratiques pour essayer, mais elles ne laissent aucune trace de ce qui a été fait ;
- la **configuration impérative** : `kubectl create -f fichier.yaml`, `kubectl replace -f`, `kubectl delete -f`. L'objet est décrit dans un fichier, mais c'est vous qui choisissez l'opération : créer, remplacer, supprimer ;
- la **configuration déclarative** : `kubectl apply -f fichier.yaml` (ou un dossier entier). Vous ne dites pas quoi faire, seulement ce qui doit exister ; kubectl calcule s'il faut créer, modifier ou ne rien faire.

La première et la troisième ne se mélangent pas bien, comme on va le voir. Les équipes qui travaillent sérieusement avec Kubernetes gardent leurs manifestes dans Git et n'agissent que par `kubectl apply`, ou par un outil qui le fait pour elles (Argo CD, au chapitre 57).

## kubectl apply

Voici le manifeste du chapitre. Il contient deux objets, un namespace et un Deployment, séparés par `---` :

```yaml title="vitrine.yaml"
apiVersion: v1
kind: Namespace
metadata:
  name: ch18
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vitrine
  namespace: ch18
  labels:
    app.kubernetes.io/name: vitrine
    app.kubernetes.io/part-of: colis
  annotations:
    colis.example/responsable: "equipe-web"
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: vitrine
  template:
    metadata:
      labels:
        app.kubernetes.io/name: vitrine
        app.kubernetes.io/part-of: colis
    spec:
      containers:
      - name: nginx
        image: nginx:1.30-alpine
```

Le Deployment précise son namespace dans ses `metadata` : le fichier se suffit à lui-même, quel que soit le namespace par défaut de votre contexte. Sa `spec.template` est un modèle de Pod, avec exactement la forme des Pods du chapitre 17 ; le chapitre 19 détaillera le reste. Appliquons-le deux fois de suite :

```bash
kubectl apply -f vitrine.yaml
kubectl -n ch18 rollout status deployment/vitrine
kubectl apply -f vitrine.yaml
```

```sortie
namespace/ch18 created
deployment.apps/vitrine created
Waiting for deployment "vitrine" rollout to finish: 0 out of 2 new replicas have been updated...
Waiting for deployment "vitrine" rollout to finish: 0 of 2 updated replicas are available...
Waiting for deployment "vitrine" rollout to finish: 1 of 2 updated replicas are available...
deployment "vitrine" successfully rolled out
namespace/ch18 unchanged
deployment.apps/vitrine unchanged
```

La première fois, `created` ; la seconde, `unchanged`. `apply` est **idempotent** : l'appliquer dix fois donne le même résultat que l'appliquer une fois. On peut donc le relancer sans crainte, après chaque modification du fichier, ou périodiquement pour s'assurer que le cluster correspond au dépôt.

### Voir avant d'agir

Changeons le nombre de répliques dans le fichier, et demandons à `kubectl diff` ce qu'`apply` ferait :

```bash
sed -i 's/replicas: 2/replicas: 3/' vitrine.yaml
kubectl diff -f vitrine.yaml; echo code=$?
kubectl apply -f vitrine.yaml
```

```sortie
diff -u -N /tmp/LIVE-1956796503/apps.v1.Deployment.ch18.vitrine /tmp/MERGED-3668599588/apps.v1.Deployment.ch18.vitrine
--- /tmp/LIVE-1956796503/apps.v1.Deployment.ch18.vitrine	2026-09-26 07:12:37.122270267 +0200
+++ /tmp/MERGED-3668599588/apps.v1.Deployment.ch18.vitrine	2026-09-26 07:12:37.122270267 +0200
@@ -7,7 +7,7 @@
...
   creationTimestamp: "2026-09-26T05:12:35Z"
-  generation: 1
+  generation: 2
   labels:
     app.kubernetes.io/name: vitrine
     app.kubernetes.io/part-of: colis
@@ -17,7 +17,7 @@
   uid: 39911a81-9a29-41f7-b788-c3da25ac804e
 spec:
   progressDeadlineSeconds: 600
-  replicas: 2
+  replicas: 3
   revisionHistoryLimit: 10
   selector:
     matchLabels:
code=1
namespace/ch18 unchanged
deployment.apps/vitrine configured
```

`kubectl diff` compare l'objet réel (`LIVE`) à ce qu'il deviendrait après `apply` (`MERGED`), calculé par l'API server lui-même, sans rien modifier. Le code de sortie 1 signifie « il y a des différences » (0 : aucune ; au-delà : une erreur), ce qui permet de s'en servir dans un script. Au passage, on voit `generation` passer de 1 à 2 : l'API server incrémente ce compteur à chaque modification de la `spec`, et le contrôleur note dans `status.observedGeneration` la dernière génération qu'il a prise en compte.

### La dérive

Revenons au vendredi soir. Quelqu'un modifie l'objet sans passer par le fichier :

```bash
kubectl -n ch18 scale deployment vitrine --replicas=5
kubectl diff -f vitrine.yaml | grep -E '^[-+] '
kubectl apply -f vitrine.yaml
kubectl -n ch18 get deployment vitrine
```

```sortie
deployment.apps/vitrine scaled
-  generation: 3
+  generation: 4
-  replicas: 5
+  replicas: 3
namespace/ch18 unchanged
deployment.apps/vitrine configured
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
vitrine   3/3     3            3           8s
```

L'objet réel s'est écarté du fichier : c'est une **dérive** (*drift*). `kubectl diff` la détecte, et le prochain `apply` la fait disparaître, en ramenant le Deployment à trois répliques. C'est la réponse à la question du début : le correctif du vendredi est perdu lundi, sans avertissement, sauf si quelqu'un a lancé `kubectl diff`. La leçon n'est pas de s'interdire `kubectl scale` en urgence, mais de reporter aussitôt le changement dans le fichier.

### Supprimer un champ

Que se passe-t-il si l'on retire un champ du fichier ? Supprimons l'annotation `colis.example/responsable` :

```bash
sed -i '/annotations:/d; /colis.example\/responsable/d' vitrine.yaml
kubectl apply -f vitrine.yaml
kubectl -n ch18 get deployment vitrine -o jsonpath='{.metadata.annotations}' | jq -c 'del(."kubectl.kubernetes.io/last-applied-configuration")'
```

```sortie
namespace/ch18 unchanged
deployment.apps/vitrine configured
{"deployment.kubernetes.io/revision":"1"}
```

L'annotation a disparu de l'objet. Mais une autre annotation, `deployment.kubernetes.io/revision`, que le fichier n'a jamais contenue, est restée. Comment `apply` fait-il la différence entre « un champ que j'ai retiré du fichier » et « un champ que quelqu'un d'autre a ajouté » ? Grâce à une troisième source. À chaque application, kubectl range une copie du fichier dans une annotation de l'objet, `kubectl.kubernetes.io/last-applied-configuration` :

```bash
kubectl -n ch18 get deployment vitrine -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' | jq -c .
```

```sortie
{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"annotations":{"colis.example/responsable":"equipe-web"},"labels":{"app.kubernetes.io/name":"vitrine","app.kubernetes.io/part-of":"colis"},"name":"vitrine","namespace":"ch18"},"spec":{"replicas":2,...
```

(Cette sortie a été relevée juste après la première application, d'où `replicas: 2`.) `apply` compare donc **trois** versions : le fichier (ce que vous voulez maintenant), la dernière application (ce que vous vouliez avant), et l'objet réel (ce qui existe, avec les modifications des autres). Un champ présent dans la dernière application et absent du fichier a été retiré par vous : il faut le supprimer. Un champ absent des deux n'est pas à vous : on n'y touche pas. Un champ présent dans le fichier et différent du réel doit être rétabli[^declaratif].

<Figure svg={applyTroisVoies} num="18.1" alt="Trois sources entrent dans kubectl apply. Le fichier vitrine.yaml, ce que vous voulez maintenant : replicas 3, annotation retirée. La dernière application, dans l'annotation last-applied-configuration, ce que vous vouliez avant : replicas 3, responsable equipe-web. L'objet réel dans le cluster : replicas 5 après kubectl scale, responsable equipe-web, revision 1 ajoutée par le contrôleur. kubectl apply compare les trois et envoie un correctif PATCH : replicas de 5 à 3, parce que le fichier diffère du réel ; responsable supprimée, parce qu'elle était appliquée et n'est plus dans le fichier ; revision gardée, parce que vous ne l'avez jamais appliquée.">
La comparaison à trois voies de <code>kubectl apply</code>, illustrée par les deux cas de ce chapitre réunis : la dérive corrigée et l'annotation retirée.
</Figure>

C'est aussi pourquoi `apply` et les commandes impératives cohabitent mal. `kubectl create -f`, par exemple, refuse un objet qui existe déjà, et crée un objet sans l'annotation dont `apply` a besoin :

```bash
kubectl create -f vitrine.yaml
```

```sortie
Error from server (AlreadyExists): error when creating "vitrine.yaml": namespaces "ch18" already exists
Error from server (AlreadyExists): error when creating "vitrine.yaml": deployments.apps "vitrine" already exists
```

### Vérifier sans rien changer

Deux options de simulation complètent `diff`. `--dry-run=client` fait travailler kubectl seul, sans contacter le cluster, et sert surtout à **générer** un manifeste à partir d'une commande impérative, qu'on range ensuite dans un fichier :

```bash
kubectl create deployment api --image=localhost:5001/colis/api:2.0 --replicas=2 --port=8000 --dry-run=client -o yaml
```

```sortie
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: api
  name: api
spec:
  replicas: 2
  selector:
    matchLabels:
      app: api
  strategy: {}
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
      - image: localhost:5001/colis/api:2.0
        name: api
        ports:
        - containerPort: 8000
        resources: {}
status: {}
```

C'est la façon la plus rapide d'écrire un premier manifeste sans faute de structure ; on retire ensuite les champs vides (`strategy: {}`, `resources: {}`, `status: {}`). `--dry-run=server` va plus loin : il envoie l'objet à l'API server, qui le valide et le fait passer par toutes les étapes du chapitre 16 (authentification, autorisation, admission), sans l'enregistrer :

```bash
kubectl apply -f vitrine.yaml --dry-run=server
kubectl -n ch18 apply -f pieges/faute.yaml --dry-run=server
```

```sortie
namespace/ch18 unchanged (server dry run)
deployment.apps/vitrine unchanged (server dry run)
Error from server (BadRequest): error when creating "faute.yaml": Pod in version "v1" cannot be handled as a Pod: strict decoding error: unknown field "spec.containers[0].imagee"
```

### Le server-side apply

La comparaison à trois voies a une faiblesse : elle se fait dans kubectl, et l'annotation `last-applied-configuration` ne connaît qu'un seul auteur. Depuis Kubernetes 1.22, l'API server sait faire ce travail lui-même : c'est le **server-side apply**, activé par l'option `--server-side`[^ssa]. Il ne garde plus une copie du fichier, mais note pour chaque champ de l'objet quel « gestionnaire » (*manager*) l'a écrit en dernier, dans les `managedFields` du chapitre 16. Et il refuse qu'un gestionnaire écrase sans le dire un champ qui appartient à un autre. Reprenons la dérive, en mode serveur :

```bash
kubectl delete -f vitrine.yaml
kubectl apply --server-side -f vitrine.yaml
kubectl -n ch18 scale deployment vitrine --replicas=4
kubectl apply --server-side -f vitrine.yaml; echo code=$?
```

```sortie
namespace/ch18 serverside-applied
deployment.apps/vitrine serverside-applied
deployment.apps/vitrine scaled
namespace/ch18 serverside-applied
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
code=1
```

Cette fois, la dérive n'est pas écrasée en silence : l'API server signale un **conflit** sur `.spec.replicas`, qui appartient désormais à `kubectl scale`. Les gestionnaires de chaque champ se lisent dans l'objet :

```bash
kubectl -n ch18 get deployment vitrine -o json --show-managed-fields | jq -r '.metadata.managedFields[] | "\(.manager)\t\(.operation)\t\(.fieldsV1 | tostring | .[0:90])"'
```

```sortie
kubectl	Apply	{"f:metadata":{"f:labels":{"f:app.kubernetes.io/name":{},"f:app.kubernetes.io/part-of":{}}
kubectl	Update	{"f:spec":{"f:replicas":{}}}
kube-controller-manager	Update	{"f:metadata":{"f:annotations":{".":{},"f:deployment.kubernetes.io/revision":{}}},"f:statu
```

Trois gestionnaires : votre `apply`, la modification de `scale` qui ne porte que sur `replicas`, et le contrôleur, qui possède l'annotation de révision et le `status`. Le message propose trois sorties : forcer (`--force-conflicts`, et le fichier reprend la main sur le champ), retirer `replicas` du fichier (et laisser un autre outil le gérer, un autoscaler par exemple, au chapitre 31), ou aligner le fichier sur la valeur réelle. C'est ce qu'on attend d'un outil de travail en équipe : on sait qui a changé quoi, et un conflit se décide au lieu de se subir. Le server-side apply est la manière recommandée pour tout nouvel outil, et c'est celle qu'utilisent Argo CD et beaucoup de contrôleurs.

Terminez en supprimant tout ce que le fichier décrit :

```bash
kubectl delete -f vitrine.yaml
```

```sortie
namespace "ch18" deleted
deployment.apps "vitrine" deleted from ch18 namespace
```

## Étiquettes et sélecteurs

Le chapitre 15 a montré qu'un ReplicaSet reconnaît ses Pods à leurs étiquettes. Les **étiquettes** (*labels*) sont des paires clé-valeur attachées à un objet, et le principal moyen de regrouper des objets dans Kubernetes : un Service trouvera ses Pods par leurs étiquettes, un Deployment les siens, et vous aussi, pour lister ou supprimer d'un coup tous les objets d'une application[^labels].

Créons cinq Pods aux étiquettes variées, dans un namespace dédié. `kubectl run` crée un Pod seul, et `--labels` lui donne des étiquettes :

```bash
kubectl create namespace ch18-a
kubectl -n ch18-a run web-dev  --image=nginx:1.30-alpine --labels=app=web,env=dev,tier=front
kubectl -n ch18-a run web-prod --image=nginx:1.30-alpine --labels=app=web,env=prod,tier=front
kubectl -n ch18-a run api-dev  --image=nginx:1.30-alpine --labels=app=api,env=dev,tier=back
kubectl -n ch18-a run api-prod --image=nginx:1.30-alpine --labels=app=api,env=prod,tier=back
kubectl -n ch18-a run outil    --image=nginx:1.30-alpine --labels=app=outil
kubectl -n ch18-a get pods --show-labels
```

```sortie
NAME       READY   STATUS              RESTARTS   AGE   LABELS
api-dev    0/1     ContainerCreating   0          1s    app=api,env=dev,tier=back
api-prod   0/1     ContainerCreating   0          1s    app=api,env=prod,tier=back
outil      0/1     ContainerCreating   0          1s    app=outil
web-dev    0/1     ContainerCreating   0          1s    app=web,env=dev,tier=front
web-prod   0/1     ContainerCreating   0          1s    app=web,env=prod,tier=front
```

Un **sélecteur**, donné par l'option `-l`, filtre les objets par leurs étiquettes. Il en existe deux formes. Les sélecteurs d'**égalité** comparent une valeur (`=`, `==`, `!=`) ; les sélecteurs d'**ensemble** testent l'appartenance à une liste (`in`, `notin`) ou la simple présence d'une clé (`env`, `!env`). Plusieurs conditions séparées par des virgules doivent toutes être vraies :

```bash
kubectl -n ch18-a get pods -l env=prod
kubectl -n ch18-a get pods -l 'env in (dev,prod),tier!=back'
kubectl -n ch18-a get pods -l '!env'
```

```sortie
NAME       READY   STATUS              RESTARTS   AGE
api-prod   0/1     ContainerCreating   0          1s
web-prod   0/1     ContainerCreating   0          1s

NAME       READY   STATUS              RESTARTS   AGE
web-dev    0/1     ContainerCreating   0          1s
web-prod   0/1     ContainerCreating   0          1s

NAME    READY   STATUS              RESTARTS   AGE
outil   0/1     ContainerCreating   0          1s
```

Les guillemets simples protègent les parenthèses et le point d'exclamation du shell. `-L` affiche des étiquettes en colonnes :

```bash
kubectl -n ch18-a get pods -L app,env
```

```sortie
NAME       READY   STATUS              RESTARTS   AGE   APP     ENV
api-dev    0/1     ContainerCreating   0          1s    api     dev
api-prod   0/1     ContainerCreating   0          1s    api     prod
outil      0/1     ContainerCreating   0          1s    outil
web-dev    0/1     ContainerCreating   0          1s    web     dev
web-prod   0/1     ContainerCreating   0          1s    web     prod
```

<Figure svg={selecteurs} num="18.2" alt="Cinq Pods et leurs étiquettes : web-dev (app=web, env=dev, tier=front), web-prod (app=web, env=prod, tier=front), api-dev (app=api, env=dev, tier=back), api-prod (app=api, env=prod, tier=back), outil (app=outil). Le sélecteur env=prod retient web-prod et api-prod. Le sélecteur env in (dev,prod),tier!=back retient web-dev et web-prod. Le sélecteur !env retient outil.">
Trois sélecteurs appliqués aux cinq Pods du chapitre. Un point plein marque un Pod retenu.
</Figure>

`kubectl label` ajoute, modifie ou retire une étiquette. Il refuse de changer une valeur existante sans `--overwrite`, et un tiret final retire la clé :

```bash
kubectl -n ch18-a label pod outil env=dev
kubectl -n ch18-a label pod outil env=prod
kubectl -n ch18-a label pod outil env=prod --overwrite
kubectl -n ch18-a label pod outil env-
kubectl -n ch18-a get pod outil --show-labels
```

```sortie
pod/outil labeled
error: 'env' already has a value (dev), and --overwrite is false
pod/outil labeled
pod/outil unlabeled
NAME    READY   STATUS    RESTARTS   AGE   LABELS
outil   1/1     Running   0          1s    app=outil
```

Une clé d'étiquette peut avoir un préfixe, séparé par une barre oblique : un nom de domaine qui dit qui a défini l'étiquette, comme `app.kubernetes.io/name` dans `vitrine.yaml`. Le préfixe `kubernetes.io` est réservé au projet. Le nom lui-même compte au plus 63 caractères, et la valeur aussi. Kubernetes recommande un jeu d'étiquettes communes, `app.kubernetes.io/name`, `app.kubernetes.io/instance`, `app.kubernetes.io/version`, `app.kubernetes.io/component`, `app.kubernetes.io/part-of`, `app.kubernetes.io/managed-by`, que les outils comme Helm (chapitre 29) posent d'eux-mêmes[^etiquettes-communes]. Les adopter dès le début rend les objets lisibles par tous les outils de l'écosystème.

## Les annotations

Les **annotations** ressemblent aux étiquettes, clé-valeur, mêmes règles de préfixe, mais servent à autre chose : elles portent des informations **sur** l'objet, destinées aux humains et aux outils, et ne servent jamais à sélectionner[^annotations]. Leur valeur peut être longue (jusqu'à 256 Kio pour l'ensemble des annotations d'un objet) et contenir n'importe quel texte :

```bash
kubectl -n ch18-a annotate pod web-prod colis.example/ticket='OPS-1234' colis.example/note='redémarré après incident'
kubectl -n ch18-a get pod web-prod -o jsonpath='{.metadata.annotations}' | jq .
kubectl -n ch18-a get pods -l colis.example/ticket=OPS-1234
```

```sortie
pod/web-prod annotated
{
  "colis.example/note": "redémarré après incident",
  "colis.example/ticket": "OPS-1234"
}
No resources found in ch18-a namespace.
```

La dernière commande le prouve : un sélecteur ne voit pas les annotations. Vous en avez déjà croisé plusieurs, écrites par Kubernetes lui-même : `last-applied-configuration`, `deployment.kubernetes.io/revision`. La règle pour choisir : une étiquette si l'on doit un jour filtrer sur cette information, une annotation sinon.

## Les namespaces

Les **namespaces** partagent un cluster en espaces séparés : les noms d'objets doivent être uniques dans un namespace, pas entre namespaces, et beaucoup de réglages (droits d'accès au chapitre 43, quotas au chapitre 23) s'y appliquent[^namespaces]. Un cluster neuf en contient quatre :

```bash
kubectl get namespaces
```

```sortie
NAME              STATUS   AGE
default           Active   20h
kube-node-lease   Active   20h
kube-public       Active   20h
kube-system       Active   20h
```

`default` accueille les objets créés sans namespace précis ; `kube-system`, les composants de Kubernetes (chapitre 15) ; `kube-node-lease`, les baux des kubelets (exercice 4 du chapitre 15) ; `kube-public`, quelques informations lisibles par tous, même sans authentification. (La sortie relevée contenait aussi les namespaces de ce chapitre, retirés ici.) Le même nom peut exister dans deux namespaces :

```bash
kubectl create namespace ch18-b
kubectl -n ch18-b run web-prod --image=nginx:1.30-alpine
kubectl get pods -A --field-selector metadata.name=web-prod
```

```sortie
NAMESPACE   NAME       READY   STATUS              RESTARTS   AGE
ch18-a      web-prod   1/1     Running             0          2s
ch18-b      web-prod   0/1     ContainerCreating   0          0s
```

(`--field-selector` filtre sur quelques champs des objets, et non sur leurs étiquettes.) Tous les objets ne vivent pas dans un namespace : les nœuds, les namespaces eux-mêmes, les volumes persistants sont communs au cluster, comme l'a montré `kubectl api-resources --namespaced=false` au chapitre 16.

Supprimer un namespace supprime tout ce qu'il contient. L'opération n'est pas instantanée : le namespace passe `Terminating`, le temps que chaque objet soit supprimé, puis disparaît :

```bash
kubectl delete namespace ch18-a --wait=false
kubectl get namespace ch18-a
kubectl wait --for=delete namespace/ch18-a --timeout=120s
kubectl get namespace ch18-a
```

```sortie
namespace "ch18-a" deleted
NAME     STATUS        AGE
ch18-a   Terminating   3s
namespace/ch18-a condition met
Error from server (NotFound): namespaces "ch18-a" not found
```

C'est pratique pour faire le ménage (c'est ce que font les sections « Nettoyer » de cette partie), et dangereux pour la même raison : un `kubectl delete namespace` sur le mauvais cluster emporte une application entière. Un namespace n'isole pas les Pods entre eux sur le réseau (un Pod peut joindre un Pod d'un autre namespace, sauf règle contraire, au chapitre 41), et ne protège pas contre le voisin qui consomme toute la mémoire (sauf quota) : c'est d'abord une frontière de noms et d'organisation.

## Exercices

:::exercice[Exercice 1 : réparer les pièges]

Corrigez les cinq fichiers du dossier `pieges` pour que chacun crée son Pod dans le namespace `ch18p`. Vérifiez chaque correction avec `kubectl apply --dry-run=server` avant de l'appliquer pour de bon. Pour `nombre.yaml`, que vaut la variable `VERSION` dans le conteneur une fois corrigée ?

:::

<details>
<summary>Corrigé</summary>

Les cinq corrections :

- `tabulation.yaml` : remplacer les tabulations des lignes 7 et 8 par des espaces (`sed -i 's/\t/  /g' tabulation.yaml` le fait d'un coup) ;
- `nombre.yaml` : `value: "1.30"` ;
- `booleen.yaml` : `expose: "yes"` ;
- `faute.yaml` : `image:` au lieu de `imagee:` ;
- `indentation.yaml` : indenter `image:` de deux espaces de plus, au niveau de `name:`.

```bash
for f in tabulation nombre booleen faute indentation; do kubectl -n ch18p apply -f pieges/$f.yaml --dry-run=server; done
kubectl -n ch18p apply -f pieges/
kubectl -n ch18p exec nombre -- printenv VERSION
```

Avec les guillemets, `VERSION` vaut `1.30`, exactement. `kubectl apply -f pieges/` applique tous les fichiers d'un dossier d'un coup ; dans un vrai dépôt, un dossier par application ou par composant est une organisation courante.

</details>

:::exercice[Exercice 2 : étiqueter en masse]

Dans un namespace `ch18x`, créez trois Pods (`web-dev`, `web-prod`, `api-dev`) avec des étiquettes `app` et `env`. Ajoutez d'une seule commande l'étiquette `colis.example/equipe=plateforme` à tous les Pods du namespace, puis affichez ceux qui ne sont **pas** en production, avec leurs étiquettes `env` et `colis.example/equipe` en colonnes.

:::

<details>
<summary>Corrigé</summary>

```bash
kubectl create namespace ch18x
kubectl -n ch18x run web-dev  --image=nginx:1.30-alpine --labels=app=web,env=dev
kubectl -n ch18x run web-prod --image=nginx:1.30-alpine --labels=app=web,env=prod
kubectl -n ch18x run api-dev  --image=nginx:1.30-alpine --labels=app=api,env=dev
kubectl -n ch18x label pods --all colis.example/equipe=plateforme
kubectl -n ch18x get pods -l 'env notin (prod)' -L env,colis.example/equipe
```

```sortie
pod/api-dev labeled
pod/web-dev labeled
pod/web-prod labeled
NAME      READY   STATUS              RESTARTS   AGE   ENV   EQUIPE
api-dev   0/1     ContainerCreating   0          0s    dev   plateforme
web-dev   0/1     ContainerCreating   0          0s    dev   plateforme
```

`--all` applique la commande à tous les objets du type dans le namespace ; `-l` aurait restreint à une sélection. `notin` retient aussi les objets qui n'ont pas du tout la clé `env` : pour exiger sa présence, on écrirait `env,env notin (prod)`. La colonne `-L` n'affiche que la dernière partie d'une clé à préfixe, en majuscules.

</details>

:::exercice[Exercice 3 : ce que -n ne change pas]

Dans le namespace `ch18x`, lancez `kubectl -n ch18x get nodes` et `kubectl -n ch18x get namespaces`. L'option `-n` a-t-elle un effet ? Pourquoi ? Quelle commande liste tous les types d'objets sur lesquels elle n'a aucun effet ?

:::

<details>
<summary>Corrigé</summary>

```bash
kubectl -n ch18x get nodes
kubectl -n ch18x get namespaces | head -3
```

```sortie
NAME       STATUS   ROLES           AGE   VERSION
minikube   Ready    control-plane   20h   v1.37.0
NAME              STATUS   AGE
ch18-b            Active   117s
ch18p             Active   2m8s
```

Aucun effet, et aucun message : les nœuds et les namespaces n'appartiennent à aucun namespace, et kubectl ignore simplement l'option. `kubectl api-resources --namespaced=false` en donne la liste complète. C'est une source de confusion classique quand on lit la sortie d'un script : un `-n` ne prouve pas que les objets listés viennent de ce namespace.

</details>

:::exercice[Exercice 4 : le correctif du vendredi]

Rejouez le scénario du début du chapitre avec `vitrine.yaml`, appliqué en mode client : un `kubectl scale` à 10 répliques, puis un `apply` du fichier. Quelles commandes auraient permis à l'équipe de voir, lundi matin, qu'un `apply` allait annuler le correctif ? Et quelles deux façons de travailler auraient évité le problème ?

:::

<details>
<summary>Corrigé</summary>

`kubectl diff -f vitrine.yaml` aurait montré `-  replicas: 10` et `+  replicas: 3`, avec un code de sortie 1 ; beaucoup d'équipes le lancent automatiquement avant chaque `apply`, et bloquent la livraison si des différences inattendues apparaissent. En mode serveur, `kubectl apply --server-side` aurait refusé d'écraser `replicas` et signalé le conflit avec `kubectl scale`, comme dans ce chapitre. Pour éviter le problème : reporter le correctif dans le fichier et le versionner (le fichier redevient la vérité), ou, si le nombre de répliques doit varier selon la charge, le retirer du fichier et en confier la gestion à un autoscaler (chapitre 31), qui en devient le gestionnaire officiel.

</details>

## Nettoyer

```bash
kubectl delete namespace ch18p ch18-b ch18x --ignore-not-found
```

[^yaml]: YAML Language Development Team, *YAML Ain't Markup Language (YAML) version 1.2.2*, section 6.1 *Indentation Spaces*. [yaml.org/spec/1.2.2](https://yaml.org/spec/1.2.2/#61-indentation-spaces)

[^yaml-bool]: YAML, « Boolean Language-Independent Type for YAML Version 1.1 ». [yaml.org/type/bool.html](https://yaml.org/type/bool.html)

[^gestion]: Kubernetes, « Kubernetes Object Management ». [kubernetes.io/docs/concepts/overview/working-with-objects/object-management](https://kubernetes.io/docs/concepts/overview/working-with-objects/object-management/)

[^declaratif]: Kubernetes, « Declarative Management of Kubernetes Objects Using Configuration Files », section *How apply calculates differences and merges changes*. [kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/)

[^ssa]: Kubernetes, « Server-Side Apply ». [kubernetes.io/docs/reference/using-api/server-side-apply](https://kubernetes.io/docs/reference/using-api/server-side-apply/)

[^labels]: Kubernetes, « Labels and Selectors ». [kubernetes.io/docs/concepts/overview/working-with-objects/labels](https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/)

[^etiquettes-communes]: Kubernetes, « Recommended Labels ». [kubernetes.io/docs/concepts/overview/working-with-objects/common-labels](https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/)

[^annotations]: Kubernetes, « Annotations ». [kubernetes.io/docs/concepts/overview/working-with-objects/annotations](https://kubernetes.io/docs/concepts/overview/working-with-objects/annotations/)

[^namespaces]: Kubernetes, « Namespaces ». [kubernetes.io/docs/concepts/overview/working-with-objects/namespaces](https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/)
