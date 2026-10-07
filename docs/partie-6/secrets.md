---
title: Les secrets pour de vrai
sidebar_label: 46. Les secrets pour de vrai
description: "Où vivent vraiment les Secrets, et comment les protéger : une sauvegarde d'etcd qui contient le mot de passe de Colis, le chiffrement au repos et ses pièges (anciennes révisions, clé perdue, rotation), Sealed Secrets pour versionner sans exposer, External Secrets et Vault pour garder la source hors du cluster."
partie: 6
chapitre: '46'
---

import secretCopies from '@site/src/figures/secret-copies.svg';
import esoVault from '@site/src/figures/eso-vault.svg';

Un jour, quelqu'un prendra une sauvegarde d'etcd (c'est même le sujet du chapitre 52). Elle partira sur un disque réseau, dans un compartiment de stockage, sur la clé USB de l'astreinte. Que contient-elle exactement ? Prenons-en une, et cherchons dedans le mot de passe de PostgreSQL de Colis :

```bash
source etcd-minikube.sh                    # la fonction E du chapitre 35
E snapshot save /var/lib/minikube/etcd/s.db
docker cp minikube:/var/lib/minikube/etcd/s.db sauvegarde.db
MDP=$(kubectl -n colis get secret colis-db -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
grep -a -o "$MDP" sauvegarde.db | wc -l
strings sauvegarde.db | grep -B3 "$MDP"
```

```sortie
sauvegarde.db : 25559072 octets, 1 occurrence(s) du mot de passe
FieldsV1::
8{"f:data":{".":{},"f:POSTGRES_PASSWORD":{}},"f:type":{}}B
POSTGRES_PASSWORD
riURxKVQ3zHKf4MVd79mIpV
```

(La première ligne de sortie est celle du script de rejeu, qui résume les deux premières commandes.) Un fichier de 25 Mo, et dedans, en clair, le nom de la clé et le mot de passe juste en dessous. Pas besoin d'outil spécial pour le trouver : `strings` suffit. Le chapitre 35 avait montré qu'etcd stocke les Secrets tels quels. Cette sauvegarde montre la conséquence : chaque copie d'etcd est une copie de tous les secrets du cluster.

Ce chapitre fait le tour des endroits où un Secret existe, et des protections qui s'appliquent à chacun. Le chiffrement au repos protège etcd et ses sauvegardes. Sealed Secrets permet de ranger des Secrets dans Git sans les exposer. External Secrets laisse la source de vérité dans un vrai coffre, hors du cluster. Les fichiers sont dans [l'archive secrets](pathname:///kits/secrets.tar.gz).

## Où vit un Secret

D'abord, une idée reçue à écarter. Les valeurs d'un Secret apparaissent encodées en base64, ce qui ressemble à du chiffrement et n'en est pas :

```bash
kubectl -n colis get secret colis-db -o jsonpath='{.data}{"\n"}'
kubectl -n colis get secret colis-db -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d; echo
```

```sortie
{"POSTGRES_PASSWORD":"cmlVUnhLVlEzekhLZjRNVmQ3OW1JcFY="}
riURxKVQ3zHKf4MVd79mIpV
```

Le base64 sert à transporter des octets quelconques dans du JSON ou du YAML, pas à les cacher. Un Secret ne diffère d'une ConfigMap que par le traitement que Kubernetes lui réserve : des droits RBAC distincts, un stockage en mémoire (tmpfs) sur les nœuds, l'éventuel chiffrement au repos[^secret]. Voici tous les endroits où sa valeur existe :

<Figure svg={secretCopies} num="46.1" alt="Le manifeste YAML dans un dépôt Git, en base64 donc en clair, est appliqué à l'API server, qui chiffre à l'écriture et déchiffre à la lecture avec une clé sur le nœud. L'API server écrit dans etcd (valeur actuelle et anciennes révisions), dont les sauvegardes sont copiées ailleurs. L'API server sert aussi les lecteurs de l'API (get, list, watch : en clair) et le kubelet (fichier en tmpfs ou variable d'environnement), qui transmet au conteneur, qui lit la valeur en clair. En dessous, les protections : Sealed Secrets pour le dépôt, RBAC pour les lecteurs de l'API, chiffrement au repos pour etcd et ses sauvegardes mais pas l'API, coffre externe pour la source de vérité hors du cluster et la rotation.">
Les copies d'un Secret, et la protection qui couvre chacune. Aucune ne couvre tout.
</Figure>

Chaque protection couvre une partie du chemin, et aucune ne protège le conteneur qui lit la valeur : c'est son métier. Le chapitre 43 a traité les lecteurs de l'API. Ce chapitre traite les trois autres cases.

## Le chiffrement au repos

L'API server peut chiffrer les objets juste avant de les écrire dans etcd, et les déchiffrer à la lecture. On le configure par un fichier, une `EncryptionConfiguration`, qui dit quelles ressources chiffrer et avec quels **fournisseurs**[^chiffrement] :

```yaml title="chiffrement/chiffrement.yaml.modele"
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources: [secrets]
  providers:
  # le premier fournisseur chiffre les écritures ; tous servent à relire
  - secretbox:
      keys:
      - name: cle1
        secret: CLE1
  - identity: {}
```

L'ordre des fournisseurs est la règle à retenir. Le **premier** chiffre tout ce qui est écrit ; **tous** sont essayés, dans l'ordre, pour relire. `identity` ne chiffre rien : placé en second, il permet de relire les Secrets écrits avant le chiffrement. `secretbox` (XSalsa20 et Poly1305, clé de 32 octets) fait partie des fournisseurs que la documentation juge solides ; elle déconseille `aescbc`, vulnérable aux attaques par oracle de remplissage, et réserve `aesgcm` à qui fait tourner ses clés automatiquement. En production, on préfère **KMS v2** : la clé qui chiffre les données est elle-même chiffrée par une clé maîtresse qui ne quitte jamais un service de gestion de clés (celui d'un fournisseur de nuage, Vault, un HSM). Avec les autres fournisseurs, la clé est dans un fichier sur le nœud[^chiffrement].

`nouvelle-cle.sh` produit 32 octets aléatoires encodés en base64, qui remplacent `CLE1`. `brancher-chiffrement.sh` dépose le fichier sur le nœud et ajoute deux options au manifeste de l'API server, comme `brancher-fournisseur.sh` au chapitre 42. La seconde active le **rechargement automatique** du fichier, qui servira à faire tourner les clés sans redémarrer.

```bash
sed "s|CLE1|$(bash nouvelle-cle.sh)|" chiffrement.yaml.modele > chiffrement.yaml
bash brancher-chiffrement.sh chiffrement.yaml
kubectl -n kube-system get pod kube-apiserver-minikube -o json | jq -r '.spec.containers[0].command[]' | grep encryption
```

```sortie
API server redémarré avec /var/lib/minikube/certs/cours-chiffrement/chiffrement.yaml
--encryption-provider-config=/var/lib/minikube/certs/cours-chiffrement/chiffrement.yaml
--encryption-provider-config-automatic-reload=true
```

Regardons les premiers octets de deux Secrets dans etcd : un nouveau, écrit après l'activation, et `colis-db`, écrit avant.

```bash
kubectl create ns ch46
kubectl -n ch46 create secret generic essai --from-literal=motdepasse=ultra-secret-46
E get /registry/secrets/ch46/essai --print-value-only | head -c 60 | od -An -c
E get /registry/secrets/colis/colis-db --print-value-only | head -c 48 | od -An -c
kubectl -n ch46 get secret essai -o jsonpath='{.data.motdepasse}' | base64 -d; echo
```

```sortie
secret/essai created
== essai (écrit après)
 k 8 s : e n c : s e c r e t b o
 x : v 1 : c l e 1 : 270 e k 326 021 026
== colis-db (écrit avant)
 k 8 s \0 \n \f \n 002 v 1 022 006 S e c r
 e t 022 363 001 \n 272 001 \n \b c o l i s -
ultra-secret-46
```

Le nouveau Secret commence par `k8s:enc:secretbox:v1:cle1:` : le fournisseur et le nom de la clé sont écrits en clair, pour que l'API server sache comment déchiffrer, puis viennent des octets illisibles. `colis-db` commence toujours par `k8s\0` suivi du protobuf du chapitre 35 : il est encore en clair. Le chiffrement ne s'applique qu'aux **écritures**. Pour les clients, rien n'a changé : l'API server déchiffre en lisant, et `kubectl` affiche la valeur comme avant.

### Réécrire, puis faire le ménage

Pour chiffrer les Secrets existants, il suffit de les réécrire tels quels ; la documentation donne la commande[^chiffrement] :

```bash
kubectl get secrets -A -o json | kubectl replace -f -
E get /registry/secrets/colis/colis-db --print-value-only | head -c 48 | od -An -c
```

```sortie
     25 replaced
 k 8 s : e n c : s e c r e t b o
 x : v 1 : c l e 1 : 350 232 / 377 250 h
```

(On a compté les lignes `replaced` au lieu de les afficher.) `colis-db` est maintenant chiffré. La sauvegarde de l'ouverture est-elle devenue inoffensive ? Prenons-en une nouvelle :

```sortie
apres-reecriture.db : 28196896 octets, 1 occurrence(s) du mot de passe
```

Toujours là. etcd garde les **anciennes révisions** de chaque clé (chapitre 35), et la version en clair de `colis-db` en fait partie. L'API server demande à etcd de les oublier par un **compactage** toutes les cinq minutes par défaut[^flags]. Compactons tout de suite, jusqu'à la révision courante, et reprenons une sauvegarde :

```bash
E compact 431766
E defrag
```

```sortie
compacted revision 431766
apres-compactage.db : 28196896 octets, 1 occurrence(s) du mot de passe
Finished defragmenting etcd member[127.0.0.1:2379]. took 158.106685ms
apres-defragmentation.db : 12111904 octets, 0 occurrence(s) du mot de passe
```

Le compactage n'a pas suffi : il retire les anciennes révisions de l'index d'etcd, mais les pages du fichier qui les contenaient sont seulement marquées comme libres, pas effacées. Il a fallu la **défragmentation**, qui recopie la base dans un fichier neuf, pour que le mot de passe disparaisse, et la base est passée de 28 à 12 Mo. etcd ne défragmente jamais tout seul. La leçon dépasse cet exemple : après l'activation du chiffrement, ou après une fuite, les sauvegardes déjà faites contiennent toujours les anciennes valeurs, et il faut les traiter comme compromises. La documentation recommande d'ailleurs d'effacer les disques qu'etcd a utilisés, une fois qu'ils ne servent plus[^bonnes] ; une sauvegarde mérite le même traitement qu'etcd lui-même : stockée chiffrée, et lisible par le moins de monde possible.

:::panne[readyz check failed, et plus aucun Secret ne se lit]

Les données chiffrées n'existent qu'avec leur clé. Le script refuse de retirer la configuration tant que l'API server tourne ; forçons-le, pour voir ce qui arrive à qui perd son fichier de clés :

```sortie
Avant de retirer le chiffrement, réécrivez les Secrets en clair (fournisseur identity en tête).
Sinon l'API server ne pourra plus les lire. FORCER=oui pour passer outre.
l'API server ne devient pas prêt : des données chiffrées sont-elles devenues illisibles ?
Error from server (InternalError): Internal error occurred: StorageError: corrupt object, Code: 7, Key: /secrets/ch46/essai, ResourceVersion: 0, AdditionalErrorMsg: data from the storage is not transformable revision=0: identity transformer tried to read encrypted data
```

L'API server redémarre, répond aux requêtes, mais n'est jamais **prêt** : son cache interne des Secrets n'arrive pas à se remplir (`cacher (secrets): unexpected ListAndWatch error ... corrupt object` dans son journal). Tout ce qui lit un Secret échoue. Les Pods déjà lancés continuent de tourner, mais aucun nouveau Pod qui monte un Secret ne pourrait démarrer. On s'en sort en remettant le même fichier, et c'est la seule issue : sans la clé, ces données sont perdues. Sauvegardez le fichier de configuration, à part des sauvegardes d'etcd, avec le même soin que la clé d'un coffre. Pour retirer proprement le chiffrement, on fait l'inverse de l'activation : `identity` en tête, réécriture de tous les Secrets, puis retrait de la configuration ; le script de rejeu le fait au début.

:::

## Ranger des secrets dans Git : Sealed Secrets

Les manifestes de Colis, organisés avec Kustomize au chapitre 30, ont vocation à vivre dans un dépôt Git, d'où le chapitre 57 les déploiera. Mais un Secret dans Git, c'est un mot de passe en base64 dans l'historique, pour toujours. **Sealed Secrets** résout ce problème avec de la cryptographie asymétrique[^sealed]. Un contrôleur, dans le cluster, garde une clé privée. Chacun peut chiffrer un Secret avec la clé publique correspondante, grâce à l'outil `kubeseal`. Le résultat, un objet `SealedSecret`, peut aller dans Git ; seul le contrôleur sait le déchiffrer, et il en fait un Secret ordinaire dans le cluster.

```bash
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.40.0/controller.yaml
kubectl -n kube-system logs deploy/sealed-secrets-controller | grep -E 'New key written|Certificate generated'
kubeseal --fetch-cert > cle-publique.pem
openssl x509 -in cle-publique.pem -noout -dates
```

```sortie
time=2026-10-07T20:02:00.331Z level=INFO msg="New key written" namespace=kube-system name=sealed-secrets-keym8gtg
time=2026-10-07T20:02:00.331Z level=INFO msg="Certificate generated" certificate=...
notBefore=Oct  7 20:02:00 2026 GMT
notAfter=Oct  4 20:02:00 2036 GMT
```

Au démarrage, le contrôleur a fabriqué sa paire de clés et l'a rangée dans un Secret de `kube-system`. La clé publique se distribue librement : on peut même la versionner, pour sceller des Secrets sans accès au cluster. Scellons un jeton d'API pour Colis. Le Secret en clair n'est fabriqué que localement, avec `--dry-run=client`, et ne part jamais vers l'API server :

```bash
kubectl -n colis create secret generic colis-scelle --from-literal=JETON_API=jeton-de-demonstration-46 --dry-run=client -o yaml > secret-clair.yaml
kubeseal --format yaml < secret-clair.yaml > colis-scelle.yaml
cat colis-scelle.yaml
```

```sortie
---
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: colis-scelle
  namespace: colis
spec:
  encryptedData:
    JETON_API: AgB8HsMZoZg2OOyRWky4/T1qButPkactynX53lX4p99rSEzSBq9btzlE2wIE...
  template:
    metadata:
      name: colis-scelle
      namespace: colis
```

(La valeur chiffrée, longue de plus de 700 caractères, a été coupée.) C'est `colis-scelle.yaml` qu'on commite ; `secret-clair.yaml` se supprime. Appliqué au cluster, il devient un Secret :

```bash
kubectl apply -f colis-scelle.yaml
kubectl -n colis get sealedsecret,secret colis-scelle
kubectl -n colis get secret colis-scelle -o jsonpath='{.data.JETON_API}' | base64 -d; echo
```

```sortie
sealedsecret.bitnami.com/colis-scelle created
NAME                                    AGE
sealedsecret.bitnami.com/colis-scelle   5s

NAME                  TYPE     DATA   AGE
secret/colis-scelle   Opaque   1      5s
jeton-de-demonstration-46
```

Qu'est-ce qui empêche quelqu'un qui a accès au dépôt de recopier ce fichier dans son propre namespace, pour que le contrôleur lui déchiffre le jeton ? Essayons :

```bash
sed 's/namespace: colis/namespace: ch46/' colis-scelle.yaml | kubectl apply -f -
kubectl -n ch46 get secret colis-scelle
kubectl -n ch46 get events --field-selector involvedObject.name=colis-scelle -o custom-columns=RAISON:.reason,MESSAGE:.message
```

```sortie
sealedsecret.bitnami.com/colis-scelle created
Error from server (NotFound): secrets "colis-scelle" not found
RAISON            MESSAGE
ErrUnsealFailed   Failed to unseal: no key could decrypt secret (JETON_API)
```

Par défaut, la portée est `strict` : le nom et le namespace font partie des données chiffrées, et un Secret scellé ne se déchiffre que sous son nom, dans son namespace[^sealed]. L'exercice 3 montre les portées plus souples. Deux précautions d'exploitation, enfin. Le contrôleur crée une nouvelle clé tous les 30 jours et garde les anciennes pour relire ce qui a été scellé avant ; ce renouvellement ne change pas les secrets eux-mêmes, qu'il faut faire tourner autrement. Et ses clés privées sont dans des Secrets de `kube-system` : si le cluster disparaît sans elles, tous les `SealedSecret` du dépôt deviennent illisibles. Elles se sauvegardent, hors du dépôt.

## La source hors du cluster : External Secrets et Vault

Sealed Secrets garde les secrets dans Git. Beaucoup d'organisations préfèrent qu'ils ne vivent nulle part ailleurs que dans un **coffre** : HashiCorp Vault, AWS Secrets Manager, Azure Key Vault, Google Secret Manager… Le coffre gère les droits, l'audit et la rotation, et le cluster ne garde qu'une copie. **External Secrets Operator** fait le lien : il lit un secret dans le coffre et le recopie dans un Secret Kubernetes, puis le tient à jour[^eso].

Il faut un coffre. On déploie Vault en **mode développement** : stockage en mémoire, déverrouillé, jeton racine connu. C'est fait pour un cours ou un essai, jamais pour le reste. Il tourne dans un namespace `coffre` au niveau `restricted`, sous l'utilisateur de l'image :

```bash
kubectl apply -f externe/vault-dev.yaml
kubectl -n coffre logs deploy/vault | grep -E 'Storage:|Version:|WARNING! dev mode|Root Token'
```

```sortie
                 Storage: inmem
                 Version: Vault v2.1.2, built 2026-10-06T15:17:37Z
WARNING! dev mode is enabled! In this mode, Vault runs entirely in-memory
Root Token: jeton-racine-du-cours
```

Comment External Secrets prouvera-t-il à Vault qu'il agit pour Colis ? Pas avec un mot de passe, qu'il faudrait lui-même stocker dans un Secret. Avec un **jeton de ServiceAccount**, comme au chapitre 42. `configurer-vault.sh` active la méthode d'authentification `kubernetes` de Vault et crée un rôle `colis-eso` : les jetons du ServiceAccount `eso-colis` du namespace `colis`, d'audience `vault`, reçoivent la politique `colis-lecture`, qui ne permet que de lire les secrets rangés sous `colis/`[^vault].

```bash
bash externe/configurer-vault.sh
```

```sortie
version            1
Success! Enabled kubernetes auth method at: kubernetes/
Success! Data written to: auth/kubernetes/config
Success! Uploaded policy: colis-lecture
Success! Data written to: auth/kubernetes/role/colis-eso
```

Pour vérifier les jetons qu'on lui présente, Vault les soumet à l'API server par un `TokenReview`, exactement comme le coffre imaginaire du chapitre 42. Il lui faut pour cela la ClusterRole `system:auth-delegator`, que `vault-dev.yaml` lui donne.

External Secrets s'installe par son chart OCI, sans son webhook ni son contrôleur de certificats, pour ménager la mémoire du nœud :

```bash
helm install external-secrets oci://ghcr.io/external-secrets/charts/external-secrets --version 2.12.0 \
  -n external-secrets --create-namespace --set installCRDs=true --set webhook.create=false --set certController.create=false --wait
```

Côté Colis, trois objets. Un ServiceAccount `eso-colis`, sans jeton monté : External Secrets demandera lui-même un jeton à la volée. Un `SecretStore`, qui dit où est le coffre et comment s'y authentifier. Un `ExternalSecret`, qui dit quoi recopier, où, et à quel rythme :

```yaml title="externe/colis-vault.yaml (extrait)"
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: vault
  namespace: colis
spec:
  provider:
    vault:
      server: http://vault.coffre.svc:8200
      path: secret
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: colis-eso
          serviceAccountRef:
            name: eso-colis
            audiences: [vault]
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: colis-partenaire
  namespace: colis
spec:
  refreshInterval: 30s
  secretStoreRef:
    kind: SecretStore
    name: vault
  target:
    name: colis-partenaire
  data:
  - secretKey: JETON_PARTENAIRE
    remoteRef:
      key: colis/api
      property: jeton-partenaire
```

```bash
kubectl apply -f externe/colis-vault.yaml
kubectl -n colis get secretstore,externalsecret
kubectl -n colis get secret colis-partenaire -o jsonpath='{.data.JETON_PARTENAIRE}' | base64 -d; echo
```

```sortie
serviceaccount/eso-colis created
secretstore.external-secrets.io/vault created
externalsecret.external-secrets.io/colis-partenaire created
NAME                                    AGE   STATUS   CAPABILITIES   READY
secretstore.external-secrets.io/vault   30s   Valid    ReadWrite      True

NAME                                                  STORETYPE     STORE   REFRESH INTERVAL   STATUS         READY   LAST SYNC
externalsecret.external-secrets.io/colis-partenaire   SecretStore   vault   30s                SecretSynced   True    1s
jeton-partenaire-v1
```

<Figure svg={esoVault} num="46.2" alt="External Secrets lit l'ExternalSecret colis-partenaire et son SecretStore. 1 : il demande à l'API server un jeton pour eso-colis, d'audience vault. 2 : il se connecte à Vault avec ce jeton. 3 : Vault demande à l'API server, par un TokenReview, si le jeton est valide. 4 : Vault applique le rôle colis-eso et la politique colis-lecture, et renvoie le secret colis/api. 5 : External Secrets écrit le Secret, toutes les 30 secondes. 6 : le kubelet le transmet au Pod lecteur, dont le fichier est mis à jour en une minute environ et la variable jamais.">
External Secrets et Vault, du coffre au Pod. Aucun mot de passe n'est stocké pour accéder au coffre : l'identité vient du jeton de ServiceAccount.
</Figure>

### La rotation, et ce que voient les Pods

L'intérêt d'un coffre est de pouvoir changer un secret à un seul endroit. Le Pod `lecteur` lit le Secret de deux façons : par une variable d'environnement, et par un fichier monté. On change la valeur dans Vault, et on chronomètre :

```bash
kubectl apply -f externe/lecteur.yaml
kubectl -n colis exec lecteur -- sh -c 'echo "variable : $JETON_PARTENAIRE ; fichier : $(cat /secrets/JETON_PARTENAIRE)"'
kubectl -n coffre exec deploy/vault -- vault kv put secret/colis/api jeton-partenaire=jeton-partenaire-v2
# on attend que le Secret, puis le fichier, changent
kubectl -n colis exec lecteur -- sh -c 'echo "variable : $JETON_PARTENAIRE ; fichier : $(cat /secrets/JETON_PARTENAIRE)"'
```

```sortie
variable : jeton-partenaire-v1 ; fichier : jeton-partenaire-v1
version            2
Secret mis à jour après 28 s
fichier mis à jour après 74 s
variable : jeton-partenaire-v1 ; fichier : jeton-partenaire-v2
```

(Les commandes `vault` du kit passent l'adresse et le jeton racine en variables d'environnement ; on les a omises ici.) Trois délais, trois mécanismes. External Secrets a vu le changement à son prochain passage, au plus 30 secondes plus tard. Le kubelet a mis à jour le fichier monté à sa propre cadence, une minute environ, au gré de sa période de synchronisation et de son cache[^secret]. La variable d'environnement, elle, ne changera **jamais** : elle a été fixée au démarrage du conteneur, et il faut redémarrer le Pod pour la relire[^configmap]. Un montage en `subPath` ne serait pas mis à jour non plus. C'est le cas de Colis, qui lit son mot de passe PostgreSQL par une variable : une rotation exigera un `kubectl rollout restart`. Pour qu'une rotation soit vraiment transparente, l'application doit relire un fichier.

## Choisir

| | Chiffrement au repos | Sealed Secrets | External Secrets |
|---|---|---|---|
| ce qu'il protège | etcd et ses sauvegardes | le dépôt Git | la source de vérité, hors du cluster |
| où est la clé | fichier sur le nœud (ou KMS) | Secret de `kube-system` | le coffre et sa propre gestion |
| rotation d'un secret | non concernée | resceller et commiter | dans le coffre, propagée seule |
| ce qu'il faut sauvegarder | le fichier de clés | les clés du contrôleur | le coffre |

Ces outils ne s'excluent pas : le chiffrement au repos est utile dans tous les cas, puisque les Secrets recopiés par Sealed Secrets ou External Secrets finissent dans etcd comme les autres. Pour Colis, le cluster de ce cours réunit les trois.

## Exercices

:::exercice[Exercice 1 : faire tourner la clé]

La clé `cle1` a peut-être fuité. Faites-la remplacer par une nouvelle clé `cle2`, sans redémarrer l'API server et sans qu'aucun Secret ne devienne illisible en chemin, puis retirez `cle1`. Dans quel ordre faut-il placer les deux clés, et pourquoi ? Comment savoir que l'API server a pris en compte le nouveau fichier ?

:::

<details>
<summary>Corrigé</summary>

Trois étapes. D'abord une configuration avec **les deux clés, `cle2` en tête** : la première chiffre les écritures, et `cle1` reste là pour relire l'existant[^chiffrement].

```yaml title="rotation-etape1.yaml (extrait)"
  - secretbox:
      keys:
      - name: cle2
        secret: <nouvelle clé>
      - name: cle1
        secret: <ancienne clé>
  - identity: {}
```

Grâce à `--encryption-provider-config-automatic-reload`, il suffit de remplacer le fichier ; l'API server le relit environ toutes les minutes, et une métrique le confirme. Ensuite, on réécrit tous les Secrets. Le corrigé de l'exercice 2 sert à vérifier.

```bash
bash brancher-chiffrement.sh rotation-etape1.yaml
kubectl get --raw /metrics | grep '^apiserver_encryption_config_controller_automatic_reloads_total'
kubectl -n ch46 create secret generic apres-rotation --from-literal=a=b
python3 corrige/audit-chiffrement.py
kubectl get secrets -A -o json | kubectl replace -f -
python3 corrige/audit-chiffrement.py
```

```sortie
configuration remplacée ; l'API server la relit seul (rechargement automatique)
configuration rechargée après 33 s
apiserver_encryption_config_controller_automatic_reloads_total{status="success"} 1
secret/apres-rotation created
  28  chiffré (secretbox, clé cle1)
   1  chiffré (secretbox, clé cle2)
     29 replaced
  29  chiffré (secretbox, clé cle2)
```

Le nouveau Secret a été chiffré avec `cle2` dès le rechargement ; après la réécriture, plus rien n'utilise `cle1`. Enfin, une configuration avec `cle2` seule (`rotation-etape2.yaml`), rechargée de la même façon. Dans l'autre ordre (`cle1` en tête), le rechargement n'aurait rien changé aux écritures, et retirer `cle1` aurait rendu illisibles tous les Secrets non réécrits. N'oubliez pas les sauvegardes d'etcd faites avant la rotation : elles restent chiffrées avec `cle1`, qu'il faut donc conserver aussi longtemps qu'elles.

</details>

:::exercice[Exercice 2 : auditer le chiffrement (programmation)]

Écrivez en Python `audit-chiffrement.py`, qui lit dans etcd tous les Secrets du cluster et indique combien sont stockés en clair, et combien sont chiffrés avec chaque fournisseur et chaque clé. Le script doit sortir avec le code 1 s'il trouve un Secret en clair, pour servir dans une vérification automatique. `etcdctl get /registry/secrets/ --prefix -w json` renvoie les clés et les valeurs encodées en base64.

:::

<details>
<summary>Corrigé</summary>

Le corrigé est `corrige/audit-chiffrement.py`. Tout repose sur le préfixe de la valeur stockée :

```python title="corrige/audit-chiffrement.py (extrait)"
def classer(valeur):
    if valeur.startswith(b"k8s:enc:"):
        # k8s:enc:<fournisseur>:v1:<nom de clé>:<données chiffrées>
        _, _, fournisseur, _, cle = valeur.split(b":", 5)[:5]
        return f"chiffré ({fournisseur.decode()}, clé {cle.decode()})"
    if valeur.startswith(b"k8s\x00"):
        return "EN CLAIR"
    return "format inconnu"
```

```bash
python3 corrige/audit-chiffrement.py; echo "code de sortie : $?"
```

```sortie
  28  chiffré (secretbox, clé cle1)
code de sortie : 0
```

On travaille sur les octets : une partie de la valeur chiffrée n'est pas de l'UTF-8, et seul l'en-tête se décode. Le découpage s'arrête après le cinquième champ, puisque les données chiffrées peuvent contenir des `:`. Ce script ne lit que la valeur courante de chaque clé : il ne dit rien des anciennes révisions, ni des sauvegardes déjà faites.

</details>

:::exercice[Exercice 3 : renommer un Secret scellé]

Le Secret scellé `colis-scelle` doit être renommé `colis-scelle-renomme`. Essayez d'abord de changer son nom dans `colis-scelle.yaml`. Trouvez ensuite, dans `kubeseal --help`, comment sceller un Secret qu'on pourra renommer librement **dans son namespace**, et vérifiez. Quel risque cette souplesse introduit-elle ?

:::

<details>
<summary>Corrigé</summary>

```bash
kubeseal --format yaml --scope namespace-wide < secret-clair.yaml > colis-scelle-ns.yaml
grep -A1 annotations colis-scelle-ns.yaml
sed 's/name: colis-scelle$/name: colis-scelle-renomme/' colis-scelle-ns.yaml | kubectl apply -f -
sed 's/name: colis-scelle$/name: colis-scelle-renomme-strict/' colis-scelle.yaml | kubectl apply -f -
kubectl -n colis get secret colis-scelle-renomme -o jsonpath='{.data.JETON_API}' | base64 -d; echo
kubectl -n colis get sealedsecret colis-scelle-renomme-strict -o json | jq -r '.status.conditions[0].message'
```

```sortie
  annotations:
    sealedsecrets.bitnami.com/namespace-wide: "true"
--
      annotations:
        sealedsecrets.bitnami.com/namespace-wide: "true"
sealedsecret.bitnami.com/colis-scelle-renomme created
sealedsecret.bitnami.com/colis-scelle-renomme-strict created
jeton-de-demonstration-46
no key could decrypt secret (JETON_API)
```

Le Secret scellé en portée `strict`, renommé, ne se déchiffre pas, pour la même raison que la copie dans `ch46`. Scellé avec `--scope namespace-wide`, il porte une annotation qui l'indique, et se déchiffre sous n'importe quel nom du namespace[^sealed]. Le risque : quelqu'un qui peut créer des `SealedSecret` dans `colis` peut y faire apparaître ce Secret sous un nom de son choix, par exemple celui qu'une autre application monte. La portée `cluster-wide` va plus loin encore, et permet de le recopier dans n'importe quel namespace. Gardez `strict` par défaut.

</details>

:::exercice[Exercice 4 : le coffre tombe]

Arrêtez Vault (`kubectl -n coffre scale deploy/vault --replicas=0`) pendant plus d'une minute. Que devient le Secret `colis-partenaire` ? Et l'`ExternalSecret` ? Redémarrez Vault : que trouvez-vous dedans, et que faut-il faire ?

:::

<details>
<summary>Corrigé</summary>

```bash
kubectl -n coffre scale deploy/vault --replicas=0
# plus d'une minute plus tard
kubectl -n colis get externalsecret colis-partenaire
kubectl -n colis get secret colis-partenaire -o jsonpath='{.data.JETON_PARTENAIRE}' | base64 -d; echo
kubectl -n colis get events --field-selector involvedObject.name=colis-partenaire,reason=UpdateFailed -o custom-columns=MESSAGE:.message | tail -1
kubectl -n coffre scale deploy/vault --replicas=1
kubectl -n coffre exec deploy/vault -- vault kv get secret/colis/api
JETON=jeton-partenaire-v2 bash externe/configurer-vault.sh
kubectl -n colis get externalsecret colis-partenaire
```

```sortie
NAME               STORETYPE     STORE   REFRESH INTERVAL   STATUS              READY   LAST SYNC
colis-partenaire   SecretStore   vault   30s                SecretSyncedError   False   73s
jeton-partenaire-v2
error processing spec.data[0] (key: colis/api), err: unable to log in to auth method: unable to log in with Kubernetes auth: Put "http://vault.coffre.svc:8200/v1/auth/kubernetes/login": dial tcp 10.98
command terminated with exit code 2
NAME               STORETYPE     STORE   REFRESH INTERVAL   STATUS         READY   LAST SYNC
colis-partenaire   SecretStore   vault   30s                SecretSynced   True    7s
```

Le Secret garde sa dernière valeur : une panne du coffre n'arrête pas les applications qui tournent, ni celles qui redémarrent. L'`ExternalSecret` passe en `SecretSyncedError`, avec un événement qui explique l'échec ; c'est ce qu'il faut surveiller (chapitre 50). Au redémarrage, `vault kv get` échoue (code 2) : le Vault de développement garde tout en mémoire, et il a tout perdu, secret, méthode d'authentification et politique. Il faut tout reconfigurer, puis External Secrets reprend sa synchronisation tout seul. Un vrai Vault stocke ses données de façon persistante, chiffrées, et tourne sur plusieurs réplicas.

</details>

## Nettoyer

Le chiffrement au repos reste actif, avec la clé `cle2` de l'exercice 1 : c'est l'état voulu pour la suite, et le défi VI le vérifiera. Le script de rejeu en recopie la configuration dans `outils/out/ch46-cle-actuelle.yaml`. Ce fichier est indispensable si vous recréez le manifeste de l'API server, et ne doit pas être commité. Pour retirer les essais :

```bash
kubectl delete namespace ch46
kubectl -n colis delete pod lecteur
kubectl -n colis delete sealedsecret colis-scelle colis-scelle-renomme
```

Vault, External Secrets et le contrôleur Sealed Secrets restent en place ; pour les retirer :

```bash
kubectl -n colis delete externalsecret colis-partenaire
kubectl -n colis delete secretstore vault
kubectl -n colis delete sa eso-colis
kubectl delete namespace coffre
kubectl delete clusterrolebinding cours-vault-tokenreview
helm uninstall external-secrets -n external-secrets
kubectl delete -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.40.0/controller.yaml
```

Pour retirer le chiffrement au repos lui-même, suivez l'ordre de l'encadré : `identity` en tête, réécriture de tous les Secrets, puis `FORCER=oui bash brancher-chiffrement.sh --retirer`.

[^secret]: Kubernetes, « Secrets » : nature des Secrets, mise à jour des Secrets montés en volume (délai égal à la période de synchronisation du kubelet plus la propagation de son cache), absence de mise à jour pour un montage en `subPath`. [kubernetes.io/docs/concepts/configuration/secret](https://kubernetes.io/docs/concepts/configuration/secret/)
[^configmap]: Kubernetes, « ConfigMaps » : « ConfigMaps consumed as environment variables are not updated automatically and require a pod restart », comportement identique pour les Secrets. [kubernetes.io/docs/concepts/configuration/configmap](https://kubernetes.io/docs/concepts/configuration/configmap/)
[^chiffrement]: Kubernetes, « Encrypting Confidential Data at Rest » : `EncryptionConfiguration`, ordre des fournisseurs, tableau des fournisseurs (secretbox jugé solide, aescbc déconseillé, aesgcm à faire tourner tous les 200 000 écritures, KMS v2 recommandé), réécriture des Secrets existants, rotation d'une clé, rechargement automatique interrogé toutes les minutes et sa métrique. [kubernetes.io/docs/tasks/administer-cluster/encrypt-data](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
[^flags]: Kubernetes, « kube-apiserver », option `--etcd-compaction-interval` (5 minutes par défaut). [kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/)
[^bonnes]: Kubernetes, « Good practices for Kubernetes Secrets », sections *Configure encryption at rest* et *Improve etcd management policies*. [kubernetes.io/docs/concepts/security/secrets-good-practices](https://kubernetes.io/docs/concepts/security/secrets-good-practices/)
[^sealed]: Bitnami, « Sealed Secrets », README : principe, portées `strict`, `namespace-wide` et `cluster-wide`, renouvellement des clés tous les 30 jours, sauvegarde des clés. [github.com/bitnami-labs/sealed-secrets](https://github.com/bitnami-labs/sealed-secrets)
[^eso]: External Secrets Operator, documentation : `SecretStore`, `ExternalSecret`, fournisseur Vault et authentification Kubernetes. [external-secrets.io](https://external-secrets.io/)
[^vault]: HashiCorp, « Kubernetes auth method » : rôles liés à des ServiceAccounts et à des namespaces, audience, vérification des jetons par TokenReview et ClusterRole `system:auth-delegator`. [developer.hashicorp.com/vault/docs/auth/kubernetes](https://developer.hashicorp.com/vault/docs/auth/kubernetes)
