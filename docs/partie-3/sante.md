---
title: La santé des Pods
sidebar_label: 22. La santé des Pods
description: "Dire à Kubernetes quand une application va bien : sondes liveness, readiness et startup, leurs réglages et leurs pièges ; puis la fin de vie d'un Pod, SIGTERM, le délai de grâce et preStop."
partie: 3
chapitre: '22'
---

import troisSondes from '@site/src/figures/trois-sondes.svg';
import arretPod from '@site/src/figures/arret-pod.svg';

Un processus peut tourner et ne servir à rien. Un serveur bloqué sur un verrou garde son port ouvert et ne répond plus ; une application qui charge un modèle de plusieurs gigaoctets met une minute à pouvoir répondre ; une autre a perdu la connexion à sa base et renvoie des erreurs à chaque requête. Pour Kubernetes, tant que le processus principal ne s'est pas arrêté, le conteneur est `Running`, et le Service continue de lui envoyer du trafic.

Kubernetes ne peut pas deviner qu'une application va mal : il faut le lui dire, par des **sondes** (*probes*), des vérifications que le kubelet fait régulièrement sur chaque conteneur. Ce chapitre montre les trois sortes de sondes, ce que chacune déclenche quand elle échoue, et comment les régler sans créer de pannes. Il traite ensuite de l'autre bout de la vie d'un Pod : son arrêt, qui doit laisser à l'application le temps de finir proprement ce qu'elle faisait.

Les manifestes sont dans [l'archive sante](pathname:///kits/sante.tar.gz).

```bash
kubectl create namespace ch22
kubectl config set-context --current --namespace=ch22
```

## Trois sondes, trois questions

Une sonde vérifie un conteneur de l'une de quatre façons[^sondes] : une requête **HTTP** (`httpGet`, réussie si le code de réponse est entre 200 et 399), une connexion **TCP** (`tcpSocket`, réussie si le port accepte la connexion), une commande lancée **dans** le conteneur (`exec`, réussie si elle sort avec le code 0), ou un appel **gRPC** au service de santé standard de gRPC. Chaque sonde répond à une question, et son échec a une conséquence précise :

- la **livenessProbe** demande « le conteneur est-il encore vivant ? ». En cas d'échec, le kubelet le tue et le relance ;
- la **readinessProbe** demande « peut-il recevoir du trafic ? ». En cas d'échec, le Pod reste en vie mais n'est plus `Ready`, et les Services cessent de lui envoyer des requêtes ;
- la **startupProbe** demande « a-t-il fini de démarrer ? ». Tant qu'elle n'a pas réussi, les deux autres sont suspendues ; si elle échoue trop longtemps, le conteneur est tué.

Quatre réglages communs dosent chaque sonde : `initialDelaySeconds` (attente avant la première vérification, 0 par défaut), `periodSeconds` (intervalle, 10 secondes par défaut), `timeoutSeconds` (délai de réponse, 1 seconde par défaut) et `failureThreshold` (nombre d'échecs consécutifs avant d'agir, 3 par défaut). Le temps pour détecter une panne est donc d'environ `periodSeconds × failureThreshold` : 30 secondes avec les valeurs par défaut.

## La livenessProbe

`agnhost liveness` est un serveur de test conçu pour mal finir : il répond `200` sur `/healthz` pendant dix secondes, puis `500` pour toujours.

```yaml title="liveness.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: malade
spec:
  containers:
  - name: agnhost
    image: registry.k8s.io/e2e-test-images/agnhost:2.61
    args: ["liveness"]
    livenessProbe:
      httpGet:
        path: /healthz
        port: 8080
      periodSeconds: 3
      failureThreshold: 3
```

Relevons son état chaque seconde pendant 75 secondes, puis ses événements :

```bash
kubectl apply -f liveness.yaml
t0=$(date +%s); last=''
while [ $(( $(date +%s)-t0 )) -lt 75 ]; do
  s=$(kubectl get pod malade --no-headers | awk '{print $2, $3, $4}')
  [ "$s" != "$last" ] && echo "t=$(( $(date +%s)-t0 )) s : $s" && last=$s
  sleep 1
done
kubectl get events --field-selector involvedObject.name=malade -o custom-columns=RAISON:.reason,NB:.count,MESSAGE:.message
```

```sortie
t=0 s : 0/1 ContainerCreating 0
t=1 s : 1/1 Running 0
t=19 s : 1/1 Running 1
t=37 s : 1/1 Running 2
t=55 s : 1/1 Running 3
t=74 s : 0/1 CrashLoopBackOff 3
RAISON      NB       MESSAGE
Scheduled   <none>   Successfully assigned ch22/malade to minikube
Pulled      4        Container image "registry.k8s.io/e2e-test-images/agnhost:2.61" already present on machine and can be accessed by the pod
Created     4        Container created
Started     4        Container started
Unhealthy   12       Liveness probe failed: HTTP probe failed with statuscode: 500
Killing     4        Container agnhost failed liveness probe, will be restarted
BackOff     2        Back-off restarting failed container agnhost in pod malade_ch22(68e2dcd9-ab92-4f35-b5eb-24afed8cc3e9)
```

Le calcul se vérifie : dix secondes de bonne santé, puis trois échecs espacés de trois secondes, et le kubelet tue le conteneur, un peu avant la vingtième seconde. Il le relance, et le cycle recommence toutes les 18 secondes environ, jusqu'à ce que le recul exponentiel du chapitre 17 s'en mêle (`CrashLoopBackOff`). Les événements comptent 12 échecs (`Unhealthy`) pour 4 arrêts (`Killing`) : trois échecs par arrêt. Remarquez que le Pod reste `1/1` pendant ses échecs : la livenessProbe ne touche pas à `READY`, qui est l'affaire de la readinessProbe.

Une livenessProbe sert à une chose : sortir un programme d'un état dont il ne sortira pas seul (un blocage, une fuite de mémoire qui l'a figé). Elle est dangereuse si elle échoue pour une autre raison : une livenessProbe qui vérifie que la base de données répond fera redémarrer **tous** les Pods de l'API au premier incident de la base, ce qui n'arrange rien et ajoute une panne à la panne. Une bonne livenessProbe ne vérifie que le processus lui-même, et répond vite.

