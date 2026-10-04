---
title: Durcir les Pods
sidebar_label: 44. Durcir les Pods
description: "Imposer un niveau de sécurité à tout un namespace : les trois Pod Security Standards, Pod Security Admission et ses modes, le Deployment accepté dont les Pods sont refusés, nginx durci pas à pas, Colis passé au niveau restricted composant par composant, et le bilan du cluster."
partie: 6
chapitre: '44'
---

import pssNiveaux from '@site/src/figures/pss-niveaux.svg';
import psaModes from '@site/src/figures/psa-modes.svg';

Que se passerait-il si l'on décidait, ce soir, que les Pods de Colis doivent respecter le niveau de sécurité le plus strict que Kubernetes définisse ? Inutile de le décider pour le savoir. On peut poser la question à l'API server en étiquetant le namespace « à blanc », avec `--dry-run=server` : rien n'est enregistré, mais la réponse est celle qu'on obtiendrait pour de vrai.

```bash
kubectl label --dry-run=server --overwrite ns colis pod-security.kubernetes.io/enforce=baseline
kubectl label --dry-run=server --overwrite ns colis pod-security.kubernetes.io/enforce=restricted
```

```sortie
namespace/colis labeled (server dry run)
Warning: existing pods in namespace "colis" violate the new PodSecurity enforce level "restricted:latest"
Warning: api-645df4f4c8-cpj5k (and 6 other pods): allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile
namespace/colis labeled (server dry run)
```

Le premier niveau, `baseline`, passe sans un mot. Le second, `restricted`, est refusé par les sept Pods de Colis, et pour les mêmes quatre raisons. Notez aussi ce que la commande n'aurait pas fait si elle avait été réelle : elle n'aurait arrêté aucun Pod. Le contrôle se fait à la création des Pods, et ceux qui tournent déjà ne sont pas concernés. Mais le prochain redémarrage de l'API, le prochain déploiement, la prochaine montée en charge auraient été refusés. Une règle de sécurité qui ne frappe qu'à retardement est le meilleur moyen de provoquer une panne le jour où l'on s'y attend le moins.

Le chapitre 12 a montré, champ par champ, comment le `securityContext` d'un Pod reproduit les protections d'un conteneur Docker durci. Ce chapitre passe à l'échelle d'un cluster. On y voit comment **imposer** ces réglages à tout un namespace, ce qui casse quand on les applique à de vrais logiciels, et comment y amener Colis sans l'interrompre. Les fichiers sont dans [l'archive durcissement](pathname:///kits/durcissement.tar.gz).

## Trois niveaux de sécurité

Kubernetes définit trois profils de sécurité pour les Pods, les **Pod Security Standards**, du plus permissif au plus strict[^pss] :

- **privileged** n'impose rien. C'est le niveau des composants qui ont réellement besoin de l'hôte : le plan de contrôle, le plugin réseau, les pilotes de stockage.
- **baseline** interdit ce qui donne accès au nœud : les conteneurs privilégiés, les namespaces de l'hôte (réseau, processus, IPC), les volumes `hostPath` et les ports de l'hôte, les capabilities hors d'une liste de base, la désactivation de seccomp. Un Pod écrit sans rien demander de spécial y passe.
- **restricted** exige en plus les bonnes pratiques de durcissement : ne pas tourner en root, interdire l'élévation de privilèges, retirer toutes les capabilities, activer le profil seccomp du runtime, et n'utiliser que des types de volumes sans risque.

<Figure svg={pssNiveaux} num="44.1" alt="Trois cadres emboîtés. Le plus grand, privileged, aucune restriction : plan de contrôle, réseau, stockage, kube-system et metallb-system ; tout est permis. Dedans, baseline, pas d'accès à l'hôte : interdit privileged true, hostNetwork, hostPID, hostIPC, volumes hostPath, hostPort, capabilities hors de la liste par défaut, seccomp Unconfined ; tout Pod ordinaire y passe. Dedans encore, restricted : en plus, exigé runAsNonRoot true, allowPrivilegeEscalation false, capabilities.drop ALL, seccomp RuntimeDefault, volumes configMap, secret, PVC, emptyDir ; Colis, après ce chapitre.">
Les trois Pod Security Standards. Chaque niveau contient toutes les exigences du précédent.
</Figure>

Le namespace `ch44-base` est soumis au niveau `baseline`. Voici ce qu'il accepte et ce qu'il refuse, avec un Pod busybox auquel on demande chaque fois une seule chose :

```bash
kubectl create ns ch44-base
kubectl label ns ch44-base pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/enforce-version=v1.37
kubectl -n ch44-base run privilegie --image=busybox:1.37 --restart=Never --overrides='{"apiVersion":"v1","spec":{"containers":[{"name":"c","image":"busybox:1.37","command":["sleep","3600"],"securityContext":{"privileged":true}}]}}'
# idem avec un volume hostPath, hostNetwork, la capability NET_ADMIN, la capability NET_RAW, et rien du tout
```

```sortie
$ privilegie
Error from server (Forbidden): pods "privilegie" is forbidden: violates PodSecurity "baseline:v1.37": privileged (container "c" must not set securityContext.privileged=true)
$ hote-fs
Error from server (Forbidden): pods "hote-fs" is forbidden: violates PodSecurity "baseline:v1.37": hostPath volumes (volume "h")
$ hote-reseau
Error from server (Forbidden): pods "hote-reseau" is forbidden: violates PodSecurity "baseline:v1.37": host namespaces (hostNetwork=true)
$ cap-netadmin
Error from server (Forbidden): pods "cap-netadmin" is forbidden: violates PodSecurity "baseline:v1.37": non-default capabilities (container "c" must not include "NET_ADMIN" in securityContext.capabilities.add)
$ cap-netraw
Error from server (Forbidden): pods "cap-netraw" is forbidden: violates PodSecurity "baseline:v1.37": non-default capabilities (container "c" must not include "NET_RAW" in securityContext.capabilities.add)
$ ordinaire
pod/ordinaire created
```

Chaque refus nomme le contrôle violé et le champ en cause. Le cas de `NET_RAW` est instructif. Cette capability fait partie des quatorze que containerd donne par défaut à tout conteneur (on la retrouvera dans un instant). Pourtant `baseline` refuse qu'on la demande explicitement, parce que sa liste de capabilities autorisées ne la contient pas : `AUDIT_WRITE`, `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `FSETID`, `KILL`, `MKNOD`, `NET_BIND_SERVICE`, `SETFCAP`, `SETGID`, `SETPCAP`, `SETUID`, `SYS_CHROOT`, et rien d'autre[^pss]. `NET_RAW` permet de fabriquer des paquets réseau arbitraires, et le niveau `restricted` finira de la retirer en exigeant `drop: [ALL]`.

## Pod Security Admission

Ces niveaux ne sont que des définitions. Pour les faire respecter, Kubernetes intègre un contrôleur d'admission, **Pod Security Admission**, actif par défaut et stable depuis la version 1.25[^psa]. On le règle namespace par namespace, avec des étiquettes de la forme `pod-security.kubernetes.io/<mode>=<niveau>`, et il connaît trois modes :

- **enforce** refuse tout Pod qui viole le niveau ;
- **warn** accepte, mais renvoie un avertissement au client, que kubectl affiche ;
- **audit** accepte, et ajoute une annotation à l'événement correspondant du journal d'audit de l'API server (minikube n'en tient pas par défaut).

