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
