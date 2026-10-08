---
title: Les Custom Resource Definitions
sidebar_label: 54. Les CRD
description: "Ajouter un type à l'API de Kubernetes sans écrire de code : une CustomResourceDefinition pour le type Colis, son schéma OpenAPI, l'élagage et les valeurs par défaut, les règles CEL, les sous-ressources status et scale, les colonnes de kubectl, les versions et leur migration, les droits RBAC et ce que coûte une définition."
partie: 8
chapitre: '54'
---

import crdTrajet from '@site/src/figures/crd-trajet.svg';
import crdVersions from '@site/src/figures/crd-versions.svg';

Le cluster du cours sert 116 types d'objets. Les Pods, les Services, les Deployments en font partie depuis les premières versions de Kubernetes ; 43 autres sont arrivés au fil des parties, avec les outils qu'on a installés. `Gateway` et `HTTPRoute` viennent de Gateway API (chapitre 28), `Certificate` de cert-manager, `ScaledObject` de KEDA (chapitre 31), `ServiceMonitor` et `PrometheusRule` de l'opérateur Prometheus (chapitre 50). Aucun de ces outils n'a modifié l'API server. Chacun a créé un objet d'un type particulier, une **CustomResourceDefinition** (CRD), qui déclare un nouveau type ; l'API server l'a servi aussitôt, avec la même interface que les types d'origine : `kubectl get`, `apply`, `watch`, RBAC, validation, stockage dans etcd.

