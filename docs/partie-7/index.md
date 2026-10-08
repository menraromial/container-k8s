---
title: Observer et exploiter
sidebar_label: Présentation de la partie
description: Partie VII du cours. Déboguer avec méthode, reconnaître les pannes courantes, mesurer avec Prometheus et Grafana, suivre les journaux et les traces, sauvegarder et restaurer, mettre à jour un cluster.
partie: 7
plaque: Présentation
---

Jusqu'ici, chaque chapitre a construit quelque chose. Celui-ci commence le travail qui vient après : faire vivre ce qu'on a construit. Un cluster en service ne tombe pas en panne de façon spectaculaire. Un Pod redémarre trois fois par heure, une requête sur cent prend deux secondes, un disque se remplit lentement, une version de Kubernetes arrive en fin de support. Rien de tout cela ne se voit dans un `kubectl get pods` lancé au hasard. Il faut savoir où regarder quand quelque chose casse, et surtout avoir mis en place, avant, de quoi le voir venir.

La partie avance du plus immédiat au plus lointain. On commence par **l'enquête** : une méthode de diagnostic, les outils de `kubectl` pour regarder à l'intérieur des Pods et des nœuds, puis un catalogue des pannes que vous rencontrerez le plus souvent, chacune reproduite et corrigée. Viennent ensuite **les instruments** : les métriques avec Prometheus et Grafana, puis les journaux et les traces, qui permettent de suivre une requête lente d'un composant à l'autre. La partie se termine sur **l'entretien** : sauvegarder et restaurer, et mettre à jour un cluster sans le casser.

| Chapitre | Ce que vous y apprenez |
|---|---|
| [48. Déboguer](deboguer.md) | une méthode couche par couche, `describe` et les événements, journaux courants et précédents, conteneurs éphémères, copies de Pods, le nœud vu de l'intérieur |
| [49. Catalogue de pannes](pannes.md) | treize pannes reproduites et corrigées, de `Pending` au finaliseur bloqué, leur signature exacte, et un arbre de diagnostic interactif |
| [50. Les métriques](metriques.md) | kube-prometheus-stack dans 4 Gio, Colis 2.2 instrumenté, ServiceMonitor et PodMonitor, PromQL par l'exemple, centiles d'histogramme, Grafana versionné, une alerte de bout en bout |

## Avant de commencer : faire de la place

Prometheus, Grafana, Loki et les autres outils de cette partie demandent de la mémoire, et le nœud minikube n'en a que 4 Gio. Or les parties précédentes en ont laissé beaucoup en place : des namespaces d'essai, trois copies de Colis, Kyverno, Vault, External Secrets, Sealed Secrets, le VPA, le canari du chapitre 28. Avant de continuer, on retire tout ce dont la suite ne se sert plus. Le script de [l'archive menage-7](pathname:///kits/menage-7.tar.gz) le fait, objet par objet, chacun désigné par son nom :

```bash
tar -xzf menage-7.tar.gz && cd menage-7
less faire-de-la-place.sh      # lisez-le avant de le lancer
bash faire-de-la-place.sh
```

Ce qui reste, et servira encore : Colis durci dans le namespace `colis`, sa politique d'images `images-colis` (chapitre 45), le chiffrement au repos (chapitre 46), cert-manager, Envoy Gateway et la passerelle `principale`, MetalLB, KEDA et metrics-server. Le script supprime aussi les volumes persistants à l'état `Released`, dont la réclamation a disparu : si vous en gardez un exprès, retirez cette dernière étape.

Sur le cluster du cours, la mémoire occupée par le nœud est passée de 3,5 Gio à 2,6 Gio, puis à 2,2 Gio après un redémarrage de l'API server. Celui-ci garde en mémoire un cache de chaque type de ressource, et 50 des 83 définitions de ressources (CRD) venaient de disparaître ; il ne rend pas au système la mémoire ainsi libérée, un redémarrage la récupère. Le kubelet le relance tout seul quand on arrête son conteneur :

```bash
docker stats --no-stream minikube --format '{{.MemUsage}}'
minikube ssh -- 'sudo crictl stop $(sudo crictl ps --name kube-apiserver -q)'
```

Désormais, chaque chapitre se termine en retirant ce qu'il a installé et dont la suite n'a pas besoin. Gardez l'habitude : un cluster de travail encombré d'expériences oubliées finit par ressembler à un cluster de production mal tenu.
