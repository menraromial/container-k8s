---
title: Les StatefulSets
sidebar_label: 26. Les StatefulSets
description: "Faire tourner des applications qui ont un état : pourquoi un Deployment ne convient pas à une base de données, l'identité stable des Pods d'un StatefulSet, le Service headless, un volume par réplique, l'ordre de démarrage et de mise à jour, puis PostgreSQL de Colis migré en StatefulSet et Colis 2.1 qui survit au redémarrage de sa base."
partie: 4
chapitre: '26'
---

import anatomieStatefulset from '@site/src/figures/anatomie-statefulset.svg';
import migrationPostgres from '@site/src/figures/migration-postgres.svg';

À la fin du chapitre 25, PostgreSQL de Colis tournait dans un Deployment, avec ses données sur un volume persistant. Il y avait une réplique, et tout allait bien. Que se passerait-il avec deux ? Pour une API, deux répliques identiques et interchangeables, c'est exactement ce qu'on veut. Pour une base de données, essayons, dans un namespace à part pour ne pas abîmer Colis :

```bash
kubectl create namespace ch26
kubectl config set-context --current --namespace=ch26
```

Les manifestes sont dans [l'archive statefulset](pathname:///kits/statefulset.tar.gz). `deux-postgres.yaml` est un Deployment de PostgreSQL à deux répliques, qui montent la même demande de volume, comme le ferait le Deployment de Colis si on changeait son `replicas` :

```bash
kubectl apply -f deux-postgres.yaml
kubectl get pods -l app=base
```

```sortie
NAME                    READY   STATUS    RESTARTS      AGE
base-544bf59587-9ds8t   1/1     Running   1 (45s ago)   46s
base-544bf59587-xt2md   1/1     Running   0             46s
```

Les deux Pods tournent. Le volume est en `ReadWriteOnce`, mais les deux Pods sont sur le même nœud, et RWO ne limite qu'à un nœud (chapitre 25). Les journaux racontent la suite :

```bash
kubectl logs base-544bf59587-9ds8t --previous | grep -m1 'initdb: error'
kubectl logs base-544bf59587-9ds8t | tail -1
kubectl logs base-544bf59587-xt2md | tail -1
```

```sortie
initdb: error: directory "/var/lib/postgresql/18/docker" exists but is not empty
2026-09-26 12:18:28.699 UTC [1] LOG:  database system is ready to accept connections
2026-09-26 12:18:29.982 UTC [1] LOG:  database system is ready to accept connections
```

Les deux conteneurs ont voulu initialiser une base neuve en même temps ; l'un a perdu, a redémarré, a trouvé une base existante et l'a ouverte. Deux serveurs PostgreSQL travaillent maintenant sur les mêmes fichiers, chacun avec ses propres tampons en mémoire. Créons une table avec l'un et lisons-la avec l'autre :

```bash
kubectl exec base-544bf59587-9ds8t -- psql -U postgres -c 'CREATE TABLE t (x int); INSERT INTO t VALUES (1), (2);'
kubectl exec base-544bf59587-xt2md -- psql -U postgres -c 'SELECT count(*) FROM t;'
```

```sortie
CREATE TABLE
INSERT 0 2
ERROR:  relation "t" does not exist
LINE 1: SELECT count(*) FROM t;
                             ^
command terminated with exit code 1
```

Le second serveur ne voit pas la table du premier. Chacun écrit son journal de transactions et ses pages de données sans savoir que l'autre existe : au premier point de contrôle, ils s'écraseront mutuellement, et la base sera corrompue. PostgreSQL a pourtant une protection contre cela, le fichier de verrou `postmaster.pid`, qui contient le PID du serveur qui tient les fichiers :

```bash
kubectl exec base-544bf59587-9ds8t -- head -1 /var/lib/postgresql/18/docker/postmaster.pid
```

```sortie
1
```

Le PID 1. Quand le second serveur a trouvé ce verrou, il a regardé si le PID 1 était vivant, et c'était le cas : c'était lui-même, dans son propre espace de noms de PID (chapitre 8). PostgreSQL considère qu'un verrou qui porte son propre PID est un reste d'un arrêt brutal précédent, et le reprend[^verrou]. La protection, pensée pour une machine, ne voit pas qu'il y a deux machines, ou plutôt deux conteneurs. Supprimez l'expérience :

```bash
kubectl delete -f deux-postgres.yaml
```

Le problème n'est pas propre à PostgreSQL. Une base de données, un courtier de messages, un nœud d'un système réparti ont besoin de choses qu'un Deployment ne donne pas : **chaque réplique a ses propres données**, et elle doit les retrouver quand elle redémarre ; **chaque réplique a un nom stable**, parce que les autres s'y adressent (« le primaire, c'est `postgres-0` ») ; et **l'ordre compte**, pour démarrer le primaire avant ses réplicas ou retirer un nœud d'un groupe proprement. C'est ce que fournit le StatefulSet[^sts].

## Un StatefulSet en trois répliques

Le StatefulSet `pile` ressemble à un Deployment, avec deux différences dans sa spécification : le champ `serviceName`, qui nomme un Service *headless*, et une liste `volumeClaimTemplates`, des modèles de demandes de volume. Chaque réplique sert en HTTP le contenu d'un fichier de son volume, où elle note chacun de ses démarrages :

```yaml title="pile.yaml"
apiVersion: v1
kind: Service
metadata:
  name: pile
spec:
  clusterIP: None          # headless : un nom DNS par Pod, pas d'adresse virtuelle
  selector:
    app: pile
  ports:
  - name: http
    port: 8080
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: pile
spec:
  serviceName: pile
  replicas: 3
  selector:
    matchLabels:
      app: pile
  template:
    metadata:
      labels:
        app: pile
    spec:
      terminationGracePeriodSeconds: 2   # busybox en PID 1 ignore SIGTERM (chapitre 22)
      containers:
      - name: serveur
        image: busybox:1.37
        command: ["sh", "-c"]
        args:
        - |
          echo "$(date -u +%T) démarrage de $(hostname)" >> /donnees/historique.txt
          sleep 3                                  # un démarrage qui prend un peu de temps
          mkdir -p /www && cp /donnees/historique.txt /www/index.html
          exec httpd -f -p 8080 -h /www
        ports:
        - name: http
          containerPort: 8080
        readinessProbe:
          tcpSocket:
            port: http
          periodSeconds: 2
        volumeMounts:
        - name: donnees
          mountPath: /donnees
  volumeClaimTemplates:
  - metadata:
      name: donnees
    spec:
      accessModes:
      - ReadWriteOnce
      resources:
        requests:
          storage: 10Mi
```

```bash
kubectl apply -f pile.yaml
kubectl rollout status statefulset/pile
kubectl get pods -l app=pile -o custom-columns='NOM:.metadata.name,CRÉÉ:.metadata.creationTimestamp,PRÊT:.status.conditions[?(@.type=="Ready")].lastTransitionTime'
kubectl get pvc
```

```sortie
NOM      CRÉÉ                   PRÊT
pile-0   2026-09-26T12:19:14Z   2026-09-26T12:19:19Z
pile-1   2026-09-26T12:19:19Z   2026-09-26T12:19:24Z
pile-2   2026-09-26T12:19:24Z   2026-09-26T12:19:29Z
NAME             STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
donnees-pile-0   Bound    pvc-167c4e0a-b791-44c8-ba52-fb8ccaf5cfe8   10Mi       RWO            standard       <unset>                 15s
donnees-pile-1   Bound    pvc-f46d21ae-e474-44ca-a8c3-7ac6739da96b   10Mi       RWO            standard       <unset>                 10s
donnees-pile-2   Bound    pvc-17929b4a-02f5-4ab7-9433-ae5f6be3d541   10Mi       RWO            standard       <unset>                 5s
```

Trois différences avec un Deployment sautent aux yeux. Les Pods ne portent pas de suffixe aléatoire, mais un numéro d'ordre : `pile-0`, `pile-1`, `pile-2`. Ils n'ont pas été créés ensemble : `pile-1` a été créé à l'instant où `pile-0` est devenu prêt, `pile-2` quand `pile-1` l'a été, si bien que le démarrage a pris 16 secondes au lieu de 5. Et chaque Pod a reçu sa propre demande de volume, nommée d'après le modèle et le Pod : `donnees-pile-0`, `donnees-pile-1`, `donnees-pile-2`. Les événements du StatefulSet montrent l'ordre des opérations, demande puis Pod, réplique après réplique :

```bash
kubectl get events --field-selector involvedObject.kind=StatefulSet --sort-by=.metadata.resourceVersion \
  -o custom-columns=RAISON:.reason,MESSAGE:.message
```

```sortie
RAISON             MESSAGE
SuccessfulCreate   Create Claim donnees-pile-0 Pod pile-0 in StatefulSet pile success
SuccessfulCreate   Create Pod pile-0 in StatefulSet pile successful
SuccessfulCreate   Create Claim donnees-pile-1 Pod pile-1 in StatefulSet pile success
SuccessfulCreate   Create Pod pile-1 in StatefulSet pile successful
SuccessfulCreate   Create Claim donnees-pile-2 Pod pile-2 in StatefulSet pile success
SuccessfulCreate   Create Pod pile-2 in StatefulSet pile successful
```

C'est le comportement par défaut, `podManagementPolicy: OrderedReady` : le Pod de rang *n* n'est créé que lorsque tous ceux de rang inférieur tournent et sont prêts. La sonde readiness compte donc ici plus encore qu'ailleurs, puisqu'elle décide quand passer au suivant.

## Une identité réseau stable

Le Service `pile` n'a pas d'adresse IP (`clusterIP: None`). Un tel Service, dit *headless*, ne passe pas par kube-proxy : son nom DNS résout directement vers les adresses des Pods prêts, et, pour un StatefulSet, chaque Pod reçoit en plus son propre nom, de la forme `<pod>.<service>.<namespace>.svc.cluster.local`[^dns]. Depuis un Pod client :

```bash
kubectl run client --image=busybox:1.37 --restart=Never -- sleep 3600
kubectl get service pile
kubectl exec client -- nslookup pile.ch26.svc.cluster.local. | grep -A1 '^Name'
kubectl exec client -- nslookup pile-1.pile.ch26.svc.cluster.local. | grep -A1 '^Name'
kubectl exec client -- wget -qO- http://pile-1.pile:8080/
```

```sortie
NAME   TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)    AGE
pile   ClusterIP   None         <none>        8080/TCP   18s
Name:	pile.ch26.svc.cluster.local
Address: 10.244.0.29
Name:	pile.ch26.svc.cluster.local
Address: 10.244.0.30
Name:	pile.ch26.svc.cluster.local
Address: 10.244.0.28
Name:	pile-1.pile.ch26.svc.cluster.local
Address: 10.244.0.29
12:19:20 démarrage de pile-1
```

Le nom du Service donne les trois adresses, et c'est au client de choisir ; le nom `pile-1.pile` désigne un Pod précis. Le chemin de recherche DNS du Pod (chapitre 20) permet de l'abréger en `pile-1.pile` depuis le même namespace. C'est ce nom que les autres membres d'un groupe utilisent : la configuration d'un cluster etcd, Kafka ou ZooKeeper liste ses membres par ces noms.

Que devient cette identité quand le Pod disparaît ? Supprimons `pile-1` :

```bash
kubectl get pod pile-1 -o jsonpath='{.metadata.uid} {.status.podIP}{"\n"}'
kubectl delete pod pile-1
kubectl wait --for=condition=Ready pod/pile-1
kubectl get pod pile-1 -o jsonpath='{.metadata.uid} {.status.podIP} {.spec.volumes[0].persistentVolumeClaim.claimName}{"\n"}'
kubectl exec client -- wget -qO- http://pile-1.pile:8080/
kubectl exec client -- nslookup pile-1.pile.ch26.svc.cluster.local. | grep -A1 '^Name'
```

```sortie
3ad184ea-6cf0-46ae-a337-252ee3939faf 10.244.0.29
pod "pile-1" deleted from ch26 namespace
pod/pile-1 condition met
5cb0acc3-fa5d-433d-af79-209b8d28576d 10.244.0.32 donnees-pile-1
12:19:20 démarrage de pile-1
12:19:35 démarrage de pile-1
Name:	pile-1.pile.ch26.svc.cluster.local
Address: 10.244.0.32
```

Le nouveau Pod est un autre objet (son `uid` a changé) et il a une autre adresse IP. Mais il porte le même nom, il a remonté la même demande `donnees-pile-1`, où il a trouvé l'historique de son prédécesseur, et le nom DNS `pile-1.pile` pointe maintenant vers sa nouvelle adresse. Pour les autres, rien n'a changé : `pile-1` est revenu. C'est cela, l'identité stable : le nom, le volume et l'entrée DNS survivent au Pod, pas l'adresse IP. Un client qui garde une adresse IP en cache au lieu de résoudre le nom à chaque connexion se retrouvera à parler dans le vide.

<Figure svg={anatomieStatefulset} num="26.1" alt="Le StatefulSet pile (replicas 3, serviceName pile, modèle de volume donnees de 10Mi) crée trois Pods, pile-0, pile-1 et pile-2 ; chaque Pod est créé quand le précédent est prêt, et les mises à jour vont en sens inverse, de pile-2 à pile-0. Chaque Pod monte sa propre PVC, donnees-pile-0, donnees-pile-1, donnees-pile-2, liée à son PV. Le Service pile, headless (clusterIP None), fait servir par CoreDNS le nom pile.ch26.svc.cluster.local, qui donne les trois adresses, et un nom par Pod : pile-0.pile.ch26.svc.cluster.local donne l'adresse de pile-0, pile-1.pile... celle de pile-1, même après son remplacement, et ainsi de suite. Chaque volume suit son Pod ; réduire le nombre de répliques supprime pile-2 mais garde sa PVC, par défaut.">
Ce qu'un StatefulSet garantit à chaque réplique : un nom, un volume et une entrée DNS qui lui survivent, et un ordre de création et de mise à jour.
</Figure>

## Changer le nombre de répliques

Réduisons à une réplique, puis revenons à trois :

```bash
kubectl scale statefulset pile --replicas=1
kubectl get events --field-selector involvedObject.kind=StatefulSet,reason=SuccessfulDelete \
  --sort-by=.metadata.resourceVersion -o custom-columns=MESSAGE:.message
kubectl get pods -l app=pile
kubectl get pvc
```

```sortie
MESSAGE
Delete Pod pile-2 in StatefulSet pile successful
Delete Pod pile-1 in StatefulSet pile successful
NAME     READY   STATUS    RESTARTS   AGE
pile-0   1/1     Running   0          40s
NAME             STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
donnees-pile-0   Bound    pvc-167c4e0a-b791-44c8-ba52-fb8ccaf5cfe8   10Mi       RWO            standard       <unset>                 40s
donnees-pile-1   Bound    pvc-f46d21ae-e474-44ca-a8c3-7ac6739da96b   10Mi       RWO            standard       <unset>                 35s
donnees-pile-2   Bound    pvc-17929b4a-02f5-4ab7-9433-ae5f6be3d541   10Mi       RWO            standard       <unset>                 30s
```

Les Pods partent dans l'ordre inverse de leur création, le plus grand numéro d'abord, et un seul à la fois. Les demandes de volume, elles, restent toutes. C'est un choix de prudence : réduire le nombre de répliques d'une base est une opération courante, perdre ses données en même temps ne doit pas l'être. En revenant à trois répliques, `pile-2` retrouve son volume :

```bash
kubectl scale statefulset pile --replicas=3
kubectl exec client -- wget -qO- http://pile-2.pile:8080/
```

```sortie
12:19:25 démarrage de pile-2
12:20:00 démarrage de pile-2
```

Ce comportement se règle par la politique de conservation des demandes, `persistentVolumeClaimRetentionPolicy`, stable depuis Kubernetes 1.32[^retention]. Elle a deux champs, `whenScaled` (quand on réduit le nombre de répliques) et `whenDeleted` (quand on supprime le StatefulSet), qui valent chacun `Retain`, la valeur par défaut, ou `Delete`. Pour un StatefulSet dont les répliques sont des caches qu'on peut reconstruire, supprimer les volumes des répliques retirées évite d'accumuler des disques oubliés :

```bash
kubectl patch statefulset pile -p '{"spec":{"persistentVolumeClaimRetentionPolicy":{"whenScaled":"Delete","whenDeleted":"Retain"}}}'
kubectl scale statefulset pile --replicas=2
kubectl get pvc
```

```sortie
NAME             STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
donnees-pile-0   Bound    pvc-167c4e0a-b791-44c8-ba52-fb8ccaf5cfe8   10Mi       RWO            standard       <unset>                 61s
donnees-pile-1   Bound    pvc-f46d21ae-e474-44ca-a8c3-7ac6739da96b   10Mi       RWO            standard       <unset>                 56s
```

La demande de `pile-2` a disparu avec lui, et avec elle son volume, dont la classe a la politique `Delete`. Revenu à trois répliques, `pile-2` repart d'un volume neuf :

```bash
kubectl scale statefulset pile --replicas=3
kubectl exec client -- wget -qO- http://pile-2.pile:8080/
```

```sortie
12:20:16 démarrage de pile-2
```

## Mettre à jour dans l'ordre

La stratégie de mise à jour par défaut d'un StatefulSet est `RollingUpdate`, comme pour un Deployment, mais elle ne fonctionne pas pareil :

```bash
kubectl get statefulset pile -o jsonpath='{.spec.updateStrategy}{" "}{.spec.podManagementPolicy}{"\n"}'
kubectl set env statefulset/pile VERSION=2
kubectl rollout status statefulset/pile
kubectl get events --field-selector involvedObject.kind=StatefulSet --sort-by=.metadata.resourceVersion \
  -o custom-columns=MESSAGE:.message | tail -6
```

```sortie
{"rollingUpdate":{"maxUnavailable":1,"partition":0},"type":"RollingUpdate"} OrderedReady
Delete Pod pile-2 in StatefulSet pile successful
Create Pod pile-2 in StatefulSet pile successful
Delete Pod pile-1 in StatefulSet pile successful
Create Pod pile-1 in StatefulSet pile successful
Delete Pod pile-0 in StatefulSet pile successful
Create Pod pile-0 in StatefulSet pile successful
```

Il n'y a pas de Pod en surnombre : un Pod de StatefulSet ne peut pas coexister avec son remplaçant, puisqu'ils auraient le même nom et le même volume. Le contrôleur **supprime** le Pod, attend qu'il soit parti, **recrée** le Pod de même nom avec le nouveau modèle, attend qu'il soit prêt, puis passe au suivant, du plus grand numéro au plus petit. Pendant chaque remplacement, cette réplique-là est indisponible ; pour une base à un seul serveur, la mise à jour est donc toujours une coupure, courte mais réelle.

L'ordre inverse n'est pas un hasard. Dans beaucoup de systèmes répliqués, la réplique 0 joue un rôle particulier (le primaire, le premier membre du groupe) : on la met à jour en dernier, quand les autres ont prouvé que la nouvelle version fonctionne. Le champ `partition` pousse l'idée plus loin : seuls les Pods dont le numéro est supérieur ou égal à la partition sont mis à jour. C'est un déploiement canari tout prêt :

```bash
kubectl patch statefulset pile -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":2}}}}'
kubectl set env statefulset/pile VERSION=3
kubectl get pods -l app=pile -o custom-columns='NOM:.metadata.name,VERSION:.spec.containers[0].env[0].value,RÉVISION:.metadata.labels.controller-revision-hash'
kubectl get statefulset pile -o jsonpath='{.status.currentRevision} {.status.updateRevision} {.status.updatedReplicas}{"\n"}'
```

```sortie
NOM      VERSION   RÉVISION
pile-0   2         pile-6877d5fccf
pile-1   2         pile-6877d5fccf
pile-2   3         pile-658944775d
pile-6877d5fccf pile-658944775d 1
```

Seul `pile-2` est passé à la version 3. Le StatefulSet garde les deux révisions, l'actuelle et la cible, et attend. Si la version 3 se comporte bien, on baisse la partition à 0 et la mise à jour se termine ; sinon, on revient en arrière sans avoir touché aux deux autres répliques :

```bash
kubectl patch statefulset pile -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":0}}}}'
kubectl rollout status statefulset/pile
kubectl get pods -l app=pile -o custom-columns='NOM:.metadata.name,VERSION:.spec.containers[0].env[0].value'
```

```sortie
partitioned roll out complete: 3 new pods have been updated...
NOM      VERSION
pile-0   3
pile-1   3
pile-2   3
```

L'autre stratégie, `OnDelete`, ne remplace aucun Pod d'elle-même : le nouveau modèle ne s'applique qu'aux Pods qu'on supprime à la main. Elle laisse à un opérateur humain, ou à un programme, le choix du moment et de l'ordre, ce que font souvent les opérateurs de bases de données (partie VIII). Le champ `maxUnavailable`, visible plus haut, permet de remplacer plusieurs Pods à la fois quand l'application le supporte[^sts].

:::panne[Une mise à jour ratée bloque le StatefulSet, même après un retour arrière]

Une image qui n'existe pas :

```bash
kubectl set image statefulset/pile serveur=busybox:9.99
kubectl get pods -l app=pile
```

```sortie
NAME     READY   STATUS             RESTARTS   AGE
pile-0   1/1     Running            0          30s
pile-1   1/1     Running            0          39s
pile-2   0/1     ImagePullBackOff   0          22s
```

`pile-2` ne démarre pas, et comme il n'est pas prêt, le contrôleur ne touche pas aux deux autres : l'ordre protège le reste. On revient en arrière, et on attend :

```bash
kubectl rollout undo statefulset/pile
sleep 45; kubectl get pods -l app=pile
kubectl get pod pile-2 -o jsonpath='{.spec.containers[0].image}{"\n"}'
```

```sortie
statefulset.apps/pile rolled back
NAME     READY   STATUS             RESTARTS   AGE
pile-0   1/1     Running            0          75s
pile-1   1/1     Running            0          84s
pile-2   0/1     ImagePullBackOff   0          67s
busybox:9.99
```

Le modèle est revenu à `busybox:1.37`, mais `pile-2` est toujours le Pod cassé, avec l'image fautive. Le contrôleur attend qu'il soit prêt avant de le remplacer, ce qui n'arrivera jamais. La documentation le décrit comme un piège connu de `OrderedReady`[^sts] : il faut supprimer à la main le Pod bloqué, et le contrôleur le recrée avec le bon modèle.

```bash
kubectl delete pod pile-2
kubectl get pod pile-2 -o jsonpath='{.spec.containers[0].image}{"\n"}'
```

```sortie
busybox:1.37
```

:::

:::panne[On ne change pas le modèle de volume d'un StatefulSet]

Les `volumeClaimTemplates` sont figés à la création :

```sortie
The StatefulSet "pile" is invalid: spec.volumeClaimTemplates: Invalid value: [...]: field is immutable
```

Pour agrandir les volumes, on agrandit chaque demande existante, si la classe le permet (chapitre 25). Pour changer autre chose (la classe, le mode d'accès), on supprime le StatefulSet sans supprimer ses Pods, `kubectl delete statefulset pile --cascade=orphan`, on le recrée avec le nouveau modèle, qui s'appliquera aux nouvelles répliques, et on migre les anciennes une par une.

:::

## PostgreSQL de Colis en StatefulSet

Colis peut maintenant quitter son Deployment. Le nouveau `colis/20-postgres.yaml` du kit contient un Service headless et un StatefulSet d'une réplique, avec un modèle de volume `donnees` de 1 Gio dans la classe `standard`. Une seule réplique : faire tourner deux serveurs PostgreSQL, un primaire et un réplica qui le suit, demande de configurer la réplication, de choisir qui bascule et quand, de rediriger les clients ; c'est le travail d'un opérateur comme CloudNativePG, que la partie VIII installera. Le StatefulSet apporte déjà l'essentiel pour une réplique : un nom stable, `postgres-0`, et un volume qui lui est attaché pour de bon.

La difficulté est de garder les données. Le StatefulSet cherchera une demande nommée `donnees-postgres-0`, et la créera, vide, si elle n'existe pas. Les colis sont dans le volume de la demande `postgres-donnees`. Il faut donc faire passer ce volume d'une demande à l'autre, avec ce que le chapitre 25 a montré : la politique `Retain` et le `claimRef`. La figure 26.2 résume les cinq étapes.

<Figure svg={migrationPostgres} num="26.2" alt="Avant, au chapitre 25 : le Deployment postgres et son Service ClusterIP, la PVC postgres-donnees, liée au PV pvc-... de la classe standard, dont le dossier /tmp/hostpath-provisioner/colis/postgres-donnees contient les données. Après, au chapitre 26 : le StatefulSet postgres et son Service headless, dont le Pod postgres-0 attend la PVC donnees-postgres-0, créée avec volumeName égal au même PV. Étapes : 1, passer le PV en Retain, pour qu'il survive à sa demande ; 2, supprimer le Deployment, le Service et la PVC, le PV devient Released ; 3, effacer le claimRef du PV, il redevient Available ; 4, créer la PVC donnees-postgres-0, qui nomme ce PV ; 5, appliquer le StatefulSet, dont le Pod trouve une PVC au nom attendu et l'utilise.">
Changer de propriétaire sans perdre les données : le volume reste, seules la demande et la charge de travail changent.
</Figure>

L'état de départ, avec le colis enregistré au chapitre précédent :

```bash
kubectl -n colis get pvc
kubectl get pv $(kubectl -n colis get pvc postgres-donnees -o jsonpath='{.spec.volumeName}')
curl -s http://192.168.49.100/api/colis | jq -c '[.[] | {id, destinataire}]'
```

```sortie
NAME               STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
postgres-donnees   Bound    pvc-72307363-a964-4130-b2cf-c1bf9ce85db5   1Gi        RWO            standard       <unset>                 4m30s
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                    STORAGECLASS   VOLUMEATTRIBUTESCLASS   REASON   AGE
pvc-72307363-a964-4130-b2cf-c1bf9ce85db5   1Gi        RWO            Delete           Bound    colis/postgres-donnees   standard       <unset>                          4m30s
[{"id":1,"destinataire":"Katherine Johnson"}]
```

Le PV a la politique `Delete` de sa classe : supprimer la demande l'effacerait. L'étape 1 le protège ; l'étape 2 retire l'ancien PostgreSQL, son Service et sa demande :

```bash
V=$(kubectl -n colis get pvc postgres-donnees -o jsonpath='{.spec.volumeName}')
kubectl patch pv $V -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
kubectl -n colis delete deployment postgres
kubectl -n colis delete service postgres
kubectl -n colis delete pvc postgres-donnees
kubectl get pv $V
```

```sortie
persistentvolume/pvc-72307363-a964-4130-b2cf-c1bf9ce85db5 patched
deployment.apps "postgres" deleted from colis namespace
service "postgres" deleted from colis namespace
persistentvolumeclaim "postgres-donnees" deleted from colis namespace
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS     CLAIM                    STORAGECLASS   VOLUMEATTRIBUTESCLASS   REASON   AGE
pvc-72307363-a964-4130-b2cf-c1bf9ce85db5   1Gi        RWO            Retain           Released   colis/postgres-donnees   standard       <unset>                          4m31s
```

Colis est maintenant en panne : l'API n'a plus de base. Les étapes 3 et 4 libèrent le volume et le donnent à une demande qui porte le nom que le StatefulSet attend, en le désignant par `volumeName` :

```bash
kubectl patch pv $V --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: donnees-postgres-0
  namespace: colis
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
  storageClassName: standard
  volumeName: $V
EOF
kubectl -n colis get pvc
```

```sortie
persistentvolumeclaim/donnees-postgres-0 created
NAME                 STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
donnees-postgres-0   Bound    pvc-72307363-a964-4130-b2cf-c1bf9ce85db5   1Gi        RWO            standard       <unset>                 3s
```

Enfin, l'étape 5 applique le StatefulSet, qui trouve la demande et la prend :

```bash
kubectl apply -f colis/20-postgres.yaml
kubectl -n colis rollout status statefulset/postgres
kubectl -n colis exec postgres-0 -- psql -U colis -d colis -tc 'SELECT id, destinataire FROM colis;'
```

```sortie
service/postgres created
statefulset.apps/postgres created
partitioned roll out complete: 1 new pods have been updated...
  1 | Katherine Johnson
```

Le colis de Katherine Johnson est là. La coupure a duré le temps des commandes, quelques dizaines de secondes. Le PV garde la politique `Retain` : c'est un bon réglage pour les données d'une base, qu'il vaut mieux supprimer délibérément.

:::panne[Appliquer le fichier en entier, trop tôt]

Deux pièges attendent qui applique `colis/20-postgres.yaml` avant d'avoir fait les étapes 2 à 4. Le premier est inoffensif : un Service ne change pas de type d'adresse, et l'ancien Service `postgres`, qui a une adresse ClusterIP, refuse de devenir headless.

```sortie
The Service "postgres" is invalid: spec.clusterIPs[0]: Invalid value: ["None"]: may not change once set
```

Le second est grave. `kubectl apply` traite les documents du fichier un par un : l'échec du Service n'empêche pas la création du StatefulSet, qui crée aussitôt une demande `donnees-postgres-0` vide, liée à un volume neuf. Quand on veut ensuite lui donner l'ancien volume, la demande refuse de changer de volume :

```sortie
The PersistentVolumeClaim "donnees-postgres-0" is invalid: spec: Forbidden: spec is immutable after creation except resources.requests and volumeAttributesClassName for bound claims
```

Si cela vous arrive, les données ne sont pas perdues, tant que l'ancien PV est en `Retain` : supprimez le StatefulSet et la demande vide, puis reprenez à l'étape 4. Retenez la leçon générale : un fichier de plusieurs objets n'est pas une transaction, et une erreur au milieu laisse les objets qui précèdent et qui suivent appliqués.

:::

### Le Service headless et les clients

L'API se connecte toujours à `postgres`. Avec un Service headless, ce nom ne désigne plus une adresse virtuelle stable, mais directement l'adresse du Pod :

```bash
kubectl -n colis exec deploy/api -- python -c 'import socket; print(socket.gethostbyname_ex("postgres")); print(socket.gethostbyname_ex("postgres-0.postgres"))'
kubectl -n colis get pod postgres-0 -o jsonpath='{.status.podIP}{"\n"}'
```

```sortie
('postgres.colis.svc.cluster.local', ['postgres.colis.svc.cluster.local', 'postgres'], ['10.244.0.44'])
('postgres-0.postgres.colis.svc.cluster.local', ['postgres-0.postgres.colis.svc.cluster.local', 'postgres-0.postgres'], ['10.244.0.44'])
10.244.0.44
```

La conséquence est importante pour l'application. Avec un Service ClusterIP, l'adresse que l'API connaît ne changeait jamais ; avec un Service headless, elle change à chaque fois que `postgres-0` est recréé. Un client qui résout le nom une seule fois, au démarrage, et garde l'adresse, ne retrouvera jamais la base. C'était le défaut de Colis depuis le chapitre 24, sous une autre forme : l'API ouvrait une connexion au démarrage et ne savait pas en ouvrir une autre.

## Colis 2.1 : une API qui se reconnecte

Colis 2.1 corrige ce défaut. Le [code de la version 2.1](pathname:///kits/colis-2.1.tar.gz) ne change que la classe `StockagePostgres`, dans `colis/stockage.py`. Avant chaque requête, elle vérifie que sa connexion est ouverte, et en ouvre une nouvelle sinon, en résolvant de nouveau le nom `postgres`. Quand une requête échoue parce que la connexion est coupée, elle abandonne la connexion. Et elle ne rejoue la requête que si c'est sans danger :

```python title="colis/stockage.py (extrait)"
    def _executer(self, sql: str, params: tuple = (), rejouable: bool = False):
        """Exécute une requête (le verrou doit être pris). Rejoue une fois si rejouable."""
        try:
            return self._connecter().execute(sql, params)
        except self._psycopg.OperationalError:
            # connexion perdue : on l'abandonne, la prochaine requête en ouvrira une autre
            self._connexion = None
            if not rejouable:
                raise
            return self._connecter().execute(sql, params)
```

Les lectures, la vérification de `/pret` et l'estimation d'une date, qui écrit toujours la même valeur, sont rejouables : les exécuter deux fois donne le même résultat. La création d'un colis ne l'est pas. Si la connexion tombe pendant un `INSERT`, on ne sait pas si la ligne a été écrite avant la coupure : la rejouer pourrait créer le colis deux fois. Mieux vaut renvoyer une erreur au client, qui décidera. Trois nouveaux tests, dans `tests/test_stockage.py`, vérifient ce comportement avec une fausse connexion, sans serveur PostgreSQL. L'image se construit avec le `Dockerfile` du défi II, qui exécute les tests pendant la construction, puis se publie dans le registre :

```bash
docker build -t colis:2.1 app
docker tag colis:2.1 localhost:5001/colis/api:2.1
docker push localhost:5001/colis/api:2.1
```

```sortie
#16 2.196 13 passed in 0.69s
```

Le kit contient les manifestes de l'API, du worker et de la purge qui utilisent `host.minikube.internal:5001/colis/api:2.1`, et la ConfigMap avec `COLIS_VERSION: "2.1.0"` :

```bash
kubectl apply -f colis/10-config.yaml -f colis/30-api.yaml -f colis/31-worker.yaml
kubectl -n colis rollout status deployment/api
curl -s http://192.168.49.100/api/sante; echo
curl -s http://192.168.49.100/api/colis | jq -c '[.[] | {id, destinataire}]'
```

```sortie
configmap/colis-config configured
deployment.apps/api configured
service/api unchanged
deployment.apps/worker configured
{"statut":"ok","version":"2.1.0","hote":"api-85cbf95c69-99p9p"}
[{"id":1,"destinataire":"Katherine Johnson"}]
```

Rejouons maintenant la panne du chapitre 24 : on supprime le Pod de PostgreSQL pendant que des requêtes arrivent, environ quatre par seconde, pendant 75 secondes.

```bash
IP=192.168.49.100
( fin=$(( $(date +%s) + 75 ))
  while [ $(date +%s) -lt $fin ]; do
    echo "$(date +%s.%N | cut -c1-14) $(curl -s -o /dev/null -m 2 -w '%{http_code}' http://$IP/api/colis)"
    sleep 0.2
  done ) > charge.txt &
sleep 5; t0=$(date +%s.%N | cut -c1-14)
kubectl -n colis delete pod postgres-0
wait
awk '{n[$2]++} END {for (c in n) print c, n[c]}' charge.txt | sort
awk -v t0=$t0 '$2!=200 {if (!d) d=$1; f=$1} END {printf "premier échec %.1f s après la suppression, dernier %.1f s après\n", d-t0, f-t0}' charge.txt
kubectl -n colis get pods -l 'app.kubernetes.io/name in (api,worker,postgres)'
```

```sortie
000 2
200 288
premier échec 2.2 s après la suppression, dernier 4.5 s après
NAME                     READY   STATUS    RESTARTS   AGE
api-85cbf95c69-4m7ns     1/1     Running   0          83s
api-85cbf95c69-99p9p     1/1     Running   0          88s
postgres-0               1/1     Running   0          70s
worker-594df4b89-9hpq4   1/1     Running   0          88s
```

Deux requêtes sur 290 ont échoué (le code `000` signifie que `curl` a abandonné au bout de 2 secondes, sans réponse), pendant les quelques secondes où `postgres-0` n'existait plus. Ensuite, tout est revenu, sans que personne n'intervienne : les Pods de l'API sont les mêmes qu'avant, sans aucun redémarrage, et ils ont rouvert leur connexion vers la nouvelle adresse de `postgres-0`. Avec la version 2.0, Colis restait en panne jusqu'à ce qu'on redémarre l'API à la main. Les deux échecs restants sont le prix d'une base à une seule réplique ; pour les faire disparaître, il faudrait un réplica prêt à prendre le relais, et c'est de nouveau le travail d'un opérateur.

Pour finir, la purge en version 2.1 :

```bash
kubectl -n colis delete pod purge
kubectl apply -f colis/50-purge.yaml
kubectl -n colis logs purge
```

```sortie
purge : 0 colis livrés depuis plus de 30 jours supprimés
```

## Exercices

:::exercice[Exercice 1 : démarrer en parallèle]

Recopiez `pile.yaml` sous le nom `pile-par`, avec `podManagementPolicy: Parallel`. Combien de temps faut-il pour que les trois Pods soient prêts ? Dans quels cas ce réglage convient-il, et dans quels cas est-il dangereux ?

:::

<details>
<summary>Corrigé</summary>

Il suffit d'ajouter la ligne sous `replicas`, et de renommer le StatefulSet, son Service, son `serviceName` et ses étiquettes :

```yaml
spec:
  serviceName: pile-par
  replicas: 3
  podManagementPolicy: Parallel
```

```sortie
prêt en 6 s
NOM          CRÉÉ                   PRÊT
pile-par-0   2026-09-26T12:24:47Z   2026-09-26T12:24:52Z
pile-par-1   2026-09-26T12:24:47Z   2026-09-26T12:24:53Z
pile-par-2   2026-09-26T12:24:47Z   2026-09-26T12:24:53Z
```

Les trois Pods sont créés à la même seconde et prêts en 6 secondes, au lieu de 16. `Parallel` garde le nom, le volume et l'entrée DNS de chaque réplique, mais renonce à l'ordre, pour la création comme pour la suppression. Il convient quand les répliques sont indépendantes les unes des autres, ou quand l'application organise elle-même son démarrage (des membres qui se découvrent par DNS et forment leur groupe à leur rythme, comme Cassandra ou un cluster Elasticsearch) : on gagne du temps, surtout avec des dizaines de répliques. Il est dangereux quand une réplique suppose que les précédentes existent, par exemple un réplica de base de données qui se connecte au primaire `-0` dès son démarrage. Notez que `podManagementPolicy` ne concerne pas les mises à jour, qui restent ordonnées. Supprimez ensuite `pile-par` et ses demandes.

</details>

:::exercice[Exercice 2 : une file Redis qui survit]

La file Redis de Colis tourne dans un Deployment, sans volume : si son Pod redémarre, les colis en attente d'estimation sont perdus. Écrivez un StatefulSet Redis d'une réplique, avec un volume de 100 Mio monté sur `/data` et la persistance de Redis activée (option `--appendonly yes`). Vérifiez qu'une liste survit à la suppression du Pod.

:::

<details>
<summary>Corrigé</summary>

Le kit contient `redis.yaml`, avec un Service headless `redis` et ce StatefulSet :

```yaml title="redis.yaml (extrait)"
      containers:
      - name: redis
        image: redis:8.8-alpine
        args: ["--appendonly", "yes"]
        volumeMounts:
        - name: donnees
          mountPath: /data
  volumeClaimTemplates:
  - metadata:
      name: donnees
    spec:
      accessModes: [ReadWriteOnce]
      resources:
        requests:
          storage: 100Mi
```

```bash
kubectl apply -f redis.yaml
kubectl exec redis-0 -- redis-cli RPUSH colis:a-estimer 41 42 43
kubectl delete pod redis-0
kubectl exec redis-0 -- redis-cli LRANGE colis:a-estimer 0 -1
kubectl exec redis-0 -- ls /data /data/appendonlydir
```

```sortie
3
pod "redis-0" deleted from ch26 namespace
41
42
43
/data:
appendonlydir
dump.rdb

/data/appendonlydir:
appendonly.aof.1.base.rdb
appendonly.aof.1.incr.aof
appendonly.aof.manifest
```

Les trois éléments sont revenus. Le volume seul ne suffit pas : sans `--appendonly yes`, Redis garde tout en mémoire et n'écrit sur le disque qu'un instantané de temps en temps (`dump.rdb`), si bien qu'un arrêt perd ce qui a été écrit depuis. Avec l'AOF (*append-only file*), chaque écriture est ajoutée au fichier `appendonly.aof.1.incr.aof`, et Redis le relit au démarrage[^redis]. Par défaut, le fichier est synchronisé sur le disque une fois par seconde : un arrêt brutal peut encore perdre la dernière seconde.

</details>

:::exercice[Exercice 3 : changer de version de PostgreSQL]

PostgreSQL 19 est sorti. Un collègue propose de remplacer `postgres:18-alpine` par `postgres:19-alpine` dans le StatefulSet de Colis et d'appliquer. Que va-t-il se passer ? Comment procéder à la place ?

:::

<details>
<summary>Corrigé</summary>

Le StatefulSet va supprimer `postgres-0` et le recréer avec l'image 19. L'image officielle range les données dans un dossier qui dépend de la version majeure, sa variable `PGDATA` :

```bash
kubectl -n colis exec postgres-0 -- sh -c 'env | grep -E "PGDATA|PG_MAJOR"'
```

```sortie
PG_MAJOR=18
PGDATA=/var/lib/postgresql/18/docker
```

Avec l'image 19, `PGDATA` vaudra `/var/lib/postgresql/19/docker`, un dossier vide du même volume. Le nouveau serveur y créera une base neuve, démarrera sans erreur, et Colis affichera une liste vide : les colis n'auront pas disparu, ils seront restés dans le dossier `18/docker`, mais plus personne ne les lira. C'est pire qu'un refus de démarrer, parce que rien ne signale le problème. Et si l'on forçait `PGDATA` vers l'ancien dossier, le serveur 19 refuserait de démarrer, car le format des fichiers de données change d'une version majeure à l'autre.

Une montée de version majeure demande une migration des données. La plus simple, pour une petite base comme celle de Colis : un `pg_dump` de l'ancienne base, un nouveau StatefulSet (ou une nouvelle demande de volume) en version 19, puis un `pg_restore`, et le basculement des clients. L'autre voie est `pg_upgrade`, qui convertit les fichiers sur place mais a besoin des binaires des deux versions dans le même conteneur. Dans tous les cas, on prend d'abord une sauvegarde, et on prévoit une coupure. Les opérateurs de bases de données (partie VIII) automatisent ce genre d'opération, souvent en créant une nouvelle instance à côté de l'ancienne.

</details>

## Nettoyer

```bash
kubectl delete namespace ch26
kubectl config set-context --current --namespace=default
```

Supprimer le namespace supprime les StatefulSets, les Pods et les demandes de volume, dont les volumes de la classe `standard` partent avec elles. Gardez Colis tel quel : PostgreSQL en StatefulSet, API et worker en 2.1. Le PV de sa base est en `Retain` ; le jour où vous supprimerez Colis, pensez à supprimer ce PV et son dossier, `/tmp/hostpath-provisioner/colis/postgres-donnees`, sur le nœud.

[^verrou]: PostgreSQL, code source de `CreateLockFile` (`src/backend/utils/init/miscinit.c`), dont le commentaire explique qu'un verrou portant le PID du processus lui-même, ou de son parent, est considéré comme un reste d'un démarrage précédent. [github.com/postgres/postgres/blob/master/src/backend/utils/init/miscinit.c](https://github.com/postgres/postgres/blob/master/src/backend/utils/init/miscinit.c)

[^sts]: Kubernetes, « StatefulSets », sections *Pod Identity*, *Deployment and Scaling Guarantees*, *Update strategies*, *Partitioned rolling updates*, *Maximum unavailable Pods* et *Forced rollback*. [kubernetes.io/docs/concepts/workloads/controllers/statefulset](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/)

[^dns]: Kubernetes, « DNS for Services and Pods », et « Service », section *Headless Services*. [kubernetes.io/docs/concepts/services-networking/dns-pod-service](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)

[^retention]: Kubernetes Enhancement Proposal 1847, « Auto remove PVCs created by StatefulSet ». [github.com/kubernetes/enhancements/tree/master/keps/sig-apps/1847-autoremove-statefulset-pvcs](https://github.com/kubernetes/enhancements/tree/master/keps/sig-apps/1847-autoremove-statefulset-pvcs)

[^redis]: Redis, « Redis persistence », sections *AOF advantages* et *How durable is the append only file?*. [redis.io/docs/latest/operate/oss_and_stack/management/persistence](https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/)
