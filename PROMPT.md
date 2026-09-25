# Prompt : cours « Conteneurs et Kubernetes, du premier conteneur à l'expertise »

> À coller tel quel au début d'une session Claude Code ouverte dans
> `/home/romial/these/docs/container_k8s`. Le plan détaillé est à la fin ; il fait
> partie du prompt.

---

## 1. Ce que je te demande

Tu vas construire avec moi un cours complet sur les conteneurs et Kubernetes, en
français, publié sous forme de site **Docusaurus** dans
`/home/romial/these/docs/container_k8s`. Le cours part de zéro (quelqu'un qui n'a
jamais lancé un conteneur) et mène jusqu'aux notions d'expert : fonctionnement
interne du cluster, sécurité, extension de l'API, opérateurs, GitOps, service mesh.
Tout ce qui est montré doit pouvoir s'exécuter **en local, sur un portable
d'étudiant, avec minikube**. Aucun compte cloud n'est nécessaire.

Le cours doit être :

- **détaillé** : on ne survole rien, chaque notion est expliquée jusqu'à ce qu'un
  débutant puisse la réexpliquer ; un chapitre fait facilement l'équivalent de 10 à
  20 pages imprimées ;
- **facile à comprendre** : progression sans marche trop haute, chaque terme défini
  à sa première apparition, un exemple concret avant chaque abstraction ;
- **pédagogique** : on apprend en faisant ; les manipulations sont intercalées dans
  le texte, au moment où la notion est introduite, pas reléguées en fin de page ;
- **illustré** : au moins une figure par chapitre, souvent plusieurs, qui montrent le
  mécanisme réel (qui parle à qui, dans quel ordre, où vivent les données).

## 2. Public et progression

Public : étudiants de Licence 3 / Master en informatique, et toute personne à l'aise
avec un terminal Linux mais qui ne connaît ni Docker ni Kubernetes. Prérequis
supposés : ligne de commande (cd, ls, cat, pipes), notion de processus, de port
réseau, d'adresse IP. Tout le reste (namespaces, cgroups, overlayfs, iptables, TLS,
YAML, etc.) est reconstruit dans le cours au moment où on en a besoin.

La progression suit trois paliers : **utiliser** (parties I et III), **comprendre le
mécanisme** (parties II et V), **exploiter et étendre** (parties IV, VI, VII, VIII).
Le projet final (partie IX) mobilise tout.

## 3. Environnement technique

- Poste de référence : Linux, 8 Go de RAM minimum côté étudiant. Mon poste de
  validation a 15 Go dont 6 à 8 réellement libres : **ne jamais lancer de cluster
  qui dépasse 6 Go au total**. Profil par défaut : `minikube start --cpus=2
  --memory=4g`. Chapitres multi-nœuds : `--nodes=3` avec 2 Go par nœud au maximum.
  Les piles lourdes (Prometheus, Istio) ont leur profil minikube dédié, démarré puis
  arrêté dans le chapitre.
- Moteur de conteneurs du cours : **Docker** (pilote minikube `docker`, le plus
  stable). Chaque fois qu'une commande diffère avec Podman, un encadré le signale.
  Déjà installés sur mon poste : docker 29, podman 5.7, kubectl 1.35, helm 3.16,
  kind 0.32, node 26. **minikube n'est pas installé** : l'installer (binaire
  utilisateur dans `~/.local/bin`, sans sudo si possible) et le signaler.
- Versions : au début de la première session, relever les dernières versions
  stables (Kubernetes, minikube, Helm, Argo CD, Cilium, etc.), les figer dans une
  page « Versions utilisées » et s'y tenir partout.
- **Chaque commande et chaque manifeste du cours est éprouvé pour de vrai** sur
  minikube avant d'être écrit dans une page. Les sorties affichées sont les sorties
  réelles (raccourcies avec `...` si besoin), jamais inventées. Garder les fichiers
  de validation dans le scratchpad, pas dans le site.
