---
title: La chaîne d'approvisionnement des images
sidebar_label: 14. Chaîne d'approvisionnement
description: "Savoir ce que contient une image et prouver d'où elle vient : un registre local durable, les attestations de BuildKit (SBOM et provenance), l'analyse de vulnérabilités, de configuration et de secrets avec Trivy, la signature et la vérification avec cosign."
partie: 2
chapitre: '14'
---

import chaineAppro from '@site/src/figures/chaine-appro.svg';
import signatureEmpreinte from '@site/src/figures/signature-empreinte.svg';

Le 29 mars 2024, un développeur de PostgreSQL remarque que ses connexions SSH consomment un peu trop de processeur. En tirant le fil, il découvre une porte dérobée dans `xz`, une bibliothèque de compression présente dans presque toutes les distributions Linux, glissée par un contributeur qui avait patiemment gagné, pendant deux ans, la confiance du projet[^xz]. Elle n'était pas dans le dépôt de code source lisible par tous, mais dans les archives publiées et dans des fichiers de test. Les versions piégées avaient déjà atteint les branches de développement de Debian et de Fedora.

L'attaque ne visait pas un programme, mais la **chaîne d'approvisionnement** : l'ensemble des étapes et des composants par lesquels passe un logiciel avant d'arriver en production. Une image de conteneur en est un bel exemple. Celle de Colis contient une Debian, un interpréteur Python, une trentaine de bibliothèques Python, le code de l'application ; elle a été construite par un outil, sur une machine, puis stockée dans un registre d'où n'importe quel nœud la télécharge. À chaque maillon, on peut se tromper ou être trompé. Ce chapitre répond à trois questions : qu'y a-t-il dans cette image ? Y a-t-il des failles connues ? Est-ce bien l'image que nous avons construite ?

Les outils de ce chapitre sont Trivy 0.74.0 et cosign 3.1.3. Ce sont des binaires uniques, à installer depuis leurs pages de publication sur GitHub (`aquasecurity/trivy` et `sigstore/cosign`), en vérifiant l'empreinte fournie avec chaque version, comme pour kubectl au chapitre 0.2.

## Un registre local durable

Au chapitre 3, un registre lancé en une commande avait servi à comprendre l'API de distribution. Celui-ci va durer : la partie III y poussera les images de Colis pour que minikube les télécharge (chapitre 24). On lui donne un volume, pour que les images survivent à la suppression du conteneur, et on l'autorise à supprimer des images, ce qu'il refuse par défaut :

```bash
docker run -d --name registre -p 5001:5000 -v registre:/var/lib/registry \
  -e REGISTRY_STORAGE_DELETE_ENABLED=true registry:3
curl -s localhost:5001/v2/_catalog
```

```sortie
{"repositories":[]}
```

Le registre parle HTTP, sans chiffrement. Docker l'accepte parce qu'il se trouve sur `localhost`, que Docker considère par exception comme sûr[^insecure-registry] ; toute autre adresse exigerait HTTPS ou une déclaration explicite dans la configuration du démon. En production, un registre se met derrière TLS et une authentification. Pour apprendre sur un poste, `localhost` suffit.

Pour y pousser l'image multi-architecture du chapitre 13, le constructeur `cours` doit pouvoir joindre `localhost:5001`. Or il tourne dans un conteneur, dont le `localhost` est le sien, pas celui du poste (chapitre 6). On le recrée donc dans le réseau de la machine :

```bash
docker buildx rm cours
docker buildx create --name cours --driver docker-container --driver-opt network=host --bootstrap
```

## Ce que BuildKit sait dire d'une image

Poussons `tampon` en demandant à BuildKit deux documents supplémentaires, un **SBOM** et une **provenance** complète :

```bash
cd tampon
docker buildx build --builder cours --platform linux/amd64,linux/arm64 \
  --build-arg VERSION=1.0.0 --sbom=true --provenance=mode=max \
  -t localhost:5001/cours/tampon:1.0.0 --push .
docker buildx imagetools inspect localhost:5001/cours/tampon:1.0.0
```

```sortie
Name:      localhost:5001/cours/tampon:1.0.0
MediaType: application/vnd.oci.image.index.v1+json
Digest:    sha256:56569db2e11971d67bdd5be97ff658150f1a6c424c495350f7bb396fd874cc5b

Manifests:
  Name:        localhost:5001/cours/tampon:1.0.0@sha256:dab6b65d8ba51cc4f9785fc88a2841577447967b9ba679aaba5f864820027f2c
  MediaType:   application/vnd.oci.image.manifest.v1+json
  Platform:    linux/amd64

  Name:        localhost:5001/cours/tampon:1.0.0@sha256:d4b6a809bcce1b7d2a844e65faa4ee73bb7ab500e80330d11af9c61e6752a3d0
  MediaType:   application/vnd.oci.image.manifest.v1+json
  Platform:    linux/arm64

  Name:        localhost:5001/cours/tampon:1.0.0@sha256:4ca94b0b65cc67fe8230357f0053acbd746ff8f70117eeb848b98f72d2d3148e
  MediaType:   application/vnd.oci.image.manifest.v1+json
  Platform:    unknown/unknown
  Annotations:
    vnd.docker.reference.digest: sha256:dab6b65d8ba51cc4f9785fc88a2841577447967b9ba679aaba5f864820027f2c
    vnd.docker.reference.type:   attestation-manifest

  Name:        localhost:5001/cours/tampon:1.0.0@sha256:2fdf186b9883f582dd80ea737e2618d9ffcf810e12a1ff2a4e29ea0362c5cc19
  MediaType:   application/vnd.oci.image.manifest.v1+json
  Platform:    unknown/unknown
  Annotations:
    vnd.docker.reference.type:   attestation-manifest
    vnd.docker.reference.digest: sha256:d4b6a809bcce1b7d2a844e65faa4ee73bb7ab500e80330d11af9c61e6752a3d0
```

