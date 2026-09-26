---
title: Les contrôleurs
sidebar_label: 36. Les contrôleurs
description: "Ce qui fait réellement bouger un cluster : la boucle de réconciliation, le gestionnaire de contrôleurs arrêté puis relancé, un contrôleur écrit à la main en Python, informers et files de travail, ownerReferences et adoption, le ramasse-miettes et ses trois modes, les finalizers et le namespace bloqué en Terminating."
partie: 5
chapitre: '36'
---

import controleurBoucle from '@site/src/figures/controleur-boucle.svg';
import proprietaires from '@site/src/figures/proprietaires.svg';

« `kubectl scale deploy vitrine --replicas=4` ajoute deux Pods. » La phrase est si naturelle qu'on ne pense pas à la discuter, et pourtant elle est fausse. La commande change un nombre dans un objet, et c'est tout. Si aucun programme ne regarde ce nombre, il ne se passe rien. On peut le vérifier en arrêtant le programme qui le regarde, le **gestionnaire de contrôleurs** (`kube-controller-manager`), puis en demandant quatre répliques à un Deployment qui en a trois :

```sortie
gestionnaire de contrôleurs arrêté (Pod disparu après ~3 s)
deployment.apps/vitrine scaled
deploy : spec.replicas=4 generation=3 observedGeneration=2 prêts=3
rs vitrine-8596884b9c : spec.replicas=3
Pods : 3
```

Dix secondes après la commande, le Deployment demande bien 4 répliques, mais son ReplicaSet en demande toujours 3, et il y a toujours 3 Pods. `kubectl` a fait son travail, l'API server aussi, etcd a enregistré le nouveau nombre. Personne n'a agi. Remettons le gestionnaire en place :

```sortie
4 Pods prêts 5 s après la remise en place
deploy : spec.replicas=4 generation=3 observedGeneration=3 prêts=4
rs vitrine-8596884b9c : spec.replicas=4
Pods : 4
```

Cinq secondes plus tard, tout est rentré dans l'ordre. Le gestionnaire n'a reçu aucune consigne à son retour, et il n'a pas eu besoin qu'on lui rejoue la commande manquée. Il a regardé l'état du cluster, constaté que le Deployment voulait 4 répliques et que le ReplicaSet n'en demandait que 3, et corrigé l'écart. C'est toute l'idée de ce chapitre, et probablement l'idée la plus importante de Kubernetes : le cluster n'exécute pas des ordres, il est entretenu par des **contrôleurs** qui ramènent sans cesse la réalité vers ce qui est décrit.