- Fin de validation : **ne rien détruire toi-même**. Laisser le cluster tourner, me
  donner les URL des interfaces (dashboard, Grafana, Argo CD, etc.) et un bloc de
  commandes de nettoyage à lancer moi-même. Dans les pages aussi, chaque TP se
  termine par une section d'accès aux interfaces et une section de nettoyage.
- Jobs gourmands (builds multi-arch, scans, gros charts) : les lancer sous
  `systemd-run --user --scope --quiet -p MemoryMax=6G -p MemorySwapMax=0`.
  `/tmp` est un tmpfs sur ce poste : ne pas y écrire de gros fichiers.

## 4. Application fil rouge : « Colis »

Un service de suivi de colis, volontairement petit mais réaliste, qui grossit avec
le cours et donne une raison concrète à chaque objet Kubernetes :

| Composant | Rôle | Sert à introduire |
|-----------|------|-------------------|
| `web` | page statique servie par nginx | image simple, Service, Ingress |
| `api` | API HTTP en Python (FastAPI) | Deployment, probes, config, HPA |
| `worker` | calcule les délais de livraison depuis une file Redis | découplage, scaling indépendant, KEDA |
| `postgres` | base des colis | volumes, StatefulSet, opérateur CloudNativePG |
| `redis` | file de messages | Service interne, NetworkPolicy |
| `purge` | supprime les colis livrés depuis 30 jours | Job, CronJob |

Code dans `kits/colis/` avec des tests (pytest), un `Dockerfile` par composant, un
`compose.yaml` (partie I), puis des manifestes, un chart Helm et des overlays
Kustomize (parties III et IV). Archives téléchargeables par étape dans
`static/kits/` pour qu'un étudiant puisse reprendre à n'importe quel chapitre.

## 5. Rédaction

- Écrire comme un enseignant qui parle à ses étudiants (« vous », parfois « on »),
  en prose continue, phrases de longueur variée. Peu de gras. Des listes seulement
  quand le contenu est vraiment une liste.
- **Pas de gabarit répété** : pas d'encadré « Objectifs » ni « Ce qu'il faut
  retenir » sur chaque page, pas de formules du type « Voici l'idée clé »,
  « Retenez », pas de triades symétriques. Ne pas ouvrir un chapitre par « dans le
  chapitre précédent… » : entrer directement dans le sujet par un problème concret.
- Beaucoup d'exemples travaillés (4 à 8 par chapitre), chiffrés quand c'est
  possible (tailles d'images, temps de démarrage, consommation mémoire mesurée).
- Ancrer les notions dans des faits réels et sourcés : incidents publics
  (post-mortems), CVE marquantes (runc CVE-2019-5736, Leaky Vessels, etc.),
  documentation officielle, KEP, papiers (Borg, Omega). **Citer la source** de toute
  définition ou affirmation empruntée (lien en note ou en fin de chapitre).
- Cours intemporel : pas de repère du type « il y a trois mois » dans les exemples ;
  les dates factuelles sont permises.
- **Jamais de tiret cadratin (U+2014)** nulle part : ni dans le texte, ni dans le code, ni
  dans les commentaires YAML.
- Chaque chapitre contient, sans que les intitulés soient figés : l'entrée par un
  problème, l'explication progressive avec manipulations intercalées, au moins une
  figure, les pannes courantes quand c'est pertinent (message d'erreur réel, cause,
  correction), des exercices gradués avec corrigés repliés (`<details>`), et le
  nettoyage.