Ce chapitre écrit une de ces définitions, pour un type `Colis` qui décrit une installation complète de l'application : sa version, le nombre de répliques de l'API, les bornes du worker, la taille de la base. Une définition seule ne fait rien tourner. Elle donne un endroit où écrire ce qu'on veut, et des règles sur ce qu'on a le droit d'y écrire. Le programme qui lira ces objets et créera les Deployments correspondants, l'opérateur, est l'objet du chapitre 55. Tout ce qui suit a été joué sur le cluster principal, dans un namespace `ch54` ; les fichiers sont dans [l'archive crd](pathname:///kits/crd.tar.gz).

## Un type de plus en vingt lignes

Avant la définition, le type n'existe pas :

```bash
kubectl get colis
```

```sortie
error: the server doesn't have a resource type "colis"
```

La définition minimale tient en une vingtaine de lignes :

```yaml title="01-colis-minimal.yaml"
# Une première définition : le type Colis, sans autre règle que « spec est un objet ».
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: colis.cours.example.com        # <pluriel>.<groupe>, obligatoirement
spec:
  group: cours.example.com
  scope: Namespaced
  names:
    kind: Colis
    singular: colis
    plural: colis
    listKind: ColisList
  versions:
  - name: v1alpha1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            x-kubernetes-preserve-unknown-fields: true
```

Le nom de l'objet est imposé : le pluriel du type, un point, puis le groupe. Le groupe est un nom de domaine, pour que deux éditeurs ne se marchent pas dessus ; `example.com` est réservé à la documentation par la RFC 2606[^rfc2606], c'est donc lui qu'on prend pour un exemple. `scope: Namespaced` range chaque objet dans un namespace, comme un Deployment ; `Cluster` en ferait un objet global, comme un Node. Le pluriel est ici identique au singulier, ce que l'API accepte : le pluriel sert à l'URL, le singulier aux commandes, `kind` au champ du même nom dans les manifestes. Enfin, `versions` liste les versions de l'API du type ; une seule ici, `v1alpha1`, servie (on peut la lire et l'écrire) et stockée (c'est sous cette forme que les objets vont dans etcd).

Le schéma est réduit au strict minimum : un objet `spec` dont les champs ne sont pas décrits (`x-kubernetes-preserve-unknown-fields`). On y reviendra.

```bash
kubectl apply -f 01-colis-minimal.yaml
kubectl wait --for=condition=Established crd/colis.cours.example.com
kubectl get crd colis.cours.example.com -o json | jq -c '.status.conditions[] | {type, status, reason}'
```

```sortie
customresourcedefinition.apiextensions.k8s.io/colis.cours.example.com created
customresourcedefinition.apiextensions.k8s.io/colis.cours.example.com condition met
{"type":"NamesAccepted","status":"True","reason":"NoConflicts"}
{"type":"Established","status":"True","reason":"InitialNamesAccepted"}
```

Deux conditions. `NamesAccepted` dit qu'aucun autre type n'utilise déjà ces noms dans le groupe ; `Established` que l'API server sert le type, une fois ses points d'entrée installés. Entre la création de la définition et `Established`, le type n'existe pas encore pour les clients, ce qui piège un `kubectl apply` qui enchaîne une définition et un objet du nouveau type (on le verra en fin de chapitre). Le type apparaît dans la découverte, la liste que `kubectl` consulte pour savoir quels types existent et à quelle URL :

```bash
kubectl api-resources --api-group=cours.example.com
kubectl get --raw /apis/cours.example.com/v1alpha1 | jq -c '.resources[] | {name, namespaced, kind, verbs}'
```

```sortie
NAME    SHORTNAMES   APIVERSION                   NAMESPACED   KIND
colis                cours.example.com/v1alpha1   true         Colis
{"name":"colis","namespaced":true,"kind":"Colis","verbs":["delete","deletecollection","get","list","patch","create","update","watch"]}
```

Les huit verbes d'un type ordinaire, dont `watch`, sans une ligne de code. C'est l'API server lui-même qui sert les ressources personnalisées : il embarque un second serveur, `apiextensions-apiserver`, qui surveille les CRD et installe pour chacune un gestionnaire générique, capable de lire, valider et stocker n'importe quel objet JSON conforme au schéma déclaré[^ressources-perso].

Un premier objet :

```yaml title="principal.yaml"
apiVersion: cours.example.com/v1alpha1
kind: Colis
metadata:
  name: principal
  namespace: ch54
spec:
  version: 2.2.1
  api:
    replicas: 2
  worker:
    min: 0
    max: 5
  base:
    taille: 1Gi
```

```bash
kubectl create namespace ch54
kubectl apply -f principal.yaml
kubectl -n ch54 get colis
```

```sortie
namespace/ch54 created
colis.cours.example.com/principal created
NAME        AGE
principal   0s
```

Dans etcd, la clé suit le même schéma que pour les types d'origine, `/registry/<groupe>/<pluriel>/<namespace>/<nom>` :

```bash
C=/var/lib/minikube/certs/etcd
kubectl -n kube-system exec etcd-minikube -- etcdctl --cacert=$C/ca.crt --cert=$C/server.crt --key=$C/server.key \
  get /registry/cours.example.com/colis/ch54/principal --print-value-only | jq -c '{apiVersion, kind, spec}'
```

```sortie
{"apiVersion":"cours.example.com/v1alpha1","kind":"Colis","spec":{"api":{"replicas":2},"base":{"taille":"1Gi"},"version":"2.2.1","worker":{"max":5,"min":0}}}
```

L'objet est stocké en JSON lisible. Comparez avec un Pod de Colis, lu de la même façon :

```sortie
# même lecture, pour la clé /registry/pods/colis/api-5dd9fd6cdf-9k4gm
   k   8   s  \0  \n  \t  \n 002   v   1 022 003   P   o   d 022
 270   )  \n 253 034  \n 024   a   p   i   -   5   d   d   9   f
```

Le préfixe `k8s\0` annonce l'encodage Protobuf, que l'API server utilise pour les types compilés dans son code. Les ressources personnalisées n'ont pas de description Protobuf : elles restent en JSON, plus volumineux et plus lent à décoder, ce qui compte à partir de quelques dizaines de milliers d'objets[^api-concepts].

## Sans schéma, n'importe quoi passe

Le schéma minimal n'a qu'un défaut, mais il est de taille : il accepte tout. Une faute de frappe dans un nom de champ, une chaîne là où on attend un nombre :

```yaml title="mauvais.yaml"
apiVersion: cours.example.com/v1alpha1
kind: Colis
metadata:
  name: mauvais
  namespace: ch54
spec:
  version: 2.2.1
  api:
    replicas: beaucoup
  wroker:
    max: 5
```

```bash
kubectl apply -f mauvais.yaml
kubectl -n ch54 get colis mauvais -o jsonpath='{.spec}'
```

```sortie
colis.cours.example.com/mauvais created
{"api":{"replicas":"beaucoup"},"version":"2.2.1","wroker":{"max":5}}
```

L'objet est enregistré tel quel. Un opérateur qui lirait `spec.api.replicas` recevrait `"beaucoup"`, et `spec.worker` n'existe pas. Rien n'aurait prévenu l'auteur du manifeste. Le schéma OpenAPI de la définition sert à refuser ces objets à l'entrée, avant qu'un programme ne tombe dessus.

```yaml title="02-colis-schema.yaml"
# Le type Colis avec un schéma : types, bornes, motifs, valeurs par défaut.
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: colis.cours.example.com
spec:
  group: cours.example.com
  scope: Namespaced
  names:
    kind: Colis
    singular: colis
    plural: colis
    listKind: ColisList
  versions:
  - name: v1alpha1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        description: Une installation de l'application Colis.
        required: [spec]
        properties:
          spec:
            type: object
            required: [version]
            properties:
              version:
                type: string
                description: Version de l'image de l'API et du worker.
                pattern: '^[0-9]+\.[0-9]+\.[0-9]+$'
              api:
                type: object
                default: {}
                properties:
                  replicas:
                    type: integer
                    minimum: 1
                    maximum: 10
                    default: 2
              worker:
                type: object
                default: {}
                properties:
                  min:
                    type: integer
                    minimum: 0
                    default: 0
                  max:
                    type: integer
                    minimum: 1
                    maximum: 20
                    default: 5
              base:
                type: object
                default: {}
                properties:
                  taille:
                    type: string
                    default: 1Gi
                    pattern: '^[0-9]+(Mi|Gi)$'
                  classe:
                    type: string
                    enum: [standard, csi-hostpath-sc]
                    default: standard
```

Chaque champ a un type. Les entiers ont des bornes (`minimum`, `maximum`), les chaînes un motif (`pattern`, une expression rationnelle) ou une liste de valeurs permises (`enum`). `required` liste les champs obligatoires, et `default` donne la valeur d'un champ absent. Le `default: {}` des objets `api`, `worker` et `base` est nécessaire : sans lui, un manifeste qui ne mentionne pas `worker` n'aurait pas d'objet `worker`, et les valeurs par défaut de `min` et `max` ne s'appliqueraient pas.

Ce schéma est **structurel** : chaque champ est décrit avec son type, à chaque niveau. C'est obligatoire depuis la version `v1` de l'API des CRD, et c'est ce qui permet à l'API server d'élaguer les champs inconnus et d'appliquer les valeurs par défaut[^crd-tache].

### Ce que devient un objet déjà stocké

La définition change, l'objet `mauvais` reste dans etcd. Que voit-on en le relisant ?

```bash
kubectl apply -f 02-colis-schema.yaml
kubectl -n ch54 get colis mauvais -o jsonpath='{.spec}'
kubectl -n ch54 get colis principal -o jsonpath='{.spec}'
```

```sortie
customresourcedefinition.apiextensions.k8s.io/colis.cours.example.com configured
# mauvais, relu
{"api":{"replicas":"beaucoup"},"base":{"classe":"standard","taille":"1Gi"},"version":"2.2.1","worker":{"max":5,"min":0}}
# principal, relu
{"api":{"replicas":2},"base":{"classe":"standard","taille":"1Gi"},"version":"2.2.1","worker":{"max":5,"min":0}}
```

Trois choses se sont passées à la lecture, sans que l'objet soit réécrit. Le champ `wroker`, inconnu du schéma, a été élagué. Les valeurs par défaut (`base`, `worker`) ont été ajoutées. Et `"beaucoup"` est toujours là : l'API server ne valide pas ce qu'il lit, seulement ce qu'on lui écrit. L'objet `principal`, lui, a reçu `base.classe: standard`, qui n'était pas dans son manifeste.

Réappliquer `mauvais.yaml` tel quel :

```sortie
The request is invalid: patch: Invalid value: "...": strict decoding error: unknown field "spec.wroker"
```

Ce refus vient d'une option de `kubectl`. Par défaut, `kubectl apply` demande à l'API server une validation stricte des champs (`--validate=strict`) : un champ inconnu devient une erreur. Avec `--validate=false`, le champ est élagué sans un mot :

```bash
kubectl apply -f mauvais.yaml --validate=false
kubectl -n ch54 get colis mauvais -o jsonpath='{.spec}'
```

```sortie
colis.cours.example.com/mauvais configured
{"api":{"replicas":"beaucoup"},"base":{"classe":"standard","taille":"1Gi"},"version":"2.2.1","worker":{"max":5,"min":0}}
# sed 's/name: mauvais/name: mauvais-2/' mauvais.yaml | kubectl apply --validate=false -f -
The Colis "mauvais-2" is invalid: spec.api.replicas: Invalid value: "string": spec.api.replicas in body must be of type integer: "string"
```

La première commande passe, et `"beaucoup"` reste. La seconde, le même contenu sous un autre nom, est refusée. La différence tient au **ratchet** (cliquet) de validation, stable depuis Kubernetes 1.33 : à la mise à jour d'un objet, l'API server tolère un champ invalide s'il n'a pas changé[^ratchet]. Sans ce mécanisme, durcir un schéma rendrait impossible toute modification des objets existants, même celle d'une étiquette, tant que leur ancienne erreur n'est pas corrigée. Un objet neuf, lui, n'a pas d'ancienne valeur, et toutes les règles s'appliquent.

### Les erreurs de validation

Un manifeste qui accumule les fautes :

```yaml title="invalide.yaml"
apiVersion: cours.example.com/v1alpha1
kind: Colis
metadata:
  name: invalide
  namespace: ch54
spec:
  version: "2.2"
  api:
    replicas: 0
  worker:
    max: 50
  base:
    taille: 1G
    classe: rapide
```

```bash
kubectl apply -f invalide.yaml
```

```sortie
The Colis "invalide" is invalid: 
* spec.api.replicas: Invalid value: 0: spec.api.replicas in body should be greater than or equal to 1
* spec.base.classe: Unsupported value: "rapide": supported values: "standard", "csi-hostpath-sc"
* spec.base.taille: Invalid value: "1G": spec.base.taille in body should match '^[0-9]+(Mi|Gi)$'
* spec.version: Invalid value: "2.2": spec.version in body should match '^[0-9]+\.[0-9]+\.[0-9]+$'
* spec.worker.max: Invalid value: 50: spec.worker.max in body should be less than or equal to 20
```

Toutes les erreurs arrivent ensemble, chacune avec le chemin du champ, la valeur reçue et la règle. Le `"2.2"` est entre guillemets dans le manifeste ; sans eux, YAML le lirait comme un nombre décimal, et l'erreur serait une erreur de type (c'est l'objet du premier exercice). Un objet sans `spec`, puis un objet réduit au seul champ obligatoire :

```sortie
The Colis "vide" is invalid: spec: Required value
```

```sortie
colis.cours.example.com/mini created
{"api":{"replicas":2},"base":{"classe":"standard","taille":"1Gi"},"version":"2.2.1","worker":{"max":5,"min":0}}
```

Le manifeste ne disait que `version: 2.2.1`. L'objet stocké a ses cinq autres champs, remplis par le schéma.

## Le trajet d'un objet personnalisé

L'ordre des opérations explique la plupart des surprises : pourquoi une valeur par défaut apparaît sur un objet ancien, pourquoi un objet invalide se relit sans erreur, pourquoi une règle peut s'appuyer sur un champ que le manifeste ne donne pas.

<Figure svg={crdTrajet} num="54.1" alt="Deux rangées. Écriture, de gauche à droite : requête en v1alpha1 ; 1, authentification et autorisation, RBAC sur colis et colis/status ; 2, décodage : champs inconnus élagués, valeurs par défaut de la version demandée ; 3, admission en mutation, défauts réappliqués si un patch a changé l'objet ; 4, validation : schéma OpenAPI puis règles CEL, ce qui n'a pas changé est toléré ; 5, admission en validation, politiques et webhooks ; 6, conversion vers la version stockée puis écriture en JSON dans etcd, sous la clé /registry/cours.example.com/colis/ch54/principal. Lecture, de droite à gauche depuis etcd : 7, décodage avec le schéma de la version stockée, élagage et défauts ; 8, conversion vers la version demandée ; pas de validation, un objet invalide déjà stocké est rendu tel quel ; réponse en v1.">
Le trajet d'un objet personnalisé dans l'API server. À l'écriture, l'élagage et les valeurs par défaut précèdent la validation ; à la lecture, ils sont refaits avec le schéma de la version stockée, et rien n'est validé.
</Figure>

La documentation de Kubernetes décrit les trois moments où les valeurs par défaut s'appliquent : sur l'objet de la requête, avec le schéma de la version demandée ; à la lecture depuis etcd, avec le schéma de la version stockée ; après un webhook de mutation qui a modifié l'objet[^crd-tache]. La validation vient après la mutation : une règle voit donc l'objet complété. On le constatera avec le dernier essai du premier exercice.

## Des règles entre les champs : CEL

Un schéma OpenAPI vérifie chaque champ isolément. Il ne sait pas dire que `worker.min` doit rester inférieur à `worker.max`, ni qu'un volume ne peut pas rétrécir. Depuis Kubernetes 1.29, une définition peut porter des règles écrites en CEL (*Common Expression Language*), le langage déjà rencontré avec les politiques d'admission du chapitre 45, sous la clé `x-kubernetes-validations`[^cel]. Trois règles sont ajoutées au schéma :

```yaml title="03-colis-cel.yaml (extraits)"
          spec:
            x-kubernetes-validations:
            - rule: "!has(oldSelf.version) || semver(self.version).compareTo(semver(oldSelf.version)) >= 0"
              message: pas de retour à une version antérieure
# ...
              worker:
                x-kubernetes-validations:
                - rule: self.min <= self.max
                  messageExpression: "'min (%d) dépasse max (%d)'.format([self.min, self.max])"
# ...
                  taille:
                    x-kubernetes-validations:
                    - rule: quantity(self).compareTo(quantity(oldSelf)) >= 0
                      message: un volume ne rétrécit pas
```

Une règle est évaluée à l'endroit du schéma où elle est déclarée, et `self` y désigne la valeur à cet endroit : l'objet `worker` pour la première, la chaîne `taille` pour la deuxième, tout `spec` pour la troisième. `oldSelf` désigne l'ancienne valeur, lors d'une mise à jour : une règle qui l'utilise est une règle de **transition**, qui n'est pas évaluée à la création. Kubernetes ajoute à CEL quelques bibliothèques : `quantity()` comprend les quantités de ressources (`512Mi`, `2Gi`) depuis 1.28, `semver()` les numéros de version sémantique depuis 1.34[^cel]. `semver` est indispensable ici : comparées comme des chaînes, `"2.10.0"` serait inférieure à `"2.9.9"`.

La première version de ces règles a été refusée deux fois. Avec `default: {}` sur `worker`, comme dans le fichier précédent :

```sortie
The CustomResourceDefinition "colis.cours.example.com" is invalid: spec.validation.openAPIV3Schema.properties[spec].properties[worker].default: Invalid value: "object": no such key: min evaluating rule: self.min <= self.max
```

:::panne[no such key: min evaluating rule: self.min &lt;= self.max]

L'API server évalue les règles sur la valeur par défaut elle-même, au moment où la définition est enregistrée. Il ne complète pas cette valeur avec les défauts des champs qu'elle contient : `{}` n'a pas de clé `min`, et la règle échoue. Deux corrections : écrire une valeur par défaut complète (`default: {min: 0, max: 5}`, la solution retenue), ou écrire une règle qui tolère l'absence (`!has(self.min) || !has(self.max) || self.min <= self.max`).

:::

La seconde erreur portait sur le message. La documentation montre un `messageExpression` construit par concaténation, avec `string()` pour convertir les nombres. Sur ce schéma, c'est refusé :

```sortie
# messageExpression: "'min (' + string(self.min) + ') dépasse max (' + string(self.max) + ')'"
The CustomResourceDefinition "colis.cours.example.com" is invalid: 
* spec.validation.openAPIV3Schema.properties[spec].properties[worker].x-kubernetes-validations[0].messageExpression: Forbidden: estimated messageExpression cost exceeds budget by factor of more than 100x (try simplifying the rule, or adding maxItems, maxProperties, and maxLength where arrays, maps, and strings are declared)
* spec.validation.openAPIV3Schema.properties[spec].properties[worker].x-kubernetes-validations[0].messageExpression: Forbidden: contributed to estimated rule cost total exceeding cost limit for entire OpenAPIv3 schema
* spec.validation.openAPIV3Schema: Forbidden: x-kubernetes-validations estimated rule cost total for entire OpenAPIv3 schema exceeds budget by factor of more than 100x (try simplifying the rule, or adding maxItems, maxProperties, and maxLength where arrays, maps, and strings are declared)
```

:::panne[estimated messageExpression cost exceeds budget by factor of more than 100x]

À l'enregistrement de la définition, l'API server estime le coût de chaque expression dans le pire cas, et refuse celles dont l'estimation dépasse un budget[^cel]. Le pire cas d'une chaîne sans longueur maximale est une chaîne immense ; une concaténation avec `string(self.min)` est estimée comme telle, même quand `min` a une borne. Ajouter `maxLength` aux chaînes du schéma ne suffit pas ici. La fonction `format()` de la bibliothèque de chaînes, elle, est acceptée : `'min (%d) dépasse max (%d)'.format([self.min, self.max])`. Quand le refus vient d'une liste ou d'une table parcourue par une règle, c'est `maxItems` ou `maxProperties` qu'il faut ajouter.

:::

Avec ces deux corrections, la définition passe. Une série de modifications de l'objet `principal` :

```sortie
# kubectl -n ch54 patch colis principal --type=merge -p '{"spec":{"worker":{"min":8}}}'
The Colis "principal" is invalid: spec.worker: Invalid value: min (8) dépasse max (5)
# kubectl -n ch54 patch colis principal --type=merge -p '{"spec":{"base":{"taille":"512Mi"}}}'
The Colis "principal" is invalid: spec.base.taille: Invalid value: "512Mi": un volume ne rétrécit pas
# kubectl -n ch54 patch colis principal --type=merge -p '{"spec":{"base":{"taille":"2Gi"}}}'
colis.cours.example.com/principal patched
# kubectl -n ch54 patch colis principal --type=merge -p '{"spec":{"version":"2.10.0"}}'
colis.cours.example.com/principal patched
# kubectl -n ch54 patch colis principal --type=merge -p '{"spec":{"version":"2.9.9"}}'
The Colis "principal" is invalid: spec: Invalid value: pas de retour à une version antérieure
{"api":{"replicas":2},"base":{"classe":"standard","taille":"2Gi"},"version":"2.10.0","worker":{"max":5,"min":0}}
```

Le message de la première règle est construit à partir des valeurs ; les deux autres sont fixes. Le passage de `2.2.1` à `2.10.0` est accepté, le retour à `2.9.9` refusé. Ces règles rendent aussi impossible de réappliquer le manifeste d'origine, qui demande `2.2.1` et `1Gi` :

```sortie
The Colis "principal" is invalid: 
* spec: Invalid value: pas de retour à une version antérieure
* spec.base.taille: Invalid value: "1Gi": un volume ne rétrécit pas
```

C'est le comportement voulu, et c'est aussi une contrainte pour un outil comme Argo CD (chapitre 57), qui réapplique les manifestes du dépôt : le dépôt doit suivre le cluster, jamais le précéder dans le passé.

## Ce que kubectl affiche

Sans indication, `kubectl get` n'affiche que le nom et l'âge d'un objet personnalisé. La définition peut ajouter des colonnes (`additionalPrinterColumns`, des chemins JSONPath dans l'objet), une abréviation (`shortNames`) et des catégories, qui regroupent plusieurs types sous un même nom. Le fichier `04-colis-complet.yaml` ajoute ces trois éléments, deux sous-ressources et un champ sélectionnable :

