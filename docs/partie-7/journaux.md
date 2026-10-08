---
title: Journaux et traces
sidebar_label: 51. Journaux et traces
description: "Les deux autres signaux : les journaux de tous les conteneurs dans Loki, collectés par OpenTelemetry, et les traces de Colis dans Tempo. LogQL, TraceQL, deux défauts d'instrumentation trouvés et corrigés (Colis 2.2.1), et une requête lente suivie de la courbe au verrou PostgreSQL qui la bloquait."
partie: 7
chapitre: '51'
---

import troisSignaux from '@site/src/figures/trois-signaux.svg';

```sortie
{"moment": "2026-10-08T08:29:59.565Z", "niveau": "info", "service": "api", "message": "requête", "methode": "GET", "chemin": "/colis", "route": "/colis", "code": 200, "duree_ms": 5930.9, "trace_id": "d785f93cb26d184f0003bffd9db16194", "span_id": "a77ccb4a2e7dcc5b"}
{"moment": "2026-10-08T08:29:59.569Z", "niveau": "info", "service": "api", "message": "requête", "methode": "GET", "chemin": "/colis", "route": "/colis", "code": 200, "duree_ms": 5884.7, "trace_id": "5386e02cf57ff44d34380f7b79474f21", "span_id": "33055cf65f68b42a"}
```

Deux requêtes, deux lignes de journal comme l'API en écrit des milliers. Celles-ci ont pris 5,9 secondes chacune, alors que leurs voisines répondent en quelques millisecondes. Les métriques du chapitre 50 n'en ont presque rien vu : le 95e centile de la route est resté à 21 ms. Pour comprendre ce qui est arrivé à ces deux requêtes-là, il faut deux autres outils. Les **journaux** disent ce qui s'est passé, requête par requête. Les **traces** disent où le temps s'est écoulé à l'intérieur de chacune. Et l'identifiant `trace_id`, présent dans les deux, permet de passer de l'un à l'autre.

Ce chapitre installe Loki pour les journaux et Tempo pour les traces, avec un collecteur OpenTelemetry qui alimente les deux. Puis il refait l'enquête de bout en bout. Les fichiers sont dans [l'archive journaux](pathname:///kits/journaux.tar.gz).

<Figure svg={troisSignaux} num="51.1" alt="À gauche, le Pod de l'API produit trois signaux : des compteurs et histogrammes sur /metrics/, une ligne JSON par requête avec trace_id sur sa sortie standard, et des spans par requête et par appel à PostgreSQL ou Redis grâce au SDK OpenTelemetry. Prometheus collecte /metrics/ directement. La sortie standard devient des fichiers sous /var/log/pods sur le nœud, que le collecteur OpenTelemetry lit avec filelog ; les traces lui arrivent en OTLP sur le port 4318. Le collecteur, un par nœud, ajoute namespace, Pod et Deployment, et envoie en OTLP les journaux à Loki et les traces à Tempo. Grafana interroge les trois : d'une courbe de latence, on choisit un intervalle, on y trouve les lignes lentes dans Loki, leur trace_id ouvre la trace dans Tempo, et la trace renvoie aux lignes qui portent son identifiant.">
Les trois signaux de Colis et leur chemin jusqu'à Grafana. Prometheus répond à « combien », Loki à « quoi », Tempo à « où » ; le <code>trace_id</code> relie les deux derniers.
</Figure>

## Faire de la place, encore

Le chapitre 50 a laissé un nœud presque plein. Avant d'ajouter trois composants, on regarde ce que coûte l'existant. Le plus gros poste de Prometheus n'est pas là où on l'attend :

```promql
count({__name__=~".+"})
sort_desc(count by (job) ({__name__=~".+"}))
```

```sortie
 68064
job=apiserver 44193
job=kubelet 8432
job=supervision-grafana 4191
job=kube-state-metrics 3365
```

L'API server publie à lui seul 44 000 séries sur 68 000, presque toutes des buckets d'histogrammes (durées et tailles des requêtes, par ressource, verbe et code), que personne ne regarde sur ce cluster. Grafana en publie 4 000 sur lui-même. Le fichier `valeurs-allegees.yaml` s'ajoute à celui du chapitre 50 : il supprime ces buckets à la collecte (`metricRelabelings` avec `action: drop`, en gardant celui dont se servent les alertes du chart), cesse de collecter Grafana, et remplace le conteneur annexe qui chargeait les sources de données par une déclaration directe, qui inclut déjà Loki et Tempo :

```yaml title="valeurs-allegees.yaml (extrait)"
# À ajouter aux valeurs du chapitre 50 avant d'installer Loki et Tempo :
# moins de séries dans Prometheus, un conteneur de moins dans Grafana, et les sources de données
# déclarées une fois pour toutes (Prometheus, Alertmanager, Loki, Tempo).
kubeApiServer:
  serviceMonitor:
    metricRelabelings:
    # les histogrammes de l'API server : 44 000 séries sur 68 000, que personne ne lit ici.
    # On garde apiserver_request_sli_duration_seconds, dont se servent les alertes du chart.
    - sourceLabels: [__name__]
      regex: (apiserver_(request_body_size_bytes|watch_events_dispatch_duration_seconds|request_duration_seconds|watch_list_duration_seconds|storage_list_duration_seconds|response_sizes|watch_cache_read_wait_seconds|watch_cache_initialization_duration_seconds|watch_events_sizes)|etcd_request_duration_seconds)_bucket
      action: drop
grafana:
  serviceMonitor:
    enabled: false        # les 4 000 séries de Grafana sur lui-même
  sidecar:
    datasources:
      enabled: false      # un conteneur annexe de moins : les sources sont déclarées ci-dessous
  datasources:
    datasources.yaml:
      apiVersion: 1
      datasources:
      - name: Prometheus
        uid: prometheus
        type: prometheus
        url: http://supervision-kube-prometheu-prometheus.supervision:9090/
        isDefault: true
      - name: Alertmanager
        uid: alertmanager
        type: alertmanager
        url: http://supervision-kube-prometheu-alertmanager.supervision:9093/
        jsonData: {implementation: prometheus}
      - name: Loki
        uid: loki
        type: loki
        url: http://loki.supervision:3100/
        jsonData:
          derivedFields:          # un trace_id dans une ligne de journal devient un lien vers Tempo
          - name: trace_id
            matcherType: regex
            matcherRegex: '"trace_id": "(\w+)"'
            datasourceUid: tempo
            url: $${__value.raw}
      - name: Tempo
        uid: tempo
        type: tempo
        url: http://tempo.supervision:3200/
        jsonData:
          tracesToLogsV2:         # d'une trace vers les lignes de journal qui portent son identifiant
            datasourceUid: loki
            filterByTraceID: true
            spanStartTimeShift: -5m
            spanEndTimeShift: 5m
          serviceMap:
            datasourceUid: prometheus
```

```bash
helm -n supervision upgrade supervision oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack --version 92.1.0 \
  -f ../metriques/valeurs-supervision.yaml -f valeurs-allegees.yaml --wait --timeout 10m
# sept minutes plus tard
```

```sortie
Release "supervision" has been upgraded. Happy Helming!
NAME                                  READY   STATUS    RESTARTS   AGE
supervision-grafana-f6fd9d8f6-n97xg   2/2     Running   0          38s
 39735
job=apiserver 19795
job=kubelet 8369
job=kube-state-metrics 3369
job=node-exporter 2463
```

Les séries passent de 68 000 à 40 000. La mémoire de Prometheus, elle, ne baisse pas tout de suite : les séries récentes restent dans son bloc en mémoire jusqu'à la prochaine compaction, toutes les deux heures. Sur un cluster réel, c'est le premier réglage à faire avant d'agrandir quoi que ce soit.

:::panne[Le nœud sature : processus tués, nœud NotReady, passerelle muette]

Même allégée, la pile complète (Prometheus, Grafana, Loki, Tempo, le collecteur) laisse peu de marge dans 4 Gio. Pendant la préparation de ce chapitre, une charge un peu soutenue a fait monter le HPA de l'API à six répliques, et le nœud a débordé. Le conteneur `minikube` a atteint sa limite, et le noyau y a tué des processus (54 fois en quelques minutes, d'après `memory.events`). Le kubelet n'a plus répondu à temps, et le nœud est passé `NotReady`. Envoy Gateway, cert-manager et KEDA ont perdu leur élection de leader et redémarré en boucle. La passerelle HTTPS est restée muette jusqu'au redémarrage de son proxy. Avec le pilote Docker, la limite du nœud est celle du conteneur, et `docker update` la change sans recréer le cluster :