On retrouve l'index du chapitre 13 : une image par architecture, et un **manifeste d'attestations** pour chacune, rattaché à son image par l'annotation `vnd.docker.reference.digest`. Ces attestations voyagent avec l'image : qui la télécharge peut les lire[^buildkit-attestations].

### Le SBOM : la liste des ingrédients

Un **SBOM** (*Software Bill of Materials*, nomenclature logicielle) est la liste des composants d'un logiciel, avec leur version, comme la liste d'ingrédients d'un produit alimentaire. Deux formats dominent : **SPDX**, porté par la Linux Foundation et devenu la norme ISO/IEC 5962:2021, et **CycloneDX**, porté par l'OWASP[^spdx][^cyclonedx]. Ils ont pris de l'importance réglementaire : aux États-Unis, le décret présidentiel 14028 de mai 2021 impose aux fournisseurs de l'administration fédérale de lui remettre un SBOM de leurs logiciels[^eo14028], et dans l'Union européenne, le règlement sur la cyberrésilience (2024/2847) exige des fabricants de produits comportant des éléments numériques qu'ils établissent un SBOM de leurs composants[^cra].

BuildKit a produit le sien en analysant l'image avec l'outil Syft. Lisons celui de la variante amd64 :

```bash
docker buildx imagetools inspect localhost:5001/cours/tampon:1.0.0 --format '{{json .SBOM}}' > sbom.json
jq -r '."linux/amd64".SPDX | .spdxVersion, (.packages | length), (.packages[] | "\(.name) \(.versionInfo)")' sbom.json
```

```sortie
SPDX-2.3
9
base-files 13.8+deb13u7
ca-certificates 20250419
media-types 13.0.0
netbase 6.5
stdlib go1.27.1
tampon UNKNOWN
tzdata 2026c-0+deb13u1
tzdata-legacy 2026c-0+deb13u1
sbom null
```

Huit composants réels (la dernière ligne désigne le document lui-même) : six paquets Debian venus de distroless, le binaire `tampon`, et `stdlib go1.27.1`, la bibliothèque standard de Go compilée dans le binaire. Comment Syft connaît-il la version de Go ? Un binaire Go contient une section *buildinfo*, que `go version -m tampon` affiche : version du compilateur, module, dépendances et options de construction. C'est ce qui permettra, plus bas, de savoir si le binaire est touché par une faille de la bibliothèque standard.

### La provenance : comment l'image a été fabriquée

La **provenance** décrit la construction elle-même, au format défini par SLSA (*Supply-chain Levels for Software Artifacts*), un cadre de la fondation OpenSSF qui gradue les garanties qu'on peut donner sur la fabrication d'un logiciel[^slsa] :

```bash
docker buildx imagetools inspect localhost:5001/cours/tampon:1.0.0 --format '{{json .Provenance}}' > prov.json
jq '."linux/amd64".SLSA | {args: .buildDefinition.externalParameters.request.args, dependances: [.buildDefinition.resolvedDependencies[] | {uri, sha256: .digest.sha256[0:16]}], debut: .runDetails.metadata.startedOn}' prov.json
```

```sortie
{
  "args": {
    "build-arg:VERSION": "1.0.0",
    "cmdline": "docker/dockerfile:1",
    "source": "docker/dockerfile:1"
  },
  "dependances": [
    {
      "uri": "pkg:docker/docker/buildkit-syft-scanner@stable-1?platform=linux%2Famd64",
      "sha256": "ae4f3b554449e7e2"
    },
    {
      "uri": "pkg:docker/docker/dockerfile@1",
      "sha256": "ecfaec9ed6d810b5"
    },
    {
      "uri": "pkg:docker/golang@1.27?platform=linux%2Famd64",
      "sha256": "3680233e3204827f"
    },
    {
      "uri": "pkg:docker/gcr.io/distroless/static-debian13@nonroot?platform=linux%2Famd64",
      "sha256": "e2e927ec666bae08"
    }
  ],
  "debut": "2026-09-25T15:55:11.455586354Z"
}
```

Les arguments de construction, et surtout chaque image utilisée, **avec son empreinte** : `golang:1.27` était, ce jour-là, `3680233e…`, et `distroless/static-debian13:nonroot` était `e2e927ec…`, l'empreinte relevée au chapitre 13. Le jour où une faille sera découverte dans une image de base, on saura exactement quelles images en dérivent. En mode `max`, la provenance contient aussi le Dockerfile complet et la liste des étapes. C'est elle qui rendait les constructions non reproductibles au chapitre 13 : elle porte la date de la construction.

## Chercher les failles connues avec Trivy

Une faille publiée reçoit un identifiant **CVE** (*Common Vulnerabilities and Exposures*), comme CVE-2024-3094 pour `xz`, et une sévérité. Les distributions et les écosystèmes de paquets publient ensuite, pour chaque CVE, les versions touchées et celles qui la corrigent. Un **scanner** d'images fait le rapprochement : il dresse l'inventaire de l'image (le même travail que le SBOM), puis confronte chaque composant à ces bases.

