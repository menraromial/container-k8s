---
title: etcd
sidebar_label: 35. etcd
description: "La base où vit tout l'état du cluster : les clés /registry, les valeurs en protobuf, les révisions et le lien avec resourceVersion, le watch, les transactions et la concurrence optimiste, le compactage, puis Raft sur un etcd de trois membres, perte du leader et perte du quorum."
partie: 5
chapitre: '35'
---

import etcdRevisions from '@site/src/figures/etcd-revisions.svg';
import etcdRaft from '@site/src/figures/etcd-raft.svg';

Voici un namespace créé il y a vingt secondes, et ses ConfigMaps :

```sortie
NAME               DATA   AGE
Reglages_1         1      268d
kube-root-ca.crt   1      19s
reglages           1      18s
```

Le premier a deux défauts, et chacun devrait le rendre impossible. Son nom contient une majuscule et un tiret bas, ce que l'API server refuse avec un `422 Invalid` (on l'a vu au chapitre 34). Et il a 268 jours, dans un namespace qui en a zéro. Aucune requête à l'API n'a pu le créer. Il a été écrit **directement dans etcd**, la base de données où Kubernetes range tout ce qu'il sait, avec une date de création choisie à la main. L'API server, qui ne fait que lire cette base, l'a trouvé et le sert comme les autres.

Ce chapitre ouvre cette base. Tout ce que vous avez créé depuis la partie III y tient, et plus que cela : chaque nœud, chaque Pod, chaque règle RBAC, chaque événement. Si l'on perd etcd sans sauvegarde, on perd le cluster, même si tous les conteneurs continuent de tourner sur les nœuds, car plus personne ne sait ce qu'ils sont censés faire. Comprendre comment etcd range, date et protège ces données explique beaucoup de comportements vus jusqu'ici : la `resourceVersion`, le code `410`, le `409 Conflict`. Et en seconde moitié, on verra pourquoi un cluster de production a trois ou cinq etcd, et ce qui se passe quand ils ne sont plus assez nombreux.

etcd est un magasin **clé-valeur**, distribué et **fortement cohérent** : une lecture renvoie toujours la dernière écriture validée, quel que soit le membre interrogé[^garanties]. C'est un projet de la CNCF, indépendant de Kubernetes, qui l'utilise comme unique magasin : aucune autre base n'est prise en charge par l'API server officiel.

## Entrer dans etcd