```bash
docker update --memory 5g --memory-swap 5g minikube
minikube ssh -- cat /sys/fs/cgroup/memory.max
```

```sortie
5368709120
```

minikube n'en sait rien : la valeur se perd si le conteneur est recréé (`minikube delete`), pas lors d'un `minikube stop` suivi d'un `start`. Si votre poste ne peut pas donner un gigaoctet de plus, gardez Loki ou Tempo, pas les deux, ou retirez Grafana entre deux séances.

:::

## Loki et le collecteur

**Loki** stocke des journaux en ne les indexant que par quelques **étiquettes** (namespace, service, Pod), pas par leur contenu. Une recherche commence par choisir des flux d'après leurs étiquettes, puis lit les lignes de ces flux pour les filtrer. C'est moins rapide qu'un moteur qui indexe chaque mot, et beaucoup moins coûteux à stocker[^loki]. Le chart est installé en mode **monolithique**, un seul processus, avec un volume de 2 Gio et deux jours de rétention :

```yaml title="valeurs-loki.yaml (extrait)"
# Loki en un seul processus (« monolithique »), stockage sur un volume, deux jours de rétention.
deploymentMode: Monolithic
loki:
  auth_enabled: false            # un seul « locataire » ; en production, un en-tête X-Scope-OrgID par équipe
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  schemaConfig:
    configs:
    - from: "2026-01-01"
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h
  limits_config:
    retention_period: 48h
    allow_structured_metadata: true
  compactor:
    retention_enabled: true
    delete_request_store: filesystem
  pattern_ingester:
    enabled: false
singleBinary:
  replicas: 1
  persistence:
    enabled: true
    size: 2Gi
  resources:
    requests: {cpu: 50m, memory: 128Mi}
    limits: {memory: 384Mi}
read: {replicas: 0}
write: {replicas: 0}
backend: {replicas: 0}
chunksCache: {enabled: false}
resultsCache: {enabled: false}
gateway: {enabled: false}
lokiCanary: {enabled: false}
test: {enabled: false}
```

Pour faire arriver les journaux, il faut un agent sur chaque nœud qui lise les fichiers que le kubelet écrit sous `/var/log/pods` (chapitre 48). On utilise le **collecteur OpenTelemetry**, en DaemonSet, parce qu'il saura aussi recevoir les traces : un seul agent pour deux signaux. Son préréglage `logsCollection` configure le récepteur `filelog` et le montage des fichiers du nœud ; `kubernetesAttributes` ajoute à chaque ligne le namespace, le Pod, le Deployment, d'après l'adresse du Pod ou le chemin du fichier[^collecteur]. Le reste de la configuration décrit deux chaînes, une par signal :

```yaml title="valeurs-collecteur.yaml (extrait)"
# Le collecteur OpenTelemetry, un par nœud : il lit les journaux des conteneurs sur le disque du nœud
# et reçoit les traces des applications, ajoute les attributs Kubernetes, et envoie le tout à Loki et Tempo.
mode: daemonset
fullnameOverride: collecteur
image:
  repository: otel/opentelemetry-collector-k8s
presets:
  logsCollection:
    enabled: true          # récepteur filelog sur /var/log/pods
  kubernetesAttributes:
    enabled: true          # namespace, Pod, Deployment, nœud ajoutés à chaque donnée
service:
  enabled: true            # un Service « collecteur » pour que les applications envoient leurs traces
resources:
  requests: {cpu: 20m, memory: 64Mi}
  limits: {memory: 256Mi}
config:
  receivers:
    jaeger: null
    zipkin: null
    prometheus: null
    filelog:
      # pas les journaux de la supervision elle-même (dont ceux du collecteur : sinon, une boucle)
      exclude:
      - /var/log/pods/supervision_*/*/*.log
  exporters:
    otlphttp/loki:
      endpoint: http://loki.supervision:3100/otlp
    otlp/tempo:
      endpoint: tempo.supervision:4317
      tls:
        insecure: true
  service:
    pipelines:
      logs:
        receivers: [filelog]
        processors: [memory_limiter, k8sattributes, batch]
        exporters: [otlphttp/loki]
      traces:
        receivers: [otlp]
        processors: [memory_limiter, k8sattributes, batch]
        exporters: [otlp/tempo]
      metrics: null
```

On exclut les journaux du namespace `supervision` : le collecteur lirait les siens, les enverrait à Loki, qui en produirait d'autres, et ainsi de suite. Les trois installations :

```bash
helm install loki oci://ghcr.io/grafana-community/helm-charts/loki --version 18.14.0 -n supervision -f valeurs-loki.yaml --wait
helm install tempo oci://ghcr.io/grafana-community/helm-charts/tempo --version 3.1.0 -n supervision -f valeurs-tempo.yaml --wait
helm install collecteur oci://ghcr.io/open-telemetry/opentelemetry-helm-charts/opentelemetry-collector --version 0.175.1 \
  -n supervision -f valeurs-collecteur.yaml --wait
kubectl -n supervision get pods
```

