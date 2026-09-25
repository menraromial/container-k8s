---
title: Comment ce cours fonctionne
sidebar_label: Comment ce cours fonctionne
description: Le parcours du cours, l'application fil rouge Colis, la façon dont les pages sont construites et les conventions de lecture.
partie: 0
chapitre: '0.1'
---

import colisArchitecture from '@site/src/figures/colis-architecture.svg';

Sur le cluster que vous démarrerez au chapitre suivant, la commande `kubectl api-resources` affiche 71 types de ressources. Pod, Deployment et Service, vous en avez sans doute déjà entendu parler. Les autres s'appellent `PodDisruptionBudget`, `ValidatingAdmissionPolicy`, `EndpointSlice`, `CSIStorageCapacity`, et la liste continue. C'est souvent là que les débutants décrochent : ils ont l'impression qu'il faut tout connaître avant de pouvoir faire quoi que ce soit.

Ce cours ne vous demandera jamais d'apprendre une liste. Un objet n'y apparaît que lorsqu'un problème concret le rend nécessaire. Votre application plante la nuit sans que personne ne la relance ? On découvre ce qui redémarre les conteneurs. Deux copies de l'API ne savent pas se partager le trafic ? On découvre les Services. Une fois l'objet compris, on le démonte pour voir ce qu'il fait vraiment dans le cluster. À la fin, vous connaîtrez une bonne partie de ces 71 ressources, et surtout vous saurez lire la documentation de celles que vous n'avez jamais croisées.

## Pourquoi commencer par les conteneurs

Kubernetes est un orchestrateur : il décide où et quand lancer des conteneurs, il les surveille et les remplace quand ils tombent. On ne peut pas comprendre ce qu'il orchestre sans savoir ce qu'est un conteneur, et cette question-là est plus subtile qu'elle n'en a l'air. Un conteneur n'est pas une petite machine virtuelle. C'est un processus Linux ordinaire à qui le noyau montre une vue restreinte du système : ses propres fichiers, son propre réseau, une part limitée du processeur et de la mémoire. Cette phrase vous paraîtra peut-être abstraite aujourd'hui. Au chapitre 8, vous fabriquerez un conteneur à la main, sans Docker, avec trois commandes du noyau, et elle deviendra une évidence.

