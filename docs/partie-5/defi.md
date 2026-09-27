---
title: Défi V, du kubectl apply au processus
sidebar_label: Défi V
description: "Prouver, pièce par pièce, tout ce que déclenche un kubectl apply : la requête à l'API, l'écriture dans etcd, les contrôleurs, le scheduler, le kubelet, le runtime, le processus et son adresse ; puis reconstituer la chronologie exacte, à la milliseconde, à partir des révisions d'etcd."
partie: 5
plaque: Défi V
---

« Un `kubectl apply`, ça envoie le conteneur sur le nœud. » Un collègue vous l'a dit, en réunion, pour expliquer à un chef de projet ce qui se passe quand on déploie. Vous savez maintenant que c'est faux à peu près à chaque mot : `kubectl` n'envoie rien au nœud, il écrit un objet dans une API, et une demi-douzaine de programmes, qui ne se parlent pas, font le reste en réagissant chacun à ce qu'ils voient changer. Le chef de projet, lui, veut des preuves.

Le défi consiste à les fournir. Vous allez suivre la création d'un Deployment de bout en bout, de la requête HTTP de `kubectl` jusqu'au processus qui tourne sur le nœud, en prouvant chaque maillon de la chaîne par une commande et sa sortie, puis en reconstituant l'ordre exact de tout ce qui s'est passé. Tout ce qu'il faut a été vu dans cette partie ; aucune commande nouvelle n'est nécessaire, seulement de les assembler.

## Le point de départ

