---
title: Le contrôle d'admission
sidebar_label: 45. Le contrôle d'admission
description: "Écrire ses propres règles pour ce qui entre dans le cluster : les politiques CEL de validation et de mutation, un webhook écrit en Python qui interroge le registre, la panne d'un webhook et failurePolicy, Kyverno pour juger l'existant et générer des objets, et un bogue de cache des paramètres reproduit pas à pas."
partie: 6
chapitre: '45'
---

import admissionTrajet from '@site/src/figures/admission-trajet.svg';
import webhookVerif from '@site/src/figures/webhook-verif.svg';

Quand vous créez un Pod, combien de programmes le lisent avant qu'il soit enregistré ? Il y a l'API server, bien sûr. Mais sur ce cluster, il y en a au moins un autre, dans un autre namespace, que vous n'avez jamais appelé directement. L'API server tient le compte de ses appels :

```bash
kubectl -n ch45 run temoin --image=busybox:1.37 -- sleep 3600
# avant et après, on relève le compteur apiserver_admission_webhook_admission_duration_seconds_count de vpa.k8s.io
```

```sortie
appels au webhook de VPA : 1 avant, 2 après
```

(Les compteurs repartent de zéro à chaque redémarrage de l'API server, ce qui explique ces petits nombres.) La création du Pod a déclenché un appel HTTPS vers le webhook du Vertical Pod Autoscaler installé au chapitre 31, qui a pu le modifier avant son enregistrement. Il n'est pas seul. Voici tous les webhooks que les outils de la partie IV ont déclarés auprès de l'API server :

```sortie
mutating    webhook.cert-manager.io                 CREATE cert-manager.io/certificaterequests                                  Fail    30s
mutating    topology.webhook.gateway.envoyproxy.io  CREATE core/pods/binding                                                    Ignore  10s
mutating    vpa.k8s.io                              CREATE core/pods ; CREATE,UPDATE autoscaling.k8s.io/verticalpodautoscalers  Ignore  5s
validating  webhook.cert-manager.io                 CREATE,UPDATE cert-manager.io,acme.cert-manager.io/*/*                      Fail    30s
validating  vscaledobject.kb.io                     CREATE,UPDATE keda.sh/scaledobjects                                         Ignore  10s
validating  vscaledjob.kb.io                        CREATE,UPDATE keda.sh/scaledjobs                                            Ignore  10s
validating  vstriggerauthentication.kb.io           CREATE,UPDATE keda.sh/triggerauthentications                                Ignore  10s
validating  vsclustertriggerauthentication.kb.io    CREATE,UPDATE keda.sh/clustertriggerauthentications                         Ignore  10s
validating  vcloudeventsource.kb.io                 CREATE,UPDATE eventing.keda.sh/cloudeventsources                            Ignore  10s
validating  vclustercloudeventsource.kb.io          CREATE,UPDATE eventing.keda.sh/clustercloudeventsources                     Ignore  10s
```

Chaque ligne dit ce que le webhook intercepte, ce qui arrive s'il ne répond pas (`Fail` ou `Ignore`), et combien de temps l'API server l'attend. Le webhook de VPA voit passer la création de **tous** les Pods du cluster ; s'il était lent, toutes les créations de Pods le seraient. La Gateway API a aussi installé une politique écrite en CEL, `safe-upgrades.gateway.networking.k8s.io`. Ces mécanismes forment le **contrôle d'admission**, le dernier filtre entre une requête autorisée et etcd. Pod Security Admission en est un cas particulier, intégré à Kubernetes. Ce chapitre montre comment y ajouter vos propres règles, avec trois outils de plus en plus puissants, et ce que chacun coûte. Les fichiers sont dans [l'archive admission](pathname:///kits/admission.tar.gz).

## Le trajet de l'admission

Le chapitre 34 a montré qu'une requête d'écriture passe par l'admission après l'authentification et l'autorisation. Regardons cette étape de plus près :

<Figure svg={admissionTrajet} num="45.1" alt="Une requête authentifiée et autorisée passe d'abord par la mutation : plugins intégrés (ServiceAccount, DefaultStorageClass…), MutatingAdmissionPolicy en CEL (defauts-securite), webhooks de mutation (VPA, Kyverno, epingle-images). Puis par la validation du schéma. Puis par la validation : plugins intégrés (PodSecurity, NodeRestriction…), ValidatingAdmissionPolicy en CEL (images-colis), webhooks de validation (verif-images, cert-manager, KEDA, Kyverno). Enfin etcd. Légende : compilé dans l'API server ; politique CEL, évaluée dans l'API server ; webhook, appel HTTPS à un Service.">
Le trajet de l'admission. La mutation passe avant la validation : ce qu'un mutateur ajoute est contrôlé ensuite, par Pod Security comme par vos propres règles.
</Figure>

Il y a deux phases, et l'ordre compte. La **mutation** peut modifier l'objet : compléter des valeurs par défaut, ajouter une étiquette, injecter un conteneur. La **validation** ne peut que dire oui ou non, sur l'objet tel que la mutation l'a laissé. Entre les deux, l'API server vérifie que l'objet respecte le schéma de sa ressource. Dans chaque phase, trois sortes d'acteurs interviennent : des plugins compilés dans l'API server et activés par l'option `--enable-admission-plugins` (le chapitre 34 l'a montrée), des **politiques CEL** évaluées par l'API server lui-même, et des **webhooks**, des services HTTPS que l'API server appelle et attend.

## Valider en CEL : ValidatingAdmissionPolicy

