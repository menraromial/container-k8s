---
title: GitOps avec Argo CD
sidebar_label: 57. GitOps avec Argo CD
description: "Livrer depuis un dépôt Git : un serveur Gitea dans le cluster, Argo CD et sa première Application, la synchronisation manuelle puis automatique, le sondage de trois minutes et le webhook qui le remplace, la dérive corrigée et son attente exponentielle, l'élagage, le conflit avec un HPA, et une application racine qui déclare les autres."
partie: 8
chapitre: '57'
---

import gitopsBoucle from '@site/src/figures/gitops-boucle.svg';
import gitopsRacine from '@site/src/figures/gitops-racine.svg';

Qui a mis ce Deployment à trois répliques, et quand ? Au défi VII, il a fallu fouiller les `managedFields` pour répondre : la modification avait été faite par un `kubectl patch`, que rien d'autre n'avait enregistré. La réponse la plus courte serait un historique, avec un auteur, une date, une raison et la possibilité de revenir en arrière. Git a tout cela depuis longtemps. Il reste à faire en sorte que le cluster suive le dépôt, et rien d'autre.

C'est l'idée du **GitOps**. Le groupe de travail OpenGitOps, sous l'égide de la CNCF, la résume en quatre principes : l'état voulu d'un système est déclaratif ; il est conservé de façon versionnée et immuable, avec tout son historique ; des agents logiciels vont le chercher eux-mêmes ; ils observent en continu l'état réel et le ramènent vers l'état voulu[^opengitops]. Le troisième principe est le plus concret. Personne ne pousse vers le cluster : un programme dans le cluster tire depuis le dépôt. Les droits d'écriture sur le cluster n'appartiennent plus aux personnes ni à la chaîne d'intégration, mais à ce programme.

