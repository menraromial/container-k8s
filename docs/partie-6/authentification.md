---
title: L'authentification
sidebar_label: 42. L'authentification
description: "Comment l'API server sait qui lui parle : certificats clients obtenus par l'API CSR et ce qu'on ne peut pas révoquer, jetons de ServiceAccount liés à un Pod, projetés et renouvelés, TokenRequest et TokenReview, anciens jetons de Secret, vérification hors ligne, et un fournisseur OIDC écrit à la main branché sur l'API server."
partie: 6
chapitre: '42'
---

import authentificateurs from '@site/src/figures/authentificateurs.svg';
import jetonProjete from '@site/src/figures/jeton-projete.svg';

Bruno quitte l'équipe ce soir, et pas dans les meilleurs termes. Son kubeconfig contient un certificat client que le cluster a signé pour un an. Avant qu'il ne parte, on voudrait lui retirer l'accès. Rejouons d'abord son arrivée : voici comment on lui avait fabriqué ce certificat, avec le script `nouvel-utilisateur.sh` de [l'archive authentification](pathname:///kits/authentification.tar.gz), qu'on démonte un peu plus loin :

```bash
NS=ch42 DUREE=31536000 bash nouvel-utilisateur.sh bruno equipe-colis
KUBECONFIG=bruno.kubeconfig kubectl auth whoami
```

```sortie
certificatesigningrequest.certificates.k8s.io/bruno created
certificatesigningrequest.certificates.k8s.io/bruno approved
bruno.kubeconfig prêt : subject=O=equipe-colis, CN=bruno, valable jusqu'au Oct  2 19:29:27 2027 GMT
ATTRIBUTE                                           VALUE
Username                                            bruno
Groups                                              [equipe-colis system:authenticated]
Extra: authentication.kubernetes.io/credential-id   [X509SHA256=58142c8bf98b6c4e62c9d8e8d5629fc81abcd33d7fc3b302fc3e11a64adf9455]
```

Le certificat a été obtenu par un objet de l'API, une `CertificateSigningRequest` nommée `bruno`. Le réflexe naturel est de la supprimer, puis de chercher un objet « utilisateur » ou une liste de révocation :

```bash
kubectl delete csr bruno
KUBECONFIG=bruno.kubeconfig kubectl auth whoami -o jsonpath='{.status.userInfo.username}{"\n"}'
kubectl api-resources | grep -i -E 'revo|crl' || echo "(aucune ressource)"
```

```sortie
certificatesigningrequest.certificates.k8s.io "bruno" deleted
bruno
(aucune ressource)
```

Bruno est toujours reconnu, et il n'y a rien d'autre à supprimer. Kubernetes ne stocke aucun utilisateur : la documentation le dit sans détour, les utilisateurs « normaux » ne peuvent pas être ajoutés par un appel d'API, ils sont gérés hors du cluster[^authn]. L'API server croit tout certificat signé par l'autorité du cluster, et ne consulte aucune liste de révocation ; aucune de ses options ne permet même de lui en donner une[^flags]. La CSR n'était qu'un formulaire de demande, et le certificat signé vit sa vie sans elle, jusqu'à sa date de fin. Les seules issues sont de retirer à Bruno ses droits (chapitre 43, en espérant qu'ils ne lui viennent pas d'un groupe partagé), ou de changer l'autorité du cluster, ce qui invalide d'un coup tous les certificats, ceux des nœuds compris.

Voilà de quoi ce chapitre parle : comment l'API server reconnaît ceux qui lui parlent, ce que chaque méthode permet de reprendre, et pourquoi on finit presque toujours par confier les humains à un fournisseur d'identité. On travaille dans le namespace `ch42` du cluster principal, avec les fichiers de l'archive.

## Les portes d'entrée de l'API server

L'authentification est la première étape du trajet d'une requête (figure 34.2). L'API server y essaie, l'un après l'autre, les **authentificateurs** qu'on lui a configurés ; le premier qui reconnaît la requête produit une identité, et les suivants ne sont pas consultés. Les options du Pod `kube-apiserver` disent lesquels sont actifs sur minikube :

```bash
kubectl -n kube-system get pod kube-apiserver-minikube -o json | jq -r '.spec.containers[0].command[]' \
  | grep -E 'client-ca|service-account|bootstrap|requestheader-(client|allowed|username|group)|authorization-mode'
```

```sortie
--authorization-mode=Node,RBAC
--client-ca-file=/var/lib/minikube/certs/ca.crt
--enable-bootstrap-token-auth=true
--requestheader-allowed-names=front-proxy-client
--requestheader-client-ca-file=/var/lib/minikube/certs/front-proxy-ca.crt
--requestheader-group-headers=X-Remote-Group
--requestheader-username-headers=X-Remote-User
--service-account-issuer=https://kubernetes.default.svc.cluster.local
--service-account-key-file=/var/lib/minikube/certs/sa.pub
--service-account-signing-key-file=/var/lib/minikube/certs/sa.key
```

On y lit quatre portes. `--client-ca-file` : tout certificat client signé par cette autorité est accepté, son `CN` donne le nom et ses `O` les groupes. `--enable-bootstrap-token-auth` : des jetons d'amorçage, stockés dans des Secrets de `kube-system`, qui servent à faire entrer de nouveaux nœuds (exercice 4). Les trois options `--service-account-*` : les jetons de ServiceAccount, signés avec `sa.key` et vérifiés avec `sa.pub`. Les options `--requestheader-*` enfin : un proxy frontal, reconnu à son certificat (`front-proxy-client`), peut authentifier lui-même l'utilisateur et transmettre son nom dans des en-têtes HTTP ; c'est ainsi que l'API server relaie les requêtes vers les API agrégées comme `metrics.k8s.io` (chapitre 34). La première ligne, `--authorization-mode`, appartient à l'étape suivante, l'autorisation ; on l'a gardée parce qu'elle rappelle où l'on va.

Il reste une cinquième voie, implicite : une requête qu'aucun authentificateur ne reconnaît et qui ne présente aucune pièce devient celle de `system:anonymous`, dans le groupe `system:unauthenticated`, puisque l'option `--anonymous-auth` vaut `true` par défaut[^flags]. Une requête qui présente une pièce fausse, en revanche, est rejetée par un `401`, sans passer à l'anonyme : vous l'avez vu au chapitre 34 avec un jeton inventé.

<Figure svg={authentificateurs} num="42.1" alt="À gauche, quatre choses qu'un client peut présenter : un certificat client pendant la poignée TLS, des en-têtes X-Remote posés par un proxy frontal, un en-tête Authorization Bearer avec un jeton, ou rien. Au centre, dans l'API server, l'authentificateur correspondant : autorité --client-ca-file, CN vers nom et O vers groupes ; proxy reconnu par son certificat ; jeton d'amorçage, de ServiceAccount (signé par sa.key, objets liés vivants) ou OIDC (émetteur de l'AuthenticationConfiguration) ; anonyme si permis sur ce chemin. À droite, un succès donne un UserInfo (username, uid, groups dont system:authenticated, extra) qui part vers l'autorisation ; aucun succès donne 401 Unauthorized.">
Les authentificateurs de l'API server. Le premier qui reconnaît la requête produit un <code>UserInfo</code> ; c'est tout ce que les étapes suivantes sauront de l'appelant.
</Figure>

Quel que soit l'authentificateur, le résultat a toujours la même forme, un `UserInfo` : un nom, parfois un `uid`, une liste de groupes, et des informations supplémentaires (`extra`). Le groupe `system:authenticated` est ajouté à toute identité reconnue. C'est exactement ce qu'affiche `kubectl auth whoami`, qui pose la question à l'API server par un objet `SelfSubjectReview`[^authn]. La ligne `credential-id` de Bruno mérite qu'on s'y arrête : c'est l'empreinte SHA-256 de son certificat. Elle figure dans les journaux d'audit, et permet de savoir quel certificat précis a servi, quand deux certificats portent le même nom.

## Fabriquer un utilisateur, pas à pas

Démontons `nouvel-utilisateur.sh`, avec une seconde utilisatrice, Alice. Tout commence chez elle, pas dans le cluster : elle fabrique une clé privée, qui ne quittera jamais son poste, et une demande de signature (CSR, au sens de X.509) qui porte son nom et son groupe :

```bash
openssl genpkey -algorithm ed25519 -out alice.key
openssl req -new -key alice.key -subj "/CN=alice/O=equipe-colis" -out alice.csr
openssl req -in alice.csr -noout -subject
```

```sortie
subject=CN=alice, O=equipe-colis
```

La demande est ensuite confiée au cluster, dans un objet `CertificateSigningRequest`. Le champ `signerName` désigne qui doit signer : `kubernetes.io/kube-apiserver-client` est le signataire intégré qui produit des certificats clients reconnus par l'API server[^csr]. `expirationSeconds` demande une durée, ici un jour :

```yaml title="alice-csr.yaml"
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: alice
spec:
  request: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURSBSRVFVRVNULS0tLS0K...   # base64 -w0 alice.csr
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400
  usages: [client auth]
```

```bash
kubectl apply -f alice-csr.yaml
kubectl get csr alice
kubectl certificate approve alice
kubectl get csr alice
```

```sortie
certificatesigningrequest.certificates.k8s.io/alice created
NAME    AGE   SIGNERNAME                            REQUESTOR       REQUESTEDDURATION   CONDITION
alice   0s    kubernetes.io/kube-apiserver-client   minikube-user   24h                 Pending
certificatesigningrequest.certificates.k8s.io/alice approved
NAME    AGE   SIGNERNAME                            REQUESTOR       REQUESTEDDURATION   CONDITION
alice   3s    kubernetes.io/kube-apiserver-client   minikube-user   24h                 Approved,Issued
```

Deux rôles distincts se succèdent. Quelqu'un **approuve** : ici vous, par `kubectl certificate approve`, qui ajoute une condition `Approved` à l'objet ; pour ce signataire, Kubernetes n'approuve jamais rien tout seul[^csr]. Puis un contrôleur **signe** : le signataire intégré tourne dans `kube-controller-manager`, avec la clé de l'autorité du cluster (`--cluster-signing-key-file`), et dépose le certificat dans `status.certificate` deux secondes plus tard. La colonne `REQUESTOR` garde la trace de qui a déposé la demande. Récupérons le certificat :

```bash
kubectl get csr alice -o jsonpath='{.status.certificate}' | base64 -d > alice.crt
date -u +%T
openssl x509 -in alice.crt -noout -subject -issuer -dates -ext extendedKeyUsage
```

```sortie
19:34:33
subject=O=equipe-colis, CN=alice
issuer=CN=minikubeCA
notBefore=Oct  2 19:29:31 2026 GMT
notAfter=Oct  3 19:29:31 2026 GMT
X509v3 Extended Key Usage: 
    TLS Web Client Authentication
```

Signé par `minikubeCA`, réservé à l'authentification d'un client. Regardez les dates : il est 19 h 34, et le certificat est valable depuis 19 h 29. Ce n'est pas une erreur. Le signataire **antidate** le début de validité de cinq minutes, pour qu'un client dont l'horloge retarde un peu ne voie pas un certificat « pas encore valable ». Pour les certificats de plus de huit heures, il retire aussi ces cinq minutes à la fin ; c'est pourquoi le certificat d'Alice expire demain à 19 h 29, et non à 19 h 34. Les certificats plus courts gardent leur durée entière après la signature. Ces règles ne sont écrites que dans le code du signataire, qui les commente lui-même : cinq minutes, c'est environ 1 % de huit heures[^signer].

Reste à fabriquer le kubeconfig, avec les commandes du chapitre 16. `--embed-certs` recopie le certificat et la clé dans le fichier, qui devient autonome (et donc aussi précieux que la clé) :

```bash
K=alice.kubeconfig
kubectl --kubeconfig=$K config set-cluster cours --server=https://192.168.49.2:8443 --certificate-authority=$HOME/.minikube/ca.crt --embed-certs
kubectl --kubeconfig=$K config set-credentials alice --client-certificate=alice.crt --client-key=alice.key --embed-certs
kubectl --kubeconfig=$K config set-context alice@cours --cluster=cours --user=alice --namespace=ch42
kubectl --kubeconfig=$K config use-context alice@cours
KUBECONFIG=$K kubectl auth whoami
openssl x509 -in alice.crt -noout -fingerprint -sha256
KUBECONFIG=$K kubectl get pods
```

```sortie
Cluster "cours" set.
User "alice" set.
Context "alice@cours" created.
Switched to context "alice@cours".
ATTRIBUTE                                           VALUE
Username                                            alice
Groups                                              [equipe-colis system:authenticated]
Extra: authentication.kubernetes.io/credential-id   [X509SHA256=ba1e3e62cfbde8c05080b24f89b73dc25ff899ea3869045a2d222a71ed1cbc67]
sha256 Fingerprint=BA:1E:3E:62:CF:BD:E8:C0:50:80:B2:4F:89:B7:3D:C2:5F:F8:99:EA:38:69:04:5A:2D:22:2A:71:ED:1C:BC:67
Error from server (Forbidden): pods is forbidden: User "alice" cannot list resource "pods" in API group "" in the namespace "ch42"
```

L'empreinte calculée par `openssl` est bien la valeur de `credential-id`. Et Alice est reconnue, mais ne peut rien faire : l'authentification a réussi, l'autorisation a échoué, d'où le `403` (un échec d'authentification aurait donné `401`). Lui donner des droits est l'affaire du chapitre 43.

Une remarque en passant, si vous donnez plusieurs groupes à quelqu'un (`nouvel-utilisateur.sh bruno equipe-colis astreinte`) : `openssl` affichera dans le certificat signé `O=astreinte + O=equipe-colis`. Le signataire, écrit en Go, regroupe les valeurs d'un même attribut dans un seul élément du nom ; l'API server y lit toujours deux groupes.

### Ce que le signataire refuse

Si l'API CSR signe ce qu'on lui demande, qu'est-ce qui empêche quelqu'un qui a le droit de créer et d'approuver des CSR de se fabriquer un certificat du groupe `system:masters`, celui qui a tous les droits ? Essayons :

```bash
openssl genpkey -algorithm ed25519 -out pirate.key
openssl req -new -key pirate.key -subj "/CN=pirate/O=system:masters" -out pirate.csr
kubectl apply -f pirate-csr.yaml
```

(`pirate-csr.yaml` est construit comme `alice-csr.yaml`, avec le nom `pirate`, le contenu de `pirate.csr` en base64, et sans `expirationSeconds`.)

```sortie
Error from server (Forbidden): error when creating "pirate-csr.yaml": certificatesigningrequests.certificates.k8s.io "pirate" is forbidden: use of kubernetes.io/kube-apiserver-client signer with system:masters group is not allowed
```

La demande n'existe même pas : elle est refusée à la création, par le contrôleur d'admission `CertificateSubjectRestriction`, actif par défaut, qui interdit précisément ce groupe pour ce signataire[^adm]. Vous étiez pourtant `system:masters` vous-même au moment de la demande. Notez que le garde-fou ne porte que sur ce groupe : un certificat au nom de `system:kube-controller-manager`, ou dans le groupe `system:nodes`, passerait, et donnerait les droits de ces composants. Le droit d'approuver des CSR est donc un droit à donner avec parcimonie ; on le retrouvera parmi les escalades du chapitre 43.

Les durées, elles, sont encadrées des deux côtés :

```bash
# deux demandes construites de la même façon, pour bob-60 et bob-315360000
kubectl apply -f b60.yaml           # expirationSeconds: 60
kubectl apply -f b315360000.yaml    # expirationSeconds: 315360000, dix ans
kubectl certificate approve bob-315360000
date -u +%T
kubectl get csr bob-315360000 -o jsonpath='{.status.certificate}' | base64 -d | openssl x509 -noout -dates
```

```sortie
The CertificateSigningRequest "bob-60" is invalid: spec.expirationSeconds: Invalid value: 60: may not specify a duration less than 600 seconds (10 minutes)
certificatesigningrequest.certificates.k8s.io/bob-315360000 created
19:34:36
notBefore=Oct  2 19:29:34 2026 GMT
notAfter=Oct  2 19:29:34 2027 GMT
```

Moins de dix minutes est refusé d'emblée : c'est le double de l'antidatage, sans quoi un certificat pourrait naître déjà expiré. Dix ans sont acceptés, mais ramenés à un an : la durée effective est le minimum de la demande et de l'option `--cluster-signing-duration` du gestionnaire de contrôleurs, qui vaut un an par défaut[^csr]. Le certificat de Bruno de l'ouverture n'aurait pas pu durer plus. Celui de `minikube-user`, avec lequel vous travaillez, a été fabriqué par minikube hors de cette API, directement avec la clé de l'autorité :

```bash
openssl x509 -in ~/.minikube/profiles/minikube/client.crt -noout -subject -dates
```

```sortie
subject=O=system:masters, CN=minikube-user
notBefore=Sep 24 09:02:40 2026 GMT
notAfter=Sep 24 09:02:40 2029 GMT
```

Trois ans, `system:masters`, irrévocable. Sur un poste de travail, c'est un choix raisonnable ; sur un cluster partagé, ce serait une clé passe-partout qu'on ne peut plus changer qu'en changeant toutes les serrures.

:::panne[error: You must be logged in to the server (Unauthorized), un matin, sans rien avoir changé]

Le certificat a expiré. kubectl n'en dit rien, mais l'API server l'écrit dans ses journaux, ce que l'exercice 1 vous fait reproduire :

```sortie
x509: certificate has expired or is not yet valid: current time 2026-10-02T19:44:34Z is after 2026-10-02T19:44:29Z
```

`openssl x509 -in <(kubectl config view --raw --minify -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d) -noout -enddate` donne la date de fin du certificat du contexte courant. Si la fin est encore loin, regardez l'horloge du poste : un certificat tout juste signé peut aussi être « pas encore valable » pour une machine dont l'horloge retarde de plus de cinq minutes.

:::

## Les jetons de ServiceAccount

Les certificats conviennent mal aux programmes qui tournent dans le cluster : il faudrait en fabriquer un par application, et on ne pourrait pas les reprendre. Les Pods utilisent donc des **jetons de ServiceAccount**. On a vu au chapitre 34 que l'admission en monte un dans chaque Pod ; ouvrons-le. Le Pod `outil` tourne sous un ServiceAccount `robot` créé pour l'occasion :

```bash
kubectl -n ch42 create sa robot
kubectl apply -f outil.yaml
kubectl -n ch42 exec outil -- ls /var/run/secrets/kubernetes.io/serviceaccount/
kubectl -n ch42 exec outil -- cat /var/run/secrets/kubernetes.io/serviceaccount/token > jeton-pod.txt
cut -d. -f1 jeton-pod.txt | base64 -d; echo
cut -d. -f2 jeton-pod.txt | tr '_-' '/+' | base64 -d | jq .
```

```sortie
ca.crt
namespace
token
{"alg":"RS256","kid":"j3tH1Un8qD5FXx6XeeFNitiVfZUeW54dmF5EqMMvjds"}
{
  "aud": [
    "https://kubernetes.default.svc.cluster.local"
  ],
  "exp": 1822505676,
  "iat": 1790969676,
  "iss": "https://kubernetes.default.svc.cluster.local",
  "jti": "2ae219df-0e38-4c6d-b2a9-11a145ec233e",
  "kubernetes.io": {
    "namespace": "ch42",
    "node": {
      "name": "minikube",
      "uid": "297b7d1e-7c18-48e0-94c2-c038eab47051"
    },
    "pod": {
      "name": "outil",
      "uid": "ba776f02-5e4b-4188-bdb6-343789f0478c"
    },
    "serviceaccount": {
      "name": "robot",
      "uid": "c2564425-f3eb-45e3-b49f-f7ea7f538513"
    },
    "warnafter": 1790973283
  },
  "nbf": 1790969676,
  "sub": "system:serviceaccount:ch42:robot"
}
```

C'est un **JWT** (*JSON Web Token*) : trois morceaux en base64, séparés par des points, l'en-tête, la charge et la signature[^jwt]. Le `tr '_-' '/+'` traduit l'alphabet base64 « pour les URL » des JWT vers l'alphabet ordinaire ; `base64` se plaint parfois du rembourrage manquant, mais décode quand même. L'en-tête annonce une signature RSA avec SHA-256 (`RS256`), faite avec la clé identifiée par `kid`. La charge contient les **revendications** (*claims*) :

- `iss`, l'émetteur, est la valeur de `--service-account-issuer` ; `aud`, l'audience, dit à qui le jeton est destiné, ici l'API server lui-même ;
- `iat`, `nbf` et `exp` sont des dates en secondes depuis 1970 : émission, début et fin de validité ; `jti` est un identifiant unique, qui sert de `credential-id` ;
- `sub` est le nom d'utilisateur que l'API server en tirera, `system:serviceaccount:<namespace>:<nom>` ;
- `kubernetes.io` dit à quoi le jeton est **lié** : au ServiceAccount, mais aussi au Pod et au nœud, chacun avec son `uid`.

Faites le calcul de `exp - iat` :

```bash
cut -d. -f2 jeton-pod.txt | tr '_-' '/+' | base64 -d \
  | jq '{validite_jours: ((.exp - .iat) / 86400), alerte_secondes: (.["kubernetes.io"].warnafter - .iat)}'
```

```sortie
{
  "validite_jours": 365,
  "alerte_secondes": 3607
}
```

Un an. Le chapitre 34 parlait pourtant d'un jeton « valable une heure » : c'est bien ce que le kubelet demande, 3607 secondes. Mais l'API server, par défaut, prolonge jusqu'à un an les jetons qu'il injecte dans les Pods, pour ne pas casser les vieilles applications qui lisent le jeton une fois au démarrage et ne le relisent jamais. C'est l'option `--service-account-extend-token-expiration`, à `true` par défaut, que sa documentation présente comme une aide à la transition[^flags]. La durée demandée n'est pas perdue : elle est notée dans `warnafter`. Un jeton utilisé après cette date reste accepté, mais l'API server le compte comme périmé (*stale*) dans ses métriques et ses journaux d'audit ; c'est ainsi qu'on repère les applications à corriger avant de couper la prolongation.

Un an, ce serait inquiétant si le jeton ne valait que par sa date. Ce n'est pas le cas. Utilisons-le depuis le poste, puis supprimons le Pod :

```bash
T=$(cat jeton-pod.txt)
kubectl --kubeconfig=/dev/null --server=https://192.168.49.2:8443 --certificate-authority=$HOME/.minikube/ca.crt --token="$T" auth whoami
kubectl -n ch42 delete pod outil --wait
kubectl --kubeconfig=/dev/null --server=https://192.168.49.2:8443 --certificate-authority=$HOME/.minikube/ca.crt --token="$T" auth whoami
kubectl -n kube-system logs kube-apiserver-minikube --since=20s | grep 'Unable to authenticate' | tail -1 | sed 's/.*err=//'
```

```sortie
ATTRIBUTE                                           VALUE
Username                                            system:serviceaccount:ch42:robot
UID                                                 c2564425-f3eb-45e3-b49f-f7ea7f538513
Groups                                              [system:serviceaccounts system:serviceaccounts:ch42 system:authenticated]
Extra: authentication.kubernetes.io/credential-id   [JTI=2ae219df-0e38-4c6d-b2a9-11a145ec233e]
Extra: authentication.kubernetes.io/node-name       [minikube]
Extra: authentication.kubernetes.io/node-uid        [297b7d1e-7c18-48e0-94c2-c038eab47051]
Extra: authentication.kubernetes.io/pod-name        [outil]
Extra: authentication.kubernetes.io/pod-uid         [ba776f02-5e4b-4188-bdb6-343789f0478c]
pod "outil" deleted from ch42 namespace
error: You must be logged in to the server (Unauthorized)
"[invalid bearer token, service account token has been invalidated]"
```

Tant que le Pod vivait, le jeton fonctionnait depuis n'importe où, y compris depuis votre poste : un jeton volé dans un conteneur est utilisable par le voleur. Mais dès que le Pod a disparu, une trentaine de secondes plus tard (le `sleep` de netshoot, en PID 1, ignore SIGTERM, et kubectl attend la fin du délai de grâce), le jeton est devenu inutilisable, presque un an avant sa date de fin. À chaque requête, l'API server vérifie que les objets auxquels le jeton est lié existent encore, **avec le même `uid`** : un Pod recréé sous le même nom ne ressusciterait pas le jeton. C'est la différence essentielle avec un certificat. Le jeton est révocable, et il est révoqué automatiquement avec ce qui l'a justifié. Remarquez aussi les groupes : tout ServiceAccount est dans `system:serviceaccounts` et dans `system:serviceaccounts:<namespace>`, deux groupes très pratiques pour donner un droit à tous les comptes d'un namespace, et très dangereux pour la même raison.

### Demander un jeton : TokenRequest

Le kubelet n'a pas fabriqué ce jeton : il l'a demandé à l'API server, par la sous-ressource `token` du ServiceAccount, l'API **TokenRequest**. `kubectl create token` fait la même demande, et permet d'en choisir la durée et l'audience :

```bash
kubectl -n ch42 create token robot --duration=1m
kubectl -n ch42 create token robot --duration=87600h > jeton-10ans.txt
cut -d. -f2 jeton-10ans.txt | tr '_-' '/+' | base64 -d | jq -c '{iat, exp, jours: ((.exp - .iat) / 86400)}'
kubectl -n ch42 create token robot --duration=10m --audience=coffre > jeton-coffre-cli.txt
cut -d. -f2 jeton-coffre-cli.txt | tr '_-' '/+' | base64 -d | jq -c '{aud, duree: (.exp - .iat), lie_a: (.["kubernetes.io"] | keys)}'
```

```sortie
error: failed to create token: TokenRequest.authentication.k8s.io "" is invalid: spec.expirationSeconds: Invalid value: 60: may not specify a duration less than 10 minutes
{"iat":1790969710,"exp":2106329710,"jours":3650}
{"aud":["coffre"],"duree":600,"lie_a":["namespace","serviceaccount"]}
```

Même plancher de dix minutes que pour les certificats. Mais pas de plafond : un jeton de dix ans a été émis sans discussion. Un jeton demandé ainsi n'est lié qu'au ServiceAccount (`namespace` et `serviceaccount`, pas de Pod) : il vivra dix ans, ou jusqu'à la suppression du compte. En production, on fixe un plafond avec l'option `--service-account-max-token-expiration` de l'API server, qui ramène toute demande plus longue à sa valeur[^flags] ; minikube ne la positionne pas.

Le troisième jeton est destiné à un autre service que l'API server, un coffre-fort à secrets imaginaire nommé `coffre`. C'est l'usage le plus élégant de ces jetons : prouver son identité à un tiers. Le tiers ne sait pas vérifier un jeton Kubernetes ? Il le demande à l'API server, par un objet **TokenReview**, en précisant l'audience qu'il attend :

```bash
kubectl create -f revue.json -o json | jq -c '.status | {authenticated, user: .user.username, audiences, error}'
```

```sortie
{"authenticated":null,"user":null,"audiences":null,"error":"[invalid bearer token, token audiences [\"coffre\"] is invalid for the target audiences [\"https://kubernetes.default.svc.cluster.local\"]]"}
{"authenticated":true,"user":"system:serviceaccount:ch42:robot","audiences":["coffre"],"error":null}
```

Sans audience précisée (première ligne), l'API server vérifie le jeton pour lui-même, et le refuse : il est destiné à `coffre`. Avec `audiences: [coffre]` (seconde ligne), il est accepté. L'audience empêche un service qui reçoit des jetons de les rejouer ailleurs : le coffre, s'il était compromis, ne pourrait pas utiliser les jetons de ses clients pour parler à l'API server en leur nom. Les composants qui reçoivent des jetons sans être l'API server, le kubelet ou metrics-server par exemple, font exactement ce que fait ici le coffre : ils passent par TokenReview pour authentifier leurs appelants.

### Un jeton par destinataire, renouvelé tout seul

Un Pod peut recevoir ce genre de jeton sans rien demander, par un volume **projeté** de type `serviceAccountToken`. Le Pod `client-coffre` refuse le jeton habituel (`automountServiceAccountToken: false`) et en reçoit un autre, pour `coffre`, de dix minutes :

```yaml title="coffre.yaml (extrait)"
spec:
  serviceAccountName: robot
  automountServiceAccountToken: false
  containers:
  - name: client
    image: busybox:1.37
    command: [sleep, infinity]
    volumeMounts:
    - name: jeton-coffre
      mountPath: /var/run/secrets/coffre
      readOnly: true
  volumes:
  - name: jeton-coffre
    projected:
      sources:
      - serviceAccountToken:
          path: jeton
          audience: coffre
          expirationSeconds: 600
```

```bash
kubectl apply -f coffre.yaml
kubectl -n ch42 exec client-coffre -- ls /var/run/secrets/
kubectl -n ch42 exec client-coffre -- ls -la /var/run/secrets/coffre/
kubectl -n ch42 exec client-coffre -- cat /var/run/secrets/coffre/jeton > jeton-coffre.txt
cut -d. -f2 jeton-coffre.txt | tr '_-' '/+' | base64 -d | jq -c '{aud, iat, exp, duree: (.exp - .iat), warnafter: .["kubernetes.io"].warnafter}'
```

```sortie
coffre
total 4
drwxrwxrwt    3 root     root           100 Oct  2 19:34 .
drwxr-xr-x    3 root     root          4096 Oct  2 19:34 ..
drwxr-xr-x    2 root     root            60 Oct  2 19:34 ..2026_10_02_19_34_30.1240559129
lrwxrwxrwx    1 root     root            32 Oct  2 19:34 ..data -> ..2026_10_02_19_34_30.1240559129
lrwxrwxrwx    1 root     root            12 Oct  2 19:34 jeton -> ..data/jeton
{"aud":["coffre"],"iat":1790969670,"exp":1790970270,"duree":600,"warnafter":null}
```

Plus de dossier `kubernetes.io/serviceaccount` : seul le jeton du coffre est là. Et cette fois, pas de prolongation : la durée est de 600 secondes exactement, puisque la prolongation ne concerne que les jetons destinés à l'API server. Comment le Pod survit-il à l'expiration ? Le kubelet renouvelle le jeton quand il a dépassé 80 % de sa durée, ou 24 heures[^sa]. Le script de rejeu lit le fichier toutes les quinze secondes pendant un quart d'heure ; on garde les changements :

```sortie
1790969670 ..2026_10_02_19_34_30.1240559129 {"iat":1790969670,"exp":1790970270}
1790970216 ..2026_10_02_19_43_31.1561968441 {"iat":1790970211,"exp":1790970811}
```

<Figure svg={jetonProjete} num="42.2" alt="Une frise de 0 à 1300 secondes. Le jeton 1 va de 0 à 600. Une flèche pointillée marque le seuil des 80 %, à 480 secondes. Le jeton 2 commence à 547 secondes, quand le kubelet remplace le fichier, et va jusqu'à 1147 ; entre 547 et 600, les deux jetons sont valides. Un jeton 3 commence vers 1100. En dessous, deux encadrés : n'importe qui, avec les clés publiques de /openid/v1/jwks ou verifier-jeton.py, peut vérifier la signature RS256 et le kid, l'émetteur, l'audience et les dates ; seul l'API server, ou un TokenReview, vérifie en plus que le ServiceAccount et le Pod lié existent avec le même uid.">
La vie d'un jeton projeté de 600 s, mesurée lors d'une première série d'essais (renouvellement à 547 s), et ce que chacun peut vérifier.
</Figure>

Le nouveau jeton a été émis 541 secondes après le premier : un peu plus que les 480 secondes du seuil, parce que le kubelet ne passe en revue les volumes des Pods que périodiquement. Le remplacement est **atomique** : le kubelet écrit le nouveau jeton dans un nouveau dossier horodaté, puis fait basculer le lien `..data` ; le programme qui lit `jeton` voit l'ancien fichier ou le nouveau, jamais un fichier à moitié écrit. Pendant 59 secondes, jusqu'à l'`exp` du premier, les deux jetons sont valides. Le kubelet fait sa part ; à l'application de relire le fichier. La documentation suggère de le relire régulièrement, toutes les cinq minutes par exemple, plutôt que de surveiller sa date d'expiration[^sa].

### Les jetons d'avant

Avant Kubernetes 1.24, chaque ServiceAccount recevait automatiquement un Secret contenant un jeton. Ce mécanisme n'existe plus, mais on peut toujours demander un tel Secret, en lui donnant le type `kubernetes.io/service-account-token` et une annotation qui désigne le compte ; un contrôleur y dépose aussitôt un jeton :

```yaml title="robot-jeton.yaml"
apiVersion: v1
kind: Secret
metadata:
  name: robot-jeton
  namespace: ch42
  annotations:
    kubernetes.io/service-account.name: robot
type: kubernetes.io/service-account-token
```

```bash
kubectl apply -f robot-jeton.yaml
kubectl -n ch42 get secret robot-jeton -o jsonpath='{.data.token}' | base64 -d > jeton-secret.txt
cut -d. -f2 jeton-secret.txt | tr '_-' '/+' | base64 -d | jq .
kubectl --kubeconfig=/dev/null --server=https://192.168.49.2:8443 --certificate-authority=$HOME/.minikube/ca.crt \
  --token="$(cat jeton-secret.txt)" auth whoami -o jsonpath='{.status.userInfo.username}{"\n"}'
kubectl -n ch42 get secret robot-jeton -o jsonpath='{.metadata.labels}{"\n"}'
```

```sortie
secret/robot-jeton created
{
  "iss": "kubernetes/serviceaccount",
  "kubernetes.io/serviceaccount/namespace": "ch42",
  "kubernetes.io/serviceaccount/secret.name": "robot-jeton",
  "kubernetes.io/serviceaccount/service-account.name": "robot",
  "kubernetes.io/serviceaccount/service-account.uid": "c2564425-f3eb-45e3-b49f-f7ea7f538513",
  "sub": "system:serviceaccount:ch42:robot"
}
system:serviceaccount:ch42:robot
```

```sortie
{"kubernetes.io/legacy-token-last-used":"2026-10-02"}
```

Pas d'`exp`, pas d'`aud`, pas d'`iat` : ce jeton n'expire jamais, et il est valable pour quiconque l'accepte. Il est stocké dans un Secret, donc lisible par tous ceux qui ont le droit de lire les Secrets du namespace, et en clair dans etcd (chapitre 35). L'étiquette `legacy-token-last-used`, posée par l'API server, dit quand il a servi pour la dernière fois, à la journée près. Pour les jetons de ce genre générés automatiquement par les anciennes versions, Kubernetes marque comme invalides ceux qui n'ont pas servi depuis un an (étiquette `legacy-token-invalid-since`), puis les supprime un an plus tard. Ce nettoyage ne concerne **que** les jetons générés automatiquement[^saadmin] : un Secret comme `robot-jeton`, créé à la main, reste valable tant qu'il existe. Ne vous en servez que si un outil ne sait vraiment pas faire autrement, et sachez où ils sont : `kubectl get secrets -A --field-selector type=kubernetes.io/service-account-token`.

Que deviennent ces jetons quand on supprime le ServiceAccount ? Le jeton de dix ans et celui du Secret sont tous deux liés au compte :

```bash
kubectl -n ch42 delete sa robot
# puis on interroge l'API avec chaque jeton, toutes les 200 ms
kubectl -n ch42 get secret
kubectl -n ch42 create sa robot
```

```sortie
avant : jeton-10ans 200, jeton-secret 200
serviceaccount "robot" deleted from ch42 namespace
aussitôt : jeton-10ans 200, jeton-secret 200
jeton-secret refusé après 8.0 s
No resources found in ch42 namespace.
serviceaccount/robot created
SA recréé : jeton-10ans 401
```

Les deux finissent refusés, et recréer un compte du même nom ne ressuscite pas le jeton de dix ans : l'`uid` a changé. Mais ni l'un ni l'autre n'est refusé sur-le-champ. L'API server garde en mémoire, pendant **dix secondes**, le résultat de chaque authentification par jeton réussie, pour ne pas refaire les mêmes vérifications à chaque requête d'un client bavard ; les échecs, eux, ne sont pas gardés. Ces dix secondes sont une constante de son code, sans option pour la changer[^cache]. La première requête « avant » a rempli ce cache, et les suivantes l'ont lu, jusqu'à son expiration : huit secondes après la suppression, puisque la requête « avant » avait eu lieu deux secondes plus tôt. Mesuré à part, avec un jeton qui venait de servir juste avant la suppression du compte, le délai est de 10,0 secondes à chaque essai. C'est aussi pourquoi le jeton du Pod `outil` a été refusé aussitôt : son dernier succès datait de plus de trente secondes. Retenez-le pour un incident : révoquer un jeton n'est pas instantané, il reste valable dix secondes après sa dernière utilisation réussie.

## Vérifier un jeton soi-même

Le coffre de tout à l'heure demandait son avis à l'API server pour chaque jeton. Il pourrait aussi vérifier la signature lui-même, s'il connaissait la clé publique du cluster. L'API server la publie, au format standard d'OpenID Connect, le protocole d'identité bâti sur OAuth 2.0[^oidc] :

```bash
kubectl get --raw /.well-known/openid-configuration | jq .
kubectl get --raw /openid/v1/jwks | jq '.keys[] | {kty, alg, use, kid, n: (.n[0:20] + "...")}'
```

```sortie
{
  "issuer": "https://kubernetes.default.svc.cluster.local",
  "jwks_uri": "https://192.168.49.2:8443/openid/v1/jwks",
  "response_types_supported": [
    "id_token"
  ],
  "subject_types_supported": [
    "public"
  ],
  "id_token_signing_alg_values_supported": [
    "RS256"
  ]
}
{
  "kty": "RSA",
  "alg": "RS256",
  "use": "sig",
  "kid": "j3tH1Un8qD5FXx6XeeFNitiVfZUeW54dmF5EqMMvjds",
  "n": "7Fi6hoCGDqsRypChkdCT..."
}
```

Le premier document, dit de **découverte**, donne l'émetteur et l'adresse des clés ; le second, le **JWKS** (*JSON Web Key Set*), contient les clés publiques, ici une seule clé RSA dont `n` est le module. Son `kid` est celui de l'en-tête de nos jetons. Il n'a rien d'arbitraire : c'est l'empreinte SHA-256 de la clé publique, encodée en base64 pour les URL[^kid]. On le vérifie avec la clé publique du nœud :

```bash
minikube ssh -- sudo cat /var/lib/minikube/certs/sa.pub > sa.pub
openssl pkey -pubin -in sa.pub -outform DER | openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | tr -d '='
```

```sortie
j3tH1Un8qD5FXx6XeeFNitiVfZUeW54dmF5EqMMvjds
```

Qui a le droit de lire ces clés ? Le JWKS est public par nature, mais l'API server ne le donne pas à n'importe qui :

```bash
kubectl get clusterrolebinding system:service-account-issuer-discovery -o jsonpath='{.subjects}{"\n"}'
curl -s -k https://192.168.49.2:8443/openid/v1/jwks | jq -c '{code, message}'
```

```sortie
[{"apiGroup":"rbac.authorization.k8s.io","kind":"Group","name":"system:serviceaccounts"}]
{"code":403,"message":"forbidden: User \"system:anonymous\" cannot get path \"/openid/v1/jwks\""}
```

Seuls les ServiceAccounts y ont accès par défaut. Pour qu'un service hors du cluster puisse vérifier les jetons, comme le fait un fournisseur de nuage qui échange un jeton de ServiceAccount contre ses propres droits, on publie ces deux documents ailleurs, ou on ouvre ce chemin aux anonymes[^sa].

Le script `verifier-jeton.py` de l'archive fait la vérification complète en une trentaine de lignes, avec la bibliothèque PyJWT : il lit le document de découverte et le JWKS par `kubectl get --raw`, choisit la clé d'après le `kid`, puis vérifie la signature, l'émetteur, l'audience et les dates. Le cœur tient en un appel :

```python title="verifier-jeton.py (extrait)"
revendications = jwt.decode(
    jeton, cles[kid], algorithms=["RS256"],
    issuer=emetteur,
    audience=audience or emetteur,
    options={"require": ["exp", "iat", "sub"]},
)
```

Donnons-lui cinq jetons. Le dernier est le jeton du coffre dont on a remplacé le sujet par celui d'un contrôleur puissant, sans toucher à la signature :

```sortie
$ python3 verifier-jeton.py jeton-pod.txt
signature valide, émise par https://kubernetes.default.svc.cluster.local
  sujet    : system:serviceaccount:ch42:robot
  audience : https://kubernetes.default.svc.cluster.local
  lié à    : Pod outil
  expire   : 2027-10-02T19:34:36+00:00 (dans 364 j)
  périmé   : non (durée demandée dépassée après 2026-10-02T20:34:43+00:00)
$ python3 verifier-jeton.py jeton-coffre.txt
REFUSÉ : InvalidAudienceError : Audience doesn't match
$ python3 verifier-jeton.py jeton-coffre.txt coffre
signature valide, émise par https://kubernetes.default.svc.cluster.local
  sujet    : system:serviceaccount:ch42:robot
  audience : coffre
  lié à    : Pod client-coffre
  expire   : 2026-10-02T19:44:30+00:00 (dans 9 min)
$ python3 verifier-jeton.py jeton-secret.txt
REFUSÉ : MissingRequiredClaimError : Token is missing the "exp" claim
$ python3 verifier-jeton.py jeton-falsifie.txt coffre
REFUSÉ : InvalidSignatureError : Signature verification failed
```

Le jeton falsifié est démasqué : changer un seul caractère de la charge invalide la signature. Le jeton du coffre n'est accepté que pour son audience, et l'ancien jeton de Secret est refusé faute de date d'expiration, parce qu'on l'a exigée. Mais regardez le premier : c'est le jeton du Pod `outil`, supprimé depuis. Le script le déclare valide, et il a raison sur tout ce qu'il peut voir : la signature est bonne, les dates aussi. Ce qu'il ne peut pas voir, c'est que le Pod n'existe plus ; seul l'API server le sait, et lui refuse ce jeton. La vérification hors ligne dit **qui a émis** un jeton, pas s'il est **encore valable**. C'est le partage de la figure 42.2, et la raison pour laquelle un service qui reçoit des jetons de longue durée devrait passer par TokenReview, ou n'accepter que des jetons courts.

## Brancher un fournisseur d'identité

Revenons aux humains. Les certificats ne se révoquent pas, les jetons de ServiceAccount sont faits pour des programmes : comment donner accès à cinquante développeurs, qui arrivent et partent ? En ne les gérant pas dans Kubernetes du tout. L'entreprise a déjà un annuaire, et un **fournisseur d'identité** (Keycloak, Dex, Microsoft Entra ID, Google, Okta…) qui sait authentifier ses employés, avec leur mot de passe et leur second facteur, et qui sait émettre des jetons OpenID Connect. Il suffit que l'API server fasse confiance à ces jetons. Quand quelqu'un part, on le désactive dans l'annuaire, et ses jetons, qui durent quelques minutes, cessent d'être renouvelés.

Pour voir ce que l'API server attend d'un tel fournisseur, le plus instructif est d'en écrire un. `fournisseur.py` en est la version minimale : un serveur HTTPS qui publie un document de découverte et un JWKS, comme celui qu'on vient de lire, et une commande qui signe des jetons. Dans un vrai fournisseur, cette signature a lieu après que l'utilisateur s'est connecté ; ici, on la déclenche à la main. Le serveur écoute sur `192.168.49.1`, l'adresse du poste sur le réseau de minikube, que le nœud joint directement :

```bash
bash preparer-fournisseur.sh
python3 fournisseur.py servir > serveur.log 2>&1 &
curl -s --cacert idp-ca.crt https://192.168.49.1:9443/.well-known/openid-configuration | jq .
```

```sortie
idp.key, idp-ca.crt, https.crt et https.key prêts
{
  "issuer": "https://192.168.49.1:9443",
  "jwks_uri": "https://192.168.49.1:9443/jwks",
  "id_token_signing_alg_values_supported": [
    "RS256"
  ]
}
```

`preparer-fournisseur.sh` a fabriqué la clé de signature des jetons (`idp.key`) et un certificat TLS pour le serveur, signé par une petite autorité locale (`idp-ca.crt`) : l'API server n'accepte de parler qu'à un émetteur en HTTPS, et il doit pouvoir vérifier son certificat.

Reste à dire à l'API server de faire confiance à cet émetteur. Les anciennes options `--oidc-*` n'acceptaient qu'un seul fournisseur. On utilise désormais un fichier, une `AuthenticationConfiguration`, désigné par l'option `--authentication-config`, stable depuis Kubernetes 1.34[^authn] :

```yaml title="authentification.yaml (produit à partir de authentification.yaml.modele)"
apiVersion: apiserver.config.k8s.io/v1
kind: AuthenticationConfiguration
jwt:
- issuer:
    url: https://192.168.49.1:9443
    audiences: [cluster-cours]
    certificateAuthority: |
      -----BEGIN CERTIFICATE-----
      ...
      -----END CERTIFICATE-----
  claimMappings:
    username:
      claim: email
      prefix: "oidc:"
    groups:
      claim: groups
      prefix: "oidc:"
anonymous:
  enabled: true
  conditions:
  - path: /livez
  - path: /readyz
  - path: /healthz
```

La section `jwt` déclare un émetteur : son adresse, l'audience que doivent porter ses jetons, et l'autorité qui a signé son certificat TLS. `claimMappings` dit comment transformer un jeton en `UserInfo` : le nom vient de la revendication `email`, les groupes de `groups`, et tous deux reçoivent le préfixe `oidc:`. La section `anonymous` est un bonus, qu'on regarde plus bas.

`brancher-fournisseur.sh` dépose ce fichier sur le nœud, dans `/var/lib/minikube/certs` (un dossier que le Pod de l'API server monte déjà), et ajoute l'option au manifeste du Pod statique `kube-apiserver`, comme on avait déplacé celui du gestionnaire de contrôleurs au chapitre 36. Le kubelet voit le manifeste changer et redémarre l'API server, ce qui prend trois quarts de minute pendant lesquels kubectl ne répond plus :

```bash
time bash brancher-fournisseur.sh
```

```sortie
API server redémarré avec /var/lib/minikube/certs/cours-authn/authentification.yaml

real	0m46.774s
```

Léa, développeuse, vient de « se connecter » ; le fournisseur lui remet un jeton :

```bash
T=$(python3 fournisseur.py emettre lea@colis.example developpeurs astreinte)
echo "$T" | cut -d. -f2 | tr '_-' '/+' | base64 -d | jq .
kubectl --kubeconfig=/dev/null --server=https://192.168.49.2:8443 --certificate-authority=$HOME/.minikube/ca.crt --token="$T" auth whoami
kubectl --kubeconfig=/dev/null --server=https://192.168.49.2:8443 --certificate-authority=$HOME/.minikube/ca.crt --token="$T" get pods -n colis
```

```sortie
{
  "iss": "https://192.168.49.1:9443",
  "aud": "cluster-cours",
  "sub": "ea65a757-9466-5981-b600-cc56d01681e5",
  "email": "lea@colis.example",
  "email_verified": true,
  "groups": [
    "developpeurs",
    "astreinte"
  ],
  "iat": 1790969773,
  "nbf": 1790969773,
  "exp": 1790970673
}
ATTRIBUTE   VALUE
Username    oidc:lea@colis.example
Groups      [oidc:developpeurs oidc:astreinte system:authenticated]
Error from server (Forbidden): pods is forbidden: User "oidc:lea@colis.example" cannot list resource "pods" in API group "" in the namespace "colis"
```

L'API server a lu le document de découverte et le JWKS de notre fournisseur (son journal en garde la trace), vérifié la signature, et construit l'identité selon nos règles. Léa n'a aucun droit pour l'instant ; au chapitre 43, on les donnera au groupe `oidc:developpeurs`, et non à Léa elle-même, pour que l'arrivée d'un collègue ne demande aucune modification du cluster.

Le jeton dure un quart d'heure. Voyons ce que l'API server refuse. Le fournisseur sait émettre un jeton pour un autre cluster, un jeton dont l'adresse n'a pas été vérifiée, un jeton déjà expiré, et un jeton qui revendique le groupe `system:masters` :

```sortie
$ emettre lea@colis.example developpeurs --audience autre-cluster
error: You must be logged in to the server (Unauthorized)
$ emettre lea@colis.example developpeurs --non-verifie
error: You must be logged in to the server (Unauthorized)
$ emettre lea@colis.example developpeurs --duree -60
error: You must be logged in to the server (Unauthorized)
$ emettre max@colis.example system:masters
Username    oidc:max@colis.example
Groups      [oidc:system:masters system:authenticated]
```

Les trois premiers sont refusés, et le journal de l'API server dit pourquoi :

```sortie
"[invalid bearer token, oidc: verify token: oidc: expected audience \"cluster-cours\" got [\"autre-cluster\"]]"
"[invalid bearer token, oidc: email not verified]"
"[invalid bearer token, oidc: verify token: oidc: token is expired (Token Expiry: 2026-10-02 19:35:14 +0000 UTC)]"
```

Le deuxième refus est intéressant : on n'a rien configuré pour lui. Quand le nom vient de la revendication `email`, l'API server exige d'office que `email_verified` ne soit pas `false`[^authn], parce qu'un fournisseur qui laisse chacun déclarer l'adresse de son choix permettrait de se faire passer pour n'importe qui. Le quatrième jeton est accepté, et c'est voulu : le groupe réclamé est devenu `oidc:system:masters`, un groupe qui n'a aucun sens pour Kubernetes. Sans le préfixe, n'importe quel administrateur du fournisseur d'identité, ou n'importe quel employé capable de s'ajouter à un groupe nommé `system:masters` dans l'annuaire, deviendrait administrateur du cluster. Le préfixe met les identités venues de l'extérieur dans un espace de noms à part.

### Changer les règles sans redémarrer

Une contrainte manque : seules les adresses de l'entreprise devraient être admises. Pour l'instant, un jeton pour `zoe@ailleurs.example` passe. Ajoutons une règle de validation, une expression **CEL** (*Common Expression Language*, le langage d'expressions qu'on retrouvera dans l'admission au chapitre 45), évaluée sur les revendications du jeton :

```yaml title="authentification.yaml (ajout dans l'émetteur, avant claimMappings)"
  claimValidationRules:
  - expression: "claims.email.endsWith('@colis.example')"
    message: "seules les adresses @colis.example sont admises"
```

On relance `brancher-fournisseur.sh`, qui recopie le fichier sur le nœud. Cette fois, l'option est déjà là : il ne touche pas au manifeste. On mesure le temps que met le jeton de Zoé à être refusé :

```sortie
oidc:zoe@ailleurs.example
fichier remplacé ; l'API server le relit seul, sans redémarrer
refusé 11 s après la copie
I1002 19:19:01.905798       1 authentication.go:818] "reloaded authentication config"
"[invalid bearer token, oidc: error evaluating claim validation expression: validation expression 'claims.email.endsWith('@colis.example')' failed: seules les adresses @colis.example sont admises]"
apiserver_authentication_config_controller_automatic_reloads_total{status="success"} 1
```

L'API server surveille le fichier, et recharge ses authentificateurs quand il change[^authn]. Sur les onze secondes mesurées, dix au plus viennent du cache des authentifications réussies, puisque le jeton de Zoé venait de servir. La métrique `apiserver_authentication_config_controller_automatic_reloads_total` compte les rechargements ; avec `status="failure"`, elle vous dirait qu'un fichier invalide a été ignoré, l'ancienne configuration restant en place. C'est ce qui rend cette configuration utilisable en production : ajouter un fournisseur ou corriger une règle ne coupe pas l'API.

### L'anonyme, restreint

La section `anonymous` du fichier a changé autre chose. Voici trois requêtes sans aucune pièce d'identité, faites avant de brancher le fournisseur :

```bash
for p in livez version api; do curl -s -k -o /dev/null -w "/$p %{http_code}\n" https://192.168.49.2:8443/$p; done
```

```sortie
/livez 200
/version 200
/api 403
```

Et les mêmes, après :

```sortie
/livez 200
/version 401
/api 401
```

Avant, l'anonyme était accepté partout, puis l'autorisation décidait : `/version` lui était permis (par la ClusterRole `system:public-info-viewer`), `/api` non, d'où le `403`. Après, l'anonyme n'existe plus que sur les trois chemins de santé ; ailleurs, une requête sans pièce n'est même pas authentifiée (`401`). La différence compte : une erreur dans les règles d'autorisation, un `ClusterRoleBinding` trop généreux pour `system:unauthenticated` par exemple, ne peut plus ouvrir le cluster aux anonymes. Les sondes des équilibreurs de charge, elles, continuent de fonctionner.

### Un greffon dans le kubeconfig

Personne ne colle un jeton à la main dans chaque commande. Le kubeconfig peut confier l'authentification à un **greffon** (*credential plugin*) : un programme que kubectl exécute, et qui lui rend un jeton dans un petit document JSON, un `ExecCredential`[^authn]. C'est le mécanisme qu'utilisent kubelogin pour OIDC[^kubelogin] et les outils des fournisseurs de nuage. Notre greffon, `jeton-exec.sh`, demande un jeton au fournisseur et l'emballe :

```bash title="jeton-exec.sh (extrait)"
JETON=$(python3 fournisseur.py emettre "${COURRIEL:-lea@colis.example}" developpeurs --duree 900)
FIN=$(date -u -d @$(( $(date +%s) + 900 )) +%Y-%m-%dT%H:%M:%SZ)
printf '{"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential","status":{"token":"%s","expirationTimestamp":"%s"}}\n' "$JETON" "$FIN"
```

```bash
kubectl --kubeconfig=lea.kubeconfig config set-cluster cours --server=https://192.168.49.2:8443 --certificate-authority=$HOME/.minikube/ca.crt --embed-certs
kubectl --kubeconfig=lea.kubeconfig config set-credentials lea --exec-api-version=client.authentication.k8s.io/v1 --exec-command=$PWD/idp/jeton-exec.sh --exec-interactive-mode=Never
kubectl --kubeconfig=lea.kubeconfig config set-context lea@cours --cluster=cours --user=lea
kubectl --kubeconfig=lea.kubeconfig config use-context lea@cours
grep -A6 'exec:' lea.kubeconfig
KUBECONFIG=lea.kubeconfig kubectl auth whoami
```

```sortie
Cluster "cours" set.
User "lea" set.
Context "lea@cours" created.
Switched to context "lea@cours".
    exec:
      apiVersion: client.authentication.k8s.io/v1
      args: null
      command: idp/jeton-exec.sh
      env: null
      interactiveMode: Never
      provideClusterInfo: false
ATTRIBUTE   VALUE
Username    oidc:lea@colis.example
Groups      [oidc:developpeurs system:authenticated]
```

kubectl, qui ne vit que le temps d'une commande, appelle le greffon à chaque fois ; un programme qui dure, comme un contrôleur écrit avec la bibliothèque client-go, garde le jeton jusqu'à `expirationTimestamp` et le redemande ensuite. Le kubeconfig de Léa ne contient plus aucun secret : on peut le distribuer à toute l'équipe, chacun s'authentifiera avec ses propres identifiants. Un vrai greffon comme kubelogin ouvrirait à ce moment le navigateur sur la page de connexion de l'entreprise ; c'est le sens de `interactiveMode`.

:::panne[exec: executable jeton-exec.sh not found, alors que le fichier est là]

Regardez la ligne `command` ci-dessus : on a donné un chemin absolu, kubectl l'a réécrit relativement au dossier du kubeconfig (`idp/jeton-exec.sh`). Tant que le kubeconfig et le greffon sont dans des dossiers différents, le chemin garde une barre oblique, et kubectl le résout depuis le dossier du kubeconfig. Mais créez le kubeconfig **dans le dossier du greffon**, même en écrivant `--exec-command=./jeton-exec.sh`, et la ligne devient `command: jeton-exec.sh`, sans dossier :

```sortie
      command: jeton-exec.sh
Unable to connect to the server: getting credentials: exec: executable jeton-exec.sh not found

It looks like you are trying to use a client-go credential plugin that is not installed.
```

Un nom sans barre oblique est cherché dans le `PATH`, comme pour n'importe quelle commande. Corrigez la ligne à la main en `command: ./jeton-exec.sh`, forme que la documentation prévoit explicitement[^authn], ou installez le greffon dans un dossier du `PATH`, ce que font kubelogin et les outils des fournisseurs de nuage.

:::

Avant de passer aux exercices, rendez à l'API server sa configuration d'origine, et arrêtez le fournisseur (son PID est celui qui écoute sur le port 9443) :

```bash
bash brancher-fournisseur.sh --retirer
kill $(ss -ltnpH 'sport = :9443' | grep -o 'pid=[0-9]*' | cut -d= -f2)
```

```sortie
API server remis dans son état d'origine
```

## Exercices

:::exercice[Exercice 1 : un certificat de dix minutes]

Fabriquez avec `nouvel-utilisateur.sh` une utilisatrice `carla`, du groupe `stagiaires`, avec la durée la plus courte permise. Notez ses dates de validité : combien de temps vaut-elle réellement après sa signature, et pourquoi pas cinq minutes de moins comme Alice ? Attendez la fin, et retrouvez dans les journaux de l'API server la raison exacte du refus.

:::

<details>
<summary>Corrigé</summary>

```bash
DUREE=600 NS=ch42 bash nouvel-utilisateur.sh carla stagiaires
openssl x509 -in carla.crt -noout -dates
# une dizaine de minutes plus tard
KUBECONFIG=carla.kubeconfig kubectl auth whoami
kubectl -n kube-system logs kube-apiserver-minikube --since=15s | grep 'Unable to authenticate' | tail -1
```

```sortie
certificatesigningrequest.certificates.k8s.io/carla created
certificatesigningrequest.certificates.k8s.io/carla approved
carla.kubeconfig prêt : subject=O=stagiaires, CN=carla, valable jusqu'au Oct  2 19:44:29 2026 GMT
notBefore=Oct  2 19:29:29 2026 GMT
notAfter=Oct  2 19:44:29 2026 GMT
error: You must be logged in to the server (Unauthorized)
"[x509: certificate has expired or is not yet valid: current time 2026-10-02T19:44:34Z is after 2026-10-02T19:44:29Z, verifying certificate SN=43083946435778201289984736011607215566, SKID=, AKID=A8:89:D0:BC:80:61:41:9E:84:C9:D9:45:6E:A6:D3:F5:85:98:5A:08 failed: x509: certificate has expired or is not yet valid: current time 2026-10-02T19:44:34Z is after 2026-10-02T19:44:29Z]"
```

Le certificat a été signé à 19 h 34 : il commence cinq minutes avant (antidatage) et se termine dix minutes après. Il couvre donc quinze minutes, dont dix utiles. Dix minutes, c'est moins que le seuil de huit heures au-dessous duquel le signataire ne raccourcit pas la fin[^signer]. Le message d'erreur donne l'heure courante, la fin du certificat, son numéro de série et l'identifiant de l'autorité qui l'a signé (`AKID`) : de quoi retrouver de quel certificat il s'agit, même si plusieurs portent le même nom.

</details>

:::exercice[Exercice 2 : qui a le dernier mot ?]

La plupart des Pods n'ont jamais besoin de parler à l'API server, et le jeton monté d'office leur est inutile, voire dangereux. `automountServiceAccountToken: false` se met sur le ServiceAccount ou sur le Pod. Créez un ServiceAccount `discret` qui le désactive, et deux Pods qui l'utilisent, l'un sans rien préciser, l'autre avec `automountServiceAccountToken: true`. Lequel a un jeton ?

:::

<details>
<summary>Corrigé</summary>

Le fichier `discret.yaml` de l'archive contient les trois objets.

```bash
kubectl apply -f discret.yaml
kubectl -n ch42 wait --for=condition=Ready pod/sans-jeton pod/avec-jeton
for p in sans-jeton avec-jeton; do echo "$p : $(kubectl -n ch42 exec $p -- ls /var/run/secrets/kubernetes.io/serviceaccount 2>&1 | tr '\n' ' ')"; done
```

```sortie
serviceaccount/discret created
pod/sans-jeton created
pod/avec-jeton created
pod/sans-jeton condition met
pod/avec-jeton condition met
sans-jeton : ls: /var/run/secrets/kubernetes.io/serviceaccount: No such file or directory command terminated with exit code 1 
avec-jeton : ca.crt namespace token 
```

Le Pod a le dernier mot : le réglage du ServiceAccount sert de valeur par défaut, celui du Pod l'emporte s'il est présent[^sa]. Désactiver le montage sur le ServiceAccount `default` de chaque namespace est une bonne habitude ; l'équipe qui a vraiment besoin de l'API le réactive dans son Pod, en connaissance de cause.

</details>

:::exercice[Exercice 3 : auditer un kubeconfig (programmation)]

Un kubeconfig qu'on vous transmet peut contenir n'importe quoi. Écrivez en Python un script `auditer-kubeconfig.py` qui lit un kubeconfig (par `kubectl config view --raw -o json`, pour ne pas dépendre d'une bibliothèque YAML) et, pour chaque utilisateur, dit de quelle sorte de pièce il s'agit et signale ce qui est risqué :

- certificat client : nom, groupes, temps restant ; alerte s'il est dans `system:masters`, s'il est valable plus de 90 jours au total, s'il est expiré ;
- jeton : s'il s'agit d'un JWT, son sujet et son temps restant ; alerte s'il n'a pas de date d'expiration, ou s'il dure plus d'un jour ;
- greffon : la commande appelée ;
- rien : l'utilisateur sera anonyme.

Essayez-le sur un kubeconfig qui réunit les identités du chapitre : le contexte `minikube`, Alice, Léa et son greffon, un jeton de dix ans et l'ancien jeton de Secret de `robot`. Le module `cryptography`, installé avec PyJWT, lit les certificats.

:::

<details>
<summary>Corrigé</summary>

Le corrigé complet est `corrige/auditer-kubeconfig.py` (une centaine de lignes). L'essentiel est dans les deux fonctions qui examinent un certificat et un jeton :

```python title="corrige/auditer-kubeconfig.py (extrait)"
def certificat(utilisateur):
    if "client-certificate-data" in utilisateur:
        pem = base64.b64decode(utilisateur["client-certificate-data"])
    else:
        pem = open(utilisateur["client-certificate"], "rb").read()
    c = x509.load_pem_x509_certificate(pem)
    nom = ", ".join(a.value for a in c.subject.get_attributes_for_oid(NameOID.COMMON_NAME))
    groupes = [a.value for a in c.subject.get_attributes_for_oid(NameOID.ORGANIZATION_NAME)]
    fin = c.not_valid_after_utc
    alertes = []
    if "system:masters" in groupes:
        alertes.append("membre de system:masters : tous les droits, irrévocable")
    if fin - c.not_valid_before_utc > datetime.timedelta(days=90):
        alertes.append(f"valable {duree(fin - c.not_valid_before_utc)} au total")
    if fin < MAINTENANT:
        alertes.append("expiré")
    detail = f"certificat CN={nom} groupes={groupes or '[]'}, fin dans {duree(fin - MAINTENANT)}"
    return detail, alertes


def jeton(utilisateur):
    brut = utilisateur.get("token") or open(utilisateur["tokenFile"]).read().strip()
    parties = brut.split(".")
    if len(parties) != 3:
        return "jeton opaque (jeton d'amorçage ou fichier de jetons)", ["impossible d'en connaître la durée"]
    charge = json.loads(base64.urlsafe_b64decode(parties[1] + "=" * (-len(parties[1]) % 4)))
    sujet = charge.get("sub", "?")
    if "exp" not in charge:
        return f"jeton JWT {sujet}, sans date d'expiration", ["ancien jeton de Secret : valable tant que le Secret existe"]
    fin = datetime.datetime.fromtimestamp(charge["exp"], datetime.timezone.utc)
    debut = datetime.datetime.fromtimestamp(charge.get("iat", charge["exp"]), datetime.timezone.utc)
    alertes = []
    if fin - debut > UN_JOUR:
        alertes.append(f"jeton longue durée ({duree(fin - debut)})")
    if fin < MAINTENANT:
        alertes.append("expiré")
    return f"jeton JWT {sujet}, fin dans {duree(fin - MAINTENANT)}", alertes
```

On ne vérifie pas la signature du JWT : on veut seulement lire ses dates, et le script doit pouvoir examiner un kubeconfig d'un autre cluster. `kubectl config view --flatten` fusionne plusieurs kubeconfigs en un seul, avec les certificats recopiés dedans :

```bash
kubectl config view --minify --flatten --context=minikube > minikube.kubeconfig
kubectl --kubeconfig=robot-10ans.kubeconfig config set-credentials robot-10ans --token="$(cat jeton-10ans.txt)"
kubectl --kubeconfig=robot-secret.kubeconfig config set-credentials robot-secret --token="$(cat jeton-secret.txt)"
KUBECONFIG=minikube.kubeconfig:alice.kubeconfig:lea.kubeconfig:robot-10ans.kubeconfig:robot-secret.kubeconfig \
  kubectl config view --flatten > equipe.kubeconfig
python3 auditer-kubeconfig.py equipe.kubeconfig
```

```sortie
ok alice      certificat CN=alice groupes=['equipe-colis'], fin dans 23 h
ok lea        greffon idp/jeton-exec.sh
!! minikube   certificat CN=minikube-user groupes=['system:masters'], fin dans 1087 j
     - membre de system:masters : tous les droits, irrévocable
     - valable 1096 j au total
!! robot-10ans jeton JWT system:serviceaccount:ch42:robot, fin dans 3649 j
     - jeton longue durée (3650 j)
!! robot-secret jeton JWT system:serviceaccount:ch42:robot, sans date d'expiration
     - ancien jeton de Secret : valable tant que le Secret existe
```

Sur ce petit échantillon, trois identités sur cinq sont à reprendre, et la plus dangereuse est celle dont vous vous servez tous les jours.

</details>

:::exercice[Exercice 4 : la cinquième porte]

L'option `--enable-bootstrap-token-auth` est active sur minikube. Créez un jeton d'amorçage, en suivant la documentation des *bootstrap tokens*[^boot] : un Secret de type `bootstrap.kubernetes.io/token` dans `kube-system`, nommé `bootstrap-token-<id>`, avec un identifiant de six caractères, un secret de seize, l'usage `usage-bootstrap-authentication`, un groupe supplémentaire et une expiration deux minutes plus tard. Sous quel nom l'API server vous reconnaît-il ? Que se passe-t-il à l'expiration, côté authentification et côté Secret ?

:::

<details>
<summary>Corrigé</summary>

```yaml title="amorce.yaml"
apiVersion: v1
kind: Secret
metadata:
  name: bootstrap-token-cours4
  namespace: kube-system
type: bootstrap.kubernetes.io/token
stringData:
  token-id: cours4
  token-secret: 0123456789abcdef
  usage-bootstrap-authentication: "true"
  auth-extra-groups: system:bootstrappers:cours
  expiration: "2026-10-02T19:40:06Z"   # deux minutes plus tard
```

Le jeton est la concaténation `<id>.<secret>` :

```bash
kubectl apply -f amorce.yaml
kubectl --kubeconfig=/dev/null --server=https://192.168.49.2:8443 --certificate-authority=$HOME/.minikube/ca.crt --token=cours4.0123456789abcdef auth whoami
kubectl --kubeconfig=/dev/null --server=https://192.168.49.2:8443 --certificate-authority=$HOME/.minikube/ca.crt --token=cours4.0123456789abcdef get pods -n ch42
# après l'heure d'expiration
date -u +%T
kubectl --kubeconfig=/dev/null --server=https://192.168.49.2:8443 --certificate-authority=$HOME/.minikube/ca.crt --token=cours4.0123456789abcdef auth whoami
until ! kubectl -n kube-system get secret bootstrap-token-cours4 >/dev/null 2>&1; do sleep 2; done; echo "Secret supprimé à $(date -u +%T)"
```

```sortie
secret/bootstrap-token-cours4 created
ATTRIBUTE   VALUE
Username    system:bootstrap:cours4
Groups      [system:bootstrappers system:bootstrappers:cours system:authenticated]
Error from server (Forbidden): pods is forbidden: User "system:bootstrap:cours4" cannot list resource "pods" in API group "" in the namespace "ch42"
19:40:08
error: You must be logged in to the server (Unauthorized)
Secret supprimé à 19:40:08
```

Le nom est `system:bootstrap:<id>`, dans le groupe `system:bootstrappers` et dans ceux qu'on a ajoutés, qui doivent commencer par `system:bootstrappers:`. Le jeton n'est pas un JWT : c'est un secret partagé, que l'API server compare à celui du Secret. Dès l'heure d'expiration, il est refusé, et le contrôleur `tokencleaner`, que minikube active dans le gestionnaire de contrôleurs (`--controllers=*,bootstrapsigner,tokencleaner`), supprime le Secret. Ces jetons servent à un nouveau nœud qui rejoint le cluster (`kubeadm join`) : avec lui, le kubelet dépose une CSR pour obtenir son propre certificat, puis oublie le jeton. Quiconque peut créer des Secrets dans `kube-system` peut donc se fabriquer une identité ; c'est une raison de plus de surveiller qui a ce droit.

</details>

## Nettoyer

Le script de rejeu remet l'API server dans son état d'origine en sortant, même s'il échoue. Si vous avez fait les manipulations à la main, vérifiez qu'il ne reste pas l'option `--authentication-config` :

```bash
kubectl -n kube-system get pod kube-apiserver-minikube -o json | jq -r '.spec.containers[0].command[]' | grep authentication-config \
  && bash brancher-fournisseur.sh --retirer
kill $(ss -ltnpH 'sport = :9443' | grep -o 'pid=[0-9]*' | cut -d= -f2) 2>/dev/null
kubectl delete namespace ch42
for c in alice carla bob-60; do kubectl delete csr $c --ignore-not-found; done
kubectl -n kube-system delete secret bootstrap-token-cours4 --ignore-not-found
```

Les kubeconfigs et les clés privées que vous avez fabriqués restent dans votre dossier de travail. Les certificats de Bruno, d'Alice et de Carla ne peuvent pas être révoqués, vous le savez maintenant ; supprimez au moins leurs clés (`rm *.key *.kubeconfig`), et celles du fournisseur (`idp.key`, `idp-ca.key`, `https.key`). Celui de Bruno vaudra encore un an.

[^authn]: Kubernetes, « Authenticating » : stratégies d'authentification, utilisateurs normaux absents de l'API, anonyme, configuration structurée (`AuthenticationConfiguration`, stable depuis 1.34, rechargement automatique et métriques, vérification d'office de `email_verified`), configuration de l'anonyme (stable depuis 1.34), greffons d'authentification et chemins relatifs, `SelfSubjectReview`. [kubernetes.io/docs/reference/access-authn-authz/authentication](https://kubernetes.io/docs/reference/access-authn-authz/authentication/)
[^flags]: Kubernetes, « kube-apiserver », référence des options : `--client-ca-file`, `--anonymous-auth`, `--service-account-extend-token-expiration` (« admission injected tokens would be extended up to 1 year »), `--service-account-max-token-expiration`. Aucune option ne concerne la révocation des certificats. [kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/)
[^csr]: Kubernetes, « Certificates and Certificate Signing Requests » : signataires intégrés (`kube-apiserver-client` n'est jamais approuvé automatiquement), `expirationSeconds` (minimum 600), durée bornée par `--cluster-signing-duration` (un an par défaut). [kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests](https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/)
[^signer]: Code source de Kubernetes, `pkg/controller/certificates/authority/policies.go` (antidatage du début, fin non raccourcie pour les certificats courts) et `pkg/controller/certificates/signer/signer.go` (antidatage de 5 minutes, seuil de 8 heures, minimum de 10 minutes). [github.com/kubernetes/kubernetes/blob/master/pkg/controller/certificates/authority/policies.go](https://github.com/kubernetes/kubernetes/blob/master/pkg/controller/certificates/authority/policies.go), [github.com/kubernetes/kubernetes/blob/master/pkg/controller/certificates/signer/signer.go](https://github.com/kubernetes/kubernetes/blob/master/pkg/controller/certificates/signer/signer.go)
[^adm]: Kubernetes, « Admission Control in Kubernetes », section *CertificateSubjectRestriction*. [kubernetes.io/docs/reference/access-authn-authz/admission-controllers](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#certificatesubjectrestriction)
[^jwt]: M. Jones, J. Bradley, N. Sakimura, « JSON Web Token (JWT) », RFC 7519, IETF, 2015 ; pour le format des clés, M. Jones, « JSON Web Key (JWK) », RFC 7517. [rfc-editor.org/rfc/rfc7519](https://www.rfc-editor.org/rfc/rfc7519), [rfc-editor.org/rfc/rfc7517](https://www.rfc-editor.org/rfc/rfc7517)
[^sa]: Kubernetes, « Configure Service Accounts for Pods » : désactiver le montage, projection de jetons avec audience et durée, renouvellement par le kubelet (« older than 80% of its total time-to-live (TTL), or if the token is older than 24 hours »), découverte de l'émetteur. [kubernetes.io/docs/tasks/configure-pod-container/configure-service-account](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/)
[^saadmin]: Kubernetes, « Managing Service Accounts » : jetons liés, API TokenRequest, nettoyage des anciens jetons générés automatiquement (étiquettes `legacy-token-last-used` et `legacy-token-invalid-since`, un an par défaut). [kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin](https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/)
[^oidc]: OpenID Foundation, « OpenID Connect Discovery 1.0 », pour le document `/.well-known/openid-configuration` et `jwks_uri`. [openid.net/specs/openid-connect-discovery-1_0.html](https://openid.net/specs/openid-connect-discovery-1_0.html)
[^kid]: Code source de Kubernetes, `pkg/serviceaccount/jwt.go`, fonction `keyIDFromPublicKey` : SHA-256 de la clé publique au format DER, encodé en base64 pour les URL sans rembourrage. [github.com/kubernetes/kubernetes/blob/master/pkg/serviceaccount/jwt.go](https://github.com/kubernetes/kubernetes/blob/master/pkg/serviceaccount/jwt.go)
[^cache]: Code source de Kubernetes, `pkg/kubeapiserver/options/authentication.go` (`TokenSuccessCacheTTL: 10 * time.Second`, `TokenFailureCacheTTL: 0`) et `pkg/kubeapiserver/authenticator/config.go` (cache placé devant les authentificateurs par jeton). [github.com/kubernetes/kubernetes/blob/master/pkg/kubeapiserver/options/authentication.go](https://github.com/kubernetes/kubernetes/blob/master/pkg/kubeapiserver/options/authentication.go)
[^kubelogin]: int128, « kubelogin », greffon kubectl pour l'authentification OpenID Connect. [github.com/int128/kubelogin](https://github.com/int128/kubelogin)
[^boot]: Kubernetes, « Authenticating with Bootstrap Tokens » : format du Secret, nom d'utilisateur `system:bootstrap:<id>`, groupes, contrôleur `tokencleaner`. [kubernetes.io/docs/reference/access-authn-authz/bootstrap-tokens](https://kubernetes.io/docs/reference/access-authn-authz/bootstrap-tokens/)
