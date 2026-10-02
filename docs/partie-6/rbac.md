---
title: RBAC
sidebar_label: 43. RBAC
description: "Donner à chacun les droits dont il a besoin, et pas plus : Role, ClusterRole et leurs liaisons, un rôle d'astreinte et un compte de déploiement pour Colis, les rôles fournis et l'agrégation, les garde-fous de l'API server, l'autorisation Node, et les outils pour relire les droits d'un cluster."
partie: 6
chapitre: '43'
---

import rbacObjets from '@site/src/figures/rbac-objets.svg';
import autorisationChaine from '@site/src/figures/autorisation-chaine.svg';
import EvaluateurRBAC from '@site/src/components/EvaluateurRBAC';

Combien d'identités ont tous les droits sur votre cluster minikube ? Faites une estimation avant de lancer la commande. Elle cherche les liaisons qui donnent le rôle `cluster-admin`, celui qui autorise tout :

```bash
kubectl get clusterrolebindings -o json \
  | jq -r '.items[] | select(.roleRef.name == "cluster-admin") | .metadata.name as $b | .subjects[]? | "\($b)\t\(.kind)\t\(.namespace // "-")\t\(.name)"' \
  | column -t
```

```sortie
cluster-admin           Group           -            system:masters
kubeadm:cluster-admins  Group           -            kubeadm:cluster-admins
minikube-rbac           ServiceAccount  kube-system  default
```

Les deux premières lignes sont attendues. `system:masters` est le groupe de votre certificat (chapitre 42) ; `kubeadm:cluster-admins` est celui que kubeadm donne au certificat du fichier `admin.conf` des clusters qu'il installe, fichier qui ne doit pas quitter les nœuds du plan de contrôle[^kubeadm]. La troisième l'est beaucoup moins : minikube donne `cluster-admin` au ServiceAccount `default` du namespace `kube-system`. Tout Pod lancé dans ce namespace sans préciser de compte reçoit donc un jeton qui ouvre tout le cluster. C'est un raccourci commode pour les addons de minikube ; sur un cluster partagé, ce serait le premier constat d'un audit.