Dans minikube, etcd est un Pod du namespace `kube-system`, qui écoute sur le port 2379 du nœud et n'accepte que les clients munis d'un certificat signé par sa propre autorité. L'image contient l'outil en ligne de commande `etcdctl`, mais pas de shell. Le fichier `etcd-minikube.sh` de [l'archive etcd](pathname:///kits/etcd.tar.gz) définit donc une fonction `E`, qui lance `etcdctl` dans le Pod avec les certificats du nœud :

```bash title="etcd-minikube.sh"
C=/var/lib/minikube/certs/etcd
E() {
  kubectl -n kube-system exec -i etcd-minikube -- \
    etcdctl --cacert=$C/ca.crt --cert=$C/server.crt --key=$C/server.key "$@"
}
```

```bash
kubectl create namespace ch35
kubectl config set-context --current --namespace=ch35
source etcd-minikube.sh
E endpoint status -w simple | awk -F', ' '{print $1, "| base", $5, "dont", $6, "utiles | leader", $9, "| terme", $11, "| index", $12}'
E member list -w simple
```

```sortie
127.0.0.1:2379 | base 8.5 MB dont 8.5 MB utiles | leader true | terme 12 | index 117354
aec36adc501070cc, started, minikube, https://192.168.49.2:2380, https://192.168.49.2:2379, false
```

(La sortie brute de `endpoint status` compte seize colonnes ; `awk` en garde cinq.) Un seul membre, qui est donc son propre leader. La base pèse 8,5 Mo. Le terme et l'index sont des notions de Raft, l'algorithme qui coordonne plusieurs membres ; on y viendra avec un vrai cluster de trois. Le port 2380, dans la liste des membres, est celui où les membres se parlent entre eux ; les clients, dont l'API server, utilisent le 2379.

Une remarque avant d'aller plus loin : la fonction `E` vous donne un accès total à etcd, sans passer par aucune des vérifications du chapitre 34. Sur un vrai cluster, les certificats du nœud de contrôle sont gardés comme des clés de coffre-fort, et ce chapitre va montrer pourquoi.

## Tout le cluster dans un arbre de clés

etcd n'a ni tables ni répertoires : un espace de clés plat, trié par ordre alphabétique, où l'on peut lire une clé, ou toutes celles qui commencent par un préfixe. Kubernetes range tout sous le préfixe `/registry` :

```bash
E get /registry --prefix --keys-only | grep -c /
E get /registry --prefix --keys-only | grep / | awk -F/ '{print $3}' | sort | uniq -c | sort -rn | head -8
```

```sortie
2190
   1250 events
    116 clusterroles
    106 clusterrolebindings
     88 serviceaccounts
     67 services
     62 pods
     61 replicasets
     44 configmaps
```

2190 clés pour tout le cluster, et plus de la moitié sont des **événements**, ces lignes que `kubectl describe` affiche en bas de page (`Scheduled`, `Pulled`, `Started`...). Ils sont nombreux, et on verra plus loin comment etcd s'en débarrasse. Les rôles et les liaisons RBAC viennent ensuite, installés pour la plupart par Kubernetes lui-même et par les composants de la partie IV.

La forme des clés reprend celle des URL du chapitre 34 :

```bash
E get /registry --prefix --keys-only | grep -E '^/registry/(deployments/colis/|pods/colis/postgres|keda.sh|namespaces/colis$)'
```

```sortie
/registry/deployments/colis/api
/registry/deployments/colis/api-canari
/registry/deployments/colis/redis
/registry/deployments/colis/web
/registry/deployments/colis/worker
/registry/keda.sh/scaledobjects/colis/worker
/registry/namespaces/colis
/registry/pods/colis/postgres-0
```

`/registry/<ressource>/<namespace>/<nom>` pour un objet d'un namespace, `/registry/<ressource>/<nom>` pour un objet de tout le cluster, comme le namespace `colis` lui-même. Les ressources ajoutées par une CRD portent en plus le nom de leur groupe : `/registry/keda.sh/scaledobjects/...`. La version (`apps/v1`) n'apparaît pas dans la clé, et c'est logique : on a vu au chapitre 34 qu'un objet est stocké une seule fois, quelle que soit la version par laquelle on le lit.

## Ce qu'il y a dans une valeur

Créons un ConfigMap et lisons sa valeur brute. `od -c` affiche chaque octet, en caractère quand il est imprimable, en octal sinon :

```bash
kubectl create configmap reglages --from-literal=couleur=bleu
E get /registry/configmaps/ch35/reglages --print-value-only | od -c | head -14
```

```sortie
0000000   k   8   s  \0  \n 017  \n 002   v   1 022  \t   C   o   n   f
0000020   i   g   M   a   p 022 267 001  \n 243 001  \n  \b   r   e   g
0000040   l   a   g   e   s 022  \0 032 004   c   h   3   5   "  \0   *
0000060   $   2   c   b   b   9   1   0   9   -   7   b   1   3   -   4
0000100   b   0   a   -   a   d   1   5   -   8   9   3   1   4   d   d
0000120   9   e   c   0   1   2  \0   8  \0   B  \b  \b 224 206 340 325
0000140 006 020  \0 212 001   X  \n 016   k   u   b   e   c   t   l   -
0000160   c   r   e   a   t   e 022 006   U   p   d   a   t   e 032 002
0000200   v   1   "  \b  \b 224 206 340 325 006 020  \0   2  \b   F   i
0000220   e   l   d   s   V   1   :   $  \n   "   {   "   f   :   d   a
0000240   t   a   "   :   {   "   .   "   :   {   }   ,   "   f   :   c
0000260   o   u   l   e   u   r   "   :   {   }   }   }   B  \0 022 017
0000300  \n  \a   c   o   u   l   e   u   r 022 004   b   l   e   u 032
0000320  \0   "  \0  \n
```

Ce n'est pas du JSON mais du **protobuf**, un format binaire plus compact et plus rapide à décoder, précédé de quatre octets magiques, `k8s\0`, qui disent à l'API server comment le lire. On reconnaît pourtant tout au passage : `v1` et `ConfigMap`, le nom `reglages`, le namespace `ch35`, l'`uid`, le gestionnaire `kubectl-create` des `managedFields` du chapitre 34, et à la fin la donnée elle-même, `couleur` et `bleu`. Les nombres qui précèdent chaque chaîne sont sa longueur : `\t` (9) pour `ConfigMap`, `\b` (8) pour `reglages`.

Tous les objets ne sont pas en protobuf. Ceux qui viennent d'une CRD sont stockés en JSON, parce que l'API server ne connaît pas leur schéma à la compilation :

```bash
E get /registry/keda.sh/scaledobjects/colis/worker --print-value-only | head -c 150; echo
```

```sortie
{"apiVersion":"keda.sh/v1alpha1","kind":"ScaledObject","metadata":{"annotations":{"kubectl.kubernetes.io/last-applied-configuration":"{\"apiVersion\":
```

Et c'est justement ce que l'API server a su lire quand on a glissé le faux ConfigMap du début : une valeur JSON sous une clé `/registry/configmaps/...`. Son lecteur reconnaît les deux formats.

Il reste une question qu'on se pose tôt ou tard. Que devient un Secret ?

```bash
kubectl create secret generic motdepasse --from-literal=motdepasse=Tr3sS3cret
E get /registry/secrets/ch35/motdepasse --print-value-only | strings | grep -B1 Tr3sS3cret
```

```sortie
motdepasse
Tr3sS3cret
```

:::panne[Les Secrets sont en clair dans etcd]

Par défaut, un Secret est rangé dans etcd exactement comme un ConfigMap : en protobuf, lisible par quiconque accède à etcd. Le base64 qu'on voit dans le YAML d'un Secret n'est qu'un encodage pour l'affichage ; il n'existe même pas dans etcd. Tout accès à etcd, ou à une **sauvegarde** d'etcd, donne donc tous les mots de passe, jetons et clés privées du cluster. Kubernetes sait chiffrer les Secrets avant de les écrire (*encryption at rest*), avec une clé que l'API server garde hors d'etcd[^chiffrement] ; minikube ne le fait pas. On l'activera au chapitre 46. En attendant, traitez les fichiers de sauvegarde d'etcd comme vous traiteriez le fichier des mots de passe de toute l'entreprise.

:::

## Les révisions

Revenons au ConfigMap `reglages`, et regardons ses métadonnées dans etcd plutôt que sa valeur :

```bash
E get /registry/configmaps/ch35/reglages -w json | jq -c '{revision: .header.revision} + (.kvs[0] | {create_revision, mod_revision, version})'
kubectl get cm reglages -o jsonpath='{.metadata.resourceVersion}{"\n"}'
```

```sortie
{"revision":98067,"create_revision":98067,"mod_revision":98067,"version":1}
98067
```

Trois compteurs. `version` compte les écritures de cette clé : 1, c'est la création. `create_revision` et `mod_revision` sont des numéros de **révision**, et ceux-là ne sont pas propres à la clé. etcd tient un seul compteur pour toute la base, qui avance de un à chaque écriture, quelle que soit la clé ; `header.revision` est sa valeur actuelle. Chaque clé retient la révision de sa création et celle de sa dernière modification. Et la `resourceVersion` que l'API server affiche, c'est tout simplement la `mod_revision` : 98067 dans les deux cas.

Voilà l'explication du trou qu'on avait remarqué à l'exercice 4 du chapitre 34, entre une liste à 94476 et une création à 94484 : entre les deux, huit écritures avaient eu lieu ailleurs dans le cluster. Un nœud qui renouvelle son bail toutes les dix secondes, un contrôleur qui met un statut à jour, un événement : chacune consomme une révision.

Modifions la valeur :

```bash
kubectl patch cm reglages --type=merge -p '{"data":{"couleur":"vert"}}'
E get /registry/configmaps/ch35/reglages -w json | jq -c '{revision: .header.revision} + (.kvs[0] | {create_revision, mod_revision, version})'
kubectl get cm reglages -o jsonpath='{.metadata.resourceVersion}{"\n"}'
```

```sortie
configmap/reglages patched
{"revision":98068,"create_revision":98067,"mod_revision":98068,"version":2}
98068
```

La clé en est à sa deuxième version, modifiée à la révision 98068, et la `resourceVersion` a suivi. Mais l'ancienne valeur n'a pas disparu. etcd est une base **multiversion** (MVCC) : une écriture n'écrase pas, elle ajoute une nouvelle version, et l'on peut encore lire la base telle qu'elle était à une révision passée :

```bash
E get /registry/configmaps/ch35/reglages --rev=98067 --print-value-only | strings | grep -A1 '^couleur' | tail -1
```

```sortie
bleu
```

C'est grâce à cela que la pagination du chapitre 34 donnait une photographie cohérente : toutes les pages étaient lues à la même révision, pendant que la base continuait d'avancer. Et c'est aussi ce qui permet à un watch de reprendre « à partir de la révision N » sans rien manquer. Mais garder toutes les versions de tout, indéfiniment, remplirait le disque. D'où le **compactage** : l'API server demande régulièrement à etcd (toutes les cinq minutes par défaut) d'oublier toutes les versions plus anciennes qu'une certaine révision, sauf la dernière de chaque clé.

```bash
E get /registry/configmaps/ch35/reglages --rev=100
```

```sortie
Error: etcdserver: mvcc: required revision has been compacted
command terminated with exit code 1
```

C'est l'origine du `410 Expired` du chapitre 34 : un watch ou un jeton de pagination qui demande une révision déjà compactée ne peut pas être servi. La figure 35.1 résume ce modèle.

<Figure svg={etcdRevisions} num="35.1" alt="Une ligne de temps graduée en révisions d'etcd, de 97005 à 97010. Sur la ligne de la clé /registry/configmaps/ch35/reglages, la version 1 (couleur: bleu) est créée à une révision, sa create_revision ; la version 2 (couleur: vert) à une révision plus tardive, sa mod_revision, qui est la resourceVersion de l'objet. Sur la ligne des autres clés du cluster, des écritures (baux, statuts, événements) prennent les révisions intermédiaires. Une commande etcdctl get avec --rev égal à la révision de création lit encore bleu. À gauche, une zone grisée marque les révisions compactées : une lecture à la révision 100 répond required revision has been compacted.">
Le compteur de révisions d'etcd est global : chaque écriture, sur n'importe quelle clé, prend la révision suivante. Une clé garde ses anciennes versions jusqu'au compactage.
</Figure>

Le compactage oublie les anciennes versions, mais ne rend pas la place sur le disque : le fichier de la base garde sa taille, avec des trous. Pour la récupérer, il faut **défragmenter** le membre, avec `E defrag`, ce qui le bloque le temps de réécrire le fichier. La première fois que je l'ai fait sur ce cluster, la base pesait 34 Mo, dont 9 seulement utiles ; après 0,12 seconde de défragmentation, il en restait 8,3. Ce n'est pas qu'une question de place : etcd a un **quota**, de 2 Go par défaut, et il compte la taille du fichier, trous compris[^maintenance].

:::panne[etcdserver: mvcc: database space exceeded]

Quand la base atteint son quota, etcd lève une alarme `NOSPACE` et refuse toute nouvelle écriture. Pour Kubernetes, c'est un cluster figé : plus aucun Pod ne peut être créé, plus aucun statut mis à jour, plus aucun bail renouvelé, et les nœuds finissent par être déclarés injoignables. Les causes habituelles sont un compactage qui ne se fait plus, ou un programme qui écrit à toute vitesse (un contrôleur qui met à jour un statut en boucle, des milliers d'événements). La réparation se fait dans l'ordre : trouver et arrêter la source des écritures, compacter, défragmenter chaque membre, puis lever l'alarme avec `etcdctl alarm disarm`. La documentation d'etcd décrit la procédure[^maintenance]. Surveiller la taille de la base (`etcd_mvcc_db_total_size_in_bytes`) évite d'en arriver là.

