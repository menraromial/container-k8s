---
title: Sauvegarder et restaurer
sidebar_label: 52. Sauvegarder et restaurer
description: "Deux niveaux de sauvegarde, testés jusqu'à la restauration : l'instantané d'etcd et sa clé de chiffrement, restauré sur le cluster ; Velero avec un stockage S3, ses pièges réels (volumes hostPath ignorés, image de restauration refusée par la politique d'admission, volume Retain qui ne se relie pas, HPA géré par KEDA), et Colis supprimé puis restauré avec ses données."
partie: 7
chapitre: '52'
---

import sauvegardeCouches from '@site/src/figures/sauvegarde-couches.svg';
import veleroRestauration from '@site/src/figures/velero-restauration.svg';

```sortie
┌──────────┬──────────┬────────────┬────────────┬─────────┐
│   HASH   │ REVISION │ TOTAL KEYS │ TOTAL SIZE │ VERSION │
├──────────┼──────────┼────────────┼────────────┼─────────┤
│ ad15f013 │   514409 │       2088 │      33 MB │   3.7.0 │
└──────────┴──────────┴────────────┴────────────┴─────────┘
```

Trente-trois mégaoctets, deux mille clés : c'est l'état complet du cluster du cours, tous namespaces confondus, tel qu'etcd le stocke. Ce fichier a été produit en moins de deux secondes, et il suffit pour reconstruire l'API à l'identique, Deployments, Secrets, rôles et tout le reste. Il ne contient pourtant pas une seule ligne de la base de Colis. Une sauvegarde de Kubernetes se fait donc à plusieurs niveaux, et ce chapitre les traite dans l'ordre, chacun jusqu'au bout, c'est-à-dire jusqu'à la restauration. Une sauvegarde qu'on n'a jamais restaurée est une hypothèse, pas une sauvegarde : le chapitre va le montrer plusieurs fois.