- Chaque partie se termine par un **défi** : un énoncé ouvert sans pas-à-pas, avec
  une grille de vérification (commandes qui prouvent que c'est réussi) et un corrigé
  replié.

## 6. Illustrations et design

- Figures : schémas sobres, traits fins colorés et remplissages très pâles, **aucune
  icône clipart, aucune ombre, aucun aplat vif** (le rendu « généré par IA » type
  ByteByteGo est refusé). Source TikZ `standalone` dans `figures/src/`, compilée en
  SVG (dvisvgm) dans `static/img/`, lisible en thème clair et sombre. Un `Makefile`
  dans `figures/`. Vérifier chaque figure en la rendant en PNG avant de l'intégrer.
- Diagrammes de séquence (appel API, cycle de réconciliation, handshake TLS) : même
  style, flèches numérotées dans l'ordre chronologique.
- Quelques composants React interactifs, seulement là où ils apportent vraiment
  (un par partie au plus) : rolling update pas à pas, parcours d'un paquet de
  Service vers Pod, décision du scheduler.
- **Identité visuelle propre**, distincte de mes deux autres sites Docusaurus
  (ingénierie du déploiement : papier/Source Serif/bleu encre ; introduction à AWS :
  façon console). Avant d'écrire le contenu, proposer **deux directions** (police,
  palette, encadrés, rendu des blocs de code et des sorties de terminal) sous forme
  de maquette de l'accueil et d'une page de chapitre ; je choisis.
- Blocs de code : titre de fichier (`title="deployment.yaml"`), lignes surlignées sur
  ce qui change d'une version à l'autre, distinction visuelle nette entre la
  commande tapée et la sortie obtenue.
- Pages étudiantes sans durée ni minutage.

## 7. Organisation du site

```
container_k8s/
  docs/
    index.md                      accueil
    demarrer/                     partie 0
    partie-1-conteneurs/          un dossier par partie, un fichier par chapitre
    ...
    annexes/
  figures/src/  figures/Makefile
  kits/colis/                     application fil rouge (+ tests)
  static/kits/  static/img/
  src/components/  src/theme/     composants et swizzles
  docusaurus.config.ts  sidebars.ts
```

Docusaurus 3 à jour, TypeScript, `onBrokenLinks: 'throw'`, recherche locale,
thème sombre. Échapper `{ } <` hors code (MDX). `npm run build` doit passer sans
avertissement à la fin de chaque session. Pas de git pour l'instant : je
déciderai plus tard ; ne jamais ajouter de mention de Claude dans un commit.

## 8. Façon de travailler

1. **Session 1** : installer minikube, relever les versions, créer le squelette
   Docusaurus, proposer les deux directions de design, attendre mon choix, puis
   écrire l'accueil et la partie 0. S'arrêter.
2. Ensuite, **une partie par session** (ou une demi-partie pour les plus longues) :
   écrire les chapitres, éprouver chaque commande sur minikube, produire les
   figures, faire le build, puis me faire un compte rendu (pages créées, figures,
   ce qui a été testé et comment, écarts ou pièges trouvés, interfaces encore
   ouvertes et commandes de nettoyage). S'arrêter et attendre ma validation.
3. Tenir à jour une mémoire de projet (avancement, décisions, pièges techniques
   rencontrés) pour reprendre d'une session à l'autre.
4. Si une notion prévue ne fonctionne pas sur minikube (ou demande trop de
   mémoire), me le dire et proposer une alternative plutôt que la simuler.

---

## 9. Plan du cours

### Partie 0 : Démarrer

0.1 Comment ce cours fonctionne (parcours, fil rouge Colis, conventions de lecture)
0.2 Préparer son poste : Docker (ou Podman), kubectl, minikube, Helm, éditeur et
    extension YAML ; vérifications
0.3 Versions utilisées et comment les mettre à jour

### Partie I : Utiliser des conteneurs

1. Le problème que résolvent les conteneurs : « chez moi ça marche », dépendances,
   isolation ; conteneur, machine virtuelle et processus comparés
2. Premier conteneur : `run`, `ps`, `logs`, `exec`, `stop`, `rm` ; cycle de vie et
   codes de sortie
3. Les images : couches, tags et digests, registres, format OCI ; `pull`, `inspect`,
   `history`
4. Écrire un Dockerfile : instructions, contexte de build, cache de couches,
   `.dockerignore`, `CMD` et `ENTRYPOINT`, PID 1 et signaux
5. Les données : volumes nommés, bind mounts, tmpfs ; où vivent les fichiers
6. Le réseau des conteneurs : bridge, publication de ports, DNS entre conteneurs,
   réseaux utilisateur