Trivy, développé par Aqua Security, est le scanner libre le plus répandu[^trivy]. Il lit dans les couches de l'image les bases de paquets des distributions (`/var/lib/dpkg/status` pour Debian, `/lib/apk/db/installed` pour Alpine), les métadonnées des paquets Python, npm ou Java, et la *buildinfo* des binaires Go. Au premier lancement, il télécharge sa base de vulnérabilités, mise à jour plusieurs fois par jour. Commençons par `tampon` :

```bash
trivy image --quiet localhost:5001/cours/tampon:1.0.0
```

```sortie
Report Summary

┌─────────────────────────────────────────────────┬──────────┬─────────────────┬─────────┐
│                     Target                      │   Type   │ Vulnerabilities │ Secrets │
├─────────────────────────────────────────────────┼──────────┼─────────────────┼─────────┤
│ localhost:5001/cours/tampon:1.0.0 (debian 13.7) │  debian  │        0        │    -    │
├─────────────────────────────────────────────────┼──────────┼─────────────────┼─────────┤
│ tampon                                          │ gobinary │        0        │    -    │
└─────────────────────────────────────────────────┴──────────┴─────────────────┴─────────┘
```

Zéro, pour les paquets Debian comme pour le binaire Go. Passons à des images plus chargées. Pour les comparer, on demande un résultat en JSON et on compte les failles par sévérité avec `jq` :

```bash
for i in colis:1.0 python:3.14-slim python:3.14 tampon:naif nginx:1.30-alpine; do
  trivy image --quiet --format json -o x.json $i
  echo "$i : $(jq -r '[.Results[]?.Vulnerabilities[]?.Severity] | group_by(.) | map("\(.[0])=\(length)") | join(" ")' x.json)"
done
```

```sortie
colis:1.0 : HIGH=46 LOW=57 MEDIUM=54 UNKNOWN=2
python:3.14-slim : HIGH=46 LOW=57 MEDIUM=54 UNKNOWN=2
python:3.14 : CRITICAL=19 HIGH=324 LOW=1312 MEDIUM=1780 UNKNOWN=270
tampon:naif : CRITICAL=2 HIGH=173 LOW=894 MEDIUM=1536 UNKNOWN=218
nginx:1.30-alpine : HIGH=1
```

Trois leçons se lisent dans ce tableau. Les failles de Colis sont exactement celles de son image de base, `python:3.14-slim` : aucune des bibliothèques Python ajoutées par l'application n'en apporte. Les images complètes (`python:3.14`, et `golang:1.27` sous `tampon:naif`) en comptent des milliers, parce qu'elles contiennent des centaines de paquets : chaque paquet est une surface d'attaque, et c'est l'argument le plus concret en faveur du chapitre 13. Enfin, Alpine, avec moins de paquets, en a très peu.

### Toutes les failles ne se valent pas

Faut-il s'alarmer des 46 failles HIGH de Colis ? Trivy indique, pour chacune, un **statut**, qui dit si une correction existe :

```bash
trivy image --quiet --format json -o colis.json colis:1.0
jq -r '.Results[] | "\(.Target) [\(.Type)] : \([.Vulnerabilities[]?.Severity] | group_by(.) | map("\(.[0])=\(length)") | join(" "))"' colis.json
jq -r '[.Results[].Vulnerabilities[]? | .Status] | group_by(.) | map("\(.[0])=\(length)") | join(" ")' colis.json
```

```sortie
colis:1.0 (debian 13.7) [debian] : HIGH=44 LOW=57 MEDIUM=53 UNKNOWN=2
Python [python-pkg] : HIGH=2 MEDIUM=1
affected=154 fix_deferred=2 fixed=3
```

`fixed` signifie qu'une version corrigée existe ; `affected`, que le paquet est touché et qu'aucune correction n'est encore publiée par la distribution ; `fix_deferred`, que la distribution a décidé de reporter la correction, en général parce qu'elle juge le risque faible dans son contexte[^trivy-status]. Sur 159 failles, 3 seulement ont une correction disponible. Pour les 156 autres, il n'y a rien à mettre à jour : la faille est dans un paquet Debian, et Debian n'a pas encore publié de correctif. Beaucoup ne se manifestent que dans des conditions très particulières : les paquets les plus touchés sont la glibc (`libc6`, `libc-bin`) et les outils de `util-linux`, dont une bonne partie ne sert jamais dans un conteneur.

C'est pourquoi on filtre presque toujours sur ce qui est corrigeable et grave :

```bash
trivy image --quiet --ignore-unfixed --severity HIGH,CRITICAL colis:1.0
```

La sortie, raccourcie ici aux lignes qui comptent, ne laisse que deux failles :

```sortie
Python (python-pkg)
===================
Total: 2 (HIGH: 2, CRITICAL: 0)

│  Library   │    Vulnerability    │ Severity │ Status │ Installed Version │ Fixed Version │
│ msgpack    │ GHSA-6v7p-g79w-8964 │ HIGH     │ fixed  │ 1.1.2             │ 1.2.1         │
│ setuptools │ CVE-2025-47273      │ HIGH     │ fixed  │ 70.3.0            │ 78.1.1        │
```

Colis n'utilise ni `msgpack` ni `setuptools`. D'où viennent-ils ? Ils ne figurent pas dans `site-packages`, mais dans `pip` lui-même, qui embarque ses propres copies de quelques bibliothèques et publie depuis peu leur liste dans un SBOM :

```bash
docker run --rm colis:1.0 sh -c 'grep -iE "^(msgpack|setuptools)" /usr/local/lib/python3.14/site-packages/pip/_vendor/vendor.txt; ls /usr/local/lib/python3.14/site-packages/pip/_vendor/bom.cdx.json'
```

