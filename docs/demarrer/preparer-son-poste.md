---
title: Préparer son poste
sidebar_label: Préparer son poste
description: Installer Docker Engine, kubectl, minikube et Helm, démarrer un premier cluster Kubernetes, le vérifier, l'arrêter et le reprendre.
partie: 0
chapitre: '0.2'
---

import minikubeStartEtapes from '@site/src/figures/minikube-start-etapes.svg';
import minikubePoupees from '@site/src/figures/minikube-poupees.svg';

Trois programmes doivent s'entendre sur votre machine. Docker fait tourner des conteneurs. minikube s'en sert pour fabriquer un cluster Kubernetes complet, rangé tout entier dans un seul de ces conteneurs. Et kubectl est l'outil avec lequel vous parlerez à ce cluster pendant tout le cours. Un quatrième, Helm, ne servira qu'à partir de la partie IV ; autant l'installer maintenant, pendant que vous avez la main dans les paquets.

Ce chapitre est long parce qu'il fait les choses une fois pour toutes : installer proprement, vérifier chaque outil, démarrer un premier cluster, regarder ce qui tourne réellement, puis apprendre à l'arrêter et à le reprendre sans rien perdre. Si vous avez déjà Docker, lisez quand même la section sur le groupe `docker` : elle contient une remarque de sécurité que beaucoup de tutoriels oublient.

## Ce qu'il faut sur la machine

Le cours est écrit et testé sous Linux. minikube demande au minimum deux processeurs, 2 Go de mémoire libre et 20 Go d'espace disque[^mk-start]. Ce minimum permet de démarrer un cluster vide ; pour travailler confortablement avec Colis, un navigateur et un éditeur ouverts à côté, comptez 8 Go de mémoire au total sur la machine. Aucune option de virtualisation n'est nécessaire dans le BIOS : avec le pilote Docker, le cluster est un conteneur, pas une machine virtuelle.

Quatre commandes suffisent pour vérifier votre machine :

```bash
nproc
free -h
df -h ~
stat -fc %T /sys/fs/cgroup/
```

Voici ce qu'elles donnent sur le poste qui a servi à écrire ce cours :

```sortie
22
               total       utilisé      libre     partagé tamp/cache   disponible
Mem:            15Gi       7,8Gi       974Mi       1,2Gi       8,1Gi       7,3Gi
Échange:          0B          0B          0B
/dev/mapper/ubuntu--vg-ubuntu--lv   935G    600G  289G  68% /
cgroup2fs
```

`nproc` compte les processeurs logiques : il en faut au moins deux. Dans la sortie de `free`, regardez la colonne `disponible` plutôt que `libre` : Linux se sert de la mémoire inoccupée comme cache de fichiers et la rend dès qu'un programme en a besoin, si bien que la colonne `libre` paraît toujours alarmante. Ici, 7,3 Go sont réellement disponibles. `df` vérifie la place sur la partition qui contient votre dossier personnel, où minikube range ses téléchargements.

La dernière ligne est la plus technique. `cgroup2fs` signifie que votre noyau utilise les cgroups version 2, le mécanisme qui permet de limiter la mémoire et le processeur d'un groupe de processus. Toutes les distributions récentes l'utilisent par défaut. Si vous lisez `tmpfs` à la place, votre système est encore en cgroups v1 : ce n'est pas bloquant pour minikube, mais certaines manipulations du chapitre 9 ne fonctionneront pas telles quelles. Nous étudierons les cgroups en détail à ce moment-là ; pour l'instant, retenez simplement qu'ils existent et que Docker s'en sert pour chaque conteneur.

:::info[Sous Windows ou macOS]

minikube fonctionne sur ces deux systèmes, mais ce cours n'a été éprouvé que sous Linux. Sous Windows, la voie la plus proche de ce que vous lirez ici consiste à installer WSL 2 avec une distribution Ubuntu, puis à suivre ce chapitre à l'intérieur de WSL[^wsl]. Sous macOS, Docker Desktop fournit le moteur de conteneurs ; minikube et kubectl s'installent ensuite avec leurs binaires pour macOS. Dans les deux cas, les chapitres de la partie II qui manipulent directement le noyau Linux devront être faits à l'intérieur de la machine virtuelle Linux sous-jacente.

:::

## Installer Docker Engine

Docker existe sous deux formes sur Linux. Docker Engine est le moteur seul : un démon qui tourne en arrière-plan et le client en ligne de commande `docker`. Docker Desktop ajoute une interface graphique et fait tourner le moteur dans une petite machine virtuelle. Ce cours utilise Docker Engine : il est plus léger, et surtout il laisse les conteneurs tourner directement sur votre noyau, ce qui nous permettra de les observer de l'extérieur dans la partie II.

Les distributions proposent souvent un paquet `docker.io` dans leurs propres dépôts. Il fonctionne, mais il a généralement plusieurs versions de retard. On installe plutôt Docker depuis le dépôt officiel de Docker, en suivant la procédure de sa documentation[^docker-install]. L'ajout du dépôt et l'installation des paquets ci-dessous ont été rejoués dans des conteneurs Ubuntu 26.04 et Debian 13 vierges ; le démon lui-même tourne sur le poste qui a servi à écrire le cours.

### Ubuntu et Debian

On commence par enregistrer la clé qui signe les paquets de Docker, pour qu'`apt` puisse vérifier qu'ils viennent bien de Docker :

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
```

On déclare ensuite le dépôt. Le nom de code de la distribution (`resolute` pour Ubuntu 26.04, `trixie` pour Debian 13) est lu dans `/etc/os-release`, pour que la même commande fonctionne sur toutes les versions :

```bash
sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
```

Sous Debian, remplacez `ubuntu` par `debian` dans les deux adresses (celle de la clé et celle du dépôt). Il reste à installer les paquets :

```bash
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Cinq paquets pour un seul outil, cela mérite une explication. `docker-ce` est le démon, le programme qui reçoit les ordres et gère les conteneurs. `docker-ce-cli` est le client `docker` que vous taperez dans le terminal : il ne fait rien lui-même, il envoie des requêtes au démon. `containerd.io` est un autre démon, plus bas dans la pile, auquel Docker délègue le vrai travail de lancer les conteneurs. Retenez ce nom : vous allez le recroiser dans quelques minutes à l'intérieur de minikube, et il aura droit à son propre chapitre (le 11). Les deux derniers paquets ajoutent les commandes `docker buildx` (construction d'images) et `docker compose` (applications à plusieurs conteneurs, chapitre 7).

### Fedora

Fedora utilise `dnf` et un fichier de dépôt fourni tout fait par Docker (commandes testées dans un conteneur Fedora 43) :