Ce chapitre utilise **Argo CD**, projet diplômé de la CNCF[^argocd], avec un dépôt hébergé dans le cluster même, sur un serveur Gitea. Le dépôt reprend le Colis des overlays Kustomize du chapitre 30, pour un environnement de préproduction, `colis-staging`. Les fichiers sont dans [l'archive gitops](pathname:///kits/gitops.tar.gz).

## Un serveur Git dans le cluster

Un vrai projet utiliserait GitHub, GitLab ou un serveur de l'entreprise. Pour rester sur le poste, on installe Gitea, un serveur Git léger, avec sa base SQLite :

```yaml title="gitea.yaml (extrait)"
      containers:
      - name: gitea
        image: gitea/gitea:28.1.0-rootless
        env:
        - {name: GITEA__security__INSTALL_LOCK, value: "true"}        # pas d'assistant d'installation
        - {name: GITEA__database__DB_TYPE, value: sqlite3}
        - {name: GITEA__server__ROOT_URL, value: "http://gitea.git.svc.cluster.local:3000/"}
        - {name: GITEA__server__DISABLE_SSH, value: "true"}
        - {name: GITEA__service__DISABLE_REGISTRATION, value: "true"}
        - {name: GITEA__security__ALLOWED_HOST_LIST, value: "10.96.0.0/12"}  # webhooks vers les Services du cluster (Argo CD)
        - {name: GITEA__webhook__SKIP_TLS_VERIFY, value: "true"}      # Argo CD a un certificat autosigné
```

L'image `rootless` tourne sans root ; `INSTALL_LOCK` saute l'assistant d'installation. La dernière variable sert plus loin, au webhook.

```bash
kubectl apply -f gitea.yaml
kubectl -n git exec deploy/gitea -- gitea admin user create --username cours --password depot-du-cours-57 \
  --email cours@example.com --admin --must-change-password=false
kubectl -n git port-forward svc/gitea 3030:3000 &
curl -s -u cours:depot-du-cours-57 -X POST -H 'Content-Type: application/json' \
  -d '{"name":"colis-config","private":true,"default_branch":"main"}' http://localhost:3030/api/v1/user/repos
```

Le contenu du dépôt est dans le dossier `depot` de l'archive : la base du chapitre 30, passée à Colis 2.2.0, et un overlay `staging`.

```yaml title="depot/overlays/staging/kustomization.yaml"
# L'environnement de préproduction, géré par Argo CD. Le mot de passe de la base n'est pas ici :
# le Secret colis-db est créé à part, dans le namespace, et n'entre jamais dans le dépôt.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: colis-staging

resources:
- namespace.yaml
- ../../base

labels:
- pairs:
    environnement: staging

replicas:
- name: api
  count: 1
- name: web
  count: 1

patches:
- path: route.yaml
```

Le Secret `colis-db` n'est pas dans le dépôt : un mot de passe n'a rien à faire dans un historique que tout le monde peut lire et que personne ne peut effacer. Il sera créé à part, dans le namespace (le quatrième exercice discute des façons de le versionner quand même).

```bash
cd depot && git init -b main && git add -A && git commit -m "Colis 2.2.0 : base et préproduction"
git remote add origin http://cours:depot-du-cours-57@localhost:3030/cours/colis-config.git
git push origin main
```

```sortie
namespace/git created
persistentvolumeclaim/gitea created
deployment.apps/gitea created
service/gitea created
deployment "gitea" successfully rolled out
New user 'cours' has been successfully created!
{"full_name":"cours/colis-config","private":true}
3652350abe0ac49a73ee7d9a3efc9d77bf799cfc
3652350 Colis 2.2.0 : base et préproduction
base/api.yaml
base/kustomization.yaml
base/postgres.yaml
base/purge.yaml
base/redis.yaml
base/route.yaml
base/web.yaml
base/worker.yaml
overlays/staging/kustomization.yaml
overlays/staging/namespace.yaml
overlays/staging/route.yaml
NAME                     CPU(cores)   MEMORY(bytes)   
gitea-65547644cf-29gxb   96m          130Mi           
```

## Installer Argo CD

Argo CD s'installe par un manifeste, dans son propre namespace :

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.4/manifests/install.yaml
```

```sortie
namespace/argocd created
objets appliqués : 59
prêt après 46.49 s
NAME                                                READY   STATUS    RESTARTS   AGE
argocd-application-controller-0                     1/1     Running   0          43s
argocd-applicationset-controller-76fd8cdd4f-v4q8w   1/1     Running   0          43s
argocd-dex-server-66c78cf887-smwnl                  1/1     Running   0          43s
argocd-notifications-controller-7fb9868fd6-4sgpp    1/1     Running   0          43s
argocd-redis-bdbdffcb4-xc2xt                        1/1     Running   0          43s
argocd-repo-server-d89c7967d-7zpnx                  1/1     Running   0          43s
argocd-server-776b7cdd4d-bq2rq                      1/1     Running   0          43s
customresourcedefinition.apiextensions.k8s.io/applications.argoproj.io
customresourcedefinition.apiextensions.k8s.io/applicationsets.argoproj.io
customresourcedefinition.apiextensions.k8s.io/appprojects.argoproj.io
```

Sept composants. Le **repo-server** clone les dépôts et produit les manifestes (avec Kustomize ou Helm s'il le faut). L'**application-controller** compare ces manifestes à l'état réel du cluster et applique les différences. L'**argocd-server** sert l'interface web, l'API et reçoit les webhooks. Redis sert de cache. Les trois autres sont facultatifs ici : Dex fournit la connexion unique (SSO) avec un annuaire d'entreprise, le contrôleur de notifications envoie des messages, celui d'ApplicationSet fabrique des Applications en série. On arrête les deux premiers :

```bash
kubectl -n argocd scale deployment argocd-dex-server argocd-notifications-controller --replicas=0
kubectl -n argocd top pods
```

```sortie
deployment.apps/argocd-dex-server scaled
deployment.apps/argocd-notifications-controller scaled
NAME                                                CPU(cores)   MEMORY(bytes)   
argocd-application-controller-0                     12m          29Mi            
argocd-applicationset-controller-76fd8cdd4f-v4q8w   8m           29Mi            
argocd-redis-bdbdffcb4-xc2xt                        14m          10Mi            
argocd-repo-server-d89c7967d-7zpnx                  23m          22Mi            
argocd-server-776b7cdd4d-bq2rq                      25m          50Mi            
argocd: v3.5.4+d6d5b24
```

Le client `argocd` est un binaire à télécharger de la page des versions. On se connecte avec le mot de passe initial de l'administrateur, rangé dans un Secret, puis on déclare le dépôt, privé, avec ses identifiants :

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443 &
argocd login localhost:8080 --username admin --insecure \
  --password "$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
argocd repo add http://gitea.git.svc.cluster.local:3000/cours/colis-config.git --username cours --password depot-du-cours-57
```

```sortie
mot de passe initial : v8EL... (16 caractères)
'admin:login' logged in successfully
Context 'localhost:8080' updated
Repository 'http://gitea.git.svc.cluster.local:3000/cours/colis-config.git' added
TYPE  NAME  REPO                                                            INSECURE  OCI    LFS    CREDS  STATUS      MESSAGE  PROJECT
git         http://gitea.git.svc.cluster.local:3000/cours/colis-config.git  false     false  false  false  Successful           
SECRET            TYPE
repo-2539118816   repository
```

L'adresse du dépôt est celle que voit le repo-server, dans le cluster ; vous, vous passez par la redirection de port. Les identifiants sont rangés dans un Secret d'`argocd`, reconnu par son étiquette `argocd.argoproj.io/secret-type=repository` : on peut aussi le créer directement, sans le client.

<Figure svg={gitopsBoucle} num="57.1" alt="De gauche à droite : vous modifiez un fichier et faites git push (1) vers le dépôt Git, l'état voulu. Dans Argo CD, le repo-server sonde le dépôt toutes les deux à trois minutes (2) ou reçoit un webhook par l'argocd-server en quelques secondes (2'), clone le dépôt et rend overlays/staging avec Kustomize ; il passe le rendu (3) à l'application-controller, qui le compare à l'état réel et déclare l'application Synced ou OutOfSync ; il applique les différences au namespace colis-staging (4) ; un watch lui signale toute dérive, qu'il corrige si selfHeal est actif (5).">
La boucle d'Argo CD. Le dépôt dit ce qui doit être ; le contrôleur compare et applique ; un webhook remplace le sondage.
</Figure>

## Une première Application

Le type `Application` relie un chemin d'un dépôt à une destination :

```yaml title="application.yaml"
# L'application colis-staging : ce que dit le dépôt, à l'endroit où il doit être appliqué.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: colis-staging
  namespace: argocd
spec:
  project: default
  source:
    repoURL: http://gitea.git.svc.cluster.local:3000/cours/colis-config.git
    targetRevision: main
    path: overlays/staging
  destination:
    server: https://kubernetes.default.svc
    namespace: colis-staging
```

Sans `syncPolicy`, la synchronisation est manuelle : Argo CD compare, mais n'applique rien de lui-même.

```bash
kubectl create namespace colis-staging
kubectl -n colis-staging create secret generic colis-db --from-literal=POSTGRES_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')"
kubectl apply -f application.yaml
argocd app get colis-staging
argocd app diff colis-staging
```

```sortie
namespace/colis-staging created
secret/colis-db created
application.argoproj.io/colis-staging created
OutOfSync Healthy 3652350abe0a
GROUP                      KIND         NAMESPACE      NAME                     STATUS     HEALTH   HOOK  MESSAGE
                           ConfigMap    colis-staging  colis-config-9cmhtm488h  OutOfSync  Missing        
                           Namespace                   colis-staging            OutOfSync                 
                           Service      colis-staging  api                      OutOfSync  Missing        
                           Service      colis-staging  postgres                 OutOfSync  Missing        
                           Service      colis-staging  redis                    OutOfSync  Missing        
                           Service      colis-staging  web                      OutOfSync  Missing        
apps                       Deployment   colis-staging  api                      OutOfSync  Missing        
apps                       Deployment   colis-staging  redis                    OutOfSync  Missing        
apps                       Deployment   colis-staging  web                      OutOfSync  Missing        
apps                       Deployment   colis-staging  worker                   OutOfSync  Missing        
apps                       StatefulSet  colis-staging  postgres                 OutOfSync  Missing        
batch                      CronJob      colis-staging  purge                    OutOfSync  Missing        
gateway.networking.k8s.io  HTTPRoute    colis-staging  colis                    OutOfSync  Missing        
===== /ConfigMap colis-staging/colis-config-9cmhtm488h ======
===== /Namespace /colis-staging ======
===== /Service colis-staging/api ======
===== /Service colis-staging/postgres ======
===== /Service colis-staging/redis ======
===== /Service colis-staging/web ======
===== apps/Deployment colis-staging/api ======
===== apps/Deployment colis-staging/redis ======
===== apps/Deployment colis-staging/web ======
===== apps/Deployment colis-staging/worker ======
===== apps/StatefulSet colis-staging/postgres ======
===== batch/CronJob colis-staging/purge ======
===== gateway.networking.k8s.io/HTTPRoute colis-staging/colis ======
```

`OutOfSync` : le dépôt décrit treize objets, le cluster n'en a aucun (`Missing`), sauf le namespace, créé à la main pour y ranger le Secret. Le nom de la ConfigMap porte un suffixe, `colis-config-9cmhtm488h` : c'est le générateur de Kustomize qui l'ajoute, calculé à partir du contenu (chapitre 30). On synchronise :

```bash
argocd app sync colis-staging
argocd app wait colis-staging --health
```

```sortie
Operation:          Sync
Sync Revision:      3652350abe0ac49a73ee7d9a3efc9d77bf799cfc
Phase:              Succeeded
Start:              2026-10-09 08:55:36 +0100 WAT
Finished:           2026-10-09 08:55:38 +0100 WAT
Duration:           2s
en bonne santé après 19,45 s
Synced Healthy 3652350abe0ac49
GROUP                      KIND         NAMESPACE      NAME                     STATUS   HEALTH   HOOK  MESSAGE
                           Namespace    colis-staging  colis-staging            Running  Synced         namespace/colis-staging configured. Warning: resource namespaces/colis-staging is missing the kubectl.kubernetes.io/last-applied-configuration annotation which is required by  apply.  apply should only be used on resources created declaratively by either  create --save-config or  apply. The missing annotation will be patched automatically.
                           ConfigMap    colis-staging  colis-config-9cmhtm488h  Synced                  configmap/colis-config-9cmhtm488h created
                           Service      colis-staging  postgres                 Synced   Healthy        service/postgres created
                           Service      colis-staging  redis                    Synced   Healthy        service/redis created
                           Service      colis-staging  api                      Synced   Healthy        service/api created
                           Service      colis-staging  web                      Synced   Healthy        service/web created
apps                       Deployment   colis-staging  redis                    Synced   Healthy        deployment.apps/redis created
apps                       Deployment   colis-staging  web                      Synced   Healthy        deployment.apps/web created
apps                       Deployment   colis-staging  api                      Synced   Healthy        deployment.apps/api created
apps                       Deployment   colis-staging  worker                   Synced   Healthy        deployment.apps/worker created
apps                       StatefulSet  colis-staging  postgres                 Synced   Healthy        statefulset.apps/postgres created
batch                      CronJob      colis-staging  purge                    Synced   Healthy        cronjob.batch/purge created
gateway.networking.k8s.io  HTTPRoute    colis-staging  colis                    Synced   Healthy        httproute.gateway.networking.k8s.io/colis created
                           Namespace                   colis-staging            Synced                  
NAME                      READY   STATUS    RESTARTS     AGE
api-7986979c7b-9fhf2      1/1     Running   1 (8s ago)   17s
postgres-0                1/1     Running   0            17s
redis-578785659c-9wjc2    1/1     Running   0            17s
web-66df747b46-kblbs      1/1     Running   0            17s
worker-5fb78d845d-bgj8m   1/1     Running   1 (8s ago)   17s
{"statut":"ok","version":"2.2.0","hote":"api-7986979c7b-9fhf2"}
```

Deux secondes pour appliquer les objets, une vingtaine pour que tous soient en bonne santé. L'application répond, en version 2.2.0, sur `colis-staging.local`. L'état de santé (`Healthy`, `Progressing`, `Degraded`...) est calculé par Argo CD pour chaque type d'objet : un Deployment est en bonne santé quand ses répliques sont disponibles, un Service de type ClusterIP toujours, un PVC quand il est lié.

## Changer par Git

Passer en 2.2.1, c'est modifier deux lignes, et rien d'autre :

```bash
git commit -am "Colis 2.2.1" && git push origin main
# ... attendre qu'Argo CD voie la révision, puis :
kubectl -n argocd get configmap argocd-cm -o jsonpath='{.data.timeout\.reconciliation}'
argocd app sync colis-staging
curl -s --resolve colis-staging.local:80:192.168.49.102 http://colis-staging.local/api/sante
argocd app history colis-staging
```

```sortie
diff --git a/base/kustomization.yaml b/base/kustomization.yaml
index 45d3981..cd8ca12 100644
--- a/base/kustomization.yaml
+++ b/base/kustomization.yaml
@@ -19,13 +19,13 @@ configMapGenerator:
 - name: colis-config
   literals:
   - COLIS_REDIS=redis://redis:6379/0
-  - COLIS_VERSION=2.2.0
+  - COLIS_VERSION=2.2.1
   - COLIS_PURGE_JOURS=30
 
 images:
 - name: colis-api
   newName: host.minikube.internal:5001/colis/api
-  newTag: "2.2.0"
+  newTag: "2.2.1"
 - name: colis-web
   newName: host.minikube.internal:5001/colis/web
   newTag: "1.1"
révision poussée : d7e3196
révision d7e3196 vue par Argo CD après 194,3 s
OutOfSync Healthy d7e319674fd7
timeout.reconciliation : 
1 resources require pruning
{"statut":"ok","version":"2.2.1","hote":"api-7979fb6dc9-87kbt"}
SOURCE  http://gitea.git.svc.cluster.local:3000/cours/colis-config.git
ID      DATE                           REVISION
0       2026-10-09 08:55:38 +0100 WAT  main (3652350)
1       2026-10-09 08:59:15 +0100 WAT  main (d7e3196)
```

Trois minutes et quatorze secondes avant qu'Argo CD voie la révision. Il sonde chaque dépôt toutes les 120 secondes, plus un délai aléatoire de 60 secondes au plus pour étaler les requêtes : trois minutes dans le pire cas[^faq]. La ConfigMap `argocd-cm` permet de changer ces valeurs (`timeout.reconciliation`), elle est vide ici, donc aux valeurs par défaut.

La synchronisation manuelle s'est terminée sur une erreur : `1 resources require pruning`. Le contenu de la ConfigMap a changé, Kustomize lui a donné un nouveau suffixe, et l'ancienne, `colis-config-9cmhtm488h`, n'est plus dans le dépôt. Argo CD ne supprime pas un objet du cluster sans qu'on le lui demande : il signale qu'il faudrait l'**élaguer** (*prune*). Le reste a été appliqué, et l'API sert bien 2.2.1. `argocd app history` garde une ligne par synchronisation, avec la révision déployée.

## Synchronisation automatique, et le webhook

```bash
kubectl -n argocd patch application colis-staging --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

`automated` applique toute nouvelle révision ; `prune` supprime ce qui n'est plus dans le dépôt ; `selfHeal` ramène vers le dépôt tout ce qui a été modifié dans le cluster[^autosync]. Pour ne plus attendre le sondage, on demande à Gitea de prévenir Argo CD à chaque `push` (un webhook, chapitre 45) :

```bash
curl -s -u cours:depot-du-cours-57 -X POST -H 'Content-Type: application/json' \
  http://localhost:3030/api/v1/repos/cours/colis-config/hooks \
  -d '{"type":"gitea","active":true,"events":["push"],"config":{"url":"https://argocd-server.argocd.svc.cluster.local/api/webhook","content_type":"json"}}'
```

```sortie
application.argoproj.io/colis-staging patched
{"id":1,"type":"gitea","events":["push"],"url":"https://argocd-server.argocd.svc.cluster.local/api/webhook"}
-  count: 1
+  count: 2
révision d8e2278 vue par Argo CD après 207,8 s
deux Pods web prêts 216,1 s après le push
```

Le webhook n'a servi à rien : 208 secondes, le sondage encore. Le journal de Gitea dit pourquoi :

```sortie
GITEA__security__ALLOWED_HOST_LIST=10.96.0.0/12
```

Gitea protège son réseau interne : un webhook est une requête que n'importe quel utilisateur peut faire partir du serveur, et donc un moyen d'atteindre des machines privées (une attaque dite SSRF, *server-side request forgery*). La première version du kit autorisait le nom `*.svc.cluster.local`, et ce n'est pas suffisant : le nom se résout en adresse privée, et Gitea exige que l'adresse elle-même soit autorisée. On autorise donc la plage d'adresses des Services du cluster, `10.96.0.0/12` sur minikube, par la variable `GITEA__security__ALLOWED_HOST_LIST`. La même mesure, sur l'application légère des exercices :

```sortie
application.argoproj.io/vitrine created
vitrine : Synced Healthy, version 6.14.1
révision 1ad55e5 vue par Argo CD après 1,314 s
version 6.15.0 servie 5,853 s après le push
```

Une seconde et demie entre le `push` et la révision vue par Argo CD, six secondes jusqu'à la nouvelle version servie. Le sondage reste actif : si un webhook se perd, la révision sera vue au plus trois minutes plus tard.

## La dérive

`selfHeal` corrige ce qui a été modifié à la main :

```bash
kubectl -n colis-staging scale deployment api --replicas=3
kubectl -n colis-staging delete service web
```

```sortie
deployment.apps/api scaled
replicas ramené à 1 après 93,90 s
service "web" deleted from colis-staging namespace
Service web recréé après 5,781 s
ID      DATE                           REVISION
0       2026-10-09 08:55:38 +0100 WAT  main (3652350)
1       2026-10-09 08:59:15 +0100 WAT  main (d7e3196)
2       2026-10-09 09:02:57 +0100 WAT  main (d8e2278)
```

Le Service supprimé revient en six secondes. Le nombre de répliques, lui, a mis une minute et demie. Argo CD n'a rien perdu : il espace ses corrections, et l'application en avait déjà subi plusieurs. Depuis la version 3, chaque nouvelle correction automatique attend plus longtemps que la précédente : 2 secondes la première fois, puis trois fois plus à chaque fois, jusqu'à 300 secondes au plus[^commande]. Le but est de ne pas se battre indéfiniment contre un autre programme qui réécrit le même champ. La mesure, écart après écart, sur l'application légère :

```sortie
écart n° 1 corrigé après 0,9210 s
écart n° 2 corrigé après 3,390 s
écart n° 3 corrigé après 15,93 s
écart n° 4 corrigé après 52,15 s
écart n° 5 corrigé après 160,9 s
```

0,9 seconde, 3,4, 15,9, 52,2, puis 160,9 : la suite 2, 6, 18, 54, 162, à la durée de la boucle de mesure près. La conséquence est pratique : une modification faite à la main peut rester en place plusieurs minutes, et elle finira quand même par disparaître. Pour un changement qui doit durer, il n'y a qu'un chemin, le dépôt.

## L'élagage

Retirer un fichier du dépôt retire l'objet du cluster, avec `prune: true`. La préproduction n'a pas besoin de la purge :

```bash
git rm base/purge.yaml        # et la ligne correspondante de base/kustomization.yaml
git commit -m "Préproduction : pas de purge" && git push origin main
```

```sortie
 M base/kustomization.yaml
D  base/purge.yaml
révision a8acd29 vue par Argo CD après 144,9 s
No resources found in colis-staging namespace.
```

Le CronJob a disparu. Argo CD ne supprime que les objets qu'il suit pour cette application, ceux qui viennent du dépôt : le Secret créé à la main, lui, n'est pas concerné.

## Quand un autre contrôleur écrit le même champ

Un HorizontalPodAutoscaler (chapitre 31) décide du nombre de répliques de l'API, entre 2 et 3. Le dépôt, lui, en déclare une (`replicas: api, count: 1` dans l'overlay). On ajoute le HPA au dépôt :

```yaml title="hpa.yaml"
# Un autoscaler pour l'API de préproduction : il décide du nombre de répliques, entre 2 et 3.
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: api}
  minReplicas: 2
  maxReplicas: 3
  metrics:
  - type: Resource
    resource:
      name: cpu
      target: {type: Utilization, averageUtilization: 70}
