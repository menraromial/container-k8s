---
title: Kustomize
sidebar_label: 30. Kustomize
description: "Décliner Colis en environnements sans modèles : une base de manifestes ordinaires, des overlays de développement et de production, les correctifs, les générateurs de ConfigMap et de Secret et leur suffixe d'empreinte, les transformations d'images, puis la comparaison avec Helm et la façon de combiner les deux."
partie: 4
chapitre: '30'
---

import kustomizeCouches from '@site/src/figures/kustomize-couches.svg';
import helmKustomize from '@site/src/figures/helm-kustomize.svg';

Le chart Helm du chapitre 29 règle la question des copies de Colis, mais à un prix. Ses fichiers ne sont plus des manifestes : `replicas: {{ .Values.api.repliques }}` n'est pas du YAML qu'on peut appliquer, ni relire d'un coup d'œil, ni valider avec les outils habituels. Chaque réglage qu'un utilisateur voudra changer doit avoir été prévu par l'auteur du chart, sous la forme d'une valeur ; le jour où il faut ajouter une tolérance ou un en-tête que personne n'avait prévu, il faut modifier le chart. Et une erreur d'indentation dans un `nindent` produit un YAML faux qu'on ne découvre qu'au rendu.

**Kustomize** part du principe inverse : on garde des manifestes ordinaires, valides, applicables tels quels, et on décrit les différences entre environnements comme des **correctifs** appliqués par-dessus. Pas de modèles, pas de langage : du YAML, et un fichier `kustomization.yaml` qui dit quoi assembler et quoi modifier[^kustomize]. Kustomize est intégré à `kubectl` depuis la version 1.14 (2019) : `kubectl kustomize` affiche le rendu, `kubectl apply -k` l'applique.

```bash
kubectl version --client
```

```sortie
Client Version: v1.37.1
Kustomize Version: v5.8.1
```