Chaque mode peut viser un niveau différent, et chacun accepte une étiquette de version, `pod-security.kubernetes.io/<mode>-version`. Sans elle, c'est `latest` : la définition du niveau suit la version de Kubernetes, et une montée de version peut durcir les règles d'un namespace sans que personne n'y ait touché. En fixant `v1.37`, on garde la définition de cette version jusqu'à ce qu'on décide de la changer[^psa].

Dans le namespace `ch44`, en `enforce=restricted`, essayons un Pod nginx ordinaire, puis le même sous forme de Deployment :

```bash
kubectl create ns ch44
kubectl label ns ch44 pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=v1.37
kubectl -n ch44 run nginx-brut --image=nginx:1.30-alpine
kubectl -n ch44 create deployment nginx-brut --image=nginx:1.30-alpine
kubectl -n ch44 get deployment,replicaset
```

```sortie
namespace/ch44 created
namespace/ch44 labeled
Error from server (Forbidden): pods "nginx-brut" is forbidden: violates PodSecurity "restricted:v1.37": allowPrivilegeEscalation != false (container "nginx-brut" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "nginx-brut" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx-brut" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "nginx-brut" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
Warning: would violate PodSecurity "restricted:v1.37": allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
deployment.apps/nginx-brut created
NAME                         READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/nginx-brut   0/1     0            0           5s

NAME                                   DESIRED   CURRENT   READY   AGE
replicaset.apps/nginx-brut-5f9566b54   1         0         0       5s
```

Le Pod est refusé net. Le Deployment, lui, est **créé**, avec un simple avertissement, alors que ses Pods violent exactement les mêmes règles. Ce n'est pas une incohérence. Le mode `enforce` ne s'applique qu'aux Pods ; les modes `warn` et `audit` s'appliquent aussi aux objets qui contiennent un gabarit de Pod (Deployments, Jobs…), pour prévenir au plus tôt[^psa]. Ici, aucune étiquette `warn` n'est posée : l'avertissement vient du contrôle `enforce`, qui signale à la création d'un Deployment un gabarit dont il refusera les Pods. On le constate ici ; la documentation n'en parle pas, ne comptez donc pas dessus et posez une étiquette `warn` explicite. Le refus a lieu plus tard, quand le contrôleur du ReplicaSet essaie de créer le Pod, et il ne s'affiche dans aucun terminal :

```bash
kubectl -n ch44 get events --field-selector reason=FailedCreate -o custom-columns=OBJET:.involvedObject.name,MESSAGE:.message
```

