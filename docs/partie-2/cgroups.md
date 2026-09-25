---
title: Les cgroups
sidebar_label: 9. Les cgroups
description: Comment le noyau limite et mesure la mémoire, le processeur et le nombre de processus d'un conteneur ; l'arbre des cgroups v2, les options de Docker traduites en fichiers, un OOM kill provoqué et expliqué.
partie: 2
chapitre: '9'
---

import arbreCgroups from '@site/src/figures/arbre-cgroups.svg';
import quotaCpu from '@site/src/figures/quota-cpu.svg';

Au chapitre 2, un conteneur tué affichait le code 137, et l'on annonçait qu'il avait deux origines possibles : un `docker stop` qui a dû forcer, ou le noyau qui tue un processus ayant dépassé sa limite de mémoire. Au chapitre 0.2, le cluster minikube avait « le droit » d'utiliser 4 Go. Ces limites ne sont pas des promesses faites par Docker : elles sont appliquées par le noyau, à chaque allocation de mémoire et à chaque tranche de temps de processeur, grâce aux **groupes de contrôle**, les cgroups.

Les namespaces du chapitre précédent décident de ce qu'un processus voit. Les cgroups décident de ce qu'il consomme. Ce chapitre les manipule à la main, dans le laboratoire du chapitre 8, jusqu'à provoquer volontairement un OOM kill et à le lire dans les journaux du noyau.

Relancez le laboratoire et la cible si vous les avez arrêtés :

```bash
docker run -d --name cible nginx:1.30-alpine
docker run -it --rm --name labo --hostname labo \
  --privileged --pid=host --cgroupns=host -v labo:/labo labo:1.0
```

L'option `--cgroupns=host` prend ici tout son sens : elle montre au laboratoire l'arbre complet des cgroups de la machine, et non la seule branche d'un conteneur.

## Un arbre de groupes de processus

Un cgroup est un groupe de processus auquel le noyau applique des règles de consommation et dont il tient les comptes. Les cgroups forment un arbre : chaque groupe peut contenir des sous-groupes, et une limite posée sur un groupe s'applique à tout ce qu'il contient. Le noyau présente cet arbre comme un système de fichiers, monté sur `/sys/fs/cgroup` : chaque cgroup est un dossier, et chaque réglage un fichier[^cgroup-v2].

À quel cgroup appartient un processus ? Le fichier `/proc/<pid>/cgroup` le dit. Pour le processus 1 de la machine, puis pour nginx dans le conteneur `cible` (son numéro, 511634, vient du `docker inspect` du chapitre 8) :

```bash
cat /proc/1/cgroup
cat /proc/511634/cgroup
```

```sortie
0::/init.scope
0::/system.slice/docker-090cfd7665399f9386ad5988ba7c9305268ad7ae808e994aa503528e8ea04758.scope
```

nginx vit dans le cgroup `/system.slice/docker-090cfd76....scope`, dont le nom contient l'identifiant complet du conteneur. Le `0::` initial indique la version 2 des cgroups, celle qui a remplacé l'ancienne à partir de 2016 : une hiérarchie unique pour toutes les ressources, là où la version 1 en avait une par ressource. Toutes les distributions récentes l'utilisent ; c'est ce que vérifiait la commande `stat -fc %T /sys/fs/cgroup/` du chapitre 0.2.

La racine de l'arbre annonce les **contrôleurs** disponibles, c'est-à-dire les ressources que le noyau sait gérer :

```bash
cat /sys/fs/cgroup/cgroup.controllers
```

```sortie
cpuset cpu io memory hugetlb pids rdma misc dmem
```

`cpu` pour le temps de processeur, `memory` pour la mémoire, `io` pour les lectures et écritures sur disque, `pids` pour le nombre de processus, `cpuset` pour épingler des processus sur certains processeurs. Juste sous la racine, on trouve les grandes branches créées par systemd : `init.scope` pour systemd lui-même, `system.slice` pour les services, `user.slice` pour les sessions des utilisateurs, `machine.slice` pour les machines virtuelles.

<Figure svg={arbreCgroups} num="9.1" alt="Arbre des cgroups : sous la racine, init.scope, user.slice, system.slice et machine.slice. Sous system.slice, docker.service et deux scopes de conteneurs : cible, sans limite, et limite, avec memory.max 67108864, cpu.max 50000 100000 et pids.max 50.">
L'arbre des cgroups du poste du cours. Docker range chaque conteneur dans un cgroup à lui, sous <code>system.slice</code>, et traduit ses options en valeurs dans les fichiers de ce cgroup.
</Figure>