```

```sortie
révision 1d12e64 vue par Argo CD après 213,4 s
0 s  replicas=1  OutOfSync
5 s  replicas=1  Synced
21 s  replicas=2  Synced
38 s  replicas=2  OutOfSync
43 s  replicas=1  Synced
48 s  replicas=2  Synced
54 s  replicas=1  Synced
64 s  replicas=2  Synced
69 s  replicas=2  OutOfSync
75 s  replicas=1  Synced
80 s  replicas=2  OutOfSync
Scaled up replica set api-7979fb6dc9 from 1 to 3     1
Scaled down replica set api-7979fb6dc9 from 3 to 1   1
Scaled up replica set api-7979fb6dc9 from 1 to 2     5
Scaled down replica set api-7979fb6dc9 from 2 to 1   4
NAME   REFERENCE        TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
api    Deployment/api   cpu: 5%/70%   2         3         2          95s
```

Les deux contrôleurs se renvoient la valeur : le HPA monte à 2, Argo CD redescend à 1, le HPA remonte. Cinq montées et quatre descentes en une minute et demie, et chacune fait naître ou disparaître un Pod. C'est le cas que l'attente exponentielle de `selfHeal` atténue, sans le résoudre. La solution est de dire à Argo CD que ce champ ne lui appartient pas :

```yaml
  ignoreDifferences:
  - group: apps
    kind: Deployment
    name: api
    jsonPointers: [/spec/replicas]
  syncPolicy:
    syncOptions:
    - RespectIgnoreDifferences=true