:::

## Les baux

Revenons aux 1250 événements. Personne ne les supprime jamais explicitement, et pourtant ils ne s'accumulent pas. C'est qu'ils sont écrits avec un **bail** (*lease*) : un objet d'etcd qui a une durée de vie, et auquel on peut rattacher des clés. Quand le bail expire, etcd supprime toutes les clés qui y sont rattachées.

```bash
E lease list | head -1
C1=$(E get /registry/events/colis --prefix --keys-only | grep / | head -1); echo $C1
L=$(E get $C1 -w json | jq -r '.kvs[0].lease')
E lease timetolive $(printf '%x' $L)
```

```sortie
found 88 leases
/registry/events/colis-defi/api-747ccbc945-p54q6.18d8e4fc08b71dd1
lease 70cca0ddc138cfb7 granted with TTL(3660s), remaining(229s)
```

(Le préfixe `/registry/events/colis` attrape aussi `colis-defi`, qui commence de la même façon.) L'événement est rattaché à un bail de 3660 secondes, une heure et une minute ; dans moins de quatre minutes, il disparaîtra. C'est la durée de rétention des événements, réglable par l'option `--event-ttl` de l'API server, une heure par défaut. Voilà pourquoi `kubectl describe` ne montre plus rien d'intéressant sur un Pod qui a eu un problème la veille, et pourquoi les équipes qui en ont besoin exportent les événements vers un système de journaux (chapitre 51).

Ne confondez pas ces baux d'etcd avec les objets `Lease` de Kubernetes, du groupe `coordination.k8s.io`, qu'on a vus au chapitre 34. Ceux-là sont des objets ordinaires, rangés sous `/registry/leases/...`, que les kubelets renouvellent pour dire « je suis vivant », et que le scheduler et le gestionnaire de contrôleurs utilisent pour élire, quand ils tournent en plusieurs exemplaires, celui qui travaille. Même mot, deux choses différentes.

## Surveiller une clé

etcd a son propre watch, que l'API server utilise pour construire le sien. Ouvrons-en un sur le préfixe des ConfigMaps de `ch35`, et faisons trois opérations avec kubectl :

```bash
E watch /registry/configmaps/ch35/ --prefix -w json < /dev/null > ew.txt &
kubectl create configmap temoin --from-literal=a=1
kubectl label cm temoin vu=oui
kubectl delete cm temoin
kill %1
jq -c '.Events[] | {type: (if .type == 1 then "DELETE" else "PUT" end), cle: (.kv.key|@base64d), mod_revision: .kv.mod_revision, version: (.kv.version // 0)}' ew.txt
```