```yaml title="04-colis-complet.yaml (extrait)"
    plural: colis
    listKind: ColisList
    shortNames: [cl]
    categories: [cours]
  versions:
  - name: v1alpha1
    served: true
    storage: true
    subresources:
      status: {}
      scale:
        specReplicasPath: .spec.api.replicas
        statusReplicasPath: .status.api.replicas
        labelSelectorPath: .status.selecteur
    additionalPrinterColumns:
    - {name: Version, type: string, jsonPath: .spec.version}
    - {name: API, type: integer, jsonPath: .spec.api.replicas}
    - {name: Prête, type: string, jsonPath: '.status.conditions[?(@.type=="Prete")].status'}
    - {name: Age, type: date, jsonPath: .metadata.creationTimestamp}
    selectableFields:
    - jsonPath: .spec.version
```

```bash
kubectl apply -f 04-colis-complet.yaml
kubectl -n ch54 get cl
kubectl get cours -A
```

```sortie
NAME        VERSION   API   PRÊTE   AGE
principal   2.10.0    2             16s
NAMESPACE   NAME        VERSION   API   PRÊTE   AGE
ch54        principal   2.10.0    2             16s
```

La colonne `PRÊTE` est vide : elle lit une condition dans `status`, que personne n'a encore écrit. Évitez la catégorie `all` pour vos propres types : `kubectl get all` est déjà trop lent sur un gros cluster, et ses utilisateurs ne s'attendent pas à y trouver vos objets. Le schéma alimente aussi `kubectl explain`. Les champs sans `description` y apparaissent nus, ce qui incite à en écrire :