```

`ignoreDifferences` fait ignorer le champ dans la comparaison ; `RespectIgnoreDifferences` le fait ignorer aussi pendant la synchronisation, sans quoi la prochaine synchronisation réécrirait la valeur du dépôt[^diffing]. L'autre solution, plus propre, est de retirer `replicas` du dépôt pour ce Deployment : le champ n'a alors qu'un seul propriétaire. On l'a vu au chapitre 55 avec KEDA, du côté d'un opérateur ; Argo CD rencontre le même problème.

## Des applications déclarées dans Git

L'Application `colis-staging` a été créée par `kubectl apply`, et modifiée par `kubectl patch` : précisément ce que le GitOps voulait éviter. La réponse est récursive. Une Application est un objet Kubernetes comme un autre, elle peut donc être décrite dans le dépôt et déployée par une autre Application. Une **application racine** déploie le dossier `apps/` du dépôt, qui contient les définitions des autres ; c'est le motif *App of Apps*[^bootstrap].

```yaml title="racine.yaml"
# L'application racine : elle ne déploie que des Applications, rangées dans le dossier apps/ du dépôt.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: racine
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io    # supprimer la racine supprime ses enfants et leurs objets
spec:
  project: default
  source:
    repoURL: http://gitea.git.svc.cluster.local:3000/cours/colis-config.git
    targetRevision: main
    path: apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: {prune: true, selfHeal: true}