Les fichiers sont dans [l'archive sauvegarde](pathname:///kits/sauvegarde.tar.gz).

## Ce qu'il faut sauvegarder

Deux chiffres guident toute stratégie. Le **RPO** (*recovery point objective*) est la quantité de données qu'on accepte de perdre, exprimée en temps : avec une sauvegarde par nuit, on perd au pire une journée. Le **RTO** (*recovery time objective*) est le temps qu'on s'accorde pour revenir en service. Les deux se négocient avec ceux qui utilisent le service, et se vérifient par des exercices de restauration chronométrés[^nist].

<Figure svg={sauvegardeCouches} num="52.1" alt="Un tableau de cinq lignes. Tout le cluster, l'état complet de l'API : instantané d'etcd avec etcdctl snapshot save, copié dans un fichier hors du nœud ; ne couvre pas les volumes et devient inutilisable sans la clé de chiffrement. Un namespace, ses objets, d'un cluster à l'autre : Velero, sauvegarde d'objets, vers un stockage objet S3 (ici RustFS) ; les Secrets y sont lisibles, il faut protéger le stockage. Les données des volumes : Velero, par copie des fichiers avec kopia ou par instantané CSI, vers le même stockage chiffré par kopia ; ne couvre pas les volumes hostPath ni la cohérence d'une base en marche. Une base de données cohérente : export logique avec pg_dump par un crochet, dans un volume que Velero copie ; ne couvre pas ce qui a changé depuis l'export. Les clés de chiffrement et de signature : copie à part, dans un coffre, ailleurs que les sauvegardes ; rien ne les régénère. En bas : les manifestes vivent dans Git et les images dans le registre, qui ont leur propre sauvegarde.">
Ce qu'on peut perdre, l'outil qui le sauvegarde, où va la copie, et ce que l'outil ne couvre pas. Aucune ligne ne suffit seule.
</Figure>

## L'instantané d'etcd

Le chapitre 35 a montré qu'etcd contient tous les objets de l'API. L'outil `etcdctl` sait en produire un instantané cohérent, sans arrêter etcd. Le script `sauvegarder-etcd.sh` le lance dans le Pod d'etcd (avec les certificats du nœud, comme la fonction `E` du chapitre 35), rapatrie le fichier sur le poste, et copie à côté la configuration de chiffrement du chapitre 46. Il vérifie enfin le fichier avec `etcdutl`, l'outil hors ligne d'etcd, qu'on installe sur le poste à la même version que le serveur (3.7.0)[^etcd] :

```bash
kubectl create ns ch52
kubectl -n ch52 create configmap inventaire --from-literal=entrepots=Lyon,Brest,Lille
kubectl -n ch52 create secret generic acces --from-literal=jeton=jeton-tres-secret-52
kubectl -n ch52 create deployment tampon --image=busybox:1.37 -- sleep 3600
bash sauvegarder-etcd.sh sauvegardes
```

```sortie
Snapshot saved at /var/lib/minikube/etcd/etcd-20261008-094517.db
Server version 3.7.0
┌──────────┬──────────┬────────────┬────────────┬─────────┐
│   HASH   │ REVISION │ TOTAL KEYS │ TOTAL SIZE │ VERSION │
├──────────┼──────────┼────────────┼────────────┼─────────┤
│ ad15f013 │   514409 │       2088 │      33 MB │   3.7.0 │
└──────────┴──────────┴────────────┴────────────┴─────────┘
sauvegardes/etcd-20261008-094517.db
```

L'instantané est un fichier ordinaire. Que contient-il de nos deux objets ?

```bash
grep -a -c 'jeton-tres-secret-52' sauvegardes/etcd-*.db
grep -a -o 'k8s:enc:secretbox:v1:[a-z0-9]*' sauvegardes/etcd-*.db | sort | uniq -c
grep -a -c 'Lyon,Brest,Lille' sauvegardes/etcd-*.db
```

```sortie
jeton en clair : 0
valeurs chiffrées (secretbox) :  39 k8s:enc:secretbox:v1:cle2
configmap inventaire : 1
```

Le jeton n'apparaît pas : les valeurs des Secrets (39 dans le fichier, anciennes révisions comprises) sont stockées chiffrées par la clé `cle2` du chapitre 46. La ConfigMap, elle, est en clair, comme toutes les ConfigMaps. Deux conséquences. L'instantané reste une donnée sensible, puisque tout ce qui n'est pas un Secret y est lisible. Et il est **inutilisable sans la clé** : restauré sur un API server qui ne la connaît pas, il donnerait des Secrets illisibles (le chapitre 46 a montré ce que devient un API server dont la clé manque). Le script range la clé dans un fichier séparé, mais c'est seulement pour l'exercice : en vrai, la clé va dans un coffre, sur un autre support que les sauvegardes. Le jour où l'on perd les deux ensemble, on ne perd pas seulement la clé, on perd aussi les sauvegardes.

### Restaurer etcd

Le scénario : après la sauvegarde, on crée un objet, puis quelqu'un supprime le namespace `ch52`.

```bash
kubectl -n default create configmap apres --from-literal=cree=apres-la-sauvegarde
kubectl delete ns ch52
```

Restaurer un instantané, c'est remplacer le répertoire de données d'etcd par un répertoire reconstruit à partir du fichier, plan de contrôle arrêté. Sur un nœud kubeadm comme celui de minikube, etcd, l'API server, le contrôleur et l'ordonnanceur sont des **Pods statiques** (chapitre 38) : on les arrête en retirant leur manifeste du dossier que surveille le kubelet. `restaurer-etcd.sh` enchaîne les étapes, et remet l'état précédent si l'une échoue :

```sortie
1. Reconstruire un répertoire de données à partir de l'instantané (sur le poste)
2. Arrêter le plan de contrôle : le kubelet arrête un Pod statique dont le manifeste disparaît
   etcd et l'API server sont arrêtés
3. Échanger les répertoires de données (l'ancien est gardé)
4. Redémarrer le plan de contrôle, puis le kubelet
   API server prêt après 6 s
Ancien répertoire de données gardé sur le nœud : /var/lib/minikube/etcd-avant-20261008-094601
```

`etcdutl snapshot restore` reconstruit un répertoire de données avec l'identité du membre (`--name`, `--initial-cluster`, les adresses du nœud), qui doivent correspondre exactement aux options du manifeste d'etcd. Moins de quarante secondes de bout en bout, dont six d'indisponibilité de l'API. Vérifions :

```bash
kubectl -n ch52 get cm,secret,deploy,pods
kubectl -n ch52 get secret acces -o jsonpath='{.data.jeton}' | base64 -d; echo
kubectl -n default get cm apres
```

```sortie
NAME                         DATA   AGE
configmap/inventaire         1      85s
configmap/kube-root-ca.crt   1      85s

NAME           TYPE     DATA   AGE
secret/acces   Opaque   1      85s

NAME                     READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/tampon   1/1     1            1           85s

NAME                          READY   STATUS    RESTARTS   AGE
pod/tampon-779d84945c-frl4q   1/1     Running   0          85s
jeton-tres-secret-52
Error from server (NotFound): configmaps "apres" not found
```

Le namespace est revenu, avec les mêmes noms et les mêmes identifiants : le Pod `tampon` a retrouvé son nom d'avant, et le kubelet a relancé son conteneur, supprimé entre-temps. Le Secret se déchiffre, puisque l'API server a toujours la clé. Et la ConfigMap `apres` a **disparu** : elle n'existait pas au moment de l'instantané. C'est le prix d'une restauration d'etcd : tout le cluster recule dans le temps, pas seulement l'objet qu'on voulait récupérer. Pour retrouver un namespace supprimé, c'est une arme bien trop lourde ; elle sert quand le plan de contrôle lui-même est perdu.

:::panne[Restaurer etcd sur un cluster de plusieurs nœuds]

Avec trois membres etcd, la restauration se fait sur **tous** les membres, à partir du **même** instantané, chacun avec son nom et ses adresses, après avoir arrêté **tous** les API servers. Restaurer un seul membre et le laisser rejoindre les autres ne marche pas : ils ont un historique qu'il n'a pas. La documentation de Kubernetes recommande aussi de redémarrer ensuite les contrôleurs, l'ordonnanceur et les kubelets, pour qu'ils ne gardent pas en mémoire un état plus récent que celui d'etcd[^etcd]. Sur un cluster managé, etcd appartient au fournisseur : on ne le sauvegarde pas soi-même.

:::

## Velero

Pour sauvegarder un namespace plutôt que tout le cluster, et pour emporter les données des volumes, l'outil de référence est **Velero**, un projet de la CNCF[^velero]. Il lit les objets par l'API, les range dans une archive sur un **stockage objet** compatible S3, et copie le contenu des volumes. Au restore, il recrée les objets dans le bon ordre et réécrit les volumes. Hors d'un poste de cours, le stockage serait un compartiment S3, GCS ou Azure, dans une autre région que le cluster. Ici, on utilise **RustFS**, un serveur S3 en un seul binaire, installé dans le cluster pour l'exercice. Un stockage de sauvegarde dans le même cluster que ce qu'on sauvegarde ne protège bien sûr de rien.

```bash
kubectl create ns velero
kubectl apply -f rustfs.yaml
bash creer-compartiment.sh       # crée le compartiment « velero » par l'API S3
helm install velero vmware-tanzu/velero --version 12.2.1 -n velero -f valeurs-velero.yaml --wait
kubectl -n velero port-forward svc/rustfs 9010:9000 &
velero backup-location get
```

```yaml title="valeurs-velero.yaml (extrait)"
# Velero, avec le greffon S3 (AWS et compatibles) et l'agent de nœud qui copie le contenu des volumes.
initContainers:
- name: velero-plugin-for-aws
  image: velero/velero-plugin-for-aws:v1.14.4
  volumeMounts:
  - mountPath: /target
    name: plugins
configuration:
  backupStorageLocation:
  - name: default
    provider: aws
    bucket: velero
    default: true
    config:
      region: us-east-1               # sans importance pour RustFS, mais exigé
      s3ForcePathStyle: "true"        # http://serveur/compartiment, et non http://compartiment.serveur
      s3Url: http://rustfs.velero.svc:9000
      # l'adresse que verra le client velero sur le poste (redirection de port) : il télécharge
      # journaux et détails directement dans le stockage, par des URL signées
      publicUrl: http://localhost:9010
  volumeSnapshotLocation: []
  # les volumes de minikube-hostpath ne savent pas faire d'instantanés : on copie les fichiers
  defaultVolumesToFsBackup: true
  uploaderType: kopia
snapshotsEnabled: false
deployNodeAgent: true
credentials:
  useSecret: true
  secretContents:
    cloud: |
      [default]
      aws_access_key_id=velero
      aws_secret_access_key=sauvegardes-du-cours-52
resources:
  requests: {cpu: 50m, memory: 128Mi}
  limits: {memory: 512Mi}
nodeAgent:
  resources:
    requests: {cpu: 50m, memory: 64Mi}
    limits: {memory: 512Mi}
```

```sortie
NAME  	NAMESPACE	REVISION	UPDATED                                	STATUS  	CHART        	APP VERSION
velero	velero   	2       	2026-10-08 09:55:55.369002456 +0100 WAT	deployed	velero-12.2.1	1.18.2     
NAME                      READY   STATUS    RESTARTS   AGE
node-agent-k62sj          1/1     Running   0          43m
rustfs-78db9cbc47-g5b7s   1/1     Running   0          47m
velero-d5696b5c9-cvb99    1/1     Running   0          43m
NAME      PROVIDER   BUCKET/PREFIX   PHASE       LAST VALIDATED                  ACCESS MODE   DEFAULT
default   aws        velero          Available   2026-10-08 10:35:05 +0100 WAT   ReadWrite     true
```

`creer-compartiment.sh` utilise `curl --aws-sigv4`, qui sait signer une requête S3 sans outil dédié. Velero lui-même a deux composants : le serveur `velero`, qui pilote les sauvegardes, et `node-agent`, un DaemonSet qui lit les fichiers des volumes sur chaque nœud. Le greffon `velero-plugin-for-aws` lui apprend à parler S3. Deux réglages méritent un mot. `defaultVolumesToFsBackup` copie par défaut le contenu de tous les volumes des Pods, par l'outil **kopia**, qui chiffre et déduplique. `publicUrl` est l'adresse par laquelle le client `velero` du poste joint le stockage : pour afficher les détails et les journaux d'une sauvegarde, il les télécharge directement dans S3, par des URL signées. Sans elle, il essaie d'ouvrir `rustfs.velero.svc`, que le poste ne sait pas résoudre.

### Une sauvegarde réussie qui n'a rien sauvé

Premier essai, dans un namespace jetable soumis aux mêmes règles que Colis (Pod Security `restricted`, politique d'images du chapitre 45). Un Pod écrit la date dans un fichier de son volume persistant :

```bash
kubectl apply -f essai.yaml
kubectl -n ch52-essai exec deploy/carnet -- cat /donnees/carnet.txt
velero backup create essai --include-namespaces ch52-essai --wait
velero backup logs essai | grep level=warning
kubectl -n velero get podvolumebackups -l velero.io/backup-name=essai
```

```sortie
Thu Oct  8 09:35:08 UTC 2026
Backup completed with status: Completed. You may check for more information using the commands `velero backup describe essai` and `velero backup logs essai`.
level=warning msg="Volume donnees in pod ch52-essai/carnet-6755d78d4-rdmnj is a hostPath volume which is not supported for pod volume backup, skipping"
POD   VOLUME   ETAT   OCTETS
```

`Completed`, et pourtant **aucune** copie de volume. L'avertissement dit pourquoi : le volume est de type `hostPath`. C'est ce que crée le provisionneur `standard` de minikube, et la copie de fichiers de Velero ne prend pas en charge ce type[^fsbackup]. On supprime le namespace, on restaure :

```bash
kubectl delete ns ch52-essai
velero restore create essai-1 --from-backup essai --wait
kubectl -n ch52-essai exec deploy/carnet -- cat /donnees/carnet.txt
```

```sortie
Restore completed with status: Completed. You may check for more information using the commands `velero restore describe essai-1` and `velero restore logs essai-1`.
Thu Oct  8 09:35:59 UTC 2026
```

Une date neuve : le volume restauré est vide, et le Pod a écrit un nouveau fichier. Rien n'a signalé la perte, sauf une ligne dans un journal que personne ne lit. C'est la première leçon : une sauvegarde `Completed` avec des avertissements est une sauvegarde **à vérifier**, et la seule vérification qui compte est la restauration.

### Un volume CSI, et une restauration refusée

Même essai avec un volume de la classe `csi-hostpath-sc` (le pilote CSI du chapitre 25), que Velero sait copier :

```bash
kubectl apply -f essai-csi.yaml
kubectl -n ch52-essai exec deploy/carnet -- cat /donnees/carnet.txt
velero backup create essai-csi --include-namespaces ch52-essai --wait
kubectl -n velero get podvolumebackups -l velero.io/backup-name=essai-csi
kubectl delete ns ch52-essai
velero restore create essai-csi-1 --from-backup essai-csi --wait
velero restore describe essai-csi-1      # extrait : les erreurs
kubectl -n ch52-essai get pods
kubectl -n ch52-essai exec deploy/carnet -- cat /donnees/carnet.txt
```

```sortie
Thu Oct  8 09:36:53 UTC 2026
Backup completed with status: Completed. You may check for more information using the commands `velero backup describe essai-csi` and `velero backup logs essai-csi`.
POD                      VOLUME    ETAT        OCTETS
carnet-6755d78d4-dz64b   donnees   Completed   29
Restore completed with status: PartiallyFailed. You may check for more information using the commands `velero restore describe essai-csi-1` and `velero restore logs essai-csi-1`.
Errors:
  Velero:     <none>
  Cluster:    <none>
  Namespaces:
    ch52-essai:  error restoring pods/ch52-essai/carnet-6755d78d4-dz64b: pods "carnet-6755d78d4-dz64b" is forbidden: ValidatingAdmissionPolicy 'images-colis' with binding 'images-colis' denied request: image hors des registres autorisés (host.minikube.internal:5001/,redis:,postgres:,busybox:) : docker.io/velero/velero:v1.18.2
Backup:  essai-csi
NAME                     READY   STATUS    RESTARTS   AGE
carnet-6755d78d4-vh2f2   1/1     Running   0          36s
Thu Oct  8 09:38:11 UTC 2026
```

Cette fois, la sauvegarde a copié les 29 octets du fichier. Mais la restauration échoue à moitié (`PartiallyFailed`), et le message est familier : la politique d'images du chapitre 45 a refusé le Pod. Pour réécrire un volume, Velero ajoute au Pod restauré un conteneur d'initialisation, `restore-wait`, qui le bloque le temps que `node-agent` ait recopié les fichiers (figure 52.2). Son image, `docker.io/velero/velero`, n'est pas dans la liste des registres autorisés. Le Pod refusé, son ReplicaSet en a créé un autre, sans conteneur d'initialisation, donc sans données : la date affichée est encore neuve.

<Figure svg={veleroRestauration} num="52.2" alt="En haut, la sauvegarde en quatre étapes : 1, crochet pre, pg_dump dans l'emptyDir ; 2, lire les objets du namespace par l'API ; 3, node-agent copie les fichiers des volumes avec kopia ; 4, l'archive des objets et le dépôt kopia vont dans S3. En bas, la restauration, qui lit cette archive : 1, recréer namespace, Secrets, ConfigMaps, Services et PVC ; 2, recréer les Pods avec un conteneur d'initialisation restore-wait ajouté ; 3, node-agent réécrit les fichiers dans le volume du Pod ; 4, restore-wait se termine et le crochet post recharge l'export avec psql. Une note : l'image de restore-wait et ses réglages de sécurité passent l'admission comme tout conteneur, politique d'images et Pod Security.">
Ce que fait Velero à la sauvegarde puis à la restauration, avec copie des fichiers des volumes. Le conteneur <code>restore-wait</code> est soumis aux mêmes règles d'admission que les autres.
</Figure>

Élargir la politique serait la mauvaise réponse. La bonne est celle du chapitre 45 : copier l'image dans le registre du cours, et dire à Velero de s'en servir, par une ConfigMap que son greffon de restauration lit :

```bash
docker buildx imagetools create --builder cours --tag localhost:5001/velero/velero:v1.18.2 docker.io/velero/velero:v1.18.2
kubectl apply -f aide-restauration.yaml
kubectl delete ns ch52-essai
velero restore create essai-csi-2 --from-backup essai-csi --wait
kubectl -n ch52-essai exec deploy/carnet -c carnet -- cat /donnees/carnet.txt
kubectl -n ch52-essai get pod -o json | jq -c '.items[0].spec.initContainers | map({name, image, securityContext})'
kubectl -n velero get podvolumerestores -l velero.io/restore-name=essai-csi-2
```

```yaml title="aide-restauration.yaml"
# L'image du conteneur d'initialisation que Velero ajoute aux Pods dont il restaure les volumes.
# Par défaut, docker.io/velero/velero : refusée par la politique d'images du chapitre 45.
# On la copie dans le registre du cours, et Velero la prend ici.
apiVersion: v1
kind: ConfigMap
metadata:
  name: fs-restore-action-config
  namespace: velero
  labels:
    velero.io/plugin-config: ""
    velero.io/pod-volume-restore: RestoreItemAction
data:
  image: host.minikube.internal:5001/velero/velero:v1.18.2
```

```sortie
#1 DONE 2.7s
configmap/fs-restore-action-config created
Restore completed with status: Completed. You may check for more information using the commands `velero restore describe essai-csi-2` and `velero restore logs essai-csi-2`.
Thu Oct  8 09:36:53 UTC 2026
[{"name":"restore-wait","image":"host.minikube.internal:5001/velero/velero:v1.18.2","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]
POD                      VOLUME    ETAT        OCTETS
carnet-6755d78d4-dz64b   donnees   Completed   29
```

La date d'origine est revenue. `imagetools create` copie l'image de registre à registre, toutes architectures comprises, sans la télécharger sur le poste. Le conteneur `restore-wait` porte des réglages de sécurité (`allowPrivilegeEscalation: false`, aucune capability) qui, avec ceux du Pod, passent le niveau `restricted`.

## Colis, pour de vrai

La base de Colis vit sur un volume `standard`, donc `hostPath` : Velero ne la copiera pas. Plutôt que de migrer le volume vers une autre classe, on fait ce qu'on ferait de toute façon pour une base de données : une **sauvegarde logique**. Copier les fichiers d'un PostgreSQL en marche donne au mieux une copie que PostgreSQL devra réparer au démarrage, au pire une copie inutilisable. Un export par `pg_dump` est cohérent par construction. Velero exécute des commandes dans les Pods avant la sauvegarde et après la restauration, déclarées par des **annotations** (les *hooks*, ou crochets)[^hooks] :

```yaml title="postgres-crochets.yaml"
# Sauvegarde logique de la base de Colis par Velero. Le volume de PostgreSQL est un hostPath
# (minikube-hostpath), que Velero ne sait pas copier : un crochet (hook) écrit avant chaque sauvegarde
# un pg_dump dans un emptyDir, que Velero copie ; un autre recharge ce fichier après une restauration.
# À appliquer par : kubectl -n colis patch statefulset postgres --patch-file postgres-crochets.yaml
spec:
  template:
    metadata:
      annotations:
        # avant la sauvegarde : un export cohérent de la base, dans le volume « sauvegarde »
        pre.hook.backup.velero.io/container: postgres
        pre.hook.backup.velero.io/command: '["/bin/sh", "-c", "pg_dump -U colis -d colis --clean --if-exists -f /sauvegarde/colis.sql"]'
        pre.hook.backup.velero.io/timeout: 2m
        # Velero copie tous les volumes des Pods (defaultVolumesToFsBackup) : on écarte le hostPath
        # (il le sauterait de toute façon), la socket et les fichiers temporaires
        backup.velero.io/backup-volumes-excludes: donnees,socket,tmp
        # après la restauration, une fois PostgreSQL prêt : recharger l'export
        post.hook.restore.velero.io/container: postgres
        post.hook.restore.velero.io/command: '["/bin/sh", "-c", "psql -U colis -d colis -q -v ON_ERROR_STOP=1 -f /sauvegarde/colis.sql"]'
        post.hook.restore.velero.io/wait-for-ready: "true"
        post.hook.restore.velero.io/exec-timeout: 2m
    spec:
      containers:
      - name: postgres
        volumeMounts:
        - name: sauvegarde
          mountPath: /sauvegarde
      volumes:
      - name: sauvegarde
        emptyDir:
          sizeLimit: 256Mi
```

```bash
kubectl -n colis patch statefulset postgres --patch-file postgres-crochets.yaml
kubectl -n colis exec postgres-0 -- psql -U colis -d colis -Atc "SELECT statut, count(*) FROM colis GROUP BY statut"
```

```sortie
estimé|2267
livré|1
```

L'option `--clean --if-exists` de `pg_dump` fait commencer l'export par la suppression des objets : rechargé dans une base où l'API a déjà recréé une table vide, il la remplace sans conflit. `ON_ERROR_STOP` fait échouer le crochet à la première erreur, plutôt que de laisser une restauration à moitié faite passer pour réussie.

### La sauvegarde

```bash
velero backup create colis-1 --include-namespaces colis --wait
kubectl -n velero get backup colis-1 -o json | jq -c '{phase: .status.phase, objets: .status.progress,
  avertissements: .status.warnings, erreurs: .status.errors, crochets: .status.hookStatus}'
kubectl -n velero get podvolumebackups -l velero.io/backup-name=colis-1
```

```sortie
Backup completed with status: Completed. You may check for more information using the commands `velero backup describe colis-1` and `velero backup logs colis-1`.

{"phase":"Completed","objets":{"itemsBackedUp":1011,"totalItems":1011},"avertissements":null,"erreurs":null,"crochets":{"hooksAttempted":1}}
POD                      VOLUME          ETAT        OCTETS
web-65cdb99b99-6ppdj     cache           Completed   <none>
web-65cdb99b99-6ppdj     run             Completed   2
web-65cdb99b99-wctcb     run             Completed   2
web-65cdb99b99-wctcb     cache           Completed   <none>
redis-5cbb6759f7-2cjfs   donnees-redis   Completed   88
postgres-0               sauvegarde      Completed   193861
```

Trente-quatre secondes, un crochet exécuté, l'export de 190 Ko copié, ainsi que la file de Redis (dans un `emptyDir`) et les petits volumes temporaires de nginx. Ce que contient l'archive :

```bash
velero backup download colis-1 -o colis-1.tar.gz
tar -tzf colis-1.tar.gz | wc -l
tar -tzf colis-1.tar.gz | sed -n 's#^resources/\([^/]*\)/.*#\1#p' | sort | uniq -c | sort -rn | head -12
tar -xzOf colis-1.tar.gz resources/secrets/namespaces/colis/colis-db.json | jq -c '{nom: .metadata.name, cles: (.data | keys)}'
```

```sortie
Backup colis-1 has been successfully downloaded to colis-1.tar.gz
2023
   1812 events
     64 replicasets.apps
     20 networkpolicies.networking.k8s.io
     14 customresourcedefinitions.apiextensions.k8s.io
     12 pods
     10 controllerrevisions.apps
      8 services
      8 rolebindings.rbac.authorization.k8s.io
      8 endpointslices.discovery.k8s.io
      8 endpoints
      8 deployments.apps
      6 serviceaccounts
{"nom":"colis-db","cles":["POSTGRES_PASSWORD"]}
```

Deux surprises. Les **événements** représentent près de 1 800 des 2 000 fichiers : Velero sauvegarde tout ce qui est dans le namespace, y compris ce qui n'a aucune valeur après une heure (exercice 4). Et le **Secret** `colis-db` est dans l'archive tel que l'API le renvoie, c'est-à-dire déchiffré : le mot de passe de la base est là, simplement encodé en base64. Le chiffrement au repos du chapitre 46 protège etcd, pas ce qui en sort par l'API. Le stockage des sauvegardes doit donc être protégé comme la base elle-même : accès restreint, chiffrement côté serveur, et idéalement verrouillage en écriture pour qu'une attaque ne puisse pas effacer les sauvegardes avec le reste. Seules les données des volumes, copiées par kopia, sont chiffrées par Velero.

### La catastrophe et la restauration

```bash
kubectl delete namespace colis
printf 'passerelle %s   ' "$(curl -sk -o /dev/null -w '%{http_code}' --resolve colis.local:443:192.168.49.102 https://colis.local/api/colis)"
printf 'service web %s\n' "$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' http://192.168.49.100/api/colis)"
velero restore create colis-1 --from-backup colis-1 --wait
```

```sortie
namespace "colis" deleted
passerelle 404   service web 000
```

La passerelle répond 404 (elle n'a plus de route), le Service web n'existe plus. La restauration se lance... et ne se termine pas. Au bout de quelques minutes, l'état du namespace dit pourquoi :

```sortie
# kubectl -n colis get pods
NAME                     READY   STATUS             RESTARTS        AGE
api-765994d98d-hm5kq     0/1     CrashLoopBackOff   8 (3m11s ago)   15m
api-765994d98d-r8vbx     0/1     CrashLoopBackOff   8 (3m4s ago)    15m
postgres-0               0/1     Pending            0               15m
redis-5cbb6759f7-2cjfs   1/1     Running            0               15m
web-65cdb99b99-6ppdj     1/1     Running            0               15m
web-65cdb99b99-wctcb     1/1     Running            0               15m
# kubectl -n colis events --types=Warning (extrait)
4m48s (x3 over 15m)    Warning   FailedScheduling   Pod/postgres-0                             0/1 nodes are available: pod has unbound immediate PersistentVolumeClaims. not found
1s (x63 over 15m)      Warning   FailedBinding      PersistentVolumeClaim/donnees-postgres-0   volume "pvc-72307363-a964-4130-b2cf-c1bf9ce85db5" already bound to a different claim.
# kubectl get pv pvc-72307363-a964-4130-b2cf-c1bf9ce85db5 ; uid de la PVC restaurée
{"etat":"Released","politique":"Retain","reclamation":{"nom":"donnees-postgres-0","uid":"722ac56b-9d72-4cbe-9864-d294f097f4d1"}}
e93094f8-d148-4b8b-b06a-96140d5ff5be
```

PostgreSQL ne démarre pas : sa PVC, restaurée, reste `Pending`. Elle désigne par son nom l'ancien PersistentVolume (`volumeName`), qui existe toujours : il est en politique `Retain` depuis le chapitre 26, et la suppression du namespace l'a laissé `Released`, données comprises. Mais ce volume garde dans `claimRef` l'identifiant (UID) de l'**ancienne** PVC, et refuse la nouvelle, qui porte le même nom mais un autre UID. Velero, lui, attend que le Pod de PostgreSQL démarre pour réécrire son volume `sauvegarde` puis lancer le crochet. Tout est bloqué. On libère le volume en effaçant sa réservation :

```bash
kubectl patch pv pvc-72307363-a964-4130-b2cf-c1bf9ce85db5 --type=json -p '[{"op":"remove","path":"/spec/claimRef"}]'
kubectl -n colis get pvc
```

```sortie
persistentvolume/pvc-72307363-a964-4130-b2cf-c1bf9ce85db5 patched
NAME                 STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
donnees-postgres-0   Bound    pvc-72307363-a964-4130-b2cf-c1bf9ce85db5   1Gi        RWO            standard       <unset>                 15m
NAME                     READY   STATUS             RESTARTS        AGE
api-765994d98d-hm5kq     0/1     CrashLoopBackOff   8 (3m53s ago)   15m
api-765994d98d-r8vbx     0/1     CrashLoopBackOff   8 (3m46s ago)   15m
postgres-0               1/1     Running            0               15m
redis-5cbb6759f7-2cjfs   1/1     Running            0               15m
web-65cdb99b99-6ppdj     1/1     Running            0               15m
web-65cdb99b99-wctcb     1/1     Running            0               15m
```

La PVC se lie aussitôt, PostgreSQL démarre, et Velero termine :

```sortie
Restore completed with status: PartiallyFailed. You may check for more information using the commands `velero restore describe colis-1` and `velero restore logs colis-1`.

Phase:                       PartiallyFailed (run 'velero restore logs colis-1' for more information)
Warnings:
  Velero:     <none>
  Cluster:  could not restore, CustomResourceDefinition:alertmanagerconfigs.monitoring.coreos.com already exists. Warning: the in-cluster version is different than the backed-up version
            could not restore, CustomResourceDefinition:httproutes.gateway.networking.k8s.io already exists. Warning: the in-cluster version is different than the backed-up version
            could not restore, CustomResourceDefinition:podmonitors.monitoring.coreos.com already exists. Warning: the in-cluster version is different than the backed-up version
            could not restore, CustomResourceDefinition:prometheusrules.monitoring.coreos.com already exists. Warning: the in-cluster version is different than the backed-up version
            could not restore, CustomResourceDefinition:referencegrants.gateway.networking.k8s.io already exists. Warning: the in-cluster version is different than the backed-up version
            could not restore, CustomResourceDefinition:scaledobjects.keda.sh already exists. Warning: the in-cluster version is different than the backed-up version
            could not restore, CustomResourceDefinition:servicemonitors.monitoring.coreos.com already exists. Warning: the in-cluster version is different than the backed-up version
            could not restore, PersistentVolume:pvc-72307363-a964-4130-b2cf-c1bf9ce85db5 already exists. Warning: the in-cluster version is different than the backed-up version
  Namespaces:
    colis:  could not restore, ConfigMap:kube-root-ca.crt already exists. Warning: the in-cluster version is different than the backed-up version
Errors:
  Velero:     <none>
  Cluster:    <none>
  Namespaces:
    colis:  error restoring scaledobjects.keda.sh/colis/worker: admission webhook "vscaledobject.kb.io" denied the request: the workload 'worker' of type 'apps/v1.Deployment' is already managed by the hpa 'keda-hpa-worker'
Backup:  colis-1
Restore PVs:  auto
HooksAttempted:   1
HooksFailed:      0
```

`PartiallyFailed`, et chaque ligne mérite lecture. Les avertissements sur les **CRD** sont sans gravité : Velero sauvegarde avec un namespace les définitions des ressources personnalisées qu'il contient, et ne les remplace pas si elles existent. L'erreur, elle, est réelle : le **ScaledObject** de KEDA a été refusé, parce que Velero avait d'abord restauré le HPA `keda-hpa-worker`, que KEDA crée et gère lui-même pour ce ScaledObject (chapitre 31). KEDA refuse un ScaledObject dont la cible est déjà pilotée par un autre HPA. Le correctif : supprimer le HPA restauré, puis ne restaurer que le ScaledObject.

```bash
kubectl -n colis delete hpa keda-hpa-worker
velero restore create colis-keda --from-backup colis-1 --include-resources scaledobjects.keda.sh --wait
kubectl -n colis get scaledobject,hpa
```

```sortie
horizontalpodautoscaler.autoscaling "keda-hpa-worker" deleted from colis namespace
Restore completed with status: Completed. You may check for more information using the commands `velero restore describe colis-keda` and `velero restore logs colis-keda`.
NAME                          SCALETARGETKIND      SCALETARGETNAME   MIN   MAX   READY   ACTIVE   FALLBACK   PAUSED   TRIGGERS   AUTHENTICATIONS   AGE
scaledobject.keda.sh/worker   apps/v1.Deployment   worker            0     5     True    False    False      False    redis                        6s

NAME                                                  REFERENCE           TARGETS              MINPODS   MAXPODS   REPLICAS   AGE
horizontalpodautoscaler.autoscaling/api               Deployment/api      cpu: <unknown>/50%   2         6         2          16m
horizontalpodautoscaler.autoscaling/keda-hpa-worker   Deployment/worker   <unknown>/5 (avg)    1         5         0          6s
```

Le crochet de restauration a rechargé l'export (`HooksAttempted: 1`, `HooksFailed: 0`). Les Pods de l'API, eux, avaient redémarré en boucle tant que la base manquait, et attendaient leur prochain essai. Un `kubectl rollout restart` raccourcit cette attente. Le bilan :

```bash
kubectl -n colis rollout restart deployment/api
kubectl -n colis exec postgres-0 -- psql -U colis -d colis -Atc "SELECT statut, count(*) FROM colis GROUP BY statut"
curl -sk -o /dev/null -w 'passerelle %{http_code}\n' --resolve colis.local:443:192.168.49.102 https://colis.local/api/colis
curl -s -o /dev/null -w 'web %{http_code}\n' http://192.168.49.100/
kubectl -n colis get svc web -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
kubectl get ns colis --show-labels | tr ',' '\n' | grep -E 'enforce=|politique-images|passerelle'
kubectl -n colis get networkpolicy,hpa,servicemonitor,prometheusrule --no-headers | awk '{print $1}'
```

```sortie
deployment.apps/api restarted
deployment "api" successfully rolled out
estimé|2267
livré|1
passerelle 200
web 200
192.168.49.100
cours/politique-images=oui
passerelle=principale
pod-security.kubernetes.io/enforce=restricted
networkpolicy.networking.k8s.io/api
networkpolicy.networking.k8s.io/dns
networkpolicy.networking.k8s.io/postgres
networkpolicy.networking.k8s.io/purge
networkpolicy.networking.k8s.io/redis
networkpolicy.networking.k8s.io/refus-par-defaut
networkpolicy.networking.k8s.io/supervision
networkpolicy.networking.k8s.io/traces
networkpolicy.networking.k8s.io/web
networkpolicy.networking.k8s.io/worker
horizontalpodautoscaler.autoscaling/api
horizontalpodautoscaler.autoscaling/keda-hpa-worker
servicemonitor.monitoring.coreos.com/api
prometheusrule.monitoring.coreos.com/colis
```

Toutes les données sont là, le site répond, et le reste a suivi le namespace. Les étiquettes Pod Security et de politique d'images, les dix NetworkPolicies, le HPA, le ServiceMonitor et les règles de Prometheus sont revenus. Le Service `web` a même retrouvé l'adresse `192.168.49.100` de MetalLB. La restauration a pris seize minutes au lieu d'une, presque toutes perdues à attendre une PVC. C'est exactement ce que les exercices de restauration servent à découvrir avant le jour où ça compte. Retenez les trois pièges pour votre procédure. Un volume en `Retain` ne se relie pas tout seul à une PVC recréée. Les objets créés par un opérateur (HPA de KEDA, Pods d'un StatefulSet, Secrets d'un certificat) gênent leur propriétaire si on les restaure. Les composants qui ont redémarré en boucle pendant la restauration mettent du temps à revenir.

## Planifier

Une sauvegarde manuelle sert à l'exercice. En exploitation, on planifie : un objet **Schedule** crée une sauvegarde selon une expression cron, et chaque sauvegarde expire au bout de son TTL.

```bash
velero schedule create colis-quotidien --schedule "0 3 * * *" --include-namespaces colis --ttl 168h0m0s
velero schedule get
```

```sortie
Schedule "colis-quotidien" created successfully.
NAME              STATUS    CREATED                         SCHEDULE    BACKUP TTL   LAST BACKUP   SELECTOR   PAUSED
colis-quotidien   Enabled   2026-10-08 10:32:28 +0100 WAT   0 3 * * *   168h0m0s     n/a           <none>     false
```

Une sauvegarde par nuit, gardée sept jours : un RPO de 24 heures au pire. Reste à s'assurer qu'elle a bien lieu et qu'elle réussit, sans attendre d'en avoir besoin (exercice 3), et à refaire régulièrement une restauration complète, dans un namespace ou un cluster d'essai.

## Exercices

:::exercice[Exercice 1 : RPO et RTO]

La planification ci-dessus sauvegarde Colis à 3 h. Un mardi à 17 h, une migration ratée détruit la table `colis`. Combien de temps de données perd-on ? Combien de temps faut-il, d'après ce chapitre, pour revenir en service, une fois les pièges connus ? Que faudrait-il pour ne perdre qu'au plus cinq minutes de données ?

:::

<details>
<summary>Corrigé</summary>

La dernière sauvegarde date de 3 h : on perd quatorze heures de colis enregistrés, livrés ou estimés. C'est le RPO réel de cette planification, entre zéro et vingt-quatre heures selon l'heure de l'incident. Pour le RTO, la restauration mesurée a pris seize minutes, dont quinze d'attente sur la PVC ; sans ce piège, la restauration d'objets prend moins d'une minute, et le crochet recharge 190 Ko en quelques secondes. Il faut ajouter le temps de décider de restaurer et de prévenir les utilisateurs, souvent le plus long.

Pour un RPO de cinq minutes, une sauvegarde toutes les cinq minutes serait absurde. Il faut changer de méthode : l'archivage continu des journaux de transactions de PostgreSQL (WAL) vers un stockage objet, qui permet de restaurer à n'importe quel instant. C'est ce que fait l'opérateur CloudNativePG du chapitre 56, avec Barman. Velero garde alors son rôle : les objets Kubernetes, et les données des applications qui n'ont pas mieux.

</details>

:::exercice[Exercice 2 : restaurer ailleurs]

Restaurez seulement les ConfigMaps et les Secrets de la sauvegarde `colis-1` dans un nouveau namespace `ch52-copie`, sans toucher à `colis`. Vérifiez que le Secret `colis-db` est identique. Pourquoi serait-il plus délicat de restaurer **tout** Colis dans un autre namespace sur le même cluster ?

:::

<details>
<summary>Corrigé</summary>

```bash
velero restore create copie --from-backup colis-1 --include-resources configmaps,secrets \
  --namespace-mappings colis:ch52-copie --wait
kubectl -n ch52-copie get configmaps,secrets
diff <(kubectl -n colis get secret colis-db -o jsonpath='{.data}') \
     <(kubectl -n ch52-copie get secret colis-db -o jsonpath='{.data}') && echo "colis-db identique"
```

```sortie
Restore completed with status: Completed. You may check for more information using the commands `velero restore describe copie` and `velero restore logs copie`.
NAME                         DATA   AGE
configmap/colis-config       3      0s
configmap/kube-root-ca.crt   1      0s
configmap/tableau-colis      1      0s

NAME              TYPE     DATA   AGE
secret/colis-db   Opaque   1      0s
colis-db identique
```

`--namespace-mappings` réécrit le namespace de chaque objet restauré, et crée le namespace s'il n'existe pas. Restaurer tout Colis à côté de l'original se heurterait à ce qui n'appartient pas au namespace et ne peut pas exister deux fois. La PVC restaurée désignerait le même PersistentVolume, déjà lié à la vraie. Le Service `LoadBalancer` réclamerait la même adresse à MetalLB. La route HTTP déclarerait le même nom d'hôte `colis.local` sur la même passerelle. Le ScaledObject piloterait un worker sans que la file soit la bonne. Pour cloner une application, on restaure plutôt dans un **autre cluster** : c'est aussi la meilleure façon de tester ses sauvegardes.

</details>

:::exercice[Exercice 3 : surveiller les sauvegardes (programmation)]

Écrivez un script Python qui lit les objets `backups.velero.io` et `schedules.velero.io`, et affiche pour chaque planification sa dernière sauvegarde réussie, son âge et son nombre d'avertissements, ainsi que les échecs éventuels. Le script doit sortir avec le code 1 si une planification n'a pas de sauvegarde réussie de moins de 26 heures, pour pouvoir servir dans une tâche planifiée ou une sonde.

:::

<details>
<summary>Corrigé</summary>

Le corrigé, `corrige/fraicheur.py`, n'est pas dans l'archive. Il regroupe les sauvegardes par l'étiquette `velero.io/schedule-name`, que Velero pose sur chaque sauvegarde créée par une planification, et ne retient que les sauvegardes `Completed`. Juste après la création de la planification, puis après une sauvegarde lancée à partir d'elle :

```bash
python3 fraicheur.py; echo "code de sortie : $?"
velero backup create --from-schedule colis-quotidien --wait
python3 fraicheur.py; echo "code de sortie : $?"
```

```sortie
PLANIFICATION      DERNIÈRE RÉUSSIE         ÂGE  AVERT.  ÉTAT
colis-quotidien    -                          -       -  AUCUNE SAUVEGARDE RÉUSSIE
(à la main)        essai-csi               0.0h       0  ok
code de sortie : 1
Backup completed with status: Completed. You may check for more information using the commands `velero backup describe colis-quotidien-20261008093959` and `velero backup logs colis-quotidien-20261008093959`.
PLANIFICATION      DERNIÈRE RÉUSSIE         ÂGE  AVERT.  ÉTAT
colis-quotidien    colis-quotidien-20261008093959    0.0h       0  ok
(à la main)        essai-csi               0.1h       0  ok
code de sortie : 0
```

Le cas qu'il fallait attraper est le premier : une planification qui existe mais n'a encore rien produit, et que personne ne remarquerait avant la première restauration. Le script considère aussi comme suspecte une sauvegarde réussie avec avertissements : c'est le cas du premier essai de ce chapitre. Velero publie les mêmes informations en métriques Prometheus (`velero_backup_last_successful_timestamp`, par planification), à surveiller par une règle d'alerte comme au chapitre 50, ce qui évite un script de plus.

</details>

:::exercice[Exercice 4 : une sauvegarde plus propre]

La sauvegarde `colis-1` contient plus de 1 800 événements, et le HPA que KEDA gère lui-même, qui a fait échouer la restauration. Créez une sauvegarde `colis-2` qui exclut les deux, et comparez le nombre d'objets.

:::

<details>
<summary>Corrigé</summary>

```bash
velero backup create colis-2 --include-namespaces colis --exclude-resources events,events.events.k8s.io \
  --selector '!scaledobject.keda.sh/name' --wait
```

```sortie
Backup completed with status: Completed. You may check for more information using the commands `velero backup describe colis-2` and `velero backup logs colis-2`.
colis-1 : 1011 objets, 0 avertissements
colis-2 : 117 objets, 0 avertissements
HPA dans colis-2 : api.json 
événements dans colis-2 : 0
```

117 objets au lieu de 1 011. Les événements existent sous deux API (`events` et `events.events.k8s.io`), qu'il faut exclure toutes les deux. Le sélecteur `!scaledobject.keda.sh/name` garde les objets qui n'ont **pas** cette étiquette, que KEDA pose sur les HPA qu'il crée : il reste le HPA `api`, qu'on a écrit nous-mêmes. La même logique vaut pour tout opérateur : on sauvegarde la ressource dont il part (ScaledObject, Certificate, Cluster), pas ce qu'il en déduit. Il recréera le reste. Ces options se posent aussi sur la planification (`velero schedule create ... --exclude-resources ...`).

</details>

## Nettoyer

La suite de la partie n'a pas besoin de Velero ni de RustFS, qui occupent près de 400 Mio. On les retire, avec les objets d'essai et l'ancien répertoire de données d'etcd. L'ordre compte : les objets `Restore` de Velero portent un finaliseur que seul Velero retire. Désinstallé trop tôt, il laisse le namespace `velero` bloqué en `Terminating`, exactement comme dans l'exercice 4 du chapitre 49. C'est arrivé pendant la préparation de ce chapitre ; on supprime donc d'abord restaurations et sauvegardes, par Velero lui-même :

```bash
kubectl delete ns ch52 ch52-essai ch52-copie
velero schedule delete colis-quotidien --confirm
velero restore delete --all --confirm
velero backup delete --all --confirm
velero backup get                       # attendre qu'il n'y en ait plus
helm -n velero uninstall velero
kubectl delete ns velero
kubectl delete crd $(kubectl get crd -o name | grep velero.io | cut -d/ -f2)
minikube ssh -- 'sudo rm -rf /var/lib/minikube/etcd-avant-*'
```

Les crochets restent sur le StatefulSet de PostgreSQL : sans Velero, personne ne les déclenche, et ils documentent la procédure. L'image `velero/velero` reste dans le registre du cours. Gardez les instantanés d'etcd et leur clé, hors du dépôt Git du cours ; le chapitre 53 commence par en prendre un.

[^nist]: NIST, SP 800-34 Rév. 1, « Contingency Planning Guide for Federal Information Systems » : définitions du RPO et du RTO, tests et exercices des plans de reprise. [csrc.nist.gov/pubs/sp/800/34/r1/upd1/final](https://csrc.nist.gov/pubs/sp/800/34/r1/upd1/final)
[^etcd]: Kubernetes, « Operating etcd clusters for Kubernetes », sections « Backing up an etcd cluster » et « Restoring an etcd cluster » : `etcdctl snapshot save`, `etcdutl snapshot restore`, restauration de tous les membres à partir du même instantané, arrêt des API servers, redémarrage recommandé des composants. [kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd](https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/)
[^velero]: Velero, « How Velero works » : sauvegarde des objets par l'API vers un stockage objet, restauration, planifications et TTL. [velero.io/docs/main/how-velero-works](https://velero.io/docs/main/how-velero-works/)
[^fsbackup]: Velero, « File System Backup » : copie des volumes par node-agent avec kopia, conteneur d'initialisation `restore-wait`, limites (volumes hostPath non pris en charge), réglage de l'image et des ressources de l'aide à la restauration par la ConfigMap `fs-restore-action-config`. [velero.io/docs/main/file-system-backup](https://velero.io/docs/main/file-system-backup/)
[^hooks]: Velero, « Backup Hooks » et « Restore Hooks » : annotations `pre.hook.backup.velero.io/*` et `post.hook.restore.velero.io/*`, attente de la disponibilité du conteneur, délais. [velero.io/docs/main/backup-hooks](https://velero.io/docs/main/backup-hooks/)