Docker demande à systemd de créer un cgroup par conteneur, en tant qu'unité de type *scope*. C'est le rôle du pilote de cgroups `systemd` de Docker, celui qu'affichait `docker info` au chapitre 0.2. Kubernetes fait de même avec le kubelet, qui range chaque Pod dans son propre cgroup.

## Ce que contient un cgroup

Entrons dans le cgroup de `cible` :

```bash
cd /sys/fs/cgroup/system.slice/docker-090cfd7665399f9386ad5988ba7c9305268ad7ae808e994aa503528e8ea04758.scope
cat memory.current memory.max cpu.max pids.current pids.max
wc -l < cgroup.procs
```

```sortie
19206144
max
max 100000
23
16221
23
```

Chaque fichier répond à une question. `memory.current` : le conteneur utilise 19,2 Mo. `memory.max` : aucune limite, d'où la valeur `max`. `cpu.max` : aucun quota de processeur. `pids.current` : 23 processus, nginx et ses 22 *workers*, qu'on retrouve listés, un par ligne, dans `cgroup.procs`.

`pids.max` réserve une surprise : 16221, alors qu'on n'a rien demandé. Ce n'est pas Docker, mais systemd, qui pose par défaut une limite `TasksMax` sur chaque unité qu'il crée :

```bash
systemctl show docker-090cfd76....scope -p TasksMax      # sur votre poste
systemctl show -p DefaultTasksMax
```

```sortie
TasksMax=16221
DefaultTasksMax=16221
```

Cette valeur représente 15 % du nombre maximal de processus du noyau (`/proc/sys/kernel/threads-max` vaut 108142 sur le poste du cours). Sur une autre machine, elle sera différente. C'est un bon exemple d'une limite qui existe sans que personne ne l'ait choisie, et qu'on découvre le jour où une application qui lance beaucoup de processus légers atteint le plafond.

## Les options de Docker, traduites en fichiers

Lançons un second conteneur, avec trois limites :

```bash
docker run -d --name limite --memory 64m --cpus 0.5 --pids-limit 50 nginx:1.30-alpine
docker stats --no-stream limite --format 'table {{.Name}}\t{{.MemUsage}}\t{{.PIDs}}'
```

```sortie
NAME      MEM USAGE / LIMIT   PIDS
limite    18.45MiB / 64MiB    23
```

`docker stats` affiche maintenant 64 Mio comme limite. D'où vient ce chiffre ? Du cgroup du conteneur :

```bash
cd /sys/fs/cgroup/system.slice/docker-500cc0c5f8fe....scope
for f in memory.max memory.swap.max cpu.max pids.max pids.current; do printf '%-16s %s\n' $f "$(cat $f)"; done
```

```sortie
memory.max       67108864
memory.swap.max  67108864
cpu.max          50000 100000
pids.max         50
pids.current     23
```

Chaque option est devenue un nombre dans un fichier :

| Option de `docker run` | Fichier du cgroup | Valeur | Signification |
|---|---|---|---|
| `--memory 64m` | `memory.max` | 67108864 | 64 × 1024 × 1024 octets |
| (implicite) | `memory.swap.max` | 67108864 | autant de swap que de mémoire |
| `--cpus 0.5` | `cpu.max` | `50000 100000` | 50 ms de processeur par période de 100 ms |
| `--pids-limit 50` | `pids.max` | 50 | au plus 50 processus |

La deuxième ligne mérite une explication. Par défaut, Docker autorise un conteneur limité en mémoire à utiliser autant d'espace d'échange (*swap*) que de mémoire : au total, le double. Le poste du cours n'a pas de swap, donc cette autorisation ne change rien ici ; sur une machine qui en a, un conteneur limité à 64 Mo peut en réalité occuper 128 Mo, dont la moitié sur le disque, avec des performances effondrées. L'option `--memory-swap` règle ce comportement. Kubernetes, par défaut, n'autorise pas de swap du tout.

`docker stats` ne fait que lire des fichiers comme ceux-ci. Tout outil de supervision de conteneurs, cAdvisor ou le kubelet de Kubernetes, fait la même chose : il parcourt `/sys/fs/cgroup`.