```

Le dossier `apps/` contient deux applications : `colis-staging`, avec la correction pour le HPA, et une petite application `quotas-staging`, qui pose un ResourceQuota (chapitre 23) sur le namespace.

```sortie
application.argoproj.io/racine created
NAME                   CLUSTER                         NAMESPACE      PROJECT  STATUS  HEALTH    SYNCPOLICY  CONDITIONS  REPO                                                            PATH              TARGET
argocd/colis-staging   https://kubernetes.default.svc  colis-staging  default  Synced  Degraded  Auto-Prune  <none>      http://gitea.git.svc.cluster.local:3000/cours/colis-config.git  overlays/staging  main
argocd/quotas-staging  https://kubernetes.default.svc  colis-staging  default  Synced  Healthy   Auto-Prune  <none>      http://gitea.git.svc.cluster.local:3000/cours/colis-config.git  quotas/staging    main
argocd/racine          https://kubernetes.default.svc  argocd         default  Synced  Healthy   Auto-Prune  <none>      http://gitea.git.svc.cluster.local:3000/cours/colis-config.git  apps              main
GROUP        KIND         NAMESPACE  NAME            STATUS  HEALTH  HOOK  MESSAGE
argoproj.io  Application  argocd     quotas-staging  Synced                application.argoproj.io/quotas-staging created
argoproj.io  Application  argocd     colis-staging   Synced                application.argoproj.io/colis-staging configured
E1009 09:14:57.677260 2024897 memcache.go:381] "Couldn't get current server API group list" err="Get \"https://192.168.49.2:8443/api?timeout=32s\": net/http: TLS handshake timeout"
0 s  replicas=2  Synced
NAME      REQUEST                                  LIMIT                       AGE
limites   pods: 7/15, requests.memory: 704Mi/2Gi   limits.memory: 1216Mi/4Gi   98s
{"ignoreDifferences":[{"group":"apps","jsonPointers":["/spec/replicas"],"kind":"Deployment","name":"api"}],"syncOptions":["RespectIgnoreDifferences=true"]}
mémoire du nœud : 4.95GiB / 5GiB
```

L'application racine a repris `colis-staging`, qui existait déjà sous ce nom, et créé `quotas-staging`. Le nombre de répliques reste à 2, celui du HPA. `colis-staging` apparaît `Degraded` dans ce relevé, pris alors que le nœud arrivait au bout de sa mémoire (voir la section suivante).

<Figure svg={gitopsRacine} num="57.2" alt="Le dépôt colis-config contient le dossier apps avec colis-staging.yaml et quotas-staging.yaml, et les dossiers base, overlays/staging et quotas/staging. L'Application racine lit apps et crée deux Applications : colis-staging, de source overlays/staging, qui déploie Deployments, Services, StatefulSet, HPA et HTTPRoute, et quotas-staging, de source quotas/staging, qui déploie le ResourceQuota limites, tous dans le namespace colis-staging. Ajouter une application revient à ajouter un fichier dans apps ; supprimer la racine avec son finaliseur supprime les enfants et leurs objets.">
Une application racine déclare les autres. Le dépôt décrit alors tout, y compris la liste de ce qu'Argo CD doit déployer.
</Figure>

### Supprimer en cascade

À la fin du rejeu, le nœud était à 4,95 Gio sur 5 : la préproduction devait partir. La racine porte le finaliseur `resources-finalizer.argocd.argoproj.io`, qui demande à Argo CD de supprimer ce qu'elle a créé avant de disparaître. Ce qui s'est passé :

```sortie
# kubectl -n argocd delete application racine
application.argoproj.io "racine" deleted from argocd namespace
# kubectl -n argocd get applications
No resources found in argocd namespace.
# kubectl -n colis-staging get all
NAME                          READY   STATUS    RESTARTS        AGE
pod/api-7979fb6dc9-87kbt      1/1     Running   2 (3m28s ago)   22m
pod/api-7979fb6dc9-hbjqc      1/1     Running   0               9m44s
pod/postgres-0                1/1     Running   0               26m
pod/redis-578785659c-9wjc2    1/1     Running   0               26m
...
```

Les deux Applications enfants ont disparu, mais leurs objets sont restés : les enfants, eux, n'avaient pas le finaliseur, et une Application supprimée sans finaliseur laisse ses objets en place. La documentation d'Argo CD le dit : pour que la suppression de la racine emporte les objets des enfants, chaque enfant doit porter le finaliseur[^bootstrap]. Les fichiers `apps/` du kit l'ont maintenant. Sans finaliseur, la suppression d'une Application est l'opération la plus sûre (rien ne part du cluster) ; avec, c'est la plus complète. Le choix se fait application par application.

## Exercices

:::exercice[Exercice 1 : revenir en arrière]

L'application `vitrine` (dans l'archive, dossier `vitrine`) est en synchronisation automatique et vient de passer de podinfo 6.14.1 à 6.15.0. Revenez à 6.14.1 de deux façons : avec `argocd app rollback`, puis par Git. Laquelle marche, et pourquoi l'autre est-elle refusée ?

:::

<details>
<summary>Corrigé</summary>

```sortie
# argocd app rollback vitrine 1
rpc error: code = FailedPrecondition desc = rollback cannot be initiated when auto-sync is enabled
SOURCE  http://gitea.git.svc.cluster.local:3000/cours/colis-config.git
ID      DATE                           REVISION
0       2026-10-09 09:32:34 +0100 WAT  main (ef7f0c3)
1       2026-10-09 09:32:38 +0100 WAT  main (1ad55e5)
1ad55e5 Vitrine : podinfo 6.15.0
ef7f0c3 Vitrine : podinfo 6.14.1
cfc5fcf Revert "Vitrine : podinfo 6.15.0"
1ad55e5 Vitrine : podinfo 6.15.0
révision cfc5fcf vue par Argo CD après 1,906 s
version 6.14.1 servie 7,703 s après le push du revert
1       2026-10-09 09:32:38 +0100 WAT  main (1ad55e5)
2       2026-10-09 09:36:54 +0100 WAT  main (cfc5fcf)
```

`argocd app rollback` redéploie une révision de l'historique sans toucher au dépôt : le cluster et le dépôt divergeraient, et la synchronisation automatique ramènerait aussitôt la révision du dépôt. Argo CD refuse donc le retour arrière quand elle est active[^autosync]. Le chemin GitOps est un `git revert`, qui crée un nouveau commit annulant le précédent : l'historique garde la trace de l'aller et du retour, et la version 6.14.1 est servie huit secondes après le `push`.

</details>

:::exercice[Exercice 2 : protéger un objet de l'élagage]

Ajoutez deux ConfigMaps à la vitrine, `garder` et `jetable`, la première avec l'annotation `argocd.argoproj.io/sync-options: Prune=false`. Retirez-les toutes deux du dépôt. Que devient chacune, et dans quel état est l'application ? Que se passe-t-il ensuite si l'on supprime l'Application, qui porte le finaliseur ?

:::

<details>
<summary>Corrigé</summary>

```sortie
révision 2cc9bca vue par Argo CD après 1,328 s
NAME      DATA   AGE
garder    1      1s
jetable   1      1s
révision 3a0e2b4 vue par Argo CD après 1,315 s
NAME     DATA   AGE
garder   1      13s
Error from server (NotFound): configmaps "jetable" not found
vitrine : OutOfSync
       ConfigMap   vitrine    garder   OutOfSync                 ignored (no prune)
