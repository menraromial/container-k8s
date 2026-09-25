---
title: Utiliser des conteneurs
sidebar_label: Présentation de la partie
description: Partie I du cours. Lancer des conteneurs, construire des images, gérer les données et le réseau, puis assembler Colis avec Compose.
partie: 1
plaque: Présentation
---

Cette partie vous apprend à vous servir de Docker comme on s'en sert tous les jours : lancer un conteneur, en construire l'image, lui donner des données qui survivent, le relier à d'autres conteneurs. On n'y parle pas encore de Kubernetes. C'est voulu : Kubernetes ne fait que lancer et surveiller des conteneurs sur plusieurs machines, et tout ce que vous apprendrez ici s'y retrouvera tel quel.

À la fin de la partie, Colis tourne en entier sur votre poste : le site web, l'API, le worker qui calcule les délais, la base PostgreSQL et la file Redis, démarrés d'une seule commande. Vous saurez aussi pourquoi chacun de ces choix a été fait, et ce qui se passerait si on en faisait un autre.

| Chapitre | Ce que vous y apprenez | Ce que Colis y gagne |
|---|---|---|
| [1. Le problème que résolvent les conteneurs](le-probleme.md) | ce qu'est un conteneur, et ce qu'il n'est pas | |
| [2. Premier conteneur](premier-conteneur.md) | lancer, observer, arrêter, supprimer ; le cycle de vie | |
| [3. Les images](images.md) | couches, étiquettes, empreintes, registres | |
| [4. Écrire un Dockerfile](dockerfile.md) | construire une image, le cache, le processus numéro 1 | l'image de l'API |
| [5. Les données](donnees.md) | volumes, montages, ce qui survit à un conteneur | PostgreSQL et ses données |
| [6. Le réseau des conteneurs](reseau.md) | ponts, ports publiés, noms DNS | les composants se parlent |
| [7. Plusieurs conteneurs avec Compose](compose.md) | décrire une application entière dans un fichier | Colis complet en une commande |
| [Défi I](defi.md) | conteneuriser seul une application inconnue | |

Il vous faut Docker installé et fonctionnel (chapitre 0.2). Le cluster minikube ne sert pas dans cette partie : vous pouvez l'arrêter avec `minikube stop` pour libérer de la mémoire.