```bash
kubectl explain colis.spec.base
```

```sortie
GROUP:      cours.example.com
KIND:       Colis
VERSION:    v1alpha1

FIELD: base <Object>

DESCRIPTION:
    <empty>
FIELDS:
  classe	<string>
  enum: standard, csi-hostpath-sc
    <no description>

  taille	<string>
    <no description>
```

## Les sous-ressources status et scale

Un objet Kubernetes a deux moitiés. `spec` dit ce qu'on veut ; `status` dit ce qui est, et c'est le contrôleur qui l'écrit. La sous-ressource `status` sépare les deux pour de bon : l'URL principale de l'objet ignore les changements de `status`, et l'URL `/status` ignore ceux de `spec`[^crd-tache]. RBAC peut alors donner à un contrôleur le droit d'écrire `colis/status` sans celui de modifier ce que l'utilisateur a demandé.

```sortie
# kubectl -n ch54 get colis principal -o jsonpath='generation={.metadata.generation} status={.status}'
generation=3 status=
# kubectl -n ch54 patch colis principal --type=merge -p '{"status":{"observedGeneration":3}}'
colis.cours.example.com/principal patched (no change)
generation=3 status=
# kubectl -n ch54 patch colis principal --subresource=status --type=merge -p ...
colis.cours.example.com/principal patched
generation=3 status={"api":{"replicas":2},"conditions":[{"lastTransitionTime":"2026-10-08T20:00:00Z","reason":"Disponible","status":"True","type":"Prete"}],"observedGeneration":3,"selecteur":"app.kubernetes.io/instance=principal"}
# kubectl -n ch54 patch colis principal --subresource=status --type=merge -p '{"spec":{"api":{"replicas":7}}}'
colis.cours.example.com/principal patched (no change)
spec.api.replicas=2
# kubectl -n ch54 label colis principal equipe=exploitation
colis.cours.example.com/principal labeled
generation=3 status={"api":{"replicas":2},"conditions":[{"lastTransitionTime":"2026-10-08T20:00:00Z","reason":"Disponible","status":"True","type":"Prete"}],"observedGeneration":3,"selecteur":"app.kubernetes.io/instance=principal"}
```

`generation` est un compteur que l'API server incrémente à chaque modification de `spec`, et seulement de `spec` : ni le statut, ni une étiquette ne le font bouger. Un contrôleur recopie dans `status.observedGeneration` la génération qu'il a traitée. Quand les deux diffèrent, le contrôleur n'a pas encore vu la dernière demande ; c'est ainsi que `kubectl rollout status` sait qu'un Deployment est à jour.

La sous-ressource `scale` expose une vue normalisée du nombre de répliques, au format `autoscaling/v1` `Scale`, à partir de trois chemins déclarés dans la définition. C'est elle qu'utilisent `kubectl scale` et l'HorizontalPodAutoscaler du chapitre 31 :

```bash
kubectl -n ch54 scale colis principal --replicas=4
kubectl -n ch54 get colis principal -o jsonpath='generation={.metadata.generation} observedGeneration={.status.observedGeneration}'
kubectl -n ch54 get cl
kubectl get --raw /apis/cours.example.com/v1alpha1/namespaces/ch54/colis/principal/scale | jq -c '{kind, apiVersion, spec, status}'
```

```sortie
colis.cours.example.com/principal scaled
generation=4 observedGeneration=3
NAME        VERSION   API   PRÊTE   AGE
principal   2.10.0    4     True    17s
{"kind":"Scale","apiVersion":"autoscaling/v1","spec":{"replicas":4},"status":{"replicas":2,"selector":"app.kubernetes.io/instance=principal"}}
```

`kubectl scale` a modifié `spec.api.replicas`, et la génération est passée à 4 ; le statut dit toujours 2 répliques, puisqu'aucun contrôleur ne les a créées. Le sélecteur (`status.selecteur`) dit à un HorizontalPodAutoscaler quels Pods mesurer : c'est encore au contrôleur de le renseigner.

Enfin, `selectableFields` permet de filtrer côté serveur sur un champ de l'objet, comme `--field-selector status.phase=Running` pour les Pods. C'est stable depuis Kubernetes 1.32[^selection]. Seuls les champs déclarés sont acceptés :

```sortie
# --field-selector spec.version=2.10.0
NAME        VERSION   API   PRÊTE   AGE
principal   2.10.0    4     True    17s
# --field-selector spec.api.replicas=4
Error from server (BadRequest): Unable to find "cours.example.com/v1alpha1, Resource=colis" that match label selector "", field selector "spec.api.replicas=4": field label not supported: spec.api.replicas
```

## Faire évoluer le type : les versions

Un type publié a des utilisateurs : des manifestes dans des dépôts, des scripts, d'autres contrôleurs. Le changer sans casser ces utilisateurs passe par une nouvelle version de l'API. Le fichier `05-colis-v1.yaml` déclare deux versions : `v1alpha1`, toujours servie mais dépréciée, et `v1`, qui ajoute un champ `spec.web` et devient la version stockée.