```bash
sudo dnf -y install dnf-plugins-core
sudo dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
sudo dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
```

La dernière ligne démarre le démon et le fait redémarrer à chaque allumage de la machine. Sous Ubuntu et Debian, l'installation du paquet s'en charge déjà. Pour les autres distributions (Arch, openSUSE, etc.), la documentation de Docker donne la procédure propre à chacune.

### Utiliser Docker sans sudo

Juste après l'installation, seul `root` peut parler au démon Docker. Si vous essayez avec votre utilisateur habituel, vous obtenez ceci :

```sortie
permission denied while trying to connect to the docker API at unix:///var/run/docker.sock
```

Le message dit exactement ce qui se passe. Le client `docker` ne lance rien lui-même : il envoie ses requêtes au démon par un fichier spécial, une socket Unix, située dans `/var/run/docker.sock`. Regardons ses droits :

```bash
ls -l /var/run/docker.sock
```

```sortie
srw-rw---- 1 root docker 0 Sep 24 18:32 /var/run/docker.sock
```

Le `s` initial indique une socket. Elle appartient à l'utilisateur `root` et au groupe `docker`, et seuls eux peuvent y lire et y écrire (`rw-rw----`). Pour y accéder sans `sudo`, on ajoute donc son utilisateur au groupe `docker` :

```bash
sudo usermod -aG docker $USER
```

L'appartenance à un groupe est lue à l'ouverture de la session : il faut se déconnecter puis se reconnecter (ou redémarrer) pour qu'elle prenne effet. En attendant, `newgrp docker` ouvre un shell dans lequel le groupe est déjà actif.

:::warning[Le groupe docker vaut un accès root]

Être membre du groupe `docker`, c'est pouvoir demander au démon de lancer n'importe quel conteneur, y compris un conteneur qui monte la racine du système (`docker run -v /:/hote ...`) et la modifie en tant que `root`. La documentation de Docker le dit sans détour : ce groupe accorde des privilèges équivalents à ceux de `root`[^docker-group]. Sur votre portable, où vous êtes déjà administrateur, ce n'est pas un problème. Sur un serveur partagé, n'ajoutez jamais quelqu'un à ce groupe à la légère. Le chapitre 12 présente le mode *rootless*, qui fait tourner le démon sous votre propre utilisateur et supprime ce risque.

:::

### Vérifier

Docker fournit une image minuscule faite exactement pour ça :

```bash
docker run --rm hello-world
```

```sortie
Unable to find image 'hello-world:latest' locally
latest: Pulling from library/hello-world
4f55086f7dd0: Pull complete
Digest: sha256:5e23090353324d887c48ad5e5c56d294eab81588df9605b07d1afe895f9cc8f8
Status: Downloaded newer image for hello-world:latest

Hello from Docker!
This message shows that your installation appears to be working correctly.
...
```

Beaucoup de choses se sont passées en une seconde. Le client a demandé au démon de lancer un conteneur à partir de l'image `hello-world`. Le démon ne l'avait pas, il l'a téléchargée depuis Docker Hub, le registre public par défaut, puis il a créé le conteneur, l'a lancé, a relayé ce qu'il affichait vers votre terminal, et l'a supprimé à la fin grâce à l'option `--rm`. Chacune de ces étapes fera l'objet d'une section du chapitre 2. Pour l'instant, ce message suffit : votre installation fonctionne.

Deux vérifications de plus :

```bash
docker version --format 'Client {{.Client.Version}} / Serveur {{.Server.Version}}'
docker info --format '{{.CgroupDriver}} cgroup v{{.CgroupVersion}}'
```

```sortie
Client 29.3.1 / Serveur 29.3.1
systemd cgroup v2
```

La première affiche deux versions parce qu'il y a deux programmes, le client et le démon. La seconde confirme que Docker utilise les cgroups v2 et qu'il les gère par l'intermédiaire de systemd.

## Installer kubectl

kubectl est un unique fichier exécutable. Il n'a pas besoin d'être installé par un gestionnaire de paquets : on le télécharge, on vérifie qu'il n'a pas été altéré en route, et on le range dans un dossier de votre `PATH`. La procédure suit la documentation de Kubernetes[^kubectl-install]. On prend la version 1.37.1, la même famille que le cluster du cours ; le chapitre 0.3 explique pourquoi c'est important.

```bash
curl -LO https://dl.k8s.io/release/v1.37.1/bin/linux/amd64/kubectl
curl -LO https://dl.k8s.io/release/v1.37.1/bin/linux/amd64/kubectl.sha256
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
```

```sortie
kubectl: OK
```

Le fichier `kubectl.sha256` contient l'empreinte SHA-256 du binaire officiel. `sha256sum` recalcule celle du fichier téléchargé et compare. Si un seul octet avait changé (téléchargement interrompu, miroir compromis), vous liriez `FAILED`, et il faudrait tout recommencer. Ne sautez pas cette étape : c'est votre seule garantie que l'outil qui aura tous les droits sur votre cluster est bien celui publié par le projet.

On installe ensuite le binaire dans `~/.local/bin`, un dossier propre à votre utilisateur, ce qui évite `sudo` :

```bash
mkdir -p ~/.local/bin
install -m 0755 kubectl ~/.local/bin/kubectl
rm kubectl kubectl.sha256
kubectl version --client
```

```sortie
Client Version: v1.37.1
Kustomize Version: v5.8.1
```

Si la dernière commande répond `command not found`, `~/.local/bin` n'est pas dans votre `PATH`. Ubuntu et Fedora l'y ajoutent automatiquement dès que le dossier existe, mais seulement à l'ouverture de la session suivante. Ailleurs, ajoutez `export PATH="$HOME/.local/bin:$PATH"` à la fin de votre `~/.bashrc` (ou `~/.zshrc`) et ouvrez un nouveau terminal.

La ligne `Kustomize Version` n'est pas une erreur : kubectl embarque Kustomize, un outil de personnalisation de manifestes que nous utiliserons au chapitre 30.

:::panne[Deux kubectl sur la même machine]

Si vous avez déjà installé un kubectl par un autre moyen (paquet de la distribution, SDK Google Cloud, Docker Desktop), deux versions peuvent coexister, et c'est la première trouvée dans le `PATH` qui répond. `which -a kubectl` les liste toutes, dans l'ordre où le shell les essaie. Sur le poste de ce cours, cette commande en a trouvé deux : celle du cours, et un `/usr/bin/kubectl` installé par le SDK Google Cloud, qui se présente comme `v1.35.8-dispatcher`. Gardez celle dont la version est la plus proche de votre cluster, et vérifiez toujours avec `kubectl version` en cas de comportement étrange.