On va voir ce principe sous plusieurs angles : sur le vrai gestionnaire de contrôleurs, sur un contrôleur qu'on écrira nous-mêmes en quelques dizaines de lignes de Python, puis sur deux mécanismes qui reposent entièrement sur lui, le ramasse-miettes et les finalizers. Les fichiers sont dans [l'archive controleurs](pathname:///kits/controleurs.tar.gz).

```bash
kubectl create namespace ch36
kubectl config set-context --current --namespace=ch36
kubectl create deployment vitrine --image=registry.k8s.io/e2e-test-images/agnhost:2.61 --replicas=2 -- /agnhost netexec
```

## Des boucles, pas des ordres

Un contrôleur suit une boucle simple, que la documentation de Kubernetes décrit en ces termes : observer l'état actuel, le comparer à l'état voulu, agir pour réduire l'écart, et recommencer[^controleurs]. L'état voulu est dans la partie `spec` des objets, écrite par vous ; l'état constaté est dans la partie `status`, écrite par les contrôleurs. La plupart des objets de Kubernetes ont ces deux moitiés, et la frontière entre les deux est une convention stricte de l'API[^conventions].

Deux champs, lus dans la sortie du début, permettent de savoir où en est un contrôleur. `metadata.generation` est un compteur que l'API server augmente à chaque modification de `spec` : il est passé à 3 avec le `scale`. `status.observedGeneration` est la génération que le contrôleur a traitée pour la dernière fois. Tant que les deux diffèrent, le statut affiché décrit un souhait périmé, et il ne faut pas s'y fier ; c'est d'ailleurs ce que vérifie `kubectl rollout status` avant de déclarer un déploiement terminé. Pendant l'arrêt du gestionnaire, on avait `generation=3` et `observedGeneration=2` : le souhait avait changé, personne ne l'avait lu.

Le mot important, dans la description de la boucle, est « état ». Un contrôleur de Kubernetes ne réagit pas à un **événement** (« quelqu'un a demandé deux Pods de plus »), il réagit à un **niveau** (« il en faut 4, il y en a 3 »). Les développeurs de Kubernetes le formulent comme une règle : un contrôleur doit être guidé par le niveau, pas par les fronts (*level-driven, not edge-driven*)[^ecrire]. La différence semble philosophique ; l'expérience du début montre qu'elle est très concrète. Un contrôleur guidé par les événements aurait manqué le `scale` pendant son absence, et ne l'aurait jamais rattrapé. Un contrôleur guidé par le niveau n'a rien à rattraper : à son retour, il compare, et l'écart lui dit quoi faire. Il en va de même après un redémarrage, une coupure réseau, un événement perdu, ou un humain qui a supprimé un Pod à la main.

### Le gestionnaire de contrôleurs

`kube-controller-manager` est un seul programme, qui fait tourner côte à côte plusieurs dizaines de contrôleurs, un par sorte d'objet ou presque. Il les lance tous par défaut, avec l'option `--controllers=*`. Comme il utilise ici une identité distincte pour chacun d'eux (`--use-service-account-credentials`), on peut en faire la liste en regardant les ServiceAccounts qu'il a créés dans `kube-system` :

```bash
kubectl -n kube-system get pod kube-controller-manager-minikube -o jsonpath='{range .spec.containers[0].command[*]}{@}{"\n"}{end}' | grep -E 'controllers=|leader-elect|use-service-account'
kubectl -n kube-system get sa -o name | grep -E 'controller$' | grep -v -E 'csi-external|snapshot-controller' | sed 's|serviceaccount/||' | column -c 110
```

```sortie
--controllers=*,bootstrapsigner,tokencleaner
--use-service-account-credentials=true
--leader-elect=false
attachdetach-controller				node-controller
certificate-controller				pv-protection-controller
clusterrole-aggregation-controller		pvc-protection-controller
cronjob-controller				replicaset-controller
daemon-set-controller				replication-controller
deployment-controller				resource-claim-controller
device-taint-eviction-controller		resourcequota-controller
disruption-controller				service-account-controller
endpoint-controller				service-cidrs-controller
endpointslice-controller			statefulset-controller
endpointslicemirroring-controller		storage-version-migrator-controller
ephemeral-volume-controller			ttl-after-finished-controller
expand-controller				ttl-controller
job-controller					validatingadmissionpolicy-status-controller
namespace-controller				volumeattributesclass-protection-controller
```

(Deux comptes qui finissent aussi par `controller` appartiennent aux addons de stockage de minikube ; on les a écartés.) On reconnaît des mécanismes vus dans les parties III et IV : `deployment-controller` et `replicaset-controller` pour les mises à jour, `job-controller` et `cronjob-controller` pour les tâches, `disruption-controller` qui calcule le `disruptionsAllowed` des PodDisruptionBudgets, `endpointslice-controller` qui tient à jour les adresses derrière chaque Service, `pvc-protection-controller` dont le finalizer retenait une PVC en usage au chapitre 25. Chacun est une boucle indépendante, qui ne connaît que ses propres objets. Aucun ne commande les autres : le contrôleur des Deployments ne crée jamais de Pod, il modifie un ReplicaSet, et c'est le contrôleur des ReplicaSets qui, voyant ce changement, crée les Pods.

D'autres contrôleurs vivent hors de ce programme. Le scheduler en est un, dont le seul travail est de remplir le champ `nodeName` des Pods qui n'en ont pas (chapitre 37). Le kubelet en est un autre, qui ramène les conteneurs de son nœud vers ce que décrivent les Pods qui lui sont attribués (chapitre 38). Et tous les composants installés en partie IV en sont : cert-manager réconcilie des `Certificate` en Secrets, KEDA des `ScaledObject` en HPA, Envoy Gateway des `HTTPRoute` en configuration de proxy.

Dernière ligne intéressante : `--leader-elect=false`. Sur un vrai plan de contrôle, trois gestionnaires de contrôleurs tournent en même temps, un par nœud de contrôle, et il ne faut pas que les trois agissent à la fois ; l'exercice 1 montre pourquoi. Ils s'élisent donc un leader, qui travaille pendant que les autres attendent, à l'aide d'un objet `Lease` de l'API que le leader renouvelle toutes les quelques secondes[^baux]. minikube n'en fait tourner qu'un, et désactive l'élection. Les composants installés par-dessus, eux, la gardent :

```bash
kubectl -n kube-system get lease -o custom-columns=BAIL:.metadata.name,DETENTEUR:.spec.holderIdentity | cut -c1-130
```

```sortie
BAIL                                                 DETENTEUR
apiserver-eqt674mfxb4j56mrjjkoe7b7ii                 apiserver-eqt674mfxb4j56mrjjkoe7b7ii_e062c7f9-f374-4ced-b614-c1643b2f8686
cert-manager-cainjector-leader-election              cert-manager-cainjector-8677bbdb7f-5sn5x_106601d5-3452-4549-b240-3148812119f1
cert-manager-controller                              cert-manager-7cbdfd77b7-nbhrb-external-cert-manager-controller
external-health-monitor-leader-hostpath-csi-k8s-io   csi-hostpathplugin-57xs6
snapshot-controller-leader                           snapshot-controller-7d8dd4dd5d-wmk9b
```

Le détenteur de chaque bail est le Pod qui travaille en ce moment. Si cert-manager tournait en deux exemplaires, le second attendrait que ce bail ne soit plus renouvelé pour prendre la place.

## Écrire un contrôleur

La meilleure façon de comprendre un contrôleur est d'en écrire un. Le fichier `mini-replicaset.py` est un ReplicaSet fait main, en Python et avec la seule bibliothèque standard. Son « objet » est un simple ConfigMap, étiqueté `cours/mini-rs=oui`, dont le champ `data.repliques` dit combien de Pods on veut :

```yaml title="vitrine-souhait.yaml"
apiVersion: v1
kind: ConfigMap
metadata:
  name: vitrine
  labels:
    cours/mini-rs: "oui"
data:
  repliques: "3"
```

Le programme a deux parties, et c'est la structure de tout contrôleur. La première tient à jour une image de l'état du cluster, avec le schéma « list puis watch » des chapitres 34 et 35 : une liste pour l'état complet, puis un watch à partir de sa `resourceVersion`. À chaque événement, il ne fait qu'une chose : il note le **nom** de l'objet concerné dans une file d'attente. Il le fait pour les ConfigMaps étiquetés et pour les Pods qu'il a créés :

```python title="mini-replicaset.py (extrait)"
def lister_puis_surveiller(ressource, selecteur, cle_de):
    """Le schéma list puis watch : remplit le cache, puis le tient à jour, et met en file les clés touchées."""
    while True:
        liste = requete("GET", f"/{ressource}?labelSelector={selecteur}")
        with verrou:
            cache[ressource] = {o["metadata"]["name"]: o for o in liste["items"]}
        for o in liste["items"]:
            file_attente.put(cle_de(o))
        rv = liste["metadata"]["resourceVersion"]
        ...
                for ligne in flux:
                    ev = json.loads(ligne)
                    ...
                    with verrou:
                        if ev["type"] == "DELETED":
                            cache[ressource].pop(o["metadata"]["name"], None)
                        else:
                            cache[ressource][o["metadata"]["name"]] = o
                    file_attente.put(cle_de(o))
```

La seconde partie prend les noms dans la file, un par un, et **réconcilie** : elle lit dans le cache le souhait et la réalité, compare, et corrige. Elle ne regarde jamais l'événement qui a mis le nom dans la file. Qu'on ait supprimé un Pod, modifié le ConfigMap ou redémarré le programme, elle fait le même calcul :

```python title="mini-replicaset.py (extrait)"
def reconcilier(nom):
    """Compare le souhait à la réalité, lue dans le cache, et corrige l'écart. Rien d'autre."""
    with verrou:
        cm = cache["configmaps"].get(nom)
        pods = [p for p in cache["pods"].values()
                if p["metadata"]["labels"].get("cours/proprietaire") == nom
                and not p["metadata"].get("deletionTimestamp")]
    if cm is None:
        return                                      # plus de souhait : le ramasse-miettes s'occupe des Pods
    voulu, reel = int(cm["data"].get("repliques", "0")), len(pods)
    if reel < voulu:
        for _ in range(voulu - reel):
            pod = {"apiVersion": "v1", "kind": "Pod",
                   "metadata": {"generateName": f"{nom}-", "labels": {"cours/proprietaire": nom},
                                "ownerReferences": [{"apiVersion": "v1", "kind": "ConfigMap", "name": nom,
                                                     "uid": cm["metadata"]["uid"], "controller": True,
                                                     "blockOwnerDeletion": True}]},
                   ...
            cree = requete("POST", "/pods", pod)
            ...
    elif reel > voulu:
        for p in sorted(pods, key=lambda p: p["metadata"]["creationTimestamp"])[voulu:]:
            requete("DELETE", f"/pods/{p['metadata']['name']}")
```

Les Pods en cours de suppression (ceux qui ont un `deletionTimestamp`) ne sont pas comptés : ils sont déjà sur le départ. Et chaque Pod créé porte une `ownerReference` vers le ConfigMap, dont on verra l'utilité plus loin. Lançons-le, derrière `kubectl proxy`, et mettons-le à l'épreuve en cinq temps :

```bash
kubectl proxy --port=8011 &
python3 -u mini-replicaset.py ch36 > log1.txt &
kubectl apply -f vitrine-souhait.yaml                              # 1. le souhait : 3 Pods
kubectl delete $(kubectl get pods -l cours/proprietaire=vitrine -o name | head -1) --wait=false   # 2. un Pod supprimé à la main
kubectl patch cm vitrine --type=merge -p '{"data":{"repliques":"1"}}'                            # 3. une seule réplique
kill %2; cat log1.txt
```

```sortie
contrôleur démarré dans ch36
19:52:58 vitrine : 0 Pod(s) pour 3 voulus, je crée vitrine-w7d7l
19:52:58 vitrine : 1 Pod(s) pour 3 voulus, je crée vitrine-ck9mm
19:52:58 vitrine : 2 Pod(s) pour 3 voulus, je crée vitrine-rw4fb
19:53:02 vitrine : 2 Pod(s) pour 3 voulus, je crée vitrine-8j4bn
19:53:05 vitrine : 3 Pod(s) pour 1 voulus, je supprime vitrine-rw4fb
19:53:05 vitrine : 2 Pod(s) pour 1 voulus, je supprime vitrine-8j4bn
```

Les trois premiers temps donnent ce qu'on attend d'un ReplicaSet. Le souhait apparaît, trois Pods sont créés. Un Pod est supprimé à la main (`vitrine-ck9mm`) : le contrôleur ne le sait pas en tant que tel, il voit qu'il y en a 2 pour 3 voulus, et en crée un quatrième. On demande une réplique : il en supprime deux, les plus récentes. Le contrôleur est maintenant arrêté. Changeons le souhait pendant son absence, puis relançons-le :

```bash
kubectl patch cm vitrine --type=merge -p '{"data":{"repliques":"4"}}'     # 4. contrôleur arrêté, on demande 4 Pods
python3 -u mini-replicaset.py ch36 > log2.txt &
sleep 4; kill %2; cat log2.txt
```

```sortie
contrôleur démarré dans ch36
19:53:11 vitrine : 1 Pod(s) pour 4 voulus, je crée vitrine-xf8ws
19:53:11 vitrine : 2 Pod(s) pour 4 voulus, je crée vitrine-7c56m
19:53:11 vitrine : 3 Pod(s) pour 4 voulus, je crée vitrine-6cp42
```

Il n'a jamais vu passer le changement de 1 à 4. Il n'en a pas besoin : au démarrage, sa liste initiale met le nom `vitrine` dans la file, et la réconciliation compare le niveau, 1 Pod pour 4 voulus. C'est l'expérience du début, avec notre propre programme. Dernier temps, toujours contrôleur arrêté : supprimons le souhait lui-même.

```bash
kubectl get pod -l cours/proprietaire=vitrine -o jsonpath='{.items[0].metadata.ownerReferences}{"\n"}'
kubectl delete cm vitrine
sleep 4; kubectl get pods -l cours/proprietaire=vitrine
```

```sortie
[{"apiVersion":"v1","blockOwnerDeletion":true,"controller":true,"kind":"ConfigMap","name":"vitrine","uid":"d180f028-29f4-4b2b-b399-7bdd4d6e3550"}]
configmap "vitrine" deleted from ch36 namespace
No resources found in ch36 namespace.
```

Les quatre Pods ont disparu en moins de quatre secondes, alors que notre contrôleur ne tournait pas, et que même s'il avait tourné, il ne supprime jamais rien quand le souhait n'existe plus (`if cm is None: return`). Quelqu'un d'autre l'a fait, en suivant l'`ownerReference` : un contrôleur du gestionnaire, le **ramasse-miettes**, sur lequel on revient plus bas.

Ce petit programme a les défauts qu'on attend d'un exemple. Il suppose que son cache est à jour quand il réconcilie, et attend pour cela 0,2 seconde avant chaque réconciliation, ce qui est un pari ; le vrai contrôleur des ReplicaSets tient à la place un registre de ses **attentes** (« j'ai demandé 3 créations, je n'en ai vu arriver que 2 ») et ne recompte pas tant qu'elles ne sont pas satisfaites. Il n'écrit aucun statut (l'exercice 4 s'en charge). Et il ne supporte pas d'avoir un jumeau (exercice 1). Mais la structure est la bonne, et c'est celle de tous les contrôleurs, en Go comme ailleurs.

## À l'intérieur d'un vrai contrôleur

Les contrôleurs de Kubernetes sont écrits en Go avec la bibliothèque `client-go`, qui fournit, bien éprouvées, les pièces qu'on vient d'écrire à la main[^ecrire]. La figure 36.1 les assemble.

<Figure svg={controleurBoucle} num="36.1" alt="L'intérieur d'un contrôleur. 1, un informer reçoit les événements de l'API server : il fait une liste, puis un watch depuis la resourceVersion de cette liste. 2, il tient à jour un cache local, copie indexée des objets suivis. 3, il met la clé ns/nom de chaque objet touché dans une file de travail, qui dédoublonne et réessaie avec un délai croissant. 4, un travailleur prend une clé à la fois et appelle réconcilier(clé) : lire le souhait et la réalité dans le cache, comparer, corriger l'écart. 5, il écrit dans l'API server : il crée, supprime, met à jour le statut. En cas d'échec, la clé est remise en file.">
L'intérieur d'un contrôleur. L'informer et la file de travail sont fournis par `client-go` ; seule la fonction de réconciliation est propre à chaque contrôleur.
</Figure>

L'**informer** fait le « list puis watch », gère les coupures et les `410` en relistant, et tient le **cache local**. Ce cache est partagé : dans le gestionnaire de contrôleurs, un seul informer des Pods sert tous les contrôleurs qui s'intéressent aux Pods, ce qui fait un seul watch sur l'API server au lieu d'une dizaine. Les réconciliations lisent dans ce cache, jamais dans l'API, qui ne voit donc passer que les écritures.

La **file de travail** reçoit des clés `namespace/nom`, pas des événements. Une clé déjà présente n'y est pas ajoutée une seconde fois : dix changements rapides sur le même Deployment ne donnent qu'une réconciliation, qui verra l'état final. Et quand une réconciliation échoue (un conflit `409`, un API server momentanément injoignable), la clé est remise en file avec un délai qui augmente à chaque échec, pour ne pas marteler l'API.

Ces files se voient dans les métriques du gestionnaire de contrôleurs. Il ne les expose qu'aux clients autorisés ; un ServiceAccount muni d'un droit de lecture sur `/metrics` suffit :

```bash
kubectl create sa lecteur-metriques
kubectl create clusterrole cours-lecture-metriques --verb=get --non-resource-url=/metrics
kubectl create clusterrolebinding cours-lecture-metriques --clusterrole=cours-lecture-metriques --serviceaccount=ch36:lecteur-metriques
metriques() {
  T=$(kubectl create token lecteur-metriques)
  minikube ssh -- "curl -sk -H 'Authorization: Bearer $T' https://127.0.0.1:10257/metrics" | grep -E '^workqueue_(adds_total|depth)\{' | grep -E 'name="(deployment|replicaset)"'
}
echo '# avant'; metriques
kubectl scale deploy vitrine --replicas=3; kubectl rollout status deploy/vitrine
echo '# après scale à 3'; metriques
```

```sortie
# avant
workqueue_adds_total{name="deployment"} 122
workqueue_adds_total{name="replicaset"} 155
workqueue_depth{name="deployment"} 0
workqueue_depth{name="replicaset"} 0
# après scale à 3
workqueue_adds_total{name="deployment"} 130
workqueue_adds_total{name="replicaset"} 165
workqueue_depth{name="deployment"} 0
workqueue_depth{name="replicaset"} 0
```

(Le gestionnaire n'écoute que sur l'adresse locale du nœud, d'où le passage par `minikube ssh`. Ses compteurs sont repartis de zéro à sa remise en place, au début du chapitre.) Un seul `scale` a mis 8 fois une clé dans la file des Deployments et 10 fois dans celle des ReplicaSets. C'est que chaque contrôleur surveille aussi les objets qui dépendent des siens : le contrôleur des Deployments est réveillé quand le Deployment change, mais aussi quand son ReplicaSet change, et quand un Pod de ce ReplicaSet change de statut, parce que chacun de ces changements peut modifier ce que le Deployment doit afficher. La profondeur des files (`depth`) est à 0 : tout a été traité. Sur un cluster surchargé, une profondeur qui ne redescend pas est le signe que les contrôleurs ne suivent plus.

## Qui appartient à qui

Un Deployment crée des ReplicaSets, qui créent des Pods. Chaque objet créé ainsi garde la trace de son créateur, dans `metadata.ownerReferences` :

```bash
P=$(kubectl get pods -l app=vitrine -o name | head -1)
kubectl get $P -o jsonpath='{.metadata.name} <- {.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
RS=$(kubectl get rs -l app=vitrine -o name)
kubectl get $RS -o jsonpath='{.metadata.name} <- {.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
kubectl get $P -o json | jq '.metadata.ownerReferences'
```

```sortie
vitrine-8596884b9c-ghrtb <- ReplicaSet/vitrine-8596884b9c
vitrine-8596884b9c <- Deployment/vitrine
[
  {
    "apiVersion": "apps/v1",
    "blockOwnerDeletion": true,
    "controller": true,
    "kind": "ReplicaSet",
    "name": "vitrine-8596884b9c",
    "uid": "d0683ff4-3d1e-4490-9f9c-e1a1961171d7"
  }
]
```

La référence désigne le propriétaire par son `kind`, son nom et surtout son `uid` : un objet recréé sous le même nom n'est pas le même propriétaire. `controller: true` signale le propriétaire qui **gère** l'objet ; un objet peut avoir plusieurs propriétaires, mais un seul gestionnaire. `blockOwnerDeletion` sert à la suppression au premier plan, plus bas.

Mais un contrôleur ne retrouve pas ses Pods par ces références : il les retrouve par son **sélecteur** d'étiquettes. Les références ne servent qu'à dire lequel des contrôleurs dont le sélecteur correspond est le gestionnaire. Cette distinction a une conséquence curieuse, qu'on peut provoquer : supprimons le ReplicaSet en laissant ses Pods derrière lui, avec `--cascade=orphan` :

```bash
echo "uid du ReplicaSet : $(kubectl get $RS -o jsonpath='{.metadata.uid}')"
kubectl get pods -l app=vitrine -o custom-columns=POD:.metadata.name,UID_DU_PROPRIETAIRE:.metadata.ownerReferences[0].uid
kubectl delete $RS --cascade=orphan
sleep 3
kubectl get rs -l app=vitrine -o custom-columns=RS:.metadata.name,UID:.metadata.uid
kubectl get pods -l app=vitrine -o custom-columns=POD:.metadata.name,UID_DU_PROPRIETAIRE:.metadata.ownerReferences[0].uid,AGE:.metadata.creationTimestamp
```

```sortie
uid du ReplicaSet : d0683ff4-3d1e-4490-9f9c-e1a1961171d7
POD                        UID_DU_PROPRIETAIRE
vitrine-8596884b9c-ghrtb   d0683ff4-3d1e-4490-9f9c-e1a1961171d7
vitrine-8596884b9c-l5mbx   d0683ff4-3d1e-4490-9f9c-e1a1961171d7
vitrine-8596884b9c-l7dm5   d0683ff4-3d1e-4490-9f9c-e1a1961171d7
vitrine-8596884b9c-mqfg9   d0683ff4-3d1e-4490-9f9c-e1a1961171d7
replicaset.apps "vitrine-8596884b9c" deleted from ch36 namespace
RS                   UID
vitrine-8596884b9c   d7705e9a-f454-40c6-9d3d-82d64a7640f3
POD                        UID_DU_PROPRIETAIRE                    AGE
vitrine-8596884b9c-ghrtb   d7705e9a-f454-40c6-9d3d-82d64a7640f3   2026-09-26T17:52:00Z
vitrine-8596884b9c-l5mbx   d7705e9a-f454-40c6-9d3d-82d64a7640f3   2026-09-26T17:51:58Z
vitrine-8596884b9c-l7dm5   d7705e9a-f454-40c6-9d3d-82d64a7640f3   2026-09-26T17:52:18Z
vitrine-8596884b9c-mqfg9   d7705e9a-f454-40c6-9d3d-82d64a7640f3   2026-09-26T17:51:58Z
```

Trois secondes après la suppression, un ReplicaSet du même nom existe de nouveau, avec un autre `uid` : le contrôleur des Deployments a vu que son Deployment n'avait plus de ReplicaSet et en a créé un. Et les quatre Pods sont les mêmes qu'avant (mêmes noms, mêmes dates de création), mais ils appartiennent maintenant au nouveau ReplicaSet. Personne ne les a recréés : le contrôleur des ReplicaSets a trouvé des Pods **orphelins** (sans gestionnaire) qui correspondaient à son sélecteur, et les a **adoptés**, en y écrivant sa propre référence. Aucun conteneur n'a redémarré. L'adoption explique aussi un piège : un Pod créé à la main avec les mêmes étiquettes qu'un ReplicaSet sera adopté par lui, et compté parmi ses répliques.

## Le ramasse-miettes

Supprimer un Deployment supprime ses ReplicaSets et ses Pods, mais ce n'est pas l'API server qui s'en charge, ni le contrôleur des Deployments. C'est un contrôleur dédié, le **ramasse-miettes** (*garbage collector*), qui surveille tous les objets, construit le graphe des `ownerReferences`, et supprime tout objet dont les propriétaires n'existent plus[^rm]. On l'a vu travailler sur les Pods de notre contrôleur Python, alors que celui-ci était arrêté. Trois modes de suppression décident de l'ordre des opérations, et on les choisit avec l'option `--cascade` de kubectl, ou le champ `propagationPolicy` de la requête `DELETE` (chapitre 34, exercice 1). La figure 36.2 les résume.

<Figure svg={proprietaires} num="36.2" alt="À gauche, la chaîne des propriétaires : trois Pods désignent le ReplicaSet vitrine-8596884b9c par leurs ownerReferences, et le ReplicaSet désigne le Deployment vitrine ; chaque dépendant désigne son propriétaire par kind, name et uid. À droite, les trois valeurs de kubectl delete --cascade. Background, par défaut : le propriétaire disparaît aussitôt ; le ramasse-miettes supprime ensuite les dépendants dont le propriétaire n'existe plus. Foreground : le propriétaire reste, avec un deletionTimestamp et le finalizer foregroundDeletion, jusqu'à la disparition des dépendants, 11 secondes dans ce chapitre. Orphan : les dépendants restent, sans propriétaire ; un contrôleur dont le sélecteur les désigne peut les adopter.">
La chaîne des propriétaires, et les trois façons de supprimer un objet qui a des dépendants.
</Figure>

Le mode par défaut, **Background**, supprime le propriétaire tout de suite, et laisse le ramasse-miettes s'occuper des dépendants ensuite. Le mode **Orphan** vient d'être vu. Le mode **Foreground** est le plus instructif, car il montre le mécanisme de la section suivante. Le fichier `lent.yaml` décrit un Deployment dont les Pods mettent 8 secondes à s'arrêter, grâce à un crochet `preStop` de type `sleep` :

```yaml title="lent.yaml (extrait)"
      containers:
      - name: c
        image: registry.k8s.io/e2e-test-images/agnhost:2.61
        args: [pause]
        lifecycle:
          preStop:
            sleep: {seconds: 8}
```

```bash
kubectl apply -f lent.yaml; kubectl rollout status deploy/lent
t=$(date +%s); kubectl delete deploy lent --cascade=foreground --wait=false
sleep 1
kubectl get deploy lent -o jsonpath='deploy lent : deletionTimestamp={.metadata.deletionTimestamp} finalizers={.metadata.finalizers}{"\n"}'
kubectl get rs -l app=lent -o jsonpath='{range .items[*]}rs {.metadata.name} : deletionTimestamp={.metadata.deletionTimestamp} finalizers={.metadata.finalizers}{"\n"}{end}'
kubectl get pods -l app=lent
while kubectl get deploy lent >/dev/null 2>&1; do sleep 0.5; done; echo "Deployment disparu $(( $(date +%s)-t )) s après la demande"
```

```sortie
deployment.apps "lent" deleted from ch36 namespace
deploy lent : deletionTimestamp=2026-09-26T17:52:31Z finalizers=["foregroundDeletion"]
rs lent-5c7b967588 : deletionTimestamp=2026-09-26T17:52:31Z finalizers=["foregroundDeletion"]
NAME                    READY   STATUS        RESTARTS   AGE
lent-5c7b967588-w8bmt   1/1     Terminating   0          3s
lent-5c7b967588-wxw87   1/1     Terminating   0          3s
Deployment disparu 11 s après la demande
```

kubectl annonce `deleted`, et pourtant le Deployment est toujours là une seconde plus tard. Il a une date de suppression, et un **finalizer**, `foregroundDeletion`, posé par l'API server à la demande du mode Foreground. Son ReplicaSet est dans le même état, et les Pods s'arrêtent. Le ramasse-miettes attend que tous les dépendants marqués `blockOwnerDeletion` aient disparu, retire alors le finalizer du ReplicaSet, qui disparaît, puis celui du Deployment : 11 secondes en tout, les 8 secondes du `preStop` et le temps de faire le tour. Ce mode sert quand on veut être sûr, au moment où le propriétaire disparaît, que plus rien de ce qu'il avait créé ne tourne.

## Les finalizers

Le mécanisme qu'on vient d'apercevoir est général. Un **finalizer** est une simple chaîne de caractères, rangée dans la liste `metadata.finalizers` d'un objet. Tant que cette liste n'est pas vide, l'API server refuse de supprimer réellement l'objet : une demande de suppression ne fait que poser un `deletionTimestamp`[^finalizers]. C'est un signal pour le contrôleur qui a posé le finalizer : « on veut supprimer cet objet, fais d'abord ton ménage, puis retire ton nom de la liste ». Quand la liste est vide, l'objet disparaît.

N'importe qui peut poser un finalizer, et c'est facile à observer avec un nom inventé, que personne ne retirera :

```yaml title="garde.yaml"
apiVersion: v1
kind: ConfigMap
metadata:
  name: garde
  finalizers:
  - cours.exemple/archivage
data:
  a: "1"
```

```bash
kubectl apply -f garde.yaml
kubectl delete cm garde --wait=false
kubectl get cm garde -o jsonpath='deletionTimestamp={.metadata.deletionTimestamp} finalizers={.metadata.finalizers}{"\n"}'
kubectl get cm garde
kubectl patch cm garde --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
kubectl get cm garde
```

```sortie
configmap/garde created
configmap "garde" deleted from ch36 namespace
deletionTimestamp=2026-09-26T17:52:42Z finalizers=["cours.exemple/archivage"]
NAME    DATA   AGE
garde   1      0s
configmap/garde patched
Error from server (NotFound): configmaps "garde" not found
```

L'objet est « supprimé », et toujours là. Il le resterait indéfiniment si l'on ne retirait pas le finalizer à la main, à la place du contrôleur imaginaire qui aurait dû le faire. Dès que la liste est vide, il disparaît. On a déjà croisé de vrais finalizers : `kubernetes.io/pvc-protection`, que le contrôleur du même nom pose sur chaque PVC pour qu'un volume en usage ne soit pas supprimé sous les pieds d'un Pod (chapitre 25), et `foregroundDeletion` à l'instant. cert-manager, les opérateurs de bases de données et la plupart des contrôleurs qui gèrent des ressources extérieures au cluster en posent aussi, pour avoir le temps de libérer ces ressources avant que l'objet ne disparaisse.

:::panne[Un namespace reste bloqué en Terminating]

C'est l'incident de finalizer le plus courant, et il se reproduit en trois commandes. On crée un namespace, on y met le ConfigMap `garde`, et on supprime le namespace :

```bash
kubectl create namespace ch36-bloque
kubectl -n ch36-bloque apply -f garde.yaml
kubectl delete namespace ch36-bloque --wait=false
sleep 6; kubectl get namespace ch36-bloque
kubectl get namespace ch36-bloque -o json | jq -r '.status.conditions[] | select(.status=="True") | "\(.type) : \(.message)"'
```

```sortie
NAME          STATUS        AGE
ch36-bloque   Terminating   6s
NamespaceContentRemaining : Some resources are remaining: configmaps. has 1 resource instances
NamespaceFinalizersRemaining : Some content in the namespace has finalizers remaining: cours.exemple/archivage in 1 resource instances
```

Le contrôleur des namespaces supprime tout ce que contient un namespace avant de supprimer le namespace lui-même. Si un seul objet ne peut pas disparaître, le namespace reste `Terminating`, sans limite de temps. Le diagnostic est dans ses conditions : quelle ressource reste, et quel finalizer la retient. La cause, dans la vraie vie, est presque toujours un contrôleur qui a été désinstallé avant les objets qu'il gérait (on supprime l'opérateur, puis le namespace de ses ressources) : plus personne n'est là pour retirer le finalizer. La bonne correction est de réinstaller ce contrôleur le temps qu'il fasse son ménage. Retirer le finalizer à la main, comme ci-dessous, débloque la situation, mais saute le ménage : si ce finalizer protégeait un disque, une base ou un équilibreur de charge chez un fournisseur de cloud, cette ressource restera allouée, et facturée, sans plus aucun objet pour s'en souvenir.

```bash
kubectl -n ch36-bloque patch cm garde --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
sleep 6; kubectl get namespace ch36-bloque
```

```sortie
configmap/garde patched
Error from server (NotFound): namespaces "ch36-bloque" not found
```

:::

## Exercices

:::exercice[Exercice 1 : deux contrôleurs pour un souhait]

Lancez **deux** copies de `mini-replicaset.py` en même temps, puis appliquez `vitrine-souhait.yaml` (3 répliques). Prédisez ce qui va se passer, puis comparez les journaux des deux copies et le nombre final de Pods. Quel mécanisme de Kubernetes évite ce problème aux vrais contrôleurs ?

:::

<details>
<summary>Corrigé</summary>

```sortie
Pods à la fin : 3
# copie A
19:53:22 vitrine : 0 Pod(s) pour 3 voulus, je crée vitrine-8cqfl
19:53:22 vitrine : 1 Pod(s) pour 3 voulus, je crée vitrine-8bfbp
19:53:22 vitrine : 2 Pod(s) pour 3 voulus, je crée vitrine-4lzjm
19:53:22 vitrine : 6 Pod(s) pour 3 voulus, je supprime vitrine-8bfbp
19:53:22 vitrine : 5 Pod(s) pour 3 voulus, je supprime vitrine-4lzjm
19:53:22 vitrine : 4 Pod(s) pour 3 voulus, je supprime vitrine-8plrg
# copie B
19:53:22 vitrine : 0 Pod(s) pour 3 voulus, je crée vitrine-zds7n
19:53:22 vitrine : 1 Pod(s) pour 3 voulus, je crée vitrine-trshb
19:53:22 vitrine : 2 Pod(s) pour 3 voulus, je crée vitrine-8plrg
19:53:22 vitrine : 6 Pod(s) pour 3 voulus, je supprime vitrine-8bfbp
19:53:22 vitrine : 5 Pod(s) pour 3 voulus, je supprime vitrine-4lzjm
19:53:22 vitrine : 4 Pod(s) pour 3 voulus, je supprime vitrine-8plrg
```

Les deux copies voient le même souhait au même moment, avec 0 Pod : chacune en crée 3, ce qui en fait 6. Puis chacune voit 6 Pods pour 3 voulus, et en supprime 3, les mêmes, puisqu'elles les choisissent avec la même règle (les plus récents). La deuxième suppression de chaque Pod ne change rien, puisqu'il est déjà en cours de suppression. On retombe sur 3, mais après avoir créé trois Pods pour rien ; avec une règle de choix moins déterministe, elles auraient pu en supprimer 6, puis en recréer, et osciller un moment. Le niveau finit toujours par être atteint, mais le travail est fait deux fois, et parfois défait. C'est pourquoi les contrôleurs qui tournent en plusieurs exemplaires s'élisent un leader, par un objet `Lease` que seul le détenteur renouvelle ; les autres restent en réserve. Écrire cette élection est un bon prolongement : c'est une application directe de la concurrence optimiste du chapitre 35 (lire le bail, le prendre par un `PUT` qui porte sa `resourceVersion`, et accepter de perdre sur un `409`).

</details>

:::exercice[Exercice 2 : un Deployment orphelin]

Supprimez le Deployment `vitrine` avec `--cascade=orphan`. Que reste-t-il ? Recréez ensuite un Deployment `vitrine` identique (`kubectl create deployment vitrine --image=registry.k8s.io/e2e-test-images/agnhost:2.61 --replicas=4 -- /agnhost netexec`). Combien de Pods sont créés ?

:::

<details>
<summary>Corrigé</summary>

```sortie
deployment.apps "vitrine" deleted from ch36 namespace
NAME                                 DESIRED   CURRENT   READY   AGE
replicaset.apps/vitrine-8596884b9c   4         4         4       67s

NAME                           READY   STATUS    RESTARTS   AGE
pod/vitrine-8596884b9c-ghrtb   1/1     Running   0          94s
pod/vitrine-8596884b9c-l5mbx   1/1     Running   0          96s
pod/vitrine-8596884b9c-l7dm5   1/1     Running   0          76s
pod/vitrine-8596884b9c-mqfg9   1/1     Running   0          96s
```

Après la recréation :

```sortie
NAME                                 DESIRED   CURRENT   READY   AGE
replicaset.apps/vitrine-8596884b9c   4         4         4       71s

NAME                           READY   STATUS    RESTARTS   AGE
pod/vitrine-8596884b9c-ghrtb   1/1     Running   0          98s
pod/vitrine-8596884b9c-l5mbx   1/1     Running   0          100s
pod/vitrine-8596884b9c-l7dm5   1/1     Running   0          80s
pod/vitrine-8596884b9c-mqfg9   1/1     Running   0          100s
```

Le ReplicaSet orphelin continue de faire son travail sans Deployment : il maintient ses 4 Pods, et les maintiendrait indéfiniment. Le nouveau Deployment ne crée **aucun** Pod : son gabarit est identique, donc le suffixe de son ReplicaSet (`8596884b9c`, une empreinte du gabarit) aussi. Il trouve un ReplicaSet orphelin qui correspond à son sélecteur et à son gabarit, et l'adopte, avec ses Pods. C'est la même adoption qu'en cours de chapitre, un étage plus haut. Ce comportement est utile pour changer un Deployment qu'on ne peut pas modifier en place (un sélecteur, par exemple, est immuable) sans interrompre le service : on le supprime en mode orphelin, et on le recrée.

</details>

:::exercice[Exercice 3 : un propriétaire dans un autre namespace]

Créez un namespace `ch36-autre` avec un ConfigMap `proprio`, puis, dans `ch36`, un ConfigMap `dependant` dont l'`ownerReference` désigne `proprio` (avec son vrai `uid`). Le propriétaire existe bel et bien. Que devient `dependant` au bout de quelques secondes ? Regardez ses événements.

:::

<details>
<summary>Corrigé</summary>

```bash
kubectl create namespace ch36-autre >/dev/null
kubectl -n ch36-autre create configmap proprio --from-literal=a=1 >/dev/null
U=$(kubectl -n ch36-autre get cm proprio -o jsonpath='{.metadata.uid}')
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: dependant\n  ownerReferences:\n  - {apiVersion: v1, kind: ConfigMap, name: proprio, uid: %s}\ndata: {a: "1"}\n' $U | kubectl apply -f -
sleep 8; kubectl get cm dependant
kubectl get events --field-selector involvedObject.name=dependant -o custom-columns=RAISON:.reason,MESSAGE:.message --no-headers
```

```sortie
configmap/dependant created
Error from server (NotFound): configmaps "dependant" not found
OwnerRefInvalidNamespace   ownerRef [v1/ConfigMap, namespace: ch36, name: proprio, uid: b3f8522d-7a95-40a0-9180-dcfa9e334882] does not exist in namespace "ch36"
```

Le dépendant a été supprimé. Une `ownerReference` ne contient pas de namespace : pour un objet d'un namespace, le propriétaire est cherché **dans le même namespace**. Le ramasse-miettes ne trouve pas `proprio` dans `ch36`, conclut que le propriétaire n'existe pas, et supprime le dépendant, en laissant l'événement `OwnerRefInvalidNamespace` comme seule trace[^rm]. Les références entre namespaces sont interdites par conception ; seul un objet de tout le cluster (un nœud, un namespace, une ClusterRole) peut être le propriétaire d'objets situés dans des namespaces différents. Un opérateur qui veut relier des objets de plusieurs namespaces doit utiliser autre chose, des étiquettes par exemple, et faire le ménage lui-même, souvent à l'aide d'un finalizer.

</details>

:::exercice[Exercice 4 : un contrôleur qui écrit son statut]

Modifiez `mini-replicaset.py` pour qu'après chaque réconciliation, il écrive dans une annotation `cours/pods` du ConfigMap le nombre de Pods prêts sur le nombre voulu (par exemple `3/3`). Attention : cette écriture modifie le ConfigMap, qui est surveillé par le contrôleur lui-même. Comment éviter une boucle sans fin ? Vérifiez que la `resourceVersion` du ConfigMap ne bouge plus une fois le statut atteint.

:::

<details>
<summary>Corrigé</summary>

La fonction ajoutée, appelée au début de `reconcilier` une fois le souhait et les Pods lus :

```python title="mini-replicaset-statut.py (extrait)"
def ecrire_statut(cm, pods, voulu):
    """Annote le souhait avec « prêts/voulus », seulement si la valeur change."""
    prets = sum(1 for p in pods for c in p.get("status", {}).get("conditions", [])
                if c["type"] == "Ready" and c["status"] == "True")
    statut = f"{prets}/{voulu}"
    if cm["metadata"].get("annotations", {}).get("cours/pods") == statut:
        return                                      # rien à écrire : sinon, chaque écriture relancerait une boucle
    requete("PATCH", f"/configmaps/{cm['metadata']['name']}",
            {"metadata": {"annotations": {"cours/pods": statut}}}, "application/merge-patch+json")
```

(La fonction `requete` reçoit un paramètre de plus, le `Content-Type`, pour pouvoir envoyer un merge patch.)

```sortie
19:53:50 vitrine : statut 0/3
19:53:50 vitrine : 0 Pod(s) pour 3 voulus, je crée vitrine-n7kdw
19:53:50 vitrine : 1 Pod(s) pour 3 voulus, je crée vitrine-p6fp2
19:53:50 vitrine : 2 Pod(s) pour 3 voulus, je crée vitrine-kswg6
19:53:51 vitrine : statut 3/3
annotation : 3/3, resourceVersion 101640
5 s plus tard : resourceVersion 101640
```

Chaque écriture du statut produit un événement `MODIFIED` sur le ConfigMap, qui remet `vitrine` dans la file, qui provoque une réconciliation. Si celle-ci réécrivait le statut à chaque fois, même identique, le contrôleur tournerait en rond indéfiniment, en consommant une révision d'etcd par tour. La parade est de ne rien écrire quand la valeur calculée est déjà la bonne : la réconciliation déclenchée par sa propre écriture constate que tout est en ordre, et s'arrête. La `resourceVersion` stable le confirme. C'est aussi pour cette raison que les vrais objets séparent `spec` et `status`, et que les contrôleurs écrivent le statut par la sous-ressource `status` (chapitre 34) : une modification du statut ne change pas `metadata.generation`, ce qui permet à un contrôleur de distinguer un nouveau souhait de l'écho de sa propre écriture.

</details>

## Nettoyer

```bash
kill %1 2>/dev/null        # kubectl proxy
kubectl delete namespace ch36 ch36-autre --ignore-not-found
kubectl delete clusterrolebinding cours-lecture-metriques
kubectl delete clusterrole cours-lecture-metriques
kubectl config set-context --current --namespace=default
```

Le gestionnaire de contrôleurs a retrouvé son manifeste dès la fin de l'expérience du début. Si vous l'avez reproduite vous-même, vérifiez qu'il tourne :

```bash
kubectl -n kube-system get pod kube-controller-manager-minikube
```

:::panne[Arrêter le gestionnaire de contrôleurs, si vous voulez refaire l'expérience]

L'expérience du début déplace le manifeste statique du gestionnaire hors du dossier que surveille le kubelet (le mécanisme des Pods statiques est l'objet du chapitre 38) :

```bash
minikube ssh -- sudo mv /etc/kubernetes/manifests/kube-controller-manager.yaml /etc/kubernetes/kcm.yaml.cours
# ... l'expérience ...
minikube ssh -- sudo mv /etc/kubernetes/kcm.yaml.cours /etc/kubernetes/manifests/kube-controller-manager.yaml
```

Ne l'oubliez pas en route : sans gestionnaire, plus aucun Deployment ne se met à jour, plus aucun Job ne se lance, plus aucun nœud n'est surveillé. Faites-le sur minikube, jamais sur un cluster partagé.

:::

[^controleurs]: Kubernetes, « Controllers », sections *Controller pattern* et *Desired versus current state*. [kubernetes.io/docs/concepts/architecture/controller](https://kubernetes.io/docs/concepts/architecture/controller/)

[^conventions]: Kubernetes, « API Conventions », sections *Spec and Status* et *Metadata* (pour `generation` et `observedGeneration`). [github.com/kubernetes/community/blob/master/contributors/devel/sig-architecture/api-conventions.md](https://github.com/kubernetes/community/blob/master/contributors/devel/sig-architecture/api-conventions.md)

[^ecrire]: Kubernetes, « Writing Controllers », guide des développeurs de SIG API Machinery : guidage par le niveau, informers partagés, files de travail. Le dépôt `sample-controller` en donne un exemple complet en Go. [github.com/kubernetes/community/blob/master/contributors/devel/sig-api-machinery/controllers.md](https://github.com/kubernetes/community/blob/master/contributors/devel/sig-api-machinery/controllers.md), [github.com/kubernetes/sample-controller](https://github.com/kubernetes/sample-controller)

[^baux]: Kubernetes, « Leases », section *Leader election*. [kubernetes.io/docs/concepts/architecture/leases](https://kubernetes.io/docs/concepts/architecture/leases/)

[^rm]: Kubernetes, « Garbage Collection » (modes Background, Foreground, Orphan) et « Owners and Dependents » (références entre namespaces, événement `OwnerRefInvalidNamespace`). [kubernetes.io/docs/concepts/architecture/garbage-collection](https://kubernetes.io/docs/concepts/architecture/garbage-collection/), [kubernetes.io/docs/concepts/overview/working-with-objects/owners-dependents](https://kubernetes.io/docs/concepts/overview/working-with-objects/owners-dependents/)

[^finalizers]: Kubernetes, « Finalizers ». [kubernetes.io/docs/concepts/overview/working-with-objects/finalizers](https://kubernetes.io/docs/concepts/overview/working-with-objects/finalizers/)
