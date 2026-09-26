---
title: Défi III, réparer un déploiement de Colis
sidebar_label: Défi III
description: "Un collègue a préparé un déploiement de Colis sur Kubernetes, et rien ne marche. Cinq erreurs s'y cachent, chacune liée à un chapitre de la partie III : les trouver avec kubectl, les corriger, et expliquer chacune."
partie: 3
plaque: Défi III
---

Un collègue a repris les manifestes du chapitre 24 pour installer une seconde copie de Colis, dans le namespace `colis-defi`, destinée aux essais de l'équipe. Il a fait quelques retouches, « pour économiser des ressources et mettre un peu d'ordre », puis il est parti en congés. Le déploiement ne fonctionne pas, et il ne répond plus au téléphone.

Il y a cinq erreurs dans ses manifestes. Aucune n'est une faute de syntaxe : `kubectl apply` accepte tout sans broncher. Chacune se rattache à un chapitre de la partie, du Service à la configuration, des sondes aux ressources. Le défi consiste à les trouver à partir des symptômes, avec les outils de diagnostic de la partie, plutôt qu'en comparant les fichiers ligne à ligne avec ceux du chapitre 24. Ce serait possible, mais sur un vrai cluster, on n'a pas toujours une version qui marche sous la main.

## Le point de départ

