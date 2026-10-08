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
