---
title: Les métriques
sidebar_label: 50. Les métriques
description: "Mesurer Colis dans la durée avec kube-prometheus-stack : installer Prometheus, Grafana et Alertmanager dans un nœud de 4 Gio, instrumenter l'API (Colis 2.2), ServiceMonitor et PodMonitor, PromQL par l'exemple (taux, ratios, centiles d'histogramme), un tableau de bord versionné, et une alerte déclenchée puis résolue pour de vrai."
partie: 7
chapitre: '50'
---

import supervisionArchitecture from '@site/src/figures/supervision-architecture.svg';
import histogrammeCentile from '@site/src/figures/histogramme-centile.svg';

Vendredi, 18 h. Quelqu'un écrit dans le canal de l'équipe : « Le suivi des colis est lent, non ? Depuis quand ? » Avec ce que vous savez faire, vous pouvez répondre sur l'instant : `kubectl top` donne la mémoire et le processeur de chaque Pod maintenant, `kubectl logs` les dernières requêtes d'un Pod. Mais « depuis quand », « plus lent qu'hier », « combien de requêtes en erreur dans la dernière heure » : aucun de ces outils ne garde la mémoire du passé, et aucun ne compte. Le chapitre 48 enquêtait sur une panne présente. Celui-ci installe de quoi mesurer en continu, garder l'historique, et prévenir quelqu'un avant que la question soit posée.