```sortie
OBJET                  MESSAGE
nginx-brut-5f9566b54   Error creating: pods "nginx-brut-5f9566b54-r8zck" is forbidden: violates PodSecurity "restricted:v1.37": allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

<Figure svg={psaModes} num="44.2" alt="En haut : vous faites kubectl apply d'un Deployment ; Pod Security Admission, sur le Deployment, fait vérifier le gabarit par warn et audit, enforce ne s'applique pas ; un avertissement Warning: would violate PodSecurity revient vers vous ; le Deployment est accepté, puis son ReplicaSet créé. En bas : le contrôleur du ReplicaSet crée un Pod ; Pod Security Admission, sur le Pod, applique enforce ; en cas de violation, le Pod est refusé, avec un événement FailedCreate sur le ReplicaSet. kubectl a affiché un avertissement et rendu la main ; le Deployment reste à 0 réplique prête, sans autre message.">
Où agissent les modes de Pod Security Admission. Un Deployment non conforme est accepté ; ce sont ses Pods qui sont refusés, plus tard, loin de votre terminal.
</Figure>

:::panne[Deployment à 0/1, aucun Pod, aucune erreur dans le terminal]

Quand un Deployment reste à `0/1` sans qu'aucun Pod n'apparaisse, ni même en `Pending`, le problème est en amont du scheduler : le ReplicaSet n'arrive pas à créer ses Pods. Les événements du **ReplicaSet** (pas du Deployment) le disent : `kubectl get events --field-selector reason=FailedCreate`, ou `kubectl describe rs`. Pod Security Admission est la cause la plus fréquente ; un quota dépassé (chapitre 23) ou un webhook d'admission (chapitre 45) donnent le même symptôme.

:::

## nginx, durci pas à pas

Les quatre champs que réclame le message semblent suffire. Le fichier `nginx-etape1.yaml` les ajoute, et rien d'autre : `runAsNonRoot` et le profil seccomp pour tout le Pod, l'interdiction d'élévation de privilèges et le retrait des capabilities pour le conteneur.

```bash
kubectl apply -f nginx-etape1.yaml
kubectl -n ch44 get pod nginx-durci
kubectl -n ch44 get events --field-selector involvedObject.name=nginx-durci,type=Warning -o custom-columns=RAISON:.reason,MESSAGE:.message
```

```sortie
pod/nginx-durci created
NAME          READY   STATUS                       RESTARTS   AGE
nginx-durci   0/1     CreateContainerConfigError   0          10s
RAISON   MESSAGE
Failed   Error: container has runAsNonRoot and image will run as root (pod: "nginx-durci_ch44(8f05b482-576b-47fa-be07-72c224235335)", container: nginx)
```

L'admission a accepté le Pod : il déclare tout ce qu'il faut. C'est le **kubelet** qui refuse de démarrer le conteneur, parce que `runAsNonRoot` est une vérification et non un réglage. L'image `nginx` ne précise aucun utilisateur, donc elle démarrerait en root, et le kubelet le constate au moment de lancer le conteneur. Il faut choisir un utilisateur. L'image en contient un, `nginx`, d'UID 101 ; `nginx-etape2.yaml` ajoute `runAsUser: 101` et `runAsGroup: 101` :

```bash
kubectl apply -f nginx-etape2.yaml
kubectl -n ch44 get pod nginx-durci
kubectl -n ch44 logs nginx-durci | tail -4
```

```sortie
pod/nginx-durci created
NAME          READY   STATUS   RESTARTS     AGE
nginx-durci   0/1     Error    1 (9s ago)   10s
2026/10/04 08:28:36 [warn] 1#1: the "user" directive makes sense only if the master process runs with super-user privileges, ignored in /etc/nginx/nginx.conf:2
nginx: [warn] the "user" directive makes sense only if the master process runs with super-user privileges, ignored in /etc/nginx/nginx.conf:2
2026/10/04 08:28:36 [emerg] 1#1: mkdir() "/var/cache/nginx/client_temp" failed (13: Permission denied)
nginx: [emerg] mkdir() "/var/cache/nginx/client_temp" failed (13: Permission denied)
```

Le conteneur démarre, mais nginx s'arrête aussitôt. Il a été écrit pour démarrer en root, créer ses dossiers de travail, puis passer sous l'utilisateur `nginx` (la directive `user`, désormais ignorée). Sous l'UID 101, il ne peut pas créer son cache dans `/var/cache/nginx`, qui appartient à root, et il ne pourrait pas écrire son fichier PID dans `/run`. On lui donne deux volumes `emptyDir`, qui lui appartiennent puisqu'ils sont vides et inscriptibles. Tant qu'à faire, on rend le reste du système de fichiers en lecture seule (`readOnlyRootFilesystem`), ce que `restricted` n'exige pas :

```yaml title="nginx-durci.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: nginx-durci
  namespace: ch44
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 101
    runAsGroup: 101
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: nginx
    image: nginx:1.30-alpine
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: [ALL]
    volumeMounts:
    - {name: cache, mountPath: /var/cache/nginx}
    - {name: run, mountPath: /run}
  volumes:
  - {name: cache, emptyDir: {}}
  - {name: run, emptyDir: {}}