:::

## Installer minikube

Même principe que pour kubectl : un binaire, une empreinte, une vérification[^mk-start]. On fixe la version 1.39.0 plutôt que de prendre « la dernière », pour que votre installation corresponde exactement à celle du cours :

```bash
curl -LO https://github.com/kubernetes/minikube/releases/download/v1.39.0/minikube-linux-amd64
curl -LO https://github.com/kubernetes/minikube/releases/download/v1.39.0/minikube-linux-amd64.sha256
echo "$(cat minikube-linux-amd64.sha256)  minikube-linux-amd64" | sha256sum --check
```

```sortie
minikube-linux-amd64: OK
```

```bash
install -m 0755 minikube-linux-amd64 ~/.local/bin/minikube
rm minikube-linux-amd64 minikube-linux-amd64.sha256
minikube version
```

```sortie
minikube version: v1.39.0
commit: 7a9f6a841470a207de8cf4bafcccee0969d8ba10
```

Le binaire pèse 136 Mo. Il contient à la fois l'outil qui crée et gère les clusters, et tout ce qu'il faut pour préparer un nœud Kubernetes à l'intérieur d'un conteneur.

## Installer Helm

Helm est le gestionnaire de paquets de Kubernetes. Il n'interviendra qu'au chapitre 29, mais il s'installe de la même façon[^helm-install] :

```bash
curl -LO https://get.helm.sh/helm-v4.3.0-linux-amd64.tar.gz
curl -LO https://get.helm.sh/helm-v4.3.0-linux-amd64.tar.gz.sha256sum
sha256sum --check helm-v4.3.0-linux-amd64.tar.gz.sha256sum
```

```sortie
helm-v4.3.0-linux-amd64.tar.gz: OK
```

Cette fois, le fichier d'empreinte contient aussi le nom du fichier : `sha256sum --check` le lit directement, sans qu'on ait à le reconstruire avec `echo`. Le binaire est livré dans une archive, qu'on décompresse avant d'installer :

```bash
tar -xzf helm-v4.3.0-linux-amd64.tar.gz
install -m 0755 linux-amd64/helm ~/.local/bin/helm
rm -r linux-amd64 helm-v4.3.0-linux-amd64.tar.gz helm-v4.3.0-linux-amd64.tar.gz.sha256sum
helm version --short
```

```sortie
v4.3.0+gbec5b06
```

## Se faciliter la vie

Vous allez taper `kubectl` plusieurs milliers de fois. Deux réglages rendent la chose supportable. Le premier est la complétion : la touche Tab propose les sous-commandes, les options et même les noms des objets qui existent dans le cluster. Le second est un alias court. Ajoutez ces lignes à la fin de votre `~/.bashrc` :

```bash title="~/.bashrc"
source <(kubectl completion bash)
source <(minikube completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k
```

La dernière ligne branche la complétion de kubectl sur l'alias `k`. Si vous utilisez zsh, mettez l'équivalent dans `~/.zshrc` :

```bash title="~/.zshrc"
source <(kubectl completion zsh)
source <(minikube completion zsh)
alias k=kubectl
```

Ouvrez un nouveau terminal, tapez `kubectl get no` puis Tab : la commande se complète en `kubectl get nodes`. Dans le cours, on écrit toujours `kubectl` en entier pour que les commandes restent lisibles, mais rien ne vous empêche d'utiliser `k`.

Pour les fichiers YAML, n'importe quel éditeur convient. Si vous utilisez VS Code, l'extension YAML de Red Hat reconnaît les manifestes Kubernetes : elle souligne les champs mal orthographiés et affiche la documentation de chaque champ au survol. C'est un gain de temps réel dès la partie III, où une indentation de travers suffit à rendre un fichier invalide.

## Démarrer le cluster

Tout est en place. Voici la commande qui démarre le cluster du cours :

```bash
minikube start --driver=docker --cpus=2 --memory=4g --kubernetes-version=v1.37.0
```

Chaque option a son rôle. `--driver=docker` dit à minikube de fabriquer le nœud sous la forme d'un conteneur Docker ; il sait aussi créer des machines virtuelles (pilotes `kvm2`, `virtualbox`) ou utiliser Podman, mais le conteneur est le plus léger et le plus rapide. `--memory=4g` fixe la mémoire que le nœud a le droit de consommer : c'est un plafond, pas une réservation, et nous verrons plus bas que le cluster au repos en utilise bien moins. `--cpus=2` devrait faire de même pour le processeur, mais avec le pilote `docker` sous Linux, minikube 1.39 ne transmet pas cette limite au conteneur du nœud : `docker inspect minikube --format '{{.HostConfig.NanoCpus}}'` affiche `0`, c'est-à-dire aucune limite, et le nœud voit tous les cœurs du poste. Le chapitre 23 en montre la conséquence pour le scheduler. `--kubernetes-version=v1.37.0` fige la version de Kubernetes ; sans cette option, minikube prend sa version par défaut, qui changera avec les prochaines versions de minikube.

Au premier démarrage, minikube télécharge environ 850 Mo. Comptez une minute avec une bonne connexion ; les démarrages suivants réutilisent le cache et prennent une dizaine de secondes.

```sortie
* minikube v1.39.0 sur Ubuntu 26.04
* Utilisation du pilote docker basé sur la configuration de l'utilisateur
* Utilisation du pilote Docker avec le privilège root
* Démarrage du nœud "minikube" primary control-plane dans le cluster "minikube"
* Extraction de l'image de base v0.0.51...
* Téléchargement du préchargement de Kubernetes v1.37.0...
* Préparation de Kubernetes v1.37.0 sur containerd 2.3.4...
* Configuration de CNI (Container Networking Interface)...
* Vérification des composants Kubernetes...
  - Utilisation de l'image gcr.io/k8s-minikube/storage-provisioner:v5
* Modules activés: storage-provisioner, default-storageclass
* Terminé ! kubectl est maintenant configuré pour utiliser "minikube" cluster et espace de noms "default" par défaut.
```

Ces douze lignes résument une suite d'opérations qui se déroulent à trois endroits différents : sur votre poste, dans Docker, puis à l'intérieur du nœud.

<Figure svg={minikubeStartEtapes} num="0.2" alt="Les huit étapes de minikube start, réparties entre le poste, Docker Engine et le nœud minikube.">
Ce que fait <code>minikube start</code>, dans l'ordre. Les étapes 2 et 3 ne se produisent qu'au premier démarrage : ensuite, l'image de base et le préchargement sont dans le cache.
</Figure>