```sortie
msgpack==1.1.2
setuptools==70.3.0
/usr/local/lib/python3.14/site-packages/pip/_vendor/bom.cdx.json
```

Trivy a lu ce SBOM. Ces deux failles sont donc réelles, mais dans un outil qui sert à **installer** les dépendances et qui n'a aucune raison d'être présent à l'exécution. Une image finale sans `pip` les ferait disparaître : c'est l'un des leviers du défi II.

### Trivy dans une chaîne d'intégration

Dans une chaîne d'intégration continue, on veut qu'une image vulnérable bloque la livraison. `--exit-code 1` fait rendre à Trivy un code non nul s'il trouve quelque chose, selon les filtres donnés :

```bash
trivy image --quiet --ignore-unfixed --severity CRITICAL --exit-code 1 colis:1.0 >/dev/null; echo "CRITICAL corrigeables : code $?"
trivy image --quiet --ignore-unfixed --severity HIGH,CRITICAL --exit-code 1 colis:1.0 >/dev/null; echo "HIGH ou CRITICAL corrigeables : code $?"
```

```sortie
CRITICAL corrigeables : code 0
HIGH ou CRITICAL corrigeables : code 1
```

Le choix du seuil est une décision d'équipe. Une règle courante : bloquer sur les failles CRITICAL et HIGH corrigeables, et suivre les autres dans un tableau de bord. Une règle trop stricte bloque des livraisons pour des failles qu'on ne peut pas corriger, et finit par être contournée.

## Le SBOM comme point de départ

Trivy sait aussi produire un SBOM, puis analyser un SBOM au lieu d'une image :

```bash
trivy image --quiet --format cyclonedx -o colis.cdx.json colis:1.0
jq -r '.bomFormat, .specVersion, (.components | length)' colis.cdx.json
jq -r '[.components[] | .purl // "" | split("/")[0]] | group_by(.) | map("\(.[0])=\(length)") | join(" ")' colis.cdx.json
trivy sbom --quiet --format json -o s.json colis.cdx.json
jq '[.Results[]?.Vulnerabilities[]?] | length' s.json
```

```sortie
CycloneDX
1.7
123
null=1 pkg:deb=87 pkg:pypi=35
159
```

123 composants, dont 87 paquets Debian et 35 paquets Python, identifiés par leur **purl** (*package URL*, une façon normalisée de désigner un paquet, comme `pkg:pypi/fastapi@0.141.1`). Analyser ce fichier a pris 134 millisecondes sur le poste du cours, sans télécharger ni ouvrir l'image, et retrouve les mêmes 159 failles. C'est l'intérêt pratique du SBOM : on le produit une fois, à la construction, et on peut l'interroger ensuite aussi souvent qu'on veut. Le jour où une nouvelle faille est annoncée dans une bibliothèque, une recherche dans les SBOM de toutes les images de l'entreprise dit en quelques secondes lesquelles sont concernées (exercice 3).

<Figure svg={chaineAppro} num="14.1" alt="Une chaîne de six étapes : les sources (main.go, Dockerfile), la construction par BuildKit, le registre localhost:5001, l'analyse par Trivy, la signature par cosign, puis le déploiement qui vérifie la signature. La construction produit l'image amd64 et arm64, un SBOM au format SPDX et une provenance SLSA ; la signature produit une signature et un SBOM attesté. Tout est rangé dans le registre à côté de l'image et désigné par son empreinte.">
La chaîne d'approvisionnement de <code>tampon</code> avec les outils de ce chapitre. La vérification au déploiement, par Kubernetes, sera l'objet du chapitre 47.
</Figure>

## Analyser aussi la configuration et les secrets

Trivy ne cherche pas que des CVE. `trivy config` applique des règles de bonnes pratiques à des fichiers de configuration : Dockerfile, manifestes Kubernetes, Terraform. Essayons les deux Dockerfile extrêmes du chapitre 13 :

```bash
trivy config --quiet Dockerfile.naif
trivy config --quiet Dockerfile
```

Les deux donnent le même résultat :

```sortie
Tests: 27 (SUCCESSES: 25, FAILURES: 2)
Failures: 2 (UNKNOWN: 0, LOW: 1, MEDIUM: 0, HIGH: 1, CRITICAL: 0)
DS-0002 (HIGH): Specify at least 1 USER command in Dockerfile with non-root user as argument
DS-0026 (LOW): Add HEALTHCHECK instruction in your Dockerfile
```

Pour le Dockerfile naïf, la règle DS-0002 a raison : l'image tourne en root. Pour le Dockerfile de production, elle se trompe : l'image `distroless/static-debian13:nonroot` fixe déjà l'utilisateur 65532, mais Trivy lit le fichier sans ouvrir l'image de base, et ne peut pas le savoir. C'est la limite de toute analyse statique. On peut la contenter, et rendre l'intention visible pour le lecteur, en ajoutant `USER 65532:65532` avant `ENTRYPOINT` : Trivy ne signale plus alors que DS-0026. La règle DS-0026, sur `HEALTHCHECK`, se discute : dans Kubernetes, ce sont les sondes du Pod qui vérifient la santé d'un conteneur (chapitre 22), et `HEALTHCHECK` est ignoré.

Le troisième type d'analyse est la recherche de **secrets** : des clés d'API, des jetons, des mots de passe restés dans l'image. Reprenons le piège du chapitre 10, un fichier ajouté dans une couche puis supprimé dans la suivante, avec un faux jeton GitHub fabriqué pour l'occasion :

