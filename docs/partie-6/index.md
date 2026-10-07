---
title: Sécurité
sidebar_label: Présentation de la partie
description: Partie VI du cours. L'authentification, RBAC, le durcissement des Pods, le contrôle d'admission, les secrets et la confiance dans les images.
partie: 6
plaque: Présentation
---

Depuis le premier `minikube start`, le cluster vous a toujours obéi. Rien d'étonnant : vous lui parlez avec un certificat du groupe `system:masters`, qui passe au-dessus de toutes les règles. C'est confortable sur un poste de travail, et intenable partout ailleurs. Un vrai cluster est partagé entre des équipes, des robots de déploiement, des applications qui interrogent l'API, et chacun doit y être reconnu, puis limité à ce dont il a besoin. Le jour où l'un d'eux est compromis, c'est cette limite qui décide de l'étendue des dégâts.

Cette partie suit le trajet d'une requête dans l'API server, celui de la partie V, mais avec l'œil de quelqu'un qui cherche les portes mal fermées. D'abord **qui parle** : les certificats, les jetons de ServiceAccount, les fournisseurs d'identité. Ensuite **ce qu'il a le droit de faire** : RBAC, et les façons classiques d'y gagner plus de droits qu'on n'en a reçu. Puis **ce qu'on accepte de faire tourner** : des Pods durcis, imposés par Pod Security Admission, puis des règles à vous, écrites en CEL ou confiées à Kyverno. Les deux derniers chapitres s'occupent de ce qui est stocké, les Secrets, et de ce qui est exécuté, les images.

| Chapitre | Ce que vous y apprenez |
|---|---|
| [42. L'authentification](authentification.md) | certificats par l'API CSR, ce qu'on ne peut pas révoquer, jetons de ServiceAccount liés et projetés, OIDC avec un fournisseur écrit à la main |
| [43. RBAC](rbac.md) | rôles et liaisons, un rôle d'astreinte et un compte de CI pour Colis, agrégation, garde-fous de l'API server, autorisation Node, relire les droits d'un cluster |
| [44. Durcir les Pods](durcir-pods.md) | les trois Pod Security Standards, Pod Security Admission et ses modes, nginx durci pas à pas, Colis passé au niveau restricted, le bilan du cluster |
| [45. Le contrôle d'admission](admission.md) | politiques CEL de validation et de mutation, un webhook écrit à la main, failurePolicy, Kyverno pour juger l'existant et générer |
| [46. Les secrets pour de vrai](secrets.md) | une sauvegarde d'etcd qui contient les mots de passe, le chiffrement au repos et ses pièges, Sealed Secrets, External Secrets et Vault |
| 47. Faire confiance aux images | vérification des signatures à l'admission, politiques de registres |
| Défi VI | audit de sécurité de Colis, et correction des écarts |

Il vous faut le cluster minikube principal, tel que la partie V l'a laissé. Plusieurs chapitres modifient la configuration de l'API server pour la durée d'une expérience ; chacun dit comment la remettre en état, et les scripts de rejeu le font d'eux-mêmes en sortant.
