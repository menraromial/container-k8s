---
title: Helm
sidebar_label: 29. Helm
description: "Empaqueter une application Kubernetes : installer, mettre à jour et revenir en arrière avec un chart existant, où Helm range ses releases, la structure d'un chart et ses modèles, puis le chart de Colis, ses pièges (un mot de passe tiré à chaque rendu, un Secret perdu à la désinstallation), ses hooks, son test, et sa publication dans un registre OCI."
partie: 4
chapitre: '29'
---

import helmRendu from '@site/src/figures/helm-rendu.svg';
import helmDesinstaller from '@site/src/figures/helm-desinstaller.svg';

Colis tient aujourd'hui dans une douzaine de fichiers YAML, répartis entre les kits des chapitres 24 à 28. Pour en installer une seconde copie, au défi III, il a fallu recopier les fichiers, changer le namespace à la main, et c'est en retouchant ces copies qu'un collègue imaginaire avait semé cinq erreurs. Une équipe réelle a le même besoin, multiplié : une copie pour le développement, une pour les tests, une pour la production, chacune avec ses nombres de répliques, ses tailles de volumes, ses noms d'hôte. Et quand une mise à jour tourne mal, il faut savoir revenir à l'ensemble cohérent d'objets d'hier, pas seulement à l'image d'hier d'un Deployment.

**Helm** répond à ces trois besoins. Il empaquette les manifestes d'une application en un **chart**, où les valeurs qui changent d'une copie à l'autre sont des paramètres ; il installe un chart sous la forme d'une **release**, dont il garde l'historique ; et il sait revenir à une révision précédente de la release entière. C'est l'outil le plus répandu pour distribuer des logiciels pour Kubernetes : la plupart des projets de l'écosystème (Envoy Gateway et cert-manager au chapitre 28, Prometheus, Argo CD plus loin) publient un chart officiel. Le cours utilise Helm 4.3.0.

