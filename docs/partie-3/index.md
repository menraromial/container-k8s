---
title: Premiers pas avec Kubernetes
sidebar_label: Présentation de la partie
description: Partie III du cours. Pourquoi un orchestrateur, minikube et kubectl, le Pod, les manifestes, les Deployments, les Services, la configuration, la santé et les ressources, puis Colis sur minikube.
partie: 3
plaque: Présentation
---

Jusqu'ici, un conteneur tournait parce que vous l'aviez lancé, sur une machine que vous aviez choisie. Kubernetes change la question qu'on se pose : on ne dit plus « lance ce conteneur ici », on décrit ce qu'on veut obtenir (trois copies de l'API, joignables sous tel nom, avec telle quantité de mémoire) et le cluster se charge d'y arriver, puis d'y rester quand une machine tombe ou qu'un programme plante.

Cette partie apprend à se servir de Kubernetes au quotidien, sur le cluster minikube installé au chapitre 0.2. Chaque objet y est introduit par le problème qu'il résout, manipulé, cassé, puis réparé. Le fonctionnement interne des composants (l'API server, etcd, le scheduler, le réseau des Pods) viendra à la partie V ; ici, on en voit assez pour comprendre ce qui se passe et savoir où regarder quand ça ne marche pas.

| Chapitre | Ce que vous y apprenez |
|---|---|
| [15. Pourquoi un orchestrateur](orchestrateur.md) | de Borg à Kubernetes, l'état désiré, la réconciliation, les composants d'un cluster |
| [16. minikube et kubectl](minikube-kubectl.md) | pilotes, profils, addons, kubeconfig et contextes, `explain`, `-o yaml` |
| [17. Le Pod](pod.md) | cycle de vie, conteneurs multiples, init containers, sidecars, redémarrages |
| [18. Décrire plutôt qu'ordonner](declaratif.md) | YAML, `apply`, labels et sélecteurs, annotations, namespaces |
| [19. ReplicaSet et Deployment](deployment.md) | mise à l'échelle, mise à jour progressive, retour arrière |
| [20. Les Services](services.md) | ClusterIP, NodePort, LoadBalancer, headless, le DNS du cluster |
| [21. Configurer une application](configuration.md) | ConfigMap, Secret, variables et fichiers montés |
| [22. La santé des Pods](sante.md) | probes, arrêt propre, preStop |
| [23. Les ressources](ressources.md) | requests et limits, classes QoS, éviction, quotas |
| [24. TP : Colis sur minikube](colis-minikube.md) | l'application complète, depuis le registre local |
| Défi III | réparer un déploiement cassé de Colis |

Il vous faut le cluster minikube du chapitre 0.2, kubectl, et pour le chapitre 24, le registre local du chapitre 14 avec l'image `colis/api:2.0` du défi II.
