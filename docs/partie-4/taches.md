---
title: DaemonSet, Job et CronJob
sidebar_label: 27. DaemonSet, Job et CronJob
description: "Les charges qui ne ressemblent pas à un service : le Job, qui s'exécute jusqu'au bout et réessaie en cas d'échec, en parallèle ou par tranches indexées ; le CronJob, qui lance des Jobs selon un calendrier, et la purge de Colis qui en devient un ; le DaemonSet, qui place un Pod sur chaque nœud."
partie: 4
chapitre: '27'
---

import tachesNoeuds from '@site/src/figures/taches-noeuds.svg';
import chronologieJobs from '@site/src/figures/chronologie-jobs.svg';

Depuis le chapitre 24, la purge de Colis est un Pod nu, avec `restartPolicy: Never`, qu'on supprime et qu'on recrée à la main pour le relancer. Au démarrage du TP, elle échouait parce que PostgreSQL n'était pas encore prêt, et restait en erreur sans que personne ne réessaie. Personne ne la lance chaque nuit. Et si le nœud qui l'exécute tombe pendant qu'elle tourne, personne ne s'en aperçoit.

Tout ce que la partie III a montré concerne des services : des processus qui tournent sans fin, qu'on redémarre quand ils s'arrêtent. Une purge, une sauvegarde, un calcul, une migration de schéma sont d'une autre nature : ils ont un début et une fin, et la seule question est de savoir s'ils ont réussi. Kubernetes leur consacre deux objets : le **Job**, qui fait exécuter une tâche jusqu'à ce qu'elle réussisse, et le **CronJob**, qui crée des Jobs selon un calendrier. Un troisième objet de ce chapitre répond à un autre besoin, qui ne ressemble pas non plus à un service ordinaire : le **DaemonSet** fait tourner un exemplaire d'un Pod sur chaque nœud du cluster.

