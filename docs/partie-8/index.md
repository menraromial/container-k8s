---
title: Étendre Kubernetes et livrer
sidebar_label: Présentation de la partie
description: Partie VIII du cours. Ajouter ses propres types à l'API, écrire un opérateur en Go, utiliser un opérateur existant pour PostgreSQL, livrer en GitOps avec Argo CD, déployer progressivement, chiffrer et observer le trafic avec un service mesh, partager un cluster entre plusieurs équipes.
partie: 8
plaque: Présentation
---

Plus d'un tiers des types d'objets que sert le cluster du cours n'existaient pas quand Kubernetes a été installé : ils sont arrivés avec Gateway API, cert-manager, KEDA, l'opérateur Prometheus. Kubernetes est conçu pour cela. Son API accepte de nouveaux types, et le modèle de contrôleur des chapitres 15 et 36 (lire l'état voulu, comparer à l'état réel, agir) s'applique à n'importe quel objet. Cette partie s'en sert de deux façons.

Les trois premiers chapitres étendent Kubernetes. On déclare d'abord un type `Colis` qui décrit une installation complète de l'application, avec son schéma, ses règles de validation et ses versions. On écrit ensuite, en Go avec kubebuilder, l'opérateur qui transforme un objet `Colis` en Deployments, Services et volumes, et qui le maintient dans cet état. Puis on confie la base de données à un opérateur écrit par d'autres, CloudNativePG, qui sait faire ce qu'un StatefulSet ne sait pas : bascule, sauvegarde continue, mise à jour sans perte.

Les quatre suivants portent sur la livraison. Argo CD applique au cluster ce que contient un dépôt Git, et signale toute dérive. Argo Rollouts remplace la mise à jour progressive d'un Deployment par un déploiement canari piloté par les métriques. Un service mesh, Linkerd, chiffre le trafic entre les Pods et mesure chaque requête sans toucher au code. Le dernier chapitre partage un cluster entre plusieurs équipes, avec des namespaces, des quotas et des clusters virtuels.

| Chapitre | Ce que vous y apprenez |
|---|---|
| [54. Les CRD](crd.md) | une CustomResourceDefinition pour le type `Colis` : schéma, élagage et valeurs par défaut, règles CEL et leurs pièges, sous-ressources `status` et `scale`, versions et migration du stockage, RBAC agrégé, coût d'une définition |
| [55. Écrire un opérateur](operateur.md) | un opérateur en Go avec kubebuilder : projet généré, marqueurs, boucle de réconciliation, références de propriétaire, le piège des réécritures mesuré, dérive corrigée, tests envtest, image distroless, déploiement et métriques |
| [56. CloudNativePG](cnpg.md) | PostgreSQL confié à un opérateur : trois instances sans StatefulSet, deux bascules et l'arrêt intelligent mesurés, sauvegarde continue et restauration à la seconde, puis la base de Colis migrée avec 55 secondes de maintenance |
| [57. GitOps avec Argo CD](gitops.md) | un dépôt Gitea dans le cluster, Argo CD, synchronisation manuelle puis automatique, sondage de 3 minutes et webhook de 1 seconde, dérive et attente exponentielle mesurée, élagage, conflit avec un HPA, App of Apps et suppression en cascade |

## Avant de commencer : faire de la place

Les chapitres de cette partie installent un opérateur, Argo CD, Argo Rollouts et un service mesh, et chacun demande quelques centaines de mégaoctets. Une partie des outils de la partie VII ne sert plus : Loki, Tempo et le collecteur OpenTelemetry, que plus aucun chapitre n'interroge, et Grafana. Prometheus, Alertmanager et le petit récepteur `pager` restent en place, parce que le chapitre 58 décidera de la suite d'un déploiement d'après des métriques.

Le script de [l'archive menage-8](pathname:///kits/menage-8.tar.gz) retire ces outils un par un, par leur nom. Il retire aussi de l'API et du worker de Colis les trois variables `OTEL_*` du chapitre 51 : sans adresse de collecteur, Colis ne charge plus l'exportateur de traces.

```bash
tar -xzf menage-8.tar.gz && cd menage-8
less faire-de-la-place.sh      # lisez-le avant de le lancer
bash faire-de-la-place.sh
```

```sortie
deployment.apps/api env updated
deployment.apps/worker env updated
networkpolicy.networking.k8s.io "traces" deleted from colis namespace
configmap "tableau-colis" deleted from colis namespace
release "collecteur" uninstalled
release "tempo" uninstalled
release "loki" uninstalled
persistentvolumeclaim "storage-loki-0" deleted from supervision namespace
persistentvolumeclaim "storage-tempo-0" deleted from supervision namespace
Pulled: ghcr.io/prometheus-community/charts/kube-prometheus-stack:92.1.0
...
Release "supervision" has been upgraded. Happy Helming!
...
persistentvolume "pvc-723b756f-9229-4d3f-b055-027151455481" deleted
persistentvolume "pvc-acee9622-952d-48eb-b12b-e31b97a821be" deleted
```

Les notes qu'affiche Helm à la fin de la mise à jour parlent encore de Grafana : c'est un texte fixe du chart, qui ne tient pas compte des valeurs. Sur le cluster du cours, la mémoire occupée par le nœud est passée de 4,09 Gio à 3,61 Gio, et le namespace `supervision` de 1 551 Mio à 721 Mio (somme de `kubectl top pods`, une minute et demie après le ménage) :

```bash
docker stats --no-stream minikube --format '{{.MemUsage}}'
kubectl -n supervision get pods
```

```sortie
3.612GiB / 5GiB
NAME                                                     READY   STATUS    RESTARTS       AGE
alertmanager-supervision-kube-prometheu-alertmanager-0   2/2     Running   2 (123m ago)   13h
pager-846797c59b-mwz7m                                   1/1     Running   1 (123m ago)   13h
prometheus-supervision-kube-prometheu-prometheus-0       2/2     Running   3 (123m ago)   13h
supervision-kube-prometheu-operator-76d74945df-t7xqf     1/1     Running   9 (123m ago)   13h
supervision-kube-state-metrics-c46cdbdbb-kb2t6           1/1     Running   9 (123m ago)   13h
supervision-prometheus-node-exporter-l9f2p               1/1     Running   7 (123m ago)   13h
```

Le chapitre 55 a besoin en plus de Go (version 1.26 ou plus récente) et de kubebuilder sur le poste ; il en détaille l'installation.