Colis a deux règles que Pod Security ne sait pas exprimer : ses images viennent du registre du cours (ou d'images officielles bien identifiées), et elles portent une étiquette précise, jamais `latest` ni rien du tout. On les écrit dans une **ValidatingAdmissionPolicy**, stable depuis Kubernetes 1.30, dont les règles sont des expressions en **CEL** (*Common Expression Language*), un petit langage d'expressions sans effets de bord, évalué dans l'API server[^vap].

```yaml title="politiques/images-politique.yaml"
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: images-colis
spec:
  failurePolicy: Fail
  paramKind:
    apiVersion: v1
    kind: ConfigMap
  matchConstraints:
    resourceRules:
    - apiGroups: ["apps"]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["deployments", "statefulsets", "daemonsets"]
    - apiGroups: [""]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["pods"]
  variables:
  - name: gabarit
    expression: "object.kind == 'Pod' ? object.spec : object.spec.template.spec"
  - name: images
    expression: "variables.gabarit.containers.map(c, c.image) + (has(variables.gabarit.initContainers) ? variables.gabarit.initContainers.map(c, c.image) : [])"
  - name: registres
    expression: "params.data.registres.split(',')"
  validations:
  - expression: "variables.images.all(i, i.contains('@sha256:') || (i.split('/')[i.split('/').size() - 1].contains(':') && !i.endsWith(':latest')))"
    messageExpression: "'chaque image doit porter une étiquette autre que latest, ou une empreinte : ' + variables.images.join(', ')"
    reason: Invalid
  - expression: "variables.images.all(i, variables.registres.exists(r, i.startsWith(r)))"
    messageExpression: "'image hors des registres autorisés (' + params.data.registres + ') : ' + variables.images.filter(i, !variables.registres.exists(r, i.startsWith(r))).join(', ')"
    reason: Forbidden
```

La politique s'applique aux Pods **et** aux objets qui en contiennent un gabarit. On l'a appris au chapitre 44 : refuser un Deployment à sa création vaut mieux que refuser ses Pods plus tard, en silence. Les `variables` évitent de répéter la même expression : `gabarit` trouve la spécification de Pod où qu'elle soit, `images` rassemble toutes les images, conteneurs d'initialisation compris. La première règle exige une empreinte, ou une étiquette autre que `latest` ; elle découpe sur `/` pour ne pas confondre le port d'un registre (`:5001`) avec une étiquette. La seconde compare chaque image à une liste de préfixes autorisés, qui n'est pas écrite dans la politique : elle vient d'un **paramètre**, ici une ConfigMap.

```yaml title="politiques/images-parametres.yaml (extrait)"
apiVersion: v1
kind: ConfigMap
metadata:
  name: images-autorisees
  namespace: politiques
data:
  registres: "host.minikube.internal:5001/,redis:,postgres:,busybox:"
```

La politique ne s'applique encore nulle part. C'est la **liaison** (*binding*) qui dit où, avec quels paramètres, et quoi faire en cas d'échec :

```yaml title="politiques/images-liaison.yaml"
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: images-colis
spec:
  policyName: images-colis
  validationActions: [Deny]
  paramRef:
    name: images-autorisees
    namespace: politiques
    parameterNotFoundAction: Deny
  matchResources:
    namespaceSelector:
      matchLabels:
        cours/politique-images: "oui"
```

`validationActions` vaut `Deny` (refuser), `Warn` (avertir le client) ou `Audit` (annoter le journal d'audit), comme les modes de Pod Security. `parameterNotFoundAction: Deny` dit quoi faire si la ConfigMap a disparu : refuser plutôt que laisser passer sans contrôle. On a rangé les paramètres dans un namespace à eux, `politiques`, et pas dans un namespace d'essai qu'on supprimera : avec `Deny`, la disparition des paramètres bloquerait toutes les applications liées.

```bash
kubectl apply -f politiques/images-politique.yaml -f politiques/images-parametres.yaml -f politiques/images-liaison.yaml
kubectl get validatingadmissionpolicy images-colis -o json | jq -c '.status.typeChecking'
kubectl label ns ch45 cours/politique-images=oui
kubectl -n ch45 run essai --image=nginx:latest --dry-run=server -o name
# idem avec busybox, busybox:1.37, docker.io/library/busybox:1.37, host.minikube.internal:5001/colis/api:2.1
```

```sortie
validatingadmissionpolicy.admissionregistration.k8s.io/images-colis created
namespace/politiques created
configmap/images-autorisees created
validatingadmissionpolicybinding.admissionregistration.k8s.io/images-colis created
{}
$ ... --image=nginx:latest
The pods "essai" is invalid: : ValidatingAdmissionPolicy 'images-colis' with binding 'images-colis' denied request: chaque image doit porter une étiquette autre que latest, ou une empreinte : nginx:latest
$ ... --image=busybox
The pods "essai" is invalid: : ValidatingAdmissionPolicy 'images-colis' with binding 'images-colis' denied request: chaque image doit porter une étiquette autre que latest, ou une empreinte : busybox
$ ... --image=busybox:1.37
pod/essai
$ ... --image=docker.io/library/busybox:1.37
Error from server (Forbidden): pods "essai" is forbidden: ValidatingAdmissionPolicy 'images-colis' with binding 'images-colis' denied request: image hors des registres autorisés (host.minikube.internal:5001/,redis:,postgres:,busybox:) : docker.io/library/busybox:1.37
$ ... --image=host.minikube.internal:5001/colis/api:2.1
pod/essai
```

`--dry-run=server` fait passer la requête par toute l'admission sans rien enregistrer : c'est la bonne façon de tester une politique. Le `reason` de chaque règle choisit le code de réponse, `422 Invalid` ou `403 Forbidden`, ce qui explique les deux formulations. En mode `Deny`, seule la première règle en échec est rapportée : `nginx:latest` viole aussi la règle des registres.

L'avant-dernière ligne montre une limite des comparaisons de chaînes. `docker.io/library/busybox:1.37` est **la même image** que `busybox:1.37`, écrite en entier, et la politique la refuse. Normaliser les noms d'images (registre par défaut, préfixe `library/`) en CEL est possible mais fastidieux. C'est le genre de travail où un outil spécialisé, comme Kyverno plus loin, rend service.

Le `{}` après la création n'est pas anodin : c'est le résultat de la **vérification de types**. L'API server connaît le schéma de chaque ressource visée et vérifie les expressions à l'avance. Une faute de frappe dans une autre politique, `object.spec.replica` au lieu de `replicas`, est signalée dès sa création, sans attendre la première requête :

```sortie
{
  "expressionWarnings": [
    {
      "fieldRef": "spec.validations[0].expression",
      "warning": "apps/v1, Kind=Deployment: ERROR: <input>:1:12: undefined field 'replica'\n | object.spec.replica <= 5\n | ...........^\n"
    }
  ]
}
```

Avant d'étiqueter le namespace de Colis, on vérifie que ses objets actuels respectent la politique : on les renvoie tels quels à l'API server, à blanc. Une ValidatingAdmissionPolicy ne juge que les requêtes, jamais les objets déjà enregistrés, et c'est le seul moyen de savoir.

```bash
kubectl -n colis get deploy,sts -o json | jq 'del(.items[].metadata.resourceVersion, .items[].metadata.managedFields)' \
  | kubectl replace --dry-run=server -f - -o name
kubectl label ns colis cours/politique-images=oui
kubectl -n colis set image deployment/web web=nginx:latest --dry-run=server
kubectl -n colis set image deployment/web web=nginx:1.30-alpine --dry-run=server
```

```sortie
deployment.apps/api
deployment.apps/api-canari
deployment.apps/redis
deployment.apps/web
deployment.apps/worker
statefulset.apps/postgres
namespace/colis labeled
error: failed to patch image update to pod template: deployments.apps "web" is forbidden: ValidatingAdmissionPolicy 'images-colis' with binding 'images-colis' denied request: chaque image doit porter une étiquette autre que latest, ou une empreinte : nginx:latest
error: failed to patch image update to pod template: deployments.apps "web" is forbidden: ValidatingAdmissionPolicy 'images-colis' with binding 'images-colis' denied request: image hors des registres autorisés (host.minikube.internal:5001/,redis:,postgres:,busybox:) : nginx:1.30-alpine
```

Les six objets de Colis passent, et Colis est désormais protégé contre une image mal choisie, en plus du niveau `restricted` du chapitre 44.

## Muter en CEL : MutatingAdmissionPolicy

Au chapitre 44, il a fallu écrire à la main, pour chaque composant de Colis, les quatre champs exigés par `restricted`. On pourrait les poser automatiquement. Une **MutatingAdmissionPolicy**, stable depuis Kubernetes 1.36, modifie les objets avec des expressions CEL[^map] :

```yaml title="politiques/defauts-securite.yaml (la politique)"
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicy
metadata:
  name: defauts-securite
spec:
  failurePolicy: Fail
  reinvocationPolicy: IfNeeded
  matchConstraints:
    resourceRules:
    - apiGroups: [""]
      apiVersions: ["v1"]
      operations: ["CREATE"]
      resources: ["pods"]
  mutations:
  - patchType: ApplyConfiguration
    applyConfiguration:
      expression: >
        Object{
          spec: Object.spec{
            securityContext: Object.spec.securityContext{
              runAsNonRoot: true,
              seccompProfile: Object.spec.securityContext.seccompProfile{type: "RuntimeDefault"}
            },
            containers: object.spec.containers.map(c, Object.spec.containers{
              name: c.name,
              securityContext: Object.spec.containers.securityContext{
                allowPrivilegeEscalation: false
              }
            })
          }
        }
  - patchType: JSONPatch
    jsonPatch:
      expression: >
        object.spec.containers.map(c, JSONPatch{
          op: "add",
          path: "/spec/containers/" + string(object.spec.containers.indexOf(c)) + "/securityContext/capabilities",
          value: Object.spec.containers.securityContext.capabilities{drop: ["ALL"]}
        })
```

Deux façons de muter cohabitent. La première, `ApplyConfiguration`, décrit l'état voulu d'une partie de l'objet, et l'API server le fusionne comme un *server-side apply* (chapitre 34) : les conteneurs sont fusionnés par leur nom, sans effacer ce qui n'est pas mentionné. La seconde, `JSONPatch`, liste des opérations précises. Pourquoi les deux ? Un premier essai posait aussi `capabilities.drop` dans l'`ApplyConfiguration`, et l'API server l'a refusé : `may not mutate atomic arrays, maps or structs: .spec.containers[0].securityContext.capabilities.drop`. Une liste « atomique » se remplace en bloc, et la fusion pourrait effacer des valeurs sans le dire ; la documentation l'interdit pour cette raison[^map]. Un JSON Patch, lui, dit explicitement ce qu'il remplace.

Le namespace `ch45-mut` est en `enforce=restricted`. Un Pod busybox qui ne déclare qu'un utilisateur y est d'abord refusé, puis accepté une fois la politique liée au namespace :

```bash
kubectl -n ch45-mut run dormeur --image=busybox:1.37 --overrides='{"apiVersion":"v1","spec":{"securityContext":{"runAsUser":65534}}}' -- sleep 3600
kubectl apply -f politiques/defauts-securite.yaml
kubectl label ns ch45-mut cours/defauts-securite=oui
kubectl -n ch45-mut run dormeur --image=busybox:1.37 --overrides='{"apiVersion":"v1","spec":{"securityContext":{"runAsUser":65534}}}' -- sleep 3600
kubectl -n ch45-mut get pod dormeur -o json | jq '{pod: .spec.securityContext, conteneur: .spec.containers[0].securityContext}'
```

```sortie
Error from server (Forbidden): pods "dormeur" is forbidden: violates PodSecurity "restricted:v1.37": allowPrivilegeEscalation != false (container "dormeur" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "dormeur" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "dormeur" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "dormeur" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
mutatingadmissionpolicy.admissionregistration.k8s.io/defauts-securite created
mutatingadmissionpolicybinding.admissionregistration.k8s.io/defauts-securite created
pod/dormeur created
{
  "pod": {
    "runAsNonRoot": true,
    "runAsUser": 65534,
    "seccompProfile": {
      "type": "RuntimeDefault"
    }
  },
  "conteneur": {
    "allowPrivilegeEscalation": false,
    "capabilities": {
      "drop": [
        "ALL"
      ]
    }
  }
}
```

La mutation a eu lieu avant Pod Security, qui a ensuite vu un Pod conforme. Le `runAsUser` d'origine est intact. C'est commode, mais réfléchissez avant de généraliser. Une mutation qui impose `drop: [ALL]` cassera silencieusement une application qui avait besoin d'une capability. Et des réglages qui n'apparaissent pas dans les manifestes rendent le comportement plus difficile à comprendre. Beaucoup d'équipes préfèrent valider (refuser avec un message clair) et réserver la mutation aux valeurs par défaut sans risque.

## Écrire un webhook

Une politique CEL ne voit que l'objet de la requête et ses paramètres. Elle ne peut rien demander au monde extérieur. Or une erreur fréquente est de déployer une étiquette d'image qui n'existe pas : `api:2.2` au lieu de `api:2.1`. Le Deployment est accepté, et les Pods restent en `ImagePullBackOff` (chapitre 17). Pour le refuser à l'entrée, il faut interroger le registre au moment de l'admission. C'est le travail d'un **webhook**.

Un webhook d'admission est un serveur HTTPS. L'API server lui envoie un objet `AdmissionReview` contenant la requête (son `uid`, l'opération, l'objet), et attend en retour une `AdmissionReview` qui dit `allowed: true` ou `false`, avec un message[^webhook]. `webhook.py`, dans le kit, en est une version complète en une centaine de lignes de Python sans dépendance. Le cœur interroge le registre par une requête `HEAD` sur le manifeste de l'image :

```python title="webhook/webhook.py (extrait)"
def existe(image):
    """Demande au registre si l'image existe. Lève une exception s'il ne répond pas."""
    reste = image[len(REGISTRE) + 1:]
    if "@" in reste:
        nom, reference = reste.split("@", 1)
    elif ":" in reste.rsplit("/", 1)[-1]:
        nom, reference = reste.rsplit(":", 1)
    else:
        nom, reference = reste, "latest"
    requete = urllib.request.Request(f"http://{REGISTRE}/v2/{nom}/manifests/{reference}",
                                     method="HEAD", headers={"Accept": ACCEPT})
    try:
        urllib.request.urlopen(requete, timeout=2)
        return True
    except urllib.error.HTTPError as erreur:
        if erreur.code == 404:
            return False
        raise
```

```python title="webhook/webhook.py (la réponse)"
        a_verifier = [i for i in images(gabarit(objet)) if i.startswith(REGISTRE + "/")]
        manquantes = [i for i in a_verifier if not existe(i)]
        reponse = {"uid": requete["uid"], "allowed": not manquantes}
        if manquantes:
            reponse["status"] = {"code": 403, "message": "image absente du registre : " + ", ".join(manquantes)}
```

L'API server n'appelle un webhook qu'en HTTPS, et il doit faire confiance à son certificat. C'est cert-manager, installé au chapitre 28, qui s'en charge. Un `Certificate` auto-signé pour le nom du Service (`verif-images.verif-images.svc`) produit un Secret monté dans le Pod. L'annotation `cert-manager.io/inject-ca-from` sur la configuration du webhook demande au `cainjector` de recopier ce certificat dans le champ `caBundle`, celui où l'API server cherche l'autorité à croire. Le Pod du webhook est lui-même durci pour le niveau `restricted`, dans un namespace qui l'impose.

```yaml title="webhook/configuration.yaml"
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: verif-images
  annotations:
    cert-manager.io/inject-ca-from: verif-images/verif-images
webhooks:
- name: verif-images.cours.example
  admissionReviewVersions: [v1]
  sideEffects: None
  failurePolicy: Fail
  timeoutSeconds: 5
  clientConfig:
    service:
      namespace: verif-images
      name: verif-images
      path: /valider
  rules:
  - apiGroups: [""]
    apiVersions: [v1]
    operations: [CREATE, UPDATE]
    resources: [pods]
  - apiGroups: [apps]
    apiVersions: [v1]
    operations: [CREATE, UPDATE]
    resources: [deployments, statefulsets]
  namespaceSelector:
    matchLabels:
      cours/images-controlees: "oui"
```

`sideEffects: None` déclare que le webhook ne modifie rien ailleurs, ce qui permet à l'API server de l'appeler aussi pour les requêtes à blanc (`--dry-run=server`). Le `namespaceSelector` limite le webhook aux namespaces étiquetés. Ce n'est pas un détail : un webhook qui se contrôlerait lui-même, en `Fail`, ne pourrait plus jamais redémarrer, puisque la création de son propre Pod exigerait qu'il réponde.

<Figure svg={webhookVerif} num="45.2" alt="L'API server lit la ValidatingWebhookConfiguration (règles, caBundle, failurePolicy) et envoie en HTTPS une AdmissionReview (uid, objet) au Pod verif-images, derrière le Service verif-images:443, qui exécute webhook.py. Le Pod fait un HEAD sur le manifeste auprès du registre du cours host.minikube.internal:5001, qui répond 200 ou 404 ; le Pod répond allowed, ou status et message. cert-manager produit le Secret verif-images-tls monté dans le Pod, et son cainjector recopie le certificat dans le caBundle. Si le webhook est injoignable, en erreur ou trop lent : avec Fail, la requête est refusée ; avec Ignore, elle est acceptée sans contrôle.">
Le webhook <code>verif-images</code> de bout en bout. cert-manager fournit le certificat du serveur et le fait connaître à l'API server.
</Figure>

```bash
kubectl apply -f webhook/deploiement.yaml
kubectl -n verif-images create configmap verif-images-code --from-file=webhook.py
kubectl apply -f webhook/configuration.yaml
kubectl get validatingwebhookconfiguration verif-images -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | base64 -d | openssl x509 -noout -ext subjectAltName
kubectl label ns ch45 cours/images-controlees=oui
kubectl -n ch45 create deployment api-ok --image=host.minikube.internal:5001/colis/api:2.1 --dry-run=server -o name
kubectl -n ch45 create deployment api-faute --image=host.minikube.internal:5001/colis/api:2.2 --dry-run=server -o name
kubectl -n ch45 run p-faute --image=host.minikube.internal:5001/colis/apii:2.1 --dry-run=server -o name
kubectl -n ch45 run p-busybox --image=busybox:1.37 --dry-run=server -o name
kubectl -n verif-images logs deployment/verif-images
```

```sortie
X509v3 Subject Alternative Name: critical
    DNS:verif-images.verif-images.svc
deployment.apps/api-ok
error: failed to create deployment: admission webhook "verif-images.cours.example" denied the request: image absente du registre : host.minikube.internal:5001/colis/api:2.2
Error from server: admission webhook "verif-images.cours.example" denied the request: image absente du registre : host.minikube.internal:5001/colis/apii:2.1
pod/p-busybox
webhook prêt sur le port 8443
CREATE Deployment ch45/api-ok vérifiées=1 refusées=0
CREATE Deployment ch45/api-faute vérifiées=1 refusées=1
CREATE Pod ch45/p-faute vérifiées=1 refusées=1
CREATE Pod ch45/p-busybox vérifiées=0 refusées=0
```

Le `caBundle` contient bien le certificat du Service. Les étiquettes et les dépôts qui n'existent pas sont refusés à l'entrée, et les images d'autres registres ne sont pas vérifiées. Les métriques de l'API server comptent chaque décision, refus compris :

```sortie
apiserver_admission_webhook_admission_duration_seconds_count{name="verif-images.cours.example",operation="CREATE",rejected="false",type="validating"} 2
apiserver_admission_webhook_admission_duration_seconds_count{name="verif-images.cours.example",operation="CREATE",rejected="true",type="validating"} 2
```

### Quand le webhook tombe

Un webhook est un service comme un autre : il peut s'arrêter, être lent, ou ne plus joindre ce qu'il interroge. `failurePolicy` dit à l'API server ce qu'il fait alors[^webhook]. Arrêtons le webhook, en `Fail` d'abord, puis en `Ignore` :

```bash
kubectl -n verif-images scale deployment/verif-images --replicas=0
kubectl -n ch45 run p-panne --image=busybox:1.37 --dry-run=server -o name
kubectl -n default run p-ailleurs --image=busybox:1.37 --dry-run=server -o name
kubectl patch validatingwebhookconfiguration verif-images --type=json -p '[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]'
kubectl -n ch45 run p-panne --image=busybox:1.37 --dry-run=server -o name
kubectl -n ch45 run p-faute --image=host.minikube.internal:5001/colis/apii:2.1 --dry-run=server -o name
```

```sortie
deployment.apps/verif-images scaled
Error from server (InternalError): Internal error occurred: failed calling webhook "verif-images.cours.example": failed to call webhook: Post "https://verif-images.verif-images.svc:443/valider?timeout=5s": dial tcp 10.105.186.122:443: connect: connection refused
réponse en 0.10 s
pod/p-ailleurs
validatingwebhookconfiguration.admissionregistration.k8s.io/verif-images patched
pod/p-panne
pod/p-faute
```

En `Fail`, toute création est refusée dans les namespaces visés, même celle d'un busybox qui n'a rien à voir avec le registre. Ailleurs, rien ne change. Le refus est immédiat parce que la connexion est refusée ; un webhook qui ne répond pas du tout ferait attendre chaque requête jusqu'au délai, 5 secondes ici, 10 par défaut. En `Ignore`, tout passe, **y compris l'image qui n'existe pas** : le contrôle a simplement disparu.

Il n'y a pas de bon choix universel. `Fail` est le seul réglage sûr pour un contrôle de sécurité, mais il fait du webhook un composant aussi critique que l'API server : plusieurs réplicas, un PodDisruptionBudget, des requests de ressources, et une surveillance. `Ignore` convient à ce qui est utile sans être indispensable, comme le webhook de VPA. Remarquez les choix des projets installés à la partie IV : cert-manager est en `Fail` pour ses propres ressources, KEDA et VPA en `Ignore`.

:::panne[Internal error occurred: failed calling webhook ... connection refused]

Toute création échoue dans un ou plusieurs namespaces, avec un message qui nomme un webhook. Lisez le nom : `kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations` dit à qui il appartient, et le champ `clientConfig.service` dit quel Service il appelle. Vérifiez ensuite que ce Service a des Pods prêts (`kubectl get endpointslices -n <ns>`). Si le webhook appartient à un outil désinstallé, sa configuration est restée orpheline : la supprimer débloque tout, mais supprime aussi le contrôle. Un `x509: certificate signed by unknown authority` à la place de `connection refused` désigne un `caBundle` qui ne correspond pas au certificat du serveur : le `cainjector` de cert-manager est-il en marche ?

:::

## Kyverno

Les politiques CEL ont deux limites qu'on a croisées : elles ne jugent que les requêtes, pas les objets qui existent déjà, et elles ne savent que valider ou modifier l'objet en cours. **Kyverno**, projet de la CNCF, est un moteur de politiques qui va plus loin : il juge l'existant en arrière-plan et en tire des rapports, et il peut **générer** des objets[^kyverno]. Il fonctionne lui-même par des webhooks d'admission, et ses politiques récentes s'écrivent dans la même syntaxe CEL que les politiques natives. On l'installe par son chart Helm, publié en OCI, sans le contrôleur de nettoyage, inutile ici :

```bash
helm install kyverno oci://ghcr.io/kyverno/charts/kyverno --version 3.9.1 -n kyverno --create-namespace \
  --set cleanupController.enabled=false --wait
helm list -n kyverno -o json | jq -r '.[] | "\(.name) \(.chart) \(.app_version) \(.status)"'
```

```sortie
kyverno kyverno-3.9.1 v1.19.1 deployed
```

L'installation affiche un avertissement important : les anciens types de politiques de Kyverno (`ClusterPolicy`, `Policy`), que la plupart des exemples en ligne utilisent encore, sont dépréciés au profit des types `policies.kyverno.io` (`ValidatingPolicy`, `MutatingPolicy`, `GeneratingPolicy`, `ImageValidatingPolicy`). On n'utilise que ces derniers.

### Juger l'existant

Toutes les applications du cluster déclarent-elles une limite mémoire, comme le chapitre 23 le recommandait ? Une `ValidatingPolicy` en mode `Audit`, avec l'évaluation en arrière-plan activée, répond sans rien bloquer :

```yaml title="kyverno/limites-memoire.yaml"
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: limites-memoire
spec:
  validationActions: [Audit]
  evaluation:
    background:
      enabled: true
  matchConstraints:
    resourceRules:
    - apiGroups: [apps]
      apiVersions: [v1]
      operations: [CREATE, UPDATE]
      resources: [deployments, statefulsets]
  validations:
  - expression: >-
      object.spec.template.spec.containers.all(c,
        has(c.resources) && has(c.resources.limits) && 'memory' in c.resources.limits)
    messageExpression: >-
      'conteneurs sans limite mémoire : ' + object.spec.template.spec.containers
        .filter(c, !(has(c.resources) && has(c.resources.limits) && 'memory' in c.resources.limits))
        .map(c, c.name).join(', ')
```

La syntaxe est presque celle d'une ValidatingAdmissionPolicy. Kyverno évalue la règle sur tous les Deployments et StatefulSets existants, et écrit le résultat dans des objets `PolicyReport`, un par objet jugé, au format défini par un groupe de travail de Kubernetes[^rapports] :

```bash
kubectl apply -f kyverno/limites-memoire.yaml
kubectl get policyreports -A -o json | jq -r '.items[] | "\(.metadata.namespace)\t\(.scope.kind)/\(.scope.name)\t\(.summary.pass // 0)\t\(.summary.fail // 0)"' | sort
```

```sortie
NAMESPACE             OBJET                                                        PASS  FAIL
cert-manager          Deployment/cert-manager                                      0     1
cert-manager          Deployment/cert-manager-cainjector                           0     1
cert-manager          Deployment/cert-manager-webhook                              0     1
ch15                  Deployment/vitrine                                           0     1
colis                 Deployment/api                                               1     0
colis                 Deployment/api-canari                                        1     0
colis                 Deployment/redis                                             1     0
colis                 Deployment/web                                               1     0
colis                 Deployment/worker                                            1     0
colis                 StatefulSet/postgres                                         1     0
colis-defi            Deployment/api                                               1     0
colis-defi            Deployment/postgres                                          1     0
colis-defi            Deployment/redis                                             1     0
colis-defi            Deployment/web                                               1     0
colis-defi            Deployment/worker                                            1     0
colis-dev             Deployment/api                                               1     0
colis-dev             Deployment/redis                                             1     0
colis-dev             Deployment/web                                               1     0
colis-dev             Deployment/worker                                            1     0
colis-dev             StatefulSet/postgres                                         1     0
colis-helm            Deployment/api                                               1     0
colis-helm            Deployment/redis                                             1     0
colis-helm            Deployment/web                                               1     0
colis-helm            Deployment/worker                                            1     0
colis-helm            StatefulSet/postgres                                         1     0
default               Deployment/essai                                             0     1
envoy-gateway-system  Deployment/envoy-gateway                                     1     0
envoy-gateway-system  Deployment/envoy-passerelle-principale-f06cdbcb              0     1
keda                  Deployment/keda-admission-webhooks                           1     0
keda                  Deployment/keda-operator                                     1     0
keda                  Deployment/keda-operator-metrics-apiserver                   1     0
kube-system           Deployment/coredns                                           1     0
kube-system           Deployment/metrics-server                                    0     1
kube-system           Deployment/snapshot-controller                               0     1
kube-system           StatefulSet/csi-hostpath-attacher                            0     1
kube-system           StatefulSet/csi-hostpath-resizer                             0     1
kyverno               Deployment/kyverno-admission-controller                      1     0
kyverno               Deployment/kyverno-background-controller                     1     0
kyverno               Deployment/kyverno-reports-controller                        1     0
metallb-system        Deployment/controller                                        1     0
verif-images          Deployment/verif-images                                      1     0
vpa                   Deployment/vpa-vertical-pod-autoscaler-admission-controller  0     1
vpa                   Deployment/vpa-vertical-pod-autoscaler-recommender           0     1
vpa                   Deployment/vpa-vertical-pod-autoscaler-updater               0     1
```

(On a ajouté la ligne d'en-tête avec `column`.) Toutes les copies de Colis passent ; cert-manager, VPA, plusieurs composants de minikube et le proxy de la passerelle n'ont pas de limite mémoire. Chaque rapport porte le message de la règle : pour cert-manager, `conteneurs sans limite mémoire : cert-manager-controller`. C'est ce qu'il faut pour préparer une règle bloquante : on la publie d'abord en `Audit`, on corrige ou on exempte ce qui doit l'être, et seulement ensuite on passe en `Deny`.

### Générer des objets

Le chapitre 41 a fermé Colis par une NetworkPolicy de refus par défaut. Qui pense à la poser dans chaque nouveau namespace d'équipe ? Une `GeneratingPolicy` le fait à la création du namespace, et la maintient[^kyverno] :

```yaml title="kyverno/refus-par-defaut.yaml (extrait)"
apiVersion: policies.kyverno.io/v1
kind: GeneratingPolicy
metadata:
  name: refus-par-defaut
spec:
  evaluation:
    synchronize:
      enabled: true
  matchConstraints:
    resourceRules:
    - apiGroups: [""]
      apiVersions: [v1]
      operations: [CREATE]
      resources: [namespaces]
  matchConditions:
  - name: namespace-d-equipe
    expression: "has(object.metadata.labels) && 'cours/equipe' in object.metadata.labels"
  generate:
  - template:
      interpolate: cel
      value: |
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        metadata:
          name: refus-par-defaut
          namespace: (( object.metadata.name ))
        spec:
          podSelector: {}
          policyTypes: [Ingress, Egress]
  # un second gabarit, autoriser-dns, rouvre le DNS comme au chapitre 41
```

Les `(( ... ))` sont des expressions CEL interpolées dans le gabarit. `synchronize` demande à Kyverno de garder les objets générés conformes au gabarit. Deux namespaces d'équipe, l'un étiqueté après sa création, l'autre créé avec son étiquette :

```bash
kubectl apply -f kyverno/refus-par-defaut.yaml
kubectl create ns ch45-fret
kubectl label ns ch45-fret cours/equipe=fret
kubectl apply -f kyverno/ch45-equipe.yaml   # un Namespace créé avec l'étiquette cours/equipe: fret
kubectl -n ch45-fret get networkpolicy
kubectl -n ch45-equipe get networkpolicy
kubectl -n ch45-equipe delete networkpolicy refus-par-defaut
# puis on attend qu'elle revienne
```

```sortie
generatingpolicy.policies.kyverno.io/refus-par-defaut created
namespace/ch45-fret created
namespace/ch45-fret labeled
namespace/ch45-equipe created
No resources found in ch45-fret namespace.
NAME               POD-SELECTOR   AGE
autoriser-dns      <none>         6s
refus-par-defaut   <none>         6s
networkpolicy.networking.k8s.io "refus-par-defaut" deleted from ch45-equipe namespace
recréée après environ 2 s
```

Le namespace créé avec son étiquette a reçu ses deux politiques. L'autre n'a rien reçu : la politique ne se déclenche qu'à la **création**, et l'étiquette est arrivée après (l'exercice 4 corrige cela). Supprimer une politique générée ne sert à rien, Kyverno la recrée en deux secondes ; pour l'enlever durablement, il faut retirer l'étiquette du namespace ou modifier la politique. Chaque objet généré porte des étiquettes `generate.kyverno.io/*` qui le relient à la politique et au namespace déclencheur.

## Choisir son outil

| | Politiques CEL natives | Webhook écrit à la main | Kyverno |
|---|---|---|---|
| où s'exécute la règle | dans l'API server | dans votre service | dans le service de Kyverno |
| ce qu'elle peut consulter | l'objet, ses paramètres | tout ce que le code peut joindre | l'objet, d'autres objets du cluster, des registres |
| juge l'existant | non | non | oui, avec des rapports |
| génère des objets | non | à programmer | oui |
| si le composant tombe | rien ne tombe, l'API server évalue lui-même | `failurePolicy` | `failurePolicy` de ses webhooks |
| coût | aucun composant à faire tourner | un service critique à écrire et à exploiter | trois contrôleurs (256 Mio de mémoire demandés ici) |

Le conseil qui en découle : commencez par les politiques CEL natives, sans composant supplémentaire ni panne possible. Passez à Kyverno quand il faut juger l'existant, générer, ou vérifier des signatures d'images (chapitre 47). N'écrivez un webhook que pour une règle qui exige une information que personne d'autre ne sait obtenir, comme l'existence d'une image dans votre registre, et traitez-le alors comme un service de production.

:::panne[La politique utilise des paramètres qui n'existent plus]

En préparant ce chapitre, on a supprimé la ConfigMap `images-autorisees` pour voir `parameterNotFoundAction: Deny` à l'œuvre. Parfois, l'API server a refusé aussitôt, comme prévu. D'autres fois, il a continué pendant des minutes à évaluer la règle avec la liste supprimée, comme si de rien n'était. La différence : entre-temps, la politique avait été supprimée puis recréée. Le script de rejeu le reproduit :

```bash
kubectl delete -f politiques/images-politique.yaml
kubectl apply -f politiques/images-politique.yaml
kubectl -n politiques delete configmap images-autorisees
# dix secondes plus tard, une image latest dans colis :
kubectl -n colis set image deployment/web web=nginx:latest --dry-run=server
```

```sortie
chaque image doit porter une étiquette autre que latest, ou une empreinte : nginx:latest
```

La liste des registres n'existe plus dans etcd, et la règle l'utilise encore. Après un redémarrage de l'API server, la même suppression donne bien ``failed to configure binding: no params found for policy binding with `Deny` parameterNotFoundAction``. C'est un bogue connu de Kubernetes : quand une politique dont les paramètres sont d'un type intégré (une ConfigMap ici) n'a plus de liaison, l'informer partagé qui surveille ces paramètres s'arrête, et une politique recréée réutilise sa copie figée ; seuls les paramètres définis par une CRD y échappent[^bogue]. En attendant le correctif, préférez une CRD pour les paramètres d'une politique importante, ou redémarrez l'API server après avoir supprimé la dernière politique qui utilisait une ConfigMap.

:::

## Exercices

:::exercice[Exercice 1 : prévenir avant d'interdire]

La politique `images-colis` ne s'applique qu'aux namespaces étiquetés. Avant de l'imposer partout, on voudrait savoir ce qu'elle refuserait. Écrivez une seconde liaison, `images-colis-avertir`, qui applique la même politique à tous les namespaces sauf ceux du système et ceux déjà étiquetés, en mode avertissement. Testez-la avec un Deployment `nginx:latest` dans `default`. Que mettez-vous dans `parameterNotFoundAction`, et pourquoi ?

:::

<details>
<summary>Corrigé</summary>

```yaml title="corrige/images-avertir.yaml"
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: images-colis-avertir
spec:
  policyName: images-colis
  validationActions: [Warn, Audit]
  paramRef:
    name: images-autorisees
    namespace: politiques
    parameterNotFoundAction: Allow
  matchResources:
    namespaceSelector:
      matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: NotIn
        values: [kube-system, kube-public, kube-node-lease]
      - key: cours/politique-images
        operator: DoesNotExist
```

```bash
kubectl apply -f corrige/images-avertir.yaml
kubectl -n default create deployment essai-latest --image=nginx:latest --dry-run=server -o name
kubectl -n default create deployment essai-busybox --image=busybox:1.37 --dry-run=server -o name
```

```sortie
validatingadmissionpolicybinding.admissionregistration.k8s.io/images-colis-avertir created
Warning: Validation failed for ValidatingAdmissionPolicy 'images-colis' with binding 'images-colis-avertir': chaque image doit porter une étiquette autre que latest, ou une empreinte : nginx:latest
Warning: Validation failed for ValidatingAdmissionPolicy 'images-colis' with binding 'images-colis-avertir': image hors des registres autorisés (host.minikube.internal:5001/,redis:,postgres:,busybox:) : nginx:latest
deployment.apps/essai-latest
deployment.apps/essai-busybox
```

En mode `Warn`, **toutes** les règles en échec sont rapportées, pas seulement la première : c'est exactement ce qu'on veut pour un inventaire. Une même politique peut avoir plusieurs liaisons, chacune avec sa portée et ses actions. Pour `parameterNotFoundAction`, il faut `Allow` : `Deny` refuserait la requête si les paramètres manquaient, **quel que soit** le mode de la liaison. Une liaison censée seulement avertir pourrait alors bloquer tout le cluster, ce que montre l'exercice suivant.

</details>

:::exercice[Exercice 2 : les paramètres disparaissent]

Avec les deux liaisons en place, supprimez la ConfigMap `images-autorisees`, puis essayez une modification anodine de Colis (`kubectl set env deployment/web ESSAI=1 --dry-run=server`) et le Deployment `nginx:latest` dans `default`. Expliquez les deux résultats, puis recréez la ConfigMap. (Faites-le après un redémarrage de l'API server, ou lisez d'abord l'encadré sur le cache des paramètres.)

:::

<details>
<summary>Corrigé</summary>

```bash
kubectl -n politiques delete configmap images-autorisees
kubectl -n colis set env deployment/web ESSAI=1 --dry-run=server -o name
kubectl -n default create deployment essai-latest --image=nginx:latest --dry-run=server -o name
kubectl apply -f politiques/images-parametres.yaml
kubectl -n colis set env deployment/web ESSAI=1 --dry-run=server -o name
```

```sortie
configmap "images-autorisees" deleted from politiques namespace
error: failed to patch env update to pod template: deployments.apps "web" is forbidden: ValidatingAdmissionPolicy 'images-colis' with binding 'images-colis' denied request: failed to configure binding: no params found for policy binding with `Deny` parameterNotFoundAction
deployment.apps/essai-latest
namespace/politiques unchanged
configmap/images-autorisees created
deployment.apps/web
```

Dans `colis`, la liaison `Deny` refuse **toute** modification, même celle qui ne touche pas aux images : sans paramètres, la politique ne peut pas s'évaluer, et `parameterNotFoundAction: Deny` choisit de bloquer. C'est le comportement sûr, et la raison pour laquelle les paramètres vivent dans un namespace qu'on ne supprime pas. Dans `default`, la liaison d'avertissement, en `Allow`, ignore purement et simplement la politique : le Deployment `nginx:latest` passe, sans même un avertissement. Les deux réglages sont cohérents avec leur rôle : bloquer quand on protège, se taire quand on informe.

</details>

:::exercice[Exercice 3 : épingler les images par leur empreinte (programmation)]

Une étiquette comme `2.1` peut être déplacée vers une autre image ; une empreinte, non (chapitre 14). Ajoutez au webhook une route `/epingler`, appelée par une `MutatingWebhookConfiguration`, qui remplace l'étiquette de chaque image du registre du cours par son empreinte, dans les Deployments et StatefulSets des namespaces étiquetés `cours/images-epinglees=oui`. Le registre donne l'empreinte dans l'en-tête `Docker-Content-Digest` de sa réponse à `HEAD`. La réponse d'un webhook de mutation contient `patchType: JSONPatch` et un champ `patch`, la liste des opérations JSON Patch encodée en base64[^webhook].

:::

<details>
<summary>Corrigé</summary>

Le corrigé est `corrige/webhook-epingle.py`, qui garde la route de validation et ajoute celle de mutation, et `corrige/epingle-configuration.yaml`. Le calcul des opérations :

```python title="corrige/webhook-epingle.py (extrait)"
def epingler(objet):
    """Opérations JSON Patch qui remplacent chaque image étiquetée du registre par nom@empreinte."""
    operations = []
    spec = gabarit(objet)
    for liste in ("initContainers", "containers"):
        for i, conteneur in enumerate(spec.get(liste, [])):
            image = conteneur["image"]
            if not image.startswith(REGISTRE + "/") or "@" in image:
                continue
            nom, _ = decomposer(image)
            condense = empreinte(image)
            if condense:
                operations.append({"op": "replace", "path": f"{chemin_gabarit(objet)}/{liste}/{i}/image",
                                   "value": f"{REGISTRE}/{nom}@{condense}"})
    return operations
```

et, dans le gestionnaire de requêtes :

```python
        if self.path.startswith("/epingler"):
            operations = epingler(objet)
            reponse = {"uid": requete["uid"], "allowed": True}
            if operations:
                reponse["patchType"] = "JSONPatch"
                reponse["patch"] = base64.b64encode(json.dumps(operations).encode()).decode()
```

On remplace le code du webhook, on le redémarre, on déclare le webhook de mutation, et on étiquette le namespace :

```bash
kubectl -n verif-images create configmap verif-images-code --from-file=webhook.py=corrige/webhook-epingle.py --dry-run=client -o yaml | kubectl replace -f -
kubectl -n verif-images rollout restart deployment/verif-images
kubectl apply -f corrige/epingle-configuration.yaml
kubectl label ns ch45 cours/images-epinglees=oui
kubectl -n ch45 create deployment api-epinglee --image=host.minikube.internal:5001/colis/api:2.1 --dry-run=server -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n ch45 create deployment autre --image=busybox:1.37 --dry-run=server -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n verif-images logs deployment/verif-images | tail -4
```

```sortie
host.minikube.internal:5001/colis/api@sha256:ade99a611b6a907ceacc9deb10f1a7cc21a1f49f7f4395d5d5b5a145205ad3a5
busybox:1.37
épinglage Deployment ch45/api-epinglee : 1 image(s)
CREATE Deployment ch45/api-epinglee vérifiées=1 refusées=0
épinglage Deployment ch45/autre : 0 image(s)
CREATE Deployment ch45/autre vérifiées=0 refusées=0
```

Le journal montre l'ordre de la figure 45.1 : pour chaque requête, la mutation d'abord, puis la validation, qui voit l'image déjà épinglée. L'empreinte est celle qu'avait montrée le chapitre 43.

Deux pièges rencontrés en mettant cet exercice au point. Juste après `rollout restart`, l'ancien Pod répond encore quelques secondes, et l'ancien code ignore le chemin `/epingler` : attendez qu'il ait disparu. Plus subtil, le kubelet met à jour le fichier monté depuis une ConfigMap avec un léger retard. Un Pod redémarré trop tôt peut lire l'ancienne version, puis voir le fichier changer sous lui, alors que Python a déjà chargé l'ancien code. Vérifiez le contenu monté (`kubectl exec ... -- grep epingler /app/webhook.py`) avant de redémarrer.

</details>

:::exercice[Exercice 4 : les namespaces déjà là]

La `GeneratingPolicy` `refus-par-defaut` n'a rien fait pour `ch45-fret`, étiqueté après sa création. Modifiez-la pour qu'elle traite aussi les namespaces déjà étiquetés au moment où on l'applique, et ceux qui reçoivent l'étiquette plus tard. Vérifiez avec un nouveau namespace `ch45-tard`, étiqueté après sa création.

:::

<details>
<summary>Corrigé</summary>

Deux changements dans `corrige/refus-par-defaut-existants.yaml` : l'option `evaluation.generateExisting.enabled: true`, qui applique la politique aux déclencheurs existants, et l'opération `UPDATE` dans `matchConstraints`, pour réagir à un namespace modifié[^kyverno].

```yaml
  evaluation:
    synchronize:
      enabled: true
    generateExisting:
      enabled: true
  matchConstraints:
    resourceRules:
    - apiGroups: [""]
      apiVersions: [v1]
      operations: [CREATE, UPDATE]
      resources: [namespaces]
```

```bash
kubectl create ns ch45-tard
kubectl label ns ch45-tard cours/equipe=fret
kubectl -n ch45-tard get networkpolicy
kubectl apply -f corrige/refus-par-defaut-existants.yaml
kubectl -n ch45-tard get networkpolicy
kubectl -n ch45-fret get networkpolicy
```

```sortie
namespace/ch45-tard labeled
No resources found in ch45-tard namespace.
generatingpolicy.policies.kyverno.io/refus-par-defaut configured
NAME               POD-SELECTOR   AGE
autoriser-dns      <none>         2s
refus-par-defaut   <none>         2s
NAME               POD-SELECTOR   AGE
autoriser-dns      <none>         2s
refus-par-defaut   <none>         2s
```

Avec la politique d'origine, `ch45-tard` n'a rien reçu. Dès que la nouvelle version est appliquée, `generateExisting` traite les deux namespaces déjà étiquetés. Un namespace étiqueté plus tard sera traité grâce à `UPDATE`. La condition `matchConditions` garde son rôle : un namespace sans l'étiquette reste ignoré, même modifié.

</details>

## Nettoyer

```bash
kubectl delete validatingwebhookconfiguration verif-images
kubectl delete mutatingwebhookconfiguration epingle-images
kubectl delete mutatingadmissionpolicybinding defauts-securite
kubectl delete mutatingadmissionpolicy defauts-securite
kubectl delete generatingpolicy refus-par-defaut
kubectl delete validatingpolicy limites-memoire
kubectl delete namespace ch45 ch45-mut ch45-fret ch45-equipe ch45-tard verif-images
```

Supprimez les webhooks **avant** le namespace de leur service : dans l'autre ordre, ils resteraient déclarés sans personne pour leur répondre. La politique `images-colis`, sa liaison et le namespace `politiques` restent en place : ils protègent Colis, et le défi VI les vérifiera. Kyverno reste installé lui aussi, pour le chapitre 47 ; pour le retirer, `helm uninstall kyverno -n kyverno`.

[^vap]: Kubernetes, « Validating Admission Policy » : stable depuis 1.30, CEL, paramètres (`paramKind`, `paramRef`, `parameterNotFoundAction`), `validationActions` Deny, Warn et Audit, vérification de types dans `status.typeChecking`. [kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/)
[^map]: Kubernetes, « Mutating Admission Policy » : stable depuis 1.36, mutations `ApplyConfiguration` et `JSONPatch`, interdiction de modifier les listes, maps et structures atomiques par une `ApplyConfiguration`, `reinvocationPolicy`. [kubernetes.io/docs/reference/access-authn-authz/mutating-admission-policy](https://kubernetes.io/docs/reference/access-authn-authz/mutating-admission-policy/)
[^webhook]: Kubernetes, « Dynamic Admission Control » : configuration des webhooks, `AdmissionReview`, réponses de mutation en JSON Patch encodé en base64, `sideEffects`, délai par défaut de 10 secondes, `failurePolicy` (Ignore, Fail) et cas d'erreur couverts, métriques. [kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/)
[^kyverno]: Kyverno, « ValidatingPolicy » et « GeneratingPolicy » : syntaxe CEL, évaluation en arrière-plan, gabarits interpolés, `synchronize`, `generateExisting`, déclenchement à la création ou à la modification. [kyverno.io/docs/policy-types/generating-policy](https://kyverno.io/docs/policy-types/generating-policy/), [kyverno.io/docs/policy-types/validating-policy](https://kyverno.io/docs/policy-types/validating-policy/)
[^rapports]: Kubernetes SIG Auth, Policy Working Group, API `wgpolicyk8s.io` des `PolicyReport` et `ClusterPolicyReport`, utilisée par Kyverno pour ses rapports. [github.com/kubernetes-sigs/wg-policy-prototypes](https://github.com/kubernetes-sigs/wg-policy-prototypes)
[^bogue]: Kubernetes, pull request #141015, « Keep core-type paramKind informers running when an admission policy is unbound », qui décrit les deux symptômes (refus permanent, ou paramètres figés) et précise que les paramètres définis par une CRD ne sont pas touchés ; voir aussi la pull request #142150 (rétroportage d'un correctif partiel sur la branche 1.36). [github.com/kubernetes/kubernetes/pull/141015](https://github.com/kubernetes/kubernetes/pull/141015)