Les fichiers sont dans [l'archive helm](pathname:///kits/helm.tar.gz).

```bash
kubectl create namespace ch29
kubectl config set-context --current --namespace=ch29
```

## Se servir d'un chart

Avant d'en écrire un, servons-nous d'un chart existant : celui de **podinfo**, une petite application web écrite pour les démonstrations, dont le chart est publié dans un registre OCI, comme une image[^podinfo].

```bash
helm install demo oci://ghcr.io/stefanprodan/charts/podinfo --version 6.14.1
```

```sortie
NAME: demo
LAST DEPLOYED: Sat Sep 26 16:03:53 2026
NAMESPACE: ch29
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
NOTES:
1. Get the application URL by running these commands:
  echo "Visit http://127.0.0.1:8080 to use your application"
  kubectl -n ch29 port-forward deploy/demo-podinfo 8080:9898
```

`demo` est le nom de la **release** : une installation d'un chart, dans un namespace. Le même chart peut être installé plusieurs fois, sous des noms différents. Le texte qui suit `NOTES:` est écrit par l'auteur du chart, pour dire quoi faire ensuite.

```bash
helm list
kubectl get deploy,svc,pods
kubectl exec deploy/demo-podinfo -- wget -qO- localhost:9898 | jq -c '{hostname,version,message}'
```

```sortie
NAME	NAMESPACE	REVISION	UPDATED                                 	STATUS  	CHART         	APP VERSION
demo	ch29     	1       	2026-09-26 16:03:53.553000994 +0200 CEST	deployed	podinfo-6.14.1	6.14.1     
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/demo-podinfo   1/1     1            1           12s

NAME                   TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)             AGE
service/demo-podinfo   ClusterIP   10.96.254.142   <none>        9898/TCP,9999/TCP   12s

NAME                                READY   STATUS    RESTARTS   AGE
pod/demo-podinfo-7ddbf4f986-g7pgm   1/1     Running   0          12s
{"hostname":"demo-podinfo-7ddbf4f986-g7pgm","version":"6.14.1","message":"greetings from podinfo v6.14.1"}
```

Helm a créé un Deployment et un Service, des objets ordinaires. Deux numéros de version coexistent : celui du **chart** (`podinfo-6.14.1`, la version de l'emballage) et celui de l'**application** qu'il déploie (`APP VERSION 6.14.1`). Ici ils coïncident, ce n'est pas une règle.

### Les valeurs

Un chart se règle par des **valeurs**, un document YAML dont le chart fournit les valeurs par défaut (`helm show values` les affiche, avec leurs commentaires). On donne les siennes dans un fichier, avec `-f`, ou une par une, avec `--set`. Passons à la version 6.15.0 du chart, avec nos réglages :

```yaml title="podinfo-valeurs.yaml"
replicaCount: 2
ui:
  message: "Bonjour depuis Helm"
resources:
  requests:
    cpu: 10m
    memory: 32Mi
  limits:
    memory: 64Mi
```

```bash
helm upgrade demo oci://ghcr.io/stefanprodan/charts/podinfo --version 6.15.0 -f podinfo-valeurs.yaml
kubectl exec deploy/demo-podinfo -- wget -qO- localhost:9898 | jq -c '{hostname,version,message}'
helm history demo
helm get values demo
```

```sortie
Release "demo" has been upgraded. Happy Helming!
STATUS: deployed
REVISION: 2
{"hostname":"demo-podinfo-7fcc79c9c5-6hp6w","version":"6.15.0","message":"Bonjour depuis Helm"}
REVISION	UPDATED                 	STATUS    	CHART         	APP VERSION	DESCRIPTION     
1       	Sat Sep 26 16:03:53 2026	superseded	podinfo-6.14.1	6.14.1     	Install complete
2       	Sat Sep 26 16:04:06 2026	deployed  	podinfo-6.15.0	6.15.0     	Upgrade complete
USER-SUPPLIED VALUES:
replicaCount: 2
resources:
  limits:
    memory: 64Mi
  requests:
    cpu: 10m
    memory: 32Mi
ui:
  message: Bonjour depuis Helm
```

La release est passée à la révision 2 : nouvelle version, deux répliques, notre message. `helm get values` rappelle les valeurs **données par l'utilisateur** pour la révision en cours ; ce sont elles qu'il faut archiver (dans Git, de préférence), car ce sont elles qui distinguent votre installation de toutes les autres.

### Revenir en arrière

```bash
helm rollback demo 1
helm history demo
kubectl exec deploy/demo-podinfo -- wget -qO- localhost:9898 | jq -c '{version,message}'
```

```sortie
Rollback was a success! Happy Helming!
REVISION	UPDATED                 	STATUS    	CHART         	APP VERSION	DESCRIPTION     
1       	Sat Sep 26 16:03:53 2026	superseded	podinfo-6.14.1	6.14.1     	Install complete
2       	Sat Sep 26 16:04:06 2026	superseded	podinfo-6.15.0	6.15.0     	Upgrade complete
3       	Sat Sep 26 16:04:10 2026	deployed  	podinfo-6.14.1	6.14.1     	Rollback to 1   
{"version":"6.14.1","message":"greetings from podinfo v6.14.1"}
```

Un retour arrière ne supprime pas la révision 2 : il crée une révision 3, copie de la 1. Tout est revenu, l'image, le nombre de répliques, le message : c'est l'ensemble des objets de la révision 1 qui a été réappliqué, pas seulement le modèle d'un Deployment comme avec `kubectl rollout undo` (chapitre 19).

### Où Helm range ses releases

Helm 2 installait dans le cluster un serveur, Tiller, doté de droits étendus, qui gardait l'état des releases. Tiller a disparu avec Helm 3, en 2019 : c'était un problème de sécurité et une source de pannes[^helm3]. Depuis, Helm n'est qu'un client, comme kubectl, et il range l'état de chaque révision dans un Secret du namespace de la release :

```bash
kubectl get secrets
kubectl get secret sh.helm.release.v1.demo.v3 -o jsonpath='{.data.release}' | base64 -d | base64 -d | gunzip \
  | jq -c '{name, version, statut: .info.status, chart: .chart.metadata.version, apply_method, cles: keys}'
kubectl get deploy demo-podinfo -o jsonpath='{.metadata.labels}{"\n"}{.metadata.annotations}{"\n"}'
```

```sortie
NAME                         TYPE                 DATA   AGE
sh.helm.release.v1.demo.v1   helm.sh/release.v1   1      30s
sh.helm.release.v1.demo.v2   helm.sh/release.v1   1      17s
sh.helm.release.v1.demo.v3   helm.sh/release.v1   1      13s
{"name":"demo","version":3,"statut":"deployed","chart":"6.14.1","apply_method":"ssa","cles":["apply_method","chart","hooks","info","manifest","name","namespace","version"]}
{"app.kubernetes.io/managed-by":"Helm","app.kubernetes.io/name":"demo-podinfo","app.kubernetes.io/version":"6.14.1","helm.sh/chart":"podinfo-6.14.1"}
{"deployment.kubernetes.io/revision":"3","meta.helm.sh/release-name":"demo","meta.helm.sh/release-namespace":"ch29"}
```

Un Secret par révision, de type `helm.sh/release.v1`. Son contenu est encodé deux fois en base64 et compressé : c'est un document JSON qui contient le chart entier, les valeurs, et les manifestes rendus de cette révision, ce qui permet à `helm rollback` de les réappliquer sans avoir le chart sous la main. `apply_method: ssa` confirme que Helm 4 applique les objets par *server-side apply* (chapitre 18). Chaque objet porte l'étiquette `app.kubernetes.io/managed-by: Helm` et les annotations `meta.helm.sh/release-name` et `release-namespace` : c'est ainsi que Helm reconnaît ses objets, et refuse de prendre ceux d'une autre release. Comme les valeurs peuvent contenir des mots de passe, ces Secrets méritent la même protection que les autres.

```bash
helm uninstall demo
```

## L'anatomie d'un chart

Un chart est un dossier. `helm create` en génère un exemple complet ; celui de Colis, dans le kit, a été écrit à la main à partir des manifestes des chapitres 25 à 28 :

```sortie
colis/
  Chart.yaml            le nom du chart, sa version, celle de l'application
  values.yaml           les valeurs par défaut, commentées
  templates/            les modèles de manifestes
    _helpers.tpl        des morceaux réutilisables
    config.yaml  secret.yaml  postgres.yaml  redis.yaml  api.yaml  worker.yaml
    web.yaml  purge.yaml  sauvegarde.yaml  route.yaml  NOTES.txt
    tests/test-pret.yaml
```

```yaml title="colis/Chart.yaml"
apiVersion: v2
name: colis
description: Colis, le service de suivi de colis du cours « Conteneurs et Kubernetes »
type: application
version: 0.1.1          # version du chart
appVersion: "2.1.0"     # version de l'application qu'il déploie
```

La version du chart suit le *semantic versioning* : chaque modification du chart, même sans changer d'application, en demande une nouvelle.

### Les modèles

Les fichiers de `templates/` sont des manifestes où des expressions entre `{{` et `}}` sont remplacées au moment du rendu. Le langage est celui des modèles de Go, complété par les fonctions de la bibliothèque Sprig[^modeles]. Un extrait du Deployment de l'API :

```yaml title="colis/templates/api.yaml (extrait)"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  labels:
    {{- include "colis.etiquettes" . | nindent 4 }}
    app.kubernetes.io/name: api
spec:
  replicas: {{ .Values.api.repliques }}
  template:
    metadata:
      annotations:
        # change quand la ConfigMap change : les Pods sont alors remplacés (chapitre 21)
        checksum/config: {{ include (print $.Template.BasePath "/config.yaml") . | sha256sum }}
    spec:
      containers:
      - name: api
        image: {{ include "colis.imageApi" . }}
        {{- include "colis.env" . | nindent 8 }}
        resources:
          {{- toYaml .Values.api.ressources | nindent 10 }}
```

Les objets disponibles dans un modèle sont `.Values` (les valeurs fusionnées), `.Release` (le nom, le namespace, le numéro de révision), `.Chart` (le contenu de `Chart.yaml`), et quelques autres. Les **fonctions** se chaînent avec `|`, comme dans un shell : `toYaml` transforme une valeur en YAML, `nindent 10` l'indente de dix espaces (le YAML est sensible à l'indentation, et c'est la première source d'erreurs d'un chart), `quote` l'entoure de guillemets, `default` fournit une valeur de repli. Le `-` dans `{{-` supprime les blancs qui précèdent, pour ne pas laisser de lignes vides. `include` insère un morceau défini dans `_helpers.tpl` :

```yaml title="colis/templates/_helpers.tpl (extrait)"
{{/* Étiquettes communes à tous les objets du chart. */}}
{{- define "colis.etiquettes" -}}
app.kubernetes.io/part-of: colis
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}
```

Les variables d'environnement communes à l'API, au worker et à la purge (la ConfigMap, le mot de passe, `COLIS_DB`) sont définies une seule fois de la même manière, dans `colis.env`. L'annotation `checksum/config` règle un problème du chapitre 21 : un Pod qui lit une ConfigMap en variables d'environnement ne voit pas ses changements. Ici, l'empreinte SHA-256 de la ConfigMap rendue est inscrite dans le modèle de Pod ; quand la ConfigMap change, l'empreinte change, le modèle change, et le Deployment remplace ses Pods.

Les conditions se font avec `if`, les boucles avec `range`, et `with` change de contexte le temps d'un bloc. Le chart publie Colis sur une Gateway seulement si on le lui demande :

```yaml title="colis/templates/route.yaml (extrait)"
{{- if .Values.passerelle.activee }}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: colis
spec:
  parentRefs:
  - name: {{ .Values.passerelle.nom }}
    namespace: {{ .Values.passerelle.namespace }}
    sectionName: {{ .Values.passerelle.ecouteur }}
  hostnames:
  - {{ .Values.passerelle.hote | quote }}
  # ... les deux règles du chapitre 28
{{- end }}
```

### Vérifier avant d'installer

`helm lint` vérifie la structure du chart, et `helm template` affiche les manifestes rendus sans rien envoyer au cluster :

```bash
helm lint colis
helm template essai colis -n colis-helm --set passerelle.activee=true | grep -E '^# Source|^kind:' | paste - -
helm template essai colis --set api.repliques=5 | grep -A3 'name: api$' | grep replicas
```

```sortie
==> Linting colis
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed
# Source: colis/templates/secret.yaml	kind: Secret
# Source: colis/templates/config.yaml	kind: ConfigMap
# Source: colis/templates/sauvegarde.yaml	kind: PersistentVolumeClaim
# Source: colis/templates/api.yaml	kind: Service
# Source: colis/templates/postgres.yaml	kind: Service
# Source: colis/templates/redis.yaml	kind: Service
# Source: colis/templates/web.yaml	kind: Service
# Source: colis/templates/api.yaml	kind: Deployment
# Source: colis/templates/redis.yaml	kind: Deployment
# Source: colis/templates/web.yaml	kind: Deployment
# Source: colis/templates/worker.yaml	kind: Deployment
# Source: colis/templates/postgres.yaml	kind: StatefulSet
# Source: colis/templates/purge.yaml	kind: CronJob
# Source: colis/templates/route.yaml	kind: HTTPRoute
# Source: colis/templates/tests/test-pret.yaml	kind: Pod
# Source: colis/templates/sauvegarde.yaml	kind: Job
  replicas: 5
```

Seize objets, dans l'ordre où Helm les appliquera : il trie par type, les Secrets et ConfigMaps d'abord, les charges de travail ensuite, pour que les dépendances existent avant ceux qui les utilisent. Les deux derniers ne font pas partie de l'installation normale ; ce sont un test et un *hook*, qu'on verra plus loin.

<Figure svg={helmRendu} num="29.1" alt="Le chart colis 0.1.1 (Chart.yaml, values.yaml avec les valeurs par défaut, templates/*.yaml et templates/_helpers.tpl) et vos valeurs (-f mes-valeurs.yaml, --set api.repliques=3, --reuse-values) entrent dans le rendu : les modèles Go, avec .Values, .Release, .Chart, include, et lookup qui lit le cluster. Il en sort les manifestes, 16 objets YAML, ce qu'affiche helm template. Puis, dans l'ordre : 1, le hook pre-upgrade, le Job sauvegarde-avant-maj, attendu jusqu'à sa fin ; 2, les objets de la release, appliqués en server-side ; 3, le Secret sh.helm.release.v1.colis.v2, la révision. La révision précédente reste dans son propre Secret : helm rollback rejoue ses manifestes et crée une nouvelle révision. L'API server ne connaît que des objets ordinaires : Helm n'est qu'un client, rien ne tourne dans le cluster.">
Ce que fait <code>helm upgrade</code> : un rendu, côté client, puis des objets ordinaires envoyés à l'API server, et une trace de la révision dans un Secret.
</Figure>

## Le chart de Colis

Les valeurs par défaut du chart reprennent les réglages des chapitres précédents :

```yaml title="colis/values.yaml (extrait)"
images:
  registre: host.minikube.internal:5001
  api:
    depot: colis/api
    etiquette: "2.1"       # l'étiquette publiée dans le registre (vide : l'appVersion du chart)
  web:
    depot: colis/web
    etiquette: "1.0"

api:
  repliques: 2
  ressources:
    requests: {cpu: 100m, memory: 192Mi}
    limits: {memory: 256Mi}

postgres:
  stockage: 1Gi
  classe: ""               # vide : la StorageClass par défaut du cluster

purge:
  planning: "0 3 * * *"
  fuseau: Europe/Paris
  jours: 30

passerelle:
  activee: false           # publier Colis sur une Gateway (chapitre 28)
  nom: principale
  namespace: passerelle
  ecouteur: http
  hote: colis.local
```

Un choix de conception mérite d'être signalé : les Services gardent leurs noms fixes, `api`, `postgres`, `redis` et `web`, au lieu d'être préfixés par le nom de la release comme le font la plupart des charts. La raison est dans l'image `web` : sa configuration nginx relaie vers `http://api:8000/`, un nom écrit en dur au chapitre 6. La conséquence : une seule release de Colis par namespace. L'exercice 3 revient sur ce compromis.

:::panne[appVersion n'est pas une étiquette d'image]

La première version de ce chart prenait par défaut l'`appVersion`, `2.1.0`, comme étiquette de l'image de l'API. Le registre ne contient que `2.1` :

```sortie
    Image:          host.minikube.internal:5001/colis/api:2.1.0
```

et les Pods restaient en `ImagePullBackOff`. `appVersion` est une indication pour les humains, que Helm n'utilise pour rien ; rien ne garantit qu'une image porte ce nom. D'où la valeur `images.api.etiquette: "2.1"` explicite. Dans vos propres projets, le plus simple est de publier les images avec l'étiquette exacte de l'`appVersion`, par exemple `2.1.0`, dans la chaîne de livraison (chapitre 57).

:::

### Le mot de passe de la base

Le chart doit créer le Secret du mot de passe de PostgreSQL, que le chapitre 24 créait à la main. Tirer une valeur au hasard semble évident, avec la fonction `randAlphaNum` :

```yaml
data:
  POSTGRES_PASSWORD: {{ randAlphaNum 24 | b64enc }}
```

Pour l'essayer, copiez le dossier `colis` sous le nom `piege` et remplacez le contenu de `templates/secret.yaml` par ces lignes (avec l'en-tête `apiVersion`, `kind` et `metadata` d'un Secret nommé `colis-db`). Installons ce chart naïf, puis faisons une mise à jour qui ajoute une réplique de l'API :

```bash
helm install piege ./piege --set api.repliques=1 --wait
kubectl get secret colis-db -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d; echo
helm upgrade piege ./piege --set api.repliques=2
kubectl get secret colis-db -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d; echo
kubectl get pods -l app.kubernetes.io/name=api --sort-by=.metadata.creationTimestamp
kubectl logs api-5cd656c9d5-xzxms --previous | tail -1
```

```sortie
zE15mdq2pUjTPMLZytcBE1y2
clKoHPHowrR6Jlft9UTUshRZ
NAME                   READY   STATUS             RESTARTS      AGE
api-5cd656c9d5-qdb64   1/1     Running            1 (49s ago)   57s
api-5cd656c9d5-xzxms   0/1     CrashLoopBackOff   2 (27s ago)   45s
psycopg.OperationalError: connection failed: connection to server at "10.244.0.162", port 5432 failed: FATAL:  password authentication failed for user "colis"
```

Le rendu est refait à chaque `helm upgrade`, et `randAlphaNum` tire un nouveau mot de passe à chaque fois. Le Secret a changé. PostgreSQL, lui, ne lit `POSTGRES_PASSWORD` qu'à la création de sa base, et garde l'ancien mot de passe. Le premier Pod de l'API tourne encore avec l'ancienne valeur, lue à son démarrage ; le nouveau reçoit la nouvelle, et se fait refuser. La prochaine mise à jour de l'API, ou le premier redémarrage d'un Pod, et tout Colis tombe.

La solution est la fonction `lookup`, qui lit un objet dans le cluster pendant le rendu[^lookup]. Le mot de passe n'est tiré au hasard que si le Secret n'existe pas encore :

```yaml title="colis/templates/secret.yaml"
{{- $existant := lookup "v1" "Secret" .Release.Namespace "colis-db" }}
apiVersion: v1
kind: Secret
metadata:
  name: colis-db
  labels:
    {{- include "colis.etiquettes" . | nindent 4 }}
  annotations:
    helm.sh/resource-policy: keep
type: Opaque
data:
  {{- if $existant }}
  POSTGRES_PASSWORD: {{ index $existant.data "POSTGRES_PASSWORD" }}
  {{- else }}
  POSTGRES_PASSWORD: {{ randAlphaNum 24 | b64enc }}
  {{- end }}
```

L'annotation `helm.sh/resource-policy: keep` sert au second piège, un peu plus loin.

### Installer, tester, mettre à jour

Colis va dans un namespace à lui, `colis-helm`, publié sur la passerelle du chapitre 28 sous le nom `colis-helm.local` ; le namespace porte l'étiquette que la passerelle exige :

```bash
kubectl create namespace colis-helm
kubectl label namespace colis-helm passerelle=principale
helm install colis ./colis -n colis-helm --set passerelle.activee=true --set passerelle.hote=colis-helm.local --wait
kubectl -n colis-helm get pods,pvc
```

```sortie
NAME: colis
LAST DEPLOYED: Sat Sep 26 16:05:23 2026
NAMESPACE: colis-helm
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
NOTES:
Colis 2.1.0 est installé dans le namespace colis-helm (révision 1).

Vérifier que tout répond :
  helm test colis -n colis-helm

Colis est publié sur la passerelle passerelle/principale, pour l'hôte colis-helm.local.
Le namespace colis-helm doit porter l'étiquette que la passerelle exige.
NAME                          READY   STATUS    RESTARTS     AGE
pod/api-7699fd8c85-qtvc9      1/1     Running   1 (4s ago)   12s
pod/api-7699fd8c85-qwlt5      1/1     Running   1 (4s ago)   12s
pod/postgres-0                1/1     Running   0            12s
pod/redis-5dbc48d8b9-ktp5s    1/1     Running   0            12s
pod/web-7bd966d7cc-mnrhc      1/1     Running   0            12s
pod/web-7bd966d7cc-qq5n4      1/1     Running   0            12s
pod/worker-647dcbf7fc-n62s2   1/1     Running   1 (4s ago)   12s

NAME                                       STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
persistentvolumeclaim/donnees-postgres-0   Bound    pvc-9b35af33-058e-40a2-8e07-8218ff0f952e   1Gi        RWO            standard       <unset>                 12s
persistentvolumeclaim/sauvegardes          Bound    pvc-970de2db-d558-4267-a00d-925f7f70ce2a   1Gi        RWO            standard       <unset>                 12s
```

Tout Colis, avec sa base en StatefulSet, sa file, son CronJob et sa route, installé en 12 secondes par une commande. `--wait` fait attendre Helm que les objets soient prêts avant de déclarer la release `deployed`. Le chart contient un **test**, un Pod marqué par l'annotation `helm.sh/hook: test`, que `helm test` lance à la demande :

```yaml title="colis/templates/tests/test-pret.yaml (extrait)"
metadata:
  name: colis-test-pret
  annotations:
    helm.sh/hook: test
spec:
  restartPolicy: Never
  containers:
  - name: test
    image: busybox:1.37
    command: ["sh", "-c", "wget -qO- http://web/api/pret | tee /dev/stderr | grep -q '\"pret\":true'"]
```

```bash
helm test colis -n colis-helm
kubectl -n colis-helm logs colis-test-pret; echo
curl -s -H 'Host: colis-helm.local' http://192.168.49.102/api/sante; echo
```

```sortie
TEST SUITE:     colis-test-pret
Phase:          Succeeded
{"stockage":"postgres","file":"redis","pret":true}
{"statut":"ok","version":"2.1.0","hote":"api-7699fd8c85-qtvc9"}
```

Le test traverse toute la chaîne, du site à la base. Enregistrons un colis, puis faisons une mise à jour qui change un réglage du worker (le temps de calcul simulé, qui est dans la ConfigMap) et le nombre de répliques de l'API. `--reuse-values` reprend les valeurs de la révision précédente, auxquelles s'ajoutent les nouvelles :

```bash
curl -s -X POST http://192.168.49.102/api/colis -H 'Host: colis-helm.local' -H 'Content-Type: application/json' \
  -d '{"destinataire":"Frances Allen","depart":"Paris","arrivee":"Nantes","poids_kg":1.1}' | jq -c '{id,destinataire}'
helm upgrade colis ./colis -n colis-helm --reuse-values --set api.repliques=3 --set worker.pause=0.2 --wait
kubectl -n colis-helm get jobs
kubectl -n colis-helm logs job/sauvegarde-avant-maj
kubectl -n colis-helm get deploy api worker
helm -n colis-helm history colis
```

```sortie
{"id":1,"destinataire":"Frances Allen"}
STATUS: deployed
REVISION: 2
NAME                   STATUS     COMPLETIONS   DURATION   AGE
sauvegarde-avant-maj   Complete   1/1           3s         17s
-rw-r--r--    1 root     root          2999 Sep 26 14:05 /sauvegardes/colis-revision-2-20260926-140540.dump
NAME     READY   UP-TO-DATE   AVAILABLE   AGE
api      3/3     3            3           34s
worker   1/1     1            1           34s
REVISION	UPDATED                 	STATUS    	CHART      	APP VERSION	DESCRIPTION     
1       	Sat Sep 26 16:05:23 2026	superseded	colis-0.1.0	2.1.0      	Install complete
2       	Sat Sep 26 16:05:39 2026	deployed  	colis-0.1.0	2.1.0      	Upgrade complete
```

Trois vérifications, faites par le script du chapitre avant et après la mise à jour :

```sortie
mot de passe inchangé
checksum : ee249d867520... -> 400cb1814c51...
[{"id":1,"destinataire":"Frances Allen"}]
```

Le mot de passe n'a pas bougé, grâce à `lookup`. L'empreinte de la ConfigMap a changé, et le worker a été remplacé pour prendre le nouveau réglage. Le colis est toujours là.

### Les hooks

Le Job `sauvegarde-avant-maj` a tourné **avant** que la mise à jour commence : c'est un *hook*, un objet que Helm crée à un moment précis du cycle de vie d'une release, et dont il attend la fin avant de continuer[^hooks]. L'annotation `helm.sh/hook` dit quand : `pre-install`, `post-install`, `pre-upgrade`, `post-upgrade`, `pre-rollback`, `pre-delete`, `post-delete`, ou `test` :

```yaml title="colis/templates/sauvegarde.yaml (extrait)"
apiVersion: batch/v1
kind: Job
metadata:
  name: sauvegarde-avant-maj
  annotations:
    helm.sh/hook: pre-upgrade
    helm.sh/hook-weight: "0"
    helm.sh/hook-delete-policy: before-hook-creation
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: pg-dump
        image: {{ .Values.images.postgres }}
        command: ["sh", "-c"]
        args:
        - |
          f=/sauvegardes/colis-revision-{{ .Release.Revision }}-$(date -u +%Y%m%d-%H%M%S).dump
          pg_dump -h postgres -U colis -d colis -Fc -f "$f" && ls -l "$f"
        # ... le mot de passe et le volume sauvegardes
```

Si le Job échoue, la mise à jour s'arrête avant d'avoir touché à quoi que ce soit, et la release passe `failed` : une sauvegarde ratée empêche une mise à jour risquée. `hook-weight` ordonne plusieurs hooks d'un même moment, et `hook-delete-policy: before-hook-creation` supprime le Job de la fois précédente avant de le recréer. Les migrations de schéma de base de données sont l'autre usage classique des hooks `pre-upgrade`.

Revenons à la révision 1 :

```bash
helm -n colis-helm rollback colis 1 --wait
kubectl -n colis-helm get deploy api worker
```

```sortie
Rollback was a success! Happy Helming!
NAME     READY   UP-TO-DATE   AVAILABLE   AGE
api      2/2     2            2           43s
worker   1/1     1            1           43s
```

Le hook `pre-upgrade` n'a pas tourné : un retour arrière déclenche les hooks `pre-rollback` et `post-rollback`, que ce chart n'a pas.

### Publier le chart dans un registre

Un chart se publie comme une image, dans un registre OCI (chapitre 14). `helm package` en fait une archive, `helm push` l'envoie :

```bash
helm package colis
helm push colis-0.1.0.tgz oci://localhost:5001/charts --plain-http
helm show chart oci://localhost:5001/charts/colis --version 0.1.0 --plain-http
```

```sortie
Successfully packaged chart and saved it to: ../colis-0.1.0.tgz
Pushed: localhost:5001/charts/colis:0.1.0
Digest: sha256:c80fbded9874c76488bd42f5b596a6d33a9147a82ec0989c93bc329ee5bb0080
apiVersion: v2
appVersion: 2.1.0
description: Colis, le service de suivi de colis du cours « Conteneurs et Kubernetes
  »
name: colis
type: application
version: 0.1.0
```

`--plain-http` est nécessaire parce que le registre du cours parle HTTP. Le chart s'installe désormais depuis n'importe quel poste qui joint le registre, avec `helm install colis oci://localhost:5001/charts/colis --version 0.1.0`, sans le dossier du chart. Les archives de charts publics se trouvent sur Artifact Hub, qui recense les charts de milliers de projets[^artifacthub].

### Désinstaller, et réinstaller

La version 0.1.0 du chart, celle publiée à l'instant, avait `lookup` mais pas encore l'annotation `keep` sur le Secret. Désinstallons :

```bash
helm -n colis-helm uninstall colis --wait
kubectl -n colis-helm get all,pvc,secret
```

```sortie
These resources were kept due to the resource policy:
[PersistentVolumeClaim] sauvegardes

release "colis" uninstalled
NAME                             READY   STATUS      RESTARTS   AGE
pod/colis-test-pret              0/1     Completed   0          52s
pod/sauvegarde-avant-maj-xxb4f   0/1     Completed   0          48s

NAME                             STATUS     COMPLETIONS   DURATION   AGE
job.batch/sauvegarde-avant-maj   Complete   1/1           3s         48s

NAME                                       STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
persistentvolumeclaim/donnees-postgres-0   Bound    pvc-9b35af33-058e-40a2-8e07-8218ff0f952e   1Gi        RWO            standard       <unset>                 64s
persistentvolumeclaim/sauvegardes          Bound    pvc-970de2db-d558-4267-a00d-925f7f70ce2a   1Gi        RWO            standard       <unset>                 64s
```

Trois choses restent. La demande `sauvegardes`, que son annotation `helm.sh/resource-policy: keep` protège : Helm la signale. La demande `donnees-postgres-0`, que Helm n'a jamais créée lui-même : c'est le StatefulSet qui l'a créée à partir de son modèle (chapitre 26), et Helm ne supprime que ses propres objets. Et le Pod de test et le Job du hook, qui ne font pas partie des objets de la release. Le Secret `colis-db`, lui, a disparu. Réinstallons, depuis le registre :

```bash
helm install colis oci://localhost:5001/charts/colis --version 0.1.0 --plain-http -n colis-helm \
  --set passerelle.activee=true --set passerelle.hote=colis-helm.local --wait --timeout 90s
kubectl -n colis-helm get pods -l app.kubernetes.io/name=api
kubectl -n colis-helm logs postgres-0 | grep -m1 'Skipping initialization'
```

```sortie
Pulled: localhost:5001/charts/colis:0.1.0
Error: INSTALLATION FAILED: resource Deployment/colis-helm/api not ready. status: InProgress, message: Available: 0/2
NAME                   READY   STATUS             RESTARTS      AGE
api-7699fd8c85-2xrb2   0/1     CrashLoopBackOff   3 (42s ago)   91s
api-7699fd8c85-f4x4f   0/1     CrashLoopBackOff   3 (41s ago)   91s
PostgreSQL Database directory appears to contain a database; Skipping initialization
```

Le piège du mot de passe, sous une autre forme. Le StatefulSet recréé a retrouvé sa demande, donc sa base, et PostgreSQL a sauté l'initialisation. Mais le Secret était parti ; `lookup` n'a rien trouvé, et un nouveau mot de passe a été tiré, que la base ne connaît pas. La figure 29.2 résume ce qui reste et ce qui part.

<Figure svg={helmDesinstaller} num="29.2" alt="Deux cadres. Supprimé par helm uninstall : les Deployments, le StatefulSet et les Services ; la ConfigMap, le CronJob et la HTTPRoute ; les Secrets des révisions sh.helm.release ; et, avec le chart 0.1.0, le Secret colis-db. Gardé : la PVC donnees-postgres-0, créée par le StatefulSet ; la PVC sauvegardes, resource-policy keep ; le Secret colis-db, keep, avec le chart 0.1.1 ; et le Job du hook et le Pod de test, hors de la release. Avec le chart 0.1.0, la base est gardée mais son mot de passe est perdu : à la réinstallation, un nouveau mot de passe est tiré, PostgreSQL, qui ne relit pas POSTGRES_PASSWORD sur une base existante, garde l'ancien, et l'API échoue.">
Ce qui reste après <code>helm uninstall</code>. Les données survivent, et c'est souhaitable, mais le Secret qui permet de les lire doit survivre avec elles.
</Figure>

:::panne[password authentication failed après une réinstallation]

Les données ne sont pas perdues, et le mot de passe actuel du Secret peut devenir celui de la base. Depuis le Pod de PostgreSQL, la connexion locale ne demande pas de mot de passe :

```bash
M=$(kubectl -n colis-helm get secret colis-db -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
kubectl -n colis-helm exec postgres-0 -- psql -U colis -d colis -c "ALTER USER colis PASSWORD '$M';"
kubectl -n colis-helm rollout status deploy/api
curl -s -H 'Host: colis-helm.local' http://192.168.49.102/api/colis | jq -c '[.[] | {id,destinataire}]'
```

```sortie
ALTER ROLE
deployment "api" successfully rolled out
[{"id":1,"destinataire":"Frances Allen"}]
```

Le colis de Frances Allen, enregistré avant la désinstallation, est là. La release, elle, est restée `failed` : l'installation a expiré avant que l'API soit prête. Une mise à jour la répare.

:::

La prévention est l'annotation `helm.sh/resource-policy: keep` sur le Secret, comme sur la demande `sauvegardes` : c'est la version 0.1.1 du chart. Publions-la, mettons à jour la release, puis refaisons le cycle désinstaller-réinstaller :

```bash
helm package colis && helm push colis-0.1.1.tgz oci://localhost:5001/charts --plain-http
helm -n colis-helm upgrade colis oci://localhost:5001/charts/colis --version 0.1.1 --plain-http --reuse-values --wait
helm -n colis-helm uninstall colis --wait
helm -n colis-helm install colis oci://localhost:5001/charts/colis --version 0.1.1 --plain-http \
  --set passerelle.activee=true --set passerelle.hote=colis-helm.local --wait
kubectl -n colis-helm get pods -l app.kubernetes.io/name=api
curl -s -H 'Host: colis-helm.local' http://192.168.49.102/api/colis | jq -c '[.[] | {id,destinataire}]'
```

```sortie
Pushed: localhost:5001/charts/colis:0.1.1
STATUS: deployed
REVISION: 2
These resources were kept due to the resource policy:
[PersistentVolumeClaim] sauvegardes
[Secret] colis-db

release "colis" uninstalled
STATUS: deployed
NAME                   READY   STATUS    RESTARTS   AGE
api-777bbbdc7b-4cj69   1/1     Running   0          4s
api-777bbbdc7b-4hzl7   1/1     Running   0          4s
[{"id":1,"destinataire":"Frances Allen"}]
```

Le Secret est resté ; à la réinstallation, Helm l'a repris (ses annotations nomment la même release), `lookup` l'a trouvé, et l'API a démarré sans un seul redémarrage. La contrepartie est à connaître : un objet gardé n'appartient plus à personne, et le jour où l'on veut vraiment tout supprimer, il faut supprimer à la main le Secret et les deux demandes de volume.

## Exercices

:::exercice[Exercice 1 : refuser les mauvaises valeurs]

Rien n'empêche aujourd'hui `--set api.repliques=0` ou `--set purge.jours=trente`, qui donneraient un Colis sans API ou une ConfigMap que la purge ne sait pas lire. Ajoutez au chart un schéma qui les refuse.

:::

<details>
<summary>Corrigé</summary>

Un fichier `values.schema.json`, au format JSON Schema, à la racine du chart[^schema] (le kit le contient, à côté du dossier `colis`) :

```json title="colis/values.schema.json"
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "properties": {
    "api": {
      "type": "object",
      "properties": {
        "repliques": {"type": "integer", "minimum": 1, "maximum": 10}
      }
    },
    "purge": {
      "type": "object",
      "properties": {
        "jours": {"type": "integer", "minimum": 1}
      }
    }
  }
}
```

```bash
helm lint colis --set api.repliques=0
helm template x colis --set purge.jours=trente
```

```sortie
- at '/api/repliques': minimum: got 0, want 1

Error: 1 chart(s) linted, 1 chart(s) failed
colis:
- at '/purge/jours': got string, want integer
```

Helm valide les valeurs fusionnées contre le schéma avant tout rendu, pour `lint`, `template`, `install` et `upgrade`. L'erreur arrive donc avant que le moindre objet soit envoyé au cluster, avec le chemin de la valeur fautive. Un schéma documente aussi le chart : un éditeur qui le connaît complète les noms de valeurs.

</details>

:::exercice[Exercice 2 : voir avant d'appliquer]

Avant de lancer `helm upgrade colis ... --set api.repliques=3 --set purge.jours=7` en production, on veut voir quels objets vont changer. Proposez une méthode, essayez-la, et relevez ses limites.

:::

<details>
<summary>Corrigé</summary>

Rendre les manifestes avec les mêmes valeurs, et les comparer au cluster avec `kubectl diff` (chapitre 18) :

```bash
helm -n colis-helm get values colis -o yaml > valeurs.yaml
helm template colis ./colis -n colis-helm -f valeurs.yaml --set api.repliques=3 --set purge.jours=7 \
  | kubectl -n colis-helm diff -f - | grep -E '^diff'
```

```sortie
diff -u -N /tmp/LIVE-1642196990/apps.v1.Deployment.colis-helm.api /tmp/MERGED-923315947/apps.v1.Deployment.colis-helm.api
diff -u -N /tmp/LIVE-1642196990/apps.v1.Deployment.colis-helm.worker /tmp/MERGED-923315947/apps.v1.Deployment.colis-helm.worker
diff -u -N /tmp/LIVE-1642196990/batch.v1.Job.colis-helm.sauvegarde-avant-maj /tmp/MERGED-923315947/batch.v1.Job.colis-helm.sauvegarde-avant-maj
diff -u -N /tmp/LIVE-1642196990/v1.ConfigMap.colis-helm.colis-config /tmp/MERGED-923315947/v1.ConfigMap.colis-helm.colis-config
diff -u -N /tmp/LIVE-1642196990/v1.Pod.colis-helm.colis-test-pret /tmp/MERGED-923315947/v1.Pod.colis-helm.colis-test-pret
diff -u -N /tmp/LIVE-1642196990/v1.Secret.colis-helm.colis-db /tmp/MERGED-923315947/v1.Secret.colis-helm.colis-db
```

Le Deployment de l'API (répliques et empreinte), celui du worker (empreinte), la ConfigMap (les jours de purge) : c'est attendu. Mais la liste contient aussi le hook et le test, que `helm template` rend comme des objets ordinaires, et surtout le **Secret** : `helm template` ne parle pas au cluster, `lookup` n'y trouve rien, et un nouveau mot de passe est tiré. Ce diff est donc trompeur sur ce point, et il ne faudrait surtout pas appliquer ce rendu avec `kubectl apply`. `helm upgrade --dry-run=server` interroge le cluster pour `lookup` et donne le vrai rendu, sans rien appliquer ; le greffon `helm-diff`, très utilisé, compare ce rendu à la révision en cours et affiche un diff lisible.

</details>

:::exercice[Exercice 3 : deux Colis dans un namespace]

Le chart de Colis impose une release par namespace, parce que ses Services ont des noms fixes. Que faudrait-il changer, dans le chart et dans l'application, pour pouvoir installer `colis-a` et `colis-b` dans le même namespace ? Est-ce souhaitable ?

:::

<details>
<summary>Corrigé</summary>

Dans le chart, préfixer tous les noms par la release (`{{ .Release.Name }}-api`, `{{ .Release.Name }}-postgres`...), ce que `helm create` fait avec un morceau `fullname` dans `_helpers.tpl` ; ajouter l'étiquette `app.kubernetes.io/instance` aux sélecteurs, ce que le chart fait déjà, pour que les Services de `colis-a` ne sélectionnent pas les Pods de `colis-b` ; et construire `COLIS_REDIS` et `COLIS_DB` avec ces noms. Dans l'application, il faudrait que l'image `web` ne relaie plus vers le nom fixe `api` : soit une configuration nginx fournie par une ConfigMap (générée par le chart avec le bon nom), soit une variable d'environnement que l'image substitue au démarrage (l'image officielle de nginx sait le faire avec ses modèles `*.template`). Plus simple encore : ne plus passer par `web` pour `/api`, puisque la route de la passerelle envoie déjà `/api` directement à l'API depuis le chapitre 28.

Est-ce souhaitable ? Pour un chart destiné à d'autres, oui : les utilisateurs s'attendent à pouvoir installer deux releases côte à côte, et les noms préfixés évitent les collisions. Pour une application interne, un namespace par copie a ses avantages : les quotas, les droits d'accès (partie VI) et les règles réseau se règlent par namespace, et `kubectl delete namespace` fait le ménage complet. Beaucoup d'équipes choisissent donc un namespace par environnement, même quand le chart permettrait mieux.

</details>

## Accéder à Colis, et nettoyer

La release `colis` reste installée dans `colis-helm` ; Colis y est servi à `http://colis-helm.local/` par la passerelle :

```bash
curl -s -H 'Host: colis-helm.local' http://192.168.49.102/api/colis
helm -n colis-helm list
```

Pour tout retirer, y compris ce que Helm garde volontairement :

```bash
helm -n colis-helm uninstall colis
kubectl -n colis-helm delete secret colis-db
kubectl -n colis-helm delete pvc sauvegardes donnees-postgres-0
kubectl delete namespace colis-helm ch29
kubectl config set-context --current --namespace=default
```

Les charts publiés restent dans le registre : `curl -s localhost:5001/v2/charts/colis/tags/list` les liste.

[^podinfo]: Stefan Prodan, podinfo, dépôt et chart. [github.com/stefanprodan/podinfo](https://github.com/stefanprodan/podinfo)

[^helm3]: Helm, « Changes since Helm 2 », section *Removal of Tiller*. [helm.sh/docs/faq/changes_since_helm2](https://helm.sh/docs/faq/changes_since_helm2/)

[^modeles]: Helm, « Chart Template Guide », dont *Built-in Objects*, *Template Functions and Pipelines* et *Named Templates*. [helm.sh/docs/chart_template_guide](https://helm.sh/docs/chart_template_guide/)

[^lookup]: Helm, « Template Functions and Pipelines », section *Using the lookup function*, qui précise que `lookup` renvoie un résultat vide avec `helm template` et `--dry-run` côté client. [helm.sh/docs/chart_template_guide/functions_and_pipelines](https://helm.sh/docs/chart_template_guide/functions_and_pipelines/)

[^hooks]: Helm, « Chart Hooks », et « Chart Development Tips and Tricks », sections *Automatically Roll Deployments* (l'annotation d'empreinte) et *Tell Helm Not To Uninstall a Resource*. [helm.sh/docs/topics/charts_hooks](https://helm.sh/docs/topics/charts_hooks/)

[^artifacthub]: Artifact Hub, le catalogue des charts et autres paquets de l'écosystème, projet de la CNCF. [artifacthub.io](https://artifacthub.io/)

[^schema]: Helm, « Charts », section *Schema Files*. [helm.sh/docs/topics/charts](https://helm.sh/docs/topics/charts/#schema-files)