```sortie
{"type":"PUT","cle":"/registry/configmaps/ch35/temoin","mod_revision":98087,"version":1}
{"type":"PUT","cle":"/registry/configmaps/ch35/temoin","mod_revision":98088,"version":2}
{"type":"DELETE","cle":"/registry/configmaps/ch35/temoin","mod_revision":98089,"version":0}
```

etcd ne connaît que deux sortes d'événements, `PUT` et `DELETE` (codé 1 dans le JSON). C'est l'API server qui les traduit en `ADDED`, `MODIFIED` et `DELETED` : un `PUT` de version 1 est une création, un `PUT` de version supérieure une modification.

Sur un cluster qui fait tourner des centaines de contrôleurs et de kubelets, chacun avec ses watches, etcd pourrait crouler sous les connexions. Il n'en voit pourtant qu'une petite partie. L'API server tient un **cache de watch** : pour chaque sorte de ressource, il ouvre un seul watch sur etcd, garde en mémoire l'état courant et une fenêtre d'événements récents, et sert à partir de là tous les watches et la plupart des lectures de ses clients[^cache]. Les compteurs le montrent :

```bash
minikube ssh -- curl -s 127.0.0.1:2381/metrics | grep -E '^etcd_debugging_mvcc_watcher_total|^etcd_disk_wal_fsync_duration_seconds_(count|sum)'
kubectl get --raw /metrics | grep -E '^apiserver_longrunning_requests\{' | grep WATCH | awk '{s+=$NF} END{print "watches servis par l API server :", s}'
```

```sortie
etcd_debugging_mvcc_watcher_total 114
etcd_disk_wal_fsync_duration_seconds_sum 80.61467937400005
etcd_disk_wal_fsync_duration_seconds_count 14573
watches servis par l API server : 327
```

114 watches sur etcd, à peu près un par sorte de ressource, pour 327 watches servis aux clients. Le « 410 » du chapitre 34 venait d'ailleurs de ce cache : le nombre entre parenthèses, dans `too old resource version: 10 (83935)`, était le début de la fenêtre qu'il gardait en mémoire.

Les deux autres lignes mesurent autre chose, qui compte beaucoup pour etcd : le temps de ses `fsync`, ces appels qui obligent le système à écrire vraiment sur le disque avant de continuer. etcd en fait un à chaque écriture validée, pour qu'aucune écriture confirmée ne puisse être perdue dans une coupure de courant. Ici, 80,6 secondes pour 14573 appels, soit 5,5 millisecondes en moyenne, sur le SSD d'un portable. Toutes les écritures du cluster passent par là. La documentation d'etcd insiste sur ce point : un disque lent, ou partagé avec un voisin bruyant, suffit à ralentir tout le cluster, et c'est la première chose à vérifier quand l'API server devient lent[^materiel].

## Écrire sans se marcher dessus

Au chapitre 34, un `PUT` qui portait une `resourceVersion` périmée recevait `409 Conflict`. On peut maintenant voir comment l'API server fait respecter cette règle. etcd propose des **transactions** de la forme « si cette condition est vraie, fais ceci, sinon fais cela », exécutées d'un bloc, sans que rien ne puisse s'intercaler. Simulons deux écrivains qui ont lu la même clé, à la même révision, et veulent chacun y écrire leur valeur. Les clés de cet essai sont hors de `/registry`, pour ne pas toucher au cluster :

```bash
E put /cours/compteur 1
M=$(E get /cours/compteur -w json | jq '.kvs[0].mod_revision'); echo "lu à la révision $M"
txn() { printf 'mod("/cours/compteur") = "%s"\n\nput /cours/compteur %s\n\nget /cours/compteur\n\n' $1 $2 | E txn -w simple; }
txn $M 2    # écrivain A
txn $M 3    # écrivain B
E del /cours/compteur
```

```sortie
OK
lu à la révision 98114
SUCCESS

OK
FAILURE

/cours/compteur
2
1
```

La transaction dit : « si la clé a toujours été modifiée en dernier à la révision 98114, écris ma valeur ; sinon, relis-la ». L'écrivain A réussit (`SUCCESS`, puis le `OK` de son écriture). L'écrivain B arrive après : la clé a changé depuis sa lecture, la condition est fausse, et il reçoit à la place la valeur actuelle, 2 (le dernier `1` est le nombre de clés supprimées par `del`). C'est exactement ce que fait l'API server pour toute modification : il envoie à etcd une transaction qui compare la `mod_revision` à la `resourceVersion` fournie par le client. Si la comparaison échoue, il renvoie `409`. La concurrence optimiste du chapitre 34 n'est rien d'autre que ce test.

## Contourner l'API server

On peut maintenant raconter l'histoire du ConfigMap de 268 jours. Il a été écrit par une seule commande :

```bash
V='{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"Reglages_1","namespace":"ch35","uid":"00000000-0000-0000-0000-000000000001","creationTimestamp":"2026-01-01T00:00:00Z"},"data":{"origine":"etcdctl"}}'
E put /registry/configmaps/ch35/Reglages_1 "$V"
kubectl get cm
```

```sortie
OK
NAME               DATA   AGE
Reglages_1         1      268d
kube-root-ca.crt   1      19s
reglages           1      18s
```

En écrivant directement dans etcd, on a sauté tout le trajet de la figure 34.2 : ni authentification, ni autorisation, ni admission, ni validation du nom. L'`uid` et la date de création, que l'API server fixe normalement lui-même, sont ceux qu'on a inventés. La `resourceVersion`, en revanche, est bien réelle : elle vient d'etcd, qui l'attribue à toute écriture. Et l'objet a été diffusé comme les autres, puisque le cache de watch de l'API server suit etcd : tous les contrôleurs qui surveillent les ConfigMaps l'ont vu arriver.

Deux leçons. D'abord, n'écrivez jamais dans etcd à la main sur un cluster qui compte : on peut y créer des objets qu'aucun composant ne sait traiter, et aucune garde ne vous arrêtera. Ensuite, celui qui atteint etcd a plus de pouvoir qu'un administrateur du cluster : il ne laisse aucune trace dans les journaux d'audit de l'API server, et contourne toutes les politiques de sécurité. C'est pourquoi etcd écoute en TLS, n'accepte que des certificats clients, et tourne sur des machines à part dans les installations exigeantes.

