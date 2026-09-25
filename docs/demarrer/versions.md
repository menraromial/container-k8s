---
title: Versions utilisées
sidebar_label: Versions utilisées
description: Les versions exactes des outils du cours, la règle de décalage de versions de Kubernetes, et ce qu'il faut savoir pour suivre le cours avec des versions plus récentes.
partie: 0
chapitre: '0.3'
---

import decalageVersions from '@site/src/figures/decalage-versions.svg';

En mai 2022, Kubernetes 1.24 a retiré le « dockershim », le morceau de code qui permettait au kubelet de faire tourner des conteneurs par l'intermédiaire de Docker. L'annonce, faite dix-huit mois plus tôt, avait déclenché une petite panique : beaucoup ont compris que Kubernetes « abandonnait Docker » et que leurs images ne fonctionneraient plus. Le projet avait dû publier un billet intitulé *Don't Panic* pour expliquer que les images construites avec Docker resteraient parfaitement utilisables, et que seul changeait l'outil qui les lance sur les nœuds[^dockershim]. Le minikube de ce cours en est l'héritier direct : son nœud utilise containerd, pas Docker.

Cet épisode résume bien pourquoi cette page existe. L'écosystème des conteneurs bouge vite : des fonctions apparaissent, d'autres disparaissent, des projets entiers sont archivés. Un cours qui ne dit pas avec quelles versions il a été écrit devient faux sans prévenir. Voici donc les versions exactes, la règle qui dit lesquelles peuvent cohabiter, et ce qu'il faut savoir si vous suivez le cours avec des versions plus récentes.

## Les versions du cours

Toutes les commandes de ce cours ont été exécutées avec les versions suivantes :

| Outil | Version | Rôle | Vérifier avec |
|---|---|---|---|
| Docker Engine | 29.3.1 | moteur de conteneurs du poste | `docker version` |
| minikube | 1.39.0 | fabrique le cluster local | `minikube version` |
| Kubernetes (cluster) | 1.37.0 | version du plan de contrôle et du kubelet | `kubectl version` |
| kubectl | 1.37.1 | client en ligne de commande | `kubectl version --client` |
| containerd (dans le nœud) | 2.3.4 | lance les conteneurs du cluster | `minikube ssh -- containerd --version` |
| runc (dans le nœud) | 1.4.3 | crée chaque conteneur à la demande de containerd | `minikube ssh -- runc --version` |
| Helm | 4.3.0 | gestionnaire de paquets, à partir du chapitre 29 | `helm version` |
| Headlamp | 0.45.0 | interface graphique, addon de minikube | `kubectl -n headlamp get deploy -o wide` |

Sur une machine installée comme au chapitre précédent, les quatre commandes principales donnent :

```bash
minikube version
kubectl version
helm version
docker version --format '{{.Server.Version}}'
```

```sortie
minikube version: v1.39.0
commit: 7a9f6a841470a207de8cf4bafcccee0969d8ba10
Client Version: v1.37.1
Kustomize Version: v5.8.1
Server Version: v1.37.0
version.BuildInfo{Version:"v4.3.0", GitCommit:"bec5b06ed841fe5269972d864d5177944fd5970f", GitTreeState:"clean", GoVersion:"go1.27.1", KubeClientVersion:"v1.37"}
29.3.1
```

Vous avez peut-être remarqué que kubectl est en 1.37.1 et le cluster en 1.37.0. Ce n'est pas un oubli. La version 1.37.1 de Kubernetes est sortie après minikube 1.39.0, qui ne sait donc pas encore la démarrer. Demandez-lui la liste de celles qu'il connaît :

```bash
minikube config defaults kubernetes-version
```

```sortie
* v1.37.0
* v1.37.0-rc.1
* v1.37.0-rc.0
* v1.37.0-beta.0
* v1.37.0-alpha.3
* v1.37.0-alpha.2
* v1.37.0-alpha.1
* v1.36.4
...
```