Les fichiers sont dans [l'archive kustomize](pathname:///kits/kustomize.tar.gz).

## Une base

La **base** contient les manifestes de Colis tels que les chapitres 25 à 28 les ont laissés, sans namespace, et un fichier `kustomization.yaml` :

```yaml title="colis/base/kustomization.yaml"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- postgres.yaml
- redis.yaml
- api.yaml
- worker.yaml
- web.yaml
- purge.yaml
- route.yaml

labels:
- pairs:
    app.kubernetes.io/part-of: colis

configMapGenerator:
- name: colis-config
  literals:
  - COLIS_REDIS=redis://redis:6379/0
  - COLIS_VERSION=2.1.0
  - COLIS_PURGE_JOURS=30

images:
- name: colis-api
  newName: host.minikube.internal:5001/colis/api
  newTag: "2.1"
- name: colis-web
  newName: host.minikube.internal:5001/colis/web
  newTag: "1.0"
```

`resources` liste les fichiers à assembler. `labels` ajoute une étiquette à tous les objets. `configMapGenerator` fabrique la ConfigMap de Colis à partir de paires clé-valeur (ou de fichiers). Et `images` remplace des noms d'images : dans les manifestes de la base, l'API et le worker demandent l'image `colis-api`, un nom de travail que Kustomize remplace par la vraie adresse, avec son étiquette. Changer de version de Colis, c'est changer une ligne ici, pas chercher toutes les occurrences de l'image dans les fichiers.

```bash
kubectl kustomize colis/base | grep -E '^kind:|^  name:' | paste - -
```

```sortie
kind: ConfigMap	  name: colis-config-tmg5b2k56h
kind: Service	  name: api
kind: Service	  name: postgres
kind: Service	  name: redis
kind: Service	  name: web
kind: Deployment	  name: api
kind: Deployment	  name: redis
kind: Deployment	  name: web
kind: Deployment	  name: worker
kind: StatefulSet	  name: postgres
kind: CronJob	  name: purge
kind: HTTPRoute	  name: colis
```

La ConfigMap s'appelle `colis-config-tmg5b2k56h`, et non `colis-config`. Ce suffixe est une empreinte de son contenu ; on verra plus loin tout ce qu'il apporte. Kustomize a aussi réécrit les références à cette ConfigMap dans les Deployments et le CronJob, qui nomment `colis-config` dans les fichiers de la base.

## Deux overlays

Un **overlay** est un autre dossier avec son `kustomization.yaml`, qui prend la base comme ressource et la modifie. L'overlay de développement :

```yaml title="colis/overlays/dev/kustomization.yaml"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: colis-dev

resources:
- namespace.yaml
- ../../base

labels:
- pairs:
    environnement: dev

secretGenerator:
- name: colis-db
  envs:
  - secret.env              # POSTGRES_PASSWORD=..., créé à la main, jamais versionné

configMapGenerator:
- name: colis-config
  behavior: merge
  literals:
  - COLIS_PURGE_JOURS=7

replicas:
- name: api
  count: 1
- name: web
  count: 1

patches:
- path: route.yaml
- target:
    kind: CronJob
    name: purge
  patch: |-
    - op: replace
      path: /spec/schedule
      value: "*/30 * * * *"
```

Chaque champ est une transformation. `namespace` place tous les objets dans `colis-dev`, qu'un petit fichier `namespace.yaml` crée avec l'étiquette exigée par la passerelle du chapitre 28. `secretGenerator` fabrique le Secret du mot de passe à partir d'un fichier `secret.env`, qui reste sur votre poste :

```bash
printf 'POSTGRES_PASSWORD=%s\n' "$(head -c 18 /dev/urandom | base64 | tr -d '/+=')" > colis/overlays/dev/secret.env
```

Le dépôt du cours l'exclut par son `.gitignore` : un mot de passe n'a rien à faire dans Git (le chapitre 46 présentera des façons de le versionner chiffré). Le second `configMapGenerator`, avec `behavior: merge`, ajoute ou remplace des clés dans la ConfigMap de la base. `replicas` règle le nombre de répliques sans correctif.

Les **correctifs**, `patches`, viennent sous deux formes. Le premier est un correctif *stratégique* : un morceau de YAML qui ressemble à l'objet visé et ne contient que ce qui change, ici le nom d'hôte de la route :

```yaml title="colis/overlays/dev/route.yaml"
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: colis
spec:
  hostnames:
  - colis-dev.local
```

Le second est un correctif *JSON Patch* (RFC 6902) : une liste d'opérations (`add`, `replace`, `remove`...) sur des chemins précis, utile quand le correctif stratégique ne sait pas désigner l'endroit, par exemple un élément d'une liste. Ici, la purge passe à toutes les trente minutes.

L'overlay de production suit le même schéma, avec trois API, plus de ressources, et une image désignée par son **empreinte** plutôt que par une étiquette : une étiquette peut être déplacée vers une autre image, une empreinte non (chapitre 14).

```yaml title="colis/overlays/prod/kustomization.yaml (extrait)"
namespace: colis-prod

replicas:
- name: api
  count: 3

images:
- name: host.minikube.internal:5001/colis/api   # le nom tel que la base l'a laissé
  digest: sha256:ade99a611b6a907ceacc9deb10f1a7cc21a1f49f7f4395d5d5b5a145205ad3a5

patches:
- path: route.yaml
- path: api-ressources.yaml
```

<Figure svg={kustomizeCouches} num="30.1" alt="La base (7 manifestes : StatefulSet, Deployments, Services, CronJob, HTTPRoute ; un configMapGenerator colis-config ; images : colis-api remplacé par l'adresse du registre et l'étiquette 2.1 ; l'étiquette part-of: colis) est la ressource des deux overlays, par resources: ../../base. L'overlay dev : namespace colis-dev, un secretGenerator à partir de secret.env, la ConfigMap fusionnée avec 7 jours, une réplique pour l'API et le site, des correctifs pour l'hôte et le planning */30. Son rendu, kubectl apply -k overlays/dev : 14 objets dans colis-dev, dont colis-config-8b7826m4dt et colis-db-dbg8m2bt96, publiés sous colis-dev.local. L'overlay prod : namespace colis-prod, un secretGenerator, trois répliques pour l'API, l'image figée par son empreinte, des correctifs pour l'hôte et les ressources de l'API. Son rendu, kubectl kustomize overlays/prod : 14 objets pour colis-prod, avec colis/api@sha256:ade9... et colis-prod.local. Chaque couche est du YAML valide, aucune ne modifie les fichiers de la couche du dessous, et le suffixe des générateurs est une empreinte du contenu : changer une valeur change le nom, donc les Pods qui s'y réfèrent.">
Une base, deux overlays : chaque environnement est décrit par ce qui le distingue, et rien d'autre.
</Figure>

### Rendre et appliquer

```bash
kubectl kustomize colis/overlays/dev | grep -E '^kind:|^  name:' | paste - -
kubectl kustomize colis/overlays/dev | grep -A2 secretKeyRef | grep 'name: colis-db' | sort | uniq -c
```

```sortie
kind: Namespace	  name: colis-dev
kind: ConfigMap	  name: colis-config-8b7826m4dt
kind: Secret	  name: colis-db-dbg8m2bt96
kind: Service	  name: api
kind: Service	  name: postgres
kind: Service	  name: redis
kind: Service	  name: web
kind: Deployment	  name: api
kind: Deployment	  name: redis
kind: Deployment	  name: web
kind: Deployment	  name: worker
kind: StatefulSet	  name: postgres
kind: CronJob	  name: purge
kind: HTTPRoute	  name: colis
      1                   name: colis-db-dbg8m2bt96
      3               name: colis-db-dbg8m2bt96
```

Quatorze objets. Le Secret, lui aussi suffixé, est référencé quatre fois (par PostgreSQL, l'API, le worker et la purge), et Kustomize a réécrit les quatre références. L'étiquette `environnement: dev` a été ajoutée aux métadonnées de chaque objet et aux modèles de Pods, mais pas aux sélecteurs : le champ `labels` ne touche aux sélecteurs que si on le lui demande (`includeSelectors: true`), ce qui évite de rendre un Deployment existant impossible à mettre à jour, puisque son sélecteur est immuable (chapitre 19). Appliquons :

```bash
kubectl apply -k colis/overlays/dev
kubectl -n colis-dev get pods,cm,secret
curl -s -H 'Host: colis-dev.local' http://192.168.49.102/api/pret; echo
kubectl -n colis-dev get cronjob purge
```

```sortie
namespace/colis-dev created
configmap/colis-config-8b7826m4dt created
secret/colis-db-dbg8m2bt96 created
service/api created
service/postgres created
service/redis created
service/web created
deployment.apps/api created
deployment.apps/redis created
deployment.apps/web created
deployment.apps/worker created
statefulset.apps/postgres created
cronjob.batch/purge created
httproute.gateway.networking.k8s.io/colis created
NAME                          READY   STATUS    RESTARTS     AGE
pod/api-66b5f5bb49-kfqc5      1/1     Running   1 (3s ago)   11s
pod/postgres-0                1/1     Running   0            11s
pod/redis-578785659c-m8nc4    1/1     Running   0            11s
pod/web-599d986bdf-nhsvl      1/1     Running   0            11s
pod/worker-5bdbd495d5-95dfg   1/1     Running   1 (4s ago)   11s

NAME                                DATA   AGE
configmap/colis-config-8b7826m4dt   3      11s
configmap/kube-root-ca.crt          1      11s

NAME                         TYPE     DATA   AGE
secret/colis-db-dbg8m2bt96   Opaque   1      11s
{"stockage":"postgres","file":"redis","pret":true}
NAME    SCHEDULE       TIMEZONE       SUSPEND   ACTIVE   LAST SCHEDULE   AGE
purge   */30 * * * *   Europe/Paris   False     0        <none>          14s
```

Un troisième Colis, en 11 secondes, avec une réplique de l'API et du site, sa purge toutes les trente minutes, et son nom d'hôte sur la passerelle. Contrairement à Helm, rien ne garde la trace de cette installation dans le cluster : ce sont des objets ordinaires, et l'historique, c'est celui des fichiers dans Git.

### Changer la configuration

Le suffixe d'empreinte des générateurs résout un problème qui revient depuis le chapitre 21 : un Pod ne voit pas les changements d'une ConfigMap lue en variables d'environnement. Passons la purge à 14 jours dans l'overlay, et regardons ce que `kubectl diff -k` prévoit :

```bash
sed -i 's/  - COLIS_PURGE_JOURS=7/  - COLIS_PURGE_JOURS=14/' colis/overlays/dev/kustomization.yaml
kubectl diff -k colis/overlays/dev | grep -E '^diff|^[-+] .*(colis-config|COLIS_PURGE)'
```

```sortie
diff -u -N /tmp/LIVE-2138944084/apps.v1.Deployment.colis-dev.api /tmp/MERGED-3519090103/apps.v1.Deployment.colis-dev.api
-            name: colis-config-8b7826m4dt
+            name: colis-config-595869mgkc
diff -u -N /tmp/LIVE-2138944084/apps.v1.Deployment.colis-dev.worker /tmp/MERGED-3519090103/apps.v1.Deployment.colis-dev.worker
-            name: colis-config-8b7826m4dt
+            name: colis-config-595869mgkc
diff -u -N /tmp/LIVE-2138944084/batch.v1.CronJob.colis-dev.purge /tmp/MERGED-3519090103/batch.v1.CronJob.colis-dev.purge
-                name: colis-config-8b7826m4dt
+                name: colis-config-595869mgkc
diff -u -N /tmp/LIVE-2138944084/v1.ConfigMap.colis-dev.colis-config-595869mgkc /tmp/MERGED-3519090103/v1.ConfigMap.colis-dev.colis-config-595869mgkc
+  COLIS_PURGE_JOURS: "14"
+  name: colis-config-595869mgkc
```

Un contenu nouveau, donc un nom nouveau : `colis-config-595869mgkc`. Les modèles de Pod de l'API et du worker changent, puisque le nom qu'ils référencent change, et les Deployments remplacent leurs Pods. C'est le même résultat que l'annotation d'empreinte du chart Helm, obtenu sans rien écrire.

```bash
kubectl apply -k colis/overlays/dev | grep -v unchanged
kubectl -n colis-dev get cm
kubectl -n colis-dev exec deploy/api -- printenv COLIS_PURGE_JOURS
```

```sortie
configmap/colis-config-595869mgkc created
deployment.apps/api configured
deployment.apps/worker configured
statefulset.apps/postgres configured
cronjob.batch/purge configured
httproute.gateway.networking.k8s.io/colis configured
NAME                      DATA   AGE
colis-config-595869mgkc   3      6s
colis-config-8b7826m4dt   3      22s
kube-root-ca.crt          1      22s
14
```

Le StatefulSet de PostgreSQL et la route apparaissent comme `configured` alors que rien ne les concernait : `kubectl apply` a seulement réécrit leur annotation `last-applied-configuration`. Leur spécification n'a pas bougé, et PostgreSQL n'a pas redémarré (sa `metadata.generation` est restée à 1). L'**ancienne** ConfigMap, elle, est toujours là, ce qui a un avantage : revenir à 7 jours, c'est réappliquer l'ancienne version des fichiers, et la ConfigMap qu'elle référence existe déjà.

```bash
sed -i 's/  - COLIS_PURGE_JOURS=14/  - COLIS_PURGE_JOURS=7/' colis/overlays/dev/kustomization.yaml
kubectl apply -k colis/overlays/dev | grep -E 'configmap|deployment'
kubectl -n colis-dev exec deploy/api -- printenv COLIS_PURGE_JOURS
```

```sortie
configmap/colis-config-8b7826m4dt unchanged
deployment.apps/api configured
deployment.apps/redis unchanged
deployment.apps/web unchanged
deployment.apps/worker configured
7
```

Le revers est l'accumulation : chaque changement laisse une ConfigMap orpheline, que personne ne supprime. L'exercice 2 y revient.

### Vérifier la production sans la déployer

```bash
kubectl kustomize colis/overlays/prod | grep -E 'image: .*colis/api' | sort | uniq -c
diff <(kubectl kustomize colis/overlays/dev) <(kubectl kustomize colis/overlays/prod) | grep -c '^[<>]'
```

```sortie
      1             image: host.minikube.internal:5001/colis/api@sha256:ade99a611b6a907ceacc9deb10f1a7cc21a1f49f7f4395d5d5b5a145205ad3a5
      2         image: host.minikube.internal:5001/colis/api@sha256:ade99a611b6a907ceacc9deb10f1a7cc21a1f49f7f4395d5d5b5a145205ad3a5
```

```sortie
98
```

L'API, le worker et la purge utilisent l'image désignée par son empreinte. Entre les rendus des deux environnements, 98 lignes diffèrent, et chacune se relie à une ligne des deux overlays : c'est ce qui rend l'approche facile à relire.

:::panne[L'overlay ne change pas l'image]

La première version de l'overlay de production nommait l'image `colis-api`, comme la base, et l'image restait `...colis/api:2.1`, sans erreur :

```sortie
images:
- name: colis-api
  digest: sha256:ade99a611b6a907ceacc9deb10f1a7cc21a1f49f7f4395d5d5b5a145205ad3a5
      1             image: host.minikube.internal:5001/colis/api:2.1
      2         image: host.minikube.internal:5001/colis/api:2.1
```

Chaque couche transforme le résultat de la couche du dessous. Quand l'overlay s'applique, la base a déjà remplacé `colis-api` par `host.minikube.internal:5001/colis/api` : il n'y a plus d'image `colis-api` à trouver, et une transformation qui ne trouve rien ne dit rien. Il faut nommer l'image telle que la base l'a laissée. La même règle vaut pour les noms d'objets si la base a un `namePrefix`.

:::

Pour vérifier la production auprès de l'API server, sans rien créer, `--dry-run=server` fait valider chaque objet comme s'il allait être créé :

```bash
kubectl apply -k colis/overlays/prod --dry-run=server 2>&1 | sort | uniq -c | sort -rn | head -3
```

```sortie
     13 Error from server (NotFound): error when creating "overlays/prod": namespaces "colis-prod" not found
      1 namespace/colis-prod created (server dry run)
```

Le namespace passe la validation, mais n'est pas réellement créé, si bien que les treize autres objets sont refusés : leur namespace n'existe pas. Un essai à blanc ne voit pas les effets de ses propres étapes. Une fois le namespace créé pour de bon, l'essai passe :

```bash
kubectl apply -f colis/overlays/prod/namespace.yaml
kubectl apply -k colis/overlays/prod --dry-run=server
kubectl delete namespace colis-prod
```

```sortie
namespace/colis-prod created
namespace/colis-prod configured (server dry run)
configmap/colis-config-tmg5b2k56h created (server dry run)
secret/colis-db-dthmc6kccg created (server dry run)
service/api created (server dry run)
service/postgres created (server dry run)
service/redis created (server dry run)
service/web created (server dry run)
deployment.apps/api created (server dry run)
deployment.apps/redis created (server dry run)
deployment.apps/web created (server dry run)
deployment.apps/worker created (server dry run)
statefulset.apps/postgres created (server dry run)
cronjob.batch/purge created (server dry run)
httproute.gateway.networking.k8s.io/colis created (server dry run)
```

Le cours ne déploie pas la production pour de bon : avec les deux Colis déjà en place, la passerelle et cert-manager, le nœud de 4 Gio serait trop juste.

## Helm ou Kustomize ?

<Figure svg={helmKustomize} num="30.2" alt="Deux approches. Helm : des modèles, comme replicas: {{ .Values... }}, qui ne sont pas du YAML valide, et des valeurs données par -f ou --set ; helm install produit une release, avec ses révisions, rollback, hooks, tests, lookup, et un chart versionné et publié. Kustomize : une base, par exemple replicas: 2, en YAML valide applicable seul, et un overlay avec un correctif replicas: 3 ; apply -k produit des objets ordinaires, sans historique, dont le retour arrière passe par Git, et Kustomize est intégré à kubectl.">
Deux façons de décliner les mêmes manifestes : paramétrer un modèle, ou corriger une base.
</Figure>

Les deux outils répondent au même besoin, avec des philosophies opposées, et chacun a son terrain.

**Helm** est fait pour **distribuer** un logiciel à des gens qui ne l'ont pas écrit. L'auteur choisit ce qui est réglable, documente les valeurs, publie le chart dans un registre avec un numéro de version ; l'utilisateur n'a qu'à fournir ses valeurs. Helm gère le cycle de vie : historique, retour arrière, hooks pour les migrations, tests. C'est pourquoi les projets de l'écosystème publient des charts, et pourquoi on installe Envoy Gateway ou cert-manager avec Helm.

**Kustomize** est fait pour **décliner** ses propres manifestes. Rien n'est caché derrière un modèle, chaque environnement se lit comme une liste de différences, et n'importe quel champ peut être corrigé sans que personne l'ait prévu. Il n'y a pas d'état dans le cluster : c'est Git qui garde l'historique, ce qui va très bien avec les outils GitOps comme Argo CD (chapitre 57).

Les deux se combinent souvent : un chart tiers, installé avec Helm, et les manifestes de l'équipe, déclinés avec Kustomize. Kustomize sait même rendre un chart Helm et corriger le résultat, avec le champ `helmCharts` :

```yaml title="podinfo/kustomization.yaml"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: ch30

helmCharts:
- name: podinfo
  repo: oci://ghcr.io/stefanprodan/charts
  version: 6.15.0
  releaseName: demo
  valuesInline:
    replicaCount: 2

labels:
- pairs:
    equipe: plateforme

patches:
- target:
    kind: Deployment
    name: demo-podinfo
  patch: |-
    - op: add
      path: /spec/template/spec/containers/0/env/-
      value:
        name: PODINFO_UI_MESSAGE
        value: rendu par Kustomize
```

```bash
kubectl kustomize podinfo
kubectl kustomize --enable-helm podinfo | grep -E '^kind:|^  name:|replicas:|equipe|PODINFO_UI_MESSAGE|rendu par|helm.sh/hook:'
```

```sortie
`: must specify --enable-helm
```

```sortie
kind: Service
    equipe: plateforme
  name: demo-podinfo
kind: Deployment
    equipe: plateforme
  name: demo-podinfo
  replicas: 2
        - name: PODINFO_UI_MESSAGE
          value: rendu par Kustomize
kind: Pod
    helm.sh/hook: test-success
    equipe: plateforme
  name: demo-podinfo-grpc-test-vdxx4
kind: Pod
    helm.sh/hook: test-success
    equipe: plateforme
  name: demo-podinfo-jwt-test-ige4o
kind: Pod
    helm.sh/hook: test-success
    equipe: plateforme
  name: demo-podinfo-service-test-izs23
```

Kustomize exige qu'on l'autorise à exécuter `helm` (`--enable-helm`), puis appelle `helm template` et applique ses propres transformations au résultat : l'étiquette et la variable d'environnement ont été ajoutées à un chart qui ne les prévoyait pas. Mais le rendu montre aussi la limite du procédé : les trois Pods de test du chart sont là, comme des objets ordinaires, avec leur annotation `helm.sh/hook` que plus personne n'interprète. Appliqué tel quel, ce rendu lancerait les tests à chaque fois. Avec Kustomize, un chart perd tout ce qui relève de Helm (hooks, tests, `lookup`, historique) ; il faut en tenir compte, et souvent filtrer ces objets.

## Exercices

:::exercice[Exercice 1 : un préfixe pour tout]

Pour installer une copie d'essai de Colis à côté de celle de `colis-dev`, un collègue propose un overlay avec `namePrefix: essai-`, dans le même namespace. Rendez cet overlay, et dites ce qui marcherait et ce qui ne marcherait pas.

:::

<details>
<summary>Corrigé</summary>

```yaml title="colis/overlays/essai/kustomization.yaml"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: colis-dev
namePrefix: essai-
resources:
- ../../base
secretGenerator:
- name: colis-db
  envs:
  - secret.env
```

Le rendu, résumé par type d'objet et par référence :

```sortie
Service essai-api
Service essai-postgres
Service essai-redis
Service essai-web
StatefulSet essai-postgres
HTTPRoute essai-colis
      1               value: postgresql://colis:$(POSTGRES_PASSWORD)@postgres:5432/colis
      2           value: postgresql://colis:$(POSTGRES_PASSWORD)@postgres:5432/colis
      1   COLIS_REDIS: redis://redis:6379/0
  serviceName: essai-postgres
  template:
    - name: api
    - name: web
```

Kustomize a préfixé tous les noms, et corrigé les références qu'il connaît : les ConfigMaps et Secrets des Pods, le `serviceName` du StatefulSet. Mais il ne sait pas que `postgres` dans `postgresql://...@postgres:5432/colis` et `redis` dans `redis://redis:6379/0` sont des noms de Services : ce sont des chaînes de caractères. L'API et le worker essaieraient donc de joindre les Services `postgres` et `redis`... de la copie `colis-dev`, avec un mot de passe qui n'est pas le leur. Et la HTTPRoute vise toujours `api` et `web`, sans préfixe : Kustomize ne connaît pas la structure des HTTPRoute, qui ne font pas partie du cœur de Kubernetes, et ne sait pas que `backendRefs` contient des noms de Services (on peut le lui apprendre avec une configuration `nameReference`). Enfin, l'image `web` relaie toujours vers `api` (chapitre 29). Conclusion : un préfixe ne suffit pas pour une application qui s'adresse à ses composants par leur nom. Ici, un namespace à part, comme pour `colis-dev`, est la bonne réponse.

</details>

:::exercice[Exercice 2 : les ConfigMaps orphelines]

Après quelques changements de configuration, le namespace `colis-dev` accumule des ConfigMaps `colis-config-...` que plus rien n'utilise. Comment les faire supprimer à chaque `apply`, sans risquer de supprimer autre chose ?

:::

<details>
<summary>Corrigé</summary>

`kubectl apply --prune` supprime les objets qui portent une étiquette donnée et qui ne figurent plus dans ce qu'on applique. Tous les objets de l'overlay portent `environnement: dev`, les ConfigMaps générées comprises. En limitant l'élagage aux ConfigMaps :

```bash
kubectl -n colis-dev get cm -l environnement=dev
kubectl apply -k colis/overlays/dev --prune -l environnement=dev --prune-allowlist=core/v1/ConfigMap | grep -v unchanged
```

```sortie
NAME                      DATA   AGE
colis-config-595869mgkc   3      105s
colis-config-8b7826m4dt   3      2m1s
statefulset.apps/postgres configured
httproute.gateway.networking.k8s.io/colis configured
configmap/colis-config-595869mgkc pruned
```

La ConfigMap inutilisée est supprimée, celle en service reste. La liste d'autorisation (`--prune-allowlist`) est essentielle : sans elle, `--prune` examinerait tous les types d'objets portant l'étiquette, et une étiquette mal choisie peut faire supprimer des objets d'un autre outil. C'est pourquoi l'élagage est souvent laissé aux outils GitOps (chapitre 57), qui savent précisément quels objets ils ont créés. Notez aussi le prix de l'élagage : on perd la possibilité de revenir instantanément à l'ancienne configuration, puisque son objet n'existe plus.

</details>

:::exercice[Exercice 3 : choisir]

Pour chacun de ces cas, choisiriez-vous Helm, Kustomize, ou les deux ? (1) Votre équipe publie un outil de supervision que d'autres entreprises installent. (2) Vous déployez vos trois microservices en recette et en production. (3) Vous installez PostgreSQL avec l'opérateur CloudNativePG, et vous voulez ajouter vos propres NetworkPolicies à ses objets.

:::

<details>
<summary>Corrigé</summary>

(1) Helm : vos utilisateurs veulent installer une version précise, avec quelques réglages documentés, et mettre à jour ou revenir en arrière sans connaître vos manifestes ; un chart publié dans un registre, avec son schéma de valeurs, est la forme attendue. (2) Kustomize : ce sont vos manifestes, vous les connaissez, et vous voulez voir d'un coup d'œil ce qui distingue la recette de la production ; une base et deux overlays, versionnés dans Git et appliqués par un outil GitOps. (3) Les deux : l'opérateur s'installe avec son chart officiel, et vos ajouts vivent dans une kustomization à côté, qui peut aussi rendre le chart par `helmCharts` si vous voulez tout décrire au même endroit, en sachant que les hooks du chart ne seront alors plus exécutés comme tels.

</details>

## Accéder à Colis, et nettoyer

La copie `colis-dev` est servie sous `colis-dev.local` :

```bash
curl -s -H 'Host: colis-dev.local' http://192.168.49.102/api/pret
```

Pour la retirer, `kubectl delete -k` supprime ce que le rendu décrit, namespace compris, avec sa demande de volume :

```bash
kubectl delete -k colis/overlays/dev
```

Gardez-la si vous comptez faire le défi IV, qui part de là. Les fichiers `secret.env` restent sur votre poste.

[^kustomize]: Kubernetes, « Declarative Management of Kubernetes Objects Using Kustomize », et la référence de Kustomize, dont *configMapGenerator*, *images*, *labels*, *patches* et *replicas*. [kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/) ; [kubectl.docs.kubernetes.io/references/kustomize](https://kubectl.docs.kubernetes.io/references/kustomize/)
