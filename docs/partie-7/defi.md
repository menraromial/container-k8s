---
title: Défi VII, l'incident
sidebar_label: Défi VII
description: "Un changement appliqué à la main casse le calcul des dates de livraison sans faire tomber l'API : recevoir la page, trouver les causes avec les métriques, les journaux, les événements et un conteneur éphémère, rétablir le service, mesurer l'impact sur les colis, puis écrire le post-mortem."
partie: 7
plaque: Défi VII
---

import chronologieIncident from '@site/src/figures/chronologie-incident.svg';

Une page arrive sur le téléphone d'astreinte. Elle tient en une ligne :

```sortie
2026-10-08T18:40:16Z FIRING   ColisFileBloquee     page   150 colis attendent leur date de livraison.
```

Personne n'a signalé de panne, le site répond, l'API aussi. Quelque part entre l'enregistrement d'un colis et le calcul de sa date de livraison, quelque chose s'est arrêté. Ce défi est une astreinte complète : rétablir le service, trouver toutes les causes, mesurer ce que les utilisateurs ont subi, puis écrire le post-mortem, le compte rendu qui permet à l'équipe de ne pas revivre la même panne. Les outils sont ceux des chapitres 48 à 53. Le travail consiste à choisir le bon au bon moment, et à ne pas s'arrêter à la première cause trouvée.

## Le point de départ

Le cluster principal, tel que le chapitre 53 l'a laissé : Colis 2.2.1 dans le namespace `colis`, avec ses métriques, ses journaux JSON et ses traces ; dans `supervision`, kube-prometheus-stack, l'Alertmanager qui envoie les alertes de Colis au petit récepteur `pager` du chapitre 50, Loki, Tempo et le collecteur OpenTelemetry du chapitre 51. Vérifiez avant de commencer que tout est vert : aucun Pod en erreur dans `colis`, et la commande `kubectl -n colis exec deploy/redis -c redis -- redis-cli llen colis:a-estimer` répond `0`.