Téléchargez [l'archive du défi](pathname:///kits/defi-3-colis.tar.gz) et déployez-la telle quelle. Il vous faut ce que le chapitre 24 a mis en place : le registre `registre` démarré, le fichier `hosts.toml` dans le nœud, et l'addon metallb avec sa plage d'adresses.

```bash
tar xzf defi-3-colis.tar.gz && cd colis-defi
kubectl apply -f 00-namespace.yaml
kubectl -n colis-defi create secret generic colis-db \
  --from-literal=POSTGRES_PASSWORD=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')
kubectl apply -f .
```

Le Colis du chapitre 24 peut continuer de tourner dans son namespace : les deux copies ne se gênent pas. Celle du défi recevra la deuxième adresse de la plage de MetalLB, `192.168.49.101`.

## Les règles

- Corrigez les manifestes, puis appliquez-les avec `kubectl apply`. Pas de `kubectl edit` ni de `kubectl patch` : la version qui marche doit être celle des fichiers.
- Ne supprimez ni une sonde, ni une limite, ni une request : réparez-les. Un déploiement qui marche parce qu'on a retiré ses garde-fous n'est pas réparé.
- Ne changez ni les images, ni le nombre de répliques, ni le namespace.
- Pour chaque erreur, notez le symptôme qui vous y a mené, la commande qui l'a révélée, et pourquoi la correction est la bonne.

## La grille de vérification

Le défi est réussi quand toutes ces vérifications passent :

| Vérification | Commande | Résultat attendu |
|---|---|---|
| 1 | `kubectl -n colis-defi get pods` | tous les Pods `1/1 Running`, sauf `purge` en `Completed` |
| 2 | `curl -s http://192.168.49.101/api/pret` | `"pret":true` |
| 3 | créer un colis, attendre cinq secondes, le relire (commandes ci-dessous) | le statut passe à `estimé`, avec une date |
| 4 | relancer la purge (supprimer le Pod, le réappliquer), puis `kubectl -n colis-defi logs purge` | le message de la purge, sans erreur |
| 5 | `kubectl -n colis-defi get pods -o custom-columns=NOM:.metadata.name,REDEMARRAGES:.status.containerStatuses[0].restartCount`, deux fois à deux minutes d'écart | aucun compteur n'a bougé |
| 6 | `kubectl -n colis-defi get endpointslices` | le port `8000` pour `api`, le port `80` pour `web`, deux adresses chacun |
| 7 | vos notes | cinq erreurs expliquées |

Pour la vérification 3 :

```bash
curl -s -X POST http://192.168.49.101/api/colis -H 'Content-Type: application/json' \
  -d '{"destinataire":"Grace Hopper","depart":"Lyon","arrivee":"Lille","poids_kg":1.2}'
sleep 5
curl -s http://192.168.49.101/api/colis/1
```

## Indices

Ouvrez-les un par un, seulement si vous êtes bloqué.

<details>
<summary>Indice 1 : par où commencer ?</summary>

Commencez par `kubectl -n colis-defi get pods`, et traitez d'abord ce dont les autres dépendent. Une API qui ne peut pas joindre sa base ne sera jamais prête ; inutile de la déboguer tant que la base ne tourne pas. Pour un Pod qui ne démarre pas, `kubectl describe pod` et ses événements ; pour un Pod qui redémarre, `kubectl logs --previous` et la section `Last State` de `describe`.

</details>

<details>
<summary>Indice 2 : un Pod en attente</summary>

Un Pod `Pending` n'a pas trouvé de nœud. L'événement `FailedScheduling` dit pourquoi. Relisez, au chapitre 23, comment s'écrivent les quantités de processeur.

</details>

<details>
<summary>Indice 3 : le même mot de passe, deux résultats</summary>

L'API et le worker lisent le même Secret, et pourtant l'un des deux se fait refuser par PostgreSQL. Comparez leurs listes de variables d'environnement, dans l'ordre (chapitre 24, section sur la configuration).

</details>

<details>
<summary>Indice 4 : prêt, mais injoignable</summary>

Quand un Pod n'est pas prêt, `kubectl describe pod` montre la sonde qui échoue et l'adresse qu'elle interroge. Quand tous les Pods sont prêts et que le Service ne répond toujours pas, relisez la méthode en trois questions de l'encadré « Un Service qui ne répond pas » du chapitre 20. La troisième question est la bonne.

</details>

## Corrigé

Ne l'ouvrez qu'après avoir essayé. Il suit l'ordre d'un diagnostic réel, de la dépendance la plus basse jusqu'au navigateur. Toutes les sorties viennent du cluster du cours. Les manifestes corrigés sont dans le dépôt du cours, sous `kits/defi-3/corrige`.

<details>
<summary>Voir le corrigé commenté</summary>

### L'état des lieux

Une minute et demie après le déploiement :

```bash
kubectl -n colis-defi get pods
```

```sortie
NAME                        READY   STATUS             RESTARTS      AGE
api-7778857c89-7bdl8        0/1     CrashLoopBackOff   3 (41s ago)   90s
api-7778857c89-wcrds        0/1     CrashLoopBackOff   3 (47s ago)   90s
postgres-8566cf9d45-l2l7n   0/1     Pending            0             90s
purge                       0/1     Error              0             90s
redis-578785659c-wl847      1/1     Running            0             90s
web-84d6645754-8vj4v        0/1     Running            0             90s
web-84d6645754-xp2dd        0/1     Running            0             90s
worker-74b9987cc6-r8mvm     0/1     OOMKilled          4 (50s ago)   90s
```

Seul Redis fonctionne. Et le site ne répond pas du tout :

```bash
curl -sS -m 5 http://192.168.49.101/ -o /dev/null
```

```sortie
curl: (28) Connection timed out after 5002 milliseconds
```

Selon les essais, `curl` échoue par un délai dépassé ou par une connexion impossible, mais jamais par une erreur HTTP : aucune requête n'arrive jusqu'à nginx. PostgreSQL est la dépendance de tout le reste : on commence par lui.

### Erreur 1 : une request de processeur de 100 cœurs

```bash
kubectl -n colis-defi describe pod -l app.kubernetes.io/name=postgres | sed -n '/^Events:/,$p'
kubectl -n colis-defi get pod -l app.kubernetes.io/name=postgres -o jsonpath='{.items[0].spec.containers[0].resources}'; echo
kubectl get node minikube -o jsonpath='{.status.allocatable.cpu}'; echo
```

```sortie
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  95s   default-scheduler  0/1 nodes are available: 1 Insufficient cpu. preemption: 0/1 nodes are available: 1 Preemption is not helpful for scheduling.
  Warning  FailedScheduling  91s   default-scheduler  0/1 nodes are available: 1 Insufficient cpu. preemption: 0/1 nodes are available: 1 Preemption is not helpful for scheduling.
{"limits":{"memory":"256Mi"},"requests":{"cpu":"100","memory":"128Mi"}}
22
```

Le Pod demande `cpu: "100"`, c'est-à-dire 100 cœurs entiers, et le nœud en offre 22. Le scheduler ne trouve aucun nœud qui convienne, et le Pod reste `Pending` indéfiniment ; la préemption n'y peut rien, puisque même un nœud vide ne suffirait pas. Il manque le suffixe `m` : la valeur voulue était `100m`, un dixième de cœur (chapitre 23). C'est une erreur que la validation ne peut pas attraper, car 100 cœurs est une demande valide, simplement irréalisable ici.

```yaml title="20-postgres.yaml"
          requests:
            cpu: 100m
```

```bash
kubectl apply -f 20-postgres.yaml
kubectl -n colis-defi rollout status deployment/postgres
```

```sortie
deployment.apps/postgres configured
service/postgres unchanged
deployment "postgres" successfully rolled out
```

La stratégie `Recreate` a supprimé le Pod en attente avant d'en créer un nouveau. PostgreSQL tourne. Mais l'API continue de redémarrer.

### Erreur 2 : une variable composée avant l'autre

```bash
kubectl -n colis-defi logs deploy/api --previous --tail=1
kubectl -n colis-defi logs deploy/postgres | grep -m1 FATAL
```

```sortie
psycopg.OperationalError: connection failed: connection to server at "10.96.209.208", port 5432 failed: FATAL:  password authentication failed for user "colis"
2026-09-26 07:28:33.405 UTC [92] FATAL:  password authentication failed for user "colis"
```

L'API joint maintenant PostgreSQL, qui refuse son mot de passe. Le Secret n'est pas en cause : le worker le lit aussi, et PostgreSQL a été initialisé avec. La différence est dans l'API. L'ordre de ses variables :

```bash
kubectl -n colis-defi get pod -l app.kubernetes.io/name=api -o jsonpath='{range .items[0].spec.containers[0].env[*]}{.name}{"\n"}{end}'
```

```sortie
COLIS_DB
POSTGRES_PASSWORD
```

`COLIS_DB` contient `$(POSTGRES_PASSWORD)`, mais elle est déclarée avant cette variable. Kubernetes ne remplace une référence `$(NOM)` que si `NOM` est défini plus haut dans la liste ; sinon, il laisse le texte tel quel, sans erreur ni avertissement. L'API a donc tenté de se connecter avec le mot de passe littéral `$(POSTGRES_PASSWORD)`. On remet les deux variables dans l'ordre :

```yaml title="30-api.yaml"
        env:
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: colis-db
              key: POSTGRES_PASSWORD
        - name: COLIS_DB
          value: postgresql://colis:$(POSTGRES_PASSWORD)@postgres:5432/colis
```

```bash
kubectl apply -f 30-api.yaml
kubectl -n colis-defi rollout status deployment/api
kubectl -n colis-defi get pods -l app.kubernetes.io/name=api
```

```sortie
deployment.apps/api configured
service/api unchanged
deployment "api" successfully rolled out
NAME                   READY   STATUS        RESTARTS      AGE
api-747ccbc945-p54q6   1/1     Running       0             4s
api-747ccbc945-vb587   1/1     Running       0             9s
api-7778857c89-7bdl8   0/1     Terminating   4 (54s ago)   2m37s
```

Les deux nouveaux Pods de l'API sont prêts, et le dernier des anciens s'en va. Leur readiness, sur `/pret`, confirme qu'ils joignent PostgreSQL et Redis.

### Erreur 3 : un worker à l'étroit

```bash
kubectl -n colis-defi describe pod -l app.kubernetes.io/name=worker | grep -A4 'Last State'
kubectl -n colis-defi get pod -l app.kubernetes.io/name=worker -o jsonpath='{.items[0].spec.containers[0].resources}'; echo
```

```sortie
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Sat, 26 Sep 2026 09:27:29 +0200
      Finished:     Sat, 26 Sep 2026 09:27:30 +0200
{"limits":{"memory":"24Mi"},"requests":{"cpu":"50m","memory":"16Mi"}}
```

Le conteneur a vécu une seconde : le noyau l'a tué (code 137, c'est-à-dire 128 + 9, SIGKILL) parce qu'il dépassait sa limite de 24 Mio (chapitre 23). Il n'a même pas eu le temps d'écrire une ligne de journal. Python, avec les bibliothèques de PostgreSQL et de Redis, a besoin de davantage. Combien ? Les valeurs du chapitre 24 (request de 96 Mio, limite de 192 Mio) viennent d'une mesure ; une fois le worker réparé, `kubectl top` le confirme :