```sortie
NAME                                                     READY   STATUS    RESTARTS   AGE
alertmanager-supervision-kube-prometheu-alertmanager-0   2/2     Running   0          73m
collecteur-agent-nqxnc                                   1/1     Running   0          71s
loki-0                                                   2/2     Running   0          4m15s
pager-846797c59b-mwz7m                                   1/1     Running   0          32m
prometheus-supervision-kube-prometheu-prometheus-0       2/2     Running   0          73m
supervision-grafana-f6fd9d8f6-n97xg                      2/2     Running   0          12m
supervision-kube-prometheu-operator-76d74945df-t7xqf     1/1     Running   0          74m
supervision-kube-state-metrics-c46cdbdbb-kb2t6           1/1     Running   0          74m
supervision-prometheus-node-exporter-l9f2p               1/1     Running   0          74m
tempo-0                                                  1/1     Running   0          2m29s
```

Les charts de Loki et Tempo utilisés ici sont ceux du dépôt `grafana-community`, publié aussi en OCI sur ghcr.io. Dans le dépôt historique `grafana.github.io`, les charts `tempo` et `grafana` sont désormais marqués obsolètes, et leurs nouvelles versions paraissent dans `grafana-community`.

### Ce que Loki a reçu

```bash
kubectl -n supervision port-forward svc/loki 3101:3100 &
curl -s localhost:3101/loki/api/v1/labels | jq -c .data
curl -s localhost:3101/loki/api/v1/label/service_name/values | jq -c .data
```

```sortie
["k8s_container_name","k8s_daemonset_name","k8s_deployment_name","k8s_namespace_name","k8s_pod_name","k8s_replicaset_name","k8s_statefulset_name","service_instance_id","service_name","service_namespace"]
["api","cert-manager","coredns","csi-hostpath-attacher","csi-hostpath-resizer","eg","envoy","etcd","hostpath.csi.k8s.io","keda","kindnet","kube-apiserver","kube-controller-manager","metrics-server","postgres","redis","snapshot-controller","speaker","storage-provisioner","web","worker"]
```

Les étiquettes viennent des attributs que le collecteur a posés : `service_name` vaut le nom du conteneur, `service_namespace` son namespace. Loki a tout reçu, y compris les journaux du plan de contrôle (`etcd`, `kube-controller-manager`). Les flux de l'API, et le nombre total de flux sur 15 minutes :

```sortie
{"service_name":"api","service_namespace":"colis","k8s_container_name":"api","k8s_deployment_name":"api","k8s_namespace_name":"colis","k8s_pod_name":"api-c868785dc-4z52n","service_instance_id":"colis.api-c868785dc-4z52n.api"}
58
```

Une poignée d'étiquettes, une vingtaine de flux pour tout le cluster. Le nom du Pod n'est pas une étiquette d'index : Loki le range en **métadonnées structurées**, attachées à chaque ligne sans multiplier les flux. C'est la même règle que pour les métriques : chaque combinaison d'étiquettes crée un flux, avec son index et ses morceaux de stockage, et une étiquette à valeurs non bornées (un identifiant de requête, une adresse) le ferait exploser.

### LogQL

On interroge Loki en **LogQL**, qui ressemble à PromQL : un sélecteur de flux entre accolades, puis une chaîne de filtres et d'analyseurs[^logql]. Les deux dernières lignes de l'API :

```logql
{service_name="api"}
```

```sortie
{"moment": "2026-10-08T08:25:46.439Z", "niveau": "info", "service": "colis", "message": "requête", "methode": "GET", "chemin": "/colis", "route": "/colis", "code": 200, "duree_ms": 3.5}
{"moment": "2026-10-08T08:25:46.701Z", "niveau": "info", "service": "colis", "message": "requête", "methode": "GET", "chemin": "/colis/1986", "route": "/colis/{id_}", "code": 200, "duree_ms": 3.0}
```

L'analyseur `json` transforme les champs de la ligne en étiquettes temporaires, sur lesquelles on filtre :

```logql
{service_name="api"} | json | code >= 400
```

```sortie
{"moment": "2026-10-08T08:25:39.848Z", "niveau": "info", "service": "colis", "message": "requête", "methode": "GET", "chemin": "/colis/997189", "route": "/colis/{id_}", "code": 404, "duree_ms": 3.6}
{"moment": "2026-10-08T08:25:40.112Z", "niveau": "info", "service": "colis", "message": "requête", "methode": "GET", "chemin": "/colis/924431", "route": "/colis/{id_}", "code": 404, "duree_ms": 2.4}
{"moment": "2026-10-08T08:25:41.189Z", "niveau": "info", "service": "colis", "message": "requête", "methode": "GET", "chemin": "/colis/957237", "route": "/colis/{id_}", "code": 404, "duree_ms": 2.6}
```

Et comme en PromQL, on peut **compter** : LogQL fabrique des métriques à partir des lignes, au moment de la requête. Les réponses par code sur cinq minutes, d'abord :

```logql
sum by (code) (count_over_time({service_name="api"} | json [5m]))
```

```sortie
pipeline error: 'JSONParserErr' for series: '{__error__="JSONParserErr", __error_details__="Value looks like object, but can't find closing '}' symbol", container_image_name="host.minikube.internal:5001/colis/api", detected_level="info", ...
```

La requête échoue entièrement. Toutes les lignes de l'API ne sont pas du JSON : Uvicorn écrit en texte ses messages de démarrage et d'arrêt, et l'analyseur `json` marque ces lignes d'une étiquette `__error__`. Une requête de type métrique refuse de mélanger lignes valides et lignes en erreur. On les retrouve avec `| json | __error__!=""` :

```sortie
INFO:     Shutting down || Value looks like object, but can't find closing '}' symbol
INFO:     Waiting for application shutdown. || Value looks like object, but can't find closing '}' symbol
INFO:     Application shutdown complete. || Value looks like object, but can't find closing '}' symbol
INFO:     Finished server process [1] || Value looks like object, but can't find closing '}' symbol
```

et on les écarte avec `__error__=""` juste après l'analyseur. Voici les réponses par code, le 95e centile des durées lues dans les lignes (`unwrap` prend la valeur d'un champ), et le volume de journaux par service :

```logql
sum by (code) (count_over_time({service_name="api"} | json | __error__="" [5m]))
quantile_over_time(0.95, {service_name="api"} | json | __error__="" | unwrap duree_ms [5m]) by (route)
sum by (service_name) (bytes_over_time({k8s_namespace_name="colis"}[5m]))
```

