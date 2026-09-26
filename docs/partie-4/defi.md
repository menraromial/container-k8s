---
title: Défi IV, Colis en production
sidebar_label: Défi IV
description: "Faire du chart Helm de Colis un déploiement de production : HTTPS sur la passerelle partagée, données persistantes, API qui suit la charge, worker qui dort quand la file est vide, budgets de perturbation pour les maintenances, le tout vérifié par un script."
partie: 4
plaque: Défi IV
---

L'équipe a validé Colis en recette. Il faut maintenant l'installer en production, dans le namespace `colis-prod`, sous le nom `colis-prod.local`. Les exigences ont été écrites par des gens qui ont déjà vécu des nuits difficiles : la base ne doit rien perdre si son Pod disparaît, l'API doit encaisser le lundi matin sans qu'on y touche, le worker ne doit rien coûter la nuit, et les maintenances des nœuds ne doivent pas couper le site. Tout doit passer par HTTPS. Et l'installation doit se faire avec le chart Helm de Colis, pour qu'on puisse la reproduire, la mettre à jour et revenir en arrière.

Tout ce qu'il faut a été vu dans cette partie : les volumes et le StatefulSet (chapitres 25 et 26), la Gateway API et cert-manager (chapitre 28), Helm (chapitre 29), le HPA et KEDA (chapitre 31), le PodDisruptionBudget (chapitre 33). Le défi consiste à les assembler dans un seul chart, sans rien retoucher à la main une fois installé.

## Le point de départ