Les manifestes sont dans [l'archive taches](pathname:///kits/taches.tar.gz).

```bash
kubectl create namespace ch27
kubectl config set-context --current --namespace=ch27
```

## Le Job : une tâche qui se termine

Le Job `compte` compte les nombres premiers inférieurs à dix millions, avec un crible d'Ératosthène, puis s'arrête :

```yaml title="compte.yaml"
apiVersion: batch/v1
kind: Job
metadata:
  name: compte
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: calcul
        image: python:3.14-alpine
        command: ["python", "-c"]
        args:
        - |
          import socket, time
          debut = time.time()
          n = 10_000_000
          crible = bytearray([1]) * n
          crible[0:2] = b"\0\0"
          for i in range(2, int(n ** 0.5) + 1):
              if crible[i]:
                  crible[i * i::i] = bytearray(len(range(i * i, n, i)))
          print(f"{sum(crible)} nombres premiers sous {n}, calculés par {socket.gethostname()} en {time.time() - debut:.2f} s")
```

La structure est celle d'un Deployment : un modèle de Pod, `template`, que le Job instancie. Une différence saute aux yeux : `restartPolicy` vaut `Never`. Un Pod de Deployment redémarre toujours ses conteneurs (`Always`) ; un Pod de Job doit pouvoir s'arrêter pour de bon.

```bash
kubectl apply -f compte.yaml
kubectl wait --for=condition=Complete job/compte
kubectl get job compte
kubectl get pods -l job-name=compte
kubectl logs job/compte
```

```sortie
job.batch/compte created
job.batch/compte condition met
NAME     STATUS     COMPLETIONS   DURATION   AGE
compte   Complete   1/1           3s         3s
NAME           READY   STATUS      RESTARTS   AGE
compte-9gsk8   0/1     Completed   0          3s
664579 nombres premiers sous 10000000, calculés par compte-9gsk8 en 0.11 s
```

Le Job a créé un Pod, le Pod a fini avec le code 0, et le Job est passé `Complete`. Le Pod reste là, en `Completed`, avec ses journaux : c'est voulu, pour qu'on puisse lire le résultat. Un Pod de Job porte l'étiquette `job-name`, qui permet de le retrouver, et une référence à son propriétaire, le Job. Les valeurs par défaut du Job disent comment il se comporte :

```bash
kubectl get job compte -o jsonpath='{.spec.completions} {.spec.parallelism} {.spec.backoffLimit} {.spec.completionMode}{"\n"}{.status.conditions[*].type}{"\n"}'
```

```sortie
1 1 6 NonIndexed
SuccessCriteriaMet Complete
```

Une complétion attendue, un Pod à la fois, six nouvelles tentatives au plus en cas d'échec, et des complétions interchangeables. Le Job est terminé quand il a obtenu autant de Pods réussis que de complétions demandées[^job].

### Réessayer, et renoncer

Le Job `echec` échoue à tous les coups, avec `backoffLimit: 3` :

```yaml title="echec.yaml"
spec:
  backoffLimit: 3
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: echec
        image: busybox:1.37
        command: ["sh", "-c", "echo \"essai à $(date -u +%T)\"; exit 1"]
```

```bash
kubectl apply -f echec.yaml
kubectl wait --for=condition=Failed job/echec --timeout=300s
kubectl get pods -l job-name=echec --sort-by=.metadata.creationTimestamp
for p in $(kubectl get pods -l job-name=echec --sort-by=.metadata.creationTimestamp -o name); do kubectl logs $p; done
kubectl get job echec -o jsonpath='{.status.conditions[?(@.type=="Failed")].reason}: {.status.conditions[?(@.type=="Failed")].message}{"\n"}'
```

```sortie
NAME          READY   STATUS   RESTARTS   AGE
echec-rdv6f   0/1     Error    0          74s
echec-l52gc   0/1     Error    0          63s
echec-lq455   0/1     Error    0          43s
echec-d9rgf   0/1     Error    0          3s
essai à 12:48:57
essai à 12:49:07
essai à 12:49:27
essai à 12:50:07
BackoffLimitExceeded: Job has reached the specified backoff limit
```

Avec `restartPolicy: Never`, chaque nouvelle tentative est un nouveau Pod : quatre Pods, le premier essai et trois reprises, gardés pour qu'on lise leurs journaux. Les reprises ne partent pas tout de suite : 10 secondes après le premier échec, puis 20, puis 40. Le délai double à chaque fois, jusqu'à un plafond de six minutes[^job]. C'est le même recul exponentiel que le `CrashLoopBackOff` du chapitre 17 : si la cause est passagère (une base qui démarre, un réseau qui hoquette), on lui laisse le temps de disparaître sans marteler le service. Après la troisième reprise, le Job renonce et passe `Failed`, 74 secondes après sa création. La figure 27.1 montre cette chronologie.

Avec `restartPolicy: OnFailure`, le kubelet relance le **conteneur** dans le même Pod, au lieu que le Job crée un nouveau Pod :

```bash
kubectl apply -f relance.yaml
sleep 25; kubectl get pods -l job-name=relance
```

```sortie
NAME            READY   STATUS   RESTARTS      AGE
relance-wh6hh   0/1     Error    2 (24s ago)   25s
```

Un seul Pod, dont le compteur de redémarrages grimpe. Le Job compte ces redémarrages dans son `backoffLimit`, et, quand il renonce (au bout de 42 secondes ici), il supprime le Pod : les journaux des essais sont perdus. `Never` coûte un Pod par tentative, mais garde les traces ; c'est souvent le meilleur choix pour comprendre un échec. Quant à `Always`, il n'a pas de sens pour une tâche qui doit finir, et l'API server le refuse :

```sortie
The Job "toujours" is invalid: spec.template.spec.restartPolicy: Required value: valid values: "OnFailure", "Never"
```

### Ne pas réessayer ce qui ne peut pas réussir

Réessayer une tâche qui échoue faute de configuration ne sert à rien : elle échouera six fois, en prenant de plus en plus de temps. Une **politique d'échec**, `podFailurePolicy`, permet de réagir selon le code de sortie du conteneur, ou selon la raison de l'échec du Pod[^job] :

```yaml title="politique.yaml"
spec:
  backoffLimit: 6
  podFailurePolicy:
    rules:
    - action: FailJob
      onExitCodes:
        containerName: tache
        operator: In
        values: [42]
    - action: Ignore
      onPodConditions:
      - type: DisruptionTarget
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: tache
        image: busybox:1.37
        command: ["sh", "-c", "echo 'variable COLIS_DB absente'; exit 42"]
```

La première règle dit : le code 42 signifie « erreur de configuration », inutile d'insister, faites échouer le Job. La seconde dit : si le Pod a été arrêté par Kubernetes lui-même (un nœud vidé pour maintenance, une préemption : la condition `DisruptionTarget`), ne comptez pas cet arrêt comme un échec de la tâche.

```bash
kubectl apply -f politique.yaml
kubectl wait --for=condition=Failed job/politique
kubectl get job politique -o jsonpath='{.status.conditions[?(@.type=="Failed")].reason}: {.status.conditions[?(@.type=="Failed")].message}{"\n"}'
```

```sortie
PodFailurePolicy: Container tache for pod ch27/politique-dzmh7 failed with exit code 42 matching FailJob rule at index 0
```

Un seul Pod, et le Job échoue en 4 secondes au lieu de plusieurs minutes. Le choix des codes de sortie devient une interface entre la tâche et Kubernetes : une tâche bien écrite distingue « réessayez plus tard » de « corrigez-moi d'abord ».

### Limiter la durée, et faire le ménage

Deux autres champs bornent la vie d'un Job. `activeDeadlineSeconds` limite sa durée totale, reprises comprises : au-delà, ses Pods sont arrêtés et le Job échoue. `ttlSecondsAfterFinished` le fait supprimer, avec ses Pods, un certain temps après sa fin, réussie ou non[^ttl] :

```yaml title="delai.yaml"
spec:
  activeDeadlineSeconds: 10
  ttlSecondsAfterFinished: 30
  template:
    spec:
      restartPolicy: Never
      terminationGracePeriodSeconds: 2
      containers:
      - name: lent
        image: busybox:1.37
        command: ["sh", "-c", "sleep 60"]
```

```bash
kubectl apply -f delai.yaml
sleep 15; kubectl get job delai
kubectl get job delai -o jsonpath='{.status.conditions[?(@.type=="Failed")].reason}: {.status.conditions[?(@.type=="Failed")].message}{"\n"}'
kubectl get pods -l job-name=delai
sleep 35; kubectl get job delai
```

```sortie
NAME    STATUS   COMPLETIONS   DURATION   AGE
delai   Failed   0/1           15s        15s
DeadlineExceeded: Job was active longer than specified deadline
No resources found in ch27 namespace.
Error from server (NotFound): jobs.batch "delai" not found
```

Au bout de 10 secondes, le Pod a été arrêté et supprimé, et le Job a échoué avec `DeadlineExceeded`. Trente secondes plus tard, le Job lui-même avait disparu. Sans `ttlSecondsAfterFinished`, les Jobs terminés s'accumulent jusqu'à ce qu'on les supprime ; avec lui, on perd leurs journaux au bout du délai. Pour une tâche lancée à la main, un TTL d'une heure ou d'un jour laisse le temps de lire le résultat.

## Paralléliser un Job

Un calcul qui se découpe en morceaux indépendants peut tourner sur plusieurs Pods à la fois. Deux champs le règlent : `completions`, le nombre de Pods qui doivent réussir, et `parallelism`, le nombre de Pods qui tournent en même temps. Reste à dire à chaque Pod quel morceau traiter. Le mode `Indexed` le fait simplement : chaque Pod reçoit un numéro, de 0 à `completions - 1`, dans la variable d'environnement `JOB_COMPLETION_INDEX`[^job].

Le Job `tranches` compte les nombres premiers inférieurs à 16 millions, en huit tranches de 2 millions, quatre à la fois, avec une méthode volontairement lente (tester chaque nombre par divisions successives) pour que le calcul dure :

```yaml title="tranches.yaml (extrait)"
spec:
  completions: 8
  parallelism: 4
  completionMode: Indexed
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: calcul
        image: python:3.14-alpine
        resources:
          requests:
            cpu: 250m
            memory: 64Mi
        command: ["python", "-c"]
        args:
        - |
          import os, socket, time
          i = int(os.environ["JOB_COMPLETION_INDEX"])
          taille = 2_000_000
          debut, fin = i * taille, (i + 1) * taille
          ...
```

```bash
kubectl apply -f tranches.yaml
kubectl wait --for=condition=Complete job/tranches --timeout=600s
kubectl get pods -l job-name=tranches --sort-by=.status.startTime \
  -o custom-columns='NOM:.metadata.name,INDEX:.metadata.annotations.batch\.kubernetes\.io/job-completion-index,DÉBUT:.status.startTime,FIN:.status.containerStatuses[0].state.terminated.finishedAt'
for p in $(kubectl get pods -l job-name=tranches -o name); do kubectl logs $p; done | sort -t' ' -k2 -n
```

```sortie
NOM                INDEX   DÉBUT                  FIN
tranches-0-9wchn   0       2026-09-26T12:51:47Z   2026-09-26T12:51:55Z
tranches-1-6h8xr   1       2026-09-26T12:51:47Z   2026-09-26T12:52:00Z
tranches-2-hh2l8   2       2026-09-26T12:51:47Z   2026-09-26T12:52:03Z
tranches-3-c5rr6   3       2026-09-26T12:51:47Z   2026-09-26T12:52:06Z
tranches-4-wbmxf   4       2026-09-26T12:51:57Z   2026-09-26T12:52:18Z
tranches-5-t9pg5   5       2026-09-26T12:52:02Z   2026-09-26T12:52:25Z
tranches-6-djfmd   6       2026-09-26T12:52:06Z   2026-09-26T12:52:30Z
tranches-7-dvc5r   7       2026-09-26T12:52:09Z   2026-09-26T12:52:34Z
tranche 0 [0, 2000000[ : 148933 premiers, tranches-0, 7.2 s
tranche 1 [2000000, 4000000[ : 134213 premiers, tranches-1, 12.4 s
tranche 2 [4000000, 6000000[ : 129703 premiers, tranches-2, 15.5 s
tranche 3 [6000000, 8000000[ : 126928 premiers, tranches-3, 18.1 s
tranche 4 [8000000, 10000000[ : 124802 premiers, tranches-4, 19.7 s
tranche 5 [10000000, 12000000[ : 123481 premiers, tranches-5, 21.7 s
tranche 6 [12000000, 14000000[ : 122017 premiers, tranches-6, 23.5 s
tranche 7 [14000000, 16000000[ : 121053 premiers, tranches-7, 24.8 s
```

Les quatre premières tranches démarrent ensemble ; la cinquième démarre dès que la première a fini, et ainsi de suite : il n'y a jamais plus de quatre Pods en même temps. Le Job a duré 50 secondes. Additionnez les nombres de la colonne des premiers : 1 031 130, le nombre exact de nombres premiers inférieurs à 16 millions, et les cinq premières tranches redonnent les 664 579 du Job `compte`. Chaque Pod porte son numéro dans son nom, dans l'annotation `batch.kubernetes.io/job-completion-index`, et dans son nom d'hôte, `tranches-0` à `tranches-7`, stable d'un essai à l'autre : si la tranche 5 échoue, c'est la tranche 5 qu'on refait, et pas une autre.

<Figure svg={chronologieJobs} num="27.1" alt="Deux chronologies mesurées. En haut, le Job echec, backoffLimit 3 : quatre essais, à 0, 10, 30 et 70 secondes, séparés par des délais de 10, 20 et 40 secondes ; le Job passe Failed à 74 secondes. En bas, le Job tranches, 8 complétions, parallelism 4 : les tranches 0 à 3 démarrent à 0 seconde et finissent à 8, 13, 16 et 19 secondes ; les tranches 4, 5, 6 et 7 démarrent à 10, 15, 19 et 22 secondes, dès qu'une autre finit, et finissent à 31, 38, 43 et 47 secondes ; le Job passe Complete à 50 secondes. Jamais plus de 4 Pods à la fois. Avec parallelism 1, il a fallu 172 secondes, avec parallelism 8, 29 secondes.">
Chronologie de deux Jobs, relevée sur le cluster du cours : les reprises espacées de plus en plus d'un Job qui échoue, et les tranches d'un Job indexé qui se relaient, quatre à la fois.
</Figure>

Le même Job, avec `parallelism: 1`, a pris 172 secondes ; avec `parallelism: 8`, 29 secondes. L'exercice 1 revient sur ces chiffres. Le mode indexé convient quand le découpage se calcule à l'avance. Quand il ne se calcule pas (des fichiers qui arrivent, des messages dans une file), on préfère des Pods qui prennent leur travail dans une file partagée jusqu'à ce qu'elle soit vide, et le Job n'attend alors qu'une seule réussite ; c'est exactement ce que fait le worker de Colis avec Redis, et le chapitre 31 fera varier leur nombre selon la longueur de la file.

## Le CronJob : des Jobs à heure fixe

Un CronJob crée un Job à chaque fois que son calendrier le dit. Le calendrier s'écrit dans la syntaxe de `cron`, le planificateur des systèmes Unix : cinq champs, minute, heure, jour du mois, mois et jour de la semaine[^cron]. `"* * * * *"` veut dire chaque minute ; `"0 3 * * *"`, chaque jour à 3 h 00 ; `"*/15 8-18 * * 1-5"`, toutes les quinze minutes de 8 h à 18 h, du lundi au vendredi.

```yaml title="horloge.yaml"
apiVersion: batch/v1
kind: CronJob
metadata:
  name: horloge
spec:
  schedule: "* * * * *"
  timeZone: Europe/Paris
  successfulJobsHistoryLimit: 2
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: Never
          containers:
          - name: horloge
            image: busybox:1.37
            command: ["sh", "-c", "echo \"exécuté à $(date -u +%T) UTC\""]
```

Un CronJob contient un modèle de Job, `jobTemplate`, qui contient lui-même un modèle de Pod : trois étages, comme le Deployment, le ReplicaSet et le Pod. `timeZone` dit dans quel fuseau lire le calendrier ; sans lui, c'est celui du contrôleur, en pratique UTC. `successfulJobsHistoryLimit` et `failedJobsHistoryLimit` disent combien de Jobs terminés garder. Le deuxième CronJob, `long`, s'exécute lui aussi chaque minute, mais chacune de ses exécutions dure deux minutes et demie, avec `concurrencyPolicy: Forbid`. Appliquez les deux, et revenez trois minutes et demie plus tard :

```bash
kubectl apply -f horloge.yaml -f long.yaml
sleep 215
kubectl get cronjobs
kubectl get jobs
for j in $(kubectl get jobs -o name | grep horloge); do kubectl logs $j; done
```

```sortie
NAME      SCHEDULE    TIMEZONE       SUSPEND   ACTIVE   LAST SCHEDULE   AGE
horloge   * * * * *   Europe/Paris   False     0        35s             3m35s
long      * * * * *   <none>         False     1        35s             3m35s
NAME               STATUS     COMPLETIONS   DURATION   AGE
horloge-29840458   Complete   1/1           3s         95s
horloge-29840459   Complete   1/1           3s         35s
long-29840457      Complete   1/1           2m33s      2m35s
long-29840459      Running    0/1           2s         2s
exécuté à 12:58:00 UTC
exécuté à 12:59:00 UTC
```

Le nom de chaque Job porte l'heure à laquelle il était prévu, comptée en minutes depuis le 1<sup>er</sup> janvier 1970 : 29 840 459 minutes, c'est le 26 septembre 2026 à 12 h 59 UTC. Ce nom déterministe empêche le contrôleur de créer deux fois le Job d'une même échéance, même s'il redémarre au mauvais moment. Les événements racontent le reste :

```bash
kubectl get events --field-selector involvedObject.kind=CronJob --sort-by=.metadata.resourceVersion \
  -o custom-columns=OBJET:.involvedObject.name,RAISON:.reason,MESSAGE:.message
```

```sortie
OBJET     RAISON             MESSAGE
long      SuccessfulCreate   Created job long-29840457
horloge   SuccessfulCreate   Created job horloge-29840457
horloge   SawCompletedJob    Saw completed job: horloge-29840457, condition: Complete
horloge   SuccessfulCreate   Created job horloge-29840458
horloge   SawCompletedJob    Saw completed job: horloge-29840458, condition: Complete
horloge   SuccessfulCreate   Created job horloge-29840459
horloge   SuccessfulDelete   Deleted job horloge-29840457
horloge   SawCompletedJob    Saw completed job: horloge-29840459, condition: Complete
long      JobAlreadyActive   Not starting job because prior execution is running and concurrency policy is Forbid
long      SawCompletedJob    Saw completed job: long-29840457, condition: Complete
long      SuccessfulCreate   Created job long-29840459
```

`horloge` a créé un Job chaque minute et supprimé le plus ancien dès qu'il en avait plus de deux terminés. `long` a créé son Job de 12 h 57 ; à 12 h 58, ce Job tournait encore, et la politique `Forbid` a sauté l'échéance (`JobAlreadyActive`) ; à 12 h 59, le premier Job avait fini, et le suivant est parti. Les deux autres politiques sont `Allow`, la valeur par défaut, qui laisse les Jobs se chevaucher, et `Replace`, qui arrête le Job en cours pour lancer le nouveau. Pour une purge, une sauvegarde ou tout ce qui touche aux mêmes données, `Forbid` évite que deux exécutions se marchent dessus.

<Figure svg={tachesNoeuds} num="27.2" alt="En haut, les tâches planifiées : le CronJob horloge (chaque minute, fuseau Europe/Paris, historique de 2 Jobs réussis) crée chaque minute un Job : horloge-29840436, supprimé pour respecter l'historique, horloge-29840437 à 12 h 37 UTC et horloge-29840438 à 12 h 38 UTC, qui ont chacun un Pod Completed. Le numéro du Job est l'heure prévue, en minutes depuis le 1er janvier 1970 ; un Job réessaie ses Pods selon backoffLimit, puis passe Complete ou Failed. En bas, un Pod par nœud : le DaemonSet veilleur, qui monte /var/log/pods en hostPath, a un Pod sur chacun des nœuds deux-noeuds et deux-noeuds-m02, et sur deux-noeuds-m03 quand il est ajouté : Pod en marche en 36 secondes, Pod supprimé 52 secondes après le retrait du nœud.">
Qui crée quoi : un CronJob crée des Jobs, qui créent des Pods ; un DaemonSet crée un Pod par nœud, et suit les nœuds qui arrivent ou partent.
</Figure>

:::panne[Un calendrier refusé, ou accepté à tort]

L'API server valide le calendrier et le fuseau :

```sortie
The CronJob "mauvaise" is invalid: spec.schedule: Invalid value: "61 * * * *": end of range (61) above maximum (59): 61
The CronJob "mauvaise" is invalid: spec.timeZone: Invalid value: "Europe/Pariss": unknown time zone Europe/Pariss
The CronJob "mauvaise" is invalid: spec.schedule: Invalid value: "CRON_TZ=UTC * * * * *": cannot use TZ or CRON_TZ in schedule, use timeZone field instead
```

Mais la validation ne rattrape pas tout. `"*/61 * * * *"`, qu'on pourrait écrire en croyant dire « toutes les 61 minutes », est accepté : un pas plus grand que l'intervalle ne garde que la première valeur, la minute 0, et le CronJob s'exécute une fois par heure. Et `"0 3 * * *"` sans `timeZone` s'exécute à 3 h UTC, soit 5 h à Paris en été. Relisez `kubectl get cronjob`, colonnes `SCHEDULE` et `TIMEZONE`, et vérifiez `LAST SCHEDULE` après la première échéance.

:::

### La purge de Colis

La purge devient un CronJob, chaque nuit à 3 h, heure de Paris :

```yaml title="colis/50-purge.yaml (extrait)"
apiVersion: batch/v1
kind: CronJob
metadata:
  name: purge
  namespace: colis
spec:
  schedule: "0 3 * * *"
  timeZone: Europe/Paris
  concurrencyPolicy: Forbid          # jamais deux purges en même temps
  startingDeadlineSeconds: 3600      # rattraper un départ manqué d'une heure au plus
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 600
      template:
        spec:
          restartPolicy: Never
          containers:
          - name: purge
            image: host.minikube.internal:5001/colis/api:2.1
            command: ["python", "-m", "colis.purge"]
            # ... la même configuration que l'API : envFrom, POSTGRES_PASSWORD, COLIS_DB
```

`startingDeadlineSeconds` dit jusqu'à quand rattraper une échéance manquée, par exemple parce que le cluster était arrêté à 3 h : au-delà d'une heure de retard, on attend la nuit suivante plutôt que de purger en pleine journée[^cron]. `backoffLimit: 2` laisse deux reprises si PostgreSQL redémarre au mauvais moment, et `activeDeadlineSeconds` borne une purge qui resterait bloquée. Remplacez le Pod par le CronJob :

```bash
kubectl -n colis delete pod purge
kubectl apply -f colis/50-purge.yaml
kubectl -n colis get cronjob purge
```

```sortie
cronjob.batch/purge created
NAME    SCHEDULE    TIMEZONE       SUSPEND   ACTIVE   LAST SCHEDULE   AGE
purge   0 3 * * *   Europe/Paris   False     0        <none>          0s
```

Pour vérifier qu'elle fonctionne sans attendre 3 h, préparons deux colis livrés, dont l'un il y a 40 jours. L'API marque un colis livré avec `POST /colis/<id>/livraison` ; la date de livraison, elle, se recule directement dans PostgreSQL :

```bash
IP=192.168.49.100
for n in 'Hedy Lamarr' 'Joan Clarke'; do
  curl -s -X POST http://$IP/api/colis -H 'Content-Type: application/json' \
    -d "{\"destinataire\":\"$n\",\"depart\":\"Lyon\",\"arrivee\":\"Brest\",\"poids_kg\":0.8}" | jq -c '{id, destinataire}'
done
sleep 5
curl -s -X POST http://$IP/api/colis/3/livraison | jq -c '{id, statut}'
curl -s -X POST http://$IP/api/colis/4/livraison | jq -c '{id, statut}'
kubectl -n colis exec postgres-0 -- psql -U colis -d colis -c "UPDATE colis SET livre_le = now() - interval '40 days' WHERE destinataire = 'Hedy Lamarr';"
kubectl -n colis exec postgres-0 -- psql -U colis -d colis -c 'SELECT id, destinataire, statut, livre_le::date FROM colis ORDER BY id;'
```

```sortie
{"id":3,"destinataire":"Hedy Lamarr"}
{"id":4,"destinataire":"Joan Clarke"}
{"id":3,"statut":"livré"}
{"id":4,"statut":"livré"}
UPDATE 1
 id | destinataire | statut |  livre_le  
----+--------------+--------+------------
  2 | Grace Hopper | estimé | 2026-09-26
  3 | Hedy Lamarr  | livré  | 2026-08-17
  4 | Joan Clarke  | livré  | 2026-09-26
(3 rows)
```

(Le colis de Grace Hopper, lui, a une date de livraison et le statut « estimé » : c'est un défaut de Colis, que l'exercice 3 vous fait trouver.) `kubectl create job --from=cronjob/...` crée tout de suite un Job à partir du modèle du CronJob, ce qu'on fait pour tester une tâche planifiée ou pour la relancer après un échec :

```bash
kubectl -n colis create job purge-manuelle --from=cronjob/purge
kubectl -n colis wait --for=condition=Complete job/purge-manuelle
kubectl -n colis logs job/purge-manuelle
kubectl -n colis exec postgres-0 -- psql -U colis -d colis -c 'SELECT id, destinataire, statut FROM colis ORDER BY id;'
```

```sortie
job.batch/purge-manuelle created
job.batch/purge-manuelle condition met
purge : 1 colis livrés depuis plus de 30 jours supprimés
 id | destinataire | statut 
----+--------------+--------
  2 | Grace Hopper | estimé
  4 | Joan Clarke  | livré
(2 rows)
```

Le colis de Hedy Lamarr, livré depuis 40 jours, est parti ; celui de Joan Clarke, livré aujourd'hui, est resté. Le Job créé à la main porte l'annotation `cronjob.kubernetes.io/instantiate: manual`, qui le distingue des Jobs planifiés.

## Le DaemonSet : un Pod sur chaque nœud

Certains programmes n'ont de sens qu'à raison d'un exemplaire par machine : un agent qui collecte les journaux des conteneurs du nœud, un exportateur de métriques qui mesure son processeur et ses disques, le composant réseau qui configure ses interfaces, un pilote de stockage. Un Deployment de trois répliques pourrait en mettre deux sur le même nœud et aucun sur un autre ; et quand un nœud arrive, il faudrait penser à augmenter le nombre de répliques. Le DaemonSet garantit exactement un Pod sur chaque nœud qui convient, et suit les nœuds qui arrivent et qui partent[^ds].

Votre cluster en a déjà. Pour que la démonstration ait un sens, il faut plusieurs nœuds : arrêtez le cluster principal, pour rester sous les 6 Gio, et démarrez le profil `deux-noeuds` du chapitre 15 (le chapitre 32 y reviendra) :

```bash
minikube stop
minikube start -p deux-noeuds
kubectl create namespace ch27
kubectl get daemonsets -A
```

```sortie
NAMESPACE     NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR            AGE
kube-system   kindnet      2         2         2       2            2           <none>                   20h
kube-system   kube-proxy   2         2         2       2            2           kubernetes.io/os=linux   20h
```

`kube-proxy`, qui écrit les règles des Services sur chaque nœud (chapitre 20), et `kindnet`, le réseau des Pods de minikube (partie V), sont des DaemonSets : deux nœuds, deux Pods chacun. Le DaemonSet `veilleur` rapporte chaque minute la charge de son nœud et le nombre de Pods dont les journaux y sont rangés, qu'il lit dans `/var/log/pods` par un volume `hostPath` en lecture seule, un des rares usages légitimes de ce type de volume (chapitre 25). Il lit le nom de son nœud par l'API descendante (chapitre 21) :

```yaml title="veilleur.yaml (extrait)"
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: veilleur
spec:
  selector:
    matchLabels:
      app: veilleur
  template:
    metadata:
      labels:
        app: veilleur
    spec:
      containers:
      - name: veilleur
        image: busybox:1.37
        env:
        - name: NOEUD
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        # ... une boucle qui affiche la charge et le nombre de dossiers de /journaux
        volumeMounts:
        - name: journaux
          mountPath: /journaux
          readOnly: true
      volumes:
      - name: journaux
        hostPath:
          path: /var/log/pods
          type: Directory
```

Pas de champ `replicas` : le nombre de Pods est celui des nœuds.

```bash
kubectl -n ch27 apply -f veilleur.yaml
kubectl -n ch27 get ds veilleur
kubectl -n ch27 get pods -l app=veilleur -o wide
for p in $(kubectl -n ch27 get pods -l app=veilleur -o name); do kubectl -n ch27 logs $p; done
```

```sortie
NAME       DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
veilleur   2         2         2       2            2           <none>          1s
NAME             READY   STATUS    RESTARTS   AGE   IP           NODE              NOMINAT
veilleur-9ssfl   1/1     Running   0          1s    10.244.1.4   deux-noeuds-m02   <none> 
veilleur-mdgt6   1/1     Running   0          1s    10.244.0.9   deux-noeuds       <none> 
12:43:56 deux-noeuds-m02 : charge 1.88 1.52 1.27, journaux de 4 Pods
12:43:56 deux-noeuds : charge 1.88 1.52 1.27, journaux de 15 Pods
```

Un Pod par nœud. La charge est la même sur les deux nœuds : ce sont deux conteneurs sur votre poste, qui partagent son noyau, et `/proc/loadavg` donne la charge de tout le poste. Sur des machines distinctes, les chiffres différeraient.

### Comment le DaemonSet place ses Pods

Le contrôleur du DaemonSet ne place pas les Pods lui-même : il crée un Pod par nœud et laisse le scheduler faire, en écrivant dans chaque Pod une affinité qui ne laisse qu'un choix possible. Il y ajoute des tolérances, pour que ses Pods restent là où d'autres seraient chassés :

```bash
P=$(kubectl -n ch27 get pods -l app=veilleur -o name | head -1)
kubectl -n ch27 get $P -o jsonpath='{.spec.affinity}{"\n"}'
kubectl -n ch27 get $P -o jsonpath='{range .spec.tolerations[*]}{.key} {.operator} {.effect}{"\n"}{end}'
```

```sortie
{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchFields":[{"key":"metadata.name","operator":"In","values":["deux-noeuds-m02"]}]}]}}}
node.kubernetes.io/not-ready Exists NoExecute
node.kubernetes.io/unreachable Exists NoExecute
node.kubernetes.io/disk-pressure Exists NoSchedule
node.kubernetes.io/memory-pressure Exists NoSchedule
node.kubernetes.io/pid-pressure Exists NoSchedule
node.kubernetes.io/unschedulable Exists NoSchedule
```

L'affinité nomme un nœud et un seul : `deux-noeuds-m02`. Les tolérances disent que ce Pod reste sur un nœud injoignable ou non prêt (au lieu d'être évincé au bout de cinq minutes, comme au chapitre 15), et qu'il peut aller sur un nœud en manque de mémoire ou de disque, ou marqué non planifiable. Un agent de journaux ou de métriques doit tourner justement quand le nœud va mal. Le chapitre 32 détaillera les affinités, les *taints* et les tolérances.