## Un cgroup fait à la main

Créer un cgroup, c'est créer un dossier. Faisons-le à la racine de l'arbre :

```bash
mkdir /sys/fs/cgroup/essai-memoire
cd /sys/fs/cgroup/essai-memoire
ls | wc -l
cat memory.max memory.current
```

```sortie
86
max
0
```

Le noyau a peuplé le dossier de 86 fichiers dès sa création : c'est lui qui gère ce système de fichiers, pas vous. Le cgroup est vide, sans limite. Fixons une limite de 50 Mo, sans swap :

```bash
echo 50M > memory.max
echo 0 > memory.swap.max
cat memory.max memory.swap.max
```

```sortie
52428800
0
```

Pour placer un processus dans un cgroup, on écrit son numéro dans le fichier `cgroup.procs`. Un processus qui y écrit son propre numéro (`$$` en shell) s'y place lui-même, et tous les processus qu'il lancera ensuite y naîtront.

### Provoquer un OOM kill

Lançons, dans ce cgroup, un programme qui veut 200 Mo. `stress-ng`, présent dans le laboratoire, sait réclamer une quantité de mémoire donnée ; l'option `--oomable` lui interdit de relancer son processus de travail s'il est tué, pour que l'expérience reste lisible :

```bash
bash -c 'echo $$ > /sys/fs/cgroup/essai-memoire/cgroup.procs
         exec stress-ng --vm 1 --vm-bytes 200M --vm-keep --oomable --timeout 10s'
grep -E '^(max|oom|oom_kill) ' memory.events
cat memory.peak
```

```sortie
stress-ng: info:  [576736] passed: 1: vm (1)
stress-ng: info:  [576736] successful run completed in 0 secs
max 112
oom 1
oom_kill 1
52428800
```

Le fichier `memory.events` raconte ce qui s'est passé. `max 112` : 112 fois, une allocation a buté sur la limite, et le noyau a tenté de récupérer de la mémoire dans le cgroup (en vidant ses caches de fichiers, par exemple). `oom 1` : une fois, il n'a rien pu récupérer ; le cgroup était à court de mémoire, *out of memory*. `oom_kill 1` : il a alors tué un processus du cgroup pour libérer de la place. `memory.peak` confirme que la consommation n'a jamais dépassé 52428800 octets, exactement la limite. `stress-ng` se déclare satisfait : son processus de travail est mort, mais `--oomable` lui a dit de l'accepter.

Le noyau consigne chaque OOM kill dans son journal, que `dmesg` affiche :

```bash
dmesg | grep -i 'Killed process' | tail -1
```

```sortie
[78998.822793] Memory cgroup out of memory: Killed process 576740 (stress-ng-vm) total-vm:273556kB, anon-rss:49408kB, file-rss:580kB, shmem-rss:32kB, UID:0 pgtables:188kB oom_score_adj:1000
```

`Memory cgroup out of memory` : ce n'est pas la machine qui manquait de mémoire, c'est le cgroup. Le poste avait à ce moment plus de 7 Go disponibles. `anon-rss:49408kB` : le processus occupait 48 Mo de mémoire au moment où il a été tué, à peine moins que la limite. `oom_score_adj:1000` : stress-ng s'était volontairement désigné comme premier candidat au sacrifice.

C'est la réponse à la question du début : un conteneur peut être tué alors que la machine a de la mémoire libre, parce que la limite est celle de son cgroup, pas celle de la machine.

### Le même OOM, vu par Docker

Reproduisons l'expérience avec Docker, sur votre poste, avec un programme Python qui réclame 200 Mo dans un conteneur limité à 64 :

```bash
docker run --name gourmand --memory 64m python:3.14-slim python -c 'b = bytearray(200 * 1024 * 1024); print("alloué")'
echo "code=$?"
docker inspect gourmand --format 'OOMKilled={{.State.OOMKilled}} code={{.State.ExitCode}}'
```

```sortie
code=137
OOMKilled=true code=137
```

Le mot « alloué » n'apparaît jamais : Python est tué avant d'avoir fini son allocation. Le code 137 (128 + 9, SIGKILL) est celui du chapitre 2, et `OOMKilled=true` lève l'ambiguïté : ce n'est pas un `docker stop` qui a forcé, c'est le noyau. Docker publie aussi un événement au moment du kill, que `docker events --filter event=oom` permet de suivre en direct :