7. Plusieurs conteneurs avec Compose : Colis complet en local, dépendances,
   healthchecks, variables d'environnement
Défi I : conteneuriser une application fournie et la faire tourner avec Compose

### Partie II : Sous le capot des conteneurs

8. Les namespaces Linux : `unshare`, `nsenter`, `lsns` ; construire un
   « conteneur » à la main
9. Les cgroups v2 : limiter CPU et mémoire, observer un OOM kill
10. Le système de fichiers en couches : overlayfs, copy-on-write, lowerdir/upperdir
11. Les runtimes : spécification OCI, runc et crun, containerd, CRI-O, shims ;
    lancer un bundle OCI avec runc sans Docker
12. Sécurité d'un conteneur : capabilities, seccomp, AppArmor/SELinux, utilisateur
    non root, rootless et user namespaces ; évasions célèbres et leurs causes
13. Des images de production : multi-stage, distroless et images minimales,
    reproductibilité, BuildKit et cache, multi-architecture avec buildx
14. La chaîne d'approvisionnement des images : scan (Trivy), SBOM, signature
    (cosign), registre local
Défi II : réduire l'image de l'API Colis sous un seuil de taille et de CVE

### Partie III : Premiers pas avec Kubernetes

15. Pourquoi un orchestrateur : de Borg à Kubernetes, état désiré, réconciliation ;
    vue d'ensemble de l'architecture
16. minikube et kubectl : pilotes, profils, addons, dashboard ; kubeconfig,
    contextes, `explain`, `get -o yaml`
17. Le Pod : cycle de vie, phases et conditions, conteneurs multiples, init
    containers, sidecars natifs, politique de redémarrage
18. Décrire plutôt qu'ordonner : YAML, `apply` déclaratif, labels et sélecteurs,
    annotations, namespaces
19. ReplicaSet et Deployment : mise à l'échelle, rolling update, `maxSurge` et
    `maxUnavailable`, historique et rollback
20. Les Services : ClusterIP, NodePort, LoadBalancer avec `minikube tunnel`,
    headless ; DNS interne
21. Configurer une application : ConfigMap, Secret, variables et fichiers montés,
    rechargement
22. La santé des Pods : probes liveness, readiness et startup ; arrêt propre,
    `terminationGracePeriodSeconds`, preStop
23. Les ressources : requests et limits, classes QoS, éviction, LimitRange,
    ResourceQuota
24. TP de synthèse : Colis déployé sur minikube (images chargées avec
    `minikube image`, puis via le registre local)
Défi III : diagnostiquer et réparer un déploiement cassé de Colis (cinq pannes
cachées)

### Partie IV : Kubernetes au quotidien

25. Le stockage : volumes, PersistentVolume, PersistentVolumeClaim, StorageClass,
    provisionnement dynamique, modes d'accès, CSI
26. Les StatefulSets : identité stable, volumes par réplique, Postgres de Colis
27. DaemonSet, Job et CronJob : la purge de Colis, parallélisme, reprise sur échec
28. Exposer en HTTP : Ingress (addon ingress-nginx), TLS avec cert-manager ;
    Gateway API
29. Helm : structure d'un chart, templates, values, releases, hooks ; écrire le
    chart de Colis
30. Kustomize : base et overlays dev/prod, patches, générateurs ; Helm ou
    Kustomize ?
31. L'autoscaling : metrics-server, HPA, VPA, scaling événementiel avec KEDA (file
    Redis du worker)
32. L'ordonnancement fin sur minikube multi-nœuds : nodeSelector, affinités,
    taints et tolérations, topology spread, priorités et préemption
33. La disponibilité : PodDisruptionBudget, `drain` et `cordon`, stratégies de
    mise à jour
Défi IV : Colis avec Helm, stockage persistant, Ingress TLS et autoscaling

### Partie V : Anatomie du cluster

34. L'API server : groupes, versions, ressources et verbes ; interroger l'API avec
    `curl` ; watch, pagination, server-side apply