L'objet se supprime sans difficulté par l'API, puisque la suppression ne valide pas le nom :

```bash
kubectl delete cm Reglages_1
```

```sortie
configmap "Reglages_1" deleted from ch35 namespace
```

## Trois membres, un leader

Un etcd seul est un point de défaillance unique : s'il s'arrête, le cluster ne peut plus rien écrire ni rien lire de cohérent. En production, on en fait tourner trois ou cinq, sur des machines différentes, qui gardent chacun une copie complète des données. La difficulté est de les garder d'accord : si deux membres acceptaient chacun une écriture différente pour la même clé, lequel aurait raison ? etcd résout ce problème avec **Raft**, un algorithme de consensus publié en 2014 par Diego Ongaro et John Ousterhout, conçu explicitement pour être plus facile à comprendre que ses prédécesseurs[^raft].

L'idée centrale de Raft est qu'il y a, à tout moment, au plus un **leader**. Toutes les écritures passent par lui. Il les note dans un **journal** (une suite numérotée d'entrées, c'est l'« index » de la sortie de `endpoint status`), les envoie aux autres membres, les **suiveurs**, et ne considère une entrée comme validée que lorsqu'une **majorité** de membres l'a notée sur disque. Alors seulement, il l'applique à la base et répond au client. Le leader est élu pour une période appelée **terme**, numérotée ; chaque élection ouvre un nouveau terme.

minikube n'a qu'un membre, et en démarrer un second profil à trois nœuds de contrôle coûterait plusieurs gigaoctets. Mais etcd lui-même est léger. Le script `trio.sh` de l'archive démarre trois membres dans trois conteneurs Docker, avec la même image que minikube :

```bash
./trio.sh demarrer
EP=cours-etcd-1:2379,cours-etcd-2:2379,cours-etcd-3:2379
docker exec cours-etcd-1 etcdctl --endpoints=$EP endpoint status -w simple | awk -F', ' '{print $1, "| base", $5, "dont", $6, "utiles | leader", $9, "| terme", $11, "| index", $12}'
docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' cours-etcd-1 cours-etcd-2 cours-etcd-3
```

```sortie
cours-etcd-1, cours-etcd-2 et cours-etcd-3 démarrés
cours-etcd-1:2379 | base 20 kB dont 16 kB utiles | leader false | terme 2 | index 8
cours-etcd-2:2379 | base 20 kB dont 16 kB utiles | leader true | terme 2 | index 8
cours-etcd-3:2379 | base 20 kB dont 16 kB utiles | leader false | terme 2 | index 8
cours-etcd-1 13MiB / 15.05GiB
cours-etcd-2 14.32MiB / 15.05GiB
cours-etcd-3 12.84MiB / 15.05GiB
```

Trois membres de 13 à 14 Mio chacun. Une élection a déjà eu lieu au démarrage : `cours-etcd-2` est leader pour le terme 2. Les trois ont le même index, 8 : leurs journaux sont identiques. La figure 35.2 montre le chemin d'une écriture.

<Figure svg={etcdRaft} num="35.2" alt="Une écriture dans un cluster etcd de trois membres. 1, l'API server, client d'etcd, envoie l'écriture au leader e1, dont le journal se termine par les entrées 9 et 10, au terme 3. 2, le leader envoie l'entrée 10 aux deux suiveurs, e2 et e3. 3, les suiveurs répondent qu'ils l'ont notée. 4, dès que 2 membres sur 3 l'ont notée, l'entrée est validée, puis appliquée. 5, le leader répond au client. En dessous, la règle de la majorité : 1 membre, quorum 1, aucune panne tolérée ; 2 membres, quorum 2, aucune panne tolérée ; 3 membres, quorum 2, une panne tolérée ; 4 membres, quorum 3, une panne tolérée ; 5 membres, quorum 3, deux pannes tolérées. Un nombre pair n'apporte rien : 4 membres tolèrent une panne, comme 3, et la majorité est plus dure à réunir.">
Une écriture dans un etcd de trois membres. Le leader ne répond qu'une fois l'entrée notée par une majorité, lui compris. En bas, le nombre de pannes qu'un cluster de n membres supporte.
</Figure>

Un client peut s'adresser à n'importe quel membre : un suiveur transmet les écritures au leader. Écrivons sur l'un, lisons sur un autre :

```bash
docker exec cours-etcd-2 etcdctl --endpoints=cours-etcd-2:2379 put /colis/1 enregistré
docker exec cours-etcd-3 etcdctl --endpoints=cours-etcd-3:2379 get /colis/1
```

```sortie
OK
/colis/1
enregistré
```

### Le leader tombe

Tuons le leader, brutalement, comme le ferait une panne de machine (`docker kill` envoie `SIGKILL`, que le processus ne peut pas intercepter), et lisons les journaux des deux survivants :

```bash
T=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ); docker kill cours-etcd-2; echo "tué à ${T:11:12}"
sleep 4
for m in cours-etcd-1 cours-etcd-3; do
  echo "# journal de $m"
  docker logs --since $T $m 2>&1 | jq -r 'select(.msg|test("lost leader|became|elected|starting a new election")) | "\(.ts[11:23]) \(.msg)"'
done
```

```sortie
cours-etcd-2
tué à 17:38:55.332
# journal de cours-etcd-1
17:38:56.442 ab0df443fc598c13 became follower at term 3
17:38:56.442 raft.node: ab0df443fc598c13 lost leader b9f99e601bd82451 at term 3
17:38:56.444 raft.node: ab0df443fc598c13 elected leader 8a94011ccb9add5d at term 3
# journal de cours-etcd-3
17:38:56.429 8a94011ccb9add5d is starting a new election at term 2
17:38:56.429 raft.node: 8a94011ccb9add5d lost leader b9f99e601bd82451 at term 2
17:38:56.430 8a94011ccb9add5d became candidate at term 3
17:38:56.444 8a94011ccb9add5d became leader at term 3
17:38:56.444 raft.node: 8a94011ccb9add5d elected leader 8a94011ccb9add5d at term 3
```

Les journaux d'etcd sont en JSON ; `jq` n'en garde que l'heure et le message, pour les lignes qui parlent d'élection. Pendant 1,1 seconde, rien : les suiveurs attendent. Un leader envoie à ses suiveurs un signe de vie toutes les 100 millisecondes ; un suiveur qui n'en reçoit plus pendant un **délai d'élection** (une seconde par défaut dans etcd, avec une part de hasard[^reglages]) conclut que le leader est mort. `cours-etcd-3` a été le premier à atteindre ce délai : il passe au terme 3, se déclare candidat, et demande leur voix aux autres. `cours-etcd-1` la lui accorde, ce qui fait deux voix sur trois, une majorité : 15 millisecondes plus tard, `cours-etcd-3` est leader. Le hasard dans le délai sert précisément à cela : que les suiveurs ne se déclarent pas candidats tous en même temps, ce qui partagerait les voix.

```bash
docker exec cours-etcd-1 etcdctl --endpoints=cours-etcd-1:2379,cours-etcd-3:2379 endpoint status -w simple | cut -d, -f1,9,11,12
docker exec cours-etcd-1 etcdctl --endpoints=cours-etcd-1:2379 put /colis/2 estimé
```

```sortie
cours-etcd-1:2379, false, 3, 10
cours-etcd-3:2379, true, 3, 10
OK
```

Deux membres sur trois suffisent : les écritures continuent. Pour un cluster Kubernetes, la panne d'une machine du plan de contrôle se traduit donc par une seconde et quelque d'écritures en suspens, que les clients réessaient sans même s'en apercevoir.

### Plus de majorité

Tuons maintenant le nouveau leader. Il ne reste qu'un membre sur trois :

```bash
T=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ); docker kill cours-etcd-3
t=$(date +%s); docker exec cours-etcd-1 etcdctl --endpoints=cours-etcd-1:2379 --command-timeout=5s put /colis/3 livré
echo "code $? après $(( $(date +%s)-t )) s"
docker exec cours-etcd-1 etcdctl --endpoints=cours-etcd-1:2379 --command-timeout=5s get /colis --prefix; echo "code $?"
docker exec cours-etcd-1 etcdctl --endpoints=cours-etcd-1:2379 get /colis --prefix --consistency=s; echo "code $?"
```

```sortie
cours-etcd-3
Error: context deadline exceeded
code 1 après 5 s
Error: context deadline exceeded
code 1
/colis/1
enregistré
/colis/2
estimé
code 0
```

L'écriture échoue au bout des cinq secondes accordées : le survivant ne peut plus réunir de majorité, il ne peut donc rien valider. Plus surprenant, la **lecture** échoue aussi. Par défaut, une lecture dans etcd est *linéarisable* : elle garantit de renvoyer la dernière écriture validée par le cluster, ce qui oblige le membre à vérifier auprès d'une majorité qu'il n'a rien manqué. Seule la lecture *sérialisable* (`--consistency=s`) répond, avec ce que le membre a localement, sans garantie que ce soit à jour[^garanties]. Un API server privé de majorité ne peut donc plus rien faire d'utile : le cluster est gelé, mais les Pods déjà lancés continuent de tourner sur les nœuds, puisque le kubelet ne les arrête pas pour autant.

Le journal du survivant montre qu'il n'abandonne pas :

```bash
docker logs --since $T cours-etcd-1 2>&1 | jq -r 'select(.msg|test("election|lost leader|became")) | "\(.ts[11:23]) \(.msg)"' | head -6
```

```sortie
17:39:00.066 peer became inactive (message send to peer failed)
17:39:01.347 ab0df443fc598c13 is starting a new election at term 3
17:39:01.347 ab0df443fc598c13 became pre-candidate at term 3
17:39:01.347 raft.node: ab0df443fc598c13 lost leader 8a94011ccb9add5d at term 3
17:39:02.748 ab0df443fc598c13 is starting a new election at term 3
17:39:02.748 ab0df443fc598c13 became pre-candidate at term 3
```

Il tente une élection toutes les secondes et demie environ, mais en **pré-candidat**, et le terme ne bouge pas. C'est le *pre-vote*, une extension de Raft décrite dans la thèse d'Ongaro[^prevote] : avant de lancer une vraie élection, qui augmenterait le terme, un membre demande aux autres s'ils voteraient pour lui. Sans réponse, il ne change rien. Sans cette précaution, un membre isolé ferait monter son terme à chaque tentative, et à son retour, son terme élevé forcerait le vrai leader à abdiquer pour rien.

Faisons revenir les deux absents :

```bash
docker start cours-etcd-2 cours-etcd-3
docker exec cours-etcd-1 etcdctl --endpoints=$EP endpoint status -w simple | cut -d, -f1,9,11,12
docker exec cours-etcd-1 etcdctl --endpoints=$EP put /colis/3 livré
docker exec cours-etcd-1 etcdctl --endpoints=$EP get /colis --prefix
```

```sortie
cours-etcd-1:2379, true, 4, 14
cours-etcd-2:2379, false, 4, 14
cours-etcd-3:2379, false, 4, 14
OK
/colis/1
enregistré
/colis/2
estimé
/colis/3
livré
```

Terme 4, un nouveau leader, les trois journaux au même index, et aucune donnée perdue : `cours-etcd-2`, absent depuis la première panne, a reçu du leader les entrées qu'il avait manquées.

### Un arrêt propre

Dernière expérience : arrêtons le leader, `cours-etcd-1`, proprement, avec `docker stop`, qui envoie `SIGTERM` et laisse au processus le temps de finir. On lit ensuite le journal du partant, puis celui des deux autres :

```bash
T=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ); docker stop cours-etcd-1 >/dev/null; echo "arrêt propre (SIGTERM) à ${T:11:12}"
sleep 2
docker logs --since $T cours-etcd-1 2>&1 | jq -r 'select(.msg|test("transfer")) | "\(.ts[11:23]) \(.msg)"'
for m in cours-etcd-2 cours-etcd-3; do
  docker logs --since $T $m 2>&1 | jq -r 'select(.msg|test("MsgTimeoutNow|became leader")) | "\(.ts[11:23]) \(.msg)"'
done
docker start cours-etcd-1
```

```sortie
arrêt propre (SIGTERM) à 17:39:15.687
17:39:15.733 leadership transfer starting
17:39:15.733 ab0df443fc598c13 [term 4] starts to transfer leadership to b9f99e601bd82451
17:39:15.834 leadership transfer finished
17:39:15.734 b9f99e601bd82451 [term 4] received MsgTimeoutNow from ab0df443fc598c13 and starts an election to get leadership.
17:39:15.738 b9f99e601bd82451 became leader at term 5
```

Pas d'attente cette fois. Le leader sait qu'il s'en va : il **transfère** son rôle à un suiveur à jour, en lui envoyant un message `MsgTimeoutNow` (« n'attends pas ton délai, présente-toi maintenant »), et un nouveau leader est en place 51 millisecondes après le signal. C'est ce qui se passe lors d'une maintenance ordinaire d'un nœud du plan de contrôle : les écritures ne sont pratiquement pas interrompues.