```

```bash
kubectl apply -f nginx-durci.yaml
kubectl -n ch44 exec nginx-durci -- sh -c 'id; wget -qO- http://127.0.0.1/ | grep -o "<title>.*</title>"; grep -E "^(CapPrm|CapEff|CapBnd|NoNewPrivs|Seccomp):" /proc/1/status; touch /etc/essai; netstat -ltn | grep ":80 "'
```

```sortie
pod/nginx-durci created
pod/nginx-durci condition met
uid=101(nginx) gid=101(nginx) groups=101(nginx)
<title>Welcome to nginx!</title>
CapPrm:	0000000000000000
CapEff:	0000000000000000
CapBnd:	0000000000000000
NoNewPrivs:	1
Seccomp:	2
touch: /etc/essai: Read-only file system
tcp        0      0 0.0.0.0:80              0.0.0.0:*               LISTEN      
```

nginx sert sa page, sous l'UID 101, sans aucune capability (`CapEff` à zéro), avec `no_new_privs` et le filtre seccomp du runtime (`Seccomp: 2`), et sa racine refuse l'écriture. Pour mesurer le chemin parcouru, voici les mêmes valeurs pour un nginx ordinaire, lancé dans un namespace sans étiquette (`ch44-libre`) :

```bash
kubectl -n ch44-libre exec nginx-brut -- sh -c 'id -u; grep -E "^(CapPrm|CapEff|CapBnd|NoNewPrivs|Seccomp):" /proc/1/status; cat /proc/sys/net/ipv4/ip_unprivileged_port_start'
capsh --decode=00000000a80425fb
```

```sortie
0
CapPrm:	00000000a80425fb
CapEff:	00000000a80425fb
CapBnd:	00000000a80425fb
NoNewPrivs:	0
Seccomp:	0
0
0x00000000a80425fb=cap_chown,cap_dac_override,cap_fowner,cap_fsetid,cap_kill,cap_setgid,cap_setuid,cap_setpcap,cap_net_bind_service,cap_net_raw,cap_sys_chroot,cap_mknod,cap_audit_write,cap_setfcap
```

Root, quatorze capabilities dont `cap_net_raw`, aucun filtre seccomp : c'est le constat du chapitre 12. Une question devrait vous gêner : comment nginx peut-il écouter sur le port 80 sans aucune capability, alors qu'un port inférieur à 1024 exige normalement `CAP_NET_BIND_SERVICE` ? La dernière valeur répond. Dans chaque Pod, `net.ipv4.ip_unprivileged_port_start` vaut 0 : tous les ports sont ouverts aux utilisateurs ordinaires. C'est containerd qui le règle ainsi, par son option `enable_unprivileged_ports`, activée par défaut depuis containerd 2.0 pour tout conteneur qui n'utilise pas le réseau de l'hôte[^containerd]. Le port reste confiné au namespace réseau du Pod, sa limite ne protégeait plus rien. Sur un runtime plus ancien, il faudrait faire écouter nginx sur un port haut, ou lui rendre la seule capability `NET_BIND_SERVICE`, que `restricted` autorise à rajouter.

## Durcir Colis sans l'interrompre

Le chemin vers `restricted` est le même pour toute application : prévenir d'abord, corriger, vérifier, et seulement ensuite interdire. On passe Colis en `warn` et `audit` sur `restricted`. Rien n'est bloqué, mais chaque modification non conforme le dit :

```bash
kubectl label ns colis pod-security.kubernetes.io/warn=restricted pod-security.kubernetes.io/warn-version=v1.37 \
  pod-security.kubernetes.io/audit=restricted pod-security.kubernetes.io/audit-version=v1.37