Le cluster principal, tel que le chapitre 41 l'a laissé. Le fichier `temoin.yaml` de [l'archive defi-5](pathname:///kits/defi-5.tar.gz) crée un namespace `defi5`, un Deployment `temoin` de deux répliques et le Service qui va avec ; ne l'appliquez pas trop vite, l'une des exigences demande d'avoir préparé l'observation avant.

La grille est un script, `verifier.sh`, qui vérifie automatiquement les huit maillons de la chaîne pour un Deployment donné. Il ne remplace pas votre dossier de preuves : il vous dit seulement si la chaîne est complète, et vous donne des points de repère.

```bash
./verifier.sh defi5 temoin
```

## Le cahier des charges

Constituez un dossier (un fichier texte suffit) qui contient, pour chacune des questions suivantes, la commande qui y répond et sa sortie, commentée en une ou deux phrases.

1. **La requête** : quelles requêtes HTTP `kubectl apply` envoie-t-il, avec quelles méthodes, vers quelles URL, et avec quels codes de réponse ? (chapitre 34)
2. **Le stockage** : sous quelle clé le Deployment est-il rangé dans etcd, et que vaut sa révision, comparée à sa `resourceVersion` ? (chapitre 35)
3. **Les contrôleurs** : qui a créé le ReplicaSet, et qui a créé les Pods ? Montrez les liens de propriété, et les traces que ces créateurs ont laissées. (chapitre 36)
4. **Le placement** : qui a choisi le nœud de chaque Pod, et où cette décision est-elle écrite ? (chapitre 37)
5. **Le démarrage** : qui a démarré les conteneurs, et que voit-on dans le runtime du nœud pour l'un des Pods (bac à sable, conteneur) ? (chapitre 38)
6. **Le processus** : quel est le PID du conteneur sur le nœud, et comment prouver qu'il appartient bien à ce Pod ? (chapitre 38)
7. **Le réseau** : qui a attribué son adresse au Pod, et comment cette adresse est-elle arrivée dans l'EndpointSlice du Service ? (chapitres 39 et 40)
8. **La chronologie** : dans quel ordre exact toutes les écritures ont-elles eu lieu, et combien de temps s'est écoulé entre la création du Deployment et le moment où les deux Pods sont prêts et joignables par le Service ?

Et une règle : la chronologie doit être **observée**, pas reconstituée après coup à partir des dates de création des objets, qui ne sont précises qu'à la seconde. Il faut donc avoir mis en place l'observation avant le `kubectl apply`.

## La grille

Quand la chaîne est complète, le script affiche huit `OK` :

```sortie
OK      1. le Deployment est dans etcd, resourceVersion 109858 = mod_revision 109858
OK      2. le ReplicaSet temoin-7dbb69b8f9 a pour propriétaire le Deployment
OK      3. 2 Pod(s) prêt(s) appartiennent au ReplicaSet
OK      4. le Pod temoin-7dbb69b8f9-pp2z9 a été placé sur minikube par default-scheduler
OK      5. le kubelet de minikube a démarré son conteneur
OK      6. containerd : bac à sable 6a77dc52b18d1, conteneur 5b16bd6a338ca
OK      7. le processus 30272 est dans le cgroup du Pod (podca4bbb44_75bd_490e_9630_c53ba09e61ab)
OK      8. l'adresse 10.244.0.70 a été attribuée au bac à sable par le greffon, et figure dans une EndpointSlice

8 vérification(s) réussie(s), 0 en échec
```

Lisez le script : chaque vérification est une piste pour l'une des questions du cahier des charges.

## Indices

Ouvrez-les un par un, seulement si vous êtes bloqué.

<details>
<summary>Indice 1 : voir les requêtes</summary>

Le niveau de détail `-v=6` de kubectl affiche une ligne par requête, avec la méthode, l'URL et le code de réponse. Un `apply` qui crée un objet n'envoie pas la même méthode qu'un `apply` qui le modifie : faites l'essai sur un namespace vide.

</details>

<details>
<summary>Indice 2 : une chronologie précise</summary>

Les objets de l'API ont une date de création à la seconde, les événements aussi, et un Deployment se déploie en moins d'une seconde. En revanche, chaque écriture dans etcd reçoit une révision, un compteur global et strictement croissant (chapitre 35). Un watch ouvert sur etcd avant le `kubectl apply` voit passer toutes les écritures, dans l'ordre, et il suffit d'horodater chaque ligne à sa réception pour avoir des durées.

</details>

<details>
<summary>Indice 3 : de quel événement s'agit-il ?</summary>

Dans etcd, les événements ont des clés opaques (le nom de l'objet suivi d'un identifiant). Leur valeur est en protobuf, mais les chaînes de caractères y sont lisibles (chapitre 35) : la raison de l'événement (`Scheduled`, `Pulled`, `Started`...) s'y trouve en clair.

</details>

<details>
<summary>Indice 4 : prouver l'appartenance d'un processus</summary>

Un PID ne dit pas à quel Pod il appartient. Son cgroup, si : le chemin lu dans `/proc/<pid>/cgroup` contient l'`uid` du Pod (chapitre 38). Et l'adresse d'un Pod est notée par le greffon `host-local` dans un fichier qui contient l'identifiant de son bac à sable (chapitre 39).

</details>

## Corrigé

Ne l'ouvrez qu'après avoir essayé. Le corrigé est dans le dépôt du cours, sous `kits/defi-5/corrige` : un script, `chronologie.sh`, qui recrée le namespace, ouvre un watch sur etcd, lance le `kubectl apply` et reconstitue tout.

<details>
<summary>Voir le corrigé commenté</summary>

### Préparer l'observation

Le script ouvre un watch sur tout le préfixe `/registry` d'etcd, et horodate chaque ligne reçue avec l'horloge de bash (`$EPOCHREALTIME`, à la microseconde). Il le fait **avant** d'appliquer quoi que ce soit :

```bash title="chronologie.sh (extrait)"
kubectl -n kube-system exec etcd-minikube -- etcdctl --cacert=$C/ca.crt --cert=$C/server.crt --key=$C/server.key \
  watch /registry/ --prefix -w json 2>/dev/null \
  | while IFS= read -r l; do printf '%s %s\n' "$EPOCHREALTIME" "$l"; done > watch.txt &
```

Un petit programme Python, `trier.py`, relit ensuite ce fichier, ne garde que les clés du namespace `defi5`, les trie par révision, remplace les noms aléatoires des deux Pods par `<Pod 1>` et `<Pod 2>`, et lit la raison de chaque événement dans sa valeur.

### 1. La requête

```sortie
# kubectl apply lancé à 05:29:07.107786 UTC
verb="PATCH" url="https://192.168.49.2:8443/api/v1/namespaces/defi5?fieldManager=kubectl-client-side-apply&fieldValidation=Strict" status="200 OK"
verb="POST" url="https://192.168.49.2:8443/apis/apps/v1/namespaces/defi5/deployments?fieldManager=kubectl-client-side-apply&fieldValidation=Strict" status="201 Created"
verb="POST" url="https://192.168.49.2:8443/api/v1/namespaces/defi5/services?fieldManager=kubectl-client-side-apply&fieldValidation=Strict" status="201 Created"
```

Trois requêtes. Le namespace existait déjà (le script l'a recréé vide pour pouvoir ouvrir le watch) : `apply` le complète par un `PATCH`, qui ajoute son annotation `last-applied-configuration`. Le Deployment et le Service n'existaient pas : deux `POST` sur leurs collections, et deux `201 Created`. Le paramètre `fieldManager=kubectl-client-side-apply` est le nom sous lequel kubectl apparaîtra dans les `managedFields` (chapitre 34).

### 2 à 7. Toute la chaîne, dans l'ordre d'etcd

```sortie
# écritures dans etcd (révision, heure de réception UTC, écart depuis la première, opération, clé)
109817  05:29:07.419  +    0 ms  CRÉE   /registry/deployments/defi5/temoin
109818  05:29:07.431  +   13 ms  CRÉE   /registry/replicasets/defi5/temoin-7dbb69b8f9
109820  05:29:07.438  +   19 ms  MODIF  /registry/deployments/defi5/temoin
109821  05:29:07.444  +   25 ms  CRÉE   /registry/services/specs/defi5/temoin
109822  05:29:07.446  +   27 ms  CRÉE   /registry/events/defi5/temoin...  (ScalingReplicaSet)
109823  05:29:07.454  +   35 ms  CRÉE   /registry/pods/defi5/<Pod 1>
109824  05:29:07.458  +   39 ms  CRÉE   /registry/services/endpoints/defi5/temoin
109825  05:29:07.458  +   40 ms  CRÉE   /registry/endpointslices/defi5/temoin-7ml2f
109826  05:29:07.461  +   42 ms  MODIF  /registry/deployments/defi5/temoin
109827  05:29:07.467  +   48 ms  CRÉE   /registry/events/defi5/temoin-7dbb69b8f9...  (SuccessfulCreate)
109828  05:29:07.469  +   50 ms  MODIF  /registry/pods/defi5/<Pod 1>
109829  05:29:07.470  +   51 ms  CRÉE   /registry/pods/defi5/<Pod 2>
109830  05:29:07.481  +   62 ms  MODIF  /registry/replicasets/defi5/temoin-7dbb69b8f9
109831  05:29:07.483  +   64 ms  CRÉE   /registry/events/defi5/temoin-7dbb69b8f9...  (SuccessfulCreate)
109832  05:29:07.485  +   66 ms  CRÉE   /registry/events/defi5/<Pod 1>...  (Scheduled)
109833  05:29:07.492  +   74 ms  MODIF  /registry/pods/defi5/<Pod 2>
109834  05:29:07.493  +   75 ms  MODIF  /registry/replicasets/defi5/temoin-7dbb69b8f9
109835  05:29:07.505  +   86 ms  MODIF  /registry/deployments/defi5/temoin
109836  05:29:07.518  +   99 ms  MODIF  /registry/pods/defi5/<Pod 1>
109837  05:29:07.518  +   99 ms  CRÉE   /registry/events/defi5/<Pod 2>...  (Scheduled)
109838  05:29:07.534  +  115 ms  MODIF  /registry/pods/defi5/<Pod 2>
109841  05:29:08.009  +  590 ms  CRÉE   /registry/events/defi5/<Pod 1>...  (Pulled)
109842  05:29:08.015  +  596 ms  MODIF  /registry/pods/defi5/<Pod 1>
109843  05:29:08.017  +  598 ms  CRÉE   /registry/events/defi5/<Pod 2>...  (Pulled)
109844  05:29:08.029  +  611 ms  MODIF  /registry/pods/defi5/<Pod 2>
109845  05:29:08.062  +  643 ms  CRÉE   /registry/events/defi5/<Pod 1>...  (Created)
109846  05:29:08.073  +  654 ms  CRÉE   /registry/events/defi5/<Pod 2>...  (Created)
109847  05:29:08.139  +  721 ms  CRÉE   /registry/events/defi5/<Pod 1>...  (Started)
109848  05:29:08.150  +  731 ms  MODIF  /registry/pods/defi5/<Pod 1>
109849  05:29:08.151  +  732 ms  CRÉE   /registry/events/defi5/<Pod 2>...  (Started)
109850  05:29:08.159  +  741 ms  MODIF  /registry/services/endpoints/defi5/temoin
109851  05:29:08.166  +  747 ms  MODIF  /registry/endpointslices/defi5/temoin-7ml2f
109852  05:29:08.167  +  749 ms  MODIF  /registry/replicasets/defi5/temoin-7dbb69b8f9
109853  05:29:08.169  +  750 ms  MODIF  /registry/pods/defi5/<Pod 2>
109854  05:29:08.176  +  757 ms  MODIF  /registry/endpointslices/defi5/temoin-7ml2f
109855  05:29:08.177  +  759 ms  MODIF  /registry/deployments/defi5/temoin
109856  05:29:08.178  +  759 ms  MODIF  /registry/services/endpoints/defi5/temoin
109857  05:29:08.179  +  760 ms  MODIF  /registry/replicasets/defi5/temoin-7dbb69b8f9
109858  05:29:08.191  +  772 ms  MODIF  /registry/deployments/defi5/temoin
<Pod 1> = temoin-7dbb69b8f9-vhzzh; <Pod 2> = temoin-7dbb69b8f9-pp2z9
```

Trente-neuf écritures pour un seul `apply`, en 772 millisecondes. On peut y lire toute la partie V, ligne par ligne.

**Le stockage (question 2).** La première écriture, révision 109817, crée la clé `/registry/deployments/defi5/temoin` : c'est le `POST` de kubectl, traduit par l'API server. La dernière, révision 109858, la modifie une dernière fois ; et la grille confirme que la `resourceVersion` du Deployment vaut bien 109858, sa `mod_revision` dans etcd.

**Les contrôleurs (question 3).** 13 millisecondes après le Deployment, le ReplicaSet est créé (109818), et le contrôleur des Deployments le signale par un événement `ScalingReplicaSet`. 17 millisecondes plus tard, le premier Pod apparaît (109823), puis le second (109829), chacun accompagné d'un `SuccessfulCreate` du contrôleur des ReplicaSets. Aucun de ces contrôleurs n'a reçu d'ordre : chacun a vu, par son watch, l'objet que le précédent venait d'écrire. Les liens de propriété se vérifient dans les objets eux-mêmes :

```bash
kubectl -n defi5 get rs -o jsonpath='{.items[0].metadata.ownerReferences[0].kind}/{.items[0].metadata.ownerReferences[0].name}{"\n"}'
kubectl -n defi5 get pods -o jsonpath='{range .items[*]}{.metadata.name} <- {.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}{end}'
```

```sortie
Deployment/temoin
temoin-7dbb69b8f9-pp2z9 <- ReplicaSet/temoin-7dbb69b8f9
temoin-7dbb69b8f9-vhzzh <- ReplicaSet/temoin-7dbb69b8f9
```

**Le placement (question 4).** Chaque Pod est modifié une première fois juste après sa création (109828 pour le Pod 1, 15 ms après sa création) : c'est le `Binding` du scheduler, qui remplit `spec.nodeName`, suivi de l'événement `Scheduled` écrit par `default-scheduler`. Le scheduler a mis moins de 20 millisecondes à décider.

**Le démarrage (question 5).** Puis vient un temps plus long, d'environ 470 millisecondes, sans aucune écriture concernant ces Pods : c'est le travail du kubelet et du runtime, qui ne passe pas par l'API. Le kubelet a vu les Pods à son nom, a demandé à containerd de créer les bacs à sable (espaces de noms, réseau par le greffon CNI) et les conteneurs. Les horodatages du runtime le montrent, pour le Pod 2 :

```sortie
# sur le nœud, pour temoin-7dbb69b8f9-pp2z9 (UTC)
bac à sable créé      : 2026-09-27T05:29:07.905996024Z
conteneur créé        : 2026-09-27T05:29:08.053906833Z
conteneur démarré     : 2026-09-27T05:29:08.116232731Z
processus             : PID 30272
```

Le bac à sable est créé à 07,906 s, soit 487 ms après le Deployment ; le conteneur est créé 148 ms plus tard, et démarré 62 ms après. Le kubelet le rapporte à l'API par les événements `Pulled` (l'image était déjà sur le nœud), `Created` et `Started`, et par les mises à jour du statut des Pods.

**Le processus (question 6).** Le PID 30272, et la grille prouve qu'il appartient au Pod par son cgroup, dont le chemin contient l'`uid` du Pod.

**Le réseau (question 7).** L'adresse du Pod a été attribuée par le greffon CNI (`host-local`, pour kindnet) au moment de la création du bac à sable, et notée dans un fichier qui porte l'identifiant du bac à sable (vérification 8 de la grille). L'EndpointSlice du Service existait dès la révision 109825, vide ; elle est modifiée à 109851 puis 109854, juste après que chaque Pod est devenu prêt (109848 et 109853) : c'est le contrôleur des EndpointSlices qui y ajoute les adresses prêtes. Les `services/endpoints` qui l'accompagnent sont l'ancien objet `Endpoints`, que Kubernetes tient encore à jour pour les programmes qui le lisent.

**La chronologie (question 8).** De la création du Deployment (+0 ms) au moment où les deux Pods figurent dans l'EndpointSlice (+757 ms), il s'écoule trois quarts de seconde, dont près des deux tiers pour le seul démarrage des conteneurs sur le nœud. Le reste, contrôleurs, scheduler et mises à jour de statut, tient en quelques dizaines de millisecondes. Les dernières écritures (+759 à +772 ms) sont les contrôleurs qui mettent à jour le statut du ReplicaSet et du Deployment : `kubectl rollout status` attend précisément celles-là.

### Ce qu'il faut en retenir

Le chef de projet a ses preuves : `kubectl apply` a fait trois requêtes HTTP, et c'est tout. Des trente-neuf écritures qui ont suivi dans etcd, deux seulement traduisent ses requêtes (la création du Deployment et celle du Service) ; toutes les autres sont le fait de cinq autres programmes (deux contrôleurs, le scheduler, le kubelet et le contrôleur des EndpointSlices), qui ne se sont jamais adressé la parole et qui se sont coordonnés uniquement en observant etcd, par l'intermédiaire de l'API. Si l'un d'eux s'était arrêté en route, la chaîne se serait interrompue à son maillon, sans erreur, jusqu'à son retour ; et à son retour, il aurait repris exactement où il en était, puisqu'il ne travaille que sur l'état, pas sur des ordres (chapitre 36). C'est à la fois la solidité de Kubernetes et la raison pour laquelle, quand quelque chose bloque, il faut savoir quel maillon regarder.

</details>

## Pour aller plus loin

- Recommencez la chronologie en arrêtant le scheduler pendant l'expérience, comme le gestionnaire de contrôleurs au chapitre 36 : où la chaîne s'arrête-t-elle, et que se passe-t-il à son retour ?
- Remplacez l'image par une image que le nœud n'a pas encore. Combien de temps le téléchargement ajoute-t-il, et où le voit-on dans la chronologie ?
- Faites la même chose pour une suppression (`kubectl delete deploy temoin`) : quel est l'ordre des suppressions, et quel contrôleur s'en charge (chapitre 36) ?

## Et maintenant

Vous connaissez les rouages du cluster : qui écrit quoi, où, et dans quel ordre. La partie VI change de point de vue. Chacun de ces rouages est aussi une porte : l'API server accepte les requêtes de ceux qui s'authentifient, les Pods tournent avec les droits qu'on leur donne, etcd garde les Secrets en clair, et une image peut contenir n'importe quoi. On verra comment on s'authentifie auprès de l'API, comment on limite ce que chacun peut faire, comment on durcit les Pods, comment on contrôle ce qui entre dans le cluster, et comment on protège les secrets pour de bon.

Pour faire le ménage du défi :

```bash
kubectl delete namespace defi5
```

Le fichier `watch.txt` que le corrigé écrit dans son dossier peut être supprimé ; il contient toutes les écritures du cluster pendant l'expérience, y compris celles des Secrets.