La plus récente est 1.37.0 ; c'est celle que le cours fige avec `--kubernetes-version=v1.37.0`. Les versions marquées `alpha`, `beta` et `rc` sont des préversions, destinées aux tests du projet : ne les utilisez pas pour suivre le cours. Quant à l'écart entre 1.37.0 et 1.37.1, il est sans conséquence, pour une raison que la section suivante explique.

Les chapitres des parties IV à VIII installeront d'autres outils dans le cluster : cert-manager, Kyverno, CloudNativePG, Argo CD, Cilium, Prometheus, et d'autres. Leur version est indiquée dans le chapitre qui les introduit, au moment où il est écrit et éprouvé. Le tableau en fin de page donne les versions relevées aujourd'hui, à titre indicatif.

## Comment se lit un numéro de version

Kubernetes numérote ses versions en trois parties, selon la convention du *semantic versioning* : dans `1.37.1`, le `1` est la version majeure, le `37` la version mineure et le dernier `1` la version de correctif[^semver].

La version majeure n'a jamais changé depuis la sortie de Kubernetes 1.0 en 2015. Les versions mineures sortent trois fois par an et apportent les nouveautés : la 1.37 est sortie le 26 août 2026, la 1.36 le 22 avril, la 1.35 en décembre 2025[^releases]. Les versions de correctif, elles, sortent environ une fois par mois et ne contiennent que des corrections de bogues et de failles de sécurité, sans rien changer au comportement. Passer de 1.37.0 à 1.37.1 ne change donc aucune commande du cours.

Chaque version mineure est maintenue environ quatorze mois : douze mois de correctifs réguliers, puis deux mois pendant lesquels seules les failles graves sont corrigées[^releases]. La 1.37 recevra des correctifs jusqu'au 28 octobre 2027. Au même moment, le projet maintient donc les trois dernières versions mineures ; au-delà, un cluster n'a plus de correctifs de sécurité, et c'est l'une des raisons pour lesquelles les entreprises mettent régulièrement leurs clusters à jour. Le chapitre 53 montre comment on fait.

## Qui peut parler à qui : le décalage de versions

Un cluster Kubernetes n'est pas un programme unique mais une dizaine de composants qui dialoguent entre eux, et ils ne sont pas toujours tous à la même version. Pendant une mise à jour, par exemple, on met d'abord à jour l'API server, puis les autres composants, puis les nœuds un par un : pendant quelques heures, des versions différentes coexistent. Le projet définit donc une règle précise, la *version skew policy*, qui dit quelles combinaisons il garantit[^skew].

<Figure svg={decalageVersions} num="0.4" alt="Pour un API server en 1.37 : kubectl est pris en charge en 1.36, 1.37 et 1.38 ; le kubelet en 1.34, 1.35, 1.36 et 1.37, jamais plus récent que l'API server.">
Les combinaisons prises en charge quand l'API server est en version 1.37. Toutes les règles se définissent par rapport à l'API server, le seul composant auquel les autres parlent.
</Figure>

Pour kubectl, la règle est symétrique : une version mineure d'écart, dans un sens ou dans l'autre. Avec un cluster en 1.37, un kubectl 1.36, 1.37 ou 1.38 est garanti. Au-delà, kubectl vous prévient :

```sortie
Client Version: v1.35.8
Kustomize Version: v5.7.1
Server Version: v1.37.0
Warning: version difference between client (1.35) and server (1.37) exceeds the supported minor version skew of +/-1
```

Cette sortie a été obtenue avec un kubectl 1.35 face au cluster du cours. Remarquez que ce n'est qu'un avertissement : la commande fonctionne, et la plupart des suivantes aussi. C'est justement ce qui rend le problème difficile à diagnostiquer. Un kubectl trop ancien ne connaît pas les champs apparus depuis sa version ; selon les cas, il les ignore ou affiche l'objet de façon incomplète, sans message d'erreur. Si une commande du cours ne donne pas le résultat attendu, vérifiez d'abord `kubectl version`.

Pour le kubelet, l'agent qui tourne sur chaque nœud, la règle est asymétrique : il peut avoir jusqu'à trois versions mineures de retard sur l'API server, mais jamais d'avance. La raison est simple : un kubelet plus récent pourrait envoyer à l'API server des champs que celui-ci ne connaît pas encore. Dans minikube, la question ne se pose pas, puisque tous les composants sont installés ensemble à la même version. Elle se posera au chapitre 53, quand nous mettrons un cluster à jour.