```yaml title="05-colis-v1.yaml (extrait)"
  - name: v1alpha1
    served: true
    storage: false
    deprecated: true
    deprecationWarning: 'cours.example.com/v1alpha1 Colis est dépréciée : utilisez cours.example.com/v1'
    # ... sous-ressources, colonnes, schéma de v1alpha1
  - name: v1
    served: true
    storage: true
    # ... les mêmes, plus spec.web dans le schéma
  conversion:
    strategy: None
```

La définition ne contient qu'une version marquée `storage: true`. `conversion: None` dit qu'il n'y a rien à convertir entre les deux versions, sinon la valeur de `apiVersion` ; c'est vrai ici, puisque `v1` ne fait qu'ajouter un champ facultatif. Si `v1` avait renommé un champ, il faudrait une conversion par webhook : un service HTTPS que l'API server appelle pour traduire chaque objet d'une version à l'autre[^versions]. kubebuilder sait en générer le squelette (chapitre 55).

Un détail de la définition a coûté un essai : le bloc `selectableFields` n'est déclaré que sur `v1`. Avec le même bloc sur les deux versions, l'API server refuse la définition, avec un message qui parle d'un champ qu'on n'a pas écrit : `spec.selectableFields: Invalid value: "": may only be set when validations.schema is included`. Le refus disparaît dès que les deux blocs diffèrent ; on garde le filtrage sur la version qui reste.

```bash
kubectl apply -f 05-colis-v1.yaml
kubectl get crd colis.cours.example.com -o jsonpath='{.status.storedVersions}'
kubectl get --raw /apis/cours.example.com | jq -c '{versions: [.versions[].version], prefere: .preferredVersion.version}'
```

```sortie
customresourcedefinition.apiextensions.k8s.io/colis.cours.example.com configured
["v1alpha1","v1"]
{"versions":["v1","v1alpha1"],"prefere":"v1"}
```

`storedVersions` est la liste des versions qui ont été un jour la version stockée : il peut donc exister dans etcd des objets encodés dans chacune d'elles. La version préférée, celle que `kubectl` utilise quand on ne précise rien, se déduit du nom : une version stable passe avant une bêta, une bêta avant une alpha, puis le numéro le plus grand l'emporte[^versions]. Les deux versions restent lisibles :

```sortie
# lu en v1alpha1
Warning: cours.example.com/v1alpha1 Colis est dépréciée : utilisez cours.example.com/v1
cours.example.com/v1alpha1 {"api":{"replicas":4},"base":{"classe":"standard","taille":"2Gi"},"version":"2.10.0","worker":{"max":5,"min":0}}
# lu en v1
cours.example.com/v1 {"api":{"replicas":4},"base":{"classe":"standard","taille":"2Gi"},"version":"2.10.0","worker":{"max":5,"min":0}}
```

La lecture en `v1alpha1` porte l'avertissement de dépréciation déclaré dans la définition. `kubectl` l'affiche à chaque appel ; un client écrit en Go le reçoit dans un en-tête HTTP `Warning`. Dans etcd, rien n'a changé :

```sortie
# dans etcd
{"apiVersion":"cours.example.com/v1alpha1"}
# kubectl -n ch54 annotate colis principal note=essai
colis.cours.example.com/principal annotated
{"apiVersion":"cours.example.com/v1"}
```

`principal` est resté en `v1alpha1` jusqu'à sa première écriture, ici une simple annotation : changer la version stockée ne réécrit aucun objet. Un objet créé en `v1alpha1` après le changement est stocké en `v1`, et la lecture montre une subtilité :

```sortie
# créé en v1alpha1
Warning: cours.example.com/v1alpha1 Colis est dépréciée : utilisez cours.example.com/v1
colis.cours.example.com/ancien created
# dans etcd
{"apiVersion":"cours.example.com/v1","spec":{"api":{"replicas":2},"base":{"classe":"standard","taille":"1Gi"},"version":"2.2.1","worker":{"max":5,"min":0}}}
# relu en v1
cours.example.com/v1 {"api":{"replicas":2},"base":{"classe":"standard","taille":"1Gi"},"version":"2.2.1","web":{"replicas":2},"worker":{"max":5,"min":0}}
```

Dans etcd, `ancien` n'a pas de champ `web` : il a été écrit en `v1alpha1`, avec les défauts de `v1alpha1`. À la lecture, l'API server applique les défauts de la version stockée, `v1`, et `web` apparaît. Plus haut, `principal` relu en `v1` n'avait pas de `web`, parce qu'il était encore stocké en `v1alpha1`. Un même type, deux objets, deux comportements : c'est la règle de la figure 54.1 appliquée à la lettre.

<Figure svg={crdVersions} num="54.2" alt="Quatre étapes. 1, une seule version : v1alpha1 servie et stockée, principal stocké en v1alpha1, storedVersions [v1alpha1]. 2, v1 ajoutée et stockée, v1alpha1 servie mais dépréciée : principal encore en v1alpha1, ancien en v1, principal sera réécrit en v1 à sa prochaine écriture ; storedVersions [v1alpha1, v1] ; retirer v1alpha1 ici est refusé. 3, après la migration par une StorageVersionMigration, chaque objet relu et réécrit : les deux objets en v1, storedVersions [v1]. 4, v1alpha1 retirée : seule v1 est servie et stockée.">
Changer de version stockée. Les objets restent dans leur ancienne version jusqu'à leur prochaine écriture ; une migration les réécrit tous, et la liste storedVersions dit quand l'ancienne version peut disparaître.
</Figure>

### Retirer l'ancienne version

Tant que `storedVersions` contient `v1alpha1`, l'API server refuse de la retirer de la définition : un objet encore encodé dans cette version ne pourrait plus être lu.

```bash
kubectl apply -f 06-colis-v1-seul.yaml
```

```sortie
The CustomResourceDefinition "colis.cours.example.com" is invalid: status.storedVersions[0]: Invalid value: "v1alpha1": missing from spec.versions; v1alpha1 was previously a storage version, and must remain in spec.versions until a storage migration ensures no data remains persisted in v1alpha1 and removes v1alpha1 from status.storedVersions
```

La migration consiste à relire et réécrire chaque objet, ce qui le réencode dans la version stockée. On pourrait le faire à la main, objet par objet. Kubernetes a pour cela un objet, `StorageVersionMigration`, déjà rencontré au chapitre 53 pour les types d'origine ; son contrôleur fait partie de kube-controller-manager et il est stable depuis Kubernetes 1.37[^svm]. Pour une ressource personnalisée, il met aussi à jour `storedVersions` à la fin :

```yaml title="migration.yaml"
apiVersion: storagemigration.k8s.io/v1
kind: StorageVersionMigration
metadata:
  name: colis-vers-v1
spec:
  resource:
    group: cours.example.com
    resource: colis
```

```sortie
storageversionmigration.storagemigration.k8s.io/colis-vers-v1 created
{"type":"Running","status":"False","reason":"MigrationCompleted"}
{"type":"Succeeded","status":"True","reason":"StorageVersionMigrationSucceeded"}
# dans etcd
/registry/cours.example.com/colis/ch54/ancien cours.example.com/v1
/registry/cours.example.com/colis/ch54/principal cours.example.com/v1
# storedVersions
["v1"]
# kubectl apply -f 06-colis-v1-seul.yaml
customresourcedefinition.apiextensions.k8s.io/colis.cours.example.com configured
# kubectl api-resources --api-group=cours.example.com
NAME    SHORTNAMES   APIVERSION             NAMESPACED   KIND
colis   cl           cours.example.com/v1   true         Colis
# kubectl -n ch54 get colis.v1alpha1.cours.example.com principal
error: the server doesn't have a resource type "colis" in group "v1alpha1.cours.example.com"
```

Les deux objets sont en `v1`, `storedVersions` ne contient plus que `v1`, et la définition réduite à `v1` passe. `v1alpha1` n'existe plus : un manifeste qui l'utilise encore sera refusé. C'est le moment où les utilisateurs du type doivent avoir migré leurs fichiers, d'où l'intérêt de l'avertissement de dépréciation, des semaines avant.