35. etcd : modèle clé-valeur, `resourceVersion`, concurrence optimiste ; lire etcd
    dans minikube avec etcdctl
36. Les contrôleurs : boucle de réconciliation, informers, ownerReferences,
    garbage collection, finalizers
37. Le scheduler : filtrage, scoring, framework de plugins ; suivre une décision
38. Le kubelet et le CRI : de la spec du Pod au processus, conteneur pause, pods
    statiques ; `crictl` dans le nœud
39. Le réseau des Pods : modèle réseau Kubernetes, CNI, veth et bridges ; minikube
    avec Calico puis Cilium
40. Les Services sous le capot : kube-proxy (iptables, IPVS, nftables),
    EndpointSlices, eBPF avec Cilium, CoreDNS
41. Les NetworkPolicies : isolation par défaut, politiques d'entrée et de sortie
    pour Colis
Défi V : suivre de bout en bout la création d'un Deployment, de `kubectl apply`
au processus sur le nœud, preuves à l'appui

### Partie VI : Sécurité

42. Authentification : certificats clients, ServiceAccounts, jetons projetés,
    kubeconfig d'un utilisateur limité
43. RBAC : Role, ClusterRole, bindings, moindre privilège, `kubectl auth can-i`,
    escalades classiques
44. Durcir les Pods : securityContext, Pod Security Standards et Pod Security
    Admission
45. Le contrôle d'admission : webhooks, ValidatingAdmissionPolicy (CEL), Kyverno
46. Les secrets pour de vrai : chiffrement au repos dans etcd, Sealed Secrets,
    External Secrets
47. Faire confiance aux images : vérification de signature à l'admission,
    politiques de registres
Défi VI : audit de sécurité de Colis et correction des écarts

### Partie VII : Observer et exploiter

48. Déboguer : events, `describe`, `logs --previous`, `kubectl debug`, conteneurs
    éphémères ; méthode de diagnostic
49. Catalogue de pannes : Pending, CrashLoopBackOff, ImagePullBackOff, OOMKilled,
    CreateContainerConfigError, probes ratées, DNS ; reproduire et corriger chacune
50. Les métriques : Prometheus et Grafana (kube-prometheus-stack), métriques de
    Colis, alertes
51. Logs et traces : Loki, OpenTelemetry, corréler une requête lente
52. Sauvegarder et restaurer : snapshot etcd, Velero
53. Mettre à jour un cluster : décalage de versions, montée de version avec
    minikube, dépréciations d'API
Défi VII : incident simulé sur Colis, du symptôme au post-mortem

### Partie VIII : Étendre Kubernetes et livrer

54. Les Custom Resource Definitions : schéma, validation, versions, sous-ressources
55. Écrire un opérateur : le patron opérateur, un contrôleur avec kubebuilder (Go)
    pour une ressource `Colis`
56. Utiliser un opérateur existant : CloudNativePG pour la base de Colis
57. GitOps avec Argo CD : Application, synchronisation, dérive, App of Apps
58. Déploiements progressifs : canary et blue-green avec Argo Rollouts
59. Service mesh : mTLS, routage et observabilité avec Linkerd (ou Istio en profil
    dédié si la mémoire le permet)
60. Plusieurs clusters et multi-locataire : profils minikube, namespaces,
    quotas, vClusters
Défi VIII : Colis livré en GitOps avec un déploiement canary

### Partie IX : Projet final

61. Cahier des charges : Colis « en production » sur minikube multi-nœuds (Helm,
    CloudNativePG, Ingress TLS, HPA, NetworkPolicies, RBAC, supervision, GitOps,
    canary)
62. Grille d'évaluation et soutenance
63. Corrigé commenté (page séparée)

### Annexes

A. Aide-mémoire kubectl et Docker
B. Dépannage de minikube (pilotes, mémoire, DNS, proxy)
C. Correspondance avec les certifications CKAD, CKA et CKS, avec séries
   d'exercices chronométrés
D. Glossaire
E. Bibliographie et sources