## La readinessProbe

La readinessProbe sert à tout ce que la livenessProbe ne doit pas faire : dire qu'un Pod, vivant, ne doit pas recevoir de requêtes pour l'instant (il démarre, il est surchargé, une dépendance est absente). Pour la piloter à la main, la sonde de ce Deployment vérifie simplement la présence d'un fichier, que le crochet `postStart` crée au démarrage :

```yaml title="readiness.yaml"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pret
spec:
  replicas: 2
  selector:
    matchLabels:
      app: pret
  template:
    metadata:
      labels:
        app: pret
    spec:
      containers:
      - name: web
        image: registry.k8s.io/e2e-test-images/agnhost:2.61
        args: ["netexec", "--http-port=8080"]
        readinessProbe:
          exec:
            command: ["cat", "/tmp/pret"]
          periodSeconds: 2
          failureThreshold: 1
        lifecycle:
          postStart:
            exec:
              command: ["sh", "-c", "touch /tmp/pret"]
---
apiVersion: v1
kind: Service
metadata:
  name: pret
spec:
  selector:
    app: pret
  ports:
  - port: 80
    targetPort: 8080
```

(Un crochet `postStart` est une commande que le kubelet lance dans le conteneur juste après son démarrage[^crochets].) Déployons, et envoyons vingt requêtes au Service depuis un client :

```bash
kubectl apply -f readiness.yaml
kubectl rollout status deployment/pret
kubectl run client --image=busybox:1.37 --restart=Never -- sleep 3600
kubectl wait --for=condition=Ready pod/client
kubectl get pods -l app=pret
kubectl exec client -- sh -c 'for i in $(seq 1 20); do wget -q -O - http://pret/hostname; echo; done' | sort | uniq -c
```

```sortie
NAME                   READY   STATUS    RESTARTS   AGE
pret-85cfb48c6-6k24m   1/1     Running   0          1s
pret-85cfb48c6-drwx5   1/1     Running   0          1s
     11 pret-85cfb48c6-6k24m
      9 pret-85cfb48c6-drwx5
```

Retirons le fichier d'un des deux Pods, comme si l'application signalait qu'elle ne peut plus servir :

```bash
kubectl exec pret-85cfb48c6-6k24m -- rm /tmp/pret
sleep 5
kubectl get pods -l app=pret
kubectl get endpointslices -l kubernetes.io/service-name=pret -o json | jq -r '.items[0].endpoints[] | "\(.targetRef.name) ready=\(.conditions.ready)"'
kubectl exec client -- sh -c 'for i in $(seq 1 20); do wget -q -O - http://pret/hostname; echo; done' | sort | uniq -c
```