```yaml title="31-worker.yaml"
          requests:
            cpu: 50m
            memory: 96Mi
          limits:
            memory: 192Mi
```

```bash
kubectl apply -f 31-worker.yaml
kubectl -n colis-defi rollout status deployment/worker
kubectl top pod -n colis-defi -l app.kubernetes.io/name=worker
```

```sortie
deployment.apps/worker configured
deployment "worker" successfully rolled out
NAME                     CPU(cores)   MEMORY(bytes)   
worker-5d8987c87-tszk5   34m          37Mi            
```

Au repos, 37 Mio : plus que la limite donnée par le collègue, avant même le premier colis. Économiser sur la mémoire se fait à partir d'une mesure, pas d'une intuition.

### Erreur 4 : une sonde qui frappe à la mauvaise porte

L'API et le worker tournent, mais le site ne répond toujours pas. Les Pods `web` sont `Running` et jamais prêts :

```bash
kubectl -n colis-defi get endpointslices -l kubernetes.io/service-name=web \
  -o jsonpath='{range .items[0].endpoints[*]}{.addresses[0]} ready={.conditions.ready}{"\n"}{end}'
kubectl -n colis-defi get events --field-selector reason=Unhealthy | grep web | tail -1
kubectl -n colis-defi get pods -l app.kubernetes.io/name=web -o jsonpath='{.items[0].spec.containers[0].ports}'; echo
```