[L'archive defi-7](pathname:///kits/defi-7.tar.gz) contient quatre fichiers : `declencher.sh`, qui rejoue la mise en production d'un collègue puis envoie du trafic ; `charge.py`, le générateur de trafic du chapitre 50 ; `verifier.sh`, la grille ; `post-mortem-modele.md`, le modèle de post-mortem.

Ne lisez pas `declencher.sh` avant d'avoir rendu votre post-mortem : il contient la réponse. Il ne modifie que des objets du namespace `colis`, note l'heure de début dans un fichier `debut-incident` (la grille s'en sert), puis lance quinze minutes de trafic dans le terminal où vous l'avez démarré :

```bash
tar -xzf defi-7.tar.gz && cd defi-7
./declencher.sh
```

```sortie
mise en production faite à 19:37:16 ; trafic pendant 1500 s (Ctrl-C pour l'arrêter plus tôt)
```

Dans un second terminal, ouvrez les accès des chapitres 50 et 51 (Prometheus sur le port 9095, Grafana sur 3050, Loki sur 3101, Tempo sur 3201), puis suivez le récepteur d'alertes, qui joue le rôle du téléphone :

```bash
kubectl -n supervision logs -f deploy/pager --timestamps
```

La page arrive au bout de trois minutes environ. Notez une première différence : `declencher.sh` affiche l'heure locale du poste, alors que le récepteur, les événements Kubernetes et Prometheus parlent en UTC. Sur le poste de validation, l'écart était d'une heure. Un post-mortem s'écrit dans un seul fuseau, et le plus simple est celui des machines.

## Le cahier des charges

1. Rétablir le service : le calcul des dates doit reprendre et la file se vider, en changeant le moins de choses possible.
2. Trouver toutes les causes, y compris celles qui n'ont encore rien cassé. Un changement qui a provoqué une panne en a souvent préparé d'autres.
3. Mesurer l'impact : combien de colis, quel retard, combien de requêtes en erreur, avec la source de chaque chiffre. « Le worker était en panne » n'est pas un impact ; « 300 colis sans date pendant 6 minutes » en est un.
4. Écrire le post-mortem à partir de `post-mortem-modele.md`. Le modèle suit celui du livre *Site Reliability Engineering* de Google[^sre-exemple], et la même règle : un post-mortem est sans blâme. Il cherche ce qui, dans le système et ses pratiques, a permis l'erreur, sans désigner de coupable[^sre-culture].
5. Programmation : écrire `impact.py`. Pour chaque colis enregistré pendant l'incident, calculez le retard entre son enregistrement (colonne `cree_le` de PostgreSQL) et le calcul de sa date (la ligne « colis N : … livraison estimée » du worker, dans Loki, qui porte le champ `colis`). Le script affiche le nombre de colis, ceux qui n'ont jamais été estimés, puis la médiane, le 95e centile et le maximum des retards.

## La grille

`verifier.sh` prend en paramètre le chemin de votre post-mortem (`post-mortem.md` par défaut). Elle ouvre elle-même son accès à Prometheus, crée un colis, lance une purge et une sonde réseau, puis supprime ce qu'elle a créé. Passée pendant l'incident :

```bash
./verifier.sh post-mortem.md
```

```sortie
ÉCHEC   1. aucune alerte en cours sur colis (en cours : ColisFileBloquee)
ÉCHEC   2. file d'estimation vide (192 colis en attente)
ÉCHEC   3. colis de l'incident tous estimés (136 sans date sur 192 depuis 2026-10-08T18:37:16Z)
ÉCHEC   4. colis neuf 3487 estimé en moins d'une minute (statut : enregistré après 60 s)
ÉCHEC   5. mémoire du worker : requête 48Mi et limite 48Mi pour un pic de 67Mi sur l'heure
ÉCHEC   6. la purge s'exécute
OK      7. base fermée aux autres namespaces
ÉCHEC   8. post-mortem : fichier post-mortem.md introuvable

1 vérification(s) réussie(s), 7 en échec
```

L'objectif : huit `OK`. Les vérifications 6 et 7 tirent dans deux directions : la purge doit joindre la base, une sonde d'un autre namespace ne le doit pas. Ouvrir la base à tous les namespaces réussirait la 6 et échouerait à la 7. La vérification 5 compare les ressources du worker à son pic de mémoire de la dernière heure, mesuré par Prometheus : une limite choisie au hasard, même grande, n'est pas le but. La 8 ne juge pas la qualité du post-mortem ; elle vérifie qu'il a ses rubriques, une chronologie horodatée, et qu'il parle de chacune des modifications du changement.

## Indices

Ouvrez-les un par un, seulement si vous êtes bloqué.

<details>
<summary>Indice 1 : qu'est-ce qui a changé ?</summary>

Une panne qui commence d'un coup a presque toujours un changement pour origine. L'API server note, pour chaque champ de chaque objet, quel gestionnaire l'a écrit en dernier et à quelle heure : ce sont les `managedFields` des chapitres 16 et 18, que `kubectl get` cache par défaut et que `--show-managed-fields` affiche. Cherchez, dans le namespace `colis`, les objets modifiés à la même seconde.

</details>

<details>
<summary>Indice 2 : un processus tué n'écrit rien</summary>

Si les journaux d'un conteneur sont vides, ce n'est pas qu'il n'y a rien à voir. Le noyau tue un processus qui dépasse sa limite de mémoire par `SIGKILL`, sans lui laisser le temps d'écrire (chapitres 9, 23 et 49). L'information est dans l'état du conteneur (`kubectl describe pod`, champ `Last State`), et dans les métriques de kube-state-metrics.

</details>

<details>
<summary>Indice 3 : le premier correctif ne suffit pas</summary>

Après la première correction, la file continue de grossir et les Pods du worker meurent encore, avec un autre code de sortie. Un défaut peut en cacher un autre quand le premier empêche le programme d'atteindre l'endroit où le second se manifeste. Relisez **tout** le changement, objet par objet.

</details>

<details>
<summary>Indice 4 : tester le réseau avec l'identité du worker</summary>

Une NetworkPolicy décide d'après les étiquettes du Pod. Pour savoir ce que le worker peut joindre, il faut tester depuis un Pod qui porte ses étiquettes, ou depuis son propre espace réseau : un conteneur éphémère (chapitre 48) partage celui du Pod, même quand le conteneur principal est en train de redémarrer. Dans `colis`, la politique d'images du chapitre 45 refuse `netshoot` : seuls le registre du cours, `redis`, `postgres` et `busybox` sont admis. `busybox` a `nc` ; l'image de Colis a Python, qui suffit aussi pour ouvrir une connexion TCP. Le profil `restricted` de `kubectl debug` respecte le niveau de Pod Security du namespace.

</details>

<details>
<summary>Indice 5 : l'impact</summary>

L'API n'a pas renvoyé une seule erreur : le taux de 5xx et la latence ne mesurent rien ici. Ce que les utilisateurs ont subi, c'est un colis affiché « enregistré », sans date, pendant plusieurs minutes. La base connaît l'heure de création de chaque colis ; le journal du worker, celle où sa date a été calculée.

</details>

## Corrigé

Ne l'ouvrez qu'après avoir essayé. Le corrigé est dans le dépôt du cours, sous `kits/defi-7/corrige` : le script de réparation `reparer.sh`, le post-mortem `post-mortem.md` et `impact.py`.

<details>
<summary>Voir le corrigé commenté</summary>

### La page et les premiers symptômes

La page dit que la file d'estimation ne se vide plus. Avant d'ouvrir un tableau de bord, un `get pods` :

```bash
kubectl -n colis get pods
```

```sortie
NAME                      READY   STATUS             RESTARTS       AGE
api-5dd9fd6cdf-9k4gm      1/1     Running            0              3m7s
api-5dd9fd6cdf-wvmvz      1/1     Running            0              3m2s
postgres-0                1/1     Running            0              25m
redis-5cbb6759f7-2cjfs    1/1     Running            1 (46m ago)    9h
web-65cdb99b99-6ppdj      1/1     Running            1 (46m ago)    9h
web-65cdb99b99-wctcb      1/1     Running            1 (46m ago)    9h
worker-7d58fdf7b6-5x8t7   0/1     CrashLoopBackOff   4 (78s ago)    2m57s
worker-7d58fdf7b6-f9frn   0/1     CrashLoopBackOff   4 (80s ago)    2m57s
worker-7d58fdf7b6-gdc5t   0/1     OOMKilled          5 (85s ago)    3m5s
worker-7d58fdf7b6-jgbn7   0/1     OOMKilled          4 (117s ago)   2m42s
worker-7d58fdf7b6-vwf8f   0/1     OOMKilled          4 (113s ago)   2m42s
```

Cinq Pods du worker, tous en échec, et deux Pods de l'API créés trois minutes plus tôt. Le reste n'a pas bougé. Prometheus confirme que l'API va bien :

```promql
max(colis_file_longueur{namespace="colis"})                              # la file
sum(rate(colis_http_requetes_total{namespace="colis", code=~"5.."}[5m]))  # les erreurs 5xx
colis:latence:p95_5m                                                     # le 95e centile par route
```

```sortie
# la file
182
# les erreurs 5xx : aucune série
# le 95e centile, en secondes
namespace=colis,route=/colis/{id_} 0.00475
namespace=colis,route=/colis 0.01937417847972805
# les alertes actives de colis
alertname=ColisFileBloquee,alertstate=firing,namespace=colis,severite=page
```

La requête des erreurs 5xx ne rend **aucune série** : la métrique n'a jamais été incrémentée avec un code 5xx, il n'y en a eu aucune. La latence est celle du chapitre 50. L'incident est entièrement hors du chemin des requêtes, ce qui explique aussi que les traces de l'API soient parfaitement normales : il n'y a rien à corréler de ce côté.

### Le worker : phase 1

```bash
kubectl -n colis describe pod worker-7d58fdf7b6-5x8t7
kubectl -n colis get events --field-selector involvedObject.name=worker-7d58fdf7b6-5x8t7
```

```sortie
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Thu, 08 Oct 2026 19:40:31 +0100
      Finished:     Thu, 08 Oct 2026 19:40:33 +0100
    Ready:          False
    Limits:
      memory:  48Mi
    Requests:
      cpu:     50m
      memory:  48Mi
```

```sortie
RAISON      NOMBRE   MESSAGE
Scheduled   1        Successfully assigned colis/worker-7d58fdf7b6-5x8t7 to minikube
Pulled      6        Container image "host.minikube.internal:5001/colis/api:2.2.1" already present on machine and can be accessed by the pod
Created     6        Container created
Started     6        Container started
BackOff     8        Back-off restarting failed container worker in pod worker-7d58fdf7b6-5x8t7_colis(90fe5d3e-e442-48d3-bdd5-e47d279a4fd1)
```

`OOMKilled`, code 137 (128 + 9, `SIGKILL`), au bout de deux secondes de vie, sous une limite de 48 Mi. En temps normal, `kubectl top` mesure 55 Mi pour un worker au travail : il ne peut pas tenir. Les journaux de la même période, dans Loki, sont vides : le worker est tué avant même d'écrire sa ligne « prêt ». Trois requêtes LogQL sur les 5 min 45 s qui séparent le changement du premier correctif :

```logql
sum by (k8s_pod_name) (count_over_time({service_name="worker", k8s_namespace_name="colis"} |= "prêt" [345s]))
sum(count_over_time({service_name="worker", k8s_namespace_name="colis"} |= "livraison estimée" [345s]))
sum(count_over_time({service_name="worker", k8s_namespace_name="colis"} |~ "(?i)(error|killed|memory)" [345s]))
```

La première ne rend aucune série : aucun worker n'a dit qu'il était prêt. Les deux autres :

```sortie
colis estimés pendant la phase 1 : 0
lignes contenant error, killed ou memory pendant la phase 1 : 0
```

### Ce qui a changé

Une limite de 48 Mi n'est pas venue toute seule. Pour chaque objet du namespace, le dernier gestionnaire qui l'a modifié, en dehors du gestionnaire de contrôleurs qui met à jour les statuts :

```bash
for o in deployment/worker deployment/api deployment/web statefulset/postgres \
         networkpolicy/postgres networkpolicy/worker configmap/colis-config; do
  kubectl -n colis get $o --show-managed-fields -o json | jq -r --arg o $o '
    [.metadata.managedFields[] | select(.manager != "kube-controller-manager" and .time != null)]
    | max_by(.time) | "\($o)\t\(.manager)\t\(.operation)\t\(.time)"'
done | sort -t$'\t' -k4 | column -t -s$'\t'
```

```sortie
deployment/web          kubectl-rollout            Update  2026-10-07T20:42:02Z
networkpolicy/worker    kubectl-client-side-apply  Update  2026-10-08T06:17:05Z
configmap/colis-config  kubectl-patch              Update  2026-10-08T08:28:18Z
statefulset/postgres    kubectl-patch              Update  2026-10-08T18:11:37Z
deployment/api          menage-ressources          Update  2026-10-08T18:37:16Z
deployment/worker       menage-ressources          Update  2026-10-08T18:37:16Z
networkpolicy/postgres  menage-ressources          Update  2026-10-08T18:37:16Z
```

Trois objets modifiés à la même seconde par le même gestionnaire, `menage-ressources`. Le gestionnaire n'est pas une personne : c'est le nom que l'outil déclare à l'API server (`kubectl` met `kubectl-patch` ou `kubectl-client-side-apply` par défaut, `--field-manager` le change). Ici, il désigne un changement, et c'est ce dont le post-mortem a besoin. Le StatefulSet de PostgreSQL a lui aussi été modifié, 25 minutes plus tôt, par un `kubectl patch` sans nom : c'est un suspect à écarter, et on l'écarte avec une raison (la base a fonctionné normalement pendant ces 25 minutes, la file était vide à 18:37:00). Les champs touchés par `menage-ressources` :

```bash
kubectl -n colis get deployment worker --show-managed-fields -o json \
  | jq -c '.metadata.managedFields[] | select(.manager == "menage-ressources") | {manager, time, champs: .fieldsV1}'
kubectl -n colis get networkpolicy postgres --show-managed-fields -o json \
  | jq -c '.metadata.managedFields[] | select(.manager == "menage-ressources") | {manager, time, champs: .fieldsV1}'
kubectl -n colis get networkpolicy postgres -o jsonpath='{.spec.ingress[0].from}'
```

```sortie
{"manager":"menage-ressources","time":"2026-10-08T18:37:16Z","champs":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"worker\"}":{"f:resources":{"f:limits":{"f:memory":{}},"f:requests":{"f:memory":{}}}}}}}}}}
{"manager":"menage-ressources","time":"2026-10-08T18:37:16Z","champs":{"f:spec":{"f:ingress":{}}}}
[{"podSelector":{"matchLabels":{"app.kubernetes.io/name":"api"}}}]
```

Sur le worker, la requête et la limite de mémoire ; sur la politique `postgres`, toute la liste des règles d'entrée, qui ne laisse plus passer que l'API. Le troisième objet, l'API elle-même, a vu sa requête mémoire passer de 192 Mi à 128 Mi. L'historique des Deployments ne dit rien de l'auteur, la colonne `CHANGE-CAUSE` est vide ; les ReplicaSets donnent l'heure des nouveaux gabarits :

```sortie
# kubectl -n colis rollout history deployment/worker | tail -2
44        <none>
45        <none>
# kubectl -n colis get rs -l 'app.kubernetes.io/name in (worker,api)' --sort-by=.metadata.creationTimestamp \
#     -o custom-columns=RS:.metadata.name,CREE:.metadata.creationTimestamp,VOULUS:.spec.replicas,MEMOIRE:.spec.template.spec.containers[0].resources.requests.memory | tail -5
worker-7c98db6968   2026-10-08T09:16:26Z   0        96Mi
worker-8c945f5bc    2026-10-08T09:16:26Z   0        96Mi
api-7984754b6       2026-10-08T09:33:29Z   0        192Mi
api-5dd9fd6cdf      2026-10-08T18:37:16Z   2        128Mi
worker-7d58fdf7b6   2026-10-08T18:37:16Z   5        48Mi
```

À ce stade, on connaît les trois modifications. Le corrigé, comme beaucoup d'astreintes réelles, ne les traite pas tout de suite toutes les trois : on répare d'abord ce qu'on comprend.

### Premier correctif, et la phase 2

On rend au worker une requête au-dessus de sa consommation mesurée, et une limite qui laisse de la marge :

```bash
kubectl -n colis patch deployment worker --type=json -p '[
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources",
   "value": {"requests": {"cpu": "50m", "memory": "96Mi"}, "limits": {"memory": "192Mi"}}}]'
```

```sortie
deployment.apps/worker patched
NAME                      READY   STATUS   RESTARTS      AGE
worker-7bdc5c5b45-4n4qg   0/1     Error    3 (48s ago)   75s
worker-7bdc5c5b45-6gwql   0/1     Error    3 (44s ago)   74s
worker-7bdc5c5b45-852dt   0/1     Error    3 (44s ago)   75s
worker-7bdc5c5b45-ml2nq   0/1     Error    3 (45s ago)   75s
worker-7bdc5c5b45-z8tlf   0/1     Error    3 (43s ago)   74s
file d'estimation : 457
```

Les Pods meurent toujours, mais autrement :

```bash
kubectl -n colis get pod worker-7bdc5c5b45-z8tlf -o json \
  | jq -c '.status.containerStatuses[0] | {restartCount, dernier: .lastState.terminated | {reason, exitCode}}'
```

```sortie
{"restartCount":3,"dernier":{"reason":"Error","exitCode":1}}
```

Code 1 : le programme s'est arrêté de lui-même, sur une exception. Cette fois, il a eu le temps de parler, et Loki a gardé ses dernières lignes. Les quatre dernières lignes d'un Pod, puis le nombre de lignes qui contiennent l'exception :

```logql
{k8s_pod_name="worker-7bdc5c5b45-4n4qg"}
sum(count_over_time({service_name="worker", k8s_namespace_name="colis"} |= "ConnectionTimeout" [5m]))
```

```sortie
    connection = connect_method(*args, **kwargs)
  File "/opt/venv/lib/python3.14/site-packages/psycopg/connection.py", line 126, in connect
    raise last_ex.with_traceback(None)
psycopg.errors.ConnectionTimeout: connection timeout expired
lignes ConnectionTimeout sur 5 min : 20
```

La trace d'appels Python arrive dans Loki ligne par ligne : chaque ligne de la sortie d'erreur est une entrée distincte, sans le format JSON des autres messages. Une recherche par `|= "ConnectionTimeout"` la retrouve ; une requête qui passe les lignes à `| json` les marque d'une erreur `JSONParserErr`, et le filtre `__error__=""` du chapitre 51 les écarte. Le worker ne joint pas PostgreSQL dans le délai de 3 secondes que lui donne son code (`connect_timeout=3`). La politique `postgres` vue plus haut est la suspecte ; un test depuis l'espace réseau du worker le confirme :

```bash
kubectl -n colis debug worker-7bdc5c5b45-4n4qg -c reseau --profile=restricted \
  --image=host.minikube.internal:5001/colis/api:2.2.1 -- python -c '
import socket
for hote, port in [("postgres", 5432), ("redis", 6379)]:
    try:
        socket.create_connection((hote, port), 3).close(); print(hote, port, "ouvert")
    except OSError as e:
        print(hote, port, "fermé :", e)'
kubectl -n colis logs worker-7bdc5c5b45-4n4qg -c reseau
```

```sortie
postgres 5432 fermé : timed out
redis 6379 ouvert
```

Redis répond, PostgreSQL non. La politique de sortie du worker (chapitre 41) autorise les deux ; c'est la politique d'entrée de la base qui refuse.

### Second correctif

On rend à la base ses trois clients, tels que les décrit `kits/politiques/40-postgres.yaml` :

```bash
kubectl -n colis patch networkpolicy postgres --type=json -p '[
  {"op": "replace", "path": "/spec/ingress/0/from",
   "value": [{"podSelector": {"matchExpressions": [{"key": "app.kubernetes.io/name", "operator": "In",
              "values": ["api", "api-canari", "worker", "purge"]}]}}]}]'
```

```sortie
# 18:44:21 UTC : politique postgres : api, api-canari, worker, purge
networkpolicy.networking.k8s.io/postgres patched
# 18:45:55 UTC : file vide
NAME                      READY   STATUS    RESTARTS       AGE
worker-7bdc5c5b45-4n4qg   1/1     Running   4 (116s ago)   2m54s
worker-7bdc5c5b45-6gwql   1/1     Running   4 (111s ago)   2m53s
worker-7bdc5c5b45-852dt   1/1     Running   4 (109s ago)   2m54s
worker-7bdc5c5b45-ml2nq   1/1     Running   4 (115s ago)   2m54s
worker-7bdc5c5b45-z8tlf   1/1     Running   4 (113s ago)   2m53s
# 18:46:25 UTC : page résolue
```

Cinq workers vident la file. La page se résout vingt secondes plus tard :

```sortie
2026-10-08T18:40:16Z FIRING   ColisFileBloquee     page   150 colis attendent leur date de livraison.
2026-10-08T18:46:16Z RESOLVED ColisFileBloquee     page   173 colis attendent leur date de livraison.
```

Le nombre affiché dans la résolution (173) est la dernière valeur au-dessus du seuil : Alertmanager envoie l'annotation telle qu'elle était quand l'alerte était active. La file était vide depuis vingt secondes.

### La cause latente : la purge

La politique fautive bloquait aussi la purge, qui ne tourne qu'à 3 h. Personne ne l'aurait vue échouer avant la nuit, et ses colis livrés seraient restés en base. On la lance à la main pour s'en assurer, à partir du CronJob :

```bash
kubectl -n colis create job defi7-essai --from=cronjob/purge
kubectl -n colis wait --for=condition=Complete job/defi7-essai --timeout=90s
kubectl -n colis logs job/defi7-essai
kubectl -n colis delete job defi7-essai
```

```sortie
job.batch/defi7-essai created
job.batch/defi7-essai condition met
{"moment": "2026-10-08T18:46:27.688Z", "niveau": "info", "service": "colis", "message": "purge : 0 colis livrés depuis plus de 30 jours supprimés", "supprimes": 0, "jours": 30}
job.batch "defi7-essai" deleted from colis namespace
```

Reste la troisième modification, la requête mémoire de l'API. Elle n'est pas une cause : l'API occupe 70 à 80 Mi, ses Pods ont été remplacés sans une erreur, et la grille ne vous demande pas de la défaire. Le post-mortem doit pourtant la mentionner, et dire pourquoi elle est mise hors de cause : c'est la seule façon pour le lecteur de savoir qu'elle a été examinée.

### La chronologie

<Figure svg={chronologieIncident} num="VII.1" alt="Courbe de la file d'estimation pendant l'incident, mesurée par Prometheus toutes les 30 secondes : elle monte régulièrement de 0 à 491 colis entre 18:37 et 18:45, pendant la phase 1 où le worker est tué par manque de mémoire puis la phase 2 où il ne joint pas la base, et retombe à 0 en une minute et demie après le second correctif. Les événements sont marqués sous l'axe du temps : changement à 18:37:16, alerte active à 18:39:45, page à 18:40:16, correctifs à 18:43:01 et 18:44:21, file vide à 18:45:55, page résolue à 18:46:16.">
La file d'estimation pendant l'incident, relevée toutes les 30 secondes dans Prometheus, et les événements qui jalonnent la chronologie.
</Figure>

La file monte d'environ 60 colis par minute, le rythme des enregistrements du générateur de trafic, et continue de monter une minute après le second correctif : le temps que KEDA voie la file (toutes les 5 secondes), que l'HPA crée les Pods et que chacun démarre. La chronologie du post-mortem se reconstruit à partir de quatre sources : les `managedFields` pour le changement, les événements pour les Pods et KEDA, Prometheus pour la file et l'alerte, le récepteur pour la page. Les événements de KEDA, par exemple :

```bash
kubectl -n colis get events -o json | jq -r --arg d 2026-10-08T18:37:16Z '.items[]
  | {t: (.eventTime // .firstTimestamp), k: .involvedObject.kind, n: .involvedObject.name, r: .reason, m: .message}
  | select(.t >= $d and (.k == "Deployment" or .k == "ScaledObject" or .k == "HorizontalPodAutoscaler"))
  | "\(.t[11:19])  \(.k)/\(.n)  \(.r)  \(.m[0:90])"' | sort | uniq
```

```sortie
18:37:18  ScaledObject/worker  KEDAScaleTargetActivated  Scaled apps/v1.Deployment colis/worker from 0 to 1, triggered by s0-redis-colis-a-estimer
18:46:18  ScaledObject/worker  KEDAScaleTargetDeactivated  Deactivated apps/v1.Deployment colis/worker from 5 to 0
18:46:23  ScaledObject/worker  KEDAScaleTargetActivated  Scaled apps/v1.Deployment colis/worker from 0 to 1, triggered by s0-redis-colis-a-estimer
18:46:53  ScaledObject/worker  KEDAScaleTargetDeactivated  Deactivated apps/v1.Deployment colis/worker from 5 to 0
18:46:58  ScaledObject/worker  KEDAScaleTargetActivated  Scaled apps/v1.Deployment colis/worker from 0 to 1, triggered by s0-redis-colis-a-estimer
18:47:43  ScaledObject/worker  KEDAScaleTargetDeactivated  Deactivated apps/v1.Deployment colis/worker from 5 to 0
18:47:48  ScaledObject/worker  KEDAScaleTargetActivated  Scaled apps/v1.Deployment colis/worker from 0 to 1, triggered by s0-redis-colis-a-estimer
18:48:23  ScaledObject/worker  KEDAScaleTargetDeactivated  Deactivated apps/v1.Deployment colis/worker from 5 to 0
18:48:28  ScaledObject/worker  KEDAScaleTargetActivated  Scaled apps/v1.Deployment colis/worker from 0 to 1, triggered by s0-redis-colis-a-estimer
```

Les événements de KEDA n'ont pas de `firstTimestamp`, seulement un `eventTime` : c'est la forme récente de l'API des événements (`events.k8s.io/v1`), que `kubectl get events` affiche mal avec `--sort-by=.lastTimestamp`. D'où le `jq`. Les allers-retours de 0 à 5 répliques après 18:46 sont le fonctionnement normal : chaque nouveau colis réveille le worker, qui retombe à zéro une fois la file vide.

L'heure de passage de l'alerte en attente vient de Prometheus : la série `ALERTS_FOR_STATE{alertname="ColisFileBloquee"}` vaut l'instant (en secondes Unix) où la condition est devenue vraie, ici 18:37:45. Ajoutez les 2 minutes du `for` de la règle et les 30 secondes de `group_wait` d'Alertmanager, et vous retrouvez la page de 18:40:16, à l'intervalle d'évaluation près.

### L'impact

`impact.py` croise la base et Loki :

```bash
kubectl -n supervision port-forward svc/loki 3101:3100 &
python3 impact.py --fin 2026-10-08T18:48:30Z
```

```sortie
période : 18:37:16 -> 18:48:30 UTC
colis enregistrés : 747
  estimés         : 747
  jamais estimés  : 0
retard médian     : 149 s
retard p95        : 426 s
retard maximal    : 449 s (7.5 min)
plus de 30 s     : 528 colis (71 %)
```

Aucun colis perdu, et c'est une chance plus qu'une propriété du système. Le worker prend un colis avec `BLPOP`, qui le retire de la liste[^blpop] : un worker tué entre la prise et l'écriture de la date perdrait ce colis pour de bon. Ici, il mourait avant même de se connecter à Redis. La documentation de Redis décrit la file fiable : `LMOVE` (ou `BLMOVE`) déplace l'élément dans une liste « en cours », dont on ne le retire qu'une fois le travail fait[^lmove]. C'est une action du post-mortem.

Les chiffres de Prometheus sur la même fenêtre :

```sortie
fenêtre                       : 12 min
file au plus haut             : 491 colis
requêtes                      : 3693
  code 200                    : 2604
  code 201                    : 739
  code 404                    : 350
95e centile au plus haut      : 20 ms
redémarrages du worker        : 37.8
pic de mémoire du worker      : 56 Mi
```

Le nombre de redémarrages n'est pas entier : `increase()` extrapole aux bords de la fenêtre, et les compteurs de Pods supprimés disparaissent en cours de route. Les événements donnent un compte exact (72 démarrages de conteneurs pour 26 Pods) ; pour un post-mortem, l'ordre de grandeur suffit.

Le script :

```python
#!/usr/bin/env python3
"""Mesure l'impact de l'incident pour les utilisateurs : combien de colis ont attendu leur date de
livraison, et combien de temps.

La création vient de la base (colonne cree_le), l'estimation du journal du worker dans Loki
(ligne « colis N : ... livraison estimée », champ colis). Le retard d'un colis est l'écart entre les deux.

Usage : python3 impact.py [--debut 2026-10-08T18:00:00Z] [--fin ...] [--loki http://localhost:3101]
(--debut lu dans debut-incident par défaut ; Loki joint par kubectl port-forward svc/loki 3101:3100)
"""
import argparse
import json
import statistics
import subprocess
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

NORMAL_S = 30  # au-delà, le colis a attendu plus que d'habitude (quelques secondes, démarrage du worker compris)


def instant(texte: str) -> datetime:
    return datetime.fromisoformat(texte.replace("Z", "+00:00"))


def creations(debut: datetime, fin: datetime) -> dict[int, datetime]:
    sql = (f"SELECT id, extract(epoch FROM cree_le) FROM colis "
           f"WHERE cree_le >= '{debut.isoformat()}' AND cree_le < '{fin.isoformat()}'")
    sortie = subprocess.run(["kubectl", "-n", "colis", "exec", "postgres-0", "--", "psql", "-U", "colis",
                             "-d", "colis", "-AtF", " ", "-c", sql], capture_output=True, text=True, check=True)
    res = {}
    for ligne in sortie.stdout.splitlines():
        id_, epoch = ligne.split()
        res[int(id_)] = datetime.fromtimestamp(float(epoch), timezone.utc)
    return res


def estimations(loki: str, debut: datetime, fin: datetime) -> dict[int, datetime]:
    requete = '{service_name="worker", k8s_namespace_name="colis"} | json | colis != ""'
    res: dict[int, datetime] = {}
    curseur = debut
    while True:  # Loki rend au plus 5000 lignes par appel : on avance par tranches
        params = urllib.parse.urlencode({"query": requete, "limit": 5000, "direction": "forward",
                                         "start": int(curseur.timestamp() * 1e9),
                                         "end": int(fin.timestamp() * 1e9)})
        with urllib.request.urlopen(f"{loki}/loki/api/v1/query_range?{params}", timeout=30) as r:
            flux = json.load(r)["data"]["result"]
        lignes = [(int(ts), json.loads(texte)) for f in flux for ts, texte in f["values"]]
        for _, l in lignes:
            id_, moment = int(l["colis"]), instant(l["moment"])
            res[id_] = min(res.get(id_, moment), moment)  # un colis estimé deux fois : la première compte
        if len(lignes) < 5000:
            return res
        curseur = datetime.fromtimestamp(max(ts for ts, _ in lignes) / 1e9 + 1e-6, timezone.utc)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--debut", help="début de l'incident (ISO 8601) ; défaut : fichier debut-incident")
    p.add_argument("--fin", help="fin de la période d'enregistrement étudiée ; défaut : maintenant")
    p.add_argument("--loki", default="http://localhost:3101")
    a = p.parse_args()
    debut = instant(a.debut or (Path(__file__).resolve().parent.parent / "debut-incident").read_text().strip())
    fin = instant(a.fin) if a.fin else datetime.now(timezone.utc)
    crees = creations(debut, fin)
    estimes = estimations(a.loki, debut, datetime.now(timezone.utc) + timedelta(minutes=1))
    retards = sorted((estimes[i] - c).total_seconds() for i, c in crees.items() if i in estimes)
    jamais = [i for i in crees if i not in estimes]
    print(f"période : {debut:%H:%M:%S} -> {fin:%H:%M:%S} UTC")
    print(f"colis enregistrés : {len(crees)}")
    print(f"  estimés         : {len(retards)}")
    print(f"  jamais estimés  : {len(jamais)}{' (' + ', '.join(map(str, sorted(jamais)[:10])) + ')' if jamais else ''}")
    if retards:
        en_retard = [r for r in retards if r > NORMAL_S]
        print(f"retard médian     : {statistics.median(retards):.0f} s")
        print(f"retard p95        : {retards[min(len(retards) - 1, int(0.95 * len(retards)))]:.0f} s")
        print(f"retard maximal    : {retards[-1]:.0f} s ({retards[-1] / 60:.1f} min)")
        print(f"plus de {NORMAL_S} s     : {len(en_retard)} colis ({100 * len(en_retard) / len(retards):.0f} %)")


if __name__ == "__main__":
    main()
```

Trois choix méritent un mot. Le retard se mesure avec l'horodatage écrit par le worker dans sa ligne (`moment`), pas avec celui de Loki, qui est l'heure de collecte. Loki rend au plus 5 000 lignes par requête : le script avance par tranches. Enfin, un colis peut être estimé deux fois (l'écriture de la date est rejouable) ; seule la première compte.

### Le post-mortem

```markdown
# Post-mortem : dates de livraison retardées de 2 à 7 minutes

Date de l'incident : 2026-10-08, de 18:37:16 à 18:45:55 UTC
Rédigé par : l'astreinte Colis
État : relu

## Résumé

Un changement de ressources et de politique réseau, appliqué à 18:37:16 directement sur le cluster, a empêché le worker de démarrer pendant 8 min 39 s. L'API a continué de répondre normalement, mais les 747 colis enregistrés pendant cette période ont attendu leur date de livraison estimée : 2 min 29 s en médiane, 7 min 29 s au plus. Aucun colis n'a été perdu. Le même changement aurait fait échouer la purge de 3 h.

## Impact

Toutes les heures sont en UTC. Chaque chiffre est suivi de sa source.

- 747 colis enregistrés entre 18:37:16 et 18:48:30, tous estimés à la fin de l'incident (base PostgreSQL, `cree_le`, croisée avec les lignes « livraison estimée » du worker dans Loki ; `impact.py`).
- Retard entre l'enregistrement et l'estimation : médiane 149 s, 95e centile 426 s, maximum 449 s. 528 colis (71 %) ont attendu plus de 30 s, contre quelques secondes d'habitude (même source).
- File d'estimation : 491 colis au plus haut, à 18:45:00 (Prometheus, `colis_file_longueur`).
- API : aucune réponse 5xx sur environ 3 700 requêtes ; 95e centile de `GET /colis` à 20 ms, inchangé (Prometheus, `colis_http_requetes_total` et `colis:latence:p95_5m`). Un client qui consultait un colis le voyait « enregistré », sans date.
- Purge : aurait échoué à 3 h faute d'accès à la base ; les colis livrés depuis plus de 30 jours seraient restés en base. Aucun effet réel, le défaut a été corrigé avant (Job de purge lancé à la main à 18:46:27).

## Chronologie

| Heure (UTC) | Événement | Source |
|---|---|---|
| 18:37:16 | Changement appliqué par `kubectl patch` sur trois objets : worker à 48 Mi (requête et limite), requête mémoire de l'API à 128 Mi, NetworkPolicy `postgres` restreinte à l'API | `managedFields`, gestionnaire `menage-ressources` |
| 18:37:16 | Nouveau ReplicaSet de l'API (`api-5dd9fd6cdf`), remplacement progressif des deux Pods, sans erreur | événements, ReplicaSets |
| 18:37:18 | KEDA active le worker (file non vide) ; premier Pod du ReplicaSet `worker-7d58fdf7b6` | événement `KEDAScaleTargetActivated` |
| 18:37:22 | Premier `BackOff` d'un Pod du worker : chaque démarrage se termine par `OOMKilled` (code 137) au bout de 2 s, sans une ligne de journal | événements, `describe pod` |
| 18:37:45 | La file dépasse 20 colis : alerte `ColisFileBloquee` en attente | Prometheus, `ALERTS_FOR_STATE` |
| 18:39:45 | L'alerte passe à l'état actif (2 minutes au-dessus du seuil) | règle `ColisFileBloquee`, `for: 2m` |
| 18:40:16 | Page reçue : « 150 colis attendent leur date de livraison » | pager |
| 18:43:01 | Correctif 1 : worker à 96 Mi demandés, 192 Mi de limite | `kubectl patch` |
| 18:43:07 | Les nouveaux Pods du worker démarrent puis s'arrêtent en `Error` (code 1) : `psycopg.errors.ConnectionTimeout` | Loki |
| 18:44:21 | Après un test depuis un conteneur éphémère dans un Pod du worker (PostgreSQL injoignable, Redis joignable), correctif 2 : NetworkPolicy `postgres` rendue à l'API, au worker et à la purge | `kubectl debug`, `kubectl patch` |
| 18:45:00 | File au plus haut, 491 colis ; 5 workers la vident | Prometheus |
| 18:45:55 | File vide : fin de l'impact | Redis, `LLEN` |
| 18:46:16 | Page résolue | pager |
| 18:46:27 | Purge lancée à la main : elle joint la base | Job `defi7-essai` |

## Causes

Deux défauts, introduits par le même changement, le second masqué par le premier.

1. La limite mémoire du worker (48 Mi) est inférieure à ce qu'il occupe en régime normal (55 à 66 Mi mesurés par `kubectl top` et `container_memory_working_set_bytes`). Le noyau tue le processus dès le démarrage, avant qu'il ait pris un colis dans la file. KEDA, qui voit la file grossir, monte à 5 répliques, toutes dans le même état.
2. La NetworkPolicy `postgres` n'autorise plus que les Pods `app.kubernetes.io/name=api`. Le worker et la purge, qui écrivent eux aussi dans la base, sont bloqués. Le défaut est resté invisible tant que le worker mourait avant d'ouvrir sa connexion ; il est apparu dès le premier correctif.

Facteurs qui ont permis l'erreur :

- le changement a été appliqué par `kubectl patch`, hors des manifestes versionnés : ni revue, ni historique (`kubectl rollout history` affiche `<none>` comme cause) ;
- la limite a été choisie sans mesure ; le worker est à 0 réplique au repos, on ne le voit donc pas dans `kubectl top` la plupart du temps ;
- la politique réseau a été réécrite d'après le nom de la base (« seule l'API s'en sert »), sans la matrice des flux du chapitre 41.

La requête mémoire de l'API (192 Mi ramenés à 128 Mi) n'a joué aucun rôle : l'API occupe 70 à 80 Mi et ses Pods ont été remplacés sans erreur.

## Déclencheur

Le changement de ressources du 2026-10-08 à 18:37:16 (gestionnaire `menage-ressources`).

## Résolution

Deux `kubectl patch` : ressources du worker remises à 96 Mi / 192 Mi à 18:43:01, puis NetworkPolicy `postgres` rendue au worker et à la purge à 18:44:21. La file s'est vidée en 1 min 34 s avec 5 workers. Le correctif est dans `reparer.sh` ; il reste à le reporter dans les manifestes versionnés (action 1).

## Détection

La page est arrivée 3 min après le changement, par l'alerte `ColisFileBloquee` (seuil de 20 colis, 2 minutes, plus 30 s de regroupement dans Alertmanager). L'alerte mesure le symptôme vu par l'utilisateur, ce qui a permis de détecter l'incident alors que l'API ne montrait rien.

Aucune autre alerte n'a sonné. `KubePodCrashLooping`, la règle générale de kube-prometheus-stack, attend 15 minutes de `CrashLoopBackOff` : elle aurait sonné vers 18:52, seize minutes après le début. Les journaux étaient vides pendant la première phase : un processus tué par le noyau n'écrit rien.

## Actions

| Action | Type | Responsable | Échéance |
|---|---|---|---|
| Reporter les ressources du worker et la NetworkPolicy `postgres` corrigées dans les manifestes versionnés | réparer | équipe Colis | immédiat |
| N'appliquer les changements que depuis Git, après revue (Argo CD, partie VIII) | prévenir | équipe plateforme | prochain trimestre |
| Dimensionner requêtes et limites à partir des mesures (`dimensionner.py`, chapitre 50), limite à au moins 1,25 fois le pic | prévenir | équipe Colis | 2 semaines |
| Tester les flux après tout changement de NetworkPolicy (`matrice.py`, chapitre 41) | prévenir | équipe plateforme | 2 semaines |
| Alerte sur les redémarrages des conteneurs de `colis` sur 5 minutes | détecter | astreinte | 1 semaine |
| Alerte sur l'échec d'un Job de la purge | détecter | astreinte | 1 semaine |
| File fiable : prendre les colis avec `LMOVE` vers une liste « en cours » au lieu de `BLPOP` | atténuer | équipe Colis | 1 mois |

## Leçons

### Ce qui a bien marché

- L'alerte sur la file a vu un incident que l'API ne montrait pas.
- Les `managedFields` ont donné en une commande l'heure du changement, son auteur (le gestionnaire) et les trois objets touchés.
- Le conteneur éphémère a testé le réseau avec l'identité exacte du worker, sans attendre qu'il reste en vie.

### Ce qui a mal marché

- Le premier correctif n'a pas suffi : on a cru la cause unique. Relire tout le changement dès qu'on l'a trouvé aurait fait gagner 80 secondes.
- Le nœud ne garde que le journal du dernier conteneur mort de chaque Pod ; avec cinq Pods qui redémarraient toutes les quelques secondes, il fallait lire les journaux dans Loki, et on y a pensé tard.

### Là où nous avons eu de la chance

- Le worker mourait avant de prendre un colis. `BLPOP` retire le colis de la file : un worker tué en plein calcul l'aurait perdu, et ce colis n'aurait jamais eu de date.
- L'incident a eu lieu de jour : à 3 h, la purge aurait échoué sans que personne le voie.
```

Avec ce post-mortem et le service rétabli :

```bash
./verifier.sh post-mortem.md
```

```sortie
OK      1. aucune alerte en cours sur colis
OK      2. file d'estimation vide (0 colis en attente)
OK      3. colis de l'incident tous estimés (0 sans date sur 748 depuis 2026-10-08T18:37:16Z)
OK      4. colis neuf 4043 estimé en moins d'une minute (statut : estimé après 6 s)
OK      5. mémoire du worker : requête 96Mi et limite 192Mi pour un pic de 67Mi sur l'heure
OK      6. la purge s'exécute (purge : 0 colis livrés depuis plus de 30 jours supprimés)
OK      7. base fermée aux autres namespaces
OK      8. post-mortem (post-mortem.md) : rubriques complètes, 14 ligne(s) horodatées

8 vérification(s) réussie(s), 0 en échec
```

### Ce que la grille ne vérifie pas

- Les deux correctifs sont des `kubectl patch`, comme le changement fautif. Tant que les fichiers du dépôt ne sont pas corrigés, le prochain `kubectl apply` de quelqu'un d'autre peut réintroduire les valeurs de son choix. C'est la première action du post-mortem, et le sujet de la partie VIII avec Argo CD.
- La grille ne lit pas le post-mortem. Un bon post-mortem se lit sans avoir suivi l'incident, met chaque chiffre à côté de sa source, et propose des actions qui changent le système. « Faire plus attention » n'est pas une action.
- Une seule alerte a sonné, celle qui mesurait le symptôme. La règle générale `KubePodCrashLooping` attend 15 minutes ; une alerte sur les redémarrages des conteneurs de `colis` sur 5 minutes, ou sur l'échec d'un Job de purge, aurait vu plus tôt les deux défauts.

</details>

## Et maintenant

Colis est maintenant observé, sauvegardé, et l'équipe sait mener un incident jusqu'à son post-mortem. Plusieurs actions de ce post-mortem relèvent de la partie VIII : n'appliquer les changements que depuis Git (Argo CD), déployer progressivement pour qu'un défaut ne touche qu'une partie du trafic (Argo Rollouts), et étendre Kubernetes avec ses propres ressources et opérateurs.

Pour faire le ménage du défi, il n'y a presque rien à supprimer : la grille efface son Job de purge et son namespace de sonde, `defi7-sonde`. Il reste le fichier qui note l'heure de début, et le conteneur éphémère `reseau`, qui disparaît avec son Pod (les Pods du worker sont supprimés dès que KEDA ramène le worker à zéro) :

```bash
rm debut-incident
kubectl get ns defi7-sonde 2>/dev/null    # rien : la grille l'a supprimé
```

Si vous avez arrêté le défi avant la fin, `corrige/reparer.sh` remet le worker et la politique `postgres` en état.

[^sre-exemple]: Google, *Site Reliability Engineering*, annexe D, « Example Postmortem » : rubriques Summary, Impact, Root Causes, Trigger, Resolution, Detection, Action Items, Lessons Learned (What went well, What went wrong, Where we got lucky), Timeline. [sre.google/sre-book/example-postmortem](https://sre.google/sre-book/example-postmortem/)
[^sre-culture]: Google, *Site Reliability Engineering*, chapitre 15, « Postmortem Culture: Learning from Failure » : un post-mortem sans blâme cherche les causes « sans mettre en cause une personne ou une équipe », en partant du principe que chacun a agi au mieux avec l'information qu'il avait. [sre.google/sre-book/postmortem-culture](https://sre.google/sre-book/postmortem-culture/)
[^blpop]: Redis, « BLPOP » : version bloquante de `LPOP`, qui retire et renvoie le premier élément de la première liste non vide. [redis.io/docs/latest/commands/blpop](https://redis.io/docs/latest/commands/blpop/)
[^lmove]: Redis, « LMOVE », section « Pattern: Reliable queue » : déplacer l'élément vers une liste de traitement en cours, et l'en retirer une fois le travail terminé, pour qu'un consommateur qui tombe ne perde pas le message. [redis.io/docs/latest/commands/lmove](https://redis.io/docs/latest/commands/lmove/)