## Ce qui change d'une version à l'autre

Chaque version mineure ajoute des fonctions, en fait mûrir d'autres, et en retire quelques-unes. Les nouveautés passent par trois stades : *alpha* (désactivée par défaut, peut disparaître), *beta* (l'interface peut encore changer) et *stable*, ou GA pour *general availability*, garantie dans la durée[^api-versioning]. Ces stades se lisent dans les noms des API : `apps/v1` est stable, un nom en `v1beta1` ou `v1alpha1` ne l'est pas. Depuis la version 1.24, les nouvelles API bêta sont elles aussi désactivées par défaut[^beta-off]. Vous pouvez le constater sur votre cluster :

```bash
kubectl api-versions | grep -cE 'alpha|beta'
kubectl api-versions | wc -l
```

```sortie
0
23
```

Le cluster du cours sert 23 groupes d'API, tous stables. Tout ce que vous y créerez avec les réglages par défaut reposera donc sur des interfaces qui ne disparaîtront pas.

Les retraits suivent une politique écrite[^deprecation-policy]. Une API stable n'est jamais retirée tant que Kubernetes reste en version majeure 1. Une API bêta, en revanche, peut l'être, après avoir été annoncée comme dépréciée pendant au moins trois versions mineures ; le guide des dépréciations publié par le projet liste chaque retrait avec sa version[^deprecation]. Deux retraits d'API bêta ont particulièrement marqué les utilisateurs. En 1.22, celui des anciennes versions de l'API Ingress a cassé les fichiers de déploiement de nombreux projets qui n'avaient pas migré vers `networking.k8s.io/v1`. En 1.25, celui des PodSecurityPolicy les a obligés à adopter le mécanisme que nous étudierons au chapitre 44. Quand vous envoyez au cluster un objet qui utilise une API dépréciée, l'API server joint un avertissement à sa réponse, et kubectl l'affiche sur une ligne qui commence par `Warning:`. Ne l'ignorez pas : c'est le seul signal que vous aurez avant le retrait.

L'écosystème autour de Kubernetes bouge aussi, parfois plus brutalement. Pendant la préparation de ce cours, deux projets très répandus ont été archivés. Le contrôleur Ingress NGINX, qui équipait une grande partie des clusters, n'est plus maintenu depuis mars 2026 ; le projet Kubernetes a recommandé de migrer vers la Gateway API[^ingress-nginx]. C'est pourquoi le chapitre 28 présente Ingress comme l'API historique et consacre l'essentiel de sa place à la Gateway API. Le tableau de bord officiel de Kubernetes a lui aussi été archivé, ses mainteneurs recommandant Headlamp, que vous avez installé au chapitre précédent.

## Suivre le cours avec des versions plus récentes

Vous lirez peut-être ce cours quand minikube 1.40 ou Kubernetes 1.38 seront sortis. Deux stratégies sont possibles.

La plus sûre consiste à installer exactement les versions de cette page, en gardant les numéros des commandes du chapitre 0.2. Les binaires restent téléchargeables longtemps après leur sortie, et `--kubernetes-version=v1.37.0` démarre la même version de Kubernetes quelle que soit la version de minikube, tant que celle-ci la prend encore en charge. Vous obtiendrez les mêmes sorties que dans le cours, à quelques noms générés près.

L'autre consiste à prendre les versions les plus récentes. Pour tout ce qui relève des parties I à III, les différences seront minimes : l'essentiel de Docker et des objets de base de Kubernetes (Pod, Deployment, Service, ConfigMap) est stable depuis des années. Les écarts viendront plutôt des sorties affichées (colonnes supplémentaires, messages reformulés) et, dans les parties avancées, des outils de l'écosystème. Dans ce cas, gardez kubectl à une version mineure du cluster, et en cas de doute, comparez avec cette page.