Ce chapitre traite de l'**autorisation**, la deuxième question que pose l'API server à chaque requête, après « qui êtes-vous ? » : « avez-vous le droit ? ». On y écrit des droits pour Colis, on apprend à les vérifier, et surtout à relire ceux qu'un cluster accorde déjà, comme on vient de le faire. Les fichiers sont dans [l'archive rbac](pathname:///kits/rbac.tar.gz) ; on travaille dans `colis` et dans un namespace d'essai, `ch43`.

## Comment l'API server décide

L'authentification a produit une identité : un nom et des groupes. L'API server y ajoute ce que la requête demande, et obtient une liste d'**attributs** : le verbe (`get`, `list`, `watch`, `create`, `update`, `patch`, `delete`…, chapitre 34), le groupe d'API et la ressource, éventuellement une sous-ressource comme `pods/log`, le namespace et le nom de l'objet. Il soumet ces attributs aux **autorisateurs** configurés par l'option `--authorization-mode`, qui vaut `Node,RBAC` sur minikube (chapitre 42). Chacun répond « oui », « non » ou « pas d'avis » ; le premier « oui » autorise la requête, et si personne ne dit oui, c'est `403 Forbidden`.

<Figure svg={autorisationChaine} num="43.1" alt="Les attributs de la requête (utilisateur, groupes, verbe, groupe d'API, ressource, namespace, nom) passent par trois étapes. 1, groupes privilégiés : membre de system:masters ? Si oui, autorisé sans regarder RBAC. 2, Node : une identité system:node ? seulement ce qu'utilisent ses Pods ; si oui, autorisé, sinon pas d'avis. 3, RBAC : une liaison réunit portée, sujet et règle qui couvre la requête ? Si oui, autorisé, et la raison nomme la liaison ; sinon 403 Forbidden.">
La chaîne d'autorisation de l'API server de minikube. Une requête autorisée passe ensuite à l'admission (chapitres 44 et 45).
</Figure>

Le groupe `system:masters` a un traitement à part : ses membres sont autorisés avant même que RBAC soit consulté. La documentation est explicite : ils échappent à toutes les vérifications, et retirer des liaisons n'y change rien[^bonnes]. C'est pourquoi on ne met personne dans ce groupe, sauf un accès de secours rangé dans un coffre. L'autorisateur **Node** ne s'occupe que des kubelets, et on le regardera plus loin. Tout le reste passe par **RBAC** (*Role-Based Access Control*), dont les permissions sont purement additives : il n'existe pas de règle « interdit », seulement des autorisations qui s'ajoutent[^rbac]. Ce qui n'est pas permis est refusé.

## Rôles et liaisons

RBAC repose sur quatre types d'objets. Un **Role** est une liste de règles, valable dans son namespace ; une **ClusterRole** est la même chose sans namespace. Chaque règle dit quels verbes sont permis sur quelles ressources de quels groupes d'API, éventuellement limités à certains noms (`resourceNames`). Un rôle ne donne rien à personne : il faut une **liaison**. Une **RoleBinding** donne un rôle à des sujets (utilisateurs, groupes, ServiceAccounts) dans un namespace ; une **ClusterRoleBinding** le donne dans tout le cluster.

<Figure svg={rbacObjets} num="43.2" alt="Trois lignes, chacune avec des sujets, une liaison et un rôle. Le groupe equipe-colis est lié par la RoleBinding astreinte du namespace colis au Role astreinte défini dans colis : valable dans colis. L'utilisatrice carla est liée par la RoleBinding cours-view-carla du namespace colis à la ClusterRole view, définie pour tout le cluster : valable dans colis seulement. Le ServiceAccount kube-system/default est lié par la ClusterRoleBinding minikube-rbac à la ClusterRole cluster-admin : valable partout.">
Une liaison relie des sujets (<code>subjects</code>) à un rôle (<code>roleRef</code>). La portée est celle de la liaison : une ClusterRole donnée par une RoleBinding ne vaut que dans le namespace de la liaison.
</Figure>

La figure montre les trois combinaisons utiles, avec des objets de ce chapitre. La deuxième est la plus pratique : on écrit une fois une ClusterRole, comme `view`, et on la donne namespace par namespace avec des RoleBindings. Une seule combinaison n'existe pas : une ClusterRoleBinding ne peut pas désigner un Role, puisqu'un Role n'a pas de sens hors de son namespace.

## Un rôle d'astreinte pour Colis

La personne d'astreinte sur Colis doit pouvoir regarder ce qui tourne, lire les journaux, et redémarrer un composant sans état qui se comporte mal. Elle n'a besoin ni des Secrets, ni de toucher à PostgreSQL. Le rôle s'écrit tel quel :

```yaml title="astreinte.yaml"
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: astreinte
  namespace: colis
rules:
- apiGroups: [""]
  resources: [pods, pods/log, services, endpoints, events, configmaps]
  verbs: [get, list, watch]
- apiGroups: [apps]
  resources: [deployments, statefulsets, replicasets]
  verbs: [get, list, watch]
- apiGroups: [apps]
  resources: [deployments]
  resourceNames: [api, web, worker]
  verbs: [patch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: astreinte
  namespace: colis
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: equipe-colis
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: astreinte
```

Quelques détails de syntaxe. Le groupe d'API vide `""` est celui du noyau (Pods, Services, Secrets…). `pods/log` est une sous-ressource : lire les journaux d'un Pod est un droit distinct de lire sa description. La troisième règle est limitée à trois Deployments par `resourceNames` ; `kubectl rollout restart` envoie un `patch`, et c'est tout ce qu'il faut pour redémarrer. Le droit est donné au **groupe** `equipe-colis`, pas à des personnes : l'arrivée d'une collègue ne demandera qu'un certificat ou une entrée dans l'annuaire, aucune modification du cluster.

Essayons-le avec le vrai certificat d'Alice, fabriqué par `nouvel-utilisateur.sh` du chapitre 42 :

```bash
kubectl apply -f astreinte.yaml
NS=colis bash nouvel-utilisateur.sh alice equipe-colis
export KUBECONFIG=$PWD/alice.kubeconfig
kubectl get pods
kubectl logs deployment/api --tail=2
kubectl rollout restart deployment/api
kubectl rollout restart statefulset/postgres
kubectl get secret colis-db
kubectl delete pod postgres-0
```

```sortie
role.rbac.authorization.k8s.io/astreinte created
rolebinding.rbac.authorization.k8s.io/astreinte created
NAME                          READY   STATUS      RESTARTS       AGE
api-9d8d47b55-66qww           1/1     Running     0              55s
api-9d8d47b55-wxrpj           1/1     Running     0              51s
api-canari-799c55878f-zsjwx   1/1     Running     10 (92m ago)   6d6h
postgres-0                    1/1     Running     6 (92m ago)    6d7h
purge-essai-k8fcd             0/1     Completed   0              5d15h
purge-manuelle-47vhh          0/1     Completed   0              6d7h
redis-578785659c-48lq8        1/1     Running     6 (92m ago)    6d13h
web-599d986bdf-md86x          1/1     Running     15 (92m ago)   6d13h
web-599d986bdf-vx59k          1/1     Running     15 (92m ago)   6d13h
Found 2 pods, using pod/api-9d8d47b55-66qww
INFO:     10.244.0.1:48910 - "GET /sante HTTP/1.1" 200 OK
INFO:     10.244.0.1:48922 - "GET /pret HTTP/1.1" 200 OK
deployment.apps/api restarted
error: failed to patch: statefulsets.apps "postgres" is forbidden: User "alice" cannot patch resource "statefulsets" in API group "apps" in the namespace "colis"
Error from server (Forbidden): secrets "colis-db" is forbidden: User "alice" cannot get resource "secrets" in API group "" in the namespace "colis"
Error from server (Forbidden): pods "postgres-0" is forbidden: User "alice" cannot delete resource "pods" in API group "" in the namespace "colis"
```

Exactement ce qu'on voulait : Alice voit, lit les journaux, redémarre l'API, et rien d'autre. Chaque refus nomme le verbe, la ressource, le groupe et le namespace qui ont manqué : c'est le premier outil de diagnostic quand quelqu'un vous dit « je n'ai pas le droit ». Alice peut aussi demander elle-même la liste de ce qu'elle peut faire dans le namespace :

```bash
kubectl auth can-i --list
```

```sortie
Resources                                       Non-Resource URLs   Resource Names   Verbs
selfsubjectreviews.authentication.k8s.io        []                  []               [create]
selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
selfsubjectrulesreviews.authorization.k8s.io    []                  []               [create]
configmaps                                      []                  []               [get list watch]
endpoints                                       []                  []               [get list watch]
events                                          []                  []               [get list watch]
pods/log                                        []                  []               [get list watch]
pods                                            []                  []               [get list watch]
services                                        []                  []               [get list watch]
deployments.apps                                []                  []               [get list watch]
replicasets.apps                                []                  []               [get list watch]
statefulsets.apps                               []                  []               [get list watch]
                                                [/api/*]            []               [get]
                                                [/api]              []               [get]
                                                [/apis/*]           []               [get]
                                                [/apis]             []               [get]
                                                [/healthz]          []               [get]
                                                [/healthz]          []               [get]
                                                [/livez]            []               [get]
                                                [/livez]            []               [get]
                                                [/openapi/*]        []               [get]
                                                [/openapi]          []               [get]
                                                [/readyz]           []               [get]
                                                [/readyz]           []               [get]
                                                [/version/]         []               [get]
                                                [/version/]         []               [get]
                                                [/version]          []               [get]
                                                [/version]          []               [get]
deployments.apps                                []                  [api]            [patch]
deployments.apps                                []                  [web]            [patch]
deployments.apps                                []                  [worker]         [patch]
```

On retrouve les règles du rôle astreinte, et en tête des droits que tout utilisateur authentifié possède : poser ces questions à l'API server, et lire les chemins de découverte et de santé. Ils viennent de ClusterRoles par défaut (`system:basic-user`, `system:discovery`, `system:public-info-viewer`) données au groupe `system:authenticated`[^rbac].

En tant qu'administrateur, vous pouvez poser la même question à la place de quelqu'un, avec `--as` et `--as-group` ; c'est la façon la plus rapide de tester un rôle avant de prévenir l'intéressé :

```bash
kubectl auth can-i list pods -n colis --as=alice --as-group=equipe-colis
kubectl auth can-i get secrets -n colis --as=alice --as-group=equipe-colis
kubectl auth can-i patch deployments/api -n colis --as=alice --as-group=equipe-colis
kubectl auth can-i patch deployments/redis -n colis --as=alice --as-group=equipe-colis
kubectl auth can-i delete pods -n colis --as=alice --as-group=equipe-colis
kubectl auth can-i patch deployments/api -n colis --as=alice
```

```sortie
yes
no
yes
no
no
no
```

La dernière ligne rappelle que le droit vient du groupe : sans `--as-group`, l'API server évalue une Alice sans groupe, qui n'a rien. `--as` repose sur un verbe RBAC à part entière, `impersonate`, que seuls les administrateurs devraient avoir.

:::panne[Forbidden alors que le rôle est bon]

Trois causes reviennent presque toujours. La liaison est dans un autre namespace que celui de la requête (une RoleBinding de `colis` ne donne rien dans `colis-dev`). Le sujet ne correspond pas : `kind: User` au lieu de `Group`, ou un ServiceAccount sans son `namespace`. Ou la règle désigne la ressource dans le mauvais groupe d'API : `deployments` est dans `apps`, pas dans `""`. Comparez mot à mot le message d'erreur et la règle : le verbe, la ressource et le groupe y sont écrits en toutes lettres.

:::

Une limite de `resourceNames` à connaître : elle ne peut pas restreindre `create` ni `deletecollection`, puisque le nom d'un objet à créer n'est pas connu au moment de l'autorisation[^rbac]. Et pour `list`, elle ne fonctionne que si le client demande explicitement ce nom (exercice 4).

## Les rôles fournis et l'agrégation

Kubernetes fournit quatre ClusterRoles destinées aux humains : `cluster-admin`, `admin`, `edit` et `view`[^rbac]. Les trois dernières sont faites pour être données namespace par namespace. Le script `roles-par-defaut.sh` crée dans `ch43` trois ServiceAccounts, un par rôle, et compare ce qu'ils peuvent faire :

```bash
bash roles-par-defaut.sh ch43
```

```sortie
action                           view  edit  admin
list pods                        yes   yes   yes  
get pods/log                     yes   yes   yes  
get secrets                      no    yes   yes  
create pods                      no    yes   yes  
create pods/exec                 no    yes   yes  
create serviceaccounts/token     no    yes   yes  
impersonate serviceaccounts      no    yes   yes  
patch deployments                no    yes   yes  
create roles                     no    no    yes  
create rolebindings              no    no    yes  
create resourcequotas            no    no    no   
```

`view` ne lit pas les Secrets, et c'est voulu. L'écart entre `view` et `edit` est bien plus grand que leurs noms ne le laissent croire. `edit` lit les Secrets du namespace, lance des Pods sous n'importe quel ServiceAccount du namespace, et peut agir au nom de ces comptes. La documentation en tire la conséquence : quiconque a `edit` dans un namespace a, en pratique, les droits de tous les ServiceAccounts de ce namespace[^rbac]. Donnez `edit` comme vous donneriez les droits du compte le plus puissant du namespace. `admin` ajoute la gestion des rôles et des liaisons dans le namespace. Aucun ne touche aux quotas (`resourcequotas`), qui restent l'affaire de l'administrateur du cluster.

`view` contient 15 règles sur minikube, et ne connaît pas les objets de KEDA. Ces rôles sont **agrégés** : un contrôleur y recopie les règles de toute ClusterRole qui porte l'étiquette convenue. On l'utilise pour rendre les ScaledObjects visibles à ceux qui ont `view`, `edit` ou `admin` :

```yaml title="keda-lecture.yaml"
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cours-keda-lecture
  labels:
    rbac.authorization.k8s.io/aggregate-to-view: "true"
    rbac.authorization.k8s.io/aggregate-to-edit: "true"
    rbac.authorization.k8s.io/aggregate-to-admin: "true"
rules:
- apiGroups: [keda.sh]
  resources: [scaledobjects, scaledjobs, triggerauthentications]
  verbs: [get, list, watch]
```

```bash
kubectl -n colis create rolebinding cours-view-carla --clusterrole=view --user=carla
kubectl auth can-i list scaledobjects.keda.sh -n colis --as=carla
kubectl get clusterrole view -o json | jq '.rules | length'
kubectl apply -f keda-lecture.yaml
kubectl get clusterrole view -o json | jq '.rules | length'
kubectl get clusterrole view -o json | jq -c '.rules[] | select(.apiGroups == ["keda.sh"])'
kubectl auth can-i list scaledobjects.keda.sh -n colis --as=carla
kubectl get scaledobjects -n colis --as=carla
```

```sortie
rolebinding.rbac.authorization.k8s.io/cours-view-carla created
no
15
clusterrole.rbac.authorization.k8s.io/cours-keda-lecture created
16
{"apiGroups":["keda.sh"],"resources":["scaledobjects","scaledjobs","triggerauthentications"],"verbs":["get","list","watch"]}
yes
NAME     SCALETARGETKIND      SCALETARGETNAME   MIN   MAX   READY   ACTIVE   FALLBACK   PAUSED   TRIGGERS   AUTHENTICATIONS   AGE
worker   apps/v1.Deployment   worker            0     5     True    False    False      False    redis                        6d5h
```

La règle apparaît dans `view` dans la seconde, et Carla voit le ScaledObject du worker de Colis. On ne modifie jamais `view` directement. D'abord parce que l'agrégation réécrirait ses règles. Ensuite parce que l'API server remet à jour les rôles par défaut à chaque démarrage, en y rajoutant ce qui leur manque[^rbac]. Les charts Helm sérieux font comme on vient de faire : ils livrent des ClusterRoles étiquetées pour leurs propres ressources (c'est le cas de `cert-manager-view` sur ce cluster).