### Combien de membres ?

La règle de la majorité, rappelée en bas de la figure 35.2, fixe le nombre de pannes qu'un cluster supporte : avec n membres, il en faut n/2 + 1 (arrondi en dessous) pour valider quoi que ce soit. Trois membres en tolèrent une, cinq en tolèrent deux. Un nombre pair n'apporte rien : quatre membres tolèrent une seule panne, comme trois, mais la majorité à réunir pour chaque écriture est plus grande, et deux fois deux membres séparés par une coupure réseau ne peuvent ni l'un ni l'autre continuer[^faq]. Aller au-delà de cinq ralentit les écritures sans gain réel. D'où les deux configurations qu'on rencontre partout pour un cluster Kubernetes de production : trois nœuds de contrôle portant chacun un membre d'etcd, ou un etcd séparé de trois ou cinq machines[^ha]. minikube, avec son membre unique, ne tolère aucune panne, ce qui est parfaitement acceptable pour un poste de TP.

## Exercices

:::exercice[Exercice 1 : ce que coûte un scale]

La vitrine a une réplique. Combien d'écritures etcd une seule commande `kubectl scale deploy vitrine --replicas=2` provoque-t-elle dans le namespace `ch35`, et sur quelles clés ? Faites une prédiction, puis observez avec `E watch /registry/ --prefix -w json`, en ne gardant que les clés qui contiennent `/ch35/`. Le manifeste de la vitrine est celui du chapitre 34.