### Un nœud arrive, un nœud part

Ajoutez un troisième nœud au profil, et chronométrez :

```bash
minikube node add -p deux-noeuds
kubectl wait --for=condition=Ready node/deux-noeuds-m03 --timeout=180s
kubectl -n ch27 get pods -l app=veilleur -o wide
```

```sortie
* m03 a été ajouté avec succès à deux-noeuds !
node/deux-noeuds-m03 condition met
NAME             READY   STATUS    RESTARTS   AGE   IP           NODE              NOMINAT
veilleur-9ssfl   1/1     Running   0          41s   10.244.1.4   deux-noeuds-m02   <none> 
veilleur-mdgt6   1/1     Running   0          41s   10.244.0.9   deux-noeuds       <none> 
veilleur-qq4s5   1/1     Running   0          3s    10.244.3.2   deux-noeuds-m03   <none> 
```

Le nœud a été prêt en 33 secondes, et le `veilleur` tournait dessus 3 secondes plus tard, sans que personne n'ait rien demandé. Retirez-le :

```bash
minikube node delete m03 -p deux-noeuds
kubectl -n ch27 get pods -l app=veilleur -o wide
```

```sortie
* Le nœud m03 a été supprimé avec succès.
NAME             READY   STATUS    RESTARTS   AGE   IP           NODE              NOMINAT
veilleur-9ssfl   1/1     Running   0          47s   10.244.1.4   deux-noeuds-m02   <none> 
veilleur-mdgt6   1/1     Running   0          47s   10.244.0.9   deux-noeuds       <none> 
veilleur-qq4s5   1/1     Running   0          9s    10.244.3.2   deux-noeuds-m03   <none> 
```