```sortie
NAME                   READY   STATUS    RESTARTS   AGE
pret-85cfb48c6-6k24m   0/1     Running   0          7s
pret-85cfb48c6-drwx5   1/1     Running   0          7s
pret-85cfb48c6-6k24m ready=false
pret-85cfb48c6-drwx5 ready=true
     20 pret-85cfb48c6-drwx5
```

Le Pod est toujours `Running`, sans redémarrage, mais `0/1` : il n'est plus prêt. L'EndpointSlice le marque `ready=false`, kube-proxy l'a retiré de ses règles, et les vingt requêtes vont à l'autre Pod. Remettons le fichier (`kubectl exec pret-85cfb48c6-6k24m -- touch /tmp/pret`) : quelques secondes plus tard, le Pod redevient `1/1` et reçoit de nouveau du trafic. C'est aussi la readinessProbe qui rend une mise à jour progressive (chapitre 19) vraiment sûre : un nouveau Pod n'est compté comme disponible, et l'ancien n'est supprimé, que lorsque sa sonde réussit.

## La startupProbe

Certaines applications mettent longtemps à démarrer. Ce Pod simule un chargement de trente secondes avant de créer le fichier que vérifie sa livenessProbe :

```yaml title="lent-sans-startup.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: lent-sans-startup
spec:
  containers:
  - name: app
    image: busybox:1.37
    command: ["sh", "-c", "echo 'chargement...'; sleep 30; touch /tmp/vivant; echo 'prêt'; sleep 3600"]
    livenessProbe:
      exec:
        command: ["cat", "/tmp/vivant"]
      periodSeconds: 5
      failureThreshold: 3
```

```bash
kubectl apply -f lent-sans-startup.yaml
# même boucle de surveillance que plus haut, pendant 130 s
kubectl logs lent-sans-startup --previous
kubectl get pod lent-sans-startup -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode} {.status.containerStatuses[0].lastState.terminated.startedAt} {.status.containerStatuses[0].lastState.terminated.finishedAt}{"\n"}'
```

```sortie
t=0 s : 0/1 ContainerCreating 0
t=1 s : 1/1 Running 0
t=46 s : 1/1 Running 1
t=91 s : 1/1 Running 2
chargement...
prêt
137 2026-09-26T06:15:09Z 2026-09-26T06:15:54Z
```

L'application n'a aucune chance : la livenessProbe échoue à 5, 10 et 15 secondes, avant la fin du chargement, et le kubelet décide de tuer le conteneur. Le détail est trompeur : les journaux affichent `prêt`, et le conteneur a vécu 45 secondes. C'est que le processus principal, un shell sans gestionnaire de signal, **ignore SIGTERM** (on le verra plus bas) : il continue donc de tourner pendant les 30 secondes du délai de grâce, finit son chargement, affiche `prêt`, puis est abattu par SIGKILL (code 137). Le Pod redémarre toutes les 45 secondes, pour toujours, sans jamais servir.

Allonger le délai de la livenessProbe (`initialDelaySeconds: 35`) résoudrait ce cas précis (exercice 1), mais ralentirait la détection d'une vraie panne après chaque redémarrage, et resterait fragile si le chargement s'allonge. La **startupProbe** sépare les deux questions : elle laisse le temps de démarrer, puis passe la main à la livenessProbe.

```yaml title="lent-avec-startup.yaml (extrait)"
    startupProbe:
      exec:
        command: ["cat", "/tmp/vivant"]
      periodSeconds: 5
      failureThreshold: 12
    livenessProbe:
      exec:
        command: ["cat", "/tmp/vivant"]
      periodSeconds: 5
      failureThreshold: 3
```

```bash
kubectl apply -f lent-avec-startup.yaml
```

```sortie
t=0 s : 0/1 ContainerCreating 0 started=false
t=1 s : 0/1 Running 0 started=false
t=35 s : 1/1 Running 0 started=true
chargement...
prêt
```

