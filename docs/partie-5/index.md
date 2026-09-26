---
title: Anatomie du cluster
sidebar_label: Présentation de la partie
description: Partie V du cours. L'API server, etcd, les contrôleurs, le scheduler, le kubelet et le CRI, le réseau des Pods, les Services sous le capot et les NetworkPolicies.
partie: 5
plaque: Présentation
---

Tapez `kubectl apply -f deployment.yaml`, et quelques secondes plus tard des processus tournent sur un nœud. Entre les deux, une demi-douzaine de programmes se sont passé le relais sans jamais s'adresser la parole directement. Aucun n'a reçu d'ordre. Chacun a remarqué qu'un objet avait changé, a fait sa part, et a écrit le résultat quelque part où le suivant le verrait. C'est ce ballet que cette partie décortique, pièce par pièce, en ouvrant chaque composant sur minikube pour le regarder travailler.

On commence par le centre, l'API server, par où tout passe, puis la base où tout est écrit, etcd. Viennent ensuite ceux qui agissent : les contrôleurs, qui ramènent sans relâche le cluster vers l'état décrit, le scheduler, qui choisit les nœuds, et le kubelet, qui transforme la description d'un Pod en processus, par l'intermédiaire du runtime de conteneurs. Les trois derniers chapitres descendent dans le réseau : comment deux Pods se joignent d'un nœud à l'autre, ce que devient un paquet adressé à un Service, et comment on filtre ces échanges.

Les parties I à IV vous ont appris à vous servir de Kubernetes. Celle-ci ne vous apprendra presque aucune commande nouvelle ; elle vous apprendra à comprendre ce que font celles que vous connaissez. C'est ce qui fait la différence le jour où quelque chose ne marche pas comme prévu.

| Chapitre | Ce que vous y apprenez |
|---|---|
| [34. L'API server](api-server.md) | groupes, versions, verbes, l'API avec `curl`, watch, pagination, server-side apply |
| [35. etcd](etcd.md) | clés et révisions, `resourceVersion`, concurrence optimiste, Raft et quorum sur trois membres |
| 36. Les contrôleurs | boucle de réconciliation, informers, ownerReferences, ramasse-miettes, finalizers |
| 37. Le scheduler | filtrage, score, plugins ; suivre une décision |
| 38. Le kubelet et le CRI | de la spec du Pod au processus, conteneur pause, Pods statiques, `crictl` |
| 39. Le réseau des Pods | modèle réseau, CNI, veth et bridges ; Calico puis Cilium |
| 40. Les Services sous le capot | kube-proxy (iptables, IPVS, nftables), EndpointSlices, eBPF, CoreDNS |
| 41. Les NetworkPolicies | isolation par défaut, règles d'entrée et de sortie pour Colis |
| Défi V | suivre la création d'un Deployment de bout en bout, preuves à l'appui |

Il vous faut le cluster minikube principal, tel que la partie IV l'a laissé. Les chapitres sur le réseau démarrent leurs propres profils minikube, avec d'autres plugins réseau ; chacun dit ce qu'il consomme et comment le retirer.
