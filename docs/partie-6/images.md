---
title: Faire confiance aux images
sidebar_label: 47. Faire confiance aux images
description: "Ne laisser tourner que des images dont on connaît l'origine : signatures vérifiées à l'admission par Kyverno, épinglage par empreinte, analyses de vulnérabilités signées et exigées, signatures sans clé des projets tiers, et deux incompatibilités réelles entre cosign 3 et Kyverno, mesurées et contournées."
partie: 6
chapitre: '47'
---

import imageConfiance from '@site/src/figures/image-confiance.svg';
import avecSansCle from '@site/src/figures/avec-sans-cle.svg';

Combien d'images différentes tournent en ce moment sur votre cluster minikube, et d'où viennent-elles ?

```bash
kubectl get pods -A -o json | jq -r '[.items[].spec.containers[].image] | unique | .[]' > images.txt
wc -l < images.txt
sed -E 's#^([^/]+\.[^/]+|[^/]+:[0-9]+)/.*#\1#; t; s#.*#docker.io (implicite)#' images.txt | sort | uniq -c | sort -rn
```

```sortie
45 images différentes
     19 registry.k8s.io
      6 docker.io (implicite)
      5 quay.io
      4 ghcr.io
      4 docker.io
      3 reg.kyverno.io
      3 host.minikube.internal:5001
      1 gcr.io
```

Quarante-cinq images, venues de huit registres. Chacune a été construite par quelqu'un, avec des dépendances choisies par quelqu'un, et publiée sous une étiquette qui peut, à tout moment, désigner autre chose (le chapitre 14 a détourné une étiquette pour le montrer). Jusqu'ici, le cluster les a toutes acceptées sur la foi de leur nom. Le chapitre 45 a restreint les **registres** autorisés pour Colis ; c'est utile, mais cela ne dit pas qui a construit une image, ni ce qu'elle contient.

