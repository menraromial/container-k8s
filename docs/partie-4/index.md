---
title: Kubernetes au quotidien
sidebar_label: Présentation de la partie
description: Partie IV du cours. Le stockage et les StatefulSets, les Jobs et les CronJobs, l'exposition HTTP, Helm et Kustomize, l'autoscaling, l'ordonnancement fin et la disponibilité.
partie: 4
plaque: Présentation
---

À la fin de la partie III, Colis tournait sur minikube, mais avec des faiblesses qu'aucune équipe n'accepterait longtemps. Les données de PostgreSQL disparaissaient avec son Pod. La purge se lançait à la main. Le site n'était joignable que par une adresse IP, en HTTP. Les manifestes étaient recopiés et retouchés à la main pour chaque copie de l'application, et une retouche malheureuse suffisait à tout casser, comme le défi III l'a montré. Le nombre de répliques de l'API était fixé une fois pour toutes, qu'il y ait dix visiteurs ou dix mille.

Cette partie règle ces problèmes un par un, avec les objets et les outils qu'on rencontre dans tout cluster en production : les volumes persistants et les StatefulSets pour les données, les Jobs et les CronJobs pour les tâches, la Gateway API et les certificats pour exposer Colis en HTTPS, Helm et Kustomize pour empaqueter et décliner ses manifestes, l'autoscaling pour suivre la charge, puis les règles de placement et de disponibilité qui décident où tournent les Pods et combien peuvent s'arrêter à la fois.

| Chapitre | Ce que vous y apprenez |
|---|---|
| [25. Le stockage](stockage.md) | volumes, PersistentVolume et PersistentVolumeClaim, StorageClass, CSI, instantanés |
| [26. Les StatefulSets](statefulset.md) | identité stable, un volume par réplique, PostgreSQL de Colis |
| [27. DaemonSet, Job et CronJob](taches.md) | la purge de Colis, parallélisme, reprise sur échec |
| [28. Exposer en HTTP](http.md) | Ingress, Gateway API, TLS avec cert-manager |
| 29. Helm | charts, templates, values, releases, le chart de Colis |
| 30. Kustomize | base et overlays, patches, générateurs ; Helm ou Kustomize ? |
| 31. L'autoscaling | HPA, VPA, KEDA sur la file Redis du worker |
| 32. L'ordonnancement fin | affinités, taints et tolérations, répartition, priorités |
| 33. La disponibilité | PodDisruptionBudget, `drain` et `cordon` |
| Défi IV | Colis avec Helm, stockage persistant, HTTPS et autoscaling |

Il vous faut le cluster minikube de la partie III, avec Colis déployé comme au chapitre 24 et le registre local du chapitre 14. Quelques chapitres activent des addons de minikube ou installent des composants supplémentaires ; chacun dit ce qu'il consomme en mémoire et comment le retirer.