(La boucle affiche aussi le champ `started` de l'état du conteneur, qui passe à `true` quand la startupProbe réussit.) La startupProbe a toléré jusqu'à 12 échecs espacés de 5 secondes, soit une minute pour démarrer ; elle a réussi à 35 secondes, et c'est seulement alors que la livenessProbe a pris le relais, avec sa détection rapide. Le Pod est aussi resté `0/1` pendant le démarrage : une readinessProbe absente est considérée comme réussie, mais pas avant la fin de la startupProbe.

<Figure svg={troisSondes} num="22.1" alt="Trois sondes et ce qui arrive quand elles échouent. startupProbe, a-t-il fini de démarrer : tant qu'elle échoue, les deux autres sondes sont suspendues ; au-delà de failureThreshold échecs, le conteneur est tué ; lent-avec-startup est prêt à 35 secondes. Puis livenessProbe, est-il encore vivant : le kubelet tue le conteneur et le relance, RESTARTS augmente ; malade est relancé à 19, 37 et 55 secondes. readinessProbe, peut-il recevoir du trafic : le Pod passe 0/1, reste en vie et sort des EndpointSlices ; les 20 requêtes vont vers l'autre Pod.">
Les trois sondes et leurs conséquences, avec les mesures de ce chapitre.
</Figure>

## La fin d'un Pod

Un Pod s'arrête souvent : à chaque mise à jour, à chaque réduction du nombre de répliques, à chaque déplacement d'un nœud à l'autre. Si l'application est en train de traiter une requête ou d'écrire en base, il faut lui laisser le temps de finir. La séquence d'arrêt suit un ordre précis[^arret] :

1. le Pod reçoit une date de suppression ; au même moment, il sort des EndpointSlices, et les Services cessent de lui envoyer de nouvelles connexions ;
2. le kubelet exécute le crochet `preStop` du conteneur, s'il en a un, et attend qu'il se termine ;
3. il envoie **SIGTERM** au processus principal du conteneur (PID 1) ;
4. si le conteneur ne s'est pas arrêté à la fin du **délai de grâce** (`terminationGracePeriodSeconds`, 30 secondes par défaut, compté dès l'étape 1), il envoie **SIGKILL**, qui ne se refuse pas.

Voici un programme qui fait les choses bien : il intercepte SIGTERM, termine son travail, puis s'arrête avec le code 0.

```yaml title="arret-propre.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: arret-propre
spec:
  terminationGracePeriodSeconds: 20
  containers:
  - name: app
    image: busybox:1.37
    command: ["sh", "-c", "trap 'echo \"$(date +%T) SIGTERM reçu, je termine les envois en cours\"; sleep 4; echo \"$(date +%T) terminé proprement\"; exit 0' TERM; echo \"$(date +%T) démarré\"; while true; do sleep 1; done"]
```

```bash
kubectl apply -f arret-propre.yaml
kubectl wait --for=condition=Ready pod/arret-propre
echo "$(date -u +%T) kubectl delete"; kubectl delete pod arret-propre --wait=false
kubectl logs -f arret-propre &
kubectl wait --for=delete pod/arret-propre
```

```sortie
06:17:28 kubectl delete
06:17:26 démarré
06:17:29 SIGTERM reçu, je termine les envois en cours
06:17:33 terminé proprement
supprimé en 6144 ms
```

(Les heures sont en UTC des deux côtés. La mesure de durée vient du script de validation.) Le signal est arrivé moins d'une seconde après la demande de suppression, le programme a pris ses quatre secondes, et le Pod a disparu en six secondes, bien avant la fin de son délai de grâce. Maintenant, le cas du shell de tout à l'heure, qui ignore SIGTERM :

```yaml title="arret-sourd.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: arret-sourd
spec:
  terminationGracePeriodSeconds: 10
  containers:
  - name: app
    image: busybox:1.37
    command: ["sh", "-c", "trap '' TERM; echo \"$(date +%T) démarré, j'ignore SIGTERM\"; while true; do sleep 1; done"]
```

```sortie
06:17:38 kubectl delete
NAME          READY   STATUS        RESTARTS   AGE
arret-sourd   1/1     Terminating   0          5s
supprimé en 11145 ms
```

Le Pod reste `Terminating` pendant tout le délai de grâce, dix secondes, puis est tué. Ici, le programme ignore SIGTERM volontairement (`trap ''`) ; dans la réalité, c'est le plus souvent involontaire, et le chapitre 4 en a donné la cause : un processus qui est le PID 1 de son namespace n'a pas de comportement par défaut pour SIGTERM, et ignore le signal s'il ne l'intercepte pas explicitement. Un script lancé par `sh -c`, un `CMD` en forme shell, une application qui n'a pas prévu de gérer le signal : chaque Pod de ce genre retarde de 30 secondes chaque mise à jour, et perd ses requêtes en cours au lieu de les terminer.