Partez du chart `colis` 0.1.1 du chapitre 29 ([l'archive helm](pathname:///kits/helm.tar.gz)), et du cluster tel que les chapitres 28 à 31 l'ont laissé : la passerelle `principale` du namespace `passerelle` sur `192.168.49.102`, cert-manager et son émetteur `colis-ca`, metrics-server et KEDA. Si vous avez mis en sommeil les autres copies de Colis au chapitre 31, laissez-les dormir : le nœud de 4 Gio n'a pas la place pour tout.

La [grille de vérification](pathname:///kits/defi-4.tar.gz) est un script, `verifier.sh`, qui fait les vérifications une par une et affiche `OK` ou `ÉCHEC`. Il prend en argument le certificat de l'autorité du cours, extrait au chapitre 28 :

```bash
kubectl -n cert-manager get secret colis-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
tar xzf defi-4.tar.gz
./defi-4/verifier.sh ca.crt
```

## Le cahier des charges

1. Colis est installé par Helm, sous le nom de release `colis`, dans le namespace `colis-prod`, avec une version du chart au moins égale à **0.2.0**.
2. Le site et l'API répondent en **HTTPS** sur `https://colis-prod.local/`, par la passerelle `principale`, avec un certificat émis par l'autorité `colis-ca` ; `http://colis-prod.local/` redirige vers HTTPS (301).
3. Un colis enregistré survit à la suppression du Pod de PostgreSQL, sans qu'il faille redémarrer l'API.
4. Le nombre de répliques de l'API est géré par un **HPA**, de 2 à 6, sur le processeur. Le Deployment de l'API rendu par le chart n'a **pas** de champ `replicas`.
5. Le worker est géré par **KEDA** : aucune réplique quand la file est vide ; une rafale de 30 colis réveille des workers, et la file est vidée en moins d'une minute.
6. L'API et le site ont chacun un **PodDisruptionBudget** qui laisse passer une maintenance de nœud, une réplique à la fois.
7. `helm test colis` réussit.

Et deux règles. Toutes les modifications de Colis passent par le chart et un fichier de valeurs, `valeurs-prod.yaml` : pas de `kubectl patch`, `edit` ni `scale` sur les objets de la release. En revanche, vous êtes aussi l'équipe plateforme : vous pouvez modifier la Gateway `principale`.

## La grille

Le script vérifie les sept exigences, dans l'ordre. La vérification 3 supprime réellement `postgres-0` ; la vérification 5 envoie 30 colis. Voici ce qu'il affiche quand tout est en ordre :

```sortie
OK      1. release colis déployée par Helm, chart 0.2.0 ou plus
OK      2a. https://colis-prod.local/api/pret répond en HTTPS, certificat de l'autorité du cours
OK      2b. http://colis-prod.local/ redirige (301)
OK      3. un colis survit à la suppression de postgres-0, sans redémarrer l'API
OK      4a. HPA sur le Deployment api, de 2 à 6 répliques
OK      4b. le Deployment api rendu par le chart n'a pas de champ replicas
OK      5a. worker à 0 réplique au repos
OK      5b. une rafale de 30 colis réveille des workers et la file se vide en moins d'une minute
OK      6. PDB sur api, qui autorise au moins une perturbation
OK      6. PDB sur web, qui autorise au moins une perturbation
OK      7. helm test colis

11 vérification(s) réussie(s), 0 en échec
```

## Indices

Ouvrez-les un par un, seulement si vous êtes bloqué.

<details>
<summary>Indice 1 : un nom d'hôte de plus sur la passerelle</summary>

L'écouteur HTTPS de la passerelle, au chapitre 28, n'accepte que le nom `colis.local`, et son certificat ne couvre que ce nom. Une route pour `colis-prod.local` attachée à cet écouteur sera refusée. Il faut un écouteur de plus, avec son propre nom d'hôte et son propre Secret de certificat ; l'annotation de la Gateway fera le reste.

</details>

<details>
<summary>Indice 2 : qui fixe le nombre de répliques ?</summary>

Relisez l'encadré du chapitre 31 sur le HPA et le champ `replicas`. Dans un modèle Helm, une condition `{{- if ... }}` autour d'une ligne suffit à la faire disparaître du rendu. `helm template` avec vos valeurs, suivi d'un `grep replicas`, vous dira si c'est le cas.

</details>

<details>
<summary>Indice 3 : où est Redis, vu de KEDA ?</summary>

L'opérateur KEDA tourne dans le namespace `keda`, pas dans celui de Colis. Le nom court `redis` ne lui dit rien : il lui faut le nom complet du Service. `.Release.Namespace` le connaît.

</details>

<details>
<summary>Indice 4 : ce qui existe déjà</summary>

Les exigences 3 et 7 sont déjà satisfaites par le chart 0.1.1, si vous l'installez correctement : PostgreSQL est un StatefulSet sur un volume persistant, Colis 2.1 rouvre ses connexions (chapitre 26), et le chart contient un test. Concentrez-vous sur le reste.

</details>

## Corrigé

Ne l'ouvrez qu'après avoir essayé. Il a été vérifié avec le script ci-dessus sur le cluster du cours. Le chart corrigé est dans le dépôt du cours, sous `kits/defi-4/corrige`.

<details>
<summary>Voir le corrigé commenté</summary>

### La passerelle

Un troisième écouteur, pour `colis-prod.local`. cert-manager voit l'écouteur et fabrique le certificat, grâce à l'annotation déjà présente sur la Gateway :

```yaml title="passerelle-tls.yaml (ajout)"
  - name: https-prod
    protocol: HTTPS
    port: 443
    hostname: colis-prod.local
    tls:
      mode: Terminate
      certificateRefs:
      - name: colis-prod-tls
    allowedRoutes:
      namespaces:
        from: Selector
        selector:
          matchLabels:
            passerelle: principale
```

```bash
kubectl apply -f passerelle-tls.yaml
kubectl -n passerelle wait --for=condition=Ready certificate/colis-prod-tls --timeout=60s
kubectl -n passerelle get certificate
```

```sortie
gateway.gateway.networking.k8s.io/principale configured
certificate.cert-manager.io/colis-prod-tls condition met
NAME             READY   SECRET           AGE
colis-prod-tls   True    colis-prod-tls   0s
colis-tls        True    colis-tls        3h6m
```

### Le chart 0.2.0

Quatre changements, tous optionnels par des valeurs, pour que le chart reste utilisable en recette avec ses réglages simples. D'abord, de nouvelles valeurs :

```yaml title="colis/values.yaml (ajouts)"
api:
  repliques: 2             # ignoré si l'autoscaling est actif
  autoscaling:
    actif: false
    min: 2
    max: 6
    cibleCpu: 50           # % de la request de processeur

worker:
  repliques: 1             # ignoré si KEDA est actif
  keda:
    actif: false
    max: 5
    colisParWorker: 5

pdb:
  actif: false             # PodDisruptionBudget pour l'API et le site (chapitre 33)

passerelle:
  https: false             # écouteur HTTPS, et redirection de HTTP vers HTTPS
  ecouteurHttps: https
```

Ensuite, le champ `replicas` de l'API et du worker ne s'écrit que si aucun autoscaler ne s'en charge :

```yaml title="colis/templates/api.yaml (extrait)"
spec:
  {{- if not .Values.api.autoscaling.actif }}
  replicas: {{ .Values.api.repliques }}
  {{- end }}
```

Un nouveau modèle crée le HPA de l'API et le ScaledObject du worker, chacun sous sa condition :

```yaml title="colis/templates/autoscaling.yaml (extrait)"
{{- if .Values.worker.keda.actif }}
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: worker
spec:
  scaleTargetRef:
    name: worker
  minReplicaCount: 0
  maxReplicaCount: {{ .Values.worker.keda.max }}
  pollingInterval: 5
  cooldownPeriod: 30
  triggers:
  - type: redis
    metadata:
      address: redis.{{ .Release.Namespace }}.svc.cluster.local:6379
      listName: colis:a-estimer
      listLength: {{ .Values.worker.keda.colisParWorker | quote }}
{{- end }}
```

Un modèle crée les deux PDB avec une boucle `range`, en tolérant l'éviction des Pods malades (chapitre 33). Dans la boucle, `.` désigne l'élément courant ; `$` redonne accès au contexte général du chart :

```yaml title="colis/templates/pdb.yaml"
{{- if .Values.pdb.actif }}
{{- range $composant := list "api" "web" }}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ $composant }}
  labels:
    {{- include "colis.etiquettes" $ | nindent 4 }}
spec:
  maxUnavailable: 1
  unhealthyPodEvictionPolicy: AlwaysAllow
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ $composant }}
      app.kubernetes.io/instance: {{ $.Release.Name }}
{{- end }}
{{- end }}
```

`maxUnavailable: 1` plutôt que `minAvailable` : le nombre de répliques de l'API varie de 2 à 6, et un minimum fixe bloquerait les maintenances quand le HPA est au plus bas (chapitre 33, exercice 1). Enfin, la route s'attache à l'écouteur HTTPS quand `passerelle.https` est vrai, et une seconde route redirige HTTP vers HTTPS, comme au chapitre 28.

### Les valeurs de production, et l'installation

```yaml title="valeurs-prod.yaml"
api:
  autoscaling:
    actif: true
    min: 2
    max: 6
worker:
  keda:
    actif: true
    max: 5
pdb:
  actif: true
passerelle:
  activee: true
  https: true
  ecouteurHttps: https-prod
  hote: colis-prod.local
```

```bash
kubectl create namespace colis-prod
kubectl label namespace colis-prod passerelle=principale
helm install colis ./colis -n colis-prod -f valeurs-prod.yaml --wait
kubectl -n colis-prod get pods,hpa,scaledobject,pdb
```

```sortie
namespace/colis-prod created
namespace/colis-prod labeled
STATUS: deployed
REVISION: 1
NAME                        READY   STATUS    RESTARTS      AGE
pod/api-7474bf78d4-jsjxj    1/1     Running   2 (14s ago)   25s
pod/api-7474bf78d4-xwchh    1/1     Running   1 (17s ago)   24s
pod/postgres-0              1/1     Running   0             25s
pod/redis-99597568d-jt7gc   1/1     Running   0             25s
pod/web-9489776bd-h8fnr     1/1     Running   0             25s
pod/web-9489776bd-zjqsb     1/1     Running   0             25s

NAME                                                  REFERENCE           TARGETS              MINPODS   MAXPODS   REPLICAS   AGE
horizontalpodautoscaler.autoscaling/api               Deployment/api      cpu: <unknown>/50%   2         6         2          25s
horizontalpodautoscaler.autoscaling/keda-hpa-worker   Deployment/worker   <unknown>/5 (avg)    1         5         0          19s

NAME                          SCALETARGETKIND      SCALETARGETNAME   MIN   MAX   READY   ACTIVE   FALLBACK   PAUSED   TRIGGERS   AUTHENTICATIONS   AGE
scaledobject.keda.sh/worker   apps/v1.Deployment   worker            0     5     True    False    False      False    redis                        25s

NAME                             MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
poddisruptionbudget.policy/api   N/A             1                 1                     25s
poddisruptionbudget.policy/web   N/A             1                 1                     25s
```

Installé en 25 secondes : deux API sous la garde du HPA, pas de worker (la file est vide), deux budgets qui laissent partir une réplique à la fois. Les redémarrages de l'API au démarrage sont ceux du chapitre 24 : elle démarre avant PostgreSQL. Si vous regardez dans les secondes qui suivent l'installation, vous verrez peut-être un worker : le Deployment rendu sans champ `replicas` est créé avec une réplique, et KEDA ne l'endort qu'après son `cooldownPeriod` de 30 secondes. Le script de vérification donne alors les onze `OK` de la grille.

### Ce qu'il faut en retenir

Aucun objet de ce chart n'est nouveau : tout vient des chapitres de la partie. Le travail du défi est dans les **interactions**. Le HPA et KEDA ne marchent bien que si le chart renonce au champ `replicas`. Le PDB doit être exprimé en absents plutôt qu'en présents, parce que le nombre de répliques varie. KEDA, qui tourne dans un autre namespace, a besoin du nom complet de Redis. Le nom d'hôte de production demande un écouteur et un certificat côté plateforme, et une étiquette sur le namespace côté application. Chacun de ces points, raté, ne produit pas d'erreur à l'installation : il se révèle plus tard, dans une rafale, une maintenance ou un `helm upgrade`. C'est pourquoi une grille de vérification exécutable, rejouée après chaque changement, vaut mieux qu'une relecture.

</details>

## Pour aller plus loin

- Ajoutez au chart, sous une valeur `vpa.actif`, un VPA qui ne gère que la mémoire de l'API, à côté du HPA qui gère son nombre de répliques (chapitre 31, exercice 1). Comparez ses recommandations après quelques rafales.
- Déclinez le chart en deux environnements avec Kustomize et `helmCharts` (chapitre 30) : recette sans autoscaling, production avec. Qu'est-ce qui change dans le rendu ? Que devient le test du chart ?
- Publiez le chart 0.2.0 dans le registre du cours (chapitre 29), et installez la production depuis le registre plutôt que depuis le dossier.

## Et maintenant

Colis est désormais une application complète, persistante, exposée en HTTPS, qui suit sa charge et survit aux maintenances. Vous avez utilisé une vingtaine de sortes d'objets Kubernetes, et presque autant de contrôleurs qui travaillent pour vous en coulisse : ceux des Deployments, des StatefulSets, des Jobs, des volumes, des taints, des évictions, du HPA, et ceux qu'ont ajoutés Envoy Gateway, cert-manager et KEDA. La partie V ouvre le capot : l'API server, etcd, le scheduler, le kubelet, le réseau des Pods. Vous y verrez comment ces pièces fonctionnent réellement, et pourquoi elles se comportent comme vous les avez vues se comporter ici.

Pour faire le ménage du défi, en gardant la passerelle telle que le chapitre 28 l'a laissée. Le Secret du mot de passe et le volume de la base survivent à `helm uninstall` (c'est voulu, chapitre 29) ; la suppression du namespace les emporte :

```bash
helm -n colis-prod uninstall colis
kubectl delete namespace colis-prod
kubectl apply -f passerelle-tls.yaml   # celui du chapitre 28, sans l'écouteur https-prod
kubectl -n passerelle delete secret colis-prod-tls
```

Inutile de supprimer le Certificate `colis-prod-tls` : cert-manager l'a créé pour l'écouteur, et le retire de lui-même quand l'écouteur disparaît. Il laisse en revanche le Secret, d'où la dernière commande.