## Un compte pour la CI

Un pipeline d'intégration continue qui déploie Colis a besoin de changer l'image d'un Deployment et de suivre le déploiement. Il n'a besoin de rien d'autre. Le fichier `deployeur.yaml` crée un ServiceAccount dédié, sans jeton monté (il ne tourne pas dans un Pod), et un rôle à sa mesure :

```yaml title="deployeur.yaml (le rôle)"
rules:
- apiGroups: [apps]
  resources: [deployments]
  verbs: [get, list, watch]
- apiGroups: [apps]
  resources: [deployments]
  resourceNames: [api, web, worker]
  verbs: [patch]
```

Le pipeline reçoit un jeton de dix minutes, demandé juste avant le déploiement (chapitre 42), et déploie l'image de l'API par son empreinte plutôt que par son étiquette, comme on l'a recommandé au chapitre 14 :

```bash
kubectl apply -f deployeur.yaml
T=$(kubectl -n colis create token deployeur --duration=10m)
ci() { kubectl --kubeconfig=/dev/null --server=https://192.168.49.2:8443 --certificate-authority=$HOME/.minikube/ca.crt --token="$T" -n colis "$@"; }
ci set image deployment/api api=host.minikube.internal:5001/colis/api@sha256:ade99a611b6a907ceacc9deb10f1a7cc21a1f49f7f4395d5d5b5a145205ad3a5
ci rollout status deployment/api --timeout=180s
ci set image deployment/redis redis=redis:8.8
ci get pods
ci get secrets
```