### preStop

Reste une course. À l'étape 1, le Pod sort des EndpointSlices ; mais il faut un peu de temps pour que chaque kube-proxy de chaque nœud (et chaque répartiteur de charge externe, chaque Ingress) mette à jour ses règles. Pendant ce temps, de nouvelles connexions peuvent encore arriver sur un Pod qui a déjà reçu SIGTERM et fermé son port. Le crochet **preStop** comble ce trou : il retarde SIGTERM, le temps que le reste du cluster ait arrêté d'envoyer du trafic.

```yaml title="prestop.yaml (extrait)"
    lifecycle:
      preStop:
        exec:
          command: ["sh", "-c", "echo \"$(date +%T) preStop : j'attends 5 s\" >> /proc/1/fd/1; sleep 5"]
```

```sortie
06:17:52 kubectl delete
06:17:50 démarré
06:17:52 preStop : j'attends 5 s
06:17:58 SIGTERM reçu
06:17:59 Pod supprimé
```

(Le crochet écrit dans `/proc/1/fd/1`, la sortie du processus principal, pour que son message apparaisse dans `kubectl logs`.) Le kubelet a lancé `preStop` aussitôt, attendu ses cinq secondes, puis seulement envoyé SIGTERM. Pour une image sans shell, comme les images distroless du chapitre 13, Kubernetes propose une action de pause intégrée, sans commande à exécuter :

```yaml title="sleep-natif.yaml (extrait)"
    lifecycle:
      preStop:
        sleep:
          seconds: 5
```

Sur le cluster du cours, un Pod agnhost ainsi équipé met 6,6 secondes à disparaître : cinq secondes de pause, et un arrêt rapide. Attention au budget : le délai de grâce court **pendant** le `preStop`. Avec un `preStop` de 5 secondes et une application qui met 10 secondes à se terminer, un délai de grâce de 10 secondes ne suffit plus ; il faut l'augmenter.

<Figure svg={arretPod} num="22.2" alt="Frise de 0 à 12 secondes à partir de kubectl delete, où le Pod sort des EndpointSlices. arret-propre reçoit SIGTERM, fait 4 secondes de nettoyage, sort avec 0, supprimé en 6,1 s. arret-sourd ignore SIGTERM, attend tout le délai de grâce de 10 secondes, reçoit SIGKILL, supprimé en 11,1 s. prestop exécute preStop (sleep 5), puis reçoit SIGTERM et sort aussitôt, en 7 s. Ordre fixe : preStop, puis SIGTERM au PID 1 du conteneur, puis SIGKILL à la fin du délai de grâce, qui court dès le début, preStop compris.">
La suppression d'un Pod, mesurée sur trois programmes. Le délai de grâce commence au moment de la suppression et englobe le <code>preStop</code>.
</Figure>

## Bien régler ses sondes

Quelques règles tirées de ce chapitre, et de l'expérience de ceux qui ont vu des sondes provoquer des pannes :

- toujours une **readinessProbe** pour un serveur qui reçoit du trafic ; c'est elle qui rend les mises à jour sans interruption ;
- une **livenessProbe** seulement si l'application peut se bloquer sans s'arrêter, et qui ne vérifie que le processus lui-même, jamais ses dépendances ;
- une **startupProbe** plutôt qu'un grand `initialDelaySeconds` quand le démarrage est long ou variable ;
- des sondes **bon marché** : un point d'entrée dédié (`/sante`, `/pret`), qui répond en quelques millisecondes, sans calcul ni requête en base pour la livenessProbe ;
- un programme qui **gère SIGTERM**, et un `preStop` de quelques secondes pour les serveurs derrière un Service.

L'API de Colis a justement deux points d'entrée faits pour cela, `/sante` (le processus répond) et `/pret` (la base et Redis sont joignables) ; le chapitre 24 s'en servira.

## Exercices

:::exercice[Exercice 1 : sans startupProbe]

Rendez le Pod `lent-sans-startup` viable sans ajouter de startupProbe, avec un seul changement dans sa livenessProbe. Vérifiez qu'il ne redémarre plus. Quel inconvénient cette solution a-t-elle par rapport à la startupProbe ?

:::

<details>
<summary>Corrigé</summary>

Il suffit de retarder la première vérification au-delà du chargement : `initialDelaySeconds: 35`.