```sortie
oom gourmand exitCode=<no value>
die gourmand exitCode=137
```

Dans Kubernetes, le même événement s'affiche sous la forme d'un Pod à l'état `OOMKilled`, qui redémarre en boucle si la limite est trop basse pour l'application. Le chapitre 49 en fait l'une des pannes de son catalogue ; vous savez maintenant exactement ce qu'elle signifie.

:::panne[Un conteneur qui voit toute la mémoire de la machine]

Dans un conteneur limité à 256 Mo, la commande `free` affiche pourtant toute la mémoire de la machine :

```sortie
              total        used        free      shared  buff/cache   available
Mem:          15408        4671         583        7286       10154        3107
```

`free` lit `/proc/meminfo`, qui décrit la machine, pas le cgroup. Une application qui dimensionne ses caches ou ses fils d'exécution d'après `/proc/meminfo` ou le nombre de processeurs de la machine se croit riche, consomme en conséquence, et se fait tuer. C'était un problème célèbre des anciennes machines virtuelles Java. La limite réelle se lit dans le cgroup, que le conteneur voit dans son propre namespace de cgroup : `cat /sys/fs/cgroup/memory.max` y affiche `268435456`. Les environnements d'exécution récents (Java depuis la version 10, Go, .NET) lisent ces fichiers ; vérifiez que les vôtres le font.

:::

## Limiter le processeur

La mémoire est une ressource qu'on ne peut pas reprendre sans tuer : si un processus en a besoin et qu'il n'y en a plus, il faut sacrifier quelqu'un. Le processeur est différent : on peut simplement faire attendre un processus. C'est ce que fait `cpu.max`.

Sa valeur a deux nombres : un quota et une période, en microsecondes. `50000 100000` signifie que le cgroup peut utiliser 50 ms de processeur toutes les 100 ms. Dès qu'il a consommé son quota, le noyau le suspend (on dit qu'il est *bridé*, *throttled*) jusqu'au début de la période suivante. Faisons l'essai avec un quota de 20 ms, et un programme qui calcule sans arrêt pendant 5 secondes :

```bash
mkdir /sys/fs/cgroup/essai-cpu && cd /sys/fs/cgroup/essai-cpu
echo '20000 100000' > cpu.max
bash -c 'echo $$ > /sys/fs/cgroup/essai-cpu/cgroup.procs
         stress-ng --cpu 1 --timeout 5s --metrics-brief 2>&1 | grep "cpu  "'
grep -E 'usage_usec|nr_periods|nr_throttled|throttled_usec' cpu.stat
```

```sortie
stress-ng: metrc: [572756] cpu                1046      5.00      0.99      0.01       209.09        1046.97
usage_usec 1029306
nr_periods 52
nr_throttled 51
throttled_usec 4073397
```

En 5 secondes, le programme n'a obtenu qu'une seconde de processeur (`usage_usec 1029306`, soit 1,03 s) : 20 % du temps, comme demandé. `cpu.stat` montre comment : sur 52 périodes de 100 ms, le cgroup a été bridé dans 51, pour un total de 4,07 secondes d'attente forcée. Le même programme, lancé hors de ce cgroup, obtient ses 5 secondes pleines et accomplit 6741 opérations au lieu de 1046, soit 6,4 fois plus.

<Figure svg={quotaCpu} num="9.2" alt="Cinq périodes de 100 ms ; dans chacune, le processus tourne pendant 20 ms puis est suspendu jusqu'à la période suivante. Mesuré sur 5 s : 1,03 s de processeur, bridé dans 51 périodes sur 52 ; sans limite, 5 s et 6,4 fois plus de travail.">
Le quota de processeur avec <code>cpu.max = 20000 100000</code>. Le processus n'est jamais tué : il attend.
</Figure>

Le bridage a une conséquence qu'on oublie souvent : il ajoute de la latence. Une requête qui arrive juste après que le conteneur a épuisé son quota attendra jusqu'à 80 ms la période suivante, même si la machine a des processeurs inoccupés. Les services web limités trop juste en processeur ont des temps de réponse irréguliers, et c'est `nr_throttled` qui l'explique. `--cpus 1.5`, lui, se traduit par `150000 100000` : 150 ms par période de 100 ms, c'est-à-dire un processeur et demi utilisé en parallèle.