```bash
mkdir fuite && cd fuite
printf 'GITHUB_TOKEN=ghp_%s\n' "$(head -c 400 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 36)" > deploiement.env
printf 'FROM alpine:3.24\nCOPY deploiement.env /tmp/deploiement.env\nRUN rm /tmp/deploiement.env\n' > Dockerfile
docker build -q -t fuite:1.0 .
docker run --rm fuite:1.0 ls -A /tmp
trivy image --quiet --scanners secret fuite:1.0
```

```sortie
/tmp/deploiement.env (secrets)
==============================
Total: 1 (UNKNOWN: 0, LOW: 0, MEDIUM: 0, HIGH: 0, CRITICAL: 1)

CRITICAL: GitHub (github-pat)
════════════════════════════════════════
GitHub Personal Access Token
────────────────────────────────────────
 /tmp/deploiement.env:1 (offset: 13 bytes) (added by 'COPY deploiement.env /tmp/deploiement.en')
────────────────────────────────────────
   1 [ GITHUB_TOKEN=****************************************
────────────────────────────────────────
```

`ls -A /tmp` n'affiche rien : le fichier n'existe plus dans le conteneur. Trivy l'a pourtant trouvé, parce qu'il analyse chaque couche, et il indique même l'instruction qui l'a ajouté. Un vrai jeton trouvé ainsi doit être considéré comme compromis et révoqué : l'image a pu être copiée n'importe où. Supprimez l'image et le dossier : `docker rmi fuite:1.0`, `cd .. && rm -r fuite`.

## Signer les images avec cosign

Revenons à la troisième question : l'image que va lancer le nœud est-elle bien celle que nous avons construite ? Un registre compromis, un identifiant de publication volé, une erreur de manipulation : une étiquette peut désigner n'importe quelle image. La réponse est la **signature** : avec une clé privée que lui seul détient, l'auteur signe l'empreinte de l'image ; avec la clé publique correspondante, n'importe qui peut vérifier que cette empreinte a bien été signée par lui.

**cosign** est l'outil de signature du projet Sigstore, de la fondation OpenSSF[^sigstore]. Sigstore propose aussi une signature *sans clé* (*keyless*) : on s'authentifie auprès d'un fournisseur d'identité (GitHub, Google), un service public délivre un certificat de courte durée, et la signature est inscrite dans **Rekor**, un journal de transparence public, pour que tout le monde puisse l'auditer. C'est le mode qu'utilisent les grands projets, et la partie VI y reviendra. Pour ce cours, qui doit fonctionner hors ligne et ne rien publier, nous utilisons une paire de clés locale et aucun service public.

### Une paire de clés, une signature

```bash
mkdir cle && cd cle
export COSIGN_PASSWORD=mot-de-passe-du-cours
cosign generate-key-pair
cosign signing-config create --out sans-journal.json
cat sans-journal.json
```

```sortie
Private key written to cosign.key
Public key written to cosign.pub
{"mediaType":"application/vnd.dev.sigstore.signingconfig.v0.2+json","rekorTlogConfig":{},"tsaConfig":{}}
```