```sortie
serviceaccount/deployeur created
role.rbac.authorization.k8s.io/deployeur created
rolebinding.rbac.authorization.k8s.io/deployeur created
deployment.apps/api image updated
Waiting for deployment "api" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "api" rollout to finish: 1 old replicas are pending termination...
deployment "api" successfully rolled out
error: failed to patch image update to pod template: deployments.apps "redis" is forbidden: User "system:serviceaccount:colis:deployeur" cannot patch resource "deployments" in API group "apps" in the namespace "colis"
Error from server (Forbidden): pods is forbidden: User "system:serviceaccount:colis:deployeur" cannot list resource "pods" in API group "" in the namespace "colis"
Error from server (Forbidden): secrets is forbidden: User "system:serviceaccount:colis:deployeur" cannot list resource "secrets" in API group "" in the namespace "colis"
```

(On a retiré de la sortie quatre répétitions des lignes `Waiting for…`.) `kubectl rollout status` n'a besoin que de suivre le Deployment, dont le statut dit combien de réplicas sont à jour : `watch` sur `deployments` suffit. Si le jeton de ce pipeline fuit, il permet de changer l'image de trois Deployments pendant dix minutes au plus, et rien d'autre. Comparez avec ce qu'on voit souvent : un kubeconfig `cluster-admin` stocké dans les variables du pipeline.

Un piège pendant la mise au point de ce rôle : si l'image demandée est déjà celle du Deployment, `kubectl set image` ne trouve rien à changer et n'envoie aucune requête. Il n'y a alors ni succès ni refus à observer, et l'on peut croire à tort qu'un droit manquant est présent. Testez vos rôles avec `kubectl auth can-i`, qui pose la question sans dépendre de l'état des objets.

## Les garde-fous de l'API server

Déléguer la gestion des droits est tentant : une cheffe de projet pourrait créer elle-même les rôles de son équipe. RBAC le permet sans risque grâce à une règle que l'API server applique à toute création de rôle ou de liaison : **on ne peut donner que ce qu'on a soi-même**[^rbac]. Le rôle `chef-projet` du kit donne à Alice, dans `ch43`, la lecture des Pods et des ConfigMaps, et la création de rôles et de liaisons. Voyons ce qu'elle peut en faire :

```bash
kubectl apply -f chef-projet.yaml
export KUBECONFIG=$PWD/alice.kubeconfig
kubectl -n ch43 create role lecteur --verb=get,list --resource=pods,configmaps
kubectl -n ch43 create rolebinding lecteur-bruno --role=lecteur --user=bruno
kubectl -n ch43 create role lecteur-secrets --verb=get --resource=secrets
kubectl -n ch43 create rolebinding admin-bruno --clusterrole=admin --user=bruno
```

```sortie
role.rbac.authorization.k8s.io/chef-projet created
rolebinding.rbac.authorization.k8s.io/chef-projet created
role.rbac.authorization.k8s.io/lecteur created
rolebinding.rbac.authorization.k8s.io/lecteur-bruno created
Error from server (Forbidden): roles.rbac.authorization.k8s.io "lecteur-secrets" is forbidden: user "alice" (groups=["equipe-colis" "system:authenticated"]) is attempting to grant RBAC permissions not currently held:
{APIGroups:[""], Resources:["secrets"], Verbs:["get"]}
error: failed to create rolebinding: rolebindings.rbac.authorization.k8s.io "admin-bruno" is forbidden: user "alice" (groups=["equipe-colis" "system:authenticated"]) is attempting to grant RBAC permissions not currently held:
{APIGroups:[""], Resources:["bindings"], Verbs:["get" "list" "watch"]}
{APIGroups:[""], Resources:["configmaps"], Verbs:["create" "delete" "deletecollection" "patch" "update"]}
[...]
85 règles manquantes au total
```

Alice a pu transmettre à Bruno ce qu'elle a déjà. Les deux autres demandes sont refusées, et le message liste précisément les permissions qui lui manquent pour les accorder : une seule pour le rôle sur les Secrets, 85 pour la ClusterRole `admin`. La délégation ne peut donc pas élargir les droits de celui qui délègue.

Deux verbes RBAC suspendent ce garde-fou : `escalate`, sur les rôles, et `bind`, sur les liaisons. Ils existent pour les outils d'administration qui doivent créer des rôles plus larges que leurs propres droits. Ne les donnez qu'à ces outils, en connaissance de cause[^bonnes].

## L'autorisateur Node

Le premier autorisateur de la chaîne, `Node`, ne répond qu'aux kubelets, reconnus à leur nom `system:node:<nœud>` et à leur groupe `system:nodes`. Il ne raisonne pas par règles mais par **relations** : un kubelet peut lire un Secret, une ConfigMap ou un volume seulement si un Pod placé sur son nœud l'utilise[^node]. On le vérifie en posant la question en son nom :

```bash
kubectl -n ch43 create secret generic orphelin --from-literal=cle=valeur
N="--as=system:node:minikube --as-group=system:nodes"
printf "%-36s %s\n" "get secret colis-db (colis)" "$(kubectl auth can-i get secret/colis-db -n colis $N)"
printf "%-36s %s\n" "get secret orphelin (ch43)" "$(kubectl auth can-i get secret/orphelin -n ch43 $N)"
printf "%-36s %s\n" "list secrets (colis)" "$(kubectl auth can-i list secrets -n colis $N)"
printf "%-36s %s\n" "get secret colis-db, nœud m02" "$(kubectl auth can-i get secret/colis-db -n colis --as=system:node:m02 --as-group=system:nodes)"
```

```sortie
get secret colis-db (colis)          yes
get secret orphelin (ch43)           no - node: no relationship found between node 'minikube' and this object
list secrets (colis)                 no - node: No Object name found
get secret colis-db, nœud m02       no - node: no relationship found between node 'm02' and this object
```

Quand la réponse est non, `kubectl auth can-i` ajoute la raison donnée par l'autorisateur. Le kubelet de `minikube` lit `colis-db`, que montent l'API, le worker, PostgreSQL et les tâches de purge, tous sur ce nœud. Il ne lit pas un Secret qu'aucun Pod n'utilise, ne peut lister aucun Secret, et le kubelet d'un autre nœud n'aurait pas accès à `colis-db`. Sur un cluster de plusieurs nœuds, un nœud compromis n'expose ainsi que les Secrets de ses propres Pods. Le contrôleur d'admission `NodeRestriction`, actif sur minikube, complète le dispositif : il empêche un kubelet de modifier d'autres objets `Node` ou `Pod` que les siens[^node].