L'image de base, `kicbase`, est l'image du conteneur qui servira de nœud : une Debian minimale avec systemd, containerd et les outils de Kubernetes. Elle pèse 508 Mo à télécharger et 1,34 Go une fois décompressée. Le préchargement (*preload*) est une archive de 348 Mo qui contient déjà les images de tous les composants de Kubernetes v1.37.0 ; sans lui, le nœud devrait les télécharger une par une au démarrage. L'étape 6 est confiée à `kubeadm`, l'outil officiel d'installation de Kubernetes : il génère les certificats du cluster, puis démarre etcd, l'API server, le scheduler et le controller-manager. Nous le reverrons en détail dans la partie V.

Relisez maintenant la ligne `Préparation de Kubernetes v1.37.0 sur containerd 2.3.4`. À l'intérieur du nœud, ce n'est pas Docker qui lancera vos conteneurs, c'est containerd, le même composant que celui installé avec Docker tout à l'heure. Docker ne sert ici qu'à fabriquer la « machine » qui joue le rôle de nœud. Cette distinction paraît byzantine le premier jour ; elle deviendra évidente au chapitre 11.

### Attendre que tout soit prêt

`minikube start` rend la main dès que le plan de contrôle répond, pas quand tout le cluster est prêt. En écrivant ce chapitre, une commande lancée à cet instant précis ne voyait que quatre conteneurs dans le nœud au lieu de huit, et le nœud était encore marqué `NotReady` : le réseau des Pods et CoreDNS démarraient toujours. Plutôt que de deviner le bon moment, demandez à kubectl d'attendre :

```bash
kubectl wait --for=condition=Ready nodes --all --timeout=120s
kubectl wait -n kube-system --for=condition=Ready pods --all --timeout=180s
```

```sortie
node/minikube condition met
pod/coredns-559f6c778d-nhsbj condition met
pod/etcd-minikube condition met
pod/kindnet-29rsh condition met
pod/kube-apiserver-minikube condition met
pod/kube-controller-manager-minikube condition met
pod/kube-proxy-285v5 condition met
pod/kube-scheduler-minikube condition met
pod/storage-provisioner condition met
```

`kubectl wait` surveille des objets jusqu'à ce qu'une condition soit remplie, ou que le délai expire. Ici, on attend d'abord que tous les nœuds soient prêts, puis que tous les Pods du namespace `kube-system` le soient. Vous retrouverez cette commande dans les scripts de tout le cours : c'est la façon propre d'enchaîner des étapes sans `sleep` approximatif.

:::note[Messages en anglais]

minikube s'exprime dans la langue de votre système. Si votre session est en anglais, vous lirez « Preparing Kubernetes v1.37.0 on containerd 2.3.4... » à la place de la ligne ci-dessus. kubectl, lui, parle toujours anglais.

:::

## Ce qui tourne maintenant sur votre machine

Demandons à Docker la liste de ses conteneurs :

```bash
docker ps --format 'table {{.ID}}\t{{.Image}}\t{{.Names}}\t{{.Status}}'
```

```sortie
CONTAINER ID   IMAGE                                 NAMES      STATUS
adcf2db61dcd   gcr.io/k8s-minikube/kicbase:v0.0.51   minikube   Up 45 seconds
```

Un seul conteneur. Pourtant, un cluster Kubernetes compte une bonne dizaine de composants. Ils sont à l'intérieur de ce conteneur, lancés non pas par Docker mais par le containerd du nœud. `minikube ssh` ouvre un terminal dans le nœud, et `crictl` y joue le rôle que `docker ps` joue sur votre poste :

```bash
minikube ssh -- sudo crictl ps
```

```sortie
CONTAINER       IMAGE           CREATED          STATE     NAME                      ...
5ee08b5ec494c   520212b8b0fcd   11 seconds ago   Running   coredns                   ...
f9264a79e932e   6e38f40d628db   11 seconds ago   Running   storage-provisioner       ...
a97b1e7acb04d   4626fe10df5b9   22 seconds ago   Running   kindnet-cni               ...
702d6b57abcac   d6a28daf3e6b0   26 seconds ago   Running   kube-proxy                ...
5063572bf6e38   364b3c3d9ec19   38 seconds ago   Running   kube-controller-manager   ...
1964434c6ca5b   1fabf80a1273a   38 seconds ago   Running   kube-scheduler            ...
cc30511beae7a   270fbeb697171   38 seconds ago   Running   etcd                      ...
6ed4a6bd58f06   bec5f0e1e2eeb   38 seconds ago   Running   kube-apiserver            ...
```

Huit conteneurs dans le conteneur. La colonne `CREATED` raconte même l'ordre du démarrage : d'abord les quatre composants du plan de contrôle, puis kube-proxy, le réseau des Pods, et enfin CoreDNS. La sortie complète compte quatre colonnes de plus, coupées ici (`...`), dont le nom du Pod auquel appartient chaque conteneur. La figure suivante montre cet emboîtement.

<Figure svg={minikubePoupees} num="0.3" alt="Emboîtement : le poste Linux contient Docker Engine, qui contient le conteneur minikube (le nœud), dans lequel containerd lance les composants du plan de contrôle, les services du cluster et les Pods.">
Un cluster entier dans un conteneur. kubectl parle à l'API server par HTTPS sur le port 8443 ; les applications sont jointes par un port du nœud (NodePort). En vert, le plan de contrôle ; en gris, les services du cluster ; en bleu, un Pod d'application.
</Figure>

Ces poupées russes ont quelque chose de trompeur : on s'attend à ce que chaque niveau soit enfermé dans le précédent, comme dans une machine virtuelle. Or un conteneur n'est qu'un processus de votre machine. Cherchons l'API server depuis votre poste, sans passer ni par Docker ni par minikube :

```bash
ps -eo pid,user,rss,cmd --sort=-rss | grep '[k]ube-apiserver'
```

```sortie
 222633 root     287404 kube-apiserver --advertise-address=192.168.49.2 --allow-privileged=true ...
```

Il est là, dans la liste des processus de votre système, avec son numéro de processus (PID) et sa mémoire (287 Mo : la colonne RSS est en kilo-octets). Deux niveaux de conteneurs n'ont pas suffi à le cacher au noyau de votre machine. Ce qui l'isole, ce n'est pas une barrière physique : c'est le fait que le noyau lui montre une vue différente du système. C'est tout le sujet du chapitre 8.

## Parler au cluster

`minikube start` a écrit dans `~/.kube/config` tout ce dont kubectl a besoin pour joindre le cluster : son adresse, le certificat qui prouve son identité, et un certificat client qui vous identifie, vous. Ce fichier peut décrire plusieurs clusters ; celui qu'utilise kubectl s'appelle le contexte courant :