`cosign.key` est la clé privée, chiffrée par le mot de passe (en situation réelle, on ne le met pas dans une variable d'environnement, et la clé vit dans un coffre-fort à secrets). `cosign.pub` est la clé publique, qu'on distribue. Le second fichier est une **configuration de signature** vide : depuis la version 3, cosign lit dans une telle configuration les services à utiliser (autorité de certification, journal de transparence, horodatage), et par défaut ce sont les services publics de Sigstore. Une configuration vide lui dit de n'en contacter aucun.

On signe toujours une **empreinte**, jamais une étiquette : une étiquette peut changer de cible entre le moment où on la lit et celui où on signe.

```bash
D=$(docker buildx imagetools inspect localhost:5001/cours/tampon:1.0.0 --format '{{json .Manifest}}' | jq -r .digest)
echo "empreinte : $D"
cosign sign --yes --key cosign.key --signing-config sans-journal.json --allow-http-registry localhost:5001/cours/tampon@$D
```

```sortie
empreinte : sha256:56569db2e11971d67bdd5be97ff658150f1a6c424c495350f7bb396fd874cc5b
Signing artifact...
Pushing signature to: localhost:5001/cours/tampon
```

`--allow-http-registry` autorise cosign à parler HTTP à notre registre. La signature est poussée **dans le registre**, à côté de l'image. Vérifions-la :

```bash
cosign verify --key cosign.pub --insecure-ignore-tlog=true --allow-http-registry localhost:5001/cours/tampon:1.0.0
```

```sortie
WARNING: Skipping tlog verification is an insecure practice that lacks transparency and auditability verification for the signature.

Verification for localhost:5001/cours/tampon:1.0.0 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The signatures were verified against the specified public key

[{"critical":{"identity":{"docker-reference":"localhost:5001/cours/tampon:1.0.0"},"image":{"docker-manifest-digest":"sha256:56569db2e11971d67bdd5be97ff658150f1a6c424c495350f7bb396fd874cc5b"},"type":"https://sigstore.dev/cosign/sign/v1"},"optional":{}}]
```

La signature est valide pour la clé publique, et porte sur l'empreinte `56569db2…`. L'avertissement rappelle ce que nous avons choisi d'abandonner : sans journal de transparence, personne d'autre ne peut savoir que cette signature existe, ni repérer une signature faite avec une clé volée. La deuxième ligne de la liste est trompeuse : avec `--insecure-ignore-tlog=true`, aucune vérification du journal n'a réellement eu lieu.

### Où vit la signature

```bash
cosign tree --allow-http-registry localhost:5001/cours/tampon:1.0.0
curl -s localhost:5001/v2/cours/tampon/tags/list
```

```sortie
📦 Supply Chain Security Related artifacts for an image: localhost:5001/cours/tampon:1.0.0
└── 🔗 https://sigstore.dev/cosign/sign/v1 artifacts via OCI referrer: localhost:5001/cours/tampon@sha256:6e69f4370a8c39620b4b5ef0450edfb4bf2f729b1131d9d929dcca1efdec8fb7
   └── 🍒 sha256:481ce15c739852ad304482025b7b17b5dc70369301c7a4cb5db455907d3c0ac5
{"name":"cours/tampon","tags":["1.0.0","sha256-56569db2e11971d67bdd5be97ff658150f1a6c424c495350f7bb396fd874cc5b"]}
```

La signature est un artefact OCI à part entière, un manifeste qui « se réfère » à l'image par son champ `subject` : c'est le mécanisme des **referrers**, ajouté dans la version 1.1 des spécifications de l'OCI pour attacher des documents à une image sans la modifier[^oci-referrers]. Un registre récent répond à la question « qu'est-ce qui se réfère à cette empreinte ? » par une API dédiée. Le nôtre ne la connaît pas ; cosign utilise alors le **schéma de repli** prévu par la spécification : une étiquette nommée d'après l'empreinte, `sha256-56569db2…`, qui désigne un index de tous les artefacts rattachés. C'est l'étiquette étrange qui est apparue dans la liste.

### Une étiquette détournée

Simulons maintenant une attaque : quelqu'un pousse une autre image sous la même étiquette `1.0.0`.

```bash
docker buildx build --builder cours --platform linux/amd64,linux/arm64 \
  --build-arg VERSION=1.0.0-pirate -t localhost:5001/cours/tampon:1.0.0 --push .
cosign verify --key cosign.pub --insecure-ignore-tlog=true --allow-http-registry localhost:5001/cours/tampon:1.0.0; echo code=$?
```

```sortie
Error: no signatures found
error during command execution: no signatures found
code=10
```

L'étiquette désigne désormais l'index `59b35b7c…`, que personne n'a signé. La vérification échoue. L'image d'origine, elle, existe toujours dans le registre, sans étiquette, et sa signature aussi :

```bash
cosign verify --key cosign.pub --insecure-ignore-tlog=true --allow-http-registry \
  localhost:5001/cours/tampon@sha256:56569db2e11971d67bdd5be97ff658150f1a6c424c495350f7bb396fd874cc5b >/dev/null 2>&1; echo code=$?
```

```sortie
code=0
```

Et une signature valide ne suffit pas : il faut qu'elle soit faite par la bonne clé. Vérifiée avec la clé publique d'une autre paire, la même image est refusée (code 1, `accepted signatures do not match threshold, Found: 0, Expected 1`).

<Figure svg={signatureEmpreinte} num="14.2" alt="L'étiquette cours/tampon:1.0.0 désignait avant l'index 56569db2, version 1.0.0 ; après le push pirate, elle désigne l'index 59b35b7c, version 1.0.0-pirate. La signature, rangée sous l'étiquette sha256-56569db2, signe l'index d'origine. cosign verify sur l'étiquette répond no signatures found, code 10 ; sur l'empreinte d'origine, code 0.">
Une signature porte sur une empreinte, pas sur une étiquette. Déplacer l'étiquette ne transfère pas la signature.
</Figure>

Tout le mécanisme repose sur un principe : **on déploie des empreintes, pas des étiquettes**, et l'on vérifie la signature de l'empreinte avant de la lancer. Dans Kubernetes, un contrôleur d'admission comme Kyverno fera cette vérification automatiquement, pour chaque Pod, au chapitre 47.

### Remettre de l'ordre dans le registre

Supprimons l'image pirate. L'API du registre supprime un manifeste par son empreinte ; on replace ensuite l'étiquette sur l'image d'origine avec `imagetools create`, qui crée une étiquette sans rien reconstruire :

```bash
docker exec registre du -sh /var/lib/registry
curl -s -o /dev/null -w 'DELETE : %{http_code}\n' -X DELETE \
  localhost:5001/v2/cours/tampon/manifests/sha256:59b35b7cacc2a295cf4da8ae21c4d33edd8a025dbeb1b09bc820a74dd13285a1
docker buildx imagetools create -t localhost:5001/cours/tampon:1.0.0 \
  localhost:5001/cours/tampon@sha256:56569db2e11971d67bdd5be97ff658150f1a6c424c495350f7bb396fd874cc5b
```

```sortie
14.3M	/var/lib/registry
DELETE : 202
```

Supprimer un manifeste ne libère pas l'espace de ses couches : d'autres images pourraient les partager (chapitre 3). C'est le **ramasse-miettes** (*garbage collection*) du registre qui parcourt tous les manifestes restants, marque les blobs encore utilisés et supprime les autres[^registry-gc]. L'option `--delete-untagged` supprime aussi les manifestes qui ne sont plus désignés par aucune étiquette, comme les deux images de l'index pirate. Essayez d'abord avec `--dry-run`, qui liste sans rien supprimer :

```bash
docker exec registre registry garbage-collect --delete-untagged /etc/distribution/config.yml | grep marked
docker exec registre du -sh /var/lib/registry
cosign verify --key cosign.pub --insecure-ignore-tlog=true --allow-http-registry localhost:5001/cours/tampon:1.0.0 >/dev/null 2>&1; echo code=$?
```

```sortie
32 blobs marked, 10 blobs and 4 manifests eligible for deletion
8.6M	/var/lib/registry
code=0
```

Quatre manifestes (deux images, deux attestations) et dix blobs de l'image pirate ont disparu, et l'image signée est intacte. La documentation recommande de ne lancer le ramasse-miettes que registre arrêté ou en lecture seule : une image poussée pendant l'opération pourrait perdre des couches que le ramasse-miettes croyait inutilisées. Sur un poste, où personne ne pousse en même temps, le risque est nul.

## Exercices

:::exercice[Exercice 1 : corriger la faille de nginx]

`nginx:1.30-alpine` présentait une faille HIGH. Identifiez le paquet et la version corrigée avec Trivy, puis construisez une image `nginx-corrige:1.30` qui en est débarrassée, sans attendre une nouvelle image officielle. Vérifiez avec Trivy. Quel est l'inconvénient de cette méthode ?

:::

<details>
<summary>Corrigé</summary>

```bash
trivy image --quiet --format json -o n.json nginx:1.30-alpine
jq -r '.Results[]?.Vulnerabilities[]? | "\(.VulnerabilityID) \(.PkgName) \(.InstalledVersion) -> \(.FixedVersion) \(.Status) \(.Severity)"' n.json
```

```sortie
CVE-2026-93990 libexpat 2.8.4-r0 -> 2.8.5-r0 fixed HIGH
```

Alpine a déjà publié `libexpat` 2.8.5-r0. Deux lignes suffisent :

```dockerfile
FROM nginx:1.30-alpine
RUN apk upgrade --no-cache libexpat
```

Après `docker build -t nginx-corrige:1.30 .`, `docker run --rm nginx-corrige:1.30 apk list -I libexpat` affiche `libexpat-2.8.5-r0`, et Trivy ne trouve plus aucune faille. L'inconvénient : la nouvelle version de `libexpat` est dans une couche supplémentaire, par-dessus l'ancienne, qui reste dans l'image (chapitre 10) ; surtout, vous avez maintenant une image à vous, qu'il faudra reconstruire à chaque nouvelle image nginx, et vous avez pris la responsabilité de tester cette combinaison. C'est une bonne mesure d'urgence ; la solution durable est de reconstruire régulièrement ses images sur des bases à jour, ce qu'on automatise dans la chaîne d'intégration.

</details>

:::exercice[Exercice 2 : accepter un risque, par écrit]

L'équipe de Colis décide que la faille `GHSA-6v7p-g79w-8964` de `msgpack`, embarqué dans `pip`, n'est pas exploitable dans son contexte. Faites en sorte que Trivy ne la signale plus, en gardant une trace de la décision. Comment éviter qu'une telle exception soit oubliée pour toujours ?

:::

<details>
<summary>Corrigé</summary>

Trivy lit un fichier `.trivyignore` dans le dossier courant : un identifiant par ligne, et des commentaires précédés de `#`.

```text title=".trivyignore"
# msgpack embarqué dans pip, jamais importé par Colis ; à revoir le 2026-12-31
GHSA-6v7p-g79w-8964
```

`trivy image --quiet --ignore-unfixed --severity HIGH,CRITICAL colis:1.0` ne signale plus que `CVE-2025-47273` (setuptools). Pour éviter l'oubli, le format YAML permet de donner une justification et une date d'expiration, au-delà de laquelle l'exception cesse de s'appliquer :

```yaml title="trivyignore.yaml"
vulnerabilities:
  - id: GHSA-6v7p-g79w-8964
    statement: msgpack embarqué dans pip, jamais importé par Colis
    expired_at: 2026-09-01
```

Avec `--ignorefile trivyignore.yaml`, et cette date déjà passée au moment où ce chapitre a été écrit, la faille réapparaît : l'exception a expiré, la décision doit être reprise. Le fichier se range dans le dépôt, à côté du Dockerfile, et chaque ajout passe en revue de code comme n'importe quelle modification. Une exception sans justification ni date est une dette qui ne sera jamais remboursée.

</details>

:::exercice[Exercice 3 : une faille annoncée dans OpenSSL]

Une faille grave vient d'être annoncée dans OpenSSL. Sans lancer d'analyse de vulnérabilités, déterminez lesquelles de vos images `colis:1.0`, `nginx:1.30-alpine` et `localhost:5001/cours/tampon:1.0.0` contiennent OpenSSL, et en quelle version. Pourquoi `tampon` est-il dans une situation particulière ?

:::

<details>
<summary>Corrigé</summary>

On produit un SBOM par image (une fois pour toutes, en pratique à la construction), puis on l'interroge :

```bash
for i in colis:1.0 nginx:1.30-alpine localhost:5001/cours/tampon:1.0.0; do
  n=$(echo $i | tr ':/' '__')
  trivy image --quiet --format cyclonedx -o $n.cdx.json $i
  echo "$i : $(jq -r '[.components[] | select(.name|test("^(libssl|openssl)")) | "\(.name) \(.version)"] | join(", ")' $n.cdx.json)"
done
```

```sortie
colis:1.0 : libssl3t64 3.5.7-1~deb13u2, openssl-provider-legacy 3.5.7-1~deb13u2, openssl 3.5.7-1~deb13u2
nginx:1.30-alpine : libssl3 3.5.8-r0
localhost:5001/cours/tampon:1.0.0 :
```

Colis embarque OpenSSL 3.5.7 de Debian, nginx OpenSSL 3.5.8 d'Alpine ; il faudra comparer ces versions à celles de l'avis de sécurité, en tenant compte des correctifs que chaque distribution applique sans changer le numéro de version principal. `tampon` n'a pas OpenSSL du tout : Go implémente TLS dans sa propre bibliothèque standard, `crypto/tls`. Il n'est pas concerné par cette faille, mais il le sera par une faille de la bibliothèque standard de Go, que son SBOM mentionne (`stdlib go1.27.1`) ; le remède serait alors de le recompiler avec une version corrigée de Go, pas de mettre à jour un paquet.

</details>

:::exercice[Exercice 4 : attester le SBOM]

Le SBOM produit par BuildKit est attaché à l'image, mais rien ne prouve qui l'a produit. Avec `cosign attest`, attachez à `localhost:5001/cours/tampon:1.0.0` un SBOM CycloneDX produit par Trivy, **signé** par votre clé, puis vérifiez-le avec `cosign verify-attestation` et lisez la liste des composants qu'il contient.

:::

<details>
<summary>Corrigé</summary>

```bash
trivy image --quiet --format cyclonedx -o tampon.cdx.json localhost:5001/cours/tampon:1.0.0
D=$(docker buildx imagetools inspect localhost:5001/cours/tampon:1.0.0 --format '{{json .Manifest}}' | jq -r .digest)
cosign attest --yes --key cle/cosign.key --signing-config cle/sans-journal.json --allow-http-registry \
  --type cyclonedx --predicate tampon.cdx.json localhost:5001/cours/tampon@$D
cosign verify-attestation --key cle/cosign.pub --insecure-ignore-tlog=true --allow-http-registry \
  --type cyclonedx localhost:5001/cours/tampon:1.0.0 2>/dev/null \
  | jq -r '.payload' | base64 -d | jq -r '.predicateType, (.predicate.components | length), ([.predicate.components[].name] | join(" "))'
```

```sortie
https://cyclonedx.org/bom
10
debian tampon base-files ca-certificates media-types netbase tzdata-legacy tzdata stdlib tampon
```

Une **attestation** est une déclaration signée à propos d'une image : ici « voici son SBOM », ailleurs « elle a passé les tests » ou « elle a été analysée sans faille critique ». Elle suit le format in-toto : un sujet (l'empreinte de l'image), un type de prédicat (`https://cyclonedx.org/bom`) et le prédicat lui-même (le SBOM), le tout enveloppé et signé. `cosign tree` montre désormais deux referrers : la signature et l'attestation. Une politique d'admission pourra exiger non seulement une signature, mais aussi une attestation de tel type, signée par telle clé.

</details>

## Nettoyer

Gardez le registre `registre` et son volume : la partie III y poussera les images de Colis. Gardez aussi votre paire de clés, dans un endroit sûr. Le reste se supprime :

```bash
docker rmi nginx-corrige:1.30
rm -f sbom.json prov.json colis.json colis.cdx.json s.json x.json n.json *.cdx.json
docker buildx rm cours          # le constructeur et son cache ; recréez-le au besoin
```

Le registre s'arrête avec `docker stop registre` et redémarre avec `docker start registre`, sans rien perdre.

[^xz]: Andres Freund, « backdoor in upstream xz/liblzma leading to ssh server compromise », liste oss-security, 29 mars 2024. [openwall.com/lists/oss-security/2024/03/29/4](https://www.openwall.com/lists/oss-security/2024/03/29/4)

[^insecure-registry]: Docker, « Test an insecure registry ». [docs.docker.com/engine/daemon/insecure-registries](https://docs.docker.com/engine/daemon/insecure-registries/)

[^buildkit-attestations]: Docker, « Build attestations », pages *SBOM attestations* et *Provenance attestations*. [docs.docker.com/build/metadata/attestations](https://docs.docker.com/build/metadata/attestations/)

[^spdx]: The Linux Foundation, « SPDX: The System Package Data Exchange ». [spdx.dev](https://spdx.dev/)

[^cyclonedx]: OWASP, « CycloneDX Bill of Materials Standard ». [cyclonedx.org](https://cyclonedx.org/)

[^eo14028]: Executive Order 14028, « Improving the Nation's Cybersecurity », 12 mai 2021, section 4(e)(vii). [federalregister.gov/d/2021-10460](https://www.federalregister.gov/d/2021-10460)

[^cra]: Règlement (UE) 2024/2847 du Parlement européen et du Conseil du 23 octobre 2024 concernant des exigences horizontales en matière de cybersécurité pour les produits comportant des éléments numériques (règlement sur la cyberrésilience), annexe I, partie II. [eur-lex.europa.eu/eli/reg/2024/2847/oj](https://eur-lex.europa.eu/eli/reg/2024/2847/oj)

[^slsa]: OpenSSF, « SLSA: Supply-chain Levels for Software Artifacts », spécification 1.0, section *Provenance*. [slsa.dev/spec/v1.0/provenance](https://slsa.dev/spec/v1.0/provenance)

[^trivy]: Aqua Security, « Trivy ». [trivy.dev](https://trivy.dev/)

[^trivy-status]: Aqua Security, documentation de Trivy, « Vulnerability », section *Status*. [trivy.dev/latest/docs/scanner/vulnerability](https://trivy.dev/latest/docs/scanner/vulnerability/)

[^sigstore]: Sigstore, « Overview », et documentation de cosign. [docs.sigstore.dev](https://docs.sigstore.dev/)

[^oci-referrers]: Open Container Initiative, *Distribution Specification* 1.1, sections *Listing Referrers* et *Referrers Tag Schema*. [github.com/opencontainers/distribution-spec/blob/main/spec.md](https://github.com/opencontainers/distribution-spec/blob/main/spec.md)

[^registry-gc]: CNCF Distribution, « Garbage collection ». [distribution.github.io/distribution/about/garbage-collection](https://distribution.github.io/distribution/about/garbage-collection/)