Il existe une autre façon de partager le processeur, plus douce : `cpu.weight`. Au lieu d'un plafond, c'est une part relative, qui n'intervient que quand les processeurs sont saturés. Un cgroup de poids 200 recevra deux fois plus de temps qu'un cgroup de poids 100, mais quand la machine est calme, chacun prend ce qu'il veut. Kubernetes se sert des deux : les *requests* de processeur d'un Pod deviennent un poids, ses *limits* un quota (chapitre 23).

## Limiter le nombre de processus

Le contrôleur `pids` protège contre une application qui lancerait des processus sans fin, par bogue ou par malveillance (une « bombe fork »). Limitons un cgroup à 5 processus et essayons d'en lancer davantage, avec le shell de BusyBox :

```bash
mkdir /sys/fs/cgroup/essai-pids && cd /sys/fs/cgroup/essai-pids
echo 5 > pids.max
busybox sh -c 'echo $$ > /sys/fs/cgroup/essai-pids/cgroup.procs
  for i in 1 2 3 4 5 6 7; do sleep 30 & echo "lancé $i"; done'
cat pids.events
```

```sortie
lancé 1
lancé 2
lancé 3
lancé 4
sh: can't fork: Resource temporarily unavailable
max 1
```

Le shell compte pour un processus : quatre `sleep` démarrent, et la cinquième création de processus est refusée par le noyau avec l'erreur `EAGAIN` (« ressource temporairement indisponible »). `pids.events` compte les refus. Tuez les `sleep` restants avec `cat cgroup.procs | xargs kill`.

## Geler un conteneur

Au chapitre 2, `docker pause` gelait un conteneur sans l'arrêter. C'est encore un cgroup. Sur votre poste, mettez `cible` en pause, puis regardez dans le laboratoire :

```bash
docker pause cible        # sur votre poste
cat /sys/fs/cgroup/system.slice/docker-090cfd76....scope/cgroup.freeze
grep frozen /sys/fs/cgroup/system.slice/docker-090cfd76....scope/cgroup.events
```

```sortie
1
frozen 1
```

Écrire `1` dans `cgroup.freeze` demande au noyau de ne plus donner de temps de processeur à aucun processus du groupe ; `cgroup.events` confirme quand le gel est effectif. `docker unpause cible` écrit `0` et tout repart.

## Les cgroups hors des conteneurs

Rien de tout cela n'est réservé aux conteneurs. systemd range chaque service dans un cgroup, et on peut lancer n'importe quelle commande dans un cgroup limité, sans `sudo`, grâce à `systemd-run`. Sur votre poste :

```bash
systemd-run --user --scope --quiet -p MemoryMax=100M bash -c \
  'cat /proc/self/cgroup; cat /sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)/memory.max'
```

```sortie
0::/user.slice/user-1000.slice/user@1000.service/app.slice/run-p580304-i611436.scope
104857600
```

systemd a créé un cgroup temporaire dans votre branche d'utilisateur et y a posé la limite de 100 Mo. Cette commande a une histoire dans ce cours : pendant sa préparation, un calcul lourd lancé sans limite a épuisé la mémoire du poste, et c'est l'éditeur de texte, pas le calcul, que le noyau a tué. Depuis, les validations gourmandes s'exécutent sous `systemd-run ... -p MemoryMax=6G` : si l'une d'elles déborde, c'est elle qui est tuée, et pas le reste de la machine. C'est exactement le service que les cgroups rendent aux conteneurs.

## Exercices

:::exercice[Exercice 1 : lire ses propres limites]

Lancez `docker run --rm --memory 256m --cpus 1.5 alpine:3.24 sh -c 'cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/cpu.max'`. Expliquez les deux valeurs affichées, et pourquoi le conteneur voit ces fichiers à la racine de `/sys/fs/cgroup`.

:::

<details>
<summary>Corrigé</summary>

```sortie
268435456
150000 100000
```

256 × 1024 × 1024 = 268435456 octets, et 1,5 processeur devient 150 ms de quota par période de 100 ms. Le conteneur voit son propre cgroup comme la racine de l'arbre parce qu'il a son propre namespace de cgroup (chapitre 8) : `/sys/fs/cgroup` y désigne `/system.slice/docker-<id>.scope`. C'est ainsi qu'une application peut connaître ses limites sans savoir où elle se trouve dans l'arbre de la machine.