Ce chapitre ajoute ce qui manque. Le cluster vérifie, à l'admission, que les images de Colis sont **signées** par la clé de l'équipe, et qu'elles sont accompagnées d'une **analyse de vulnérabilités** signée elle aussi, sans faille grave. On regarde aussi comment vérifier les images des projets qu'on installe, signées sans clé par leurs chaînes de publication. Les signatures reposent sur cosign et les clés du chapitre 14 ; la vérification, sur Kyverno, installé au chapitre 45. Les fichiers sont dans [l'archive images](pathname:///kits/images.tar.gz).

<Figure svg={imageConfiance} num="47.1" alt="L'intégration continue construit colis/web:1.1, l'analyse avec Trivy, et pousse l'image dans le registre : image sha256:9ac4…, et une étiquette 1.1, simple pointeur mobile. Avec la clé privée cosign.key, gardée par qui publie, on signe et on atteste : le registre reçoit à côté de l'image sha256-9ac4….sig, la signature, et sha256-9ac4….att, l'analyse signée. L'admission (Kyverno) lit le registre et fait quatre choses : étiquette vers empreinte, signature vérifiée avec la clé publique, analyse signée sans faille grave, et le Pod reçoit web:1.1@sha256:9ac4…. La clé publique est dans la politique.">
Ce qui accompagne une image de confiance dans le registre, et ce que l'admission en vérifie. L'étiquette ne sert qu'à trouver l'empreinte ; tout le reste porte sur l'empreinte.
</Figure>

## Exiger une signature

Le chapitre 14 a signé deux images avec la clé `cosign.key` : `cours/tampon:1.0.0`, et `colis/api:2.0` au défi II. Les images qui tournent dans Colis, `api:2.1` et `web:1.0`, sont arrivées après ; on les signe donc à leur tour. Puis on écrit la règle : dans les namespaces étiquetés `cours/images-signees=oui`, toute image du registre du cours doit porter une signature valide de la clé du cours. C'est une **ImageValidatingPolicy**, le type de politique de Kyverno dédié aux images[^ivpol] :

```yaml title="images-signees.yaml.modele"
apiVersion: policies.kyverno.io/v1
kind: ImageValidatingPolicy
metadata:
  name: images-signees
spec:
  validationActions: [Deny]
  matchConstraints:
    resourceRules:
    - apiGroups: [""]
      apiVersions: [v1]
      operations: [CREATE, UPDATE]
      resources: [pods]
    namespaceSelector:
      matchLabels:
        cours/images-signees: "oui"
  # seules les images du registre du cours sont concernées
  matchImageReferences:
  - glob: "host.minikube.internal:5001/*"
  credentials:
    allowInsecureRegistry: true      # le registre du cours parle HTTP
  attestors:
  - name: cours
    cosign:
      key:
        data: |
          CLE_PUBLIQUE
      ctlog:
        insecureIgnoreTlog: true     # signatures faites hors ligne, sans journal de transparence (chapitre 14)
        insecureIgnoreSCT: true
  validationConfigurations:
    required: true
    verifyDigest: true
    mutateDigest: true
  validations:
  - expression: >-
      images.containers.map(image, verifyImageSignatures(image, [attestors.cours])).all(n, n > 0)
    message: "image du registre du cours sans signature valide de la clé du cours"
```

Les **attestors** disent à qui l'on fait confiance : ici, la clé publique `cosign.pub` du chapitre 14, que `avec-cle.py` insère à la place de `CLE_PUBLIQUE`. Les options `ctlog` acceptent des signatures absentes du journal de transparence public : on a signé hors ligne, sur un registre local. `mutateDigest` remplace l'étiquette de chaque image vérifiée par son empreinte. `verifyDigest` garantit que c'est bien cette empreinte qui a été vérifiée. La règle elle-même est une expression CEL, comme au chapitre 45 : `verifyImageSignatures` compte les signatures valides d'une image, et il en faut au moins une pour chaque conteneur.

Une remarque sur `matchImageReferences`. La documentation de Kyverno montre une expression `image.registry == '...'`, qui est refusée à la création par Kyverno 1.19.1 (`undeclared reference to 'image'`). Le motif `glob` fonctionne, et `*` y couvre aussi les `/` : `colis/api` est bien concerné.

### Le format de signature compte

Signons une image neuve, `cours/format-recent:1.0`, exactement comme au chapitre 14, puis demandons-la dans le namespace `ch47`, soumis à la politique :

```bash
cosign sign --yes --key cosign.key --signing-config sans-journal.json --allow-http-registry localhost:5001/cours/format-recent@sha256:b2a5180e…
cosign verify --key cosign.pub --insecure-ignore-tlog=true --allow-http-registry localhost:5001/cours/format-recent:1.0
kubectl -n ch47 run essai --image=host.minikube.internal:5001/cours/format-recent:1.0 --dry-run=server -o name
```

```sortie
Pushing signature to: localhost:5001/cours/format-recent
cosign verify : signature valide
$ cours/format-recent:1.0
Error from server: admission webhook "ivpol.validate.kyverno.svc-fail" denied the request: Policy images-signees failed: image du registre du cours sans signature valide de la clé du cours
```

cosign trouve la signature, Kyverno ne la trouve pas. Le journal du contrôleur d'admission de Kyverno le dit en toutes lettres, lors des premiers essais de ce chapitre : `failed to verify cosign signatures: no signatures found`. L'explication est dans le registre :

```sortie
["1.0","sha256-b2a5180e0848995fc7ebd4e82c5851fe701ceea7413f7f06f6f40b0f2952e6f0"]
["application/vnd.dev.sigstore.bundle.v0.3+json"]
```

La première ligne liste les étiquettes du dépôt, la seconde le type de ce que porte l'étiquette `sha256-…`. cosign 3 range désormais une signature sous la forme d'un *bundle* Sigstore, rattaché à l'image par l'API *referrers* d'OCI 1.1. Notre registre (`registry:3`) n'offre pas cette API ; cosign se replie alors sur une étiquette `sha256-<empreinte>` qui pointe vers un index. Kyverno 1.19.1 ignore ces entrées sur un registre sans API *referrers* : c'est une question connue, ouverte chez Kyverno[^bundle]. Le contournement est de signer à l'**ancien format**, que cosign 3 sait encore produire :

```bash
cosign sign --yes --key cosign.key --new-bundle-format=false --use-signing-config=false --tlog-upload=false \
  --allow-http-registry localhost:5001/cours/format-recent@sha256:b2a5180e…
```

```sortie
Pushing signature to: localhost:5001/cours/format-recent
["1.0","sha256-b2a5180e0848995fc7ebd4e82c5851fe701ceea7413f7f06f6f40b0f2952e6f0","sha256-b2a5180e0848995fc7ebd4e82c5851fe701ceea7413f7f06f6f40b0f2952e6f0.sig"]
$ cours/format-recent:1.0
host.minikube.internal:5001/cours/format-recent:1.0@sha256:b2a5180e0848995fc7ebd4e82c5851fe701ceea7413f7f06f6f40b0f2952e6f0
```

L'ancien format range la signature sous l'étiquette `sha256-<empreinte>.sig`, que Kyverno lit. Le Pod est accepté, et son image est enregistrée **avec son empreinte** : `mutateDigest` a fait son travail. La morale dépasse cet exemple : deux outils de la même famille, chacun dans sa dernière version, ne s'entendent pas toujours. Testez la chaîne complète, de la signature au refus, avant de compter sur elle.

### Colis signé

On signe les deux images de Colis au même format, puis on rejoue l'essai avec elles et une image jamais signée :

```bash
cosign sign --yes --key cosign.key --new-bundle-format=false --use-signing-config=false --tlog-upload=false --allow-http-registry localhost:5001/colis/api@sha256:ade99a61…
cosign sign --yes --key cosign.key --new-bundle-format=false --use-signing-config=false --tlog-upload=false --allow-http-registry localhost:5001/colis/web@sha256:1a115fe5…
```

```sortie
Pushing signature to: localhost:5001/colis/api
Pushing signature to: localhost:5001/colis/web
$ colis/api:2.1
host.minikube.internal:5001/colis/api:2.1@sha256:ade99a611b6a907ceacc9deb10f1a7cc21a1f49f7f4395d5d5b5a145205ad3a5
$ colis/web:1.0
host.minikube.internal:5001/colis/web:1.0@sha256:1a115fe589222fc2bd7abac408e0f4ffb4bb2ad95ca7de70bb68c20cbd643dcc
$ cours/non-signee:1.0
Error from server: admission webhook "ivpol.validate.kyverno.svc-fail" denied the request: Policy images-signees failed: image du registre du cours sans signature valide de la clé du cours
```

Les images signées passent, épinglées ; l'image non signée est refusée. Une image d'un autre registre, `busybox:1.37`, n'est pas concernée : `matchImageReferences` ne la retient pas, et le Pod garde son étiquette. On peut désormais appliquer la politique à Colis :

```bash
kubectl label ns colis cours/images-signees=oui
kubectl -n colis rollout restart deployment/api
kubectl -n colis get pods -l app.kubernetes.io/name=api -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.containers[0].image}{"\n"}{end}'
kubectl -n colis get deploy api -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

```sortie
namespace/colis labeled
deployment.apps/api restarted
api-f7cb69f77-47mck  host.minikube.internal:5001/colis/api:2.1@sha256:ade99a611b6a907ceacc9deb10f1a7cc21a1f49f7f4395d5d5b5a145205ad3a5
api-f7cb69f77-dq7d7  host.minikube.internal:5001/colis/api:2.1@sha256:ade99a611b6a907ceacc9deb10f1a7cc21a1f49f7f4395d5d5b5a145205ad3a5
host.minikube.internal:5001/colis/api:2.1@sha256:ade99a611b6a907ceacc9deb10f1a7cc21a1f49f7f4395d5d5b5a145205ad3a5
```

(Les deux anciens Pods, encore en cours d'arrêt, ont été retirés de la sortie.) Les nouveaux Pods tournent avec l'image épinglée. Le Deployment aussi a été modifié : la politique ne vise que les Pods, mais Kyverno l'applique d'office aux objets qui en contiennent un gabarit. La politique d'images du chapitre 45 accepte cette forme, puisqu'elle autorise les empreintes.

:::panne[failed to resolve digest for image ... connect: connection refused]

Après un redémarrage du poste, plus aucun Pod de Colis ne démarre, et la création échoue avec ce message. Pour vérifier une signature, Kyverno doit joindre le registre, et le registre du cours n'a pas redémarré :

```sortie
Error from server: admission webhook "ivpol.mutate.kyverno.svc-fail" denied the request: Policy images-signees error: failed to update digest: failed to resolve digest for image host.minikube.internal:5001/colis/api:2.1: Get "https://host.minikube.internal:500
```

`docker start registre` règle le problème ici. La leçon est plus large : vérifier les images à l'admission fait du registre, et de Kyverno, des dépendances de **chaque création de Pod**, mises à l'échelle et redémarrages compris. En production, on surveille leur disponibilité comme celle de l'API server. On peut aussi limiter la politique aux namespaces où elle compte, ce que fait ici le sélecteur `cours/images-signees`.

:::

## Exiger une analyse signée

Une signature dit **qui** a publié une image, pas **ce qu'elle contient**. `web:1.0` est signée, et pourtant elle embarque des bibliothèques vulnérables. Le chapitre 14 a analysé des images avec Trivy ; il reste à attacher le résultat à l'image, de façon infalsifiable, et à l'exiger. C'est une **attestation** : un document (ici le rapport de Trivy), enveloppé dans une déclaration in-toto qui désigne l'image par son empreinte, et signé avec la même clé[^attestation].

Trivy sait produire son rapport directement au format attendu par cosign pour une attestation de vulnérabilités (`--format cosign-vuln`)[^trivy]. `signer-et-attester.sh` enchaîne les étapes : il résout l'empreinte, analyse, signe et atteste, au format classique.

```bash
bash signer-et-attester.sh colis/api:2.1
bash signer-et-attester.sh colis/web:1.0
cosign verify-attestation --key cosign.pub --type vuln --insecure-ignore-tlog=true --new-bundle-format=false \
  --allow-http-registry localhost:5001/colis/web:1.0 | jq -r .payload | base64 -d | jq -c '{predicateType, scanner: .predicate.scanner.uri, failles: [...]}'
```

```sortie
colis/api:2.1 (sha256:ade99a611b6a907ceacc9deb10f1a7cc21a1f49f7f4395d5d5b5a145205ad3a5) : {"MEDIUM":1}
Pushing signature to: localhost:5001/colis/api
Signing artifact...
colis/web:1.0 (sha256:1a115fe589222fc2bd7abac408e0f4ffb4bb2ad95ca7de70bb68c20cbd643dcc) : {"HIGH":2,"MEDIUM":3}
Pushing signature to: localhost:5001/colis/web
Signing artifact...
{"predicateType":"https://cosign.sigstore.dev/attestation/vuln/v1","scanner":"pkg:github/aquasecurity/trivy@0.74.0","failles":["libexpat CVE-2026-93990 HIGH","libpng CVE-2026-46675 MEDIUM","nghttp2-libs CVE-2026-58055 MEDIUM","pcre2 CVE-2026-103111 HIGH","zlib CVE-2026-85091 MEDIUM"]}
```

L'API n'a qu'une vulnérabilité moyenne. Le site web en a cinq, dont deux de sévérité élevée, toutes dans des bibliothèques de l'image de base Alpine de nginx. Les attestations sont rangées sous l'étiquette `sha256-<empreinte>.att`, à côté des signatures.

### Une politique, deux tentatives

La politique naturelle est une seconde `ImageValidatingPolicy`, `analyse-vulnerabilites.yaml.modele` dans le kit. Elle déclare l'attestation attendue par son type, vérifie sa signature avec `verifyAttestationSignatures`, puis lit son contenu avec `extractPayload` :

```yaml title="analyse-vulnerabilites.yaml.modele (extrait)"
  attestations:
  - name: vuln
    intoto:
      type: https://cosign.sigstore.dev/attestation/vuln/v1
  validations:
  - expression: >-
      images.containers.map(image, verifyAttestationSignatures(image, attestations.vuln, [attestors.cours])).all(n, n > 0)
    message: "aucune analyse de vulnérabilités signée par la clé du cours"
  - expression: >-
      images.containers.map(image, extractPayload(image, attestations.vuln).scanner.result.Results.all(r,
        !has(r.Vulnerabilities) || r.Vulnerabilities.all(v, v.Severity != 'CRITICAL' && v.Severity != 'HIGH'))).all(ok, ok)
    message: "l'analyse signée signale des vulnérabilités de sévérité HIGH ou CRITICAL"
```

```sortie
$ colis/api:2.1
Error from server: admission webhook "ivpol.validate.kyverno.svc-fail-d0545027" denied the request: Policy analyse-vulnerabilites failed: aucune analyse de vulnérabilités signée par la clé du cours
```

Même l'API, dont l'attestation est valide (`cosign verify-attestation` l'accepte), est refusée. Le journal de Kyverno donne `cosign bundle verification failed`. C'est un autre défaut de Kyverno 1.19.1, corrigé par une pull request encore ouverte : l'option `insecureIgnoreTlog` est respectée pour les signatures, mais pas pour les attestations, qui exigent donc une inscription au journal de transparence public[^tlog]. Deux issues raisonnables. La première consiste à inscrire les attestations au journal public Sigstore, ce qui publie l'empreinte de l'image et la signature dans un registre ouvert à tous, et que l'on évite pour un registre interne. La seconde, retenue ici, reprend l'ancien type de politique de Kyverno, `ClusterPolicy`, déprécié mais qui gère correctement ce cas, en attendant le correctif :

```yaml title="analyse-vulnerabilites-classique.yaml.modele (extrait)"
    verifyImages:
    - imageReferences: ["host.minikube.internal:5001/*"]
      mutateDigest: true
      imageRegistryCredentials:
        allowInsecureRegistry: true
      attestations:
      - type: https://cosign.sigstore.dev/attestation/vuln/v1
        attestors:
        - entries:
          - keys:
              publicKeys: |-
                CLE_PUBLIQUE
              rekor:
                ignoreTlog: true
              ctlog:
                ignoreSCT: true
        conditions:
        - all:
          - key: "{{ scanner.result.Results[].Vulnerabilities[?Severity=='HIGH' || Severity=='CRITICAL'][] | length(@) }}"
            operator: Equals
            value: 0
            message: "l'analyse signée signale des vulnérabilités de sévérité HIGH ou CRITICAL"
```

La condition est écrite en JMESPath, le langage de requêtes des anciennes politiques Kyverno : elle compte les vulnérabilités élevées ou critiques du rapport, et en exige zéro.

```sortie
clusterpolicy.kyverno.io/analyse-vulnerabilites-classique created
$ colis/api:2.1
host.minikube.internal:5001/colis/api:2.1@sha256:ade99a611b6a907ceacc9deb10f1a7cc21a1f49f7f4395d5d5b5a145205ad3a5
$ colis/web:1.0
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request: 
analyse-vulnerabilites-classique:
  analyse-signee-sans-faille-grave: 'image attestations verification failed, verifiedCount: 0, requiredCount: 1, error: .attestations[0].attestors[0].entries[0].keys: attestation checks failed for host.minikube.internal:5001/colis/web:1.0 and predicate https://cosign.sigstore.dev/attestation/vuln/v1: l''analyse signée signale d
$ cours/non-signee:1.0
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request: 
analyse-vulnerabilites-classique:
  analyse-signee-sans-faille-grave: 'image attestations verification failed, verifiedCount: 0, requiredCount: 1, error: no matching attestations: '
```

(Kyverno affiche à chaque création un avertissement de dépréciation, retiré ici, et sa ligne d'en-tête `resource Pod/... was blocked`.) L'API passe. Le site est refusé à cause du contenu de son analyse, et l'image sans attestation faute d'analyse. On ne l'impose pas encore à Colis : son site serait refusé au prochain redémarrage. Il faut d'abord corriger `web`, ce que fait l'exercice 3.

Une limite à garder en tête : une analyse est datée. Celle de `api:2.1` ne connaît que les failles publiées le jour où elle a été faite, et une image sans faille aujourd'hui en aura demain. Une chaîne sérieuse refait l'analyse régulièrement, attache la nouvelle attestation, et peut exiger dans la politique une analyse de moins de quelques jours.

## Les images des autres

Colis ne représente que trois des 45 images du cluster. Les autres viennent de projets qui les publient eux-mêmes, et beaucoup les signent, avec une autre méthode : la signature **sans clé** (*keyless*). Pas de clé privée à garder. La chaîne de publication du projet obtient de GitHub une identité OIDC, l'échange auprès de l'autorité de Sigstore (Fulcio) contre un certificat de courte durée, signe avec, et inscrit la signature au journal public Rekor[^sigstore]. On vérifie alors une **identité** : « signée par le workflow de publication de tel dépôt », plutôt qu'une clé.

<Figure svg={avecSansCle} num="47.2" alt="Deux lignes. Avec une clé, le cas de Colis dans ce cours : une clé privée gardée par l'équipe, à protéger et faire tourner, produit une signature dans le registre ; on vérifie qu'elle a été faite par la clé dont on a la partie publique. Sans clé, le cas de Kyverno et d'External Secrets : le workflow de publication reçoit une identité OIDC de GitHub Actions, obtient un certificat éphémère de Fulcio, et la signature est inscrite au journal public Rekor ; on vérifie qu'elle a été faite par ce workflow de ce dépôt, à tel commit.">
Signer avec une clé, ou sans clé. Dans le second cas, ce qu'on vérifie n'est plus la possession d'une clé, mais l'identité de la chaîne qui a publié.
</Figure>

Vérifions l'image de Kyverno qui tourne dans le cluster. Ses signatures sont rangées à part, dans `ghcr.io/kyverno/signatures`, ce que cosign apprend par `COSIGN_REPOSITORY` :

```bash
COSIGN_REPOSITORY=ghcr.io/kyverno/signatures cosign verify reg.kyverno.io/kyverno/kyverno:v1.19.1 \
  --certificate-identity-regexp '^https://github.com/kyverno/kyverno/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
kubectl -n kyverno get pods -l app.kubernetes.io/component=admission-controller -o jsonpath='{.items[0].status.containerStatuses[0].imageID}{"\n"}'
```

```sortie
code de sortie : 0
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
{"empreinte":"sha256:b31d8511ae5fd6010e2a01ea72ebae08eb82fa51d91af14a1d9fe989949b4edb","optional":{"kind":"image","ref":"40ec788d48bb28d83dbf85538e962a59db9d45c6","repo":"kyverno/kyverno","workflow":"releaser"}}
reg.kyverno.io/kyverno/kyverno@sha256:b31d8511ae5fd6010e2a01ea72ebae08eb82fa51d91af14a1d9fe989949b4edb
```

(Le script de rejeu résume la sortie JSON de cosign en une ligne.) La signature a été faite par une identité issue du dépôt `kyverno/kyverno`, et l'inscription au journal a été vérifiée. Le projet a ajouté à sa signature le commit source et le nom du workflow, `releaser`. L'empreinte signée est exactement celle de l'image qui tourne. Les options `--certificate-identity-regexp` et `--certificate-oidc-issuer` sont obligatoires, et c'est tout l'intérêt : sans elles, n'importe quelle signature sans clé, faite par n'importe qui, serait acceptée. Une `ImageValidatingPolicy` peut exiger la même chose avec un attestor `keyless` qui liste les identités admises[^ivpol]. On l'écrirait pour les namespaces de Kyverno, d'External Secrets ou de cert-manager.

## Les registres et le cache du nœud

Le chapitre 45 a limité les registres autorisés pour Colis par une politique CEL, et ce chapitre a épinglé ses images par empreinte. Reste une question que les politiques d'admission ne voient pas : une image **privée**, déjà téléchargée sur un nœud, peut-elle être utilisée par un Pod qui n'aurait pas les identifiants pour la télécharger ? Longtemps, oui, avec `imagePullPolicy: IfNotPresent`. Le kubelet tient désormais un registre des téléchargements et des identifiants qui les ont permis, et vérifie les identifiants avant de réutiliser une image en cache[^images] :

```bash
kubectl get --raw /api/v1/nodes/minikube/proxy/configz | jq '.kubeletconfig | {imagePullCredentialsVerificationPolicy, preloadedImagesVerificationAllowlist}'
```

```sortie
{
  "imagePullCredentialsVerificationPolicy": "NeverVerifyPreloadedImages",
  "preloadedImagesVerificationAllowlist": null
}
```

`NeverVerifyPreloadedImages`, la valeur par défaut, vérifie toutes les images téléchargées par le kubelet, mais pas celles déposées sur le nœud par d'autres moyens, comme `minikube image load`. `AlwaysVerify` vérifierait tout. C'est ce mécanisme, avec ses fiches dans `/var/lib/kubelet/image_manager/`, qui avait causé au chapitre 24 un `ErrImagePull` inattendu après un `minikube image load`. L'ancienne solution, le contrôleur d'admission `AlwaysPullImages`, force un téléchargement à chaque démarrage de conteneur ; elle reste possible, au prix d'une dépendance permanente au registre.

## Exercices

:::exercice[Exercice 1 : la mauvaise clé]

Signez l'image `cours/autre-cle:1.0` avec la clé du dossier `autre` du chapitre 14, au format classique, et demandez-la dans `ch47`. Le message de Kyverno distingue-t-il ce cas d'une image non signée ? Comment savoir, avec cosign, quelle clé a signé ?

:::

<details>
<summary>Corrigé</summary>

```bash
cosign sign --yes --key autre/cosign.key --new-bundle-format=false --use-signing-config=false --tlog-upload=false \
  --allow-http-registry localhost:5001/cours/autre-cle@sha256:7cefa58b…
kubectl -n ch47 run essai --image=host.minikube.internal:5001/cours/autre-cle:1.0 --dry-run=server -o name
cosign verify --key cosign.pub --insecure-ignore-tlog=true --new-bundle-format=false --allow-http-registry localhost:5001/cours/autre-cle:1.0
cosign verify --key autre/cosign.pub --insecure-ignore-tlog=true --new-bundle-format=false --allow-http-registry localhost:5001/cours/autre-cle:1.0
```

```sortie
Pushing signature to: localhost:5001/cours/autre-cle
$ cours/autre-cle:1.0
Error from server: admission webhook "ivpol.validate.kyverno.svc-fail" denied the request: Policy images-signees failed: image du registre du cours sans signature valide de la clé du cours
error during command execution: no matching signatures: invalid signature when validating ASN.1 encoded signature
  - The cosign claims were validated
  - The signatures were verified against the specified public key
```

Pour la politique, une image signée par une autre clé et une image non signée sont dans le même cas : aucune signature **valide pour la clé attendue**. Le message, écrit par nous, ne les distingue pas. cosign le fait : avec la clé du cours, `invalid signature` (une signature existe, mais ne correspond pas) ; avec l'autre clé, la vérification réussit. Une signature n'a de valeur que par la clé à laquelle on la confronte, et cette clé publique est la vraie racine de confiance de la politique : qui peut la remplacer dans la politique peut faire accepter n'importe quoi. D'où l'importance des droits sur les politiques Kyverno elles-mêmes (chapitre 43).

</details>

:::exercice[Exercice 2 : l'inventaire (programmation)]

Écrivez en Python `inventaire-images.py`, qui liste les images des Pods en cours d'exécution, et pour chaque image du registre du cours dit si elle est signée par la clé du cours, et résume sa dernière analyse signée (nombre de failles par sévérité, date). Les autres images seront marquées « hors registre du cours ». Appuyez-vous sur `cosign verify` et `cosign verify-attestation`, dont la sortie JSON contient la charge en base64.

:::

<details>
<summary>Corrigé</summary>

Le corrigé est `corrige/inventaire-images.py`. Le cœur décode la charge de chaque attestation et garde la plus récente :

```python title="corrige/inventaire-images.py (extrait)"
    att = cosign("verify-attestation", "--key", cle, "--type", "vuln", *OPTIONS, ref)
    if att.returncode != 0:
        return "signée", "pas d'analyse signée"
    # une ligne JSON par attestation ; on garde la plus récente
    analyses = []
    for ligne in att.stdout.splitlines():
        charge = json.loads(base64.b64decode(json.loads(ligne)["payload"]))["predicate"]
        analyses.append(charge)
    derniere = max(analyses, key=lambda a: a["metadata"]["scanFinishedOn"])
    severites = collections.Counter(v["Severity"] for r in derniere["scanner"]["result"].get("Results", [])
                                    for v in r.get("Vulnerabilities") or [])
```

```bash
python3 corrige/inventaire-images.py cosign.pub | grep -A1 '^host.minikube'
```

```sortie
host.minikube.internal:5001/colis/api:2.1
    signée                   1 MEDIUM (analyse du 2026-10-07)  [colis]
host.minikube.internal:5001/colis/api:2.1@sha256:ade99a611b6a907ceacc9deb10f1a7cc21a1f49f7f4395d5d5b5a145205ad3a5
    signée                   1 MEDIUM (analyse du 2026-10-07)  [colis]
host.minikube.internal:5001/colis/web:1.0
    signée                   2 HIGH, 3 MEDIUM (analyse du 2026-10-07)  [colis]
```

Une même image apparaît sous deux formes : avec son étiquette seule (les Pods créés avant la politique et pas encore redémarrés, comme l'API canari) et avec son empreinte (ceux d'après). Plusieurs attestations peuvent exister pour une même image, une par analyse ; c'est pourquoi le script garde la plus récente. Il ne vérifie pas que l'analyse est récente : c'est une amélioration naturelle.

</details>

:::exercice[Exercice 3 : corriger le site]

Les deux failles élevées de `web:1.0` ont toutes un correctif dans Alpine. Construisez `colis/web:1.1` en appliquant les mises à jour de l'image de base, signez-la et attestez-la, déployez-la dans Colis, puis imposez la politique d'analyse à Colis (`cours/analyse-exigee=oui`) et vérifiez que l'application tourne toujours.

:::

<details>
<summary>Corrigé</summary>

Une ligne suffit dans le Dockerfile du site de Colis (partie I), juste après le `FROM` (`corrige/web-1.1`) :

```dockerfile
FROM nginx:1.30-alpine

# appliquer les correctifs publiés depuis la construction de l'image de base (chapitre 47)
RUN apk upgrade --no-cache
```

```bash
docker build -t localhost:5001/colis/web:1.1 web-1.1 && docker push localhost:5001/colis/web:1.1
bash signer-et-attester.sh colis/web:1.1
kubectl -n colis set image deployment/web web=host.minikube.internal:5001/colis/web:1.1
kubectl label ns colis cours/analyse-exigee=oui
kubectl -n colis rollout restart deployment/web deployment/api
kubectl -n colis get pods -l 'app.kubernetes.io/name in (api,web)' -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.containers[0].image}{"\n"}{end}'
curl -s -o /dev/null -w "page d'accueil : %{http_code}\n" http://192.168.49.100/
curl -s http://192.168.49.100/api/sante; echo
```

```sortie
colis/web:1.1 (sha256:9ac4d5a43e71bc5410bfcd5cdcc8644a00711e5d416252f546ba4851f59bd5d4) : {}
Pushing signature to: localhost:5001/colis/web
Signing artifact...
deployment.apps/web image updated
namespace/colis labeled
deployment.apps/web restarted
deployment.apps/api restarted
api-9d84c4889-b6j9z  host.minikube.internal:5001/colis/api:2.1@sha256:ade99a611b6a907ceacc9deb10f1a7cc21a1f49f7f4395d5d5b5a145205ad3a5
api-9d84c4889-x57vd  host.minikube.internal:5001/colis/api:2.1@sha256:ade99a611b6a907ceacc9deb10f1a7cc21a1f49f7f4395d5d5b5a145205ad3a5
web-65cdb99b99-6ppdj  host.minikube.internal:5001/colis/web:1.1@sha256:9ac4d5a43e71bc5410bfcd5cdcc8644a00711e5d416252f546ba4851f59bd5d4
web-65cdb99b99-wctcb  host.minikube.internal:5001/colis/web:1.1@sha256:9ac4d5a43e71bc5410bfcd5cdcc8644a00711e5d416252f546ba4851f59bd5d4
page d'accueil : 200
{"statut":"ok","version":"2.1.0","hote":"api-9d84c4889-x57vd"}
```

(Un ancien Pod de l'API, en cours d'arrêt, a été retiré de la sortie.) L'analyse de `web:1.1` est vide : plus aucune faille connue. L'ordre compte : on déploie la version corrigée **avant** d'imposer la politique, sinon le site serait refusé au premier redémarrage. Notez que `apk upgrade` rend la construction moins reproductible, puisque son résultat dépend du jour. L'autre solution, plus propre, est d'attendre que nginx publie une image de base reconstruite, et de changer le `FROM`.

</details>

:::exercice[Exercice 4 : vérifier External Secrets]

L'image d'External Secrets installée au chapitre 46 est publiée par le projet `external-secrets/external-secrets` sur GitHub. Vérifiez-la sans clé, en exigeant que la signature vienne de ce dépôt et de GitHub Actions. Quel workflow l'a signée, sur quelle branche, et l'empreinte vérifiée est-elle celle qui tourne ?

:::

<details>
<summary>Corrigé</summary>

```bash
cosign verify ghcr.io/external-secrets/external-secrets:v2.12.0 \
  --certificate-identity-regexp '^https://github.com/external-secrets/external-secrets/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  | jq '.[0] | {empreinte: .critical.image["docker-manifest-digest"], Subject: .optional.Subject, Issuer: .optional.Issuer, githubWorkflowTrigger: .optional.githubWorkflowTrigger, githubWorkflowSha: .optional.githubWorkflowSha}'