```sortie
10.244.0.136 ready=false
10.244.0.137 ready=false
117s        Warning   Unhealthy   pod/web-84d6645754-xp2dd        Readiness probe failed: Get "http://10.244.0.136:8080/": dial tcp 10.244.0.136:8080: connect: connection refused
[{"containerPort":80,"name":"http","protocol":"TCP"}]
```

L'EndpointSlice connaît les deux Pods, mais les marque non prêts, et un Service n'envoie rien à un Pod non prêt : d'où l'absence totale de réponse, sans même une erreur HTTP. La sonde interroge le port 8080, où nginx n'écoute pas ; il écoute sur le port 80, que le conteneur déclare sous le nom `http`. En désignant le port par son nom, la sonde suit le conteneur si le port change un jour (chapitre 22) :

```yaml title="40-web.yaml"
        readinessProbe:
          httpGet:
            path: /
            port: http
```

```bash
kubectl apply -f 40-web.yaml
kubectl -n colis-defi rollout status deployment/web
curl -s -o /dev/null -w 'site : %{http_code}\n' http://192.168.49.101/
curl -s -w '\napi : %{http_code}\n' http://192.168.49.101/api/pret
```

```sortie
deployment.apps/web configured
service/web unchanged
deployment "web" successfully rolled out
site : 200
<html>
<head><title>502 Bad Gateway</title></head>
<body>
<center><h1>502 Bad Gateway</h1></center>
<hr><center>nginx/1.30.5</center>
</body>
</html>

api : 502
```

Le site répond, mais pas l'API derrière lui. La réponse `502` vient de nginx, qui n'arrive pas à joindre le Service `api`.

### Erreur 5 : un Service qui vise le mauvais port

Les Pods de l'API sont prêts depuis l'erreur 2. Appliquons les trois questions du chapitre 20. Le nom `api` se résout, sinon nginx aurait refusé de démarrer. L'EndpointSlice contient bien deux adresses. Reste le port :

```bash
kubectl -n colis-defi get endpointslices -l kubernetes.io/service-name=api
kubectl -n colis-defi get service api -o jsonpath='{.spec.ports}'; echo
```

```sortie
NAME        ADDRESSTYPE   PORTS   ENDPOINTS                   AGE
api-dgsh6   IPv4          8080    10.244.0.140,10.244.0.141   3m52s
[{"name":"http","port":8000,"protocol":"TCP","targetPort":8080}]
```

Le Service reçoit sur le port 8000 et relaie vers le port 8080 des Pods, où rien n'écoute : l'API écoute sur 8000. Les connexions sont refusées, et nginx répond 502. Comme pour la sonde, le plus sûr est de désigner le port par son nom :

```yaml title="30-api.yaml"
  ports:
  - name: http
    port: 8000
    targetPort: http
```

```bash
kubectl apply -f 30-api.yaml
kubectl -n colis-defi get endpointslices -l kubernetes.io/service-name=api
curl -s http://192.168.49.101/api/pret; echo
```