</details>

:::exercice[Exercice 2 : trouver le coupable]

Un conteneur redémarre sans cesse avec le code 137. Donnez deux façons de savoir, sur votre poste, s'il est tué par le noyau pour manque de mémoire ou par autre chose.

:::

<details>
<summary>Corrigé</summary>

`docker inspect <conteneur> --format '{{.State.OOMKilled}}'` affiche `true` si le dernier arrêt est dû au noyau. `docker events --filter event=oom` montre en direct un événement `oom` avant chaque `die`. On peut aussi chercher `Memory cgroup out of memory` dans `dmesg` (qui demande les droits de `root`, donc le laboratoire ou `sudo`), ou regarder le compteur `oom_kill` du fichier `memory.events` du cgroup du conteneur. Si aucun indice ne mentionne la mémoire, le code 137 vient d'un SIGKILL envoyé par quelqu'un d'autre : un `docker stop` qui a dû forcer, ou un `docker kill`.

</details>

:::exercice[Exercice 3 : le prix du bridage]

Dans le laboratoire, créez un cgroup avec `cpu.max` à `10000 100000`, placez-y un shell, et mesurez la durée de `time stress-ng --cpu 1 --cpu-ops 500`. Recommencez hors du cgroup. Que mesure `time` dans les deux cas ?

:::

<details>
<summary>Corrigé</summary>

Sur le poste du cours :

| | temps réel (`real`) | temps de processeur (`user`) |
|---|---|---|
| hors cgroup | 0,42 s | 0,40 s |
| cgroup à 10 % | 5,29 s | 0,49 s |

Le temps de processeur est à peu près le même, puisque le travail à faire est identique. Le temps réel, lui, est plus de douze fois plus long : le programme passe l'essentiel de son temps suspendu, et `cpu.stat` compte 53 périodes bridées. Le rapport dépasse légèrement dix parce qu'un quota se consomme par périodes entières de 100 ms. C'est la latence que subit un service trop bridé. Supprimez ensuite le cgroup avec `rmdir`, une fois le shell sorti.

</details>

:::exercice[Exercice 4 : protéger sa machine]

Sur votre poste, écrivez dans un fichier `gourmand.py` un programme qui consomme de la mémoire sans fin :

```python title="gourmand.py"
l = []
while True:
    l.append(bytearray(10**6))
```

Lancez-le protégé par `systemd-run`, avec une limite de 200 Mo : `systemd-run --user --scope -p MemoryMax=200M -p MemorySwapMax=0 python3 gourmand.py`. Que se passe-t-il ? Où trouvez-vous la trace de l'événement ?

:::

<details>
<summary>Corrigé</summary>

Le programme grossit jusqu'à 200 Mo puis est tué en une fraction de seconde, sans que le reste de la machine ne soit affecté ; `echo $?` affiche 137. `journalctl --user -n 20` montre ce que systemd a vu :

```sortie
run-p582191-i576742.scope: The kernel OOM killer killed some processes in this unit.
run-p582191-i576742.scope: Failed with result 'oom-kill'.
run-p582191-i576742.scope: Consumed 152ms CPU time over 153ms wall clock time, 200M memory peak.
```

Sans `MemorySwapMax=0`, le programme pourrait d'abord déborder sur le swap de votre machine, si elle en a, avant d'être tué. C'est la bonne façon de lancer une expérience ou un calcul dont vous ne connaissez pas la consommation.

</details>

## Nettoyer

Dans le laboratoire, supprimez les cgroups de ce chapitre, une fois leurs processus terminés (`rmdir` refuse un cgroup qui contient encore des processus) ; sur votre poste, supprimez les conteneurs :

```bash
rmdir /sys/fs/cgroup/essai-memoire /sys/fs/cgroup/essai-cpu /sys/fs/cgroup/essai-pids   # dans le laboratoire
docker rm -f limite gourmand                                                           # sur votre poste
```

Gardez `cible` et le laboratoire pour le chapitre suivant.

[^cgroup-v2]: Linux kernel documentation, « Control Group v2 », en particulier les sections *Basic Operations*, *Memory* (`memory.max`, `memory.events`), *CPU* (`cpu.max`, `cpu.weight`) et *PID*. [docs.kernel.org/admin-guide/cgroup-v2.html](https://docs.kernel.org/admin-guide/cgroup-v2.html)