Le nœud n'existe plus, mais son Pod apparaît encore, `Running`, parce que plus aucun kubelet n'est là pour dire le contraire. Il a disparu 52 secondes plus tard : c'est le ramasse-miettes des Pods, un contrôleur du plan de contrôle, qui supprime les Pods rattachés à un nœud qui n'existe plus, après une courte quarantaine[^podgc].

### Choisir les nœuds

Un DaemonSet n'est pas obligé d'aller partout. Avec un `nodeSelector` dans le modèle de Pod, il ne vise que les nœuds qui portent certaines étiquettes, par exemple un agent qui surveille des disques SSD :

```bash
kubectl label node deux-noeuds-m02 disque=ssd
kubectl -n ch27 patch ds veilleur -p '{"spec":{"template":{"spec":{"nodeSelector":{"disque":"ssd"}}}}}'
kubectl -n ch27 get ds veilleur
kubectl label node deux-noeuds disque=ssd
sleep 5; kubectl -n ch27 get pods -l app=veilleur -o wide
```

```sortie
NAME       DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
veilleur   1         1         1       1            1           disque=ssd      105s
NAME             READY   STATUS    RESTARTS   AGE   IP            NODE              NOMINA
veilleur-5z5pd   1/1     Running   0          5s    10.244.0.10   deux-noeuds       <none>
veilleur-xdmvc   1/1     Running   0          6s    10.244.1.5    deux-noeuds-m02   <none>
```