```sortie
deployment.apps/api unchanged
service/api configured
NAME        ADDRESSTYPE   PORTS   ENDPOINTS                   AGE
api-dgsh6   IPv4          8000    10.244.0.140,10.244.0.141   3m56s
```

```sortie
{"stockage":"postgres","file":"redis","pret":true}
```

Le contrôleur des EndpointSlices a mis à jour le port en quelques secondes, sans toucher aux Pods.

### La purge et la grille

La purge a échoué au démarrage, quand PostgreSQL n'existait pas encore. Son `restartPolicy: Never` la laisse en erreur ; on la relance :

```bash
kubectl -n colis-defi delete pod purge
kubectl apply -f 50-purge.yaml
kubectl -n colis-defi wait --for=jsonpath='{.status.phase}'=Succeeded pod/purge --timeout=90s
kubectl -n colis-defi logs purge
```

```sortie
pod "purge" deleted from colis-defi namespace
pod/purge created
pod/purge condition met
purge : 0 colis livrés depuis plus de 30 jours supprimés
```

La grille, ensuite :

```sortie
NAME                        READY   STATUS      RESTARTS   AGE
api-747ccbc945-p54q6        1/1     Running     0          87s
api-747ccbc945-vb587        1/1     Running     0          92s
postgres-7847c54c4d-vwnt5   1/1     Running     0          2m24s
purge                       0/1     Completed   0          4s
redis-578785659c-wl847      1/1     Running     0          4m
web-599d986bdf-66mw8        1/1     Running     0          11s
web-599d986bdf-8t947        1/1     Running     0          9s
worker-5d8987c87-tszk5      1/1     Running     0          82s
{"stockage":"postgres","file":"redis","pret":true}
{"id":1,"destinataire":"Grace Hopper","depart":"Lyon","arrivee":"Lille","poids_kg":1.2,"statut":"estimé","cree_le":"2026-09-26T07:30:50.793104Z","livraison_estimee":"2026-09-29","livre_le":null}
```

Deux minutes plus tard, aucun compteur de redémarrages n'a bougé : tous sont à 0. Les manifestes corrigés sont identiques à ceux du chapitre 24, au namespace près.

### Ce qu'il faut en retenir

Les cinq erreurs ont un point commun : aucune n'était visible dans les fichiers pour un œil pressé, et `kubectl apply` les a toutes acceptées. Kubernetes valide la forme d'un objet, pas son sens. Ce qui les a révélées, ce sont les états et les messages que le cluster produit : `Pending` et `FailedScheduling`, `CrashLoopBackOff` et les journaux du conteneur précédent, `OOMKilled` et son code 137, `Running` sans être prêt et les événements `Unhealthy`, et enfin l'EndpointSlice et son port. Remonter la chaîne des dépendances, de la base vers le navigateur, a évité de chercher une panne de l'API alors qu'il manquait sa base.

Quatre des cinq erreurs auraient été évitées par des habitudes simples : désigner les ports par leur nom, dimensionner la mémoire à partir d'une mesure, et relire l'ordre des variables composées. La partie VII reviendra sur le diagnostic, avec des outils plus puissants comme `kubectl debug` (chapitre 48).

</details>

## Pour aller plus loin

- Une sixième erreur, plus sournoise : dans `10-config.yaml`, remplacez `redis://redis:6379/0` par `redis://redis:6380/0`. Prédisez le symptôme avant d'appliquer, puis vérifiez. Faut-il redémarrer quelque chose pour qu'une correction de la ConfigMap soit prise en compte (chapitre 21) ?
- Écrivez un script `verifier.sh` qui exécute la grille et affiche `OK` ou `ÉCHEC` pour chaque ligne. Un tel script est la première brique d'un test de fumée, qu'on lance après chaque déploiement.

## Et maintenant

Vous savez déployer une application complète sur Kubernetes, la mettre à jour sans coupure, et chercher pourquoi elle ne marche pas. Deux faiblesses sont restées sans réponse : les données de PostgreSQL disparaissent avec son Pod, et la purge se lance à la main. La partie IV s'en occupe, avec les volumes persistants, les StatefulSets, les Jobs et les CronJobs, puis l'Ingress pour exposer Colis sous un nom, et Helm et Kustomize pour empaqueter ses manifestes.

Pour faire le ménage du défi, en gardant le Colis du chapitre 24 :

```bash
kubectl delete namespace colis-defi
```