## Relire les droits d'un cluster

Écrire des rôles ajustés ne sert à rien si l'on ne sait pas relire ceux qui existent. Trois outils, du plus précis au plus large.

**`kubectl auth can-i`**, on l'a vu, répond oui ou non pour une identité et une action. Il pose en fait la question à l'API server par un objet `SubjectAccessReview`, et cet objet peut se créer directement. Sa réponse a l'avantage de dire **quelle liaison** accorde le droit :

```bash
kubectl create -f sar.json -o json | jq -c .status
```

```sortie
{"allowed":true,"reason":"RBAC: allowed by RoleBinding \"astreinte/colis\" of Role \"astreinte\" to Group \"equipe-colis\""}
{"allowed":false}
{"allowed":true,"reason":"RBAC: allowed by ClusterRoleBinding \"minikube-rbac\" of ClusterRole \"cluster-admin\" to ServiceAccount \"default/kube-system\""}
```

Les trois questions étaient : Alice peut-elle faire un `patch` sur le Deployment `api` de `colis` ? Peut-elle lire le Secret `colis-db` ? Le ServiceAccount `kube-system/default` peut-il supprimer le namespace `colis` ? La troisième réponse remonte jusqu'à la liaison du début du chapitre. C'est aussi par `SubjectAccessReview` que des composants extérieurs, comme le kubelet ou metrics-server, demandent à l'API server si un appelant a le droit de faire ce qu'il leur demande.

Le composant ci-dessous refait ce raisonnement pas à pas, avec les rôles et les liaisons de ce chapitre. Choisissez une identité et une requête : il parcourt la chaîne de la figure 43.1, puis toutes les liaisons, et montre celle qui accorde le droit, ou le message que kubectl afficherait. Essayez par exemple `deployeur` sur `deployments/redis`, Alice dans `colis-dev` avec un `delete`, ou `list` sur `deployments` avec et sans nom.

<EvaluateurRBAC />

**`qui-peut.py`** prend la question dans l'autre sens : pour une action, qui a le droit ? Il lit tous les rôles et toutes les liaisons du cluster par `kubectl get -o json`, et garde les liaisons dont une règle couvre l'action. Le cœur du script est la correspondance entre une règle et une requête, avec les jokers `*` :

```python title="qui-peut.py (extrait)"
def regles_qui_permettent(regles, verbe, groupe, ressource):
    for r in regles or []:
        if (couvre(r.get("verbs", []), verbe)
                and couvre(r.get("apiGroups", []), groupe)
                and ressource_couverte(r.get("resources", []), ressource)):
            yield r
```

Qui peut lire le mot de passe de PostgreSQL de Colis ?

```bash
python3 qui-peut.py get secrets colis
```

```sortie
Group kubeadm:cluster-admins                          ClusterRoleBinding kubeadm:cluster-admins -> cluster-admin                                          tout le cluster 
Group system:masters                                  ClusterRoleBinding cluster-admin                                                                    tout le cluster 
ServiceAccount cert-manager/cert-manager              ClusterRoleBinding cert-manager-controller-certificates                                             tout le cluster 
ServiceAccount cert-manager/cert-manager              ClusterRoleBinding cert-manager-controller-challenges                                               tout le cluster 
ServiceAccount cert-manager/cert-manager              ClusterRoleBinding cert-manager-controller-clusterissuers                                           tout le cluster 
ServiceAccount cert-manager/cert-manager              ClusterRoleBinding cert-manager-controller-issuers                                                  tout le cluster 
ServiceAccount cert-manager/cert-manager              ClusterRoleBinding cert-manager-controller-orders                                                   tout le cluster 
ServiceAccount cert-manager/cert-manager-cainjector   ClusterRoleBinding cert-manager-cainjector                                                          tout le cluster 
ServiceAccount envoy-gateway-system/envoy-gateway     ClusterRoleBinding eg-gateway-helm-envoy-gateway-rolebinding -> eg-gateway-helm-envoy-gateway-role  tout le cluster 
ServiceAccount keda/keda-operator                     ClusterRoleBinding keda-operator                                                                    tout le cluster 
ServiceAccount kube-system/default                    ClusterRoleBinding minikube-rbac -> cluster-admin                                                   tout le cluster 
ServiceAccount kube-system/generic-garbage-collector  ClusterRoleBinding system:controller:generic-garbage-collector                                      tout le cluster 
ServiceAccount kube-system/namespace-controller       ClusterRoleBinding system:controller:namespace-controller                                           tout le cluster 
User system:kube-controller-manager                   ClusterRoleBinding system:kube-controller-manager                                                   tout le cluster 
14 autorisations, plus le groupe system:masters, que RBAC ne consulte jamais
```

Personne de l'équipe Colis ne figure dans la liste, et c'est bon signe. On y trouve les administrateurs, des contrôleurs de Kubernetes lui-même (le ramasse-miettes et le contrôleur des namespaces doivent pouvoir supprimer des Secrets), et surtout les opérateurs installés par des charts Helm à la partie IV : cert-manager, Envoy Gateway et KEDA lisent les Secrets **de tout le cluster**. Ils en ont besoin pour leur travail, mais chacun de leurs Pods porte un jeton qui ouvre tous les Secrets. Le cas de KEDA mérite un regard :

```bash
kubectl get clusterrole keda-operator -o json | jq -c '.rules[] | select(.resources | index("*"))'
```

```sortie
{"apiGroups":["*"],"resources":["*"],"verbs":["get"]}
```

Un `get` sur toutes les ressources de tous les groupes : KEDA doit pouvoir lire n'importe quel objet qu'on lui demande de mettre à l'échelle. Cette règle a l'air d'être de la simple lecture, mais elle couvre aussi les Secrets, et `nodes/proxy`, l'accès à l'API des kubelets, dont la documentation précise que le `get` n'est pas en lecture seule[^bonnes]. Une règle à joker accorde aussi tous les types de ressources qui seront créés plus tard. Il n'y a pas de solution parfaite ici. On peut regarder si le chart propose une option pour restreindre les namespaces surveillés, et sinon savoir que le namespace `keda` mérite la même protection que le plan de contrôle.

### Les permissions à surveiller