## Qui a le droit : RBAC

Un type neuf n'est dans aucun rôle. Un compte lié au rôle `view` du namespace, qui lit presque tous les autres types (pas les Secrets), ne voit pas les objets `Colis` :

```bash
kubectl -n ch54 create serviceaccount lecteur
kubectl -n ch54 create rolebinding lecteur-view --clusterrole=view --serviceaccount=ch54:lecteur
kubectl auth can-i list colis.cours.example.com -n ch54 --as=system:serviceaccount:ch54:lecteur
```

```sortie
no
```

Les rôles prédéfinis `view`, `edit` et `admin` (chapitre 43) sont des rôles **agrégés** : leur liste de règles est la réunion de celles de tous les ClusterRoles qui portent une étiquette donnée, recalculée par un contrôleur à chaque changement[^rbac]. Un éditeur de CRD qui veut que ses objets soient lisibles avec `view` publie donc un ClusterRole étiqueté :

```yaml title="07-roles.yaml"
# Les rôles prédéfinis view, edit et admin agrègent les ClusterRoles qui portent ces étiquettes.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: colis-lecture
  labels:
    rbac.authorization.k8s.io/aggregate-to-view: "true"
rules:
- apiGroups: [cours.example.com]
  resources: [colis]
  verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: colis-ecriture
  labels:
    rbac.authorization.k8s.io/aggregate-to-edit: "true"
    rbac.authorization.k8s.io/aggregate-to-admin: "true"
rules:
- apiGroups: [cours.example.com]
  resources: [colis, colis/scale]
  verbs: [create, update, patch, delete, deletecollection]
```

```sortie
# kubectl apply -f 07-roles.yaml
clusterrole.rbac.authorization.k8s.io/colis-lecture created
clusterrole.rbac.authorization.k8s.io/colis-ecriture created
# kubectl auth can-i list colis.cours.example.com -n ch54 --as=system:serviceaccount:ch54:lecteur
yes
# kubectl auth can-i create colis.cours.example.com -n ch54 --as=system:serviceaccount:ch54:lecteur
no
# kubectl get clusterrole view -o json | jq -c '[.rules[] | select(.apiGroups | index("cours.example.com"))]'
[{"apiGroups":["cours.example.com"],"resources":["colis"],"verbs":["get","list","watch"]}]
```

Le rôle `view` a gagné une règle sans qu'on le touche. `colis/scale` est nommé à part dans le rôle d'écriture : une sous-ressource est une ressource distincte pour RBAC, et c'est ce qui permet de donner `colis/status` à un contrôleur sans lui donner `colis` (troisième exercice).

## Ce que coûte une définition

Chaque définition ajoute un type à la découverte, un schéma au document OpenAPI que l'API server publie, des gestionnaires et un cache en mémoire. Cinquante définitions sans un seul objet, créées d'un coup :

```sortie
avant : 44 définitions, 117 types, document de découverte 5937 octets, OpenAPI v3 66 groupes-versions
50 définitions établies en 11,0 s
après : 94 définitions, 167 types, document de découverte 6105 octets, OpenAPI v3 67 groupes-versions
```

Onze secondes pour que les cinquante soient établies, cinquante types de plus dans `api-resources`. Le document de découverte de `/apis` ne grossit que d'un groupe, et le document OpenAPI v3 d'un groupe-version, parce que les cinquante types partagent `cout.example.com/v1`. La mémoire de l'API server, mesurée avec `kubectl top` avant et après, a varié de quelques dizaines de mégaoctets dans un sens ou dans l'autre selon les essais : le ramasse-miettes de Go brouille une mesure de cette taille. Au début de la partie VII, en revanche, la suppression de 50 des 83 définitions du cluster, avec leurs objets, avait fait passer la mémoire du nœud de 2,6 à 2,2 Gio au redémarrage suivant de l'API server : ces types avaient des objets, donc des caches remplis. Le coût d'une définition tient surtout à ses objets.

Supprimer une définition supprime tous ses objets, dans tous les namespaces, sans confirmation. Un finaliseur, posé par l'API server sur chaque CRD, garantit seulement que les objets sont effacés avant la définition :

```bash
kubectl get crd colis.cours.example.com -o jsonpath='{.metadata.finalizers}'
kubectl delete crd colis.cours.example.com
kubectl get colis -A
```

```sortie
# objets Colis : 2
# finaliseurs : []
customresourcedefinition.apiextensions.k8s.io "colis.cours.example.com" deleted
Error from server (NotFound): Unable to list "cours.example.com/v1, Resource=colis": the server could not find the requested resource (get colis.cours.example.com)
# clés restantes sous /registry/cours.example.com : 0
```

Plus aucune clé sous `/registry/cours.example.com` dans etcd. Un `kubectl delete -f` sur le dossier d'un outil qui contient ses CRD efface de la même façon tout ce que l'outil gérait : relisez ce que vous supprimez.

:::panne[resource mapping not found for name ... ensure CRDs are installed first]

Un même fichier contient la définition et un objet du nouveau type. `kubectl apply` prépare tous les objets du fichier avant d'envoyer le premier, et cherche pour chacun son URL dans la découverte ; le type n'y est pas encore, et l'objet est refusé alors que la définition, elle, est créée. Un second `apply` passe :

```sortie
# kubectl apply -f ensemble.yaml      # la définition, puis un objet Colis
customresourcedefinition.apiextensions.k8s.io/colis.cours.example.com created
error: resource mapping not found for name: "principal" namespace: "ch54" from "ensemble.yaml": no matches for kind "Colis" in version "cours.example.com/v1"
ensure CRDs are installed first
# kubectl apply -f ensemble.yaml
customresourcedefinition.apiextensions.k8s.io/colis.cours.example.com unchanged
colis.cours.example.com/principal created
```

Helm installe pour cette raison les CRD d'un chart, rangées dans un dossier `crds/`, avant tout le reste[^helm-crd]. Avec `kubectl`, appliquez les définitions, attendez `Established`, puis le reste. La variante inverse existe : `kubectl` garde la découverte en cache dans `~/.kube/cache/discovery`, et peut croire qu'un type existe encore juste après la suppression de sa définition ; c'est la forme du message de `kubectl get colis -A` ci-dessus. `kubectl api-resources` rafraîchit ce cache.

:::

## Exercices

:::exercice[Exercice 1 : accepté, refusé ou élagué ?]

Avec la définition finale (`06-colis-v1-seul.yaml`), prévoyez le sort de chacun de ces objets avant de les appliquer : accepté tel quel, accepté avec des champs ajoutés ou retirés, ou refusé, et par quelle règle. Pour le premier, donnez aussi le résultat avec `--validate=false`.

```yaml
spec: {version: "2.3.0", api: {replicas: 3, cpu: 200m}}   # a
spec: {version: 2.3}                                        # b
spec: {version: "3.0.0", worker: {max: 3}}                  # c
spec: {version: "3.0.0", worker: {min: 6}}                  # d
```

:::

<details>
<summary>Corrigé</summary>

```sortie
# kubectl apply -f essai-a.yaml      # spec: {version: "2.3.0", api: {replicas: 3, cpu: 200m}}
Error from server (BadRequest): error when creating "essai-a.yaml": Colis in version "v1" cannot be handled as a Colis: strict decoding error: unknown field "spec.api.cpu"
# kubectl apply -f essai-a.yaml --validate=false
colis.cours.example.com/essai-a created
  enregistré : {"api":{"replicas":3},"base":{"classe":"standard","taille":"1Gi"},"version":"2.3.0","web":{"replicas":2},"worker":{"max":5,"min":0}}
# kubectl apply -f essai-b.yaml      # spec: {version: 2.3}
The Colis "essai-b" is invalid: 
* spec.version: Invalid value: "number": spec.version in body must be of type string: "number"
* <nil>: Invalid value: null: some validation rules were not checked because the object was invalid; correct the existing errors to complete validation
# kubectl apply -f essai-c.yaml      # spec: {version: "3.0.0", worker: {max: 3}}
colis.cours.example.com/essai-c created
  enregistré : {"api":{"replicas":2},"base":{"classe":"standard","taille":"1Gi"},"version":"3.0.0","web":{"replicas":2},"worker":{"max":3,"min":0}}
# kubectl apply -f essai-d.yaml      # spec: {version: "3.0.0", worker: {min: 6}}
The Colis "essai-d" is invalid: spec.worker: Invalid value: min (6) dépasse max (5)
```