L'outil standard dans l'écosystème Kubernetes s'appelle Prometheus. Comme Kubernetes, il est hébergé par la CNCF, dont il a été le deuxième projet[^prometheus]. On l'installe rarement seul : le chart **kube-prometheus-stack** l'assemble avec Alertmanager, Grafana, les exportateurs qui décrivent le cluster et un opérateur qui pilote le tout par des ressources Kubernetes. Les fichiers du chapitre sont dans [l'archive metriques](pathname:///kits/metriques.tar.gz), et la nouvelle version de l'API dans [l'archive colis-2.2](pathname:///kits/colis-2.2.tar.gz).

## Le modèle de Prometheus

Trois idées suffisent pour lire tout le reste du chapitre.

**Prometheus va chercher les mesures.** Chaque programme surveillé expose, sur une adresse HTTP (souvent `/metrics`), l'état de ses compteurs à l'instant présent. Prometheus interroge chaque **cible** à intervalle régulier (15 ou 30 secondes ici) et range ce qu'il lit. C'est le modèle *pull* : l'application n'a pas à connaître Prometheus, et une cible qui ne répond plus se voit immédiatement, puisque la collecte échoue.

**Une métrique est une famille de séries temporelles.** Une **série** est identifiée par un nom et un ensemble d'étiquettes, par exemple `colis_http_requetes_total{route="/colis", code="200"}`, et contient une suite de couples (instant, valeur). Chaque combinaison d'étiquettes distincte est une série distincte, stockée et indexée à part. C'est la source de presque tous les problèmes de coût, comme on le verra.

**On interroge avec PromQL**, un langage qui travaille sur ces séries : les filtrer par étiquettes, calculer un taux sur une fenêtre de temps, agréger, diviser. Les règles d'alerte sont des requêtes PromQL évaluées en permanence.

<Figure svg={supervisionArchitecture} num="50.1" alt="À gauche, ce qui est collecté : l'API de Colis sur le port 8000, chemin /metrics/, par un ServiceMonitor ; le worker sur le port 9101 par un PodMonitor ; le kubelet et cAdvisor pour les conteneurs ; kube-state-metrics pour l'état des objets ; node-exporter pour le nœud ; l'API server et CoreDNS. Au centre, Prometheus interroge chaque cible toutes les 15 à 30 secondes par HTTP GET, garde deux jours de séries temporelles et évalue les règles d'enregistrement et d'alerte. Au-dessus, Prometheus Operator traduit ServiceMonitor, PodMonitor, PrometheusRule et AlertmanagerConfig en configuration. À droite, Grafana interroge Prometheus en PromQL et charge ses tableaux de bord depuis des ConfigMaps ; Alertmanager reçoit les alertes actives, les regroupe, les déduplique et les route selon leurs étiquettes vers un récepteur, ici un webhook pager.">
La pile de supervision du chapitre. En bleu, les deux cibles que Colis ajoute ; les autres sont fournies par le chart.
</Figure>

## Installer la pile

Le chart est volumineux, et ses valeurs par défaut visent un vrai cluster. Le fichier de valeurs du kit réduit les ressources de chaque composant, limite la rétention de Prometheus à deux jours et 1 Go, et lève un filtre qui surprend tout le monde la première fois :

```yaml title="valeurs-supervision.yaml"
# kube-prometheus-stack sur le minikube du cours : Prometheus, Alertmanager, Grafana,
# kube-state-metrics et node-exporter, réglés pour tenir dans un nœud de 4 Gio.
prometheus:
  prometheusSpec:
    retention: 2d
    retentionSize: 1GB
    resources:
      requests: {cpu: 100m, memory: 400Mi}
      limits: {memory: 1Gi}
    # sans ces trois lignes, Prometheus ne lirait que les ServiceMonitor, PodMonitor
    # et PrometheusRule portant l'étiquette release: supervision
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
alertmanager:
  alertmanagerSpec:
    resources:
      requests: {cpu: 10m, memory: 32Mi}
      limits: {memory: 128Mi}
grafana:
  persistence:
    enabled: false
  resources:
    requests: {cpu: 50m, memory: 128Mi}
    limits: {memory: 384Mi}
  sidecar:
    dashboards:
      searchNamespace: ALL      # tableaux de bord lus dans les ConfigMaps de tous les namespaces
prometheusOperator:
  resources:
    requests: {cpu: 20m, memory: 64Mi}
    limits: {memory: 256Mi}
kube-state-metrics:
  resources:
    requests: {cpu: 10m, memory: 32Mi}
    limits: {memory: 128Mi}
prometheus-node-exporter:
  resources:
    requests: {cpu: 10m, memory: 24Mi}
    limits: {memory: 64Mi}
# Dans minikube (comme avec kubeadm par défaut), etcd, kube-controller-manager et kube-scheduler
# n'exposent leurs métriques que sur 127.0.0.1 : Prometheus ne peut pas les joindre.
kubeEtcd:
  enabled: false
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
```

Par défaut, le Prometheus du chart ne lit que les ServiceMonitor, PodMonitor et PrometheusRule qui portent l'étiquette `release: supervision`, celle de sa propre release Helm. Les objets que vous créez pour vos applications seraient ignorés en silence. Les trois réglages `...NilUsesHelmValues: false` lui font lire tous ceux du cluster.

Le chart est publié en OCI, comme ceux de la partie VI :

```bash
helm install supervision oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack \
  --version 92.1.0 -n supervision --create-namespace -f valeurs-supervision.yaml --wait --timeout 10m
```

```sortie
Pulled: ghcr.io/prometheus-community/charts/kube-prometheus-stack:92.1.0
Digest: sha256:1d18af4218d0295656dee4d01f4a839d75639703e5f9c01d6beebbb8821ee5d1
Error: INSTALLATION FAILED: resource Deployment/supervision/supervision-grafana not ready. status: Failed, message: Progress deadline exceeded
```

:::panne[Helm annonce un échec, alors que tout finit par démarrer]

`--wait` attend que chaque Deployment soit disponible avant son délai de progression (10 minutes par défaut, `progressDeadlineSeconds`). Ici, Grafana a mis plus longtemps : ses trois images (Grafana et deux conteneurs annexes) se téléchargeaient lentement. Le Deployment est passé en `ProgressDeadlineExceeded`, Helm a marqué la release `failed`, puis le Pod a démarré quelques minutes plus tard. Rien n'est cassé dans le cluster, seulement dans l'état de la release. Un `helm upgrade` avec les mêmes valeurs, une fois les Pods prêts, la remet en `deployed`.

:::

Une fois tout démarré, une première question : que collecte Prometheus ? Son API répond, par une redirection de port :

```bash
kubectl -n supervision port-forward svc/supervision-kube-prometheu-prometheus 9095:9090 &
curl -s localhost:9095/api/v1/targets | jq -r '.data.activeTargets[] | [.scrapePool, .health, (.lastError|.[0:90])] | @tsv' \
  | sed 's|serviceMonitor/supervision/supervision-kube-prometheu-||' | sort | uniq -c
```

```sortie
      1 alertmanager/0	up	
      1 alertmanager/1	up	
      1 apiserver/0	up	
      1 coredns/0	up	
      1 kube-controller-manager/0	down	Get "https://192.168.49.2:10257/metrics": dial tcp 192.168.49.2:10257: connect: connection
      1 kube-etcd/0	down	Get "http://192.168.49.2:2381/metrics": dial tcp 192.168.49.2:2381: connect: connection re
      1 kubelet/0	up	
      1 kubelet/1	up	
      1 kubelet/2	up	
      1 kube-proxy/0	up	
      1 kube-scheduler/0	down	Get "https://192.168.49.2:10259/metrics": dial tcp 192.168.49.2:10259: connect: connection
      1 operator/0	up	
      1 prometheus/0	up	
      1 prometheus/1	up	
      1 serviceMonitor/supervision/supervision-grafana/0	up	
      1 serviceMonitor/supervision/supervision-kube-state-metrics/0	up	
      1 serviceMonitor/supervision/supervision-prometheus-node-exporter/0	up	
```

Trois cibles sont `down`, et le message dit pourquoi : rien n'écoute sur l'adresse du nœud pour etcd, kube-controller-manager et kube-scheduler. minikube les configure comme kubeadm le fait par défaut, avec leurs métriques sur `127.0.0.1` seulement. Deux choix possibles. Sur un cluster que l'on administre, on change l'adresse d'écoute dans les manifestes statiques (`--bind-address=0.0.0.0`, `--listen-metrics-urls` pour etcd), en sachant qu'on expose ces métriques sur le réseau des nœuds. Ici, on renonce à les collecter (les trois derniers réglages du fichier de valeurs), et le même `helm upgrade` répare la release :

```bash
helm -n supervision upgrade supervision oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack \
  --version 92.1.0 -f valeurs-supervision.yaml --wait --timeout 10m
helm -n supervision list
```

```sortie
NAME       	NAMESPACE  	REVISION	UPDATED                               	STATUS  	CHART                       	APP VERSION
supervision	supervision	2       	2026-10-08 07:21:18.68337376 +0100 WAT	deployed	kube-prometheus-stack-92.1.0	v0.94.1    
```

Sur un cluster managé (EKS, GKE, AKS), ces trois composants appartiennent au fournisseur : la question ne se pose pas, et leurs métriques sont, ou non, proposées par son propre service de supervision.

```bash
kubectl -n supervision get pods
docker stats --no-stream minikube --format '{{.MemUsage}}'
kubectl get crd -o name | grep monitoring.coreos.com
```

```sortie
NAME                                                     READY   STATUS        RESTARTS   AGE
alertmanager-supervision-kube-prometheu-alertmanager-0   2/2     Running       0          33m
prometheus-supervision-kube-prometheu-prometheus-0       2/2     Running       0          33m
supervision-grafana-596f55dcd4-grf4h                     3/3     Running       0          19m
supervision-kube-prometheu-operator-76d74945df-t7xqf     1/1     Running       0          34m
supervision-kube-state-metrics-c46cdbdbb-kb2t6           1/1     Running       0          34m
supervision-prometheus-node-exporter-l9f2p               1/1     Running       0          34m
3.614GiB / 4GiB
customresourcedefinition.apiextensions.k8s.io/alertmanagerconfigs.monitoring.coreos.com
customresourcedefinition.apiextensions.k8s.io/alertmanagers.monitoring.coreos.com
customresourcedefinition.apiextensions.k8s.io/podmonitors.monitoring.coreos.com
customresourcedefinition.apiextensions.k8s.io/probes.monitoring.coreos.com
customresourcedefinition.apiextensions.k8s.io/prometheusagents.monitoring.coreos.com
customresourcedefinition.apiextensions.k8s.io/prometheuses.monitoring.coreos.com
customresourcedefinition.apiextensions.k8s.io/prometheusrules.monitoring.coreos.com
customresourcedefinition.apiextensions.k8s.io/scrapeconfigs.monitoring.coreos.com
customresourcedefinition.apiextensions.k8s.io/servicemonitors.monitoring.coreos.com
customresourcedefinition.apiextensions.k8s.io/thanosrulers.monitoring.coreos.com
```

Six Pods, et dix types de ressources ajoutés par l'opérateur. Les quatre qui nous serviront : **ServiceMonitor** et **PodMonitor** (quoi collecter), **PrometheusRule** (quoi calculer et quand alerter), **AlertmanagerConfig** (à qui envoyer). Le nœud est monté à 3,6 Gio sur 4. Le chiffre de `docker stats` inclut le cache de fichiers du noyau, que celui-ci peut libérer ; il reste néanmoins peu de marge, et le chapitre 51 devra en tenir compte.

## Ce que Colis dit de lui-même

kube-state-metrics, cAdvisor et node-exporter décrivent le cluster de l'extérieur : un Pod redémarre, un conteneur consomme 70 Mio. Ils ne savent rien des requêtes de Colis, de leur durée, des colis enregistrés. Pour cela, l'application doit s'**instrumenter** elle-même. C'est l'objet de la version 2.2 de l'image, qui ajoute aussi des journaux JSON et des traces (pour le chapitre 51), et corrige enfin le défaut relevé au chapitre 27 : une estimation tardive remettait un colis livré à l'état « estimé ».

La bibliothèque officielle `prometheus-client` fournit les types de métriques. Colis en déclare quatre familles :

```python title="colis-2.2/app/colis/observabilite.py (extrait)"
REQUETES = Counter("colis_http_requetes_total", "Requêtes HTTP traitées",
                   ["methode", "route", "code"])
DUREE = Histogram("colis_http_duree_secondes", "Durée de traitement des requêtes HTTP",
                  ["methode", "route"],
                  buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5))
ENREGISTRES = Counter("colis_enregistres_total", "Colis enregistrés par l'API")
ESTIMES = Counter("colis_estimes_total", "Colis dont la date de livraison a été calculée",
                  ["par"])
LIVRES = Counter("colis_livres_total", "Colis marqués livrés")
FILE = Gauge("colis_file_longueur", "Colis en attente d'estimation dans la file")
```

Les trois types correspondent à trois questions. Un **compteur** (`Counter`) ne fait que croître, sauf au redémarrage du processus où il repart de zéro : combien de requêtes depuis le démarrage. Une **jauge** (`Gauge`) monte et descend : combien de colis en attente maintenant. Un **histogramme** (`Histogram`) range chaque observation dans des intervalles fixés à l'avance (les *buckets*) : combien de requêtes ont pris moins de 5 ms, moins de 10 ms, etc.[^types]

Chaque requête passe par une fonction intermédiaire qui mesure sa durée, incrémente le compteur, alimente l'histogramme et écrit une ligne de journal :

```python title="colis-2.2/app/colis/app.py (extrait)"
    @app.middleware("http")
    async def mesurer(request: Request, suite):
        debut = time.perf_counter()
        code = 500
        try:
            reponse = await suite(request)
            code = reponse.status_code
            return reponse
        finally:
            route = getattr(request.scope.get("route"), "path", "inconnue")
            if route not in SILENCIEUX and not request.url.path.startswith("/metrics"):
                duree = time.perf_counter() - debut
                REQUETES.labels(request.method, route, str(code)).inc()
                DUREE.labels(request.method, route).observe(duree)
                log.info("requête", extra={"champs": {
                    "methode": request.method, "chemin": request.url.path, "route": route,
                    "code": code, "duree_ms": round(duree * 1000, 1)}})
```

Le détail qui compte est l'étiquette `route`. Elle vaut le **modèle** de la route, `/colis/{id_}`, jamais le chemin réel, `/colis/249`. Avec le chemin réel, chaque identifiant de colis créerait ses propres séries, des dizaines par colis avec l'histogramme, et la base de Prometheus grossirait avec le nombre de colis. C'est la règle de base de l'instrumentation : des étiquettes en petit nombre, à valeurs bornées[^nommage]. Les sondes `/sante` et `/pret`, appelées en boucle par le kubelet, sont exclues des métriques comme du journal.

L'image se construit comme celles de la partie II, avec le constructeur `cours` du chapitre 13, et l'étape de tests (16 tests, dont trois nouveaux pour les métriques et l'estimation) doit passer :

```bash
tar -xzf colis-2.2.tar.gz
docker buildx build --builder cours -t localhost:5001/colis/api:2.2 --push colis-2.2/app
```

Le script `passer-en-2.2.sh` du kit passe ensuite l'API, le worker et la purge à l'image 2.2, déclare le port de métriques du worker et pose sur le Service `api` une étiquette qui servira à le sélectionner :

```bash
bash passer-en-2.2.sh
kubectl -n colis get deploy -o custom-columns=NOM:.metadata.name,IMAGE:.spec.template.spec.containers[0].image
```

```sortie
configmap/colis-config patched (no change)
deployment.apps/worker patched (no change)
service/api not labeled
deployment "api" successfully rolled out
NOM      IMAGE
api      host.minikube.internal:5001/colis/api:2.2
redis    redis:8.8-alpine
web      host.minikube.internal:5001/colis/web:1.1@sha256:9ac4d5a43e71bc5410bfcd5cdcc8644a00711e5d416252f546ba4851f59bd5d4
worker   host.minikube.internal:5001/colis/api:2.2
```

Avant de brancher Prometheus, regardons ce qu'il lira, après quelques secondes de trafic. `charge.py` envoie des requêtes à Colis par la passerelle HTTPS du chapitre 28 (20 % d'enregistrements, 50 % de listes, 20 % de lectures, 10 % de colis inexistants) :

```bash
python3 charge.py --duree 4 --debit 5 --ca ca.crt
kubectl -n colis exec deploy/api -- python -c "import urllib.request as u; print(u.urlopen('http://localhost:8000/metrics/').read().decode())" > metriques.txt
grep -E '^# (HELP|TYPE) colis_http_requetes_total|^colis_http_requetes_total' metriques.txt
grep 'colis_http_duree_secondes.*route="/colis"}' metriques.txt
grep -E '^colis_(enregistres_total|file_longueur) ' metriques.txt
kubectl -n colis logs deploy/api --tail=2
```

```sortie
réponses : 200 x14, 201 x2, 404 x3
# HELP colis_http_requetes_total Requêtes HTTP traitées
# TYPE colis_http_requetes_total counter
colis_http_requetes_total{code="404",methode="GET",route="/colis/{id_}"} 137.0
colis_http_requetes_total{code="200",methode="GET",route="/colis"} 563.0
colis_http_requetes_total{code="200",methode="GET",route="/colis/{id_}"} 250.0
colis_http_requetes_total{code="201",methode="POST",route="/colis"} 254.0
colis_http_duree_secondes_bucket{le="0.005",methode="GET",route="/colis"} 549.0
colis_http_duree_secondes_bucket{le="0.01",methode="GET",route="/colis"} 562.0
colis_http_duree_secondes_bucket{le="0.025",methode="GET",route="/colis"} 563.0
colis_http_duree_secondes_bucket{le="0.05",methode="GET",route="/colis"} 563.0
colis_http_duree_secondes_bucket{le="0.1",methode="GET",route="/colis"} 563.0
colis_http_duree_secondes_bucket{le="0.25",methode="GET",route="/colis"} 563.0
colis_http_duree_secondes_bucket{le="0.5",methode="GET",route="/colis"} 563.0
colis_http_duree_secondes_bucket{le="1.0",methode="GET",route="/colis"} 563.0
colis_http_duree_secondes_bucket{le="2.5",methode="GET",route="/colis"} 563.0
colis_http_duree_secondes_bucket{le="5.0",methode="GET",route="/colis"} 563.0
colis_http_duree_secondes_bucket{le="+Inf",methode="GET",route="/colis"} 563.0
colis_http_duree_secondes_count{methode="GET",route="/colis"} 563.0
colis_http_duree_secondes_sum{methode="GET",route="/colis"} 1.8987404940198758
colis_enregistres_total 254.0
colis_file_longueur 2.0
{"moment": "2026-10-08T06:40:49.872Z", "niveau": "info", "service": "colis", "message": "requête", "methode": "GET", "chemin": "/colis/759", "route": "/colis/{id_}", "code": 200, "duree_ms": 2.4}
{"moment": "2026-10-08T06:40:50.725Z", "niveau": "info", "service": "colis", "message": "requête", "methode": "GET", "chemin": "/colis/759", "route": "/colis/{id_}", "code": 200, "duree_ms": 2.5}
```

C'est le format texte de Prometheus : une ligne par série, le nom, les étiquettes entre accolades, la valeur. Ces chiffres ne concernent qu'**un** des deux Pods de l'API, celui qu'a choisi `kubectl exec` ; chaque Pod a ses propres compteurs, et c'est Prometheus qui les additionnera. Les lignes de l'histogramme sont **cumulatives** : `le="0.01"` (*less or equal*) compte les requêtes de 10 ms ou moins, y compris celles de 5 ms ou moins. Les trois listes ont donc pris moins de 25 ms, dont une moins de 5 ms. `_sum` et `_count` donnent la somme des durées et le nombre d'observations, de quoi calculer une moyenne. La jauge `colis_file_longueur` est lue dans Redis au moment même de la collecte. Les deux dernières lignes sont le nouveau journal, une ligne JSON par requête : le chapitre 51 s'en servira.

## Dire à Prometheus où regarder

Prometheus ne découvre pas les applications tout seul. Avec l'opérateur, on le lui dit par deux ressources. Un **ServiceMonitor** désigne les Pods derrière un Service ; un **PodMonitor** désigne des Pods directement, pour ceux qui n'ont pas de Service, comme le worker[^operateur] :

```yaml title="moniteurs.yaml"
# Ce que Prometheus doit collecter dans Colis : l'API par son Service, le worker par ses Pods
# (il n'a pas de Service : personne ne l'appelle).
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: api
  namespace: colis
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: api
  endpoints:
  - port: http          # nom du port du Service
    path: /metrics/
    interval: 15s
---
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: worker
  namespace: colis
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: worker
  podMetricsEndpoints:
  - port: metriques     # nom du port du conteneur
    interval: 15s
```

```bash
kubectl apply -f moniteurs.yaml
# une à deux minutes plus tard
curl -s localhost:9095/api/v1/targets | jq -r '.data.activeTargets[] | select(.labels.namespace == "colis")
  | "\(.scrapePool) \(.labels.pod) \(.health) \(.lastError)"'
```

```sortie
servicemonitor.monitoring.coreos.com/api created
podmonitor.monitoring.coreos.com/worker created
colis/api/0 api-68558b8b5-9nhnr down Get "http://10.244.0.71:8000/metrics/": context deadline exceeded
colis/api/0 api-68558b8b5-dplz4 down Get "http://10.244.0.72:8000/metrics/": context deadline exceeded
```

Les deux Pods de l'API sont découverts, et leur collecte échoue : `context deadline exceeded`, Prometheus a attendu 10 secondes sans réponse. La signature du chapitre 49 : une attente qui expire, pas un refus. Ce sont les NetworkPolicies du chapitre 41 : le refus par défaut du namespace `colis` bloque aussi Prometheus, qui vient du namespace `supervision`. Le worker n'apparaît pas encore : il est à zéro réplique au repos (KEDA, chapitre 31), donc sans Pod à collecter. On ouvre les deux ports de métriques, et seulement à Prometheus :

```yaml title="politique-supervision.yaml"
# Le refus par défaut du chapitre 41 bloque aussi Prometheus : on lui ouvre les deux ports de métriques.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: supervision
  namespace: colis
spec:
  podSelector:
    matchExpressions:
    - {key: app.kubernetes.io/name, operator: In, values: [api, worker]}
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: supervision
      podSelector:
        matchLabels:
          app.kubernetes.io/name: prometheus
    ports:
    - port: 8000
    - port: 9101
```

```bash
kubectl apply -f politique-supervision.yaml
```

```sortie
networkpolicy.networking.k8s.io/supervision created
colis/api/0 api-68558b8b5-9nhnr up 
colis/api/0 api-68558b8b5-dplz4 up 
```

## PromQL par l'exemple

Pour avoir des courbes, il faut du trafic qui dure. Lancez `charge.py --duree 330 --debit 8` dans un terminal, attendez cinq minutes, et interrogez Prometheus par son API (la fonction `q` du script de rejeu met en forme le JSON ; l'interface web, sur `http://localhost:9095`, accepte les mêmes requêtes).

**Les cibles de Colis répondent-elles ?** `up` est une série que Prometheus crée lui-même pour chaque cible : 1 si la dernière collecte a réussi, 0 sinon.

```sortie
namespace=colis pod=api-68558b8b5-dplz4 1
namespace=colis pod=api-68558b8b5-9nhnr 1
namespace=colis pod=worker-5d6d995cc5-9tx4z 1
namespace=colis pod=worker-5d6d995cc5-g9hdd 1
namespace=colis pod=worker-5d6d995cc5-c25x9 1
```

Le worker est apparu : la charge a rempli la file, KEDA a démarré trois workers, et le PodMonitor les a trouvés sans intervention.

**Combien de requêtes par seconde, par route et par code ?** Un compteur seul ne dit rien d'utile (« 4 213 requêtes depuis le démarrage »). On veut sa vitesse de croissance, que donne `rate()` : l'augmentation moyenne par seconde sur la fenêtre indiquée, ici 5 minutes. `rate()` détecte aussi les remises à zéro des compteurs quand un Pod redémarre. Puis `sum by` additionne les deux Pods :

```promql
sum by (route, code) (rate(colis_http_requetes_total{namespace="colis"}[5m]))
```

```sortie
code=200 route=/colis/{id_} 1.379
code=200 route=/colis 3.663
code=201 route=/colis 1.449
code=404 route=/colis/{id_} 0.779
```

Environ 7,3 requêtes par seconde au total, un peu moins que les 8 demandées à `charge.py` (chaque requête attend sa réponse avant la pause suivante), réparties selon son mélange.

**Quelle part d'erreurs ?** Un ratio de deux taux :

```promql
sum(rate(colis_http_requetes_total{namespace="colis", code="404"}[5m]))
  / sum(rate(colis_http_requetes_total{namespace="colis"}[5m]))
```

```sortie
0.107
```

**Quelle latence ?** Une moyenne masquerait les requêtes lentes, celles dont les utilisateurs se plaignent. On regarde les **centiles** : le 95e centile est la durée sous laquelle tombent 95 % des requêtes. `histogram_quantile()` l'estime à partir des buckets de l'histogramme, après les avoir additionnés entre Pods (l'étiquette `le` doit rester dans le `by`) :

```promql
histogram_quantile(0.95, sum by (le, route) (rate(colis_http_duree_secondes_bucket{namespace="colis"}[5m])))
```

```sortie
route=/colis/{id_} 0.005
route=/colis 0.019
```

Et la médiane (50e centile) :

```sortie
route=/colis/{id_} 0.003
route=/colis 0.004
```

C'est une **estimation**. Prometheus ne connaît pas les durées réelles, seulement combien de requêtes tombent dans chaque intervalle. Il trouve l'intervalle qui contient le 95e centile, puis suppose les observations réparties uniformément à l'intérieur et interpole[^histogrammes] :

<Figure svg={histogrammeCentile} num="50.2" alt="Les buckets cumulatifs de l'histogramme de la route /colis, mesurés sur 10 minutes : 944 requêtes en 5 ms ou moins, 1 148 en 10 ms ou moins, 1 330 en 25 ms ou moins et en 50 ms ou moins, sur 1 332. Le 95e centile se trouve dans l'intervalle de 10 à 25 ms : Prometheus place la valeur estimée par interpolation linéaire entre les deux bornes, selon la part manquante pour atteindre 95 %. La précision est celle de la largeur de l'intervalle.">
Comment <code>histogram_quantile</code> estime un centile : il repère le bucket qui contient le rang voulu, puis interpole linéairement entre ses bornes. La précision dépend du choix des buckets.
</Figure>

Conséquence pratique : choisissez les bornes des buckets autour des seuils qui vous intéressent. Si l'objectif est « 95 % des requêtes en moins de 500 ms », il faut une borne à 0,5 s. Le centile estimé ne sera jamais plus précis que la largeur de l'intervalle qui le contient.

**Combien de mémoire, face à ce qui est réservé ?** Les métriques de cAdvisor (par le kubelet) et de kube-state-metrics se combinent avec celles de l'application :

```promql
sum by (pod) (container_memory_working_set_bytes{namespace="colis", container!=""}) / 2^20
sum by (pod) (kube_pod_container_resource_requests{namespace="colis", resource="memory"}) / 2^20
```

```sortie
# mémoire utilisée (Mio)
pod=postgres-0 38.867
pod=redis-5cbb6759f7-2cjfs 9.066
pod=web-65cdb99b99-wctcb 17.262
pod=web-65cdb99b99-6ppdj 17.93
pod=api-68558b8b5-9nhnr 60.859
pod=api-68558b8b5-dplz4 61.18
pod=worker-5d6d995cc5-c25x9 3.793
# requests (Mio)
pod=postgres-0 128
pod=web-65cdb99b99-wctcb 32
pod=redis-5cbb6759f7-2cjfs 32
pod=web-65cdb99b99-6ppdj 32
pod=api-68558b8b5-dplz4 192
pod=api-68558b8b5-9nhnr 192
```

Les deux Pods de l'API utilisent un peu moins du tiers des 192 Mio qu'ils réservent ; Redis, un peu plus du quart de ses 32 Mio. Le worker n'a pas de request mémoire : il n'apparaît que dans la première liste. Ces écarts, mesurés sur plusieurs jours plutôt que cinq minutes, sont la base d'un bon dimensionnement (exercice 3). `container!=""` écarte une série que cAdvisor publie pour le Pod entier, en plus de chaque conteneur, et qui serait comptée deux fois.

**Le travail du worker :**

```promql
sum by (par) (increase(colis_estimes_total{namespace="colis"}[5m]))
```

```sortie
par=worker 324.25
```

`increase()` donne l'augmentation sur la fenêtre plutôt qu'un taux par seconde. Tous les colis ont été estimés par le worker, aucun par l'API : la file fonctionne.

**Et le coût de tout cela :**

```promql
count({__name__=~".+"})
count({__name__=~"colis_.+"})
```

```sortie
68011
131
réponses : 200 x1667, 201 x477, 404 x253
```

Près de soixante-dix mille séries actives pour un cluster d'un nœud, dont une centaine seulement pour Colis. L'essentiel vient du kubelet, de cAdvisor et de l'API server, qui publient de nombreux histogrammes. La mémoire de Prometheus suit à peu près le nombre de séries actives : c'est le chiffre à surveiller avant toute autre optimisation.

### Les règles d'enregistrement

Les requêtes de centiles parcourent tous les buckets de toutes les routes à chaque évaluation. Un tableau de bord rafraîchi toutes les 30 secondes par dix personnes les recalculerait sans cesse. Une **règle d'enregistrement** calcule une requête à intervalle régulier et range le résultat comme une nouvelle série, au nom conventionnel `niveau:métrique:opération`[^regles]. `regles.yaml` en définit deux, puis les alertes :

```yaml title="regles.yaml (règles d'enregistrement)"
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: colis
  namespace: colis
spec:
  groups:
  - name: colis.enregistrements
    rules:
    - record: colis:requetes:taux5m
      expr: sum by (namespace, route, code) (rate(colis_http_requetes_total{namespace="colis"}[5m]))
    - record: colis:latence:p95_5m
      expr: |
        histogram_quantile(0.95,
          sum by (namespace, le, route) (rate(colis_http_duree_secondes_bucket{namespace="colis"}[5m])))
```

```sortie
namespace=colis route=/colis/{id_} 0.005
namespace=colis route=/colis 0.019
```

Même résultat que la requête complète, pour le prix d'une lecture de série.

## Grafana

Prometheus a une interface, mais pas de tableaux de bord. Grafana interroge Prometheus et affiche des courbes ; le chart l'a installé avec Prometheus et Alertmanager déjà configurés comme sources de données, et une vingtaine de tableaux de bord sur le cluster. Son mot de passe d'administration a été tiré au hasard et rangé dans un Secret :

```bash
kubectl -n supervision get secret supervision-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl -n supervision port-forward svc/supervision-grafana 3050:80 &
```

L'interface est alors sur `http://localhost:3050`, utilisateur `admin`. Les tableaux de bord « Kubernetes / Compute Resources / Namespace (Pods) » et « Kubernetes / Compute Resources / Pod » répondent déjà à la plupart des questions sur la consommation.

Pour Colis, on pourrait dessiner un tableau de bord à la souris, puis l'exporter. Il vaut mieux le **versionner** comme le reste : le chart déploie à côté de Grafana un conteneur annexe qui surveille les ConfigMaps étiquetées `grafana_dashboard` dans tous les namespaces (c'est le réglage `searchNamespace: ALL` des valeurs) et charge le JSON qu'elles contiennent. `tableau-colis.yaml` décrit six panneaux : requêtes par route, part d'erreurs, 95e centile, file et nombre de workers, colis enregistrés et estimés, mémoire des conteneurs.

```bash
kubectl apply -f tableau-colis.yaml
curl -s -u admin:$MDP 'http://localhost:3050/api/search?query=Colis' | jq -c '.[] | {title, uid, url}'
curl -s -u admin:$MDP 'http://localhost:3050/api/search?type=dash-db' | jq length
curl -s -u admin:$MDP 'http://localhost:3050/api/datasources' | jq -c '.[] | {name, uid, url}'
```

```sortie
{"title":"Colis","uid":"colis","url":"/d/colis/colis"}
27
{"name":"Alertmanager","uid":"alertmanager","url":"http://supervision-kube-prometheu-alertmanager.supervision:9093/"}
{"name":"Prometheus","uid":"prometheus","url":"http://supervision-kube-prometheu-prometheus.supervision:9090/"}
```

Le tableau est à l'adresse `http://localhost:3050/d/colis/colis`. Modifié dans l'interface, il serait écrasé au prochain chargement de la ConfigMap : on modifie le fichier, on l'applique, et la modification passe en revue comme du code.

## Les alertes

Un tableau de bord ne sert que si quelqu'un le regarde. Une alerte va chercher quelqu'un. Le risque est inverse : trop d'alertes, et plus personne ne les lit. Le principe le plus utile est d'alerter sur les **symptômes**, ce que subissent les utilisateurs (erreurs, lenteur, travail qui n'avance pas), plutôt que sur les causes possibles (un processeur à 90 %, qui peut très bien ne gêner personne)[^sre]. Les trois alertes de `regles.yaml` suivent ce principe :

```yaml title="regles.yaml (alertes)"
  - name: colis.alertes
    rules:
    - alert: ColisErreursServeur
      expr: |
        sum by (namespace) (rate(colis_http_requetes_total{namespace="colis", code=~"5.."}[5m]))
          / sum by (namespace) (rate(colis_http_requetes_total{namespace="colis"}[5m])) > 0.05
      for: 2m
      labels:
        severite: page
      annotations:
        resume: "Plus de 5 % des requêtes de l'API échouent (5xx)"
        description: "{{ $value | humanizePercentage }} des requêtes en erreur sur 5 minutes."
    - alert: ColisLenteur
      expr: colis:latence:p95_5m{route!="inconnue"} > 0.5
      for: 5m
      labels:
        severite: ticket
      annotations:
        resume: "La route {{ $labels.route }} est lente"
        description: "95 % des requêtes en moins de {{ $value | humanizeDuration }}, au lieu de 0,5 s."
    - alert: ColisFileBloquee
      expr: max by (namespace) (colis_file_longueur{namespace="colis"}) > 20
      for: 2m
      labels:
        severite: page
      annotations:
        resume: "La file d'estimation ne se vide plus"
        description: "{{ $value }} colis attendent leur date de livraison."
```

Une alerte est une requête PromQL : chaque série qu'elle renvoie est une alerte active. `for` impose une durée avant de prévenir : la condition doit rester vraie à chaque évaluation pendant ce temps, sinon l'alerte retourne à l'état inactif. Entre les deux, elle est `pending`. Cela évite d'être réveillé par un pic de dix secondes. Les étiquettes (`severite`) servent au routage ; les annotations, au texte du message. Chaque expression garde l'étiquette `namespace` : on va voir pourquoi.

```bash
kubectl apply -f regles.yaml
kubectl -n colis get prometheusrules
curl -s localhost:9095/api/v1/rules | jq -r '.data.groups[] | select(.name | startswith("colis"))
  | .rules[] | "\(.type) \(.name) \(.health) \(.state // "-")"'
```

```sortie
NAME    AGE
colis   5m30s
alerting ColisErreursServeur ok inactive
alerting ColisLenteur ok inactive
alerting ColisFileBloquee ok inactive
recording colis:requetes:taux5m ok -
recording colis:latence:p95_5m ok -
```

Prometheus évalue les alertes, mais ne prévient personne : il transmet les alertes actives à **Alertmanager**, qui les regroupe, supprime les doublons, applique les silences et les envoie aux **récepteurs**. Pour l'exercice, un récepteur minimal, `pager.yaml`, écrit dans son journal ce qu'il reçoit ; dans la vraie vie, ce serait un service d'astreinte, une messagerie ou un courriel. L'AlertmanagerConfig dit où envoyer les alertes de Colis :

```yaml title="alertmanager-colis.yaml"
# Où envoyer les alertes de Colis. L'opérateur ajoute de lui-même le filtre namespace="colis" :
# cette configuration ne reçoit que les alertes de son namespace.
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: colis
  namespace: colis
spec:
  route:
    receiver: pager
    groupBy: [alertname]
    groupWait: 30s
    groupInterval: 2m
    repeatInterval: 4h
  receivers:
  - name: pager
    webhookConfigs:
    - url: http://pager.supervision.svc:8080/
      sendResolved: true
```

L'opérateur fusionne cet objet dans la configuration générale d'Alertmanager, en ajoutant de lui-même un filtre sur le namespace de l'objet. La configuration produite le montre :

```bash
kubectl apply -f pager.yaml -f alertmanager-colis.yaml
kubectl -n supervision get secret alertmanager-supervision-kube-prometheu-alertmanager-generated \
  -o jsonpath='{.data.alertmanager\.yaml\.gz}' | base64 -d | gunzip | sed -n '/^route:/,/^templates/p'
```

```sortie
configmap/pager created
deployment.apps/pager created
service/pager created
alertmanagerconfig.monitoring.coreos.com/colis created
route:
  receiver: "null"
  group_by:
  - namespace
  routes:
  - receiver: colis/colis/pager
    group_by:
    - alertname
    matchers:
    - namespace="colis"
    continue: true
    group_wait: 30s
    group_interval: 2m
    repeat_interval: 4h
  - receiver: "null"
    matchers:
    - alertname = "Watchdog"
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 12h
inhibit_rules:
- target_matchers:
  - severity =~ warning|info
  source_matchers:
  - severity = critical
  equal:
  - namespace
  - alertname
- target_matchers:
  - severity = info
  source_matchers:
  - severity = warning
  equal:
  - namespace
  - alertname
- target_matchers:
  - severity = info
  source_matchers:
  - alertname = InfoInhibitor
  equal:
```

Notre route n'accepte que `namespace="colis"`. Une alerte dont l'expression aurait perdu cette étiquette, avec un `sum()` sans `by (namespace)` par exemple, tomberait dans le récepteur `null` de la route par défaut, c'est-à-dire nulle part, sans aucun message d'erreur. Les règles d'inhibition, en dessous, viennent du chart : une alerte `critical` fait taire les alertes `warning` de même nom et de même namespace.

### Une alerte, du début à la fin

Pour déclencher `ColisFileBloquee` sans rien casser, on suspend KEDA (le worker reste à zéro), puis on enregistre 40 colis : ils s'accumulent dans la file.

```bash
kubectl -n colis annotate scaledobject worker autoscaling.keda.sh/paused=true
# 40 colis enregistrés par la passerelle, puis l'état de l'alerte toutes les 20 secondes
curl -s localhost:9095/api/v1/alerts | jq -r '.data.alerts[] | select(.labels.alertname == "ColisFileBloquee")
  | "\(.state) depuis \(.activeAt) valeur \(.value)"'
# une fois l'alerte en firing : ce qu'a reçu le récepteur, et ce qu'en dit Alertmanager
kubectl -n supervision logs deploy/pager
curl -s localhost:9094/api/v2/alerts | jq -c '.[] | {alerte: .labels.alertname, namespace: .labels.namespace,
  etat: .status.state, recepteurs: [.receivers[].name]}'
```

```sortie
scaledobject.keda.sh/worker annotated
40 colis enregistrés
07:48:50
07:49:10 pending depuis 2026-10-08T06:49:07.201605963Z valeur 4e+01
07:49:30 pending depuis 2026-10-08T06:49:07.201605963Z valeur 4e+01
07:49:50 pending depuis 2026-10-08T06:49:07.201605963Z valeur 4e+01
07:50:10 pending depuis 2026-10-08T06:49:07.201605963Z valeur 4e+01
07:50:30 pending depuis 2026-10-08T06:49:07.201605963Z valeur 4e+01
07:50:50 pending depuis 2026-10-08T06:49:07.201605963Z valeur 4e+01
07:51:10 firing depuis 2026-10-08T06:49:07.201605963Z valeur 4e+01
FIRING   ColisFileBloquee     page   40 colis attendent leur date de livraison.
{"alerte":"ColisFileBloquee","namespace":"colis","etat":"active","recepteurs":["colis/colis/pager"]}
{"alerte":"Watchdog","namespace":null,"etat":"active","recepteurs":["null"]}
```

La chronologie se lit ligne à ligne. Les colis sont enregistrés à 07:48:50 (heure locale, en avance d'une heure sur l'heure UTC qu'affiche Prometheus). Dix-sept secondes plus tard, à la première évaluation qui voit la file au-dessus de 20, l'alerte passe `pending`. Elle reste `pending` deux minutes (`for: 2m`), puis passe `firing`. Alertmanager attend encore `groupWait` (30 secondes) pour regrouper d'éventuelles alertes voisines, puis appelle le récepteur. L'alerte `Watchdog`, envoyée au récepteur `null`, est une alerte du chart qui sonne en permanence : si elle s'arrête un jour, c'est que la chaîne d'alertes elle-même est en panne, et un service extérieur peut le détecter.

On relâche KEDA :

```bash
kubectl -n colis annotate scaledobject worker autoscaling.keda.sh/paused-
# toutes les 20 secondes : nombre de workers et longueur de la file, puis le journal du récepteur
kubectl -n supervision logs deploy/pager
```

```sortie
scaledobject.keda.sh/worker annotated
07:51:56
07:52:16 workers=3 file=24
07:52:36 workers=3 file=0
07:52:56 workers= file=0
07:53:16 workers= file=0
07:53:37 workers= file=0
FIRING   ColisFileBloquee     page   40 colis attendent leur date de livraison.
RESOLVED ColisFileBloquee     page   35 colis attendent leur date de livraison.
```

KEDA démarre trois workers, la file se vide en moins d'une minute, et le récepteur reçoit la fin de l'alerte (`RESOLVED`, grâce à `sendResolved: true`). Le message de résolution reprend les annotations de la dernière évaluation où la condition était vraie : « 35 colis attendent », alors que la file est vide depuis longtemps quand le message arrive. C'est le comportement d'Alertmanager, à connaître pour ne pas mal lire un message de résolution.

## Ce que coûte la supervision

```bash
kubectl top pod -n supervision
docker stats --no-stream minikube --format '{{.MemUsage}}'
```

```sortie
alertmanager-supervision-kube-prometheu-alertmanager-0   1m    47Mi    
pager-846797c59b-mwz7m                                   1m    11Mi    
prometheus-supervision-kube-prometheu-prometheus-0       26m   502Mi   
supervision-grafana-596f55dcd4-grf4h                     20m   438Mi   
supervision-kube-prometheu-operator-76d74945df-t7xqf     4m    36Mi    
supervision-kube-state-metrics-c46cdbdbb-kb2t6           2m    28Mi    
supervision-prometheus-node-exporter-l9f2p               2m    15Mi    
3.593GiB / 4GiB
```

Prometheus et Grafana pèsent à eux deux près d'un gigaoctet, soit davantage que tout Colis. Sur un cluster réel, la supervision est souvent le plus gros consommateur après les applications elles-mêmes, et parfois avant. Les leviers, dans l'ordre : réduire le nombre de séries (étiquettes bornées, métriques inutiles abandonnées par `metricRelabelings`), la rétention, la fréquence de collecte. Pour garder des mois d'historique, on envoie les données vers un stockage dédié (Thanos, Mimir, VictoriaMetrics) plutôt que d'agrandir Prometheus.

## Exercices

:::exercice[Exercice 1 : le prix d'une étiquette]

Supposez que `route` contienne le chemin réel (`/colis/249`) au lieu du modèle. Combien de séries l'histogramme de durée produirait-il pour les lectures de colis, avec les colis actuellement en base ? Comparez avec le nombre de séries de durée d'aujourd'hui.

:::

<details>
<summary>Corrigé</summary>

```bash
# séries de durée aujourd'hui, au total et par Pod
curl -s localhost:9095/api/v1/query --data-urlencode 'query=count(colis_http_duree_secondes_bucket{namespace="colis"})'
curl -s localhost:9095/api/v1/query --data-urlencode 'query=count by (pod) (colis_http_duree_secondes_bucket{namespace="colis"})'
kubectl -n colis exec postgres-0 -- psql -U colis -d colis -Atc 'SELECT count(*) FROM colis'
```

```sortie
66
pod=api-68558b8b5-dplz4 33
pod=api-68558b8b5-9nhnr 33
1275
```

Aujourd'hui, chaque Pod publie 11 buckets (dix bornes et `+Inf`) pour chacune de ses combinaisons méthode et route, soit 66 séries de buckets au total. Avec le chemin réel, chaque colis lu créerait ses propres combinaisons : 11 buckets, plus `_sum` et `_count`, soit 13 séries par colis et par Pod qui l'a servi, sans compter les séries du compteur (une par code de réponse). Avec 1 275 colis en base et deux Pods, cela peut atteindre 1 275 × 13 × 2 = 33 150 séries, pour une seule route, et le nombre croît avec chaque colis enregistré. Il n'existe pas de « bonne » limite universelle, mais une étiquette dont les valeurs ne sont pas bornées (identifiant, adresse IP, nom d'utilisateur, URL complète) n'a pas sa place dans une métrique : elle va dans les journaux ou les traces.

</details>

:::exercice[Exercice 2 : un objectif de service]

L'équipe se fixe deux objectifs sur 30 jours : 99,5 % des requêtes sans erreur serveur, et 95 % des requêtes servies en moins de 25 ms. Écrivez les deux requêtes PromQL qui mesurent ces deux proportions (sur 30 minutes, faute d'historique). Testez-les. L'une d'elles cache un piège quand il n'y a eu aucune erreur.

:::

<details>
<summary>Corrigé</summary>

```promql
# disponibilité
1 - sum(increase(colis_http_requetes_total{namespace="colis", code=~"5.."}[30m]))
  / sum(increase(colis_http_requetes_total{namespace="colis"}[30m]))
# la même, robuste à l'absence d'erreur
1 - (sum(increase(colis_http_requetes_total{namespace="colis", code=~"5.."}[30m])) or vector(0))
  / sum(increase(colis_http_requetes_total{namespace="colis"}[30m]))
# part des requêtes en moins de 25 ms : un bucket divisé par le total
sum(rate(colis_http_duree_secondes_bucket{namespace="colis", le="0.025"}[30m]))
  / sum(rate(colis_http_duree_secondes_count{namespace="colis"}[30m]))
```

```sortie
# disponibilité
# disponibilité, avec or vector(0)
1
# part sous 25 ms
0.9996
```

La première requête ne renvoie **rien** : aucune requête n'a reçu de code 5xx, donc aucune série ne correspond au filtre, et une opération sur un ensemble vide donne un ensemble vide. Un tableau de bord afficherait « pas de données », une alerte ne se déclencherait jamais. `or vector(0)` remplace l'ensemble vide par zéro. La seconde mesure se lit directement dans un bucket, sans estimation, à condition que 25 ms soit une borne : c'est une raison de plus de choisir les buckets d'après les objectifs. L'écart entre l'objectif et la mesure s'appelle le **budget d'erreur** : avec 99,5 % sur 30 jours, l'équipe s'accorde 0,5 % de requêtes en échec, qu'elle peut dépenser en mises en production risquées tant qu'il en reste[^sre].

</details>

:::exercice[Exercice 3 : dimensionner d'après la mesure (programmation)]

Écrivez un script Python qui interroge l'API HTTP de Prometheus et affiche, pour chaque conteneur d'un namespace : le maximum de mémoire utilisée (`container_memory_working_set_bytes`) sur une période, la request et la limite de mémoire déclarées (kube-state-metrics), la part de la request réellement utilisée, et une recommandation : request absente, proche de la limite, ou à réduire (en proposant le maximum mesuré plus 20 %).

:::

<details>
<summary>Corrigé</summary>

Le corrigé, `corrige/dimensionner.py`, n'est pas dans l'archive. Il regroupe par **conteneur**, tous Pods confondus. Une première version, par Pod, affichait une quarantaine de lignes : en une heure, KEDA avait créé et supprimé des dizaines de Pods de worker, dont cAdvisor gardait les séries mais dont kube-state-metrics ne connaissait plus les requests. Les Pods d'un Deployment passent ; c'est son modèle de Pod qu'on dimensionne. Le cœur du script tient en quatre requêtes :

```python
utilise = requete(base, f'max by (container) (max_over_time('
                        f'container_memory_working_set_bytes{{namespace="{ns}", container!=""}}[{per}]))')
demande = requete(base, f'max by (container) (kube_pod_container_resource_requests'
                        f'{{namespace="{ns}", resource="memory"}})')
limite = requete(base, f'max by (container) (kube_pod_container_resource_limits'
                       f'{{namespace="{ns}", resource="memory"}})')
actuels = requete(base, f'count by (container) (kube_pod_container_info{{namespace="{ns}"}})')
```

```bash
python3 dimensionner.py colis --periode 1h
```

```sortie
CONTENEUR    PODS     MAX  REQUEST  LIMITE  UTILISÉ  PROPOSITION
api             2     72M     192M    256M     38%  request à ramener vers 87 Mio
postgres        1     45M     128M    256M     35%  request à ramener vers 54 Mio
redis           1     10M      32M    128M     33%  request à ramener vers 13 Mio
web             2     19M      32M     64M     58%  correct
worker          0     47M       0M      0M       -  aucun Pod en ce moment : requests inconnues
```

`max_over_time` prend le pic de chaque série sur la période, pas la moyenne : c'est le pic qui déclenche l'arrêt pour dépassement de mémoire. Le worker n'a aucun Pod au moment de la requête (KEDA l'a ramené à zéro) : sa consommation passée est connue, ses requests actuelles non. Une heure de mesure ne suffit pas pour décider : il faut couvrir les pics réels (une purge nocturne, un lundi matin), donc plusieurs jours ou semaines. C'est exactement ce que fait le VPA du chapitre 31 en mode recommandation, avec un historique plus long et des centiles plutôt que le maximum.

</details>

:::exercice[Exercice 4 : surveiller la surveillance]

Si Prometheus ne peut plus collecter l'API, les trois alertes de Colis ne se déclencheront jamais : sans données, pas d'erreurs ni de lenteur. Écrivez une alerte `ColisApiMuette` qui sonne quand aucune instance de l'API n'est collectée depuis une minute, que les cibles soient en échec ou qu'elles aient disparu. Testez-la en supprimant la NetworkPolicy `supervision`, puis en la remettant.

:::

<details>
<summary>Corrigé</summary>

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: colis-collecte
  namespace: colis
spec:
  groups:
  - name: colis.collecte
    rules:
    - alert: ColisApiMuette
      expr: (sum by (namespace) (up{namespace="colis", service="api"}) == 0) or absent(up{namespace="colis", service="api"})
      for: 1m
      labels:
        severite: page
        namespace: colis
      annotations:
        resume: "Prometheus ne collecte plus l'API de Colis"
        description: "Aucune instance de l'API ne répond à la collecte depuis 1 minute."
```

Deux cas, deux moitiés de l'expression. Si les cibles existent mais échouent, `up` vaut 0 et la somme aussi. Si elles ont disparu (Service supprimé, ServiceMonitor effacé), il n'y a plus de série `up` du tout, et seul `absent()` le détecte. Le `namespace` est ajouté en étiquette, puisque `absent()` ne garde que les étiquettes d'égalité de son filtre et que le routage en a besoin.

```bash
kubectl apply -f muette.yaml
kubectl -n colis delete networkpolicy supervision
```

```sortie
prometheusrule.monitoring.coreos.com/colis-collecte created
networkpolicy.networking.k8s.io "supervision" deleted from colis namespace
07:53:48
07:54:03 inactive up=1
07:54:18 pending up=0
07:54:33 pending up=0
07:54:48 pending up=0
07:55:04 pending up=0
07:55:19 firing up=0
RESOLVED ColisFileBloquee     page   35 colis attendent leur date de livraison.
FIRING   ColisApiMuette       page   Aucune instance de l'API ne répond à la collecte depuis 1 minute.
networkpolicy.networking.k8s.io/supervision created
RESOLVED ColisApiMuette       page   Aucune instance de l'API ne répond à la collecte depuis 1 minute.
```

`up` tombe à 0 à la première collecte qui expire, l'alerte passe `pending`, puis `firing` une minute plus tard, et le récepteur la reçoit. La NetworkPolicy remise, elle se résout. La même logique s'applique à la chaîne entière : la question « qui surveille Prometheus ? » a pour réponse habituelle un second Prometheus, ou le `Watchdog` relié à un service extérieur.

</details>

## Nettoyer

La pile de supervision reste installée : le chapitre 51 y branchera les journaux et les traces, et Grafana les affichera à côté des métriques. Colis reste en version 2.2, avec ses moniteurs, ses règles et son tableau de bord. On retire seulement ce qui ne sert qu'aux exercices :

```bash
kubectl -n colis delete prometheusrule colis-collecte --ignore-not-found
```

Interfaces, à ouvrir par redirection de port : Prometheus `http://localhost:9095`, Grafana `http://localhost:3050` (utilisateur `admin`, mot de passe dans le Secret `supervision-grafana`), Alertmanager `http://localhost:9094` :

```bash
kubectl -n supervision port-forward svc/supervision-kube-prometheu-prometheus 9095:9090 &
kubectl -n supervision port-forward svc/supervision-grafana 3050:80 &
kubectl -n supervision port-forward svc/supervision-kube-prometheu-alertmanager 9094:9093 &
```

Pour tout retirer plus tard : `helm -n supervision uninstall supervision`, puis les CRD `*.monitoring.coreos.com`, que Helm laisse en place.

[^prometheus]: Prometheus, « Overview » : modèle de données multidimensionnel, collecte par HTTP en mode pull, PromQL ; projet de la CNCF depuis 2016, deuxième après Kubernetes. [prometheus.io/docs/introduction/overview](https://prometheus.io/docs/introduction/overview/)
[^types]: Prometheus, « Metric types » : counter, gauge, histogram (buckets cumulatifs `le`, `_sum`, `_count`) et summary. [prometheus.io/docs/concepts/metric_types](https://prometheus.io/docs/concepts/metric_types/)
[^nommage]: Prometheus, « Metric and label naming » et « Instrumentation » : unités de base dans les noms (`_seconds`, `_total`), mise en garde contre les étiquettes à forte cardinalité (identifiants, adresses). [prometheus.io/docs/practices/naming](https://prometheus.io/docs/practices/naming/)
[^operateur]: Prometheus Operator, « Design » et référence de l'API : ServiceMonitor, PodMonitor, PrometheusRule, AlertmanagerConfig et l'ajout automatique d'un filtre sur le namespace. [prometheus-operator.dev/docs/getting-started/design](https://prometheus-operator.dev/docs/getting-started/design/)
[^histogrammes]: Prometheus, « Histograms and summaries » : estimation des centiles par `histogram_quantile` avec interpolation linéaire dans le bucket, erreur bornée par la largeur du bucket, choix des bornes autour des objectifs. [prometheus.io/docs/practices/histograms](https://prometheus.io/docs/practices/histograms/)
[^regles]: Prometheus, « Recording rules » et « Alerting rules » : convention de nommage `level:metric:operations`, clause `for`, états pending et firing. [prometheus.io/docs/prometheus/latest/configuration/recording_rules](https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/)
[^sre]: B. Beyer, C. Jones, J. Petoff, N. R. Murphy (dir.), *Site Reliability Engineering*, O'Reilly, 2016, chapitre 6 « Monitoring Distributed Systems » (les quatre signaux : latence, trafic, erreurs, saturation ; alerter sur les symptômes) et chapitre 3 « Embracing Risk » (budget d'erreur). [sre.google/sre-book/monitoring-distributed-systems](https://sre.google/sre-book/monitoring-distributed-systems/)