# après la suppression de l'Application
["resources-finalizer.argocd.argoproj.io"]
application.argoproj.io "vitrine" deleted from argocd namespace
NAME                         DATA   AGE
```

`jetable` est élaguée, `garder` reste, et l'application reste `OutOfSync` : Argo CD signale l'écart (`ignored (no prune)`) sans le corriger. C'est la protection qu'on met sur un objet coûteux à recréer, un PVC par exemple. Elle ne protège que de l'élagage : la suppression de l'Application, avec son finaliseur, a emporté `garder` comme le reste (section « cascade » du troisième corrigé).

</details>

:::exercice[Exercice 3 : l'état des applications face au dépôt (programmation)]

Écrivez un script Python qui affiche, pour chaque Application, son mode (automatique ou manuel), son état de synchronisation et de santé, la révision réellement déployée et la dernière révision de la branche suivie, lue dans le dépôt par `git ls-remote`. Il signale les applications en retard sur leur dépôt, désynchronisées ou en mauvaise santé, et sort avec le code 1 s'il en trouve. Attention au piège : `status.sync.revision` n'est pas la révision déployée.

:::

<details>
<summary>Corrigé</summary>

Le corrigé, `corrige/etat-gitops.py`, n'est pas dans l'archive. `status.sync.revision` est la dernière révision **comparée** : Argo CD l'avance dès qu'il voit un nouveau commit, même sans rien appliquer. La révision **déployée** est celle de la dernière synchronisation, en tête de `status.history`. Le dépôt n'étant joignable depuis le poste que par la redirection de port, le script accepte une traduction d'adresse.

```sortie
# python3 etat-gitops.py --depot-local ...
APPLICATION  MODE  SYNC       SANTÉ    DÉPLOYÉE  DÉPÔT    ÉTAT
vitrine      auto  OutOfSync  Healthy  3a0e2b4   3a0e2b4  désynchronisée