`a` est refusé par `kubectl` à cause du champ inconnu `cpu` ; avec `--validate=false`, il est accepté et `cpu` élagué. `b` est refusé : sans guillemets, YAML lit `2.3` comme un nombre, et le schéma attend une chaîne. La seconde ligne de l'erreur signale que les règles CEL n'ont pas été évaluées, puisque l'objet n'avait pas la bonne forme. `c` est accepté et complété par les valeurs par défaut, `web` compris. `d` est le cas instructif : le manifeste ne donne pas `max`, la valeur par défaut 5 est appliquée avant la validation, et la règle `min <= max` refuse l'objet en citant un `max` que personne n'a écrit.

</details>

:::exercice[Exercice 2 : une règle entre deux branches]

Ajoutez à la définition une règle qui interdit d'avoir plus de quatre workers au maximum par réplique de l'API : `worker.max` ne doit pas dépasser `4 × api.replicas`. À quel niveau du schéma faut-il la placer ? Vérifiez-la avec un objet refusé, un objet accepté, puis un `kubectl scale` qui rendrait l'objet accepté invalide.

:::

<details>
<summary>Corrigé</summary>

La règle relie deux branches, `api` et `worker` : elle doit être déclarée sur leur parent commun, `spec`, où `self` donne accès aux deux.

```yaml
            x-kubernetes-validations:
            # ... la règle de version, puis :
            - rule: self.worker.max <= 4 * self.api.replicas
              messageExpression: "'worker.max doit rester sous 4 × api.replicas, soit %d'.format([4 * self.api.replicas])"
```

```sortie
# kubectl apply -f essai-e.yaml      # spec: {version: "3.0.0", api: {replicas: 1}, worker: {max: 5}}
The Colis "essai-e" is invalid: spec: Invalid value: worker.max doit rester sous 4 × api.replicas, soit 4
# kubectl apply -f essai-f.yaml      # spec: {version: "3.0.0", api: {replicas: 2}, worker: {max: 8}}
colis.cours.example.com/essai-f created
  enregistré : {"api":{"replicas":2},"base":{"classe":"standard","taille":"1Gi"},"version":"3.0.0","web":{"replicas":2},"worker":{"max":8,"min":0}}
# kubectl -n ch54 scale colis essai-f --replicas=1
The Colis "essai-f" is invalid: spec: Invalid value: worker.max doit rester sous 4 × api.replicas, soit 4
```

Le `kubectl scale` est refusé lui aussi : la sous-ressource `scale` modifie `spec.api.replicas`, et l'objet modifié passe par la même validation. Les règles CEL protègent l'objet quel que soit le chemin d'écriture.

</details>