:::

<details>
<summary>Corrigé</summary>

```sortie
98243 PUT    /registry/deployments/ch35/vitrine
98244 PUT    /registry/replicasets/ch35/vitrine-cc58b69f4
98245 PUT    /registry/events/ch35/vitrine...
98246 PUT    /registry/deployments/ch35/vitrine
98247 PUT    /registry/pods/ch35/vitrine-cc58b69f4-xxxxx
98248 PUT    /registry/deployments/ch35/vitrine
98249 PUT    /registry/events/ch35/vitrine-cc58b69f4...
98250 PUT    /registry/replicasets/ch35/vitrine-cc58b69f4
98251 PUT    /registry/pods/ch35/vitrine-cc58b69f4-xxxxx
98252 PUT    /registry/events/ch35/vitrine-cc58b69f4-xxxxx...
98253 PUT    /registry/replicasets/ch35/vitrine-cc58b69f4
98254 PUT    /registry/deployments/ch35/vitrine
98255 PUT    /registry/pods/ch35/vitrine-cc58b69f4-xxxxx
98260 PUT    /registry/events/ch35/vitrine-cc58b69f4-xxxxx...
98261 PUT    /registry/pods/ch35/vitrine-cc58b69f4-xxxxx
98262 PUT    /registry/events/ch35/vitrine-cc58b69f4-xxxxx...
98263 PUT    /registry/events/ch35/vitrine-cc58b69f4-xxxxx...
98264 PUT    /registry/pods/ch35/vitrine-cc58b69f4-xxxxx
98265 PUT    /registry/replicasets/ch35/vitrine-cc58b69f4
98267 PUT    /registry/deployments/ch35/vitrine
```