kubectl -n external-secrets get pods -o jsonpath='{.items[0].status.containerStatuses[0].imageID}{"\n"}'
```

```sortie
code de sortie : 0
{
  "empreinte": "sha256:7a3c4f7e038fa0f86a3172da19b9388f3f4d846e87e9994ee3474c5b72a9330d",
  "Subject": "https://github.com/external-secrets/external-secrets/.github/workflows/release.yml@refs/heads/main",
  "Issuer": "https://token.actions.githubusercontent.com",
  "githubWorkflowTrigger": "workflow_dispatch",
  "githubWorkflowSha": "9d17906e8e4c5532ffe513f72273df03b7b07bc6"
}
ghcr.io/external-secrets/external-secrets@sha256:7a3c4f7e038fa0f86a3172da19b9388f3f4d846e87e9994ee3474c5b72a9330d
```

Le certificat désigne le workflow `release.yml` de la branche `main`, déclenché à la main (`workflow_dispatch`), au commit `9d17906e…`, et l'empreinte correspond à l'image en marche. Contrairement à Kyverno, ce projet range ses signatures à côté de l'image ; pas besoin de `COSIGN_REPOSITORY`. Pour un contrôle plus strict, on remplacerait l'expression régulière par l'identité exacte (`--certificate-identity`), workflow et branche compris : une signature faite par un autre workflow du même dépôt, par exemple celui des tests, serait alors refusée.

</details>

## Nettoyer

Colis reste sous les deux politiques (`cours/images-signees` et `cours/analyse-exigee`), avec `web:1.1` : c'est l'état voulu pour le défi VI. Gardez à l'esprit le revers de la médaille de l'encadré : le registre du cours doit tourner pour que les Pods de Colis puissent être créés. Pour retirer les essais :

```bash
kubectl delete namespace ch47 ch47-analyse
```

Pour retirer les politiques et revenir à `web:1.0` :

```bash
kubectl label ns colis cours/images-signees- cours/analyse-exigee-
kubectl delete imagevalidatingpolicy images-signees
kubectl delete clusterpolicy analyse-vulnerabilites-classique
kubectl -n colis set image deployment/web web=host.minikube.internal:5001/colis/web:1.0
```

Les signatures et attestations restent dans le registre, sous leurs étiquettes `.sig` et `.att`. Elles ne gênent rien.

[^ivpol]: Kyverno, « ImageValidatingPolicy » : `matchImageReferences`, `credentials.allowInsecureRegistry`, attestors cosign (clé, sans clé, `ctlog.insecureIgnoreTlog`), `validationConfigurations` (`mutateDigest`, `verifyDigest`, `required`), fonctions `verifyImageSignatures`, `verifyAttestationSignatures`, `extractPayload`. [kyverno.io/docs/policy-types/image-validating-policy](https://kyverno.io/docs/policy-types/image-validating-policy/)
[^bundle]: Kyverno, question #16664, « verifyImages: cosign 3.x bundle signatures invisible on registries without OCI referrers API », ouverte. [github.com/kyverno/kyverno/issues/16664](https://github.com/kyverno/kyverno/issues/16664)
[^tlog]: Kyverno, pull request #17217, « fix(ivpol): honor insecureIgnoreTlog/insecureIgnoreSCT in attestation verification », ouverte : « offline keyed attestation verification ... always failed with `cosign bundle verification failed` ». [github.com/kyverno/kyverno/pull/17217](https://github.com/kyverno/kyverno/pull/17217)
[^attestation]: Sigstore, « Cosign: In-Toto Attestations » et spécification des prédicats de cosign, dont `https://cosign.sigstore.dev/attestation/vuln/v1`. [docs.sigstore.dev/cosign/verifying/attestation](https://docs.sigstore.dev/cosign/verifying/attestation/)
[^trivy]: Trivy, « Cosign Vulnerability Attestation » : format `cosign-vuln` et attestation avec `cosign attest --type vuln`. [trivy.dev/docs/latest/supply-chain/attestation/vuln](https://trivy.dev/docs/latest/supply-chain/attestation/vuln/)
[^sigstore]: Sigstore, « Overview » et « Signing Overview » : signature sans clé, certificats de courte durée émis par Fulcio pour une identité OpenID Connect, journal de transparence Rekor. [docs.sigstore.dev/about/overview](https://docs.sigstore.dev/about/overview/), [docs.sigstore.dev/cosign/signing/overview](https://docs.sigstore.dev/cosign/signing/overview/)
[^images]: Kubernetes, « Images » : vérification des identifiants pour les images en cache (`imagePullCredentialsVerificationPolicy` : NeverVerify, NeverVerifyPreloadedImages par défaut, NeverVerifyAllowListedImages, AlwaysVerify), contrôleur d'admission `AlwaysPullImages`. [kubernetes.io/docs/concepts/containers/images](https://kubernetes.io/docs/concepts/containers/images/)