Un seul nœud portait l'étiquette : un seul Pod. Dès qu'on a étiqueté le second, le DaemonSet y a placé un Pod. La mise à jour d'un DaemonSet suit la stratégie `RollingUpdate`, nœud par nœud (`maxUnavailable: 1`, `maxSurge: 0` par défaut : l'ancien Pod d'un nœud est arrêté avant que le nouveau démarre), ou `OnDelete`. Pour revenir au cluster principal :

```bash
minikube stop -p deux-noeuds
minikube start
kubectl apply -f metallb-plage.yaml      # la plage de MetalLB, remise à zéro par minikube start (chapitre 20)
```

## Exercices

:::exercice[Exercice 1 : combien de Pods en parallèle ?]

Le Job `tranches` a pris 172 secondes avec `parallelism: 1`, 50 avec 4, 29 avec 8. Le nœud minikube a été créé avec `--cpus=2`. Comment 8 Pods peuvent-ils aller plus vite que 4 sur 2 processeurs ? Que se passerait-il sur un vrai nœud de 2 processeurs ? Quelle valeur de `parallelism` choisir ?

:::

<details>
<summary>Corrigé</summary>

Ils ne sont pas sur 2 processeurs. Avec le pilote `docker` sous Linux, minikube ne limite pas le processeur du conteneur du nœud, et le nœud annonce tous les cœurs du poste :