```bash
kubectl config current-context
kubectl cluster-info
```

```sortie
minikube
Kubernetes control plane is running at https://192.168.49.2:8443
CoreDNS is running at https://192.168.49.2:8443/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
```

L'adresse `192.168.49.2` est celle du conteneur `minikube` sur un réseau Docker créé pour l'occasion. Le port 8443 est celui de l'API server : c'est la seule porte d'entrée du cluster. Toutes les commandes kubectl que vous taperez dans ce cours deviennent des requêtes HTTPS vers cette adresse.

```bash
kubectl get nodes
```

```sortie
NAME       STATUS   ROLES           AGE   VERSION
minikube   Ready    control-plane   37s   v1.37.0
```

Un seul nœud, qui porte à la fois le plan de contrôle (les composants qui gèrent le cluster) et vos applications. Dans un vrai cluster, on les sépare ; au chapitre 32, nous démarrerons un minikube à trois nœuds pour voir comment Kubernetes répartit le travail. Le statut `Ready` signifie que le nœud accepte des Pods ; c'est ce que `kubectl wait` attendait tout à l'heure.

Enfin, la liste de tout ce qui tourne dans le cluster :

```bash
kubectl get pods --all-namespaces
```

```sortie
NAMESPACE     NAME                               READY   STATUS    RESTARTS   AGE
kube-system   coredns-559f6c778d-nhsbj           1/1     Running   0          27s
kube-system   etcd-minikube                      1/1     Running   0          34s
kube-system   kindnet-29rsh                      1/1     Running   0          27s
kube-system   kube-apiserver-minikube            1/1     Running   0          34s
kube-system   kube-controller-manager-minikube   1/1     Running   0          35s
kube-system   kube-proxy-285v5                   1/1     Running   0          27s
kube-system   kube-scheduler-minikube            1/1     Running   0          34s
kube-system   storage-provisioner                1/1     Running   0          32s
```

On retrouve les huit conteneurs de `crictl`, présentés cette fois comme des Pods rangés dans le namespace `kube-system`, réservé aux composants du cluster. Vous n'avez pas besoin de tout comprendre maintenant. En quelques mots :

| Pod | Rôle | Étudié au chapitre |
|---|---|---|
| `kube-apiserver` | reçoit et valide toutes les requêtes, seul à parler à etcd | 34 |
| `etcd` | base de données qui stocke l'état du cluster | 35 |
| `kube-controller-manager` | boucles qui ramènent le cluster vers l'état demandé | 36 |
| `kube-scheduler` | choisit le nœud de chaque nouveau Pod | 37 |
| `kube-proxy` | traduit les Services en règles réseau sur le nœud | 40 |
| `kindnet` | donne une adresse IP à chaque Pod et les relie entre eux | 39 |
| `coredns` | résout les noms des Services en adresses | 20 et 40 |
| `storage-provisioner` | crée des volumes à la demande, propre à minikube | 25 |

Un composant manque à l'appel : le kubelet, l'agent qui fait réellement démarrer les conteneurs sur le nœud. Il n'apparaît pas dans cette liste parce qu'il ne tourne pas dans un Pod. C'est un service systemd du nœud, qui lance les autres. Le chapitre 38 lui est consacré.

## Un premier déploiement pour vérifier

Le cluster répond ; vérifions qu'il sait faire tourner une application et la rendre accessible. Trois commandes suffisent :

```bash
kubectl create deployment bonjour --image=nginx:1.29-alpine
kubectl rollout status deployment/bonjour
kubectl expose deployment bonjour --type=NodePort --port=80
```

```sortie
deployment.apps/bonjour created
Waiting for deployment "bonjour" rollout to finish: 0 of 1 updated replicas are available...
deployment "bonjour" successfully rolled out
service/bonjour exposed
```

La première crée un Deployment, un objet qui demande à Kubernetes de maintenir en vie un serveur nginx. La deuxième attend que ce serveur soit prêt. La troisième crée un Service de type NodePort, qui ouvre un port du nœud et redirige ce qui y arrive vers nginx. minikube sait retrouver l'adresse complète :

```bash
minikube service bonjour --url
curl -s $(minikube service bonjour --url) | grep title
```

```sortie
http://192.168.49.2:30331
<title>Welcome to nginx!</title>
```

Le port 30331 a été choisi au hasard par Kubernetes dans une plage réservée (30000 à 32767) ; le vôtre sera différent. Vous pouvez aussi ouvrir cette adresse dans votre navigateur.

:::panne[curl ne répond rien juste après expose]

Si la toute première requête échoue, relancez-la une seconde plus tard. Le Service existe dès que `kubectl expose` rend la main, mais kube-proxy a besoin d'un instant pour écrire les règles réseau qui le font fonctionner. On a observé ce décalage en écrivant ce chapitre. Le chapitre 40 montre ces règles et le moment où elles apparaissent.

:::

Deployment, Service, NodePort : ces mots n'ont pour l'instant qu'un sens vague, et c'est normal. Ils sont le sujet de la partie III. Retenez surtout que votre chaîne complète fonctionne : Docker, minikube, kubectl et le cluster.

## Une interface graphique : Headlamp

Beaucoup de tutoriels proposent `minikube dashboard`, qui installe le tableau de bord historique de Kubernetes. Ce projet est archivé : ses mainteneurs ont annoncé qu'il n'était plus maintenu et recommandent Headlamp à la place[^dashboard]. minikube propose Headlamp sous forme d'addon :

```bash
minikube addons enable headlamp
```

```sortie
! headlamp est un module complémentaire tiers et non maintenu ou vérifié par les mainteneurs de minikube, activez-le à vos risques et périls.
  - Utilisation de l'image ghcr.io/headlamp-k8s/headlamp:v0.45.0
* Pour accéder à Headlamp, utilisez la commande suivante :

	minikube service headlamp -n headlamp

* To authenticate in Headlamp, fetch the Authentication Token using the following command:

        kubectl create token headlamp --duration 24h -n headlamp
...
* Le module 'headlamp' est activé
```

L'avertissement est honnête : l'addon est maintenu par l'équipe de Headlamp, pas par celle de minikube. La sortie donne aussi les deux commandes utiles. La première ouvre l'interface dans votre navigateur :

```bash
minikube service headlamp -n headlamp
```

Headlamp demande alors un jeton d'authentification. La seconde commande le fabrique :

```bash
kubectl create token headlamp --duration 24h -n headlamp
```

Elle affiche une longue chaîne de près de mille caractères qui commence par `eyJhbGciOi` ; collez-la dans le champ de connexion. Vous pouvez alors parcourir les namespaces, les Pods, leurs journaux, et retrouver le Deployment `bonjour`.