```sortie
# réponses par code
 6
code=200 293
code=201 76
code=404 53
# p95 par route
route=/colis 16.02
route=/colis/{id_} 4.18
# volume par service
service_name=api 110768
service_name=postgres 374
service_name=redis 445
service_name=web 11400
service_name=worker 22488
```

La première ligne, sans étiquette `code`, compte les lignes JSON qui ne décrivent pas une requête : le message « traces actives » qu'écrit chaque Pod au démarrage.

Ce 95e centile est **exact** : calculé sur toutes les durées réelles, pas estimé à partir de buckets comme au chapitre 50. Il est aussi beaucoup plus coûteux, puisque Loki relit chaque ligne. Les métriques restent l'outil des tableaux de bord et des alertes, les journaux celui de l'enquête.

## Les traces

Une **trace** est l'histoire d'une requête. Elle est faite de **spans** : chacun est une opération (traiter la requête HTTP, exécuter une requête SQL, écrire dans Redis) avec son début, sa durée, ses attributs, et l'identifiant de son parent. Tous les spans d'une même requête portent le même `trace_id`. Quand une requête traverse plusieurs services, le contexte (identifiant de trace, identifiant du span parent) voyage avec elle, dans l'en-tête HTTP standard `traceparent` du W3C[^w3c]. C'est la **propagation de contexte**.

Colis 2.2 sait produire des traces grâce au SDK OpenTelemetry et à ses **instrumentations** automatiques pour FastAPI, psycopg et Redis. Il ne le fait que si `OTEL_EXPORTER_OTLP_ENDPOINT` est défini. **Tempo** les stocke, en un seul processus lui aussi (`valeurs-tempo.yaml`). On donne aux services les mêmes noms que ceux que le collecteur donne à leurs journaux :

```bash
bash activer-traces.sh
# du trafic, puis, une minute plus tard :
curl -s -G localhost:3201/api/search --data-urlencode 'q={ resource.service.name = "api" }' | jq '.traces | length'
kubectl -n colis logs deploy/api | grep -v '^{' | grep -v '^INFO:' | head -4
```

```sortie
deployment.apps/api env updated
deployment.apps/worker env updated
Waiting for deployment "api" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "api" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "api" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "api" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "api" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "api" rollout to finish: 1 old replicas are pending termination...
deployment "api" successfully rolled out
20
Failed to export spans batch due to timeout, max retries or shutdown.
Failed to export spans batch due to timeout, max retries or shutdown.
Failed to export spans batch due to timeout, max retries or shutdown.
Failed to export spans batch due to timeout, max retries or shutdown.
```

Aucune trace, et le SDK le dit dans le journal : il n'arrive pas à exporter. On connaît cette signature depuis le chapitre 50 : le refus par défaut du chapitre 41 bloque aussi les **sorties** des Pods de Colis, et rien n'autorise l'API à joindre le collecteur. Cette fois, c'est une règle `Egress` qu'il faut :

```yaml title="politique-traces.yaml"
# Le refus par défaut du chapitre 41 bloque aussi les sorties : l'API et le worker
# doivent pouvoir envoyer leurs traces au collecteur, et à lui seul.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: traces
  namespace: colis
spec:
  podSelector:
    matchExpressions:
    - {key: app.kubernetes.io/name, operator: In, values: [api, worker]}
  policyTypes: [Egress]
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: supervision
      podSelector:
        matchLabels:
          app.kubernetes.io/name: opentelemetry-collector
    ports:
    - port: 4318
```

```bash
kubectl apply -f politique-traces.yaml
kubectl -n colis rollout restart deployment/api deployment/worker
curl -s -G localhost:3201/api/search --data-urlencode 'q={ resource.service.name = "api" }' --data-urlencode limit=4 \
  | jq -r '.traces[] | "\(.traceID) \(.rootServiceName) \(.rootTraceName) \(.durationMs // 0) ms"'
```

```sortie
networkpolicy.networking.k8s.io/traces created
deployment.apps/api restarted
deployment.apps/worker restarted
f4953c3a5d3541cd3e87ee298f8d0fbb api PING 0 ms
6b9bcf1d0b15c1e6f5ee52c9c2f7cb28 api LLEN 0 ms
746f5ad6e0ff2da7e69fe686d07d8889 api PING 1 ms
188d835bcae90f4eaf27fc9afaa9720 api PING 0 ms
```

Des traces arrivent, mais pas celles qu'on attendait : `PING`, `LLEN`. Et quand on ouvre la trace d'un enregistrement, avec le petit script `arbre-trace.py` du kit qui l'affiche en arbre :

```sortie
POST /colis                                    api     +     0.0 ms       9.0 ms  /colis
  POST /colis http receive                     api     +     0.7 ms       0.0 ms  
  RPUSH                                        api     +     5.7 ms       1.1 ms  RPUSH ? ?
  POST /colis http send                        api     +     8.4 ms       0.0 ms  
  POST /colis http send                        api     +     8.8 ms       0.0 ms  
  POST /colis http send                        api     +     8.9 ms       0.0 ms  
```