L'histoire va dans le même sens. Kubernetes a été publié par Google en 2014. Il reprend dix ans d'expérience de Borg, le système qui faisait tourner les services internes de l'entreprise sur des conteneurs bien avant que Docker n'existe[^borg]. Les idées de Kubernetes (regrouper des conteneurs dans des Pods, les désigner par des étiquettes plutôt que par des noms de machines, décrire l'état souhaité et laisser des boucles de contrôle le maintenir) viennent toutes de là. Elles sont plus faciles à comprendre quand on a d'abord manipulé des conteneurs seuls et ressenti ce qui manque.

## Le chemin

Le cours compte dix parties. Elles alternent deux façons d'apprendre : utiliser un outil, puis descendre voir comment il fonctionne.

| Partie | Ce que vous y faites | Palier |
|---|---|---|
| 0. Démarrer | installer les outils, démarrer un premier cluster | |
| I. Utiliser des conteneurs | lancer, construire, relier des conteneurs ; Colis avec Compose | utiliser |
| II. Sous le capot des conteneurs | namespaces, cgroups, overlayfs, runtimes, sécurité, images de production | comprendre |
| III. Premiers pas avec Kubernetes | Pods, Deployments, Services, configuration, santé, ressources | utiliser |
| IV. Kubernetes au quotidien | stockage, StatefulSets, Gateway API, Helm, autoscaling, ordonnancement | exploiter |
| V. Anatomie du cluster | API server, etcd, contrôleurs, scheduler, kubelet, réseau | comprendre |
| VI. Sécurité | authentification, RBAC, admission, secrets, images signées | exploiter |
| VII. Observer et exploiter | débogage, pannes, métriques, logs, sauvegardes, mises à jour | exploiter |
| VIII. Étendre Kubernetes et livrer | CRD, opérateurs, GitOps, déploiements progressifs, service mesh | étendre |
| IX. Projet final | Colis « en production » sur un cluster de plusieurs nœuds | tout |

Les parties II et V sont des descentes. On y quitte les commandes de tous les jours pour regarder le noyau Linux, les fichiers d'etcd, les règles de pare-feu écrites par kube-proxy. Ce sont les parties les plus exigeantes, et ce sont elles qui font la différence le jour où quelque chose casse. Quelqu'un qui sait ce qu'est un cgroup lit un `OOMKilled` en une seconde. Celui qui l'ignore cherche pendant une heure pourquoi son application redémarre.

Chaque partie se termine par un défi. C'est un énoncé ouvert, sans pas-à-pas, qui ressemble à ce qu'on vous demanderait en entreprise. Une grille de vérification vous indique les commandes qui prouvent que vous avez réussi, et un corrigé commenté reste replié tant que vous ne l'ouvrez pas.

## Colis, l'application qui grandit avec vous

Déployer « nginx » dix fois de suite n'apprend pas grand-chose. Tout le cours s'appuie donc sur une vraie application, petite mais complète : Colis, un service de suivi de colis. On y enregistre un envoi, on consulte où il en est, et un calcul en arrière-plan estime sa date de livraison.

<Figure svg={colisArchitecture} num="0.1" alt="Architecture de Colis : le navigateur appelle web, qui transmet à api ; api lit et écrit dans postgres et dépose des tâches dans redis ; worker consomme redis et enregistre les délais dans postgres ; purge supprime chaque nuit les colis livrés depuis 30 jours.">
Les six composants de Colis. Les couleurs distinguent ce qui garde des données (en vert) de ce qui peut être détruit et recréé sans perte (en bleu) ; cette différence gouverne presque tous les choix de déploiement du cours.
</Figure>

Chaque composant existe parce qu'il pose une question que Kubernetes doit résoudre :

- `web` sert des pages statiques. C'est le composant le plus simple, celui qui servira à comprendre comment on expose une application au monde extérieur (Services, puis Gateway API).
- `api`, écrite en Python avec FastAPI, est sans état : on peut en lancer une ou dix copies, n'importe laquelle peut répondre. C'est le terrain des Deployments, des sondes de santé et de l'autoscaling.
- `postgres` garde les colis. Perdre ses fichiers, c'est perdre les données : il faudra des volumes persistants, un StatefulSet, puis un opérateur qui sait faire des sauvegardes.
- `redis` sert de file d'attente entre l'API et le worker. Il montrera comment deux composants se trouvent dans le cluster, et comment on interdit aux autres de leur parler (NetworkPolicy).
- `worker` calcule les délais de livraison. Il ne reçoit aucune requête HTTP ; sa charge dépend du nombre de tâches en attente. On le fera grandir et rétrécir en fonction de la longueur de la file.
- `purge` ne tourne qu'une fois par nuit. C'est un CronJob, avec toutes les questions qui vont avec : que se passe-t-il si la purge de la veille n'est pas finie ? Et si le nœud redémarre à 3 h du matin ?

Au début de chaque partie, une archive contient Colis dans l'état où la partie le reprend. Si vous avez sauté des chapitres, ou si votre version ne fonctionne plus, vous repartez de cette archive sans rien perdre du fil.

## À quoi ressemble une page

Les chapitres se lisent devant un terminal ouvert. Les manipulations ne sont pas rangées en fin de page : elles arrivent dans le texte, au moment où la notion est introduite. Voici les éléments que vous croiserez.

Une commande à taper s'affiche dans un bloc sombre. Le bouton en haut à droite du bloc la copie. L'invite du shell (`$`) n'est jamais écrite, pour que la copie soit directement utilisable :

```bash
kubectl get nodes
```

Ce que la commande affiche suit immédiatement, dans un bloc clair marqué d'un filet de la couleur de la partie :

```sortie
NAME       STATUS   ROLES           AGE   VERSION
minikube   Ready    control-plane   18m   v1.37.0
```

Les sorties sont celles qu'on a obtenues en exécutant la commande. Chez vous, trois choses différeront à coup sûr : les noms générés (`bonjour-665bd8cc97-6jqzl` deviendra autre chose), les durées et les ports choisis au hasard. Les messages de minikube seront peut-être aussi en anglais : il parle la langue de votre système, et le poste qui a servi à écrire ce cours est réglé en français. Quand une sortie est trop longue, les lignes coupées sont remplacées par `...`.

Un fichier à écrire porte son nom en titre. Les lignes qui changent par rapport à la version précédente sont surlignées :

```yaml title="pod.yaml" {7}
apiVersion: v1
kind: Pod
metadata:
  name: bonjour
spec:
  containers:
    - image: nginx:1.29-alpine
      name: nginx
```

Vous n'avez pas besoin de comprendre ce fichier aujourd'hui : c'est le sujet du chapitre 17.

Le cours utilise Docker, mais tout ce qui y est fait fonctionne aussi avec Podman. Chaque fois que les commandes diffèrent, un encadré le signale :

:::podman

Remplacez `docker` par `podman` : la syntaxe est la même pour presque toutes les commandes de la partie I. Les exceptions sont signalées une par une.

:::

Les erreurs que vous rencontrerez le plus souvent ont leur propre encadré. Le message y est recopié tel que la commande l'affiche, pour que vous puissiez le retrouver en cherchant dans la page :

:::panne[permission denied while trying to connect to the docker API]

Votre utilisateur n'a pas le droit de parler au démon Docker. La cause et la correction sont expliquées au chapitre 0.2.

:::

Les exercices terminent les sections importantes. Leur corrigé est replié juste en dessous. Essayez vraiment avant de l'ouvrir : c'est en cherchant la commande qu'on la retient.

:::exercice[Exercice 1]

Parmi les six composants de Colis, lesquels peut-on détruire et recréer à tout moment sans perdre de données ? Lesquels non, et pourquoi ?

:::

<details>
<summary>Corrigé</summary>

`web`, `api` et `worker` ne gardent rien : toutes leurs données sont dans `postgres` ou dans `redis`. On peut les détruire et les recréer sans perte, c'est ce qu'on appelle des composants sans état. `purge` non plus ne garde rien entre deux exécutions. `postgres` garde les colis : détruire ses fichiers, c'est perdre les données. `redis` est un cas intermédiaire : il garde les tâches en attente, et les perdre signifie que certains délais ne seront pas calculés tant que l'API ne les aura pas redemandés. On y reviendra au chapitre 26.

</details>

Enfin, les sources. Toute définition reprise d'un texte de référence, tout chiffre, tout incident cité renvoie à sa source par une note numérotée, regroupée en bas de page. Les liens pointent de préférence vers la documentation officielle de Kubernetes, les propositions d'évolution du projet (les KEP) et les articles de recherche.

## Trois façons de lire ce cours

**Vous partez de zéro.** Lisez dans l'ordre. Les parties II et V peuvent sembler longues au premier passage ; ne les sautez pas, mais n'hésitez pas à y revenir plus tard.

**Vous utilisez déjà Docker.** Commencez par le défi de la partie I. Si vous le réussissez sans ouvrir le corrigé, passez directement à la partie II. Sinon, les chapitres de la partie I vous montreront ce qui vous manquait.

**Vous devez déployer une application rapidement.** Le parcours le plus court est I, III, IV puis VII : utiliser des conteneurs, les déployer sur Kubernetes, les exploiter. Revenez ensuite aux parties II et V ; elles expliquent tout ce que vous aurez fait sans vraiment le comprendre.

Si vous préparez une certification de la CNCF (CKAD, CKA ou CKS), l'annexe C met en regard chaque domaine de l'examen et les chapitres qui le couvrent.

## Ce qu'il faut savoir avant de commencer

Le cours suppose peu de choses. Vous devez être à l'aise dans un terminal Linux : vous déplacer dans les dossiers, lire un fichier, enchaîner deux commandes avec un `|`. Vous devez savoir ce qu'est un processus, un port réseau et une adresse IP. Si l'un de ces points vous pose problème, *The Linux Command Line* de William Shotts est gratuit et couvre tout ce qui est nécessaire dans ses premiers chapitres[^shotts].

En revanche, vous n'avez besoin ni de connaître Docker, ni d'avoir administré un serveur, ni de savoir programmer en Go. Les notions de système (namespaces, cgroups, systèmes de fichiers en couches), de réseau (ponts, règles de pare-feu, DNS) et de sécurité (certificats, jetons) sont toutes reconstruites dans le cours, au moment où on en a besoin. Le code de Colis est en Python ; vous le lirez plus que vous ne l'écrirez.

## Une remarque sur le vocabulaire

Kubernetes a son vocabulaire, et il est en anglais. Ce cours garde les noms des objets de l'API tels quels, avec leur majuscule : un Pod, un Deployment, un Service, un ConfigMap. Ce ne sont pas des mots ordinaires, ce sont des types de ressources : on les écrit ainsi dans les fichiers YAML, on les tape ainsi dans les commandes, et c'est sous ce nom que vous les chercherez dans la documentation. Traduire « Deployment » par « déploiement » créerait une confusion permanente entre l'objet et l'action de déployer.

Pour les notions générales, on emploie le français : un nœud (*node*), le plan de contrôle (*control plane*), une sonde (*probe*), une boucle de contrôle (*control loop*). Le terme anglais est donné entre parenthèses à sa première apparition, pour que vous puissiez passer d'une documentation à l'autre sans vous perdre. Le mot *namespace* reste en anglais : il désigne à la fois un mécanisme du noyau Linux (partie II) et un objet de Kubernetes (partie III), et ce double sens est justement une chose qu'il faudra démêler.

Le chapitre suivant installe les outils et démarre votre premier cluster.

[^borg]: Brendan Burns, Brian Grant, David Oppenheimer, Eric Brewer, John Wilkes, « Borg, Omega, and Kubernetes », *ACM Queue*, vol. 14, n° 1, 2016. [queue.acm.org/detail.cfm?id=2898444](https://queue.acm.org/detail.cfm?id=2898444)

[^shotts]: William Shotts, *The Linux Command Line*, 5e édition internet, 2019, sous licence Creative Commons. [linuxcommand.org/tlcl.php](https://linuxcommand.org/tlcl.php)