:::warning[Ce jeton ouvre tout le cluster]

L'addon relie le compte `headlamp` au rôle `cluster-admin`, le plus puissant qui existe. Vous pouvez le vérifier :

```bash
kubectl get clusterrolebinding headlamp-admin -o wide
```

Quiconque possède ce jeton peut tout lire, tout modifier et tout supprimer dans le cluster pendant 24 heures. Sur minikube, c'est sans conséquence. Sur un cluster partagé, on ne distribue jamais un tel jeton ; les chapitres 42 et 43 montrent comment donner à chacun exactement les droits dont il a besoin.

:::

Ce cours utilise surtout kubectl, parce que c'est l'outil que vous aurez toujours sous la main, sur n'importe quel cluster, et parce qu'il montre exactement ce qu'on demande à Kubernetes. Headlamp est pratique pour avoir une vue d'ensemble ou lire des journaux ; servez-vous-en comme d'une vitrine, pas comme d'un tableau de commande.

## Arrêter, reprendre, supprimer

Le cluster consomme de la mémoire tant qu'il tourne. Quand vous ne travaillez pas sur le cours, arrêtez-le :

```bash
minikube stop
```

```sortie
* Arrêt du nœud  "minikube" ...
* Mise hors tension du profil "minikube" via SSH…
* 1 nœud arrêté.
```

L'arrêt prend six à dix secondes. Le conteneur `minikube` est arrêté mais pas supprimé : son disque, et donc etcd avec tout l'état du cluster, est conservé. `minikube start`, sans aucune option cette fois, le relance avec les réglages du premier démarrage :

```bash
minikube start
kubectl get deployments --all-namespaces
```

```sortie
...
* Terminé ! kubectl est maintenant configuré pour utiliser "minikube" cluster et espace de noms "default" par défaut.
NAMESPACE     NAME       READY   UP-TO-DATE   AVAILABLE   AGE
default       bonjour    1/1     1            1           34s
headlamp      headlamp   1/1     1            1           27s
kube-system   coredns    1/1     1            1           69s
```