kubectl -n colis rollout restart deployment/redis
```

```sortie
namespace/colis labeled
Warning: would violate PodSecurity "restricted:v1.37": allowPrivilegeEscalation != false (container "redis" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "redis" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "redis" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "redis" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
deployment.apps/redis restarted
```

Le redémarrage de Redis a eu lieu, avec un avertissement. C'est l'état idéal pendant une migration : les équipes voient ce qu'elles devront corriger, sans que rien ne casse.

Pour chaque composant, il faut connaître l'utilisateur sous lequel l'image peut tourner, et ce qu'elle a besoin d'écrire. On l'a relevé en inspectant les images et les Pods en marche :

| Composant | Image | Utilisateur | Ce qu'il écrit |
|---|---|---|---|
| api, api-canari, worker, purge | `colis/api:2.1` | `10001`, déjà déclaré par l'image (Dockerfile du défi II) | rien |
| web | `colis/web:1.0` (nginx) | root par défaut ; `nginx` (101) existe | `/var/cache/nginx`, `/run` |
| redis | `redis:8.8-alpine` | root, puis `redis` (999, groupe 1000) | `/data` |
| postgres | `postgres:18-alpine` | root, puis `postgres` (70) | le volume persistant, `/var/run/postgresql`, `/tmp` |

Redis et PostgreSQL ont une particularité : leur script de démarrage commence en root, change les propriétaires des dossiers de données, puis passe sous l'utilisateur du service. S'ils démarrent directement sous cet utilisateur, ils sautent cette étape, ce qui marche tant que les dossiers lui appartiennent déjà. C'est le cas du volume de PostgreSQL, que le premier démarrage a confié à l'UID 70.

Les correctifs sont des *patches* stratégiques, un par composant, dans `colis/`. Celui de l'API est le plus simple : l'image tourne déjà sous l'UID 10001, il suffit de le déclarer. On en profite pour ne plus monter de jeton de ServiceAccount dans des Pods qui ne parlent jamais à l'API Kubernetes (chapitre 42) :

```yaml title="colis/api.yaml"
spec:
  template:
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: api
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: [ALL]
```

`colis/worker.yaml` et `colis/purge.yaml` sont identiques, au nom du conteneur près (et, pour le CronJob, au chemin `spec.jobTemplate.spec.template`). On commence par les composants sans état, puis on vérifie que l'application répond et que le worker, réveillé par KEDA, traite un nouveau colis :

```bash
kubectl -n colis patch deployment api --patch-file colis/api.yaml
kubectl -n colis patch deployment api-canari --patch-file colis/api.yaml
kubectl -n colis patch deployment worker --patch-file colis/worker.yaml
curl -s http://192.168.49.100/api/sante; echo
curl -s -X POST http://192.168.49.100/api/colis -H 'Content-Type: application/json' -d '{"destinataire":"Essai ch44","depart":"Brest","arrivee":"Nantes","poids_kg":2}' | jq -c '{id, statut}'
# une fois le worker démarré par KEDA
kubectl -n colis logs $W --tail=2
kubectl -n colis exec $W -- sh -c 'id; grep -E "^(CapEff|NoNewPrivs|Seccomp):" /proc/1/status; ls /var/run/secrets/kubernetes.io'
```

```sortie
deployment.apps/api patched
deployment.apps/api-canari patched
deployment.apps/worker patched
{"statut":"ok","version":"2.1.0","hote":"api-868c78ff96-6ntgf"}
{"id":245,"statut":"enregistré"}
worker worker-8c945f5bc-mvsh4 prêt (stockage : postgres)
colis 245 : Brest -> Nantes, 2 jours, livraison estimée le 2026-10-06
uid=10001(colis) gid=10001(colis) groups=10001(colis)
CapEff:	0000000000000000
NoNewPrivs:	1
Seccomp:	2
ls: /var/run/secrets/kubernetes.io: No such file or directory
command terminated with exit code 1
```

L'API répond, le colis 245 a été estimé par un worker sans capability, et aucun jeton d'API n'est plus monté (`No such file or directory`, ce qu'on voulait). Un Pod compromis n'aurait plus ni droits sur l'API Kubernetes, ni capabilities à exploiter.

`web` reprend les réglages de nginx vus plus haut. `redis` tourne sous l'UID 999 avec `/data` dans un `emptyDir`, puisque sa file de travail n'était déjà pas persistante. Le CronJob `purge` reçoit le même correctif que l'API :

```bash
kubectl -n colis patch deployment web --patch-file colis/web.yaml
kubectl -n colis patch deployment redis --patch-file colis/redis.yaml
kubectl -n colis patch cronjob purge --patch-file colis/purge.yaml
kubectl -n colis exec deploy/redis -- sh -c 'id; redis-cli ping'
curl -s -o /dev/null -w "page d'accueil : %{http_code}\n" http://192.168.49.100/
kubectl -n colis create job purge-durcie --from=cronjob/purge
kubectl -n colis logs job/purge-durcie --tail=1
```

```sortie
deployment.apps/web patched
deployment.apps/redis patched
cronjob.batch/purge patched
uid=999(redis) gid=1000(redis) groups=1000(redis)
PONG
page d'accueil : 200
job.batch/purge-durcie created
purge : 0 colis livrés depuis plus de 30 jours supprimés
```

Reste PostgreSQL, le seul composant dont un échec coûterait des données. Son correctif ajoute deux `emptyDir`, pour le socket et pour `/tmp`, et ne touche pas au volume persistant :

```yaml title="colis/postgres.yaml (extrait)"
      containers:
      - name: postgres
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: [ALL]
        volumeMounts:
        - {name: socket, mountPath: /var/run/postgresql}
        - {name: tmp, mountPath: /tmp}
```

```bash
kubectl -n colis patch statefulset postgres --patch-file colis/postgres.yaml
kubectl -n colis rollout status statefulset/postgres --timeout=300s
kubectl -n colis logs postgres-0 --tail=2
kubectl -n colis exec postgres-0 -- sh -c 'id; ls -lnd /var/lib/postgresql/18/docker'
curl -s http://192.168.49.100/api/colis | jq length
curl -s -X POST http://192.168.49.100/api/colis -H 'Content-Type: application/json' -d '{"destinataire":"Essai ch44 bis","depart":"Rennes","arrivee":"Lille","poids_kg":1}' | jq -c '{id, statut}'
```

```sortie
statefulset.apps/postgres patched
Waiting for partitioned roll out to finish: 0 out of 1 new pods have been updated...
Waiting for 1 pods to be ready...
partitioned roll out complete: 1 new pods have been updated...
2026-10-04 08:29:21.159 UTC [25] LOG:  database system was shut down at 2026-10-04 08:29:19 UTC
2026-10-04 08:29:21.171 UTC [1] LOG:  database system is ready to accept connections
uid=70(postgres) gid=70(postgres) groups=70(postgres)
drwx------   19 70       0             4096 Oct  4 08:29 /var/lib/postgresql/18/docker
50
{"id":246,"statut":"enregistré"}
```

(On a retiré deux répétitions de `Waiting for 1 pods to be ready...`.) PostgreSQL a redémarré sous l'UID 70 sur ses données existantes, que le dossier lui appartenait déjà. La liste des colis se lit (l'API renvoie les 50 plus récents) et une écriture passe : l'API version 2.1 s'est reconnectée seule, comme prévu au chapitre 26.

Plus d'avertissement possible : l'étiquetage à blanc ne trouve plus rien à redire, et on peut imposer le niveau.

```bash
kubectl label --dry-run=server --overwrite ns colis pod-security.kubernetes.io/enforce=restricted
kubectl label --overwrite ns colis pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=v1.37
kubectl -n colis get pods
```

```sortie
namespace/colis labeled (server dry run)
namespace/colis labeled
NAME                          READY   STATUS      RESTARTS      AGE
api-868c78ff96-6ntgf          1/1     Running     0             38s
api-868c78ff96-jgdgf          1/1     Running     0             34s
api-canari-6878794947-dzktk   1/1     Running     0             37s
postgres-0                    1/1     Running     0             7s
purge-durcie-zhd4b            0/1     Completed   0             13s
redis-5cbb6759f7-2cjfs        1/1     Running     0             19s
web-55679cdb97-bhpbx          1/1     Running     0             19s
web-55679cdb97-z8ppk          1/1     Running     0             17s
worker-8c945f5bc-mvsh4        1/1     Running     1 (18s ago)   29s
```

Colis tourne désormais au niveau `restricted`, imposé. Le seul redémarrage visible est celui du worker, au moment où PostgreSQL a redémarré : le worker s'arrête quand il perd sa connexion, et le kubelet le relance. Ce comportement existait avant ce chapitre ; on l'avait simplement moins souvent provoqué.

:::panne[Après avoir ajouté runAsUser, la base démarre vide ou refuse de démarrer]

Si les fichiers du volume appartiennent à un autre UID que celui choisi, le service n'a plus le droit de les lire ou de les écrire, et s'arrête au démarrage ou à la première écriture ; le message dépend du logiciel. Vérifiez le propriétaire avec `ls -ln` dans un Pod qui monte le volume, et choisissez le même UID, comme on l'a fait pour PostgreSQL (70). Le champ `fsGroup` du Pod, qui demande au kubelet de confier le volume à un groupe au montage, est une autre piste ; on n'en a pas eu besoin ici, et il modifie les droits de tous les fichiers du volume, ce qu'un logiciel comme PostgreSQL, exigeant sur les droits de son dossier de données, peut refuser. Et si une base démarre **vide**, vérifiez que le montage du volume persistant n'a pas disparu dans l'opération : c'est ce qu'aurait fait la première version du script `defaire-colis.sh`, dont le filtre retirait par erreur le montage nommé `donnees`, le nom du volume de PostgreSQL.

:::

## Le bilan du cluster

L'étiquetage à blanc fonctionne aussi sur tous les namespaces à la fois. C'est la façon la plus rapide de savoir où en est un cluster, avant de choisir le niveau de chaque namespace[^migrer] :

```bash
kubectl label --dry-run=server --overwrite ns --all pod-security.kubernetes.io/enforce=baseline
```

```sortie
Warning: existing pods in namespace "kube-system" violate the new PodSecurity enforce level "baseline:latest"
Warning: csi-hostpath-attacher-0 (and 2 other pods): hostPath volumes, privileged
Warning: etcd-minikube (and 3 other pods): host namespaces, hostPath volumes, hostPort, probe or lifecycle host
Warning: kindnet-rq5t5: non-default capabilities, host namespaces, hostPath volumes
Warning: kube-proxy-n9tb4: host namespaces, hostPath volumes, privileged
Warning: storage-provisioner: host namespaces, hostPath volumes
Warning: existing pods in namespace "metallb-system" violate the new PodSecurity enforce level "baseline:latest"
Warning: speaker-869zv: non-default capabilities, host namespaces, hostPort
```

(Les lignes `namespace/... labeled (server dry run)` ont été retirées.) Seuls deux namespaces ont besoin de `privileged`, et c'est normal : `kube-system` contient le plan de contrôle, kube-proxy, kindnet et le pilote de stockage ; `metallb-system` contient le `speaker`, qui doit annoncer des adresses sur le réseau du nœud. Tout le reste passe `baseline`.

La même commande avec `restricted` est plus bavarde. Retenons ce qu'elle dit des namespaces de la partie IV : `cert-manager`, `keda` et `envoy-gateway-system` sont **absents** de la liste des avertissements. Leurs charts livrent déjà des Pods conformes à `restricted`, et l'on pourrait leur imposer ce niveau demain. `vpa`, `metallb-system` et `kube-system` ne le sont pas, ni les copies de Colis des parties précédentes (`colis-helm`, `colis-defi`), ni quelques Pods oubliés dans `default` et `ch15`. L'exercice 3 vous fait écrire l'outil qui résume tout cela en un tableau.

Quand un namespace a besoin de `privileged`, on le dit explicitement, par l'étiquette `enforce=privileged`, plutôt que de le laisser sans étiquette. Une configuration d'admission (`AdmissionConfiguration`) peut aussi fixer un niveau par défaut pour tout le cluster, et déclarer des **exemptions** par namespace, par utilisateur ou par `RuntimeClass`[^psa]. Attention aux exemptions par utilisateur : la plupart des Pods sont créés par des contrôleurs, pas par des personnes, et exempter une personne n'exempte que les Pods qu'elle crée directement.

## Au-delà de restricted

`restricted` est un plancher, pas un plafond. Colis va déjà plus loin sur deux points que le niveau n'exige pas : la racine en lecture seule, et l'absence de jeton de ServiceAccount. D'autres protections existent, que les Pod Security Standards ne contrôlent pas ou peu :

- les **user namespaces** (`hostUsers: false`), qui font correspondre le root d'un conteneur à un utilisateur sans privilège sur le nœud ; le chapitre 12 a montré qu'ils ne fonctionnent pas avec le pilote docker de minikube ;
- les profils **AppArmor** ou **SELinux** dédiés, plus précis que les profils par défaut du runtime ;
- un profil **seccomp** `Localhost` écrit pour l'application, plus étroit que `RuntimeDefault` ;
- les **requests et limits** (chapitre 23), qui empêchent un Pod compromis d'affamer ses voisins.

Pour des règles que les trois niveaux ne savent pas exprimer, comme « les images doivent venir de notre registre » ou « tout Deployment doit déclarer des limites », il faut écrire ses propres règles d'admission. C'est le sujet du chapitre 45.

## Exercices

:::exercice[Exercice 1 : le dormeur]

Écrivez le Pod le plus simple possible qui soit accepté dans `ch44` (niveau `restricted`) : un conteneur `busybox:1.37` qui exécute `sleep 3600`. Busybox ne déclare aucun utilisateur ; lequel choisir ? Vérifiez avec `id`.

:::

<details>
<summary>Corrigé</summary>

```yaml title="dormeur.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: dormeur
  namespace: ch44
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: c
    image: busybox:1.37
    command: [sleep, "3600"]
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: [ALL]
```

```bash
kubectl apply -f dormeur.yaml
kubectl -n ch44 exec dormeur -- id
```

```sortie
pod/dormeur created
uid=65534(nobody) gid=65534(nobody) groups=65534(nobody)
```

Sans `runAsUser`, le kubelet refuserait de démarrer le conteneur, comme pour nginx à l'étape 1. L'UID 65534, `nobody`, existe dans presque toutes les images, et ne possède rien : c'est le choix par défaut pour un programme qui n'écrit nulle part. Les quatre exigences de `restricted` plus un utilisateur : c'est le gabarit minimal à garder sous la main.

</details>

:::exercice[Exercice 2 : la panne silencieuse]

Un collègue a créé dans `ch44` le Deployment `nginx-brut` de la section sur Pod Security Admission. kubectl a affiché un avertissement qu'il n'a pas lu, et il vous dit que « le Deployment ne démarre pas, sans erreur ». Sans regarder ce chapitre, quelles commandes lancez-vous, dans quel ordre, et qu'y lisez-vous ? Comment corrigez-vous, et à quel objet appliquez-vous la correction ?

:::

<details>
<summary>Corrigé</summary>

```bash
kubectl -n ch44 get deployment,replicaset,pods
kubectl -n ch44 describe replicaset -l app=nginx-brut | tail -3
kubectl -n ch44 get events --field-selector reason=FailedCreate
```

Le Deployment est à `0/1`, le ReplicaSet a `DESIRED 1` et `CURRENT 0`, et il n'y a **aucun** Pod, pas même en `Pending` : le problème est donc avant le scheduler. Les événements du ReplicaSet donnent le message complet, celui de la section : `violates PodSecurity "restricted:v1.37"` suivi des quatre contrôles. La correction porte sur le **gabarit de Pod du Deployment** (`kubectl edit deployment nginx-brut`, ou mieux, le manifeste versionné), en reprenant les réglages de `nginx-durci.yaml` : utilisateur 101, `emptyDir` pour le cache et `/run`, et les quatre champs. Modifier le ReplicaSet ou créer le Pod à la main ne servirait à rien : le Deployment recréerait son ReplicaSet à partir de son propre gabarit.

</details>

:::exercice[Exercice 3 : le tableau de bord PSS (programmation)]

Écrivez en Python `niveau-pss.py`, qui affiche pour chaque namespace : le nombre de Pods, les étiquettes `enforce` et `warn` actuelles, et le niveau le plus strict que **tous** ses Pods respectent déjà. Signalez les namespaces prêts à recevoir une étiquette `enforce` qu'ils n'ont pas encore. Ne recodez pas les contrôles des Pod Security Standards : demandez à l'API server, avec l'étiquetage à blanc sur tous les namespaces, et analysez ses avertissements. Attention aux namespaces vides.

:::

<details>
<summary>Corrigé</summary>

Le corrigé est `corrige/niveau-pss.py`. Le cœur tient en une fonction, qui renvoie les namespaces en infraction pour un niveau :

```python title="corrige/niveau-pss.py (extrait)"
def namespaces_en_infraction(niveau):
    _, erreurs = kubectl("label", "--dry-run=server", "--overwrite", "ns", "--all",
                         f"{CLE}enforce={niveau}")
    return set(re.findall(r'existing pods in namespace "([^"]+)" violate', erreurs))
```

Les avertissements arrivent sur la sortie d'erreur de kubectl. Un namespace est au niveau `restricted` s'il n'est pas dans les infractions de `restricted`, sinon au niveau `baseline` s'il n'est pas dans celles de `baseline`, sinon `privileged`.

```bash
python3 corrige/niveau-pss.py
```

```sortie
namespace              Pods  enforce      warn         niveau atteint
cert-manager              3  -            -            restricted      <- prêt pour enforce=restricted
ch15                      3  -            -            baseline        <- prêt pour enforce=baseline
ch43                      0  -            -            -               (aucun Pod : rien à vérifier)
ch44                      2  restricted   -            restricted    
ch44-base                 1  baseline     -            baseline      
ch44-libre                1  -            -            baseline        <- prêt pour enforce=baseline
colis                     9  restricted   restricted   restricted    
colis-defi                1  -            -            baseline        <- prêt pour enforce=baseline
colis-dev                 0  -            -            -               (aucun Pod : rien à vérifier)
colis-helm                5  -            -            baseline        <- prêt pour enforce=baseline
default                   2  -            -            baseline        <- prêt pour enforce=baseline
envoy-gateway-system      2  -            -            restricted      <- prêt pour enforce=restricted
keda                      3  -            -            restricted      <- prêt pour enforce=restricted
kube-node-lease           0  -            -            -               (aucun Pod : rien à vérifier)
kube-public               0  -            -            -               (aucun Pod : rien à vérifier)
kube-system              14  -            -            privileged    
metallb-system            2  -            -            privileged    
passerelle                0  -            -            -               (aucun Pod : rien à vérifier)
vitrine                   0  -            -            -               (aucun Pod : rien à vérifier)
vpa                       3  -            -            baseline        <- prêt pour enforce=baseline
```

Le piège des namespaces vides : sans Pod, aucun avertissement, et un namespace vide semblerait conforme à `restricted`. Il l'est, trivialement, mais cela ne dit rien des Pods qu'on y créera. `colis-dev` est vide parce que ses répliques ont été mises à zéro au chapitre 31 ; avant de l'étiqueter, il faudrait relancer ses Pods et refaire la mesure.

</details>

:::exercice[Exercice 4 : déboguer dans un namespace restricted]

Colis est désormais en `enforce=restricted`. Essayez d'attacher un conteneur de débogage éphémère à un Pod de l'API avec `kubectl debug <pod> --image=busybox:1.37 --target=api`. Que se passe-t-il, et pourquoi ? Trouvez dans `kubectl debug --help` l'option qui règle le problème, et vérifiez que le conteneur de débogage voit bien le processus de l'API.

:::

<details>
<summary>Corrigé</summary>

```bash
P=$(kubectl -n colis get pods --field-selector=status.phase=Running -o name | grep -m1 '^pod/api-' | cut -d/ -f2)
kubectl -n colis debug $P --image=busybox:1.37 --target=api -- sleep 30
kubectl -n colis debug $P --image=busybox:1.37 --target=api --profile=restricted -- sh -c 'id; ps -o user,pid,args | head -3'
kubectl -n colis logs $P -c debugger-99b7w
```

```sortie
Targeting container "api". If you don't see processes from this container it may be because the container runtime doesn't support this feature.
Defaulting debug container name to debugger-f4p7b.
Warning: Non-root user is configured for the entire target Pod, and some capabilities granted by debug profile may not work. Please consider using "--custom" with a custom profile that specifies "securityContext.runAsUser: 0".
Error from server (Forbidden): pods "api-868c78ff96-6ntgf" is forbidden: violates PodSecurity "restricted:v1.37": allowPrivilegeEscalation != false (container "debugger-f4p7b" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "debugger-f4p7b" must set securityContext.capabilities.drop=["ALL"]; container "debugger-f4p7b" must not include "SYS_PTRACE" in securityContext.capabilities.add)
Targeting container "api". If you don't see processes from this container it may be because the container runtime doesn't support this feature.
Defaulting debug container name to debugger-99b7w.
uid=10001 gid=10001 groups=10001
USER     PID   COMMAND
10001        1 {uvicorn} /opt/venv/bin/python /opt/venv/bin/uvicorn colis.app:app --host 0.0.0.0 --port 8000
10001        8 sh -c id; ps -o user,pid,args | head -3
```

Un conteneur éphémère est ajouté au Pod par une mise à jour (sous-ressource `ephemeralcontainers`), et Pod Security Admission la contrôle comme le reste. Le profil par défaut de `kubectl debug`, `general`, ajoute la capability `SYS_PTRACE` pour permettre de tracer les processus : `restricted` la refuse. Le profil `restricted` produit un conteneur conforme. Il hérite de l'utilisateur du Pod (10001) et voit, grâce à `--target`, les processus du conteneur `api`, ce qui suffit à la plupart des diagnostics. Les autres profils (`baseline`, `netadmin`, `sysadmin`) correspondent à d'autres niveaux ; on y reviendra au chapitre 48.

</details>

## Nettoyer

```bash
kubectl delete namespace ch44 ch44-base ch44-libre
kubectl -n colis delete job purge-durcie
```

Colis reste durci, et c'est voulu : le défi VI partira de cet état. Pour le remettre tel qu'il était avant ce chapitre (sans les réglages de sécurité, les volumes ajoutés ni les étiquettes Pod Security), le kit fournit `defaire-colis.sh`, que le script de rejeu utilise au début.

[^pss]: Kubernetes, « Pod Security Standards » : niveaux privileged, baseline et restricted, contrôles de chacun (liste des capabilities permises en baseline, types de volumes permis, `runAsNonRoot`, seccomp, élévation de privilèges, `capabilities.drop: [ALL]` avec seul ajout permis `NET_BIND_SERVICE`). [kubernetes.io/docs/concepts/security/pod-security-standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
[^psa]: Kubernetes, « Pod Security Admission » : stable depuis 1.25, modes enforce, audit et warn, étiquettes de niveau et de version (`latest` par défaut), modes warn et audit appliqués aux ressources de charge de travail et enforce aux seuls Pods, exemptions par utilisateur, `RuntimeClass` et namespace. [kubernetes.io/docs/concepts/security/pod-security-admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
[^migrer]: Kubernetes, « Enforce Pod Security Standards with Namespace Labels » et « Migrate from PodSecurityPolicy to the Built-In PodSecurity Admission Controller » : étiquetage à blanc avec `--dry-run=server` pour évaluer un niveau sur les Pods existants. [kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels](https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/)
[^containerd]: containerd, « CRI Plugin Config Guide » : `enable_unprivileged_ports` règle `net.ipv4.ip_unprivileged_port_start=0` pour les conteneurs qui n'utilisent pas le réseau de l'hôte ; la valeur par défaut était `false` avant containerd 2.0. [github.com/containerd/containerd/blob/main/docs/cri/config.md](https://github.com/containerd/containerd/blob/main/docs/cri/config.md)