(J'ai masqué le suffixe aléatoire du Pod et des événements.) Vingt écritures, pour une commande qui n'en a fait qu'une, la première. Toutes les autres viennent de composants qui ont réagi en chaîne, chacun à l'écriture du précédent : le contrôleur des Deployments augmente le nombre voulu du ReplicaSet (98244) et note un événement ; le contrôleur des ReplicaSets crée le Pod (98247) ; le scheduler lui attribue un nœud (98251, le `Binding` modifie le Pod) ; le kubelet met à jour son statut à chaque étape (98255, 98261, 98264) et chaque étape produit un événement (`Scheduled`, `Pulled`, `Created`, `Started`) ; enfin chaque contrôleur met à jour le statut de son objet (98253, 98265, 98267). Les révisions manquantes (98256 à 98259, 98266) ont servi à d'autres clés, hors de `ch35`. C'est tout le sujet du chapitre 36 : aucune de ces écritures n'a été ordonnée ; chacune est la réponse d'un contrôleur à un changement qu'il a vu passer.

</details>

:::exercice[Exercice 2 : le mot de passe de Colis]

Le chart Helm du chapitre 29 génère le mot de passe de PostgreSQL et le range dans le Secret `colis-db`. Retrouvez-le directement dans etcd, sans `kubectl get secret`. Qui, sur un cluster réel, peut faire la même chose ?

:::

<details>
<summary>Corrigé</summary>

```bash
E get /registry/secrets/colis/colis-db --print-value-only | strings | grep -A1 POSTGRES_PASSWORD | tail -1 | cut -c1-6; echo '(tronqué)'
```

```sortie
riURxK
(tronqué)
```

La clé suit la règle habituelle, et la valeur contient le mot de passe en clair, juste après le nom de la clé du Secret (je l'ai tronqué). Peuvent faire de même : quiconque détient un certificat client accepté par etcd (ceux des nœuds de contrôle, celui de l'API server) ; quiconque a un accès administrateur à une machine qui héberge etcd, puisque le fichier de la base est sur son disque ; et quiconque met la main sur une **sauvegarde** d'etcd, ce qui est souvent le plus facile. Le chiffrement des Secrets au repos (chapitre 46) protège contre les deux derniers cas ; RBAC ne protège contre aucun, puisqu'il n'intervient que dans l'API server.

</details>

:::exercice[Exercice 3 : un suiveur en retard]

Sur le trio, arrêtez un **suiveur** (pas le leader) avec `docker kill`, écrivez cinq clés `/rattrapage/1` à `/rattrapage/5`, puis redémarrez-le. Les écritures ont-elles réussi pendant son absence ? Comparez l'index des membres avant et après son retour, et vérifiez qu'il a bien les cinq clés, en l'interrogeant seul et en lecture sérialisable.

:::

<details>
<summary>Corrigé</summary>

```sortie
suiveur arrêté : cours-etcd-1
cours-etcd-2:2379, true, 5, 22
cours-etcd-3:2379, false, 5, 22
cours-etcd-1:2379, false, 5, 23
cours-etcd-2:2379, true, 5, 23
cours-etcd-3:2379, false, 5, 23
5
```

Les cinq écritures réussissent : le leader et le suiveur restant forment une majorité. La perte d'un suiveur ne provoque même pas d'élection, le terme reste à 5. Après le redémarrage, les trois membres ont le même index (l'entrée supplémentaire, 23, est une écriture interne à etcd, faite au retour du membre), et le membre revenu, interrogé seul avec `--consistency=s`, possède les cinq clés : le leader lui a renvoyé les entrées de journal qui lui manquaient. S'il avait été absent très longtemps, au point que le leader ait compacté son journal, il aurait reçu à la place une copie complète de la base (un *snapshot*), avant de reprendre le fil.

</details>

:::exercice[Exercice 4 : deux compteurs concurrents]

Le programme `compteur.py` de l'archive incrémente N fois un compteur rangé dans le ConfigMap `compteur`, en passant par `kubectl proxy`. À chaque tour, il lit le ConfigMap, ajoute 1, et le réécrit par un `PUT` qui porte la `resourceVersion` lue ; sur un `409`, il relit et recommence. Lancez-en deux en même temps, de 20 incréments chacun, à partir de zéro. Quelle valeur finale attendez-vous ? Recommencez avec l'option `sans-version`, qui retire la `resourceVersion` avant d'écrire. Expliquez les deux résultats.

```bash
kubectl create configmap compteur --from-literal=valeur=0
kubectl proxy --port=8011 &
python3 compteur.py A 20 & python3 compteur.py B 20 & wait %2 %3
kubectl get cm compteur -o jsonpath='valeur finale : {.data.valeur}{"\n"}'
```

:::

<details>
<summary>Corrigé</summary>

Avec la `resourceVersion` :

```sortie
A : 20 incréments, 5 conflits
B : 20 incréments, 20 conflits
valeur finale : 40
```

Sans :

```sortie
B : 20 incréments, 0 conflits
A : 20 incréments, 0 conflits
valeur finale : 20
```

Dans le premier cas, chaque fois que les deux programmes lisent la même valeur, le second à écrire reçoit un `409` (la transaction d'etcd échoue), relit et recommence : il y a eu 25 conflits, mais aucun incrément perdu, et le compteur arrive bien à 40. Dans le second cas, l'API server n'a plus de révision à comparer, et accepte chaque `PUT` en remplaçant l'objet : quand A et B lisent tous deux 7, ils écrivent tous deux 8, et l'un des deux incréments disparaît. Aucune erreur, aucun conflit signalé, et pourtant la moitié du travail est perdue. C'est le problème classique de la « mise à jour perdue ». Les contrôleurs de Kubernetes écrivent tous avec la `resourceVersion` qu'ils ont lue, et réessaient sur un conflit ; un script maison qui fait `GET` puis `PUT` sans elle, ou qui la retire « pour que ça passe », réintroduit ce problème.

</details>

## Nettoyer

```bash
kubectl delete namespace ch35
kubectl config set-context --current --namespace=default
./trio.sh supprimer
```

La clé d'essai `/cours/compteur` a déjà été supprimée dans la section sur les transactions. Si vous avez glissé d'autres clés hors de `/registry` dans l'etcd de minikube, supprimez-les de la même façon, par leur nom, avec `E del`.

[^garanties]: etcd, « KV API guarantees », pour la cohérence forte et la différence entre lectures linéarisables et sérialisables ; « Data model », pour les révisions et le stockage multiversion. [etcd.io/docs/v3.6/learning/api_guarantees](https://etcd.io/docs/v3.6/learning/api_guarantees/), [etcd.io/docs/v3.6/learning/data_model](https://etcd.io/docs/v3.6/learning/data_model/)

[^chiffrement]: Kubernetes, « Encrypting Confidential Data at Rest ». [kubernetes.io/docs/tasks/administer-cluster/encrypt-data](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)

[^maintenance]: etcd, « Maintenance » : historique et compactage, défragmentation, quota d'espace et alarme `NOSPACE`. [etcd.io/docs/v3.6/op-guide/maintenance](https://etcd.io/docs/v3.6/op-guide/maintenance/)

[^cache]: Kubernetes Enhancement Proposal 2340, « Consistent Reads from Cache », qui décrit le cache de watch de l'API server et le service des lectures depuis ce cache. [github.com/kubernetes/enhancements/tree/master/keps/sig-api-machinery/2340-Consistent-reads-from-cache](https://github.com/kubernetes/enhancements/tree/master/keps/sig-api-machinery/2340-Consistent-reads-from-cache)

[^materiel]: etcd, « Hardware recommendations », section *Disks*, et « Tuning », section *Disk*. [etcd.io/docs/v3.6/op-guide/hardware](https://etcd.io/docs/v3.6/op-guide/hardware/)

[^raft]: Diego Ongaro et John Ousterhout, « In Search of an Understandable Consensus Algorithm », *USENIX Annual Technical Conference*, 2014. [raft.github.io/raft.pdf](https://raft.github.io/raft.pdf)

[^reglages]: etcd, « Tuning », section *Time parameters* : intervalle de signe de vie de 100 ms et délai d'élection de 1000 ms par défaut. [etcd.io/docs/v3.6/tuning](https://etcd.io/docs/v3.6/tuning/)

[^prevote]: Diego Ongaro, *Consensus: Bridging Theory and Practice*, thèse de doctorat, Université Stanford, 2014, section 9.6 (*Preventing disruptions when a server rejoins the cluster*). [github.com/ongardie/dissertation](https://github.com/ongardie/dissertation)

[^faq]: etcd, « Frequently Asked Questions », *Why an odd number of cluster members?* et *What is maximum cluster size?*. [etcd.io/docs/v3.6/faq](https://etcd.io/docs/v3.6/faq/)

[^ha]: Kubernetes, « Options for Highly Available Topology » : etcd empilé sur les nœuds de contrôle, ou etcd externe. [kubernetes.io/docs/setup/production-environment/tools/kubeadm/ha-topology](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/ha-topology/)