Le span racine `POST /colis` (la requête HTTP), ses étapes internes (`http receive`, `http send`, posées par l'instrumentation ASGI), l'écriture dans Redis (`RPUSH`)... et rien pour PostgreSQL. L'insertion du colis, qui est pourtant la moitié du travail, n'apparaît pas. Le journal de la même requête porte bien le même `trace_id` :

```sortie
{"moment": "2026-10-08T08:27:29.087Z", "niveau": "info", "service": "api", "message": "requête", "methode": "POST", "chemin": "/colis", "route": "/colis", "code": 201, "duree_ms": 7.5, "trace_id": "001ce43ecbcfae8964e2bd3fe56117a7", "span_id": "25e9f89a05575760"}
```

Comptons les traces par nom de span racine, sur les dernières minutes :

```sortie
     26 GET
      6 PING
      5 POST
      3 LLEN
     14 estimer un
      7 BLPOP 0
      3 BLPOP 2008
```

### Deux défauts d'instrumentation

Ces chiffres trahissent deux défauts dans Colis 2.2, du genre qu'on ne découvre qu'en regardant de vraies traces.

**Les requêtes SQL manquent.** L'instrumentation de psycopg fonctionne en remplaçant la fonction `psycopg.connect` : une connexion ouverte **après** l'activation produit des spans, une connexion ouverte **avant** n'en produira jamais. Or Colis ouvre sa connexion en créant son stockage, à l'import du module, puis active les traces. Dans le worker, même chose. Le script `ordre-des-traces.py` du kit isole le phénomène : il ouvre une connexion avant ou après l'activation, puis exécute la même lecture dans un span, avec un exportateur en mémoire.

```bash
A=$(kubectl -n colis get pods -l app.kubernetes.io/name=api -o name | head -1)
for o in connexion-avant connexion-apres; do
  kubectl -n colis exec -i $A -- sh -c "cd /app && python - $o" < ordre-des-traces.py
done
```

```sortie
connexion-avant  spans : ['requête']
connexion-apres  spans : ['CREATE', 'SELECT', 'requête']
```

L'ordre des deux lignes suffit à tout perdre. Pire, le défaut est intermittent : quand la connexion se coupe et que Colis la rouvre (chapitre 26), la nouvelle connexion est instrumentée, et des spans SQL réapparaissent sans qu'on comprenne pourquoi.

**Des traces parasites.** Les `PING` viennent de la sonde `/pret`, exclue des traces HTTP mais pas des appels Redis qu'elle fait : sans span parent, chaque `PING` devient la racine d'une trace. Les `LLEN` viennent de la jauge `colis_file_longueur`, lue dans Redis à chaque collecte de Prometheus, toutes les 15 secondes. Et le worker, qui attend la file par `BLPOP` avec un délai de 2 secondes, produit une trace toutes les 2 secondes, qu'il y ait du travail ou non. Ces traces ne disent rien d'utile, mais elles se stockent et se paient.

Le correctif, Colis **2.2.1**, est dans le kit sous forme de patch (dix blocs de modification). Il active les traces avant toute connexion, et entoure la lecture de la jauge et l'attente du worker par `suppress_instrumentation()`, qui coupe les instrumentations le temps d'un bloc :

```diff title="colis-2.2.1.patch (extrait)"
--- a/app/colis/app.py
+++ b/app/colis/app.py
@@ -15,7 +15,7 @@
 from .file import File
 from .modele import Colis, NouveauColis
 from .observabilite import (DUREE, ENREGISTRES, ESTIMES, LIVRES, REQUETES, configurer_traces,
-                            journal, mesurer_file)
+                            instrumenter_app, journal, mesurer_file)
 from .stockage import Stockage
 
 VERSION = os.environ.get("COLIS_VERSION", "1.0.0")
@@ -112,6 +112,8 @@
     return app
 
 
+traces = configurer_traces()          # avant stockage_depuis_env(), qui ouvre la connexion
 app = creer_app(stockage_depuis_env(), file_depuis_env())
-if configurer_traces(app):
+if traces:
+    instrumenter_app(app)
     log.info("traces actives", extra={"champs": {"collecteur": os.environ["OTEL_EXPORTER_OTLP_ENDPOINT"]}})
--- a/app/colis/worker.py
+++ b/app/colis/worker.py
@@ -13,7 +13,7 @@
 
 from .config import file_depuis_env, stockage_depuis_env
 from .delais import VilleInconnue, date_estimee, jours_de_livraison
-from .observabilite import ESTIMES, configurer_traces, journal, mesurer_file
+from .observabilite import ESTIMES, configurer_traces, journal, mesurer_file, sans_traces
 
 log = journal("colis.worker")
 traceur = trace.get_tracer("colis.worker")
@@ -30,6 +30,7 @@
 def main() -> int:
     signal.signal(signal.SIGTERM, arreter)
     signal.signal(signal.SIGINT, arreter)
+    configurer_traces()          # avant d'ouvrir les connexions à Redis et PostgreSQL
     file = file_depuis_env()
     if file is None:
         log.error("COLIS_REDIS n'est pas défini : le worker n'a pas de file à lire")
@@ -41,10 +42,10 @@
     # métriques du worker sur un port à lui (le worker n'a pas de serveur HTTP)
     start_http_server(int(os.environ.get("COLIS_METRIQUES_PORT", "9101")))
     mesurer_file(file)
-    configurer_traces()
     log.info(f"worker {nom} prêt (stockage : {stockage.nom})")
     while continuer:
-        id_ = file.prendre(attente_s=2)
+        with sans_traces():      # attendre la file n'est pas un travail : pas de trace
+            id_ = file.prendre(attente_s=2)
         if id_ is None:
             continue
         with traceur.start_as_current_span("estimer un colis", attributes={"colis.id": id_}):
```

```bash
patch -p1 -d colis-2.2 < colis-2.2.1.patch
docker buildx build --builder cours -t localhost:5001/colis/api:2.2.1 --push colis-2.2/app
bash passer-en-2.2.1.sh
```

Les mêmes requêtes, après le correctif. Un enregistrement, une lecture, et une estimation par le worker :

```sortie
# arbre-trace.py 1ca3703b3f9eb59d72e9e1d42d4f7f34
POST /colis                                    api     +     0.0 ms       7.8 ms  /colis
  POST /colis http receive                     api     +     0.5 ms       0.0 ms  
  INSERT                                       api     +     1.5 ms       3.2 ms  INSERT INTO colis (destinataire, depart, arrivee, poids_kg, 
  RPUSH                                        api     +     5.0 ms       0.7 ms  RPUSH ? ?
  POST /colis http send                        api     +     7.1 ms       0.0 ms  
  POST /colis http send                        api     +     7.5 ms       0.0 ms  
  POST /colis http send                        api     +     7.7 ms       0.0 ms  
# arbre-trace.py b01f0a64523650473339cd81c020758
GET /colis/{id_}                               api     +     0.0 ms       5.8 ms  /colis/{id_}
  SELECT                                       api     +     1.5 ms       1.4 ms  SELECT id, destinataire, depart, arrivee, poids_kg, statut, 
  GET /colis/{id_} http send                   api     +     4.8 ms       0.1 ms  
  GET /colis/{id_} http send                   api     +     5.4 ms       0.0 ms  
  GET /colis/{id_} http send                   api     +     5.7 ms       0.0 ms  
# arbre-trace.py 8c6b05b9fc1c39e9556d026958e9e8f
estimer un colis                               worker  +     0.0 ms     515.8 ms  
  SELECT                                       worker  +     0.1 ms       2.2 ms  SELECT id, destinataire, depart, arrivee, poids_kg, statut, 
  UPDATE                                       worker  +   503.0 ms      12.4 ms  UPDATE colis SET livraison_estimee = %s, statut = CASE WHEN 
# racines
     21 GET
      8 SELECT
      8 PING
      2 POST
      1 LLEN
     12 estimer un colis
      1 CREATE 0 ms
```

Les requêtes SQL apparaissent, avec leur texte (paramètres masqués), sous le span de la requête HTTP. Le worker n'a plus que des traces `estimer un colis`, avec leur lecture et leur écriture en base, et plus aucun `BLPOP`. Dans le décompte, `PING` et `SELECT` viennent de la sonde `/pret`, qui interroge Redis et PostgreSQL : ce sont des appels réels, faits par une requête qu'on a choisi de ne pas tracer, d'où des spans orphelins. Les exclure demanderait d'entourer le corps de `/pret` du même `suppress_instrumentation()`. `CREATE` est la création du schéma au démarrage du Pod. Le dernier `LLEN` date des derniers instants d'un Pod encore en 2.2 : l'attribut `service.version` de sa trace l'indique. Une dernière remarque : la trace du worker est séparée de celle de la requête qui a déposé le colis. La file ne transporte que l'identifiant du colis, pas le contexte de trace ; l'exercice 3 corrige cela.

## Corréler une requête lente

Reprenons l'enquête du début. Pendant une charge régulière de huit requêtes par seconde (deux exemplaires de `charge.py`), quelqu'un pose sur la table `colis` un verrou exclusif pendant six secondes. Cela se produit, par exemple, avec une migration de schéma (`ALTER TABLE`) lancée en pleine journée. À la troisième seconde, on regarde ce qu'attend PostgreSQL :

```bash
kubectl -n colis exec postgres-0 -- psql -U colis -d colis -c \
  "BEGIN; LOCK TABLE colis IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(6); COMMIT;" &
sleep 3
kubectl -n colis exec postgres-0 -- psql -U colis -d colis -c "SELECT pid, state, wait_event_type AS attente,
  wait_event, now() - query_start AS depuis, left(query, 50) AS requete FROM pg_stat_activity
  WHERE datname = 'colis' AND pid <> pg_backend_pid() ORDER BY query_start"
```

```sortie
  pid  | state  | attente | wait_event |     depuis      |                      requete                       
-------+--------+---------+------------+-----------------+----------------------------------------------------
 32356 | idle   | Client  | ClientRead | 00:00:04.2822   | UPDATE colis SET livraison_estimee = $1, statut = 
 32357 | idle   | Client  | ClientRead | 00:00:04.017426 | UPDATE colis SET livraison_estimee = $1, statut = 
 32237 | idle   | Client  | ClientRead | 00:00:03.206408 | INSERT INTO colis (destinataire, depart, arrivee, 
 32387 | active | Timeout | PgSleep    | 00:00:03.015488 | BEGIN; LOCK TABLE colis IN ACCESS EXCLUSIVE MODE; 
 32245 | active | Lock    | relation   | 00:00:02.932961 | SELECT id, destinataire, depart, arrivee, poids_kg
 32348 | active | Lock    | relation   | 00:00:02.69222  | UPDATE colis SET livraison_estimee = $1, statut = 
(6 rows)
```

Dans la vraie vie, on ne regarderait pas `pg_stat_activity` à la bonne seconde : on découvrirait le problème après coup. Reprenons donc dans l'ordre d'une enquête.

**Les métriques.** Le 95e centile de la route `/colis`, au plus haut sur dix minutes, et le nombre de requêtes de plus de 2,5 secondes, qu'on lit directement dans les buckets :

```promql
max_over_time(colis:latence:p95_5m{route="/colis"}[10m])
sum(increase(colis_http_duree_secondes_count{namespace="colis"}[10m]))
  - sum(increase(colis_http_duree_secondes_bucket{namespace="colis", le="2.5"}[10m]))
```

```sortie
p95 maximal de /colis sur 10 min : 0.02135971969145249
requêtes de plus de 2,5 s sur 10 min : 2.1627636363637066
```

C'est la limite des centiles : quelques requêtes bloquées parmi des centaines ne déplacent pas le 95e centile. Le second chiffre, deux requêtes et une fraction, n'est pas entier parce que `increase()` extrapole (exercice 1). Elles se voient dans le compte des requêtes qui dépassent un seuil, et c'est ce qu'il faut surveiller pour les attraper.

**Les journaux.** LogQL retrouve les requêtes de plus d'une seconde, et chacune donne son `trace_id` :

```logql
sum by (route) (count_over_time({service_name="api"} | json | __error__="" | duree_ms > 1000 [5m]))
{service_name="api"} | json | duree_ms > 1000
```

```sortie
# requêtes de plus d'une seconde, par route
route=/colis 2
{"moment":"2026-10-08T08:29:59.565Z","methode":"GET","chemin":"/colis","code":200,"duree_ms":5930.9,"trace_id":"d785f93cb26d184f0003bffd9db16194"}
{"moment":"2026-10-08T08:29:59.569Z","methode":"GET","chemin":"/colis","code":200,"duree_ms":5884.7,"trace_id":"5386e02cf57ff44d34380f7b79474f21"}
```

**La trace.** L'identifiant de la plus lente ouvre sa trace :

```sortie
GET /colis                                     api     +     0.0 ms    5932.0 ms  /colis
  SELECT                                       api     +     1.2 ms    5927.8 ms  SELECT id, destinataire, depart, arrivee, poids_kg, statut, 
  GET /colis http send                         api     +  5931.7 ms       0.1 ms  
  GET /colis http send                         api     +  5931.9 ms       0.0 ms  
  GET /colis http send                         api     +  5932.0 ms       0.0 ms  
```

Tout le temps est dans un seul span : la requête SQL, qui a attendu. Le span HTTP la contient, les autres étapes prennent quelques millisecondes. On saurait maintenant quoi chercher côté base : un verrou, à cette heure-là. **TraceQL**, le langage de recherche de Tempo, permet aussi de partir directement des traces : toutes celles de l'API de plus d'une seconde, ou tous les spans PostgreSQL de plus d'une seconde, quel que soit le service[^traceql] :

```
{ resource.service.name = "api" && duration > 1s }
{ span.db.system = "postgresql" && duration > 1s }
```

```sortie
# traceql api
5386e02cf57ff44d34380f7b79474f21 api GET /colis 5885 ms
d785f93cb26d184f0003bffd9db16194 api GET /colis 5931 ms
# traceql postgresql
d785f93cb26d184f0003bffd9db16194 api GET /colis 5931 ms
cdbb4523d66370f8b05869b62f7614d2 worker estimer un colis 6190 ms
```

### Dans Grafana

Le même parcours se fait à la souris. Grafana a été configuré avec quatre sources de données, et les liens entre elles :

```sortie
{"name":"Alertmanager","type":"alertmanager","uid":"alertmanager"}
{"name":"Loki","type":"loki","uid":"loki"}
{"name":"Prometheus","type":"prometheus","uid":"prometheus"}
{"name":"Tempo","type":"tempo","uid":"tempo"}
prometheus : {"status":"OK","message":"Successfully queried the Prometheus API."}
loki : {"status":"OK","message":"Data source successfully connected."}
tempo : {"status":"OK","message":"Data source is working"}
```

Dans **Explore**, choisissez Loki et la requête `{service_name="api"} | json | duree_ms > 1000`. Chaque ligne affiche un lien `trace_id` : c'est le champ dérivé (`derivedFields`) de `valeurs-allegees.yaml`, qui extrait l'identifiant par une expression régulière et en fait un lien vers Tempo. La trace s'ouvre à côté, en cascade ; depuis un span, « Logs for this span » repart vers Loki avec l'identifiant (`tracesToLogsV2`). Le tableau de bord du chapitre 50 complète le tableau : la courbe de latence situe l'incident, l'intervalle choisi se reporte dans Explore. L'adresse est `http://localhost:3050/explore`, après une redirection de port vers `svc/supervision-grafana`.

## Ce que coûtent les journaux et les traces

```bash
kubectl top pod -n supervision
```

```sortie
prometheus-supervision-kube-prometheu-prometheus-0       29m   636Mi   
supervision-grafana-f6fd9d8f6-n97xg                      18m   366Mi   
tempo-0                                                  10m   309Mi   
loki-0                                                   22m   215Mi   
collecteur-agent-9nx8v                                   48m   78Mi    
alertmanager-supervision-kube-prometheu-alertmanager-0   1m    45Mi    
supervision-kube-prometheu-operator-76d74945df-t7xqf     4m    33Mi    
supervision-kube-state-metrics-c46cdbdbb-kb2t6           3m    30Mi    
supervision-prometheus-node-exporter-l9f2p               2m    17Mi    
pager-846797c59b-mwz7m                                   1m    11Mi    
```

Loki, Tempo et le collecteur ajoutent environ 400 Mio, moins que Prometheus seul. Le volume, lui, croît avec le trafic : chaque requête produit une ligne de journal et une trace de quatre à huit spans. Les leviers sont connus : ne pas tout garder (rétention de deux jours pour Loki, un jour pour Tempo), ne pas tout tracer (l'**échantillonnage**, exercice 4), et ne pas journaliser en boucle ce qui n'apporte rien, comme les sondes, déjà exclues par Colis.

## Exercices

:::exercice[Exercice 1 : deux façons de compter]

Comptez les réponses 404 de l'API sur les deux dernières minutes, une fois avec LogQL à partir des journaux, une fois avec PromQL à partir des métriques. Les deux nombres sont-ils égaux ? Pourquoi peuvent-ils différer ?

:::

<details>
<summary>Corrigé</summary>

```logql
sum(count_over_time({service_name="api"} | json | __error__="" | code="404" [2m]))
```

```promql
sum(increase(colis_http_requetes_total{namespace="colis", code="404"}[2m]))
```

```sortie
# LogQL
41
# PromQL
46.857142857142854
```

Les deux sont proches sans être égaux. LogQL compte des lignes dont l'horodatage tombe dans la fenêtre : c'est un compte exact des requêtes journalisées. `increase()` extrapole à partir des échantillons collectés toutes les 15 secondes : le premier et le dernier échantillon de la fenêtre ne tombent pas exactement à ses bords, et Prometheus prolonge la pente, d'où une valeur décimale. Sur une longue période, l'écart relatif devient négligeable. Il existe aussi des différences de fond : une requête dont le journal est perdu (Pod supprimé avant la collecte, ligne trop longue) manque dans Loki, tandis qu'un redémarrage du Pod remet le compteur à zéro, ce que `increase()` rattrape.

</details>

:::exercice[Exercice 2 : une étiquette de trop]

Un collègue propose de faire de `trace_id` une étiquette d'index de Loki, « pour retrouver plus vite les lignes d'une trace ». Combien de flux Loki aurait-il après une heure de trafic à 6 requêtes par seconde ? Que se passerait-il ? Comment Grafana retrouve-t-il les lignes d'une trace sans cela ?

:::

<details>
<summary>Corrigé</summary>

Chaque requête a son propre `trace_id` : 6 par seconde, c'est 21 600 nouveaux flux par heure pour l'API seule, contre une vingtaine de flux aujourd'hui pour tout le cluster. Chaque flux a son entrée d'index, et ses lignes sont regroupées en morceaux compressés par flux : 21 600 flux d'une ligne chacun, c'est un index énorme et des morceaux minuscules, que Loki gère très mal. Les limites par défaut finissent par refuser les écritures (`max_global_streams_per_user`), et l'ingestion s'arrête. La documentation de Loki le dit sans détour : les étiquettes doivent avoir une faible cardinalité[^loki].

Grafana n'en a pas besoin. « Logs for this span » lance une requête qui sélectionne les flux du service par ses étiquettes, puis **filtre** sur le contenu des lignes (`|= "<trace_id>"`). Loki ne lit alors que les lignes de la bonne période et des bons flux, ce qui reste rapide sur une fenêtre de quelques minutes. C'est ce que fait le script de rejeu avec `{service_name="api"} |= "<trace_id>"`. Quand on veut vraiment un accès direct par identifiant, on le range en métadonnée structurée, que Loki attache à la ligne sans créer de flux.

</details>

:::exercice[Exercice 3 : suivre un colis à travers la file (programmation)]

La trace du worker est séparée de celle de la requête qui a déposé le colis. Modifiez `deposer` et `prendre` (dans `colis/file.py`) pour que l'API dépose, avec l'identifiant du colis, le contexte de trace courant, et que le worker ouvre son span `estimer un colis` comme enfant de ce contexte. Les messages déjà dans la file (de simples identifiants) doivent rester lisibles. Testez sans cluster, avec un exportateur en mémoire.

:::

<details>
<summary>Corrigé</summary>

Le corrigé, `corrige/propagation.py`, n'est pas dans l'archive. Il utilise le propagateur par défaut d'OpenTelemetry, celui du W3C, qui sait écrire et relire `traceparent` dans n'importe quel dictionnaire :

```python
def deposer(redis, id_: int) -> None:
    porteur: dict[str, str] = {}
    propagate.inject(porteur)                 # {"traceparent": "00-<trace>-<span>-01"} s'il y a une trace
    redis.rpush(CLE, json.dumps({"id": id_, **porteur}))


def prendre(redis, attente_s: int) -> tuple[int, context.Context] | None:
    resultat = redis.blpop([CLE], timeout=attente_s)
    if not resultat:
        return None
    message = resultat[1]
    if message.isdigit():                     # un message déposé par une API 2.2 : pas de contexte
        return int(message), context.get_current()
    donnees = json.loads(message)
    return int(donnees.pop("id")), propagate.extract(donnees)
```

Le worker passe le contexte relu à `start_as_current_span(..., context=parent)`. Le test (`corrige/test_propagation.py`) remplace Redis par une liste et Tempo par un exportateur en mémoire :

```bash
pip install opentelemetry-sdk==1.45.1 pytest
python -m pytest -q -s test_propagation.py
```

```sortie
message dans la file : {"id": 42, "traceparent": "00-b21e31032a77af3e7d28d54fb6f5677c-5082b0f7aa82df7e-03"}
API    : trace b21e31032a77af3e7d28d54fb6f5677c span 5082b0f7aa82df7e
worker : trace b21e31032a77af3e7d28d54fb6f5677c parent 5082b0f7aa82df7e
..
2 passed in 0.04s
```

Le span du worker a le même `trace_id` que la requête de l'API, et son parent est le span de cette requête : dans Tempo, l'estimation apparaîtrait sous `POST /colis`, avec le temps passé dans la file entre les deux. Le dernier caractère de `traceparent` (`03`) contient les drapeaux : échantillonnée, et identifiant aléatoire. Un vrai déploiement doit aussi tenir compte des deux versions qui cohabitent pendant une mise à jour progressive (chapitre 19). Une API 2.2.1 dépose encore des identifiants nus, que le nouveau worker doit savoir lire : c'est le rôle du test `isdigit()`. Et un ancien worker doit pouvoir lire les messages JSON, ce qui impose de déployer le worker **avant** l'API.

</details>

:::exercice[Exercice 4 : n'en garder qu'une sur dix]

Configurez l'API pour n'enregistrer qu'une trace sur dix (`OTEL_TRACES_SAMPLER=parentbased_traceidratio`, `OTEL_TRACES_SAMPLER_ARG=0.1`), envoyez une minute de trafic, et comparez le nombre de traces de l'API dans Tempo au nombre de requêtes dans les journaux. Puis prenez quelques `trace_id` dans les journaux, et demandez leur trace à Tempo. Que constatez-vous, et quel problème cela pose-t-il pour l'enquête de ce chapitre ?

:::

<details>
<summary>Corrigé</summary>

```bash
kubectl -n colis set env deployment/api OTEL_TRACES_SAMPLER=parentbased_traceidratio OTEL_TRACES_SAMPLER_ARG=0.1
# une minute de trafic à 5 requêtes par seconde, puis :
```

```sortie
traces de l'API dans Tempo : 29
requêtes dans les journaux : 280
c2c6dcb5b6d3526741a088090a6c9a5d absente : {"trace":{}}
f2ed022d2d151a64b49f255aea229440 absente : {"trace":{}}
71703bf92f859ccf8cfc1ef5345678c7 absente : {"trace":{}}
9fec58bf4e33d3d6c3f295b18e63249b absente : {"trace":{}}
2d349a5e291be40eb728e183c59c6c3d absente : {"trace":{}}
f9cc22ba89b401f6216f036b41ca5846 absente : {"trace":{}}
dd95dec8d660e94d5c3dcc5e9bd4f453 absente : {"trace":{}}
fd2f343ceb30170741b38b8adc3fa75e absente : {"trace":{}}
```

Environ une trace sur dix arrive dans Tempo, comme demandé. Mais **toutes** les lignes de journal portent un `trace_id`, y compris celles des requêtes non retenues : le SDK crée toujours un contexte de trace, et ne décide qu'ensuite de l'enregistrer ou non. Pour la plupart des identifiants, Tempo ne trouve rien ; il ne répond pas par une erreur 404 mais par un code 200 et une trace vide, `{"trace":{}}`, qu'il faut savoir reconnaître. C'est le piège de l'échantillonnage « en tête » (*head sampling*), décidé au début de la requête, au hasard : la requête lente de l'enquête a neuf chances sur dix de ne pas avoir de trace. Deux remèdes. Journaliser aussi le drapeau d'échantillonnage, pour que Grafana ne propose le lien que s'il mène quelque part. Ou échantillonner **en queue** (*tail sampling*) : le collecteur garde toutes les traces quelques secondes, puis décide de conserver les lentes et celles en erreur, et une fraction des autres. C'est le rôle du processeur `tail_sampling` du collecteur, qui demande de faire passer toutes les traces d'une même requête par le même collecteur.

</details>

## Nettoyer

Loki, Tempo et le collecteur restent en place, comme Prometheus et Grafana : le défi VII s'en servira. Colis reste en version 2.2.1, traces actives. On retire seulement ce qui ne sert qu'aux exercices, déjà fait par le script des exercices : l'échantillonnage revient à 100 %.

Interfaces (redirections de port) : Grafana `http://localhost:3050` (Explore pour Loki et Tempo), Loki `http://localhost:3101`, Tempo `http://localhost:3201`, Prometheus `http://localhost:9095`.

```bash
kubectl -n supervision port-forward svc/loki 3101:3100 &
kubectl -n supervision port-forward svc/tempo 3201:3200 &
```

Pour tout retirer plus tard : `helm -n supervision uninstall collecteur tempo loki`, puis les PVC `storage-loki-0` et `storage-tempo-0`, que Helm laisse en place.

[^loki]: Grafana Labs, « Loki overview » et « Understand labels » : index par étiquettes seulement, lignes compressées par flux, recommandation d'étiquettes à faible cardinalité, métadonnées structurées pour les valeurs à forte cardinalité. [grafana.com/docs/loki/latest/get-started/labels](https://grafana.com/docs/loki/latest/get-started/labels/)
[^collecteur]: OpenTelemetry, « Important Components for Kubernetes » : récepteur filelog en DaemonSet sur /var/log/pods, processeur k8sattributes (association par adresse IP du Pod ou par chemin du fichier), préréglages du chart. [opentelemetry.io/docs/platforms/kubernetes/collector/components](https://opentelemetry.io/docs/platforms/kubernetes/collector/components/)
[^logql]: Grafana Labs, « LogQL: Log query language » : sélecteurs de flux, filtres de ligne, analyseurs (`json`, `logfmt`), requêtes métriques (`count_over_time`, `bytes_over_time`, `quantile_over_time` avec `unwrap`). [grafana.com/docs/loki/latest/query](https://grafana.com/docs/loki/latest/query/)
[^w3c]: W3C, « Trace Context », recommandation : en-têtes `traceparent` (version, identifiant de trace de 16 octets, identifiant du parent de 8 octets, drapeaux) et `tracestate`. [w3.org/TR/trace-context](https://www.w3.org/TR/trace-context/)
[^traceql]: Grafana Labs, « Construct a TraceQL query » : ensembles de spans entre accolades, attributs `span.` et `resource.`, champs intrinsèques `name`, `duration`, `kind`. [grafana.com/docs/tempo/latest/traceql](https://grafana.com/docs/tempo/latest/traceql/)