```bash
sed 's/name: lent-sans-startup/name: lent-delai/; s/      periodSeconds: 5/      initialDelaySeconds: 35\n      periodSeconds: 5/' lent-sans-startup.yaml > lent-delai.yaml
kubectl apply -f lent-delai.yaml
sleep 60
kubectl get pod lent-delai
```

```sortie
NAME         READY   STATUS    RESTARTS   AGE
lent-delai   1/1     Running   0          62s
```

Aucun redémarrage. Les inconvénients : le délai s'applique à chaque démarrage, y compris après un redémarrage par la livenessProbe, et il doit être supérieur au démarrage **le plus lent** qu'on puisse rencontrer (un nœud chargé, un cache froid) ; si le chargement dépasse un jour 35 secondes, on retombe dans la boucle. La startupProbe, elle, laisse une fenêtre maximale (une minute ici) mais passe la main dès que l'application est prête, 35 secondes ou 5.

</details>

:::exercice[Exercice 2 : entendre SIGTERM]

Modifiez `arret-sourd.yaml` pour que le programme s'arrête aussitôt quand il reçoit SIGTERM, et mesurez le temps de suppression. Comment obtenir le même résultat pour un programme dont on ne peut pas modifier le code ?

:::

<details>
<summary>Corrigé</summary>

Il suffit de remplacer `trap '' TERM` par `trap 'exit 0' TERM`.

```bash
kubectl apply -f arret-corrige.yaml
kubectl wait --for=condition=Ready pod/arret-corrige
d=$(date +%s%N); kubectl delete pod arret-corrige
echo "supprimé en $(( ($(date +%s%N)-d)/1000000 )) ms"
```

```sortie
arret-corrige supprimé en 1501 ms
```

Une seconde et demie au lieu de onze, dont une partie vient de la boucle `sleep 1`, pendant laquelle le shell ne traite pas le signal. Pour un programme qu'on ne peut pas modifier, la solution est de ne pas le faire tourner en PID 1 : on lance à sa place un petit processus d'initialisation, comme `tini`, qui relaie les signaux au programme et récupère ses enfants terminés (c'est ce que fait `docker run --init`, que Kubernetes n'a pas ; il faut donc ajouter `tini` à l'image, chapitre 4). Et dans un `CMD` ou un `command`, on évite la forme shell (`sh -c "mon-programme"`) au profit de la forme exec (`["mon-programme"]`), pour que le programme soit lui-même le PID 1 et reçoive le signal.

</details>

:::exercice[Exercice 3 : une livenessProbe dangereuse]

L'équipe de Colis propose de donner à l'API une livenessProbe sur `/pret`, qui vérifie que PostgreSQL et Redis répondent. Que se passerait-il lors d'une coupure de la base de dix minutes ? Quelle sonde utiliser sur `/pret`, et laquelle sur `/sante` ?

:::

<details>
<summary>Corrigé</summary>

Pendant la coupure, `/pret` échouerait sur tous les Pods de l'API à la fois. Au bout de `periodSeconds × failureThreshold`, le kubelet tuerait tous les conteneurs, les relancerait, les tuerait de nouveau, et le recul exponentiel finirait par les laisser en `CrashLoopBackOff`, jusqu'à cinq minutes entre deux tentatives. Quand la base reviendrait, l'API resterait indisponible jusqu'à la fin de ce recul, et les redémarrages en masse auraient chargé la base au moment où elle redémarre. C'est un exemple classique de panne en cascade.

La bonne répartition : `/pret` en readinessProbe (pendant la coupure, les Pods sortent des Services, et les clients reçoivent une erreur claire au lieu d'attendre ; ils reviennent tout seuls dès que la base répond), `/sante` en livenessProbe (le processus Python répond-il ?). C'est ce que fera le chapitre 24.

</details>

## Nettoyer

```bash
kubectl delete namespace ch22
kubectl config set-context --current --namespace=default
```

[^sondes]: Kubernetes, « Liveness, Readiness, and Startup Probes », et « Configure Liveness, Readiness and Startup Probes », section *Configure Probes* (valeurs par défaut). [kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes](https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/)

[^crochets]: Kubernetes, « Container Lifecycle Hooks ». [kubernetes.io/docs/concepts/containers/container-lifecycle-hooks](https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/)

[^arret]: Kubernetes, « Pod Lifecycle », section *Termination of Pods*. [kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination)