Dans les deux cas, gardez l'habitude de vérifier les versions avant de chercher ailleurs la cause d'un comportement étrange. C'est la première question que pose n'importe quel mainteneur de projet quand on lui signale un bogue.

## Outils des parties suivantes

Les versions ci-dessous ont été relevées en septembre 2026, avant l'écriture des chapitres qui les utilisent. Chaque chapitre confirmera la version qu'il a réellement éprouvée.

| Outil | Version relevée | Chapitre |
|---|---|---|
| Docker Compose | 5.5.1 | 7 |
| Docker Buildx | 0.37.1 (BuildKit 0.32.2 dans le constructeur) | 13 |
| Trivy | 0.74.0 | 14 |
| cosign | 3.1.3 | 14, 47 |
| Gateway API | 1.6.2 | 28 |
| cert-manager | 1.21.2 | 28 |
| Kustomize (intégré à kubectl) | 5.8.1 | 30 |
| KEDA | 2.21.0 | 31 |
| Calico | 3.32.2 | 39, 41 |
| Cilium | 1.20.2 | 39, 40, 41 |
| Kyverno | 1.19.1 | 45, 47 |
| kube-prometheus-stack (chart Helm) | 91.5.2 | 50 |
| Loki | 3.7.8 | 51 |
| OpenTelemetry Collector | 0.161.0 | 51 |
| Velero | 1.18.3 | 52 |
| kubebuilder | 4.16.0 | 55 |
| CloudNativePG | 1.30.1 | 56 |
| Argo CD | 3.5.3 | 57 |
| Argo Rollouts | 1.10.0 | 58 |
| Linkerd | 2.20 (edge-26.6.3) | 59 |

Pour Linkerd, une précision : depuis la version 2.15, le projet open source ne publie plus que des versions « edge », hebdomadaires ; les versions stables numérotées sont distribuées par des éditeurs[^linkerd]. La 2.20 correspond à l'édition edge `edge-26.6.3`, que le chapitre 59 utilisera.

[^dockershim]: Kubernetes, « Don't Panic: Kubernetes and Docker », blog, 2 décembre 2020, et « Kubernetes is Moving on From Dockershim: Commitments and Next Steps », blog, 10 janvier 2022. [kubernetes.io/blog/2020/12/02/dont-panic-kubernetes-and-docker](https://kubernetes.io/blog/2020/12/02/dont-panic-kubernetes-and-docker/)

[^semver]: Tom Preston-Werner, « Semantic Versioning 2.0.0 ». [semver.org](https://semver.org/)

[^releases]: Kubernetes, « Releases », calendrier et dates de fin de maintenance de chaque version. [kubernetes.io/releases](https://kubernetes.io/releases/)

[^skew]: Kubernetes, « Version Skew Policy ». [kubernetes.io/releases/version-skew-policy](https://kubernetes.io/releases/version-skew-policy/)

[^api-versioning]: Kubernetes, « The Kubernetes API », section *API versioning*. [kubernetes.io/docs/concepts/overview/kubernetes-api](https://kubernetes.io/docs/concepts/overview/kubernetes-api/)

[^beta-off]: KEP-3136, « Beta APIs Off by Default ». [github.com/kubernetes/enhancements/issues/3136](https://github.com/kubernetes/enhancements/issues/3136)

[^deprecation-policy]: Kubernetes, « Kubernetes Deprecation Policy », règles 4a et 4b. [kubernetes.io/docs/reference/using-api/deprecation-policy](https://kubernetes.io/docs/reference/using-api/deprecation-policy/)

[^deprecation]: Kubernetes, « Deprecated API Migration Guide ». [kubernetes.io/docs/reference/using-api/deprecation-guide](https://kubernetes.io/docs/reference/using-api/deprecation-guide/)

[^ingress-nginx]: Kubernetes, « Ingress NGINX Retirement: What You Need to Know », blog, 11 novembre 2025 ; dépôt `kubernetes/ingress-nginx`, archivé. [kubernetes.io/blog/2025/11/11/ingress-nginx-retirement](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/)

[^linkerd]: Linkerd, « Releases and Versions ». [linkerd.io/releases](https://linkerd.io/releases/)