La documentation de Kubernetes tient une liste des permissions qui, accordées sans réflexion, donnent plus que ce qu'elles semblent donner[^bonnes]. C'est la liste à avoir sous les yeux quand on écrit un rôle ou qu'on relit un chart :

| Permission | Pourquoi elle compte |
|---|---|
| `get`, `list` ou `watch` sur `secrets` | `list` et `watch` renvoient le contenu des Secrets, pas seulement leurs noms |
| créer des Pods, ou ce qui en crée (Deployments, Jobs…) | un Pod peut monter les Secrets du namespace et tourner sous n'importe quel ServiceAccount du namespace |
| créer des `persistentvolumes` | un PersistentVolume peut désigner un dossier de l'hôte |
| `nodes/proxy` | donne accès à l'API des kubelets, hors de l'audit et de l'admission |
| les verbes `escalate` et `bind` | suspendent le garde-fou de la section précédente |
| le verbe `impersonate` | permet d'agir sous une autre identité |
| approuver des CSR et désigner un signataire | permet d'obtenir un certificat pour une autre identité (chapitre 42) |
| créer des `serviceaccounts/token` | donne un jeton, donc les droits, du compte visé |
| modifier les webhooks d'admission | permet de voir ou de modifier les objets envoyés à l'API (chapitre 45) |
| modifier les namespaces | les étiquettes d'un namespace pilotent Pod Security Admission (chapitre 44) |

Aucune de ces permissions n'est interdite : chacune a des usages légitimes, et les contrôleurs de Kubernetes en ont plusieurs. Mais une liaison qui en accorde une à un humain ou à une application doit pouvoir se justifier, et l'exercice 3 vous fait écrire l'outil qui les retrouve toutes.

## Exercices

:::exercice[Exercice 1 : seulement les journaux]

L'équipe support doit lire les journaux des Pods de Colis, et rien d'autre. Créez un rôle `journaux` qui ne donne que `get` sur `pods/log`, liez-le au groupe `support`, et essayez `kubectl logs` en tant que `sam` du groupe `support`. Que manque-t-il ? Corrigez, puis essayez `kubectl logs deployment/api` : pourquoi échoue-t-il encore, et faut-il le permettre ?

:::

<details>
<summary>Corrigé</summary>

```bash
kubectl -n colis create role journaux --verb=get --resource=pods/log
kubectl -n colis create rolebinding journaux --role=journaux --group=support
P=$(kubectl -n colis get pods --field-selector=status.phase=Running -o name | grep -m1 '^pod/api-' | cut -d/ -f2)
kubectl -n colis logs $P --tail=1 --as=sam --as-group=support
kubectl -n colis delete role journaux
kubectl -n colis create role journaux --verb=get --resource=pods,pods/log
kubectl -n colis logs $P --tail=1 --as=sam --as-group=support
kubectl -n colis logs deployment/api --tail=1 --as=sam --as-group=support
```

```sortie
role.rbac.authorization.k8s.io/journaux created
rolebinding.rbac.authorization.k8s.io/journaux created
Error from server (Forbidden): pods "api-645df4f4c8-q88hj" is forbidden: User "sam" cannot get resource "pods" in API group "" in the namespace "colis"
role.rbac.authorization.k8s.io/journaux created
INFO:     10.244.0.1:60558 - "GET /pret HTTP/1.1" 200 OK
Error from server (Forbidden): deployments.apps "api" is forbidden: User "sam" cannot get resource "deployments" in API group "apps" in the namespace "colis"
```

kubectl lit d'abord le Pod, pour savoir quels conteneurs il contient, avant de demander ses journaux : il faut `get` sur `pods` en plus de `get` sur `pods/log`. Avec `deployment/api`, kubectl doit en outre lire le Deployment et trouver ses Pods, ce qui demande `get` sur `deployments` et `list` sur `pods`. Inutile de le permettre : le support peut obtenir les noms des Pods autrement, et chaque droit en moins est un droit à ne pas justifier. C'est une démarche à retenir : partir de rien, lire le refus, ajouter exactement ce qu'il nomme.

</details>

:::exercice[Exercice 2 : un rôle, deux namespaces]

L'équipe Colis doit pouvoir tout regarder, sauf les Secrets, dans `colis-dev` et `colis-helm`, mais pas dans `colis-defi`. Écrivez une seule ClusterRole `lecture-colis`, donnez-la avec deux RoleBindings au groupe `equipe-colis`, et vérifiez avec `kubectl auth can-i` dans les quatre namespaces `colis-dev`, `colis-helm`, `colis-defi` et `colis`.

:::

<details>
<summary>Corrigé</summary>

```yaml title="corrige/lecture-colis.yaml"
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: lecture-colis
rules:
- apiGroups: [""]
  resources: [pods, pods/log, services, configmaps, events]
  verbs: [get, list, watch]
- apiGroups: [apps]
  resources: [deployments, statefulsets, replicasets]
  verbs: [get, list, watch]
```

```bash
kubectl apply -f corrige/lecture-colis.yaml
for ns in colis-dev colis-helm; do kubectl -n $ns create rolebinding lecture-colis --clusterrole=lecture-colis --group=equipe-colis; done
for ns in colis-dev colis-helm colis-defi colis; do
  printf "%-11s list pods : %-4s get secrets : %s\n" $ns \
    "$(kubectl auth can-i list pods -n $ns --as=bruno --as-group=equipe-colis)" \
    "$(kubectl auth can-i get secrets -n $ns --as=bruno --as-group=equipe-colis)"
done
```

```sortie
clusterrole.rbac.authorization.k8s.io/lecture-colis created
rolebinding.rbac.authorization.k8s.io/lecture-colis created
rolebinding.rbac.authorization.k8s.io/lecture-colis created
colis-dev   list pods : yes  get secrets : no
colis-helm  list pods : yes  get secrets : no
colis-defi  list pods : no   get secrets : no
colis       list pods : yes  get secrets : no
```

La ClusterRole ne donne rien par elle-même : seules les deux RoleBindings l'activent, chacune dans son namespace, d'où le `no` dans `colis-defi`. Le `yes` dans `colis` vient d'ailleurs, du rôle `astreinte`. Pourquoi ne pas avoir pris `view` ? On aurait pu. Mais `view` grandit avec chaque chart qui y agrège ses ressources, alors qu'une ClusterRole à vous ne change que quand vous la modifiez.

</details>

:::exercice[Exercice 3 : un audit RBAC (programmation)]

