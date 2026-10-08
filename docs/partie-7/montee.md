---
title: Mettre à jour un cluster
sidebar_label: 53. Mettre à jour un cluster
description: "Faire monter un cluster d'une version mineure de Kubernetes à la suivante, mesuré sur un profil minikube passé de 1.35.8 à 1.37.0 : le rythme des versions, le décalage permis entre composants, les API dépréciées et retirées, l'interruption vue par une sonde, la migration des versions stockées, et pourquoi il n'y a pas de retour arrière."
partie: 7
chapitre: '53'
---

import decalageVersions from '@site/src/figures/decalage-versions.svg';
import ordreMontee from '@site/src/figures/ordre-montee.svg';

```sortie
Client Version: v1.37.1
Server Version: v1.35.8
Warning: version difference between client (1.37) and server (1.35) exceeds the supported minor version skew of +/-1
```

Ce message de `kubectl` est une première rencontre avec une règle que tout cluster finit par imposer : les composants de Kubernetes ne supportent qu'un écart limité de versions entre eux, et un cluster qu'on ne met pas à jour sort de ces limites, puis de la période où il reçoit des correctifs de sécurité. Mettre à jour n'est donc pas une option qu'on exerce un jour de calme : c'est une opération périodique, qu'il faut savoir mener sans casser ce qui tourne. Ce chapitre la mène sur un profil minikube dédié, `montee`, de la version 1.35.8 à la 1.37.0, en mesurant à chaque étape ce qu'une application voit de l'extérieur.