Onze secondes, et `bonjour` est de nouveau là (la colonne `AGE` compte depuis la création de l'objet, pas depuis le redémarrage). Kubernetes n'a rien « restauré » : au redémarrage, les contrôleurs ont relu dans etcd ce qui devait exister et ont relancé les conteneurs correspondants. C'est le principe de l'état désiré, sur lequel repose tout Kubernetes.

Deux autres commandes complètent le tableau. `minikube pause` gèle les conteneurs du plan de contrôle sans arrêter le nœud, pour libérer du processeur quelques minutes ; `minikube unpause` les réveille. `minikube delete`, en revanche, détruit le conteneur et tout ce qu'il contient : le cluster suivant repartira de zéro, mais le cache des téléchargements est conservé. Pour tout effacer, cache compris, `minikube delete --all --purge` supprime tous les clusters et le dossier `~/.minikube`.

minikube sait gérer plusieurs clusters à la fois, appelés profils. Celui que vous venez de créer s'appelle `minikube`, le nom par défaut. L'option `-p` en crée d'autres (`minikube start -p essai`), et `minikube profile list` les affiche :

```sortie
┌──────────┬────────┬────────────┬──────────────┬─────────┬────────┬───────┬────────────────┬────────────────────┐
│ PROFILE  │ DRIVER │  RUNTIME   │      IP      │ VERSION │ STATUS │ NODES │ ACTIVE PROFILE │ ACTIVE KUBECONTEXT │
├──────────┼────────┼────────────┼──────────────┼─────────┼────────┼───────┼────────────────┼────────────────────┤
│ minikube │ docker │ containerd │ 192.168.49.2 │ v1.37.0 │ OK     │ 1     │ *              │ *                  │
└──────────┴────────┴────────────┴──────────────┴─────────┴────────┴───────┴────────────────┴────────────────────┘
```

Chaque profil a son propre conteneur et son propre contexte kubectl. Nous nous en servirons pour les chapitres qui demandent une configuration particulière (plusieurs nœuds, un autre réseau de Pods), sans toucher au cluster principal.

## Quand quelque chose ne va pas

Les pannes ci-dessous sont celles qu'on rencontre le plus souvent à ce stade. Les messages sont reproduits tels qu'ils s'affichent.

:::panne[RSRC_OVER_ALLOC_MEM]

```sortie
X Fermeture en raison de RSRC_OVER_ALLOC_MEM : L'allocation de mémoire demandée 65536 Mo est supérieure à la limite de votre système 15408 Mo.
* Suggestion : Start minikube with less memory allocated: 'minikube start --memory=3800mb'
```

Vous avez demandé plus de mémoire que la machine n'en possède. minikube refuse avant de créer le conteneur, et propose une valeur raisonnable. Relancez avec `--memory=4g`, ou moins si votre machine a moins de 8 Go. Si la tentative ratée visait un profil nommé (`-p essai`), minikube en garde une trace : `minikube profile list` signale ensuite `1 profil(s) invalide(s) trouvé(s)` et propose la commande qui le retire, `minikube delete -p essai`.

:::

:::panne[version difference between client and server exceeds the supported minor version skew]

```sortie
Client Version: v1.35.8
Server Version: v1.37.0
Warning: version difference between client (1.35) and server (1.37) exceeds the supported minor version skew of +/-1
```

Votre kubectl est trop ancien (ou trop récent) pour ce cluster. Les commandes semblent fonctionner, et c'est ce qui rend le piège sournois : certaines options récentes sont ignorées sans erreur. Installez un kubectl de la même version mineure que le cluster, à une version près. Le chapitre 0.3 explique cette règle.

:::

:::panne[kubectl parle au mauvais cluster]

Si vous avez déjà utilisé kind, un cluster d'entreprise ou un second profil minikube, `~/.kube/config` contient plusieurs contextes. Démarrer un profil minikube fait de lui le contexte courant, ce qui peut surprendre. Vérifiez où vous êtes avant toute commande qui modifie quelque chose. Voici ce qu'affichait le poste du cours juste après le démarrage d'un second profil, `essai-podman` (les autres contextes de la machine ont été retirés de la sortie) :

```bash
kubectl config get-contexts
```

```sortie
CURRENT   NAME           CLUSTER        AUTHINFO       NAMESPACE
*         essai-podman   essai-podman   essai-podman   default
          minikube       minikube       minikube       default
```

L'étoile marque le contexte courant. `kubectl config use-context minikube` revient au cluster du cours ; `minikube profile minikube` fait la même chose et règle en plus le profil par défaut de minikube.

:::

:::panne[Unable to resolve the current Docker CLI context "default"]

minikube affiche parfois cet avertissement au début de chaque commande, suivi du conseil `docker context use default`. Il est sans conséquence : minikube cherche un fichier de métadonnées que le contexte Docker par défaut n'a jamais. Il apparaît quand `~/.docker/config.json` contient la ligne `"currentContext": "default"`, souvent laissée par une ancienne installation de Docker Desktop. Suivre le conseil ne le fait pas disparaître ; retirer cette ligne du fichier, si.

:::

Derrière un proxy d'entreprise ou un VPN, le cluster peut démarrer sans parvenir à télécharger ses images. La documentation de minikube indique qu'il faut alors exporter `HTTP_PROXY` et `HTTPS_PROXY`, et ajouter à `NO_PROXY` le réseau du cluster (`192.168.49.0/24`) pour que kubectl ne passe pas par le proxy pour le joindre[^mk-proxy]. Cette configuration n'a pas pu être éprouvée pour ce cours ; si vous êtes dans ce cas, commencez par vérifier que `docker pull nginx` fonctionne.

## Avec Podman

Si vous préférez Podman à Docker, ou si vous n'avez pas les droits d'administration pour installer Docker, minikube sait utiliser Podman en mode rootless : tout tourne alors sous votre utilisateur, sans démon et sans `sudo`. Le pilote est encore marqué expérimental[^mk-podman], mais le parcours ci-dessous a été éprouvé de bout en bout avec Podman 5.7.

Le mode rootless demande que systemd délègue à votre utilisateur le contrôle du processeur et de la mémoire. Vérifiez-le :

```bash
cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers
```

```sortie
cpu memory pids
```

Si `cpu` ou `memory` manque, la documentation de Podman explique comment activer la délégation. Ensuite, on indique à minikube qu'il travaille sans root, puis on démarre le cluster :

```bash
minikube config set rootless true
minikube start -p k8s-podman --driver=podman --container-runtime=containerd --cpus=2 --memory=4g --kubernetes-version=v1.37.0
```

La deuxième commande crée un profil séparé, `k8s-podman`, pour ne pas mélanger ce cluster avec celui du pilote Docker. Le démarrage affiche un message d'erreur inquiétant mais sans conséquence :

```sortie
* [k8s-podman] minikube v1.39.0 sur Ubuntu 26.04
  - MINIKUBE_ROOTLESS=true
* Utilisation du pilote podman basé sur la configuration de l'utilisateur
* Utilisation du pilote Podman sans root
* Démarrage du nœud "k8s-podman" primary control-plane dans le cluster "k8s-podman"
* Extraction de l'image de base v0.0.51...
E0925 10:17:58.131105  235506 cache.go:238] Error downloading kic artifacts:  not yet implemented, see issue #8426
* Préparation de Kubernetes v1.37.0 sur containerd 2.3.4...
* Configuration de CNI (Container Networking Interface)...
* Vérification des composants Kubernetes...
  - Utilisation de l'image gcr.io/k8s-minikube/storage-provisioner:v5
* Modules activés: storage-provisioner, default-storageclass
* Terminé ! kubectl est maintenant configuré pour utiliser "k8s-podman" cluster et espace de noms "default" par défaut.
```

Trois pièges ont été rencontrés en éprouvant ce parcours.

:::panne[unable to select an IP from lo network interface]

Le démarrage échoue pendant `kubeadm init` avec ce message si le profil s'appelle `podman`. minikube crée un réseau portant le nom du profil ; or Podman possède déjà un réseau par défaut nommé `podman`. Le nœud se retrouve rattaché à ce réseau-là, sans adresse utilisable, et kubeadm ne trouve aucune interface pour l'API server. Supprimez le profil raté avec `MINIKUBE_ROOTLESS=true minikube delete -p podman` et choisissez un autre nom.

:::

:::panne[GUEST_STOP_TIMEOUT : sudo: interactive authentication is required]

C'est ce qui arrive si le mode rootless n'a été activé que pour une commande, par la variable d'environnement `MINIKUBE_ROOTLESS=true`, au lieu de l'être par `minikube config set rootless true`. Les commandes suivantes, `minikube stop` en tête, retombent alors sur `sudo podman` et échouent. Activez le réglage, ou répétez la variable devant chaque commande qui vise ce profil.

:::

Le troisième piège est plus sournois, parce qu'il ne produit aucun message. `minikube config set rootless true` est un réglage global : il s'applique à tous les profils. Avec ce réglage actif, la création d'un nouveau cluster avec le pilote Docker s'arrête net après la ligne `Utilisation du pilote docker`, sans explication, avec le code de retour 14. Un cluster Docker déjà créé, lui, continue de démarrer normalement. Si vous n'utilisez que Podman, gardez le réglage. Si vous alternez entre les deux moteurs, retirez-le (`minikube config unset rootless`) et préfixez plutôt chaque commande du profil Podman par `MINIKUBE_ROOTLESS=true`.

Reste l'accès aux applications. En mode rootless, l'adresse du nœud n'est pas joignable depuis votre poste. `minikube service` crée alors un tunnel vers `127.0.0.1`, qui ne vit que tant que la commande tourne :

```bash
minikube -p k8s-podman service bonjour --url
```

```sortie
http://127.0.0.1:34981
! Comme vous utilisez un pilote Docker sur linux, le terminal doit être ouvert pour l'exécuter.
```

Laissez ce terminal ouvert et utilisez l'adresse dans un autre : `curl http://127.0.0.1:34981` renvoie bien la page de nginx. Le message parle de pilote Docker alors que vous utilisez Podman : c'est une approximation de minikube, le comportement est bien celui décrit.

## Exercices

:::exercice[Exercice 1 : ce que le cluster consomme vraiment]

Le cluster a le droit d'utiliser 4 Go de mémoire. Combien en utilise-t-il au repos ? Trouvez une commande Docker qui répond, puis refaites la mesure après avoir activé Headlamp.

:::

<details>
<summary>Corrigé</summary>

```bash
docker stats --no-stream minikube --format '{{.MemUsage}}'
```

Sur le poste du cours, cette commande a affiché `528.5MiB / 4GiB` juste après un démarrage, puis entre `630MiB` et `730MiB` avec Headlamp et le déploiement `bonjour`. La valeur varie d'une mesure à l'autre : le cluster n'est jamais complètement immobile. Le chiffre de droite est le plafond fixé par `--memory=4g`. Le cluster n'occupe que ce dont il a besoin ; le plafond garantit seulement qu'il ne dépassera jamais 4 Go, même si une application s'emballe. Ce plafond est posé par un cgroup, exactement comme ceux du chapitre 9.

</details>

:::exercice[Exercice 2 : un processus, deux numéros]

Vous avez trouvé le PID de `kube-apiserver` depuis votre poste avec `ps`. Cherchez maintenant le PID de ce même processus vu depuis l'intérieur du nœud. Puis regardez quel processus porte le PID 1 dans le nœud. Que pouvez-vous en conclure ?

:::

<details>
<summary>Corrigé</summary>

```bash
pgrep -a kube-apiserver
minikube ssh -- pgrep -a kube-apiserver
minikube ssh -- ps -o pid,comm -p 1
```

```sortie
228772 kube-apiserver --advertise-address=192.168.49.2 ...
1150 kube-apiserver --advertise-address=192.168.49.2 ...
    PID COMMAND
      1 systemd
```

C'est le même processus, mais il porte le numéro 228772 pour votre poste et 1150 pour le nœud. Et dans le nœud, le PID 1, normalement réservé au tout premier programme lancé au démarrage d'une machine, est un systemd qui n'est pas celui de votre poste. Le noyau tient donc deux numérotations des processus : celle de la machine, et une numérotation privée pour tout ce qui vit dans le conteneur. C'est un *PID namespace*, l'un des mécanismes du chapitre 8.

</details>

:::exercice[Exercice 3 : ce qui survit à un redémarrage]

Créez un second Deployment (`kubectl create deployment essai --image=nginx:1.29-alpine`). Arrêtez le cluster, redémarrez-le, et vérifiez qu'`essai` existe toujours. Recommencez avec `minikube delete` à la place de `minikube stop`. Qu'est-ce qui fait la différence ?

:::

<details>
<summary>Corrigé</summary>

Après `minikube stop` puis `minikube start`, `kubectl get deployments` montre toujours `bonjour` et `essai`. Après `minikube delete` puis `minikube start --driver=docker --cpus=2 --memory=4g --kubernetes-version=v1.37.0`, il n'y a plus que `coredns` dans `kube-system`. `stop` arrête le conteneur du nœud mais garde son disque, où etcd enregistre l'état du cluster. `delete` supprime le conteneur et son disque, donc etcd et tout ce qu'il contenait. Pensez-y avant de taper `delete` : un cluster minikube n'a aucune sauvegarde. Le chapitre 52 montre comment en faire une.

</details>

:::exercice[Exercice 4 : le jeton de Headlamp]

L'API server du cluster écoute sur `https://192.168.49.2:8443`. Interrogez-la avec `curl` pour lister les namespaces, une fois sans rien fournir, une fois avec le jeton de Headlamp dans l'en-tête `Authorization: Bearer ...`. L'option `-k` de curl ignore le certificat du cluster, que votre système ne connaît pas.

:::

<details>
<summary>Corrigé</summary>

```bash
curl -sk https://192.168.49.2:8443/api/v1/namespaces | grep message
TOKEN=$(kubectl create token headlamp --duration 1h -n headlamp)
curl -sk -H "Authorization: Bearer $TOKEN" https://192.168.49.2:8443/api/v1/namespaces | grep '"name"'
```

```sortie
  "message": "namespaces is forbidden: User \"system:anonymous\" cannot list resource \"namespaces\" in API group \"\" at the cluster scope",
        "name": "default",
        "name": "headlamp",
        "name": "kube-node-lease",
        "name": "kube-public",
        "name": "kube-system",
```

Sans jeton, l'API server vous traite comme l'utilisateur anonyme et refuse. Avec le jeton, il vous traite comme le compte `headlamp` et répond, puisque ce compte a tous les droits. Deux leçons pour la suite : l'API server est un serveur HTTPS ordinaire, que n'importe quel client peut interroger (kubectl n'est qu'un client parmi d'autres, chapitre 34) ; et chaque requête est authentifiée puis autorisée avant d'être traitée (chapitres 42 et 43).

</details>

## Accès aux interfaces

| Interface | Comment l'ouvrir |
|---|---|
| Application de test `bonjour` | `minikube service bonjour --url`, puis l'adresse dans un navigateur |
| Headlamp | `minikube service headlamp -n headlamp`, puis le jeton de `kubectl create token headlamp --duration 24h -n headlamp` |

## Nettoyer

Le Deployment `bonjour` ne servira plus. Supprimez-le avec son Service, puis arrêtez le cluster si vous en avez fini pour aujourd'hui :

```bash
kubectl delete service,deployment bonjour
minikube stop
```

Headlamp peut rester activé ; `minikube addons disable headlamp` le retire si vous préférez économiser un peu de mémoire. Si vous avez créé le profil Podman, `minikube delete -p k8s-podman` le supprime (préfixé par `MINIKUBE_ROOTLESS=true` si vous avez retiré le réglage global).

[^mk-start]: minikube, « minikube start », section *What you'll need*. [minikube.sigs.k8s.io/docs/start](https://minikube.sigs.k8s.io/docs/start/)

[^wsl]: Microsoft, « Install WSL ». [learn.microsoft.com/windows/wsl/install](https://learn.microsoft.com/windows/wsl/install)

[^docker-install]: Docker, « Install Docker Engine on Ubuntu » (et les pages Debian et Fedora de la même section). [docs.docker.com/engine/install/ubuntu](https://docs.docker.com/engine/install/ubuntu/)

[^docker-group]: Docker, « Linux post-installation steps for Docker Engine », avertissement sur le groupe `docker` ; voir aussi « Docker Engine security », section *Docker daemon attack surface*. [docs.docker.com/engine/install/linux-postinstall](https://docs.docker.com/engine/install/linux-postinstall/)

[^kubectl-install]: Kubernetes, « Install and Set Up kubectl on Linux ». [kubernetes.io/docs/tasks/tools/install-kubectl-linux](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/)

[^helm-install]: Helm, « Installing Helm », section *From the Binary Releases*. [helm.sh/docs/intro/install](https://helm.sh/docs/intro/install/)

[^dashboard]: Dépôt `kubernetes/dashboard`, avis d'archivage en tête du README. [github.com/kubernetes/dashboard](https://github.com/kubernetes/dashboard)

[^mk-proxy]: minikube, « Proxies and VPNs ». [minikube.sigs.k8s.io/docs/handbook/vpn_and_proxy](https://minikube.sigs.k8s.io/docs/handbook/vpn_and_proxy/)

[^mk-podman]: minikube, « podman » (pilote), sections *Experimental* et *Known issues*. [minikube.sigs.k8s.io/docs/drivers/podman](https://minikube.sigs.k8s.io/docs/drivers/podman/)