Écrivez en Python `auditer-rbac.py`, qui parcourt toutes les liaisons du cluster et liste, sujet par sujet, les permissions de la table « Les permissions à surveiller » qu'il a reçues, avec la liaison et la portée. Signalez aussi les règles à joker (`*` dans les verbes et dans les ressources) et les règles limitées par `resourceNames`. Par défaut, omettez les liaisons installées par Kubernetes lui-même (nom commençant par `system:` ou `kubeadm:`), dont les droits sont documentés, et ajoutez une option `--tout` pour les voir. Partez de `qui-peut.py`.

:::

<details>
<summary>Corrigé</summary>

Le corrigé est `corrige/auditer-rbac.py`. La liste des permissions sensibles y est une table de données, ce qui la rend facile à compléter :

```python title="corrige/auditer-rbac.py (extrait)"
SENSIBLES = [
    # (libellé, verbes, groupe d'API, ressources)
    ("lire les Secrets", ["get", "list", "watch"], "", ["secrets"]),
    ("créer des Pods", ["create"], "", ["pods"]),
    ("créer des charges de travail", ["create"], "apps", ["deployments", "daemonsets", "statefulsets"]),
    ("créer des Jobs", ["create"], "batch", ["jobs", "cronjobs"]),
    ("exec ou attach dans les Pods", ["create"], "", ["pods/exec", "pods/attach"]),
    ("émettre des jetons de ServiceAccount", ["create"], "", ["serviceaccounts/token"]),
    ("agir sous une autre identité", ["impersonate"], "", ["users", "groups", "serviceaccounts"]),
    ("lier ou étendre des rôles", ["bind", "escalate"], "rbac.authorization.k8s.io", ["roles", "clusterroles"]),
    ("approuver des CSR", ["update", "patch"], "certificates.k8s.io", ["certificatesigningrequests/approval"]),
    ("API du kubelet (nodes/proxy)", ["get", "create"], "", ["nodes/proxy"]),
    ("créer des PersistentVolumes", ["create"], "", ["persistentvolumes"]),
    ("modifier les webhooks d'admission", ["create", "update", "patch"], "admissionregistration.k8s.io",
     ["validatingwebhookconfigurations", "mutatingwebhookconfigurations"]),
]
```

```bash
python3 corrige/auditer-rbac.py
```

```sortie
ServiceAccount cert-manager/cert-manager
   - créer des Pods, partout (ClusterRoleBinding cert-manager-controller-challenges)
   - lire les Secrets, partout (ClusterRoleBinding cert-manager-controller-certificates)
   - lire les Secrets, partout (ClusterRoleBinding cert-manager-controller-challenges)
   - lire les Secrets, partout (ClusterRoleBinding cert-manager-controller-clusterissuers)
   - lire les Secrets, partout (ClusterRoleBinding cert-manager-controller-issuers)
   - lire les Secrets, partout (ClusterRoleBinding cert-manager-controller-orders)
ServiceAccount cert-manager/cert-manager-cainjector
   - lire les Secrets, partout (ClusterRoleBinding cert-manager-cainjector)
   - modifier les webhooks d'admission, partout (ClusterRoleBinding cert-manager-cainjector)
ServiceAccount cert-manager/cert-manager-webhook
   - lire les Secrets (noms restreints), dans cert-manager (RoleBinding cert-manager-webhook:dynamic-serving)
ServiceAccount ch43/sa-admin
   - agir sous une autre identité, dans ch43 (RoleBinding sa-admin)
   - créer des Jobs, dans ch43 (RoleBinding sa-admin)
   - créer des Pods, dans ch43 (RoleBinding sa-admin)
   - créer des charges de travail, dans ch43 (RoleBinding sa-admin)
   - exec ou attach dans les Pods, dans ch43 (RoleBinding sa-admin)
   - lire les Secrets, dans ch43 (RoleBinding sa-admin)
   - émettre des jetons de ServiceAccount, dans ch43 (RoleBinding sa-admin)
ServiceAccount ch43/sa-edit
   - agir sous une autre identité, dans ch43 (RoleBinding sa-edit)
   - créer des Jobs, dans ch43 (RoleBinding sa-edit)
   - créer des Pods, dans ch43 (RoleBinding sa-edit)
   - créer des charges de travail, dans ch43 (RoleBinding sa-edit)
   - exec ou attach dans les Pods, dans ch43 (RoleBinding sa-edit)
   - lire les Secrets, dans ch43 (RoleBinding sa-edit)
   - émettre des jetons de ServiceAccount, dans ch43 (RoleBinding sa-edit)
ServiceAccount envoy-gateway-system/eg-gateway-helm-certgen
   - lire les Secrets, dans envoy-gateway-system (RoleBinding eg-gateway-helm-certgen)
   - modifier les webhooks d'admission (noms restreints), partout (ClusterRoleBinding eg-gateway-helm-certgen:envoy-gateway-system)
ServiceAccount envoy-gateway-system/envoy-gateway
   - créer des charges de travail, dans envoy-gateway-system (RoleBinding eg-gateway-helm-infra-manager)
   - lire les Secrets, partout (ClusterRoleBinding eg-gateway-helm-envoy-gateway-rolebinding)
ServiceAccount keda/keda-operator
   - API du kubelet (nodes/proxy), partout (ClusterRoleBinding keda-operator)
   - créer des Jobs, partout (ClusterRoleBinding keda-operator)
   - lire les Secrets (noms restreints), dans keda (RoleBinding keda-operator-certs)
   - lire les Secrets, partout (ClusterRoleBinding keda-operator)
   - modifier les webhooks d'admission, partout (ClusterRoleBinding keda-operator-minimal)
ServiceAccount kube-system/csi-hostpathplugin-sa
   - créer des PersistentVolumes, partout (ClusterRoleBinding csi-hostpathplugin-provisioner-cluster-role)
ServiceAccount kube-system/csi-provisioner
   - créer des PersistentVolumes, partout (ClusterRoleBinding csi-provisioner-role)
ServiceAccount kube-system/default
   - API du kubelet (nodes/proxy), partout (ClusterRoleBinding minikube-rbac)
   - agir sous une autre identité, partout (ClusterRoleBinding minikube-rbac)
   - approuver des CSR, partout (ClusterRoleBinding minikube-rbac)
   - créer des Jobs, partout (ClusterRoleBinding minikube-rbac)
   - créer des PersistentVolumes, partout (ClusterRoleBinding minikube-rbac)
   - créer des Pods, partout (ClusterRoleBinding minikube-rbac)
   - créer des charges de travail, partout (ClusterRoleBinding minikube-rbac)
   - exec ou attach dans les Pods, partout (ClusterRoleBinding minikube-rbac)
   - lier ou étendre des rôles, partout (ClusterRoleBinding minikube-rbac)
   - lire les Secrets, partout (ClusterRoleBinding minikube-rbac)
   - modifier les webhooks d'admission, partout (ClusterRoleBinding minikube-rbac)
   - règle joker (tous verbes, toutes ressources), partout (ClusterRoleBinding minikube-rbac)
   - émettre des jetons de ServiceAccount, partout (ClusterRoleBinding minikube-rbac)
ServiceAccount kube-system/storage-provisioner
   - créer des PersistentVolumes, partout (ClusterRoleBinding storage-provisioner)
12 sujets avec au moins une permission sensible
```