Les fichiers sont dans [l'archive montee](pathname:///kits/montee.tar.gz). Le cluster principal du cours est arrêté pendant le chapitre (`minikube stop`) : les deux ensemble dépasseraient la mémoire qu'on s'autorise.

## Le rythme des versions

Kubernetes publie environ trois versions mineures par an (1.35, 1.36, 1.37...). Le projet maintient en même temps les trois dernières, et chacune reçoit environ un an de versions correctives (1.37.1, 1.37.2...), qui portent les correctifs de sécurité[^versions]. Un cluster qui reste sur la même version mineure sort donc du support au bout d'un an environ. Les distributions et les services managés suivent leur propre calendrier, souvent un peu en retard, mais la contrainte est la même : au moins une montée de version mineure par an, et plutôt trois.

La seconde contrainte est qu'on ne saute pas de version mineure. Pour aller de 1.35 à 1.37, on passe par 1.36. La raison est le décalage permis entre composants.

## Le décalage permis

Un cluster n'est jamais mis à jour d'un seul coup : pendant l'opération, des composants de versions différentes cohabitent. La politique de décalage de versions dit lesquels peuvent cohabiter[^decalage] :

<Figure svg={decalageVersions} num="53.1" alt="Pour un API server en 1.37, sur une échelle de 1.34 à 1.38 : kube-apiserver en 1.37 seulement, c'est la référence ; kube-controller-manager, kube-scheduler et cloud-controller-manager en 1.36 ou 1.37 ; kubelet de 1.34 à 1.37 ; kube-proxy de 1.34 à 1.37, avec trois versions d'écart au plus avec son kubelet ; kubectl de 1.36 à 1.38. En bas : avec plusieurs API servers, les plus récents et les plus anciens ne peuvent différer que d'une version mineure, d'où une version mineure à la fois.">
Ce qui peut cohabiter avec un API server en 1.37. Rien ne peut être plus récent que l'API server, sauf <code>kubectl</code>, d'une version.
</Figure>

Deux règles en découlent. **L'API server monte en premier** : aucun autre composant ne peut être plus récent que lui. Et **une version mineure à la fois** : avec plusieurs API servers derrière un équilibreur, pendant la montée certains sont déjà en N+1 et d'autres encore en N, et la politique ne tolère qu'une version d'écart entre eux. Le kubelet, lui, a de la marge : jusqu'à trois versions de retard, ce qui permet de faire monter les nœuds plus tard, ou de les remplacer d'une version à l'autre.

Le profil `montee`, fraîchement créé en 1.35.8, montre déjà une infraction à la règle, côté client :

```bash
kubectl version
kubectl get nodes -o custom-columns=NOEUD:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion
kubectl -n kube-system get pods -o custom-columns=IMAGE:.spec.containers[0].image --no-headers | grep -E 'kube-|etcd|coredns'
```

```sortie
Client Version: v1.37.1
Server Version: v1.35.8
Warning: version difference between client (1.37) and server (1.35) exceeds the supported minor version skew of +/-1
NOEUD    KUBELET   RUNTIME
montee   v1.35.8   containerd://2.3.4
registry.k8s.io/etcd:3.6.6-0
registry.k8s.io/kube-apiserver:v1.35.8
registry.k8s.io/kube-controller-manager:v1.35.8
registry.k8s.io/kube-scheduler:v1.35.8
```

Le `kubectl` du cours est en 1.37, deux versions au-dessus du serveur : hors de la fenêtre de plus ou moins une version. Il fonctionne, mais le projet ne teste pas cette combinaison. Le reste est cohérent : API server, contrôleur, ordonnanceur et kubelet en 1.35.8, avec etcd 3.6.6, la version que kubeadm associe à Kubernetes 1.35. (kube-proxy et CoreDNS n'ont pas encore de Pod une minute après la création du cluster : ils apparaîtront plus loin.)

## Avant de monter

<Figure svg={ordreMontee} num="53.2" alt="Cinq étapes enchaînées, puis une flèche qui revient au début pour la version mineure suivante. 0, avant : lire les notes de version, repérer les API retirées, prendre un instantané d'etcd et sa clé. 1, plan de contrôle : nœud par nœud, kubeadm upgrade, l'API server d'abord. 2, extensions : CNI, CoreDNS, kube-proxy, contrôleurs installés à part. 3, nœuds de travail, un par un : cordon, drain, kubelet, uncordon. 4, après : manifestes vers les nouvelles API, versions stockées.">
L'ordre d'une montée de version d'un cluster kubeadm, répété pour chaque version mineure.
</Figure>

### Les API qui vont disparaître

Le vrai risque d'une montée de version n'est presque jamais le cluster lui-même : ce sont les manifestes, charts et outils qui utilisent une version d'API **retirée** dans la version cible. Kubernetes retire régulièrement des versions bêta d'API, après une période de dépréciation annoncée[^deprecation]. Quelques retraits marquants :

| Version | Ce qui a été retiré | Remplacé par |
|---|---|---|
| 1.16 | Deployment, DaemonSet, ReplicaSet en `extensions/v1beta1`, `apps/v1beta1`, `apps/v1beta2` | `apps/v1` |
| 1.22 | Ingress en `networking.k8s.io/v1beta1`, CustomResourceDefinition en `apiextensions.k8s.io/v1beta1`, webhooks en `admissionregistration.k8s.io/v1beta1` | les versions `v1` |
| 1.25 | PodSecurityPolicy (`policy/v1beta1`), sans remplaçant direct ; CronJob `batch/v1beta1`, PodDisruptionBudget `policy/v1beta1` | Pod Security Admission (chapitre 44), `batch/v1`, `policy/v1` |
| 1.26 | HorizontalPodAutoscaler `autoscaling/v2beta2` | `autoscaling/v2` |
| 1.32 | FlowSchema et PriorityLevelConfiguration `flowcontrol.apiserver.k8s.io/v1beta3` | `flowcontrol.apiserver.k8s.io/v1` |

Un manifeste en version retirée est simplement refusé par le nouvel API server (`no matches for kind ... in version ...`). Les objets déjà stockés, eux, restent lisibles dans la nouvelle version : c'est l'API server qui les convertit. Pour savoir si quelqu'un utilise encore une API dépréciée sur un cluster en marche, l'API server tient une métrique, `apiserver_requested_deprecated_apis`, qui compte les requêtes reçues sur ces API, avec la version prévue pour leur retrait. Le script de rejeu interroge chaque groupe et chaque version servis, puis lit la métrique :

```bash
kubectl get --raw /metrics | grep '^apiserver_requested_deprecated_apis'
```

```sortie
{group="",removed_release="",resource="componentstatuses",subresource="",version="v1"} 1
{group="",removed_release="",resource="endpoints",subresource="",version="v1"} 1
```

Entre 1.35 et 1.37, seules deux API sont dépréciées, et aucune n'a de date de retrait (`removed_release` vide) : `componentstatuses`, qui donnait l'état du contrôleur et de l'ordonnanceur, et `endpoints`, remplacé par les EndpointSlices (chapitre 40). On le vérifiera après la montée : aucune version d'API n'a disparu.

### L'instantané

Avant de toucher au plan de contrôle, on prend un instantané d'etcd, avec le script du chapitre 52, qui accepte un autre profil :

```bash
PROFIL=montee bash sauvegarder-etcd.sh sauvegardes
```

```sortie
pas de chiffrement au repos sur ce nœud
┌──────────┬──────────┬────────────┬────────────┬─────────┐
│   HASH   │ REVISION │ TOTAL KEYS │ TOTAL SIZE │ VERSION │
├──────────┼──────────┼────────────┼────────────┼─────────┤
│ c3661d81 │      575 │        371 │     1.2 MB │   3.6.0 │
└──────────┴──────────┴────────────┴────────────┴─────────┘
sauvegardes/etcd-20261008-183614.db
```

Il n'y a pas de clé de chiffrement sur ce profil, d'où le message. Retenez la version d'etcd affichée : elle montera avec Kubernetes, et c'est l'une des raisons pour lesquelles on ne revient pas en arrière.

## Une montée de version, mesurée

Pour voir ce qu'une application perçoit, le kit déploie un témoin : trois répliques de nginx derrière un Service NodePort, avec un PodDisruptionBudget qui exige deux Pods disponibles (chapitre 33). Pendant toute la montée, `sonde.py` l'interroge toutes les 200 millisecondes et note chaque réponse.

```bash
kubectl apply -f vitrine.yaml
python3 sonde.py http://$(minikube -p montee ip):30080/ sonde-v1.36.4.log &
date +%T; time minikube start -p montee --kubernetes-version=v1.36.4; date +%T
# une fois la commande terminée : arrêter la sonde, puis
python3 sonde.py --resume sonde-v1.36.4.log
```

```sortie
18:36:18
* [montee] minikube v1.39.0 sur Ubuntu 26.04
* Kubernetes 1.37.0 est désormais disponible. Si vous souhaitez effectuer une mise à niveau, spécifiez : --kubernetes-version=v1.37.0
* Utilisation du pilote docker basé sur le profil existant
* Démarrage du nœud "montee" primary control-plane dans le cluster "montee"
* Extraction de l'image de base v0.0.51...
* Préparation de Kubernetes v1.36.4 sur containerd 2.3.4...
* Configuration de CNI (Container Networking Interface)...
* Vérification des composants Kubernetes...
  - Utilisation de l'image gcr.io/k8s-minikube/storage-provisioner:v5
* Modules activés: storage-provisioner, default-storageclass
* Terminé ! kubectl est maintenant configuré pour utiliser "montee" cluster et espace de noms "default" par défaut.
real	4m13.495s
18:40:32
589 requêtes en 276 s, 450 en échec (76.4 %), plus longue interruption : 248.8 s
  interruption de 248.8 s à partir de t+15 s
```

Un peu plus de quatre minutes pour la montée, avec l'archive préchargée de Kubernetes 1.36.4 (images et binaires) déjà en cache ; le premier essai, qui l'avait téléchargée, avait pris dix minutes. Et la sonde a vu le service s'interrompre pendant presque toute l'opération. Sur un seul nœud, minikube arrête le nœud, remplace les composants et le redémarre : tous les conteneurs du nœud redémarrent, le témoin compris, et le PodDisruptionBudget n'y peut rien. Il protège contre les **évictions** (un `drain`), pas contre l'arrêt du nœud lui-même. Les trois Pods ont le même nom qu'avant et un redémarrage de plus :

```sortie
Client Version: v1.37.1
Server Version: v1.36.4
NOEUD    KUBELET   RUNTIME
montee   v1.36.4   containerd://2.3.4
registry.k8s.io/coredns/coredns:v1.14.2
registry.k8s.io/coredns/coredns:v1.13.1
registry.k8s.io/etcd:3.6.6-0
registry.k8s.io/kube-apiserver:v1.36.4
registry.k8s.io/kube-proxy:v1.35.8
POD                        REDEMARRAGES   DEPUIS
vitrine-549cc97fd9-2xw69   1              2026-10-08T17:35:33Z
vitrine-549cc97fd9-bk2mx   1              2026-10-08T17:35:34Z
vitrine-549cc97fd9-r6g6v   1              2026-10-08T17:35:33Z
```

Deux composants n'ont pas suivi immédiatement. kube-proxy est encore en 1.35.8 au moment de la mesure : c'est un DaemonSet, que la montée met à jour ensuite, par une mise à jour progressive (chapitre 27). CoreDNS a deux Pods, l'ancien et le nouveau. Pendant ces quelques secondes, le cluster tourne avec un kube-proxy d'une version de retard, ce que la politique permet. Un instant plus tard :

```sortie
Waiting for daemon set "kube-proxy" rollout to finish: 0 out of 1 new pods have been updated...
Waiting for daemon set "kube-proxy" rollout to finish: 0 of 1 updated pods are available...
daemon set "kube-proxy" successfully rolled out
Waiting for deployment "coredns" rollout to finish: 0 of 1 updated replicas are available...
deployment "coredns" successfully rolled out
registry.k8s.io/kube-proxy:v1.36.4
```

La seconde montée, de 1.36.4 à 1.37.0, avec une archive déjà présente :

```bash
date +%T; time minikube start -p montee --kubernetes-version=v1.37.0; date +%T
python3 sonde.py --resume sonde-v1.37.0.log
```

```sortie
18:41:29
* [montee] minikube v1.39.0 sur Ubuntu 26.04
* Utilisation du pilote docker basé sur le profil existant
* Démarrage du nœud "montee" primary control-plane dans le cluster "montee"
* Extraction de l'image de base v0.0.51...
* Préparation de Kubernetes v1.37.0 sur containerd 2.3.4...
* Configuration de CNI (Container Networking Interface)...
* Vérification des composants Kubernetes...
  - Utilisation de l'image gcr.io/k8s-minikube/storage-provisioner:v5
* Modules activés: default-storageclass, storage-provisioner
* Terminé ! kubectl est maintenant configuré pour utiliser "montee" cluster et espace de noms "default" par défaut.
real	2m46.849s
18:44:16
392 requêtes en 190 s, 318 en échec (81.1 %), plus longue interruption : 174.9 s
  interruption de 174.9 s à partir de t+15 s
```

Moins de trois minutes de bout en bout cette fois, et une interruption de même nature. Sur un vrai cluster, on évite ces coupures par la redondance : plusieurs nœuds de plan de contrôle mis à jour un par un derrière un équilibreur, et des nœuds de travail vidés un par un (`kubectl drain`, qui respecte les PodDisruptionBudgets) pendant que les autres portent la charge. C'est la troisième étape de la figure 53.2, et la raison pour laquelle un service qui doit rester disponible pendant une montée a besoin d'au moins deux répliques, sur au moins deux nœuds.

```sortie
Client Version: v1.37.1
Server Version: v1.37.0
NOEUD    KUBELET   RUNTIME
montee   v1.37.0   containerd://2.3.4
registry.k8s.io/coredns/coredns:v1.14.6
registry.k8s.io/etcd:3.6.8-0
registry.k8s.io/kube-apiserver:v1.37.0
registry.k8s.io/kube-controller-manager:v1.37.0
registry.k8s.io/kube-proxy:v1.37.0
Waiting for daemon set "kube-proxy" rollout to finish: 0 of 1 updated pods are available...
daemon set "kube-proxy" successfully rolled out
Waiting for deployment "coredns" rollout to finish: 0 of 1 updated replicas are available...
deployment "coredns" successfully rolled out
registry.k8s.io/kube-proxy:v1.37.0
POD                        REDEMARRAGES   DEPUIS
vitrine-549cc97fd9-2xw69   2              2026-10-08T17:35:33Z
vitrine-549cc97fd9-bk2mx   2              2026-10-08T17:35:34Z
vitrine-549cc97fd9-r6g6v   2              2026-10-08T17:35:33Z
```

## Après la montée

### Les API servies

Le rejeu a enregistré la liste des groupes et versions servis à chaque étape (`kubectl api-versions`). Entre 1.35 et 1.37 :

```bash
diff api-1.35.txt api-1.37.txt
```

```sortie
21a22
> storagemigration.k8s.io/v1
```

Aucune version retirée, une apparue : `storagemigration.k8s.io/v1`. Les dépréciations n'ont pas bougé, et `kubectl` rappelle celle des Endpoints à chaque usage :

```sortie
Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice
NAME         ENDPOINTS                                      AGE
```

### Les versions stockées

Une montée de version ne réécrit pas les objets déjà dans etcd : chacun reste encodé dans la version d'API avec laquelle il a été écrit, et l'API server le convertit à la lecture. Le jour où une version stockée doit être retirée, ou quand on change de clé de chiffrement (chapitre 46), il faut réécrire les objets. Le chapitre 46 l'avait fait à la main, par un `kubectl replace` de chaque Secret. Kubernetes 1.37 sert l'API **StorageVersionMigration**, qui confie ce travail à un contrôleur[^svm] :

```yaml title="migration.yaml"
apiVersion: storagemigration.k8s.io/v1
kind: StorageVersionMigration
metadata:
  name: secrets-apres-1-37
spec:
  resource:
    group: ""
    resource: secrets
```

```bash
kubectl apply -f migration.yaml
kubectl get storageversionmigration secrets-apres-1-37 -o json | jq -c '{conditions: [.status.conditions[] | {type, status, reason}], resourceVersion: .status.resourceVersion}'
```

```sortie
storageversionmigration.storagemigration.k8s.io/secrets-apres-1-37 created
{"conditions":[{"type":"Running","status":"False","reason":"MigrationCompleted"},{"type":"Succeeded","status":"True","reason":"StorageVersionMigrationSucceeded"}],"resourceVersion":"1372"}
```

Le contrôleur a relu puis réécrit chaque Secret, à la version de stockage actuelle et avec la clé de chiffrement courante, jusqu'à la révision d'etcd notée dans `resourceVersion`.

## Pas de retour arrière

Et si la nouvelle version pose problème ?

```bash
minikube start -p montee --kubernetes-version=v1.36.4
```

```sortie
* [montee] minikube v1.39.0 sur Ubuntu 26.04
X Fermeture en raison de K8S_DOWNGRADE_UNSUPPORTED : Impossible de rétrograder en toute sécurité le cluster Kubernetes v1.37.0 existant vers v1.36.4
* Suggestion : 
    1) Recréez le cluster avec Kubernetes 1.36.4, en exécutant :
    minikube delete -p montee
    minikube start -p montee --kubernetes-version=v1.36.4
    2) Créez un deuxième cluster avec Kubernetes 1.36.4, en exécutant :
    minikube start -p montee2 --kubernetes-version=v1.36.4
    3) Utilisez le cluster existant à la version Kubernetes 1.37.0, en exécutant :
    minikube start -p montee --kubernetes-version=v1.37.0
code de sortie : 106
```

minikube refuse, et propose de recréer le cluster. Kubernetes lui-même ne prévoit pas de redescendre de version mineure. Les objets ont pu être réécrits dans des versions que l'ancien API server ne connaît pas (la migration ci-dessus vient de le faire), et etcd a lui aussi changé de version (de 3.6.6 à 3.6.8 ici ; un cluster créé directement en 1.37, comme le cluster principal du cours, a etcd 3.7.0). Le seul retour arrière fiable est une **restauration** : un cluster recréé dans l'ancienne version, à partir d'un instantané pris avant la montée, ou l'application redéployée depuis ses manifestes et ses sauvegardes (chapitre 52). C'est pourquoi l'instantané se prend avant, et pourquoi on monte d'abord un cluster de préproduction.

## Exercices

:::exercice[Exercice 1 : le bon ordre]

Un cluster a son plan de contrôle en 1.37 et trois groupes de nœuds : le premier en 1.37, le deuxième en 1.35, le troisième en 1.34. On veut monter le plan de contrôle en 1.38. Est-ce permis tout de suite ? Sinon, que faut-il faire d'abord, et dans quel ordre ? Et si l'équipe veut passer directement de 1.37 à 1.39 ?

:::

<details>
<summary>Corrigé</summary>

Avec un API server en 1.38, un kubelet peut avoir au plus trois versions de retard, soit 1.35 au minimum. Le troisième groupe, en 1.34, sortirait de la fenêtre. Il faut d'abord le monter en 1.35 au moins, nœud par nœud, en vidant chaque nœud (`drain`) ; sur un service managé, on remplace plutôt le groupe de nœuds par un groupe neuf dans la bonne version. Ensuite le plan de contrôle passe en 1.38 (API server d'abord, puis contrôleur et ordonnanceur), puis les extensions, puis les nœuds, à leur rythme.

Passer de 1.37 à 1.39 en une fois n'est pas permis pour le plan de contrôle : on enchaîne deux montées, 1.38 puis 1.39, avec les vérifications d'API à chaque étape. kubeadm le refuse d'ailleurs explicitement. Les nœuds, eux, peuvent attendre et sauter 1.38 : un kubelet en 1.37 reste dans la fenêtre d'un API server en 1.39 (deux versions d'écart)[^decalage].

</details>

:::exercice[Exercice 2 : les manifestes du cours face à un cluster (programmation)]

Écrivez un script Python qui parcourt un dossier de manifestes YAML (documents multiples compris), relève chaque couple `apiVersion` et `kind`, et le compare à ce que sert un cluster (`kubectl api-resources`). Le script affiche les couples absents, avec un exemple de fichier, et sort avec le code 1 s'il y en a. Lancez-le sur le dossier `kits` du cours, contre le profil `montee`.

:::

<details>
<summary>Corrigé</summary>

Le corrigé, `corrige/apis-manquantes.py`, n'est pas dans l'archive. Le point délicat est la sortie de `kubectl api-resources`, dont la colonne des abréviations est parfois vide : on lit donc la version et le type par la fin de la ligne. Les fichiers qui ne sont pas du YAML valide (les gabarits de Helm, avec leurs `{{ }}`) sont comptés à part.

```bash
python3 apis-manquantes.py kits --contexte montee
```

```sortie
384 objets lus, 25 fichiers illisibles (gabarits), 38 objets non servis par « montee »
  autoscaling.k8s.io/v1                      VerticalPodAutoscaler          1 fichier(s), ex. autoscaling/vpa-worker.yaml
  cert-manager.io/v1                         Certificate                    2 fichier(s), ex. admission/webhook/deploiement.yaml
  cert-manager.io/v1                         ClusterIssuer                  2 fichier(s), ex. http/autorite.yaml
  cert-manager.io/v1                         Issuer                         1 fichier(s), ex. admission/webhook/deploiement.yaml
  cilium.io/v2                               CiliumNetworkPolicy            1 fichier(s), ex. politiques/cilium-politique.yaml
  extensions/v1beta1                         Deployment                     1 fichier(s), ex. api/ancien.yaml
  external-secrets.io/v1                     ExternalSecret                 1 fichier(s), ex. secrets/externe/colis-vault.yaml
  external-secrets.io/v1                     SecretStore                    1 fichier(s), ex. secrets/externe/colis-vault.yaml
  gateway.networking.k8s.io/v1               Gateway                        3 fichier(s), ex. defi-4/corrige/passerelle-tls.yaml
  gateway.networking.k8s.io/v1               GatewayClass                   1 fichier(s), ex. http/passerelle.yaml
  gateway.networking.k8s.io/v1               HTTPRoute                     10 fichier(s), ex. http/colis/route-canari.yaml
  gateway.networking.k8s.io/v1               ReferenceGrant                 1 fichier(s), ex. http/colis/autorisation-vitrine.yaml
  keda.sh/v1alpha1                           ScaledObject                   1 fichier(s), ex. autoscaling/keda-worker.yaml
  kustomize.config.k8s.io/v1beta1            Kustomization                  4 fichier(s), ex. kustomize/colis/base/kustomization.yaml
  monitoring.coreos.com/v1                   PodMonitor                     1 fichier(s), ex. metriques/moniteurs.yaml
  monitoring.coreos.com/v1                   PrometheusRule                 1 fichier(s), ex. metriques/regles.yaml
  monitoring.coreos.com/v1                   ServiceMonitor                 1 fichier(s), ex. metriques/moniteurs.yaml
  monitoring.coreos.com/v1alpha1             AlertmanagerConfig             1 fichier(s), ex. metriques/alertmanager-colis.yaml
  policies.kyverno.io/v1                     GeneratingPolicy               2 fichier(s), ex. admission/corrige/refus-par-defaut-existants.yaml
  policies.kyverno.io/v1                     ValidatingPolicy               1 fichier(s), ex. admission/kyverno/limites-memoire.yaml
  snapshot.storage.k8s.io/v1                 VolumeSnapshot                 1 fichier(s), ex. stockage/instantane.yaml
code de sortie : 1
```

Une seule API retirée dans les manifestes du cours : `extensions/v1beta1` pour un Deployment, dans `api/ancien.yaml`, le fichier volontairement périmé du chapitre 34 (retiré en 1.16). Tous les autres couples absents sont des **ressources personnalisées**, définies par des CRD que le profil `montee` n'a pas (Gateway API, Prometheus Operator, KEDA, cert-manager, Kyverno...). `Kustomization` est un cas à part : c'est le fichier de configuration de Kustomize (chapitre 30), lu par l'outil et jamais envoyé à l'API. Le même script, lancé contre le cluster principal, ne signalerait plus que l'ancien Deployment, Kustomize et les outils retirés au chapitre 48. C'est le contrôle à faire avant une montée de version, contre un cluster de test dans la version cible, et aussi avant de déplacer une application vers un autre cluster. Des outils dédiés font la même chose avec la liste officielle des retraits, comme `kubent` ou `pluto`.

</details>

:::exercice[Exercice 3 : lire la sonde]

La sonde a mesuré, pour la première montée, les interruptions ci-dessous. À quoi correspond chacune ? Combien de temps l'application aurait-elle été coupée sur un cluster de trois nœuds de travail, avec trois répliques réparties et le PodDisruptionBudget du kit ?

```sortie
589 requêtes en 276 s, 450 en échec (76.4 %), plus longue interruption : 248.8 s
  interruption de 248.8 s à partir de t+15 s
```

:::

<details>
<summary>Corrigé</summary>

La longue coupure correspond à l'arrêt du nœud par minikube, au remplacement des binaires et des images, puis au redémarrage de tous les conteneurs. Le service ne revient qu'une fois kubelet, kube-proxy et le témoin de nouveau prêts. Les coupures courtes qui suivent éventuellement viennent du redémarrage de composants après coup (kube-proxy remplacé par sa mise à jour progressive, qui réécrit les règles du Service). Sur trois nœuds, le plan de contrôle se met à jour sans toucher aux Pods des nœuds de travail : le trafic vers un NodePort ou un équilibreur ne passe pas par l'API server. Puis chaque nœud de travail est vidé à son tour. Le `drain` évince ses Pods en respectant le budget (au plus une réplique indisponible sur trois), le ReplicaSet les recrée ailleurs, et le Service ne route que vers les Pods prêts. L'application ne voit alors aucune interruption, à condition que ses Pods s'arrêtent proprement (chapitre 22 : `preStop` et délai de grâce) et que ses clients réessaient une requête coupée. C'est l'exercice du chapitre 33, à refaire à chaque montée de version.

</details>

## Nettoyer

Le profil `montee` ne sert plus. On le supprime, et on redémarre le cluster principal :

```bash
minikube delete -p montee
minikube start
kubectl apply -f metallb-plage.yaml     # la plage d'adresses de MetalLB, à réappliquer (chapitre 24)
docker start registre                   # si le registre du cours est arrêté
```

Le chiffrement au repos, la limite de 5 Gio du conteneur et l'état de Colis survivent à l'arrêt.

[^versions]: Kubernetes, « Releases » et « Patch Releases » : maintien des trois dernières versions mineures, environ un an de correctifs pour chacune, cadence d'environ trois versions mineures par an. [kubernetes.io/releases](https://kubernetes.io/releases/)
[^decalage]: Kubernetes, « Version Skew Policy » : décalages permis entre kube-apiserver, kube-controller-manager, kube-scheduler, cloud-controller-manager, kubelet, kube-proxy et kubectl, ordre de montée, une version mineure à la fois pour les API servers. [kubernetes.io/releases/version-skew-policy](https://kubernetes.io/releases/version-skew-policy/)
[^deprecation]: Kubernetes, « Deprecated API Migration Guide » : API retirées version par version et leurs remplaçants ; « Kubernetes Deprecation Policy » : durées minimales de dépréciation selon le niveau de stabilité ; métrique `apiserver_requested_deprecated_apis`. [kubernetes.io/docs/reference/using-api/deprecation-guide](https://kubernetes.io/docs/reference/using-api/deprecation-guide/)
[^svm]: Kubernetes, « Migrate Kubernetes Objects Using Storage Version Migration » : ressource StorageVersionMigration, réécriture des objets à la version de stockage courante, usage après une rotation de clé de chiffrement. [kubernetes.io/docs/tasks/manage-kubernetes-objects/storage-version-migration](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/storage-version-migration/)