:::exercice[Exercice 3 : les droits d'un contrôleur]

Le chapitre 55 écrira un contrôleur pour ce type. Écrivez un Role et un ServiceAccount `operateur` dans `ch54` qui lui permettent de lire et de surveiller les objets `Colis`, et d'écrire leur statut, sans jamais pouvoir modifier leur `spec` ni leur nombre de répliques. Vérifiez avec `kubectl auth can-i` (option `--subresource`), puis avec un vrai `patch` sous son identité.

:::

<details>
<summary>Corrigé</summary>

```yaml
rules:
- apiGroups: [cours.example.com]
  resources: [colis]
  verbs: [get, list, watch]
- apiGroups: [cours.example.com]
  resources: [colis/status]
  verbs: [get, update, patch]
```

```sortie
watch colis : yes
patch colis : no
patch colis/status : yes
update colis/scale : no
# kubectl -n ch54 patch colis principal --subresource=status --type=merge -p '{"status":{"observedGeneration":1}}' --as=system:serviceaccount:ch54:operateur
colis.cours.example.com/principal patched
# kubectl -n ch54 patch colis principal --type=merge -p '{"spec":{"api":{"replicas":3}}}' --as=system:serviceaccount:ch54:operateur
Error from server (Forbidden): colis.cours.example.com "principal" is forbidden: User "system:serviceaccount:ch54:operateur" cannot patch resource "colis" in API group "cours.example.com" in the namespace "ch54"
```

Le contrôleur écrit `status` mais ne peut ni modifier `spec`, ni passer par `scale`. Un vrai contrôleur aura besoin de plus : créer et modifier les Deployments, Services et autres objets qu'il fabrique, et écrire des événements. kubebuilder génère ces règles à partir d'annotations dans le code.

</details>

:::exercice[Exercice 4 : l'état des versions d'un cluster (programmation)]

Écrivez un script Python qui fait l'état de toutes les définitions du cluster : pour chacune, sa version stockée, ses versions servies (dépréciées marquées), et le contenu de `status.storedVersions`. Il signale celles qui demandent une migration avant qu'on puisse retirer une ancienne version, compte leurs objets avec une option `--objets`, et sort avec le code 1 s'il en trouve. Pour le tester, recréez la situation du chapitre : définition `05-colis-v1.yaml`, un objet encore stocké en `v1alpha1`.

:::

<details>
<summary>Corrigé</summary>

Le corrigé, `corrige/versions-crd.py`, n'est pas dans l'archive. Il lit `kubectl get crd -o json` et compare, pour chaque définition, `status.storedVersions` à la version marquée `storage: true`. Pour créer un objet stocké en `v1alpha1` alors que la définition stocke en `v1`, le plus simple est de repasser un instant `storage: true` sur `v1alpha1` par un `kubectl patch`, de créer l'objet, puis de réappliquer `05-colis-v1.yaml`.

```sortie
# python3 versions-crd.py --objets
DÉFINITION               STOCKÉE  SERVIES       DANS ETCD    OBJETS  ÉTAT
colis.cours.example.com  v1       v1alpha1*,v1  v1,v1alpha1  2       migrer v1alpha1 -> v1

44 définitions, 1 à migrer
code de sortie : 1
# python3 versions-crd.py --objets
DÉFINITION  STOCKÉE  SERVIES  DANS ETCD  OBJETS  ÉTAT

44 définitions, 0 à migrer
code de sortie : 0
# python3 versions-crd.py --tout | grep -E 'DÉFINITION|v1beta1  |définitions'
DÉFINITION                                      STOCKÉE   SERVIES     DANS ETCD  ÉTAT
referencegrants.gateway.networking.k8s.io       v1beta1   v1,v1beta1  v1beta1    ok
volumesnapshotclasses.snapshot.storage.k8s.io   v1beta1   v1,v1beta1  v1beta1    ok
volumesnapshotcontents.snapshot.storage.k8s.io  v1beta1   v1,v1beta1  v1beta1    ok
volumesnapshots.snapshot.storage.k8s.io         v1beta1   v1,v1beta1  v1beta1    ok
44 définitions, 0 à migrer
```

Après la migration, le script ne signale plus rien et sort avec le code 0. L'option `--tout` montre aussi les définitions en règle, et fait apparaître un cas réel sur le cluster du cours : les quatre définitions ci-dessus servent `v1` et `v1beta1`, mais stockent toujours en `v1beta1`. Elles viennent de versions anciennes des modules complémentaires de minikube (instantanés de volumes) et de Gateway API ; rien n'est à migrer pour l'instant, mais le jour où `v1beta1` disparaîtra, il faudra d'abord changer de version stockée, puis migrer.

```python title="corrige/versions-crd.py"
#!/usr/bin/env python3
"""Fait l'état des versions de chaque CustomResourceDefinition d'un cluster.

Pour chaque définition : la version stockée, les versions servies (dépréciées marquées d'une *),
et les versions encore présentes dans etcd (status.storedVersions). Signale celles qui demandent
une migration avant qu'on puisse retirer une version, et compte les objets si --objets est donné.

Usage : python3 versions-crd.py [--objets] [--tout]
(--tout affiche aussi les définitions sans rien à signaler)
"""
import argparse
import json
import subprocess
import sys


def kubectl(*args: str) -> str:
    return subprocess.run(["kubectl", *args], capture_output=True, text=True, check=True).stdout


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--objets", action="store_true", help="compter les objets de chaque type (plus lent)")
    p.add_argument("--tout", action="store_true", help="afficher aussi les définitions en règle")
    a = p.parse_args()
    crds = json.loads(kubectl("get", "crd", "-o", "json"))["items"]
    a_migrer = 0
    lignes = []
    for crd in sorted(crds, key=lambda c: c["metadata"]["name"]):
        nom = crd["metadata"]["name"]
        versions = crd["spec"]["versions"]
        stockee = next(v["name"] for v in versions if v["storage"])
        servies = [v["name"] + ("*" if v.get("deprecated") else "") for v in versions if v["served"]]
        dans_etcd = crd.get("status", {}).get("storedVersions", [])
        anciennes = [v for v in dans_etcd if v != stockee]
        if anciennes:
            a_migrer += 1
        if not (anciennes or a.tout):
            continue
        objets = ""
        if a.objets:
            sortie = subprocess.run(["kubectl", "get", nom, "-A", "--no-headers", "--ignore-not-found"],
                                    capture_output=True, text=True).stdout
            objets = str(len(sortie.splitlines()))
        etat = f"migrer {','.join(anciennes)} -> {stockee}" if anciennes else "ok"
        lignes.append((nom, stockee, ",".join(servies), ",".join(dans_etcd), objets, etat))
    entete = ("DÉFINITION", "STOCKÉE", "SERVIES", "DANS ETCD", "OBJETS" if a.objets else "", "ÉTAT")
    largeurs = [max(len(l[i]) for l in [entete, *lignes]) for i in range(6)]
    for l in [entete, *lignes]:
        print("  ".join(c.ljust(w) for c, w in zip(l, largeurs) if w).rstrip())
    print(f"\n{len(crds)} définitions, {a_migrer} à migrer")
    return 1 if a_migrer else 0


if __name__ == "__main__":
    sys.exit(main())
```

</details>

## Nettoyer

Le chapitre 55 génère sa propre définition du type `Colis` à partir du code Go de l'opérateur. Celle-ci ne sert plus, pas plus que le namespace et les deux ClusterRoles :

```bash
kubectl delete namespace ch54
kubectl delete crd colis.cours.example.com
kubectl delete clusterrole colis-lecture colis-ecriture
kubectl delete storageversionmigration colis-vers-v1
```

La suppression de la définition emporte l'objet `principal` qui restait. Les cinquante définitions de la mesure de coût ont été supprimées dans la foulée de la mesure.

[^rfc2606]: D. Eastlake, A. Panitz, « Reserved Top Level DNS Names », RFC 2606, juin 1999 : `example.com`, `example.net` et `example.org` sont réservés pour la documentation et les exemples. [rfc-editor.org/rfc/rfc2606](https://www.rfc-editor.org/rfc/rfc2606)
[^ressources-perso]: Kubernetes, « Custom Resources » : CRD et agrégation d'API, ressources personnalisées servies par l'API server sans programme supplémentaire, stockage et RBAC communs avec les types d'origine. [kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/)
[^api-concepts]: Kubernetes, « Kubernetes API Concepts », section sur l'encodage Protobuf : disponible pour les types d'origine, pas pour les ressources définies par une CRD. [kubernetes.io/docs/reference/using-api/api-concepts](https://kubernetes.io/docs/reference/using-api/api-concepts/)
[^crd-tache]: Kubernetes, « Extend the Kubernetes API with CustomResourceDefinitions » : schéma structurel, élagage des champs inconnus avant le stockage, trois moments d'application des valeurs par défaut, sous-ressources (`PUT` sur `/status` ignore `spec`, l'URL principale ignore `status`, `metadata.generation` incrémentée sauf pour `metadata` et `status`), colonnes, catégories, suppression d'une CRD et de tous ses objets. [kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/)
[^ratchet]: Kubernetes, même page, section « Validation ratcheting » (stable depuis 1.33) : une mise à jour est acceptée si chaque partie invalide de l'objet n'a pas été modifiée ; et KEP-4008, « CRD Validation Ratcheting ». [github.com/kubernetes/enhancements/.../4008-crd-ratcheting](https://github.com/kubernetes/enhancements/tree/master/keps/sig-api-machinery/4008-crd-ratcheting)
[^cel]: Kubernetes, « Common Expression Language in Kubernetes » : variables `self` et `oldSelf`, bibliothèques ajoutées par Kubernetes (quantités depuis 1.28, `format` depuis 1.32, versions sémantiques depuis 1.34), budget de coût à l'exécution et estimation du coût à l'écriture. [kubernetes.io/docs/reference/using-api/cel](https://kubernetes.io/docs/reference/using-api/cel/) ; et KEP-2876, « CRD Validation Expression Language ». [github.com/kubernetes/enhancements/.../2876-crd-validation-expression-language](https://github.com/kubernetes/enhancements/tree/master/keps/sig-api-machinery/2876-crd-validation-expression-language)
[^selection]: KEP-4358, « Custom Resource Field Selectors », stable en 1.32 : champ `selectableFields` par version, filtrage côté serveur. [github.com/kubernetes/enhancements/.../4358-custom-resource-field-selectors](https://github.com/kubernetes/enhancements/tree/master/keps/sig-api-machinery/4358-custom-resource-field-selectors)
[^versions]: Kubernetes, « Versions in CustomResourceDefinitions » : priorité des versions déduite de leur nom, dépréciation et avertissement, conversion `None` qui ne change que `apiVersion`, conversion par webhook, `status.storedVersions` et migration vers une nouvelle version stockée. [kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definition-versioning](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definition-versioning/)
[^svm]: KEP-4192, « Move Storage Version Migrator in-tree » : alpha en 1.30, bêta en 1.35, stable en 1.37. [github.com/kubernetes/enhancements/.../4192-svm-in-tree](https://github.com/kubernetes/enhancements/tree/master/keps/sig-api-machinery/4192-svm-in-tree) ; et Kubernetes, « Migrate Kubernetes Objects Using Storage Version Migration ». [kubernetes.io/docs/tasks/manage-kubernetes-objects/storage-version-migration](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/storage-version-migration/)
[^rbac]: Kubernetes, « Using RBAC Authorization », section « Aggregated ClusterRoles » : étiquettes `rbac.authorization.k8s.io/aggregate-to-view`, `-edit` et `-admin` des rôles par défaut. [kubernetes.io/docs/reference/access-authn-authz/rbac](https://kubernetes.io/docs/reference/access-authn-authz/rbac/#aggregated-clusterroles)
[^helm-crd]: Helm, « Charts », section « Custom Resource Definitions (CRDs) » : les fichiers du dossier `crds/` sont envoyés avant le reste du chart, Helm attend que l'API server serve les nouveaux types, puis rend et installe les gabarits ; ces fichiers ne sont ni mis à jour ni supprimés par Helm. [helm.sh/docs/topics/charts](https://helm.sh/docs/topics/charts/#custom-resource-definitions-crds)