```bash
kubectl get node minikube -o jsonpath='{.status.allocatable.cpu} CPU allouables{"\n"}'
minikube ssh -- nproc
```

```sortie
22 CPU allouables
22
```

Les 8 Pods ont chacun trouvé un cœur libre. Le gain n'est pas de 8 : 172 secondes en série, 29 en parallèle, soit un facteur 6, parce que les tranches n'ont pas la même durée (tester un grand nombre coûte plus de divisions qu'un petit) et que le Job attend la plus lente, la tranche 7, de 25 secondes, plus le démarrage des Pods. Sur un vrai nœud de 2 processeurs, les 8 Pods se partageraient 2 cœurs : chacun irait quatre fois moins vite, et la durée totale serait à peu près celle de `parallelism: 2`, avec plus de mémoire consommée. Au-delà du nombre de cœurs disponibles, le parallélisme ne fait plus gagner de temps.

Le bon réglage part des ressources : chaque Pod demande `cpu: 250m`, ce qui laisse le scheduler placer quatre Pods par cœur déclaré, bien plus que ce que le calcul peut en utiliser. Pour un calcul qui occupe un cœur entier, demandez `cpu: 1`, et fixez `parallelism` au nombre de cœurs que vous voulez lui consacrer : le scheduler ne lancera pas plus de Pods que les nœuds ne peuvent en porter, et les autres attendront en `Pending`.

</details>

:::exercice[Exercice 2 : une sauvegarde nocturne]

Écrivez un CronJob `sauvegarde`, dans le namespace `colis`, qui chaque nuit à 2 h (heure de Paris) fait un `pg_dump` de la base de Colis dans un volume persistant de 1 Gio, et garde les sept dernières sauvegardes. Quelle politique de concurrence choisir ? Que se passe-t-il si le cluster est arrêté à 2 h ?

:::

<details>
<summary>Corrigé</summary>

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sauvegardes
  namespace: colis
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: sauvegarde
  namespace: colis
spec:
  schedule: "0 2 * * *"
  timeZone: Europe/Paris
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 7200
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          restartPolicy: Never
          containers:
          - name: pg-dump
            image: postgres:18-alpine
            env:
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: colis-db
                  key: POSTGRES_PASSWORD
            command: ["sh", "-c"]
            args:
            - |
              f=/sauvegardes/colis-$(date -u +%Y%m%d-%H%M).dump
              pg_dump -h postgres -U colis -d colis -Fc -f "$f" && ls -l "$f"
              ls -1t /sauvegardes/colis-*.dump | tail -n +8 | xargs -r rm -v
            volumeMounts:
            - name: sauvegardes
              mountPath: /sauvegardes
          volumes:
          - name: sauvegardes
            persistentVolumeClaim:
              claimName: sauvegardes
```

Le kit contient ce fichier, `sauvegarde.yaml`. On le teste sans attendre 2 h :

```bash
kubectl apply -f sauvegarde.yaml
kubectl -n colis create job sauvegarde-essai --from=cronjob/sauvegarde
kubectl -n colis logs job/sauvegarde-essai
```

```sortie
-rw-r--r--    1 root     root          3049 Sep 26 13:04 /sauvegardes/colis-20260926-1304.dump
```

Le script garde les sept fichiers les plus récents et supprime les autres. `Forbid` : deux `pg_dump` simultanés doubleraient la charge sur la base et écriraient dans le même dossier. `successfulJobsHistoryLimit` ne règle que le nombre de Jobs gardés, pas le nombre de fichiers : ce sont deux choses différentes. Si le cluster est arrêté à 2 h et redémarre à 3 h, le contrôleur voit une échéance manquée de moins de deux heures (`startingDeadlineSeconds: 7200`) et lance la sauvegarde ; s'il redémarre à 5 h, il l'abandonne jusqu'à la nuit suivante. Dernière remarque : cette sauvegarde vit sur le même nœud et dans le même cluster que la base. Une vraie sauvegarde doit partir ailleurs (un stockage objet, un autre site) ; le chapitre 52 y reviendra.

</details>

:::exercice[Exercice 3 : le colis de Grace Hopper]

Dans la liste des colis, celui de Grace Hopper a une date de livraison (`livre_le`) mais le statut « estimé ». Il a été créé, puis marqué livré aussitôt, sans attendre. Relisez `colis/worker.py` et `colis/stockage.py` de Colis 2.1 : que s'est-il passé ? Proposez une correction.

:::

<details>
<summary>Corrigé</summary>

La création d'un colis le dépose dans la file Redis ; le worker le prend un peu plus tard, attend `COLIS_WORKER_PAUSE` (une demi-seconde, pour simuler un calcul), calcule la date, puis appelle `stockage.estimer()`. Entre-temps, l'appel à `/colis/2/livraison` avait déjà mis le statut à « livré » et rempli `livre_le`. `estimer()` exécute ensuite, sans condition :

```sql
UPDATE colis SET livraison_estimee = %s, statut = %s WHERE id = %s
```

et remet le statut à « estimé ». C'est une *condition de course* entre deux écrivains, l'API et le worker, sur la même ligne : le dernier qui écrit gagne, quel que soit l'ordre logique des événements. Kubernetes n'y est pour rien, mais le découpage en services qui travaillent en parallèle rend ce genre de défaut plus fréquent.

La correction consiste à ne faire passer à « estimé » qu'un colis encore « enregistré » :

```sql
UPDATE colis SET livraison_estimee = %s,
       statut = CASE WHEN statut = 'enregistré' THEN 'estimé' ELSE statut END
WHERE id = %s
```

Essayons-la sur le colis de Joan Clarke, livré, dans une transaction qu'on annule pour ne rien modifier :

```bash
kubectl -n colis exec postgres-0 -- psql -U colis -d colis -c "BEGIN;
  UPDATE colis SET livraison_estimee = current_date + 3,
         statut = CASE WHEN statut = 'enregistré' THEN 'estimé' ELSE statut END WHERE id = 4;
  SELECT id, destinataire, statut, livraison_estimee FROM colis WHERE id = 4; ROLLBACK;"
```

```sortie
BEGIN
UPDATE 1
 id | destinataire | statut | livraison_estimee 
----+--------------+--------+-------------------
  4 | Joan Clarke  | livré  | 2026-09-29
(1 row)

ROLLBACK
```

La date estimée est enregistrée dans tous les cas, mais un colis déjà livré garde son statut. Cette condition dans la requête elle-même, exécutée atomiquement par PostgreSQL, est plus sûre qu'une lecture du statut suivie d'une écriture, entre lesquelles l'API pourrait encore passer. Notez aussi que l'opération reste rejouable, ce que Colis 2.1 exige pour `estimer()` (chapitre 26).

</details>

## Nettoyer

Sur le cluster principal :

```bash
kubectl delete namespace ch27
kubectl -n colis delete job purge-manuelle
kubectl config set-context --current --namespace=default
```

Gardez le CronJob `purge` de Colis. Sur le profil `deux-noeuds`, s'il tourne encore :

```bash
kubectl --context deux-noeuds delete namespace ch27
kubectl --context deux-noeuds label node deux-noeuds deux-noeuds-m02 disque-
minikube stop -p deux-noeuds
```

[^job]: Kubernetes, « Jobs », sections *Parallel execution for Jobs*, *Completion mode*, *Pod backoff failure policy* (reprises à 10 s, 20 s, 40 s..., plafonnées à six minutes) et *Pod failure policy*. [kubernetes.io/docs/concepts/workloads/controllers/job](https://kubernetes.io/docs/concepts/workloads/controllers/job/)

[^ttl]: Kubernetes, « Automatic Cleanup for Finished Jobs ». [kubernetes.io/docs/concepts/workloads/controllers/ttlafterfinished](https://kubernetes.io/docs/concepts/workloads/controllers/ttlafterfinished/)

[^cron]: Kubernetes, « CronJob », sections *Schedule syntax*, *Time zones*, *Concurrency policy* et *Deadline for delayed Job start*. [kubernetes.io/docs/concepts/workloads/controllers/cron-jobs](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/)

[^ds]: Kubernetes, « DaemonSet », sections *How Daemon Pods are scheduled* et *Taints and tolerations*. [kubernetes.io/docs/concepts/workloads/controllers/daemonset](https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/)

[^podgc]: Kubernetes, « Pod Lifecycle », section *Garbage collection of Pods*. [kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-garbage-collection)