Lecture du rapport, du plus important au moins important :

- `kube-system/default` coche toutes les cases. C'est la liaison `minikube-rbac` du début du chapitre, à supprimer sur tout cluster qui n'est pas un poste de TP.
- `sa-edit` et `sa-admin`, les comptes de `roles-par-defaut.sh`, montrent ce que contient vraiment `edit` dans un namespace.
- Les opérateurs (cert-manager, Envoy Gateway, KEDA) ont des droits larges mais justifiés par leur rôle. Il faut le savoir, et protéger leurs namespaces en conséquence.
- Les approvisionneurs de stockage créent des PersistentVolumes, c'est leur métier.

Le script ne voit que RBAC. Il ne voit ni `system:masters`, ni l'autorisateur Node.

</details>

:::exercice[Exercice 4 : une seule ConfigMap]

Dans `ch43`, créez deux ConfigMaps, `reglages` et `autre`, puis un rôle `un-seul` qui permet `get` et `list` sur la seule ConfigMap `reglages`, lié à l'utilisateur `sam`. En tant que `sam`, essayez `kubectl get configmap reglages`, `kubectl get configmaps`, `kubectl get configmaps --field-selector=metadata.name=reglages` et `kubectl get configmap autre`. Expliquez la deuxième réponse.

:::

<details>
<summary>Corrigé</summary>

```bash
kubectl -n ch43 create configmap reglages --from-literal=a=1
kubectl -n ch43 create configmap autre --from-literal=b=2
kubectl -n ch43 create role un-seul --verb=get,list --resource=configmaps --resource-name=reglages
kubectl -n ch43 create rolebinding un-seul --role=un-seul --user=sam
kubectl -n ch43 get configmap reglages --as=sam
kubectl -n ch43 get configmaps --as=sam
kubectl -n ch43 get configmaps --field-selector=metadata.name=reglages --as=sam
kubectl -n ch43 get configmap autre --as=sam
```

```sortie
role.rbac.authorization.k8s.io/un-seul created
rolebinding.rbac.authorization.k8s.io/un-seul created
NAME       DATA   AGE
reglages   1      0s
Error from server (Forbidden): configmaps is forbidden: User "sam" cannot list resource "configmaps" in API group "" in the namespace "ch43"
NAME       DATA   AGE
reglages   1      1s
Error from server (Forbidden): configmaps "autre" is forbidden: User "sam" cannot get resource "configmaps" in API group "" in the namespace "ch43"
```

L'API server décide **avant** d'exécuter la requête, sur ses seuls attributs. Un `list` sans nom demande toute la collection : RBAC ne sait pas que le résultat ne contiendrait, une fois filtré, que des objets permis, et refuse. Le sélecteur de champ `metadata.name=reglages` donne un nom à la requête, et la règle s'applique. C'est le comportement décrit par la documentation pour `list` et `watch`[^rbac]. Il explique que `resourceNames` soit si peu utilisé avec `list`, et que les outils qui listent tout (tableaux de bord, opérateurs) demandent presque toujours un accès à toute la collection.

</details>

## Nettoyer

Le script de rejeu remet l'image de l'API sur l'étiquette `2.1` en sortant. Pour retirer les objets du chapitre :

```bash
kubectl delete namespace ch43
kubectl -n colis delete role,rolebinding astreinte deployeur journaux --ignore-not-found
kubectl -n colis delete rolebinding cours-view-carla --ignore-not-found
kubectl -n colis delete sa deployeur --ignore-not-found
kubectl -n colis-dev delete rolebinding lecture-colis --ignore-not-found
kubectl -n colis-helm delete rolebinding lecture-colis --ignore-not-found
kubectl delete clusterrole cours-keda-lecture lecture-colis --ignore-not-found
kubectl delete csr alice --ignore-not-found
```

La liaison `minikube-rbac` appartient à minikube, et ses addons peuvent en dépendre ; on la laisse en place sur ce poste de TP. On la notera parmi les écarts du défi VI.

[^rbac]: Kubernetes, « Using RBAC Authorization » : Role, ClusterRole et liaisons, permissions additives sans règle de refus, `resourceNames` (ni `create` ni `deletecollection` ; `list` et `watch` exigent un sélecteur de champ), ClusterRoles agrégées, rôles destinés aux utilisateurs (`edit` permet d'obtenir les droits de tout ServiceAccount du namespace), mise à jour automatique des rôles par défaut au démarrage, restrictions à la création de rôles et de liaisons (verbes `escalate` et `bind`). [kubernetes.io/docs/reference/access-authn-authz/rbac](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
[^bonnes]: Kubernetes, « Role Based Access Control Good Practices » : moindre privilège, groupe `system:masters` qui échappe à toutes les vérifications, revue périodique, et liste des permissions présentant un risque d'élévation de privilèges (Secrets, création de charges de travail, PersistentVolumes, `nodes/proxy`, `escalate`, `bind`, `impersonate`, CSR, TokenRequest, webhooks d'admission, namespaces). [kubernetes.io/docs/concepts/security/rbac-good-practices](https://kubernetes.io/docs/concepts/security/rbac-good-practices/)
[^node]: Kubernetes, « Using Node Authorization » : autorisateur Node, relations entre un nœud et les objets que ses Pods utilisent, contrôleur d'admission `NodeRestriction`. [kubernetes.io/docs/reference/access-authn-authz/node](https://kubernetes.io/docs/reference/access-authn-authz/node/)
[^kubeadm]: Kubernetes, « Implementation details » de kubeadm : `admin.conf` porte un certificat `O = kubeadm:cluster-admins, CN = kubernetes-admin`, groupe lié à `cluster-admin`, fichier à garder sur les nœuds du plan de contrôle. [kubernetes.io/docs/reference/setup-tools/kubeadm/implementation-details](https://kubernetes.io/docs/reference/setup-tools/kubeadm/implementation-details/)
