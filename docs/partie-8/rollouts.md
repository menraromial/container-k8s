---
title: Déploiements progressifs avec Argo Rollouts
sidebar_label: 58. Argo Rollouts
description: "Livrer une version par étapes : Argo Rollouts et son greffon Gateway API, un canari à 10 puis 50 % du trafic mesuré requête par requête, la promotion, une analyse Prometheus qui abandonne seule une version défaillante, puis le déploiement bleu-vert et sa bascule d'une seconde."
partie: 8
chapitre: '58'
---

import rolloutsCanari from '@site/src/figures/rollouts-canari.svg';
import rolloutsBleuVert from '@site/src/figures/rollouts-bleu-vert.svg';

Pendant une mise à jour progressive (*rolling update*), un Deployment ne vérifie qu'une chose sur chaque nouveau Pod : qu'il soit prêt. Le serveur podinfo lancé avec l'option `--random-error` répond par une erreur une fois sur trois[^podinfo], et sa sonde `/readyz` répond 200 sans difficulté. Un Deployment installerait cette version sur tous ses Pods sans jamais ralentir, et les utilisateurs découvriraient les erreurs avant l'équipe.

Le **déploiement progressif** (*progressive delivery*) corrige ce point en exposant la nouvelle version à une petite part du trafic d'abord, en regardant ce qu'elle fait de ce trafic, puis en élargissant ou en revenant en arrière. Deux formes reviennent. Le **canari** envoie 10 %, puis 50 %, puis 100 % des requêtes à la nouvelle version. Le **bleu-vert** installe la nouvelle version à côté de l'ancienne, la laisse tester sur une adresse à part, puis fait basculer tout le trafic d'un coup.

