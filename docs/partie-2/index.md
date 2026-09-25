---
title: Sous le capot des conteneurs
sidebar_label: Présentation de la partie
description: Partie II du cours. Namespaces, cgroups, systèmes de fichiers en couches, runtimes, sécurité, images de production et chaîne d'approvisionnement.
partie: 2
plaque: Présentation
---

La partie I a utilisé les conteneurs comme des boîtes noires qui fonctionnent. Celle-ci les ouvre. On y fabrique un conteneur sans Docker, avec les commandes du noyau ; on le limite en mémoire jusqu'à ce que le noyau le tue ; on empile des systèmes de fichiers à la main ; on lance une image avec runc, le programme que Docker, containerd et Kubernetes appellent tous au bout du compte. Puis on remonte vers la pratique : ce qui rend un conteneur sûr, ce qui fait une bonne image de production, et comment savoir ce que contient une image avant de la faire tourner.

C'est la partie la plus exigeante du cours, et c'est elle qui fait la différence le jour où un conteneur est tué sans raison apparente, refuse de démarrer ou se révèle vulnérable. Chaque notion y est manipulée pour de vrai, dans un laboratoire préparé au chapitre 8.

| Chapitre | Ce que vous y apprenez |
|---|---|
| [8. Les namespaces Linux](namespaces.md) | les huit namespaces, `nsenter`, `unshare`, un conteneur fait à la main |
| [9. Les cgroups](cgroups.md) | limiter la mémoire et le processeur, provoquer un OOM kill |
| [10. Les systèmes de fichiers en couches](overlayfs.md) | overlayfs, la copie à l'écriture, les couches d'une image |
| [11. Les runtimes](runtimes.md) | la spécification OCI, runc, containerd, les shims |
| [12. La sécurité d'un conteneur](securite.md) | capabilities, seccomp, AppArmor, utilisateurs non root, rootless |
| [13. Des images de production](images-production.md) | constructions en plusieurs étapes, images minimales, multi-architecture |
| 14. La chaîne d'approvisionnement | analyse de vulnérabilités, SBOM, signature des images |
| Défi II | réduire l'image de Colis sous un seuil de taille et de vulnérabilités |

Il vous faut Docker et, pour le chapitre 11, le cluster minikube du chapitre 0.2. Tout le reste est fourni par le laboratoire.
