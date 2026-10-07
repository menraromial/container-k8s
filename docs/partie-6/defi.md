---
title: Défi VI, l'audit de sécurité
sidebar_label: Défi VI
description: "Une copie de Colis déployée vite, « pour tester », dans un namespace colis-audit : la trouver en défaut avec les outils de la partie VI, expliquer chaque écart et son risque, puis la corriger jusqu'à ce que la grille passe, sans casser l'application."
partie: 6
plaque: Défi VI
---

Vendredi, 17 h. Une équipe a déployé une copie de Colis dans le namespace `colis-audit`, pour tester une fonctionnalité avec un partenaire. Ça marche, le partenaire est content, et l'équipe voudrait la garder telle quelle. Avant de dire oui, la responsable de la sécurité vous demande un audit : qu'est-ce qui, dans ce déploiement, contredit les règles appliquées au vrai Colis tout au long de cette partie ? Pour chaque écart, quel est le risque ? Et pouvez-vous le corriger d'ici lundi sans rien casser ?

Le défi consiste à mener cet audit, puis la correction. Tous les outils nécessaires ont été écrits dans les chapitres 42 à 47 : il s'agit de s'en servir, de lire leurs résultats avec un œil critique, et de corriger sans interrompre l'application.

## Le point de départ

Le cluster principal, tel que le chapitre 47 l'a laissé : chiffrement au repos actif, Kyverno et ses politiques d'images, la politique d'images CEL du chapitre 45. Le fichier `colis-audit.yaml` de [l'archive defi-6](pathname:///kits/defi-6.tar.gz) déploie la copie à auditer, avec une réplique de chaque composant, sans worker :

```bash
kubectl apply -f colis-audit.yaml
kubectl -n colis-audit get pods
```

```sortie
namespace/colis-audit created
configmap/colis-config created
rolebinding.rbac.authorization.k8s.io/equipe-et-robots created
secret/jeton-ci created
deployment.apps/postgres created
service/postgres created
deployment.apps/redis created
service/redis created
deployment.apps/api created
service/api created
deployment.apps/web created
service/web created
NAME                        READY   STATUS    RESTARTS      AGE
api-599b8fbc4f-b4g8q        1/1     Running   1 (12s ago)   15s
postgres-5cb4548d4f-sr2cv   1/1     Running   0             15s
redis-5877dd98cd-rvks5      1/1     Running   0             15s
web-5747f79d7f-5qljl        1/1     Running   0             15s
```

Lisez le manifeste, mais ne vous en contentez pas : un audit part de ce qui tourne, pas de ce qui est écrit. Le déploiement n'a pas d'adresse externe ; pour tester l'application, `kubectl -n colis-audit port-forward svc/web 18080:80`, puis `http://127.0.0.1:18080`.

## Le cahier des charges

1. **L'audit.** Dressez la liste des écarts, chacun avec : ce que vous avez observé (la commande et sa sortie), le risque concret qu'il fait courir, et le chapitre qui traite le sujet. Utilisez les outils de la partie plutôt que la lecture du manifeste : `niveau-pss.py` (chapitre 44), `qui-peut.py` et `auditer-rbac.py` (chapitre 43), `inventaire-images.py` (chapitre 47), `audit-chiffrement.py` (chapitre 46), les rapports de Kyverno (chapitre 45), `kubectl auth can-i` et une sonde réseau (chapitre 41).
2. **La correction.** Corrigez tous les écarts, en modifiant le moins de choses possible, et sans jamais casser l'application : la page doit répondre et l'API doit pouvoir créer un colis.
3. **Une contrainte.** Aucun secret ne doit apparaître en clair dans un fichier que vous pourriez versionner.

Il y a au moins neuf écarts. La grille ci-dessous en vérifie neuf, plus le fonctionnement de l'application ; votre rapport peut en trouver d'autres.

## La grille

La grille est un script, `verifier.sh`, qui prend le namespace en paramètre, et la clé publique cosign du chapitre 14 dans la variable `CLE_PUBLIQUE`. Sur la copie telle qu'elle est livrée :

```bash
CLE_PUBLIQUE=cosign.pub ./verifier.sh colis-audit
```

```sortie
ÉCHEC   1. étiquettes du namespace (Pod Security, images) : manquent pod-security.kubernetes.io/enforce cours/politique-images cours/images-signees cours/analyse-exigee 
ÉCHEC   2. Pods conformes au niveau restricted (2 avertissement(s))
ÉCHEC   3. mot de passe hors des ConfigMaps (trouvé : POSTGRES_PASSWORD), dans le Secret ?, chiffré dans etcd
ÉCHEC   4. ServiceAccounts sans droit sur les Secrets ni les Pods (trop : default:get-secrets default:create-pods )
ÉCHEC   5. aucun jeton de ServiceAccount monté (dans : api-599b8fbc4f-b4g8q,postgres-5cb4548d4f-sr2cv,redis-5877dd98cd-rvks5,web-5747f79d7f-5qljl)
ÉCHEC   6. aucun jeton de Secret sans expiration (trouvé : secret/jeton-ci )
ÉCHEC   7. base, Redis et API injoignables depuis un autre namespace (ouverts : postgres:5432 redis:6379 api:8000 )
ÉCHEC   8. images signées et analysées sans faille grave (en défaut : host.minikube.internal:5001/colis/web:1.0(analyse:2) )
ÉCHEC   9. limites mémoire partout (manquent : postgres-5cb4548d4f-sr2cv/postgres,redis-5877dd98cd-rvks5/redis)
OK      10. l'application répond (santé : ok, colis créé et relu : 1)

1 vérification(s) réussie(s), 9 en échec
```

L'objectif : dix `OK`. La grille donne les écarts, mais pas les risques, ni l'ordre dans lequel les corriger. C'est le cœur du travail. Lisez aussi le script : chaque vérification est une façon de mesurer, que vous pourrez réutiliser.

## Indices

Ouvrez-les un par un, seulement si vous êtes bloqué.

<details>
<summary>Indice 1 : les outils ont leurs angles morts</summary>

Un outil d'audit ne trouve que ce qu'on lui a appris à chercher, et vous avez écrit plusieurs de ceux de cette partie. Relisez les options de `auditer-rbac.py` : que fait-il par défaut des sujets dont le nom commence par `system:` ? Et quel est le nom complet du groupe qui réunit tous les ServiceAccounts d'un namespace (chapitre 42) ?

</details>

<details>
<summary>Indice 2 : l'ordre des corrections</summary>

Certaines corrections en conditionnent d'autres. Imposer `restricted` au namespace avant d'avoir durci les gabarits ne casse rien tout de suite, mais bloque le prochain redémarrage. Exiger une analyse sans faille grave avant d'avoir remplacé l'image vulnérable bloque le site. Pensez au Deployment accepté dont les Pods sont refusés (chapitre 44).

</details>

<details>
<summary>Indice 3 : ce qu'un apply ne retire pas</summary>

Un `kubectl apply` d'un manifeste corrigé met à jour les objets qu'il contient, mais ne supprime pas ceux qui n'y figurent plus. Une liaison RBAC ou un jeton qu'on retire du fichier restent dans le cluster.

</details>

<details>
<summary>Indice 4 : le mot de passe</summary>

Le mot de passe de PostgreSQL a vécu en clair dans une ConfigMap, lisible par quiconque peut lire les ConfigMaps du namespace, ce que `view` permet (chapitre 43). Le déplacer dans un Secret ne suffit pas : il faut aussi le changer. Et pour que le nouveau ne se retrouve pas dans un fichier versionné, créez le Secret par une commande, ou passez par Sealed Secrets ou External Secrets (chapitre 46).

</details>

## Corrigé

Ne l'ouvrez qu'après avoir essayé. Le corrigé est dans le dépôt du cours, sous `kits/defi-6/corrige` : le manifeste corrigé `colis-audit-corrige.yaml` et le script `corriger.sh`.

<details>
<summary>Voir le corrigé commenté</summary>

### L'audit

**Pod Security.** L'outil du chapitre 44 classe le namespace au niveau `baseline` : aucun Pod ne demande l'accès à l'hôte, mais aucun n'est durci.

```sortie
namespace              Pods  enforce      warn         niveau atteint
colis-audit               4  -            -            baseline        <- prêt pour enforce=baseline
Warning: api-599b8fbc4f-b4g8q (and 3 other pods): allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile
```

Risque : un conteneur compromis tourne en root (PostgreSQL, Redis et nginx démarrent en root), avec les capabilities par défaut et sans filtre seccomp. Le namespace n'a aucune étiquette : rien n'empêche demain un Pod privilégié.

**RBAC.** Qui peut lire les Secrets du namespace, en dehors des administrateurs et des contrôleurs ?

```sortie
Group system:serviceaccounts:colis-audit              RoleBinding equipe-et-robots -> edit                                                                namespace colis-audit 
ServiceAccount external-secrets/external-secrets      ClusterRoleBinding external-secrets-controller                                                      tout le cluster       
```

(Sortie de `qui-peut.py get secrets colis-audit`, dont on a retiré les lignes déjà vues au chapitre 43 : administrateurs, cert-manager, KEDA, Envoy, contrôleurs du système.) La liaison `equipe-et-robots` donne `edit` au **groupe de tous les ServiceAccounts du namespace**. Chaque Pod de Colis, avec son jeton monté, peut donc lire tous les Secrets du namespace, créer des Pods, et emprunter l'identité de n'importe quel compte (chapitre 43). Une seule faille dans l'API ou dans nginx suffit pour tout obtenir. On remarque au passage le contrôleur d'External Secrets, installé au chapitre 46, qui lit les Secrets de tout le cluster.

L'outil d'audit du chapitre 43, lui, ne voit **rien**, et c'est instructif :

```sortie
--- auditer-rbac.py (sans --tout)
0
--- auditer-rbac.py --tout
Group system:serviceaccounts:colis-audit
   - agir sous une autre identité, dans colis-audit (RoleBinding equipe-et-robots)
   - créer des Jobs, dans colis-audit (RoleBinding equipe-et-robots)
   - créer des Pods, dans colis-audit (RoleBinding equipe-et-robots)
   - créer des charges de travail, dans colis-audit (RoleBinding equipe-et-robots)
   - exec ou attach dans les Pods, dans colis-audit (RoleBinding equipe-et-robots)
   - lire les Secrets, dans colis-audit (RoleBinding equipe-et-robots)
   - émettre des jetons de ServiceAccount, dans colis-audit (RoleBinding equipe-et-robots)
```

Par défaut, il omet les sujets dont le nom commence par `system:`, pour ne pas noyer le rapport sous les composants de Kubernetes. Le groupe en cause s'appelle justement `system:serviceaccounts:colis-audit`. Un filtre pensé pour réduire le bruit a caché le résultat le plus grave : un audit ne vaut que ce que valent ses filtres.

**Jetons.** Un ancien jeton de Secret, sans date d'expiration (chapitre 42) :

```sortie
NAME       TYPE                                  DATA   AGE
jeton-ci   kubernetes.io/service-account-token   3      24s
{"sub":"system:serviceaccount:colis-audit:default","exp":null}
```

Il donne, pour toujours, les droits du compte `default`, c'est-à-dire `edit` sur le namespace. Et la grille a montré que les quatre Pods reçoivent un jeton d'API dont aucun n'a besoin.

**Secrets.** Le mot de passe de PostgreSQL est dans la ConfigMap :

```sortie
{"COLIS_PURGE_JOURS":"30","COLIS_REDIS":"redis://redis:6379/0","COLIS_VERSION":"2.1.0","POSTGRES_PASSWORD":"colis-audit-2026"}
```

Une ConfigMap n'est pas chiffrée au repos (seuls les Secrets le sont, chapitre 46), et `view` permet de la lire (chapitre 43). Ce mot de passe doit être considéré comme connu.

**Réseau.** Aucune NetworkPolicy (`No resources found`), et la grille confirme qu'un Pod de n'importe quel namespace joint PostgreSQL, Redis et l'API (chapitre 41).

**Images.** L'inventaire du chapitre 47 :

```sortie
host.minikube.internal:5001/colis/api:2.1
    signée                   1 MEDIUM (analyse du 2026-10-07)  [colis, colis-audit]
--
host.minikube.internal:5001/colis/web:1.0
    signée                   2 HIGH, 3 MEDIUM (analyse du 2026-10-07)  [colis-audit]
```

Le site tourne avec `web:1.0`, dont l'analyse signée signale deux failles de sévérité élevée, corrigées dans `web:1.1`. Le namespace n'est soumis à aucune des politiques d'images des chapitres 45 et 47.

**Ressources.** Les rapports de la politique Kyverno `limites-memoire` du chapitre 45, qui juge l'existant :

```sortie
Deployment/api       pass=1  fail=0  
Deployment/postgres  pass=0  fail=1  conteneurs sans limite mémoire : postgres
Deployment/redis     pass=0  fail=1  conteneurs sans limite mémoire : redis
Deployment/web       pass=1  fail=0  
```

Sans limite, une fuite de mémoire de PostgreSQL ou de Redis peut affamer tout le nœud (chapitre 23), et cela vaut aussi pour un conteneur compromis.

### La correction

L'ordre suit l'indice 2 : d'abord supprimer ce qui donne des droits, ensuite déployer des gabarits conformes, et poser les étiquettes du namespace dans le même mouvement. Les nouveaux Pods sont conformes, et les anciens, qui ne le sont pas, ne sont pas touchés par `enforce` : ils disparaissent avec le déploiement.

`corriger.sh` fait les trois choses qu'un `apply` ne fait pas (indice 3) : supprimer la liaison et le jeton, et créer le Secret avec un **nouveau** mot de passe, tiré au hasard, sans qu'il apparaisse dans aucun fichier.

```bash title="corrige/corriger.sh (extrait)"
kubectl -n $NS delete rolebinding equipe-et-robots --ignore-not-found
kubectl -n $NS delete secret jeton-ci --ignore-not-found
# nouveau mot de passe : l'ancien a vécu en clair dans une ConfigMap, il est compromis
kubectl -n $NS create secret generic colis-db --from-literal=POSTGRES_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f $D/colis-audit-corrige.yaml
```

Le manifeste corrigé reprend, composant par composant, ce que les chapitres ont appliqué au vrai Colis : les réglages de sécurité du chapitre 44 (utilisateurs 70, 999, 10001 et 101, racine en lecture seule, `emptyDir` pour ce qui doit s'écrire), `automountServiceAccountToken: false`, des limites mémoire partout, `web:1.1`, et six NetworkPolicies : refus par défaut, DNS, puis exactement les flux web vers API, API vers PostgreSQL et Redis. Le namespace reçoit ses étiquettes :

```yaml title="corrige/colis-audit-corrige.yaml (extrait)"
apiVersion: v1
kind: Namespace
metadata:
  name: colis-audit
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.37
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.37
    cours/politique-images: "oui"
    cours/images-signees: "oui"
    cours/analyse-exigee: "oui"
```

```bash
bash corrige/corriger.sh
CLE_PUBLIQUE=cosign.pub ./verifier.sh colis-audit
```

```sortie
rolebinding.rbac.authorization.k8s.io "equipe-et-robots" deleted from colis-audit namespace
secret "jeton-ci" deleted from colis-audit namespace
secret/colis-db created
Warning: existing pods in namespace "colis-audit" violate the new PodSecurity enforce level "restricted:v1.37"
Warning: api-599b8fbc4f-b4g8q (and 3 other pods): allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile
namespace/colis-audit configured
configmap/colis-config configured
deployment.apps/postgres configured
deployment.apps/redis configured
deployment.apps/api configured
deployment.apps/web configured
networkpolicy.networking.k8s.io/refus-par-defaut created
networkpolicy.networking.k8s.io/dns created
networkpolicy.networking.k8s.io/web created
networkpolicy.networking.k8s.io/api created
networkpolicy.networking.k8s.io/postgres created
networkpolicy.networking.k8s.io/redis created
deployment "postgres" successfully rolled out
deployment "redis" successfully rolled out
deployment "api" successfully rolled out
deployment "web" successfully rolled out
OK      1. étiquettes du namespace (Pod Security, images) 
OK      2. Pods conformes au niveau restricted (0 avertissement(s))
OK      3. mot de passe hors des ConfigMaps, dans le Secret colis-db, chiffré dans etcd
OK      4. ServiceAccounts sans droit sur les Secrets ni les Pods
OK      5. aucun jeton de ServiceAccount monté
OK      6. aucun jeton de Secret sans expiration
OK      7. base, Redis et API injoignables depuis un autre namespace
OK      8. images signées et analysées sans faille grave
OK      9. limites mémoire partout
OK      10. l'application répond (santé : ok, colis créé et relu : 1)

10 vérification(s) réussie(s), 0 en échec
```

L'avertissement de Pod Security au moment de l'`apply` est attendu : il signale les anciens Pods, qui sont remplacés dans la foulée. La ConfigMap a perdu sa clé `POSTGRES_PASSWORD` sans qu'on la supprime : `kubectl apply` retire les champs qu'il avait lui-même posés et qui ont disparu du fichier. Le contrôle 3 vérifie au passage que le nouveau Secret est bien chiffré dans etcd, grâce à la configuration du chapitre 46. Et l'application répond toujours : PostgreSQL a redémarré avec une base vide (`emptyDir`) et le nouveau mot de passe, ce qui est acceptable pour une copie de test, et serait à préparer avec soin pour une vraie base.

### Ce que la grille ne vérifie pas

Un bon rapport va au-delà de la grille. Trois remarques qu'on attend :

- PostgreSQL stocke ses données dans un `emptyDir` : chaque redémarrage efface la base. C'est un défaut de fiabilité plus que de sécurité, mais une copie « gardée telle quelle » doit avoir un volume persistant (chapitre 26).
- La copie n'a ni PodDisruptionBudget, ni plusieurs réplicas (chapitre 33).
- L'audit a révélé un défaut dans un outil du cours lui-même, le filtre par défaut de `auditer-rbac.py`. Le signaler fait partie du travail.

</details>

## Et maintenant

Colis est désormais authentifié, autorisé, durci, filtré à l'admission, ses secrets sont chiffrés et ses images vérifiées. Il reste à le faire vivre. La partie VII passe de l'autre côté : observer ce qui se passe, comprendre ce qui casse, mesurer, tracer, sauvegarder, et mettre le cluster à jour sans tout interrompre. Plusieurs des pannes de cette partie (un webhook injoignable, un registre arrêté, une clé de chiffrement perdue) y serviront de cas d'école.

Pour faire le ménage du défi :

```bash
kubectl delete namespace colis-audit
```

La grille crée et supprime elle-même son namespace de sonde, `defi6-sonde`.