Kubernetes ne fait ni l'un ni l'autre. **Argo Rollouts**, du projet Argo (le même qu'Argo CD), ajoute pour cela une ressource `Rollout` : le même gabarit de Pod qu'un Deployment, et une stratégie décrite étape par étape[^concepts]. Ce chapitre l'utilise avec une petite application, `vitrine` (podinfo, déjà vue au chapitre 57), publiée sur la passerelle du chapitre 28. Les fichiers sont dans [l'archive rollouts](pathname:///kits/rollouts.tar.gz).

## Installer le contrôleur

Le projet publie un manifeste par version. Appliqué comme les autres :

```sortie
# kubectl create namespace argo-rollouts
namespace/argo-rollouts created
# kubectl apply -n argo-rollouts -f install.yaml
deployment.apps/argo-rollouts created
Error from server (Invalid): CustomResourceDefinition.apiextensions.k8s.io "analysisruns.argoproj.io" is invalid: metadata.annotations: Too long: may not be more than 262144 bytes
Error from server (Invalid): CustomResourceDefinition.apiextensions.k8s.io "rollouts.argoproj.io" is invalid: metadata.annotations: Too long: may not be more than 262144 bytes
```

:::panne[metadata.annotations: Too long: may not be more than 262144 bytes]

`kubectl apply` (le mode « côté client ») range une copie complète de chaque objet dans l'annotation `kubectl.kubernetes.io/last-applied-configuration`, pour calculer la différence au prochain `apply`. L'API server limite la taille totale des annotations d'un objet à 256 Kio (262 144 octets)[^annotations]. Les définitions des types `Rollout` et `AnalysisRun` portent un schéma OpenAPI complet, celui d'un gabarit de Pod compris, et leur copie dépasse la limite. Le Deployment, lui, est passé : l'installation est à moitié faite. La documentation d'installation donne la solution, `--server-side`[^installation]. L'application côté serveur ne range pas de copie dans une annotation : elle note dans `managedFields` quels champs appartiennent à quel gestionnaire.

:::

```sortie
# kubectl apply -n argo-rollouts --server-side -f install.yaml
objets appliqués : 15
# kubectl get crd | grep argoproj (CRD d'Argo Rollouts)
analysisruns.argoproj.io
analysistemplates.argoproj.io
clusteranalysistemplates.argoproj.io
experiments.argoproj.io
rollouts.argoproj.io
# kubectl argo rollouts version --short
kubectl-argo-rollouts: v1.10.0+d90700a
```

Cinq CRD. `Rollout` remplace le Deployment ; `AnalysisTemplate` décrit une analyse et `AnalysisRun` en est une exécution ; `ClusterAnalysisTemplate` est la version valable pour tous les namespaces ; `Experiment` lance des versions côte à côte pour les comparer, et ne sert pas ici. La dernière ligne vient de `kubectl-argo-rollouts`, une extension de kubectl publiée avec chaque version, à poser dans le `PATH` ; c'est elle qui fournit les commandes `kubectl argo rollouts`.

## Le greffon Gateway API

Pour envoyer 10 % des requêtes à la nouvelle version, il faut un composant qui sache répartir le trafic : un service mesh, un contrôleur d'Ingress, ou une passerelle. Argo Rollouts en connaît plusieurs directement ; pour l'API Gateway, il passe par un greffon, un programme séparé que le contrôleur télécharge à son démarrage[^greffons]. Le greffon reçoit les poids voulus et les écrit dans une HTTPRoute[^gatewayapi].

Le contrôleur télécharge le greffon à chaque démarrage, et ne démarre pas tant que le téléchargement n'a pas abouti[^greffons]. Le binaire pèse 78 Mo. Lors d'un premier essai, depuis la page des versions de GitHub, le téléchargement a pris 86 secondes, et la sonde de vivacité du contrôleur l'a redémarré avant la fin, puis encore. Le kit copie donc le binaire dans une version (*release*) du serveur Gitea installé au chapitre 57, dans le cluster, et donne au contrôleur son empreinte SHA-256 :

```yaml title="greffon-gateway.yaml (extrait)"
apiVersion: v1
kind: ConfigMap
metadata:
  name: argo-rollouts-config
  namespace: argo-rollouts
data:
  trafficRouterPlugins: |-
    - name: "argoproj-labs/gatewayAPI"
      # copie du binaire de la version 0.17.0, servie par le Gitea du cluster (chapitre 57)
      location: "http://gitea.git.svc.cluster.local:3000/cours/outils/releases/download/gatewayapi-v0.17.0/gatewayapi-plugin-linux-amd64"
      sha256: "1904ca787d33107c140521899d61fff030ee75d99908bd175fca5a4647759061"
```

Le même fichier donne au compte de service du contrôleur le droit de lire et de modifier les HTTPRoutes, que le manifeste d'installation ne prévoit pas.

```sortie
# taille et empreinte du binaire téléchargé
77762829 gatewayapi-plugin-linux-amd64
1904ca787d33107c140521899d61fff030ee75d99908bd175fca5a4647759061  gatewayapi-plugin-linux-amd64
# la version créée dans le dépôt cours/outils de Gitea, avec le binaire en pièce jointe
{"tag_name":"gatewayapi-v0.17.0","assets":[{"name":"gatewayapi-plugin-linux-amd64","size":77762829}]}
# kubectl apply -f greffon-gateway.yaml ; kubectl -n argo-rollouts rollout restart deployment/argo-rollouts
configmap/argo-rollouts-config configured
clusterrole.rbac.authorization.k8s.io/argo-rollouts-gatewayapi created
clusterrolebinding.rbac.authorization.k8s.io/argo-rollouts-gatewayapi created
# kubectl -n argo-rollouts logs deploy/argo-rollouts | grep -i download
Downloading plugin argoproj-labs/gatewayAPI from: http://gitea.git.svc.cluster.local:3000/cours/outils/releases/download/gatewayapi-v0.17.0/gatewayapi-plugin-linux-amd64
Download complete, it took 1.477589005s
# kubectl -n argo-rollouts get pods
NAME                             READY   STATUS    RESTARTS   AGE
argo-rollouts-675d55fc7f-grth2   1/1     Running   0          9s
```

Une seconde et demie de téléchargement. L'empreinte n'est pas facultative en pratique : sans elle, le contrôleur exécuterait n'importe quel binaire servi à cette adresse, avec ses droits sur tous les Pods et Services du cluster.

## Un premier Rollout

L'application a deux Services, un pour la version stable et un pour la version canari, qui sélectionnent tous les deux les Pods `app: vitrine`, et une HTTPRoute qui les met derrière la passerelle avec des poids :

```yaml title="01-services-route.yaml (extrait)"
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: vitrine
  namespace: ch58
spec:
  parentRefs:
  - {name: principale, namespace: passerelle, sectionName: http}
  hostnames: [vitrine.local]
  rules:
  - backendRefs:
    - {name: vitrine-stable, port: 80, weight: 100}
    - {name: vitrine-canari, port: 80, weight: 0}
```

Le Rollout ressemble à un Deployment jusqu'à `strategy` :

```yaml title="02-rollout.yaml (extrait)"
  strategy:
    canary:
      stableService: vitrine-stable
      canaryService: vitrine-canari
      trafficRouting:
        plugins:
          argoproj-labs/gatewayAPI:
            httpRoute: vitrine
            namespace: ch58
      steps:
      - setWeight: 10
      - pause: {duration: 30s}
      - setWeight: 50
      - pause: {}              # attente sans limite : il faut promouvoir à la main
      - setWeight: 100
```

Cinq étapes : 10 % du trafic, trente secondes d'attente, 50 %, une attente sans limite, et 100 %. Une pause sans durée attend une décision humaine. Deux petites fonctions servent dans tout le chapitre : `poids` lit les poids de la route, `mesure` envoie N requêtes à `/version` par la passerelle et compte les versions servies.

```bash
poids() { kubectl -n ch58 get httproute vitrine -o json | jq -c '[.spec.rules[0].backendRefs[] | "\(.name)=\(.weight)"]'; }
mesure() {
  for i in $(seq 1 ${1:-200}); do
    curl -s --max-time 2 --resolve vitrine.local:80:192.168.49.102 http://vitrine.local/version | jq -r '.version // "erreur"'
  done | sort | uniq -c | tr -s ' ' | tr '\n' ' '; echo
}
```

```sortie
# kubectl apply -f 01-services-route.yaml -f 02-rollout.yaml
namespace/ch58 created
service/vitrine-stable created
service/vitrine-canari created
httproute.gateway.networking.k8s.io/vitrine created
rollout.argoproj.io/vitrine created
# kubectl argo rollouts status vitrine -n ch58
Progressing - more replicas need to be updated
Progressing - updated replicas are still becoming available
Healthy
# kubectl argo rollouts get rollout vitrine -n ch58
Name:            vitrine
Namespace:       ch58
Status:          ✔ Healthy
Strategy:        Canary
  Step:          5/5
  SetWeight:     100
  ActualWeight:  100
Images:          ghcr.io/stefanprodan/podinfo:6.14.1 (stable)
Replicas:
  Desired:       4
  Current:       4
  Updated:       4
  Ready:         4
  Available:     4

NAME                                 KIND        STATUS     AGE  INFO
⟳ vitrine                            Rollout     ✔ Healthy  16s  
└──# revision:1                                                  
   └──⧉ vitrine-5cc88fcd5c           ReplicaSet  ✔ Healthy  4s   stable
      ├──□ vitrine-5cc88fcd5c-hvbd9  Pod         ✔ Running  4s   ready:1/1
      ├──□ vitrine-5cc88fcd5c-jwnms  Pod         ✔ Running  4s   ready:1/1
      ├──□ vitrine-5cc88fcd5c-mts4g  Pod         ✔ Running  4s   ready:1/1
      └──□ vitrine-5cc88fcd5c-vsgwd  Pod         ✔ Running  4s   ready:1/1
# poids
["vitrine-stable=100","vitrine-canari=0"]
200 requêtes :  200 6.14.1 
```

Le premier déploiement ne suit pas les étapes : il n'y a pas encore de version stable à protéger, et le Rollout passe directement à `Step: 5/5`. L'arbre affiché par `kubectl argo rollouts get` montre la révision 1 et son ReplicaSet, marqué `stable`. Les poids de la route sont à 100 et 0. Le contrôleur a aussi ajouté aux sélecteurs des deux Services l'étiquette `rollouts-pod-template-hash` du ReplicaSet stable : c'est ce qui permettra plus loin à `vitrine-canari` de ne viser que les nouveaux Pods.

## Le canari pas à pas

Une nouvelle version se déploie en changeant l'image, avec `kubectl argo rollouts set image` ou en modifiant le fichier :

```bash
kubectl argo rollouts set image vitrine podinfo=ghcr.io/stefanprodan/podinfo:6.15.0 -n ch58
```

```sortie
rollout "vitrine" image updated
# kubectl argo rollouts get rollout vitrine -n ch58 (début)
Name:            vitrine
Namespace:       ch58
Status:          ॥ Paused
Message:         CanaryPauseStep
Strategy:        Canary
  Step:          1/5
  SetWeight:     10
  ActualWeight:  10
Images:          ghcr.io/stefanprodan/podinfo:6.14.1 (stable)
                 ghcr.io/stefanprodan/podinfo:6.15.0 (canary)
# poids
["vitrine-stable=90","vitrine-canari=10"]
# kubectl -n ch58 get rs
RS                   VOULUS   PRETS   IMAGE
vitrine-558fb9698f   1        1       ghcr.io/stefanprodan/podinfo:6.15.0
vitrine-5cc88fcd5c   4        4       ghcr.io/stefanprodan/podinfo:6.14.1
200 requêtes :  178 6.14.1  22 6.15.0 
# kubectl argo rollouts get rollout vitrine -n ch58 (début)
Name:            vitrine
Namespace:       ch58
Status:          ॥ Paused
Message:         CanaryPauseStep
Strategy:        Canary
  Step:          3/5
  SetWeight:     50
  ActualWeight:  50
Images:          ghcr.io/stefanprodan/podinfo:6.14.1 (stable)
                 ghcr.io/stefanprodan/podinfo:6.15.0 (canary)
# poids
["vitrine-stable=50","vitrine-canari=50"]
# kubectl -n ch58 get rs
RS                   VOULUS   PRETS   IMAGE
vitrine-558fb9698f   2        2       ghcr.io/stefanprodan/podinfo:6.15.0
vitrine-5cc88fcd5c   4        4       ghcr.io/stefanprodan/podinfo:6.14.1
200 requêtes :  106 6.14.1  94 6.15.0 
# 20 s plus tard : étape, spec.paused, status.pauseConditions
étape 3, en pause :  [{"reason":"CanaryPauseStep","startTime":"2026-10-09T09:45:01Z"}]
```

À la première étape, le contrôleur a créé un ReplicaSet pour la version 6.15.0 avec un seul Pod, réglé le sélecteur de `vitrine-canari` sur ce ReplicaSet, puis écrit 90 et 10 dans la route. Sur 200 requêtes, 22 sont arrivées à la nouvelle version, 11 %. Avec un routage du trafic, le nombre de Pods canari suit le poids (10 % de 4 répliques, arrondi au-dessus : 1 Pod, puis 2 à 50 %), et le ReplicaSet stable garde ses 4 Pods pendant tout le canari[^canary]. Le cluster porte donc 6 Pods au lieu de 4 à l'étape à 50 %, et 8 à l'étape à 100 %, juste avant la bascule. C'est le prix d'un retour en arrière immédiat : la version stable n'a jamais rétréci, et l'annulation ne consiste qu'à remettre les poids à 100 et 0.

Trente secondes plus tard, la pause de l'étape 1 a expiré, le poids est passé à 50 % (94 requêtes sur 200, 47 %) et le Rollout s'est arrêté à l'étape 3, sur la pause sans durée. `status.pauseConditions` en garde la raison et l'heure.

## Promouvoir

`kubectl argo rollouts promote` lève la pause en cours et passe à l'étape suivante :

```sortie
# kubectl argo rollouts promote vitrine -n ch58
rollout 'vitrine' promoted
# kubectl argo rollouts status vitrine -n ch58
Progressing - waiting for rollout to unpause
Progressing - more replicas need to be updated
Progressing - waiting for all steps to complete
Healthy
terminé 3,635 s après la promotion
# poids
["vitrine-stable=100","vitrine-canari=0"]
# kubectl argo rollouts get rollout vitrine -n ch58 (arbre)
NAME                                 KIND        STATUS     AGE  INFO
⟳ vitrine                            Rollout     ✔ Healthy  82s  
├──# revision:2                                                  
│  └──⧉ vitrine-558fb9698f           ReplicaSet  ✔ Healthy  63s  stable
│     ├──□ vitrine-558fb9698f-5mzpw  Pod         ✔ Running  63s  ready:1/1
│     ├──□ vitrine-558fb9698f-cqr2f  Pod         ✔ Running  30s  ready:1/1
│     ├──□ vitrine-558fb9698f-lkxbk  Pod         ✔ Running  3s   ready:1/1
│     └──□ vitrine-558fb9698f-m9dfk  Pod         ✔ Running  3s   ready:1/1
└──# revision:1                                                  
   └──⧉ vitrine-5cc88fcd5c           ReplicaSet  ✔ Healthy  70s  delay:29s
      ├──□ vitrine-5cc88fcd5c-hvbd9  Pod         ✔ Running  70s  ready:1/1
      ├──□ vitrine-5cc88fcd5c-jwnms  Pod         ✔ Running  70s  ready:1/1
      ├──□ vitrine-5cc88fcd5c-mts4g  Pod         ✔ Running  70s  ready:1/1
      └──□ vitrine-5cc88fcd5c-vsgwd  Pod         ✔ Running  70s  ready:1/1
# 35 s plus tard : kubectl -n ch58 get rs
RS                   VOULUS   IMAGE
vitrine-558fb9698f   4        ghcr.io/stefanprodan/podinfo:6.15.0
vitrine-5cc88fcd5c   0        ghcr.io/stefanprodan/podinfo:6.14.1
```

Trois secondes et demie après la promotion, le Rollout est terminé : le poids est passé à 100, le nouveau ReplicaSet est monté à 4 Pods, puis le contrôleur a remis le sélecteur du Service stable sur le nouveau ReplicaSet et les poids à 100 et 0. L'ancien ReplicaSet affiche `delay:29s` : avec un routage du trafic, l'ancienne version est gardée 30 secondes (`scaleDownDelaySeconds`) après la bascule, le temps que la passerelle cesse d'y envoyer des requêtes[^spec]. Trente-cinq secondes plus tard, il est à 0.

Il existe aussi `kubectl argo rollouts promote --full`, qui saute toutes les étapes restantes, analyses comprises. C'est la commande des urgences, et elle annule l'intérêt du canari.

## Décider d'après les métriques

Jusqu'ici, c'est une personne qui regarde et décide. Argo Rollouts peut confier cette décision à une **analyse** : une requête, répétée à intervalle régulier, et une condition de succès[^analyse]. L'analyse a besoin d'une métrique qui distingue les versions. podinfo compte ses requêtes dans `http_requests_total`, avec le code de réponse ; il reste à savoir de quel ReplicaSet vient chaque série. Le PodMonitor recopie pour cela l'étiquette `rollouts-pod-template-hash` des Pods sur les séries :

```yaml title="03-moniteur.yaml"
# Prometheus relève les métriques de podinfo ; l'étiquette rollouts-pod-template-hash,
# posée par Argo Rollouts sur chaque Pod, distingue le canari du stable.
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: vitrine
  namespace: ch58
spec:
  selector:
    matchLabels: {app: vitrine}
  podTargetLabels: [rollouts-pod-template-hash]
  podMetricsEndpoints:
  - port: http
    interval: 10s
```

Le modèle d'analyse reçoit le hash en argument, et calcule la part des réponses 2xx sur la dernière minute :

```yaml title="04-analyse.yaml"
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: taux-de-succes
  namespace: ch58
spec:
  args:
  - name: hash
  metrics:
  - name: taux-de-succes
    initialDelay: 60s        # le temps que Prometheus ait deux relevés des nouveaux Pods
    interval: 20s
    count: 4
    successCondition: result[0] >= 0.95
    failureLimit: 1
    provider:
      prometheus:
        address: http://supervision-kube-prometheu-prometheus.supervision.svc:9090
        query: |
          sum(rate(http_requests_total{namespace="ch58", rollouts_pod_template_hash="{{args.hash}}", status=~"2.."}[1m]))
          /
          sum(rate(http_requests_total{namespace="ch58", rollouts_pod_template_hash="{{args.hash}}"}[1m]))
```

Quatre mesures, une toutes les 20 secondes, chacune réussie si le taux atteint 95 %, et l'analyse échoue au-delà d'une mesure ratée. Le délai initial de 60 secondes n'est pas décoratif. Lors de la préparation, sans lui, les premières mesures sont sorties en erreur : les nouveaux Pods n'avaient pas encore deux relevés dans la fenêtre d'une minute, et `rate()` n'avait rien à calculer.

Le Rollout lance l'analyse en arrière-plan à partir de l'étape 1, et lui passe le hash du dernier ReplicaSet :

```yaml title="05-rollout-analyse.yaml (extrait)"
  strategy:
    canary:
      stableService: vitrine-stable
      canaryService: vitrine-canari
      trafficRouting:
        plugins:
          argoproj-labs/gatewayAPI:
            httpRoute: vitrine
            namespace: ch58
      analysis:
        templates:
        - templateName: taux-de-succes
        startingStep: 1
        args:
        - name: hash
          valueFrom:
            podTemplateHashValue: Latest
      steps:
      - setWeight: 20
      - pause: {duration: 40s}
      - setWeight: 50
      - pause: {duration: 40s}
      - setWeight: 100
```

<Figure svg={rolloutsCanari} num="58.1" alt="Une frise de six cases : set image, setWeight 20, pause 40 s, setWeight 50, pause 40 s, setWeight 100. Sous chaque étape, les poids de la HTTPRoute passent de 100/0 à 80/20, 50/50 puis 0/100. Une bande en dessous représente l'analyse en arrière-plan, qui mesure toutes les 20 secondes la part des réponses 2xx de la version testée dans Prometheus et exige au moins 95 %. En cas d'échec, une flèche mène à l'état Degraded, les poids reviennent à 100/0. Une note précise que les Pods stables restent au complet pendant tout le canari, de sorte que le retour en arrière ne demande que de changer les poids.">
Un canari avec analyse. Les étapes règlent les poids de la route ; l'analyse tourne en parallèle et peut tout arrêter à n'importe quelle étape.
</Figure>

Les étapes n'ont plus de pause sans durée : si l'analyse ne trouve rien à redire, le déploiement va au bout tout seul. Le fichier garde l'image 6.15.0, la version stable du moment, pour que son application ne déclenche aucun déploiement. Pour l'essai, une charge de fond envoie cinq requêtes par seconde à la vitrine pendant tout le déploiement ; sans trafic, il n'y aurait rien à mesurer.

### Une mauvaise version

La « mauvaise version » est la même image, lancée avec `--random-error` :

```bash
kubectl -n ch58 patch rollout vitrine --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args","value":["./podinfo","--port=9898","--random-error=true"]}]'
```

```sortie
# kubectl -n ch58 patch rollout vitrine ... --random-error=true
abandon 84,62 s après le déploiement de la mauvaise version
# kubectl argo rollouts get rollout vitrine -n ch58 (début)
Name:            vitrine
Namespace:       ch58
Status:          ✖ Degraded
Message:         RolloutAborted: Rollout aborted update to revision 3: Background analysis phase error/failed: Metric "taux-de-succes" assessed Failed due to failed (2) > failureLimit (1)
Strategy:        Canary
  Step:          0/5
  SetWeight:     0
  ActualWeight:  0
Images:          ghcr.io/stefanprodan/podinfo:6.15.0 (canary, stable)
# poids
["vitrine-stable=100","vitrine-canari=0"]
# kubectl -n ch58 get analysisrun
ANALYSE                PHASE    MESSAGE
vitrine-69db878d79-3   Failed   Metric "taux-de-succes" assessed Failed due to failed (2) > failureLimit (1)
# mesures de l'analyse (status.metricResults)
{"name":"taux-de-succes","phase":"Failed","successful":null,"failed":2,"mesures":[{"phase":"Failed","value":"[0.5882352941176471]"},{"phase":"Failed","value":"[0.611111111111111]"}]}
200 requêtes :  200 6.15.0 
```

L'analyse a fait deux mesures, 59 % et 61 % de réponses correctes, toutes deux sous les 95 %. Deux échecs dépassent la limite d'un, l'analyse est passée à `Failed`, et le Rollout a abandonné : état `Degraded`, poids remis à 100 et 0. L'abandon est arrivé 85 secondes après le changement, soit le délai initial de 60 secondes et deux intervalles de 20 secondes, à quelques secondes près. Pendant ces 85 secondes, la nouvelle version a reçu 20 % des requêtes, puis 50 % après la première pause ; un Deployment lui en aurait donné 100 % en quelques secondes. Les 200 requêtes envoyées juste après ont toutes été servies par la version stable. La ligne `Images` affiche la même image pour `canary` et `stable` : seuls les arguments diffèrent, et c'est bien le gabarit complet, pas l'étiquette de l'image, qui fait une révision.

Le Rollout reste `Degraded` tant que personne n'intervient. Pour Argo CD, un Rollout dans cet état est une application en mauvaise santé : Argo CD sait lire l'état d'un Rollout, et traduit aussi une pause en `Suspended`[^sante].

### Une bonne version

Retirer les arguments et revenir à l'image 6.14.1 relance un déploiement :

```sortie
# kubectl -n ch58 patch rollout vitrine ... (sans args, image 6.14.1)
état Healthy 90,67 s plus tard
# kubectl -n ch58 get analysisrun
ANALYSE                PHASE
vitrine-5cc88fcd5c-4   Successful
vitrine-69db878d79-3   Failed
# mesures de la nouvelle analyse
{"name":"taux-de-succes","phase":"Successful","successful":2,"failed":null,"mesures":[{"phase":"Successful","value":"[1]"},{"phase":"Successful","value":"[1]"}]}
# kubectl argo rollouts get rollout vitrine -n ch58 (arbre)
NAME                                 KIND         STATUS        AGE    INFO
⟳ vitrine                            Rollout      ✔ Healthy     5m37s  
├──# revision:4                                                        
│  ├──⧉ vitrine-5cc88fcd5c           ReplicaSet   ✔ Healthy     5m25s  stable
│  │  ├──□ vitrine-5cc88fcd5c-cp5vk  Pod          ✔ Running     90s    ready:1/1
│  │  ├──□ vitrine-5cc88fcd5c-nmkff  Pod          ✔ Running     47s    ready:1/1
│  │  ├──□ vitrine-5cc88fcd5c-lcmqt  Pod          ✔ Running     4s     ready:1/1
│  │  └──□ vitrine-5cc88fcd5c-px4zg  Pod          ✔ Running     4s     ready:1/1
│  └──α vitrine-5cc88fcd5c-4         AnalysisRun  ✔ Successful  87s    ✔ 2
├──# revision:3                                                        
│  ├──⧉ vitrine-69db878d79           ReplicaSet   • ScaledDown  2m58s  
│  └──α vitrine-69db878d79-3         AnalysisRun  ✖ Failed      2m54s  ✖ 2
└──# revision:2                                                        
   └──⧉ vitrine-558fb9698f           ReplicaSet   ✔ Healthy     5m18s  delay:27s
```

Deux mesures à 100 %, et le Rollout est arrivé au bout en 91 secondes, soit les deux pauses de 40 secondes et le temps de démarrer les Pods. L'analyse s'est arrêtée avec le déploiement, après deux des quatre mesures prévues. La révision 4 a réutilisé le ReplicaSet `5cc88fcd5c` de la révision 1 : même gabarit, même hash. L'arbre montre aussi l'historique, avec la révision 3 abandonnée et son analyse en échec, et la révision 2, l'ancienne version stable, gardée encore 27 secondes.

## Le déploiement bleu-vert

Le canari mélange les deux versions pendant plusieurs minutes. Certaines applications le supportent mal : un changement de schéma de base de données, une interface qui charge ses fichiers statiques d'une version et ses données de l'autre. La stratégie bleu-vert ne fait jamais servir les deux versions aux mêmes utilisateurs. Elle a deux Services, `actif` et `aperçu` :

```yaml title="06-bleu-vert.yaml (extrait)"
  strategy:
    blueGreen:
      activeService: bv-actif
      previewService: bv-apercu
      autoPromotionEnabled: false       # la bascule attend une promotion
      scaleDownDelaySeconds: 30         # l'ancienne version reste 30 s, de quoi revenir en arrière
```

Un client dans le cluster interroge les deux Services chaque seconde pendant l'essai :

```sortie
# kubectl apply -f 06-bleu-vert.yaml
service/bv-actif created
service/bv-apercu created
rollout.argoproj.io/bv created
# kubectl argo rollouts status bv -n ch58
Progressing - more replicas need to be updated
Progressing - updated replicas are still becoming available
Healthy
# sélecteurs des deux Services
SERVICE     SELECTEUR
bv-actif    map[app:bv rollouts-pod-template-hash:bb86b56b]
bv-apercu   map[app:bv rollouts-pod-template-hash:bb86b56b]
# kubectl argo rollouts set image bv podinfo=ghcr.io/stefanprodan/podinfo:6.15.0 -n ch58
rollout "bv" image updated
# kubectl argo rollouts get rollout bv -n ch58 (début)
Name:            bv
Namespace:       ch58
Status:          ॥ Paused
Message:         BlueGreenPause
Strategy:        BlueGreen
Images:          ghcr.io/stefanprodan/podinfo:6.14.1 (stable, active)
                 ghcr.io/stefanprodan/podinfo:6.15.0 (preview)
# sélecteurs des deux Services
SERVICE     SELECTEUR
bv-actif    map[app:bv rollouts-pod-template-hash:bb86b56b]
bv-apercu   map[app:bv rollouts-pod-template-hash:685cc98bf4]
# journal du client, une requête par seconde sur chaque Service
09:51:40 actif=6.14.1 apercu=6.15.0
09:51:41 actif=6.14.1 apercu=6.15.0
09:51:42 actif=6.14.1 apercu=6.15.0
# 09:51:43 : kubectl argo rollouts promote bv -n ch58
rollout 'bv' promoted
# journal du client (suite)
09:51:44 actif=6.14.1 apercu=6.15.0
09:51:45 actif=6.15.0 apercu=6.15.0
09:51:46 actif=6.15.0 apercu=6.15.0
09:51:47 actif=6.15.0 apercu=6.15.0
09:51:48 actif=6.15.0 apercu=6.15.0
09:51:49 actif=6.15.0 apercu=6.15.0
09:51:50 actif=6.15.0 apercu=6.15.0
09:51:51 actif=6.15.0 apercu=6.15.0
# kubectl -n ch58 get rs -l app=bv
RS              VOULUS   IMAGE
bv-685cc98bf4   2        ghcr.io/stefanprodan/podinfo:6.15.0
bv-bb86b56b     2        ghcr.io/stefanprodan/podinfo:6.14.1
# 35 s plus tard
RS              VOULUS   IMAGE
bv-685cc98bf4   2        ghcr.io/stefanprodan/podinfo:6.15.0
bv-bb86b56b     0        ghcr.io/stefanprodan/podinfo:6.14.1
```

Sans mise à jour en cours, les deux Services visent le même ReplicaSet. Au changement d'image, le contrôleur a créé le ReplicaSet de la version 6.15.0 et réglé sur lui le sélecteur de `bv-apercu`, puis s'est mis en pause (`BlueGreenPause`) : les utilisateurs, sur `bv-actif`, voient toujours 6.14.1, et l'équipe peut tester 6.15.0 sur `bv-apercu`. Après la promotion, le client a vu la nouvelle version sur `bv-actif` en une à deux secondes, sans aucune requête en échec. La bascule n'est qu'un changement de sélecteur de Service. L'ancien ReplicaSet garde ses deux Pods pendant `scaleDownDelaySeconds`, 30 secondes, le temps que chaque nœud mette à jour ses règles de routage vers le Service[^bleuvert]. Pendant ces 30 secondes, revenir en arrière ne coûte qu'un nouveau changement de sélecteur.

<Figure svg={rolloutsBleuVert} num="58.2" alt="Deux schémas côte à côte. À gauche, la nouvelle version déployée et en pause : le Service bv-actif vise le ReplicaSet bleu, 6.14.1 avec 2 Pods, et le Service bv-apercu vise le ReplicaSet vert, 6.15.0 avec 2 Pods ; les utilisateurs voient 6.14.1, l'équipe teste 6.15.0 sur bv-apercu. Une flèche promote mène à droite, après la promotion : les deux Services visent le ReplicaSet vert, le ReplicaSet bleu est gardé 30 secondes puis réduit à zéro Pod. Le lien entre Service et ReplicaSet est l'étiquette rollouts-pod-template-hash.">
Le déploiement bleu-vert. La promotion ne crée aucun Pod : elle change le sélecteur du Service actif.
</Figure>

Le prix est la capacité : pendant la pause, la nouvelle version tourne avec autant de Pods que l'ancienne, soit le double des ressources. Le canari avec routage en demande moins, mais mélange les versions.

## Ce que coûte le contrôleur

```sortie
# kubectl -n argo-rollouts top pods
NAME                             CPU(cores)   MEMORY(bytes)   
argo-rollouts-675d55fc7f-grth2   15m          52Mi            
mémoire du nœud : 5.215GiB / 5.5GiB
```

52 Mio pour le contrôleur, greffon compris. Le nœud, avec toute la pile des chapitres précédents (Prometheus, CloudNativePG, Argo CD, Gitea), est à 5,2 Gio sur les 5,5 que lui laisse Docker.

## Exercices

:::exercice[Exercice 1 : abandonner puis reprendre]

Déployez la version 6.15.0 sur la vitrine (stable : 6.14.1) et, une fois l'étape à 50 % atteinte, abandonnez avec `kubectl argo rollouts abort`. Que deviennent les poids de la route et les Pods canari ? Reprenez ensuite avec `kubectl argo rollouts retry rollout`. À quelle étape le Rollout repart-il ?

:::

<details>
<summary>Corrigé</summary>

```sortie
# suite de l'exercice 3 : le Rollout est à l'étape à 50 %
# kubectl argo rollouts abort vitrine -n ch58
rollout 'vitrine' aborted
# phase et étape du Rollout
Degraded étape 0
# poids
["vitrine-stable=100","vitrine-canari=0"]
# kubectl -n ch58 get rs (ReplicaSets non vides)
RS                   VOULUS   IMAGE
vitrine-558fb9698f   2        ghcr.io/stefanprodan/podinfo:6.15.0
vitrine-5cc88fcd5c   4        ghcr.io/stefanprodan/podinfo:6.14.1
# kubectl argo rollouts retry rollout vitrine -n ch58
rollout 'vitrine' retried
# phase et étape du Rollout
Paused étape 1
# poids
["vitrine-stable=80","vitrine-canari=20"]
# kubectl argo rollouts status vitrine -n ch58
Healthy
# poids
["vitrine-stable=100","vitrine-canari=0"]
# les deux dernières analyses
vitrine-558fb9698f-5     Successful
vitrine-558fb9698f-5.1   Successful
```

L'abandon remet tout de suite les poids à 100 et 0 et passe le Rollout à `Degraded`, mais les deux Pods canari sont toujours là cinq secondes plus tard : avec un routage du trafic, ils sont gardés `abortScaleDownDelaySeconds`, 30 secondes par défaut[^spec], pour la même raison que l'ancienne version après une promotion. `retry` repart de la première étape, pas de celle où l'abandon a eu lieu : poids 80 et 20, puis tout le parcours, avec une nouvelle analyse (`-5.1`), réussie.

</details>

:::exercice[Exercice 2 : un canari sans routage du trafic]

Créez un Rollout `simple` de 4 répliques, derrière un Service ordinaire, avec une stratégie canari sans `trafficRouting` : `setWeight: 10` puis une pause sans durée. Déployez une nouvelle version. Combien de Pods de chaque version tournent ? Quelle part de 400 requêtes la nouvelle version reçoit-elle, et pourquoi pas 10 % ?

:::

<details>
<summary>Corrigé</summary>

```sortie
# kubectl apply -f sans-routage.yaml
service/simple created
rollout.argoproj.io/simple created
# kubectl argo rollouts status simple -n ch58
Healthy
# kubectl argo rollouts set image simple podinfo=ghcr.io/stefanprodan/podinfo:6.15.0 -n ch58
rollout "simple" image updated
# kubectl argo rollouts get rollout simple -n ch58 (extrait)
  SetWeight:     10
  ActualWeight:  20
# kubectl -n ch58 get rs -l app=simple
RS                  VOULUS   PRETS   IMAGE
simple-8646dfc744   1        1       ghcr.io/stefanprodan/podinfo:6.15.0
simple-c6685cd84    4        4       ghcr.io/stefanprodan/podinfo:6.14.1
400 requêtes au Service simple :
    319 6.14.1
     81 6.15.0
```

Sans routage, il n'y a pas de poids à écrire nulle part : le Service répartit les requêtes entre tous les Pods prêts, et la seule façon d'approcher 10 % est de jouer sur le nombre de Pods. La documentation parle d'un « meilleur effort »[^canary]. Le calcul, dans `approximateWeightedCanaryStableReplicaCounts`, refuse zéro Pod canari pour un poids entre 1 et 99, puis compare les possibilités : 1 Pod sur 4 fait 25 %, et 1 Pod sur 5, en utilisant le `maxSurge` de 25 % (un Pod de plus), fait 20 %, plus près de 10 %[^code]. D'où `ActualWeight: 20`, 5 Pods pour 4 répliques demandées, et 81 requêtes sur 400 (20 %). Avec 4 répliques, 10 % est impossible ; il en faudrait au moins 10, ou un routage du trafic.

</details>

:::exercice[Exercice 3 : vérifier la répartition annoncée (programmation)]

Écrivez un script Python qui envoie N requêtes à `vitrine.local/version` par la passerelle, compte les versions, lit le poids de `vitrine-canari` dans la HTTPRoute, et dit si la part observée est compatible avec ce poids. Utilisez un intervalle de confiance à 95 % (la méthode de Wilson convient), et sortez avec le code 1 en cas d'incompatibilité. Lancez-le aux étapes à 20 % et à 50 % du Rollout avec analyse.

:::

<details>
<summary>Corrigé</summary>

Le corrigé, `corrige/repartition.py`, n'est pas dans l'archive. La passerelle est jointe à son adresse avec un en-tête `Host`, comme le fait `curl --resolve` ; le poids est lu par `kubectl get httproute -o json`.

```sortie
# kubectl argo rollouts set image vitrine podinfo=ghcr.io/stefanprodan/podinfo:6.15.0 -n ch58
rollout "vitrine" image updated
# python3 repartition.py -n 300      # étape 20 %
300 requêtes vers vitrine.local, poids annoncé pour vitrine-canari : 20/100 (20%)
  6.14.1       240   80.0%
  6.15.0        60   20.0%
part de 6.15.0 : 20.0%, intervalle à 95 % [15.9% ; 24.9%] : compatible avec 20%
code : 0
# python3 repartition.py -n 300      # étape 50 %
300 requêtes vers vitrine.local, poids annoncé pour vitrine-canari : 50/100 (50%)
  6.14.1       149   49.7%
  6.15.0       151   50.3%
part de 6.15.0 : 50.3%, intervalle à 95 % [44.7% ; 56.0%] : compatible avec 50%
code : 0
```

Avec 300 requêtes, l'intervalle fait environ ±5 points : une passerelle qui servirait 30 % au lieu de 20 % serait détectée, une qui servirait 22 % ne le serait pas. Pour resserrer l'intervalle de moitié, il faut quatre fois plus de requêtes. La même limite pèse sur l'analyse : à 5 requêtes par seconde, une fenêtre d'une minute sur 20 % du trafic ne contient qu'une soixantaine de requêtes de la version testée. Le seuil de 95 % tolère alors 3 erreurs sur 60, et une version qui échoue sur 6 % des requêtes réussit une mesure sur deux (probabilité 0,51 d'avoir au plus 3 erreurs, d'après la loi binomiale). Une analyse fiable demande du trafic, ou des mesures plus longues.

</details>

:::exercice[Exercice 4 : annuler un bleu-vert]

Le Rollout `bv` est stable en 6.15.0. Déployez 6.14.1, puis, pendant la pause, abandonnez. Que deviennent les deux Services et le ReplicaSet de la version abandonnée ?

:::

<details>
<summary>Corrigé</summary>

```sortie
# kubectl argo rollouts set image bv podinfo=ghcr.io/stefanprodan/podinfo:6.14.1 -n ch58
rollout "bv" image updated
# phase du Rollout
Paused
# sélecteurs des deux Services
SERVICE     SELECTEUR
bv-actif    map[app:bv rollouts-pod-template-hash:685cc98bf4]
bv-apercu   map[app:bv rollouts-pod-template-hash:bb86b56b]
# kubectl argo rollouts abort bv -n ch58
rollout 'bv' aborted
# phase du Rollout
Degraded
# sélecteurs des deux Services
SERVICE     SELECTEUR
bv-actif    map[app:bv rollouts-pod-template-hash:685cc98bf4]
bv-apercu   map[app:bv rollouts-pod-template-hash:bb86b56b]
RS              VOULUS   IMAGE
bv-685cc98bf4   2        ghcr.io/stefanprodan/podinfo:6.15.0
bv-bb86b56b     2        ghcr.io/stefanprodan/podinfo:6.14.1
# 35 s plus tard
RS              VOULUS   IMAGE
bv-685cc98bf4   2        ghcr.io/stefanprodan/podinfo:6.15.0
bv-bb86b56b     0        ghcr.io/stefanprodan/podinfo:6.14.1
```

Le Service actif n'a jamais quitté la version 6.15.0 : rien n'a changé pour les utilisateurs. Le Service d'aperçu vise encore la version abandonnée, dont le ReplicaSet garde ses Pods 30 secondes (`abortScaleDownDelaySeconds`) avant de passer à 0[^spec]. Le Rollout reste `Degraded` jusqu'au prochain changement de gabarit, ou jusqu'à ce qu'on remette dans le Rollout l'image stable.

</details>

## Interfaces et nettoyage

`kubectl argo rollouts dashboard` sert une interface web sur `http://localhost:3100`, qui montre les mêmes informations que `kubectl argo rollouts get` et propose les boutons de promotion et d'abandon. Le contrôleur et son greffon restent installés pour le défi VIII. L'application du chapitre a été supprimée :

```bash
kubectl delete namespace ch58
```

Pour retirer Argo Rollouts plus tard : `kubectl delete namespace argo-rollouts`, les cinq CRD `*.argoproj.io` de la section d'installation (attention, `applications.argoproj.io` et ses voisines appartiennent à Argo CD), puis `kubectl delete clusterrole,clusterrolebinding argo-rollouts-gatewayapi`.

[^podinfo]: podinfo, option `--random-error` : « 1/3 chances of a random response error ». [github.com/stefanprodan/podinfo/blob/6.15.0/cmd/podinfo/main.go](https://github.com/stefanprodan/podinfo/blob/6.15.0/cmd/podinfo/main.go)
[^concepts]: Argo Rollouts, « Concepts » : la ressource Rollout, les stratégies bleu-vert et canari. [github.com/argoproj/argo-rollouts/blob/v1.10.0/docs/concepts.md](https://github.com/argoproj/argo-rollouts/blob/v1.10.0/docs/concepts.md) ; documentation en ligne : [argoproj.github.io/argo-rollouts](https://argoproj.github.io/argo-rollouts/)
[^annotations]: Kubernetes, `TotalAnnotationSizeLimitB = 256 * (1 << 10)` dans la validation des métadonnées. [github.com/kubernetes/apimachinery/blob/v0.34.0/pkg/api/validation/objectmeta.go](https://github.com/kubernetes/apimachinery/blob/v0.34.0/pkg/api/validation/objectmeta.go) ; sur l'application côté serveur : [kubernetes.io/docs/reference/using-api/server-side-apply](https://kubernetes.io/docs/reference/using-api/server-side-apply/)
[^installation]: Argo Rollouts, « Installation » : les CRD s'appliquent avec `kubectl apply --server-side`. [github.com/argoproj/argo-rollouts/blob/v1.10.0/docs/installation.md](https://github.com/argoproj/argo-rollouts/blob/v1.10.0/docs/installation.md)
[^greffons]: Argo Rollouts, « Traffic Router Plugins » : téléchargement au démarrage, contrôleur qui ne démarre pas si le greffon est introuvable, somme `sha256` facultative. [github.com/argoproj/argo-rollouts/blob/v1.10.0/docs/features/traffic-management/plugins.md](https://github.com/argoproj/argo-rollouts/blob/v1.10.0/docs/features/traffic-management/plugins.md)
[^gatewayapi]: Argo Rollouts Gateway API plugin, documentation et installation. [rollouts-plugin-trafficrouter-gatewayapi.readthedocs.io](https://rollouts-plugin-trafficrouter-gatewayapi.readthedocs.io/en/latest/installation/) ; version 0.17.0 : [github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi/releases/tag/v0.17.0](https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi/releases/tag/v0.17.0)
[^canary]: Argo Rollouts, « Canary » : répartition par nombre de Pods sans routage du trafic, ReplicaSet stable gardé au complet avec routage. [github.com/argoproj/argo-rollouts/blob/v1.10.0/docs/features/canary/index.md](https://github.com/argoproj/argo-rollouts/blob/v1.10.0/docs/features/canary/index.md)
[^spec]: Argo Rollouts, « Rollout Specification » : `scaleDownDelaySeconds` et `abortScaleDownDelaySeconds`, 30 secondes par défaut. [github.com/argoproj/argo-rollouts/blob/v1.10.0/docs/features/specification.md](https://github.com/argoproj/argo-rollouts/blob/v1.10.0/docs/features/specification.md)
[^analyse]: Argo Rollouts, « Analysis & Progressive Delivery » : analyse en arrière-plan, `startingStep`, `podTemplateHashValue`, `failureLimit`, `initialDelay`. [github.com/argoproj/argo-rollouts/blob/v1.10.0/docs/features/analysis.md](https://github.com/argoproj/argo-rollouts/blob/v1.10.0/docs/features/analysis.md)
[^sante]: Argo CD, vérification de santé des Rollouts : `Paused` traduit en `Suspended`, abandon traduit en `Degraded`. [github.com/argoproj/argo-cd/blob/v3.5.4/resource_customizations/argoproj.io/Rollout/health.lua](https://github.com/argoproj/argo-cd/blob/v3.5.4/resource_customizations/argoproj.io/Rollout/health.lua)
[^bleuvert]: Argo Rollouts, « BlueGreen Deployment Strategy » : Services actif et d'aperçu, délai de propagation et `scaleDownDelaySeconds`. [github.com/argoproj/argo-rollouts/blob/v1.10.0/docs/features/bluegreen.md](https://github.com/argoproj/argo-rollouts/blob/v1.10.0/docs/features/bluegreen.md)
[^code]: Argo Rollouts, `utils/replicaset/canary.go`, fonction `approximateWeightedCanaryStableReplicaCounts`. [github.com/argoproj/argo-rollouts/blob/v1.10.0/utils/replicaset/canary.go](https://github.com/argoproj/argo-rollouts/blob/v1.10.0/utils/replicaset/canary.go)