1 applications, 1 à regarder
code de sortie : 1
révision 63cff9b vue par Argo CD après 2,516 s
# python3 etat-gitops.py --depot-local ...
APPLICATION  MODE    SYNC       SANTÉ    DÉPLOYÉE  DÉPÔT    ÉTAT
vitrine      manuel  OutOfSync  Healthy  3a0e2b4   63cff9b  en retard sur le dépôt, désynchronisée

1 applications, 1 à regarder
code de sortie : 1
```

Premier passage : la vitrine est désynchronisée à cause de la ConfigMap `garder` de l'exercice 2. Second passage, synchronisation automatique coupée et un commit poussé : la révision comparée a avancé, la révision déployée non, et le script le voit.

</details>

:::exercice[Exercice 4 : le Secret hors du dépôt]

Le Secret `colis-db` a été créé à la main, hors du dépôt. Quelles sont les conséquences pour la reconstruction d'un environnement à partir de Git seul ? Proposez deux façons de le décrire dans le dépôt sans y écrire le mot de passe en clair.

:::

<details>
<summary>Corrigé</summary>

Un cluster reconstruit depuis le dépôt n'aurait pas ce Secret : PostgreSQL ne démarrerait pas (`CreateContainerConfigError`, chapitre 49), et quelqu'un devrait savoir qu'il faut le recréer, avec quel nom et quelle clé. Le dépôt n'est plus la description complète de l'environnement. Le chapitre 46 a présenté deux solutions. Sealed Secrets chiffre le Secret avec la clé publique d'un contrôleur du cluster : l'objet `SealedSecret` peut être versionné, et seul ce contrôleur peut le déchiffrer. External Secrets Operator décrit dans le dépôt une référence vers un coffre (Vault, un gestionnaire de secrets d'un fournisseur de cloud) : le dépôt dit où est le secret, jamais ce qu'il contient. Dans les deux cas, Argo CD synchronise un objet qui n'est pas un secret en clair, et un contrôleur fabrique le vrai Secret dans le cluster.

</details>

## Interfaces et nettoyage

L'interface web d'Argo CD est à `https://localhost:8080` derrière la redirection de port (compte `admin`, mot de passe du Secret `argocd-initial-admin-secret`), celle de Gitea à `http://localhost:3030` (compte `cours`). Argo CD et Gitea servent encore au chapitre 58 et au défi VIII. La préproduction et la vitrine ont été supprimées en fin de chapitre ; si vous les avez gardées :

```bash
kubectl -n argocd delete application racine vitrine --ignore-not-found
kubectl delete namespace colis-staging vitrine --ignore-not-found
```

Pour tout retirer plus tard : `kubectl delete namespace argocd git`, puis les trois CRD `*.argoproj.io`, qu'Argo CD laisse derrière lui.

[^opengitops]: OpenGitOps, « GitOps Principles v1.0.0 » : déclaratif, versionné et immuable, tiré automatiquement, réconcilié en continu. [opengitops.dev](https://opengitops.dev/) ; texte source : [github.com/open-gitops/documents/blob/main/PRINCIPLES.md](https://github.com/open-gitops/documents/blob/main/PRINCIPLES.md)
[^argocd]: Argo CD, documentation de la version 3.5. [argo-cd.readthedocs.io](https://argo-cd.readthedocs.io/en/stable/)
[^faq]: Argo CD, FAQ, « How often does Argo CD check for changes to my Git or Helm repository? » : sondage toutes les 120 s plus jusqu'à 60 s d'aléa, clés `timeout.reconciliation` et `timeout.reconciliation.jitter` de `argocd-cm`. [github.com/argoproj/argo-cd/blob/v3.5.4/docs/faq.md](https://github.com/argoproj/argo-cd/blob/v3.5.4/docs/faq.md)
[^autosync]: Argo CD, « Automated Sync Policy » : `prune`, `selfHeal`, nouvel essai de correction après le délai de self-heal, retour arrière impossible quand la synchronisation automatique est active. [github.com/argoproj/argo-cd/blob/v3.5.4/docs/user-guide/auto_sync.md](https://github.com/argoproj/argo-cd/blob/v3.5.4/docs/user-guide/auto_sync.md)
[^commande]: Argo CD, référence de `argocd-application-controller` : `--self-heal-backoff-timeout-seconds` (2), `--self-heal-backoff-factor` (3), `--self-heal-backoff-cap-seconds` (300). [github.com/argoproj/argo-cd/blob/v3.5.4/docs/operator-manual/server-commands/argocd-application-controller.md](https://github.com/argoproj/argo-cd/blob/v3.5.4/docs/operator-manual/server-commands/argocd-application-controller.md)
[^diffing]: Argo CD, « Diffing Customization » et « Sync Options » (`RespectIgnoreDifferences`, `Prune=false`). [github.com/argoproj/argo-cd/blob/v3.5.4/docs/user-guide/sync-options.md](https://github.com/argoproj/argo-cd/blob/v3.5.4/docs/user-guide/sync-options.md)
[^bootstrap]: Argo CD, « Cluster Bootstrapping » : motif App of Apps, et finaliseur à mettre sur les applications enfants pour que la suppression du parent emporte leurs objets. [github.com/argoproj/argo-cd/blob/v3.5.4/docs/operator-manual/cluster-bootstrapping.md](https://github.com/argoproj/argo-cd/blob/v3.5.4/docs/operator-manual/cluster-bootstrapping.md)
