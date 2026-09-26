---
title: Configurer une application
sidebar_label: 21. Configurer une application
description: "Séparer la configuration de l'image : ConfigMap et Secret, en variables d'environnement ou en fichiers ; ce qui se met à jour tout seul et ce qui ne bouge pas ; l'API descendante ; ce qu'un Secret protège vraiment."
partie: 3
chapitre: '21'
---

import configmapConso from '@site/src/figures/configmap-conso.svg';
import secretVisible from '@site/src/figures/secret-visible.svg';

La même image de l'API Colis doit tourner sur le poste d'un développeur, dans un environnement de test et en production. Seules changent quelques valeurs : l'adresse de la base de données, son mot de passe, le niveau de détail des journaux. Construire une image par environnement serait absurde : on testerait une image et on en livrerait une autre. La règle, formulée depuis longtemps sous le nom de *twelve-factor app*, est de garder la configuration hors du code, dans l'environnement où il s'exécute[^twelve]. Le chapitre 4 l'a appliquée avec Docker : Colis lit `COLIS_DB` et `COLIS_REDIS` dans ses variables d'environnement.

Kubernetes fournit deux objets pour porter cette configuration : la **ConfigMap** pour les valeurs ordinaires, le **Secret** pour les valeurs sensibles. Ce chapitre les injecte dans des Pods de toutes les façons possibles, mesure ce qui se passe quand on les modifie, et regarde de près ce qu'un Secret protège, et ce qu'il ne protège pas.

Les manifestes sont dans [l'archive config](pathname:///kits/config.tar.gz).

```bash
kubectl create namespace ch21
kubectl config set-context --current --namespace=ch21
```

## La ConfigMap

Une ConfigMap est un dictionnaire de chaînes de caractères, rangé dans l'API comme n'importe quel objet[^configmap]. `kubectl create configmap` en fabrique à partir de valeurs, d'un fichier au format `CLÉ=valeur`, ou de fichiers entiers :

```bash
kubectl create configmap essai --from-literal=COULEUR=bleu --from-literal=TAILLE=12 --dry-run=client -o yaml
printf 'COULEUR=vert\nTAILLE=14\n' > reglages.env
kubectl create configmap essai-env --from-env-file=reglages.env --dry-run=client -o yaml
kubectl create configmap essai-fichier --from-file=reglages.env --dry-run=client -o yaml
```

```sortie
apiVersion: v1
data:
  COULEUR: bleu
  TAILLE: "12"
kind: ConfigMap
metadata:
  name: essai
...
data:
  COULEUR: vert
  TAILLE: "14"
...
data:
  reglages.env: |
    COULEUR=vert
    TAILLE=14
```

Les trois formes donnent la même structure, `data`, où tout est texte : `TAILLE: "12"` entre guillemets, pour la raison vue au chapitre 18. Avec `--from-env-file`, chaque ligne devient une clé ; avec `--from-file`, le fichier entier devient la valeur d'une clé qui porte son nom. Une ConfigMap ne peut pas dépasser 1 Mio : c'est fait pour de la configuration, pas pour des données.

Voici celle du chapitre. Elle mélange des valeurs courtes et un fichier HTML complet :

```yaml title="configmap.yaml"
apiVersion: v1
kind: ConfigMap
metadata:
  name: vitrine-config
data:
  MESSAGE: "Bienvenue sur Colis"
  NIVEAU_LOG: "info"
  index.html: |
    <!doctype html>
    <html lang="fr"><body><h1>Colis</h1><p>Suivi de vos envois.</p></body></html>
```

Le `|` du YAML introduit un texte sur plusieurs lignes, qui garde ses sauts de ligne.

## En variables d'environnement

Un conteneur peut recevoir toutes les clés d'une ConfigMap en variables d'environnement avec `envFrom`, et monter certaines clés comme fichiers. Ce Deployment fait les deux :

```yaml title="vitrine.yaml"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vitrine
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vitrine
  template:
    metadata:
      labels:
        app: vitrine
    spec:
      containers:
      - name: nginx
        image: nginx:1.30-alpine
        envFrom:
        - configMapRef:
            name: vitrine-config
        volumeMounts:
        - name: site
          mountPath: /usr/share/nginx/html
      volumes:
      - name: site
        configMap:
          name: vitrine-config
          items:
          - key: index.html
            path: index.html
```

```bash
kubectl apply -f configmap.yaml -f vitrine.yaml
kubectl rollout status deployment/vitrine
P=$(kubectl get pods -l app=vitrine -o name)
kubectl exec $P -- sh -c 'echo MESSAGE=$MESSAGE; echo NIVEAU_LOG=$NIVEAU_LOG; env | grep -A1 ^index'
kubectl exec $P -- wget -q -O - http://localhost/
```

```sortie
MESSAGE=Bienvenue sur Colis
NIVEAU_LOG=info
index.html=<!doctype html>
<html lang="fr"><body><h1>Colis</h1><p>Suivi de vos envois.</p></body></html>
<!doctype html>
<html lang="fr"><body><h1>Colis</h1><p>Suivi de vos envois.</p></body></html>
```

nginx sert la page tirée de la ConfigMap. Et `envFrom` a créé une variable pour **chaque** clé, y compris `index.html`, avec tout le fichier pour valeur. Longtemps, Kubernetes ignorait les clés dont le nom n'était pas un nom de variable valide pour un shell ; il accepte désormais presque tous les caractères imprimables[^env-noms]. D'où une règle simple : `envFrom` sur une ConfigMap faite pour cela, et `env` avec des clés choisies une à une quand la ConfigMap sert aussi à autre chose.

La forme détaillée, `env` avec `valueFrom`, choisit une clé et lui donne le nom qu'on veut. Le Pod `lecteur` s'en sert, et en profite pour montrer une autre source de valeurs, l'**API descendante** (*downward API*), qui expose au conteneur des informations sur son propre Pod[^downward] :

```yaml title="lecteur.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: lecteur
spec:
  containers:
  - name: lecteur
    image: busybox:1.37
    command: ["sh", "-c", "while true; do echo \"$(date +%T) env=$MESSAGE fichier=$(cat /config/MESSAGE) subpath=$(cat /etc/message)\"; sleep 2; done"]
    env:
    - name: MESSAGE
      valueFrom:
        configMapKeyRef:
          name: vitrine-config
          key: MESSAGE
    - name: NOM_DU_POD
      valueFrom:
        fieldRef:
          fieldPath: metadata.name
    - name: MEMOIRE_MAX
      valueFrom:
        resourceFieldRef:
          resource: limits.memory
    resources:
      limits:
        memory: 64Mi
    volumeMounts:
    - name: config
      mountPath: /config
    - name: config
      mountPath: /etc/message
      subPath: MESSAGE
  volumes:
  - name: config
    configMap:
      name: vitrine-config
```

Le même message y arrive par trois chemins : une variable d'environnement, un fichier dans un volume monté sur `/config`, et un fichier monté seul à `/etc/message` grâce à `subPath`. Le programme les affiche toutes les deux secondes.

```bash
kubectl apply -f lecteur.yaml
kubectl wait --for=condition=Ready pod/lecteur
kubectl logs lecteur | tail -1
kubectl exec lecteur -- sh -c 'echo NOM_DU_POD=$NOM_DU_POD; echo MEMOIRE_MAX=$MEMOIRE_MAX'
```

```sortie
05:55:29 env=Bienvenue sur Colis fichier=Bienvenue sur Colis subpath=Bienvenue sur Colis
NOM_DU_POD=lecteur
MEMOIRE_MAX=67108864
```

Les trois chemins donnent la même valeur. `NOM_DU_POD` vient de `metadata.name`, et `MEMOIRE_MAX` de la limite de mémoire du conteneur, en octets (64 Mio). Une application peut ainsi dimensionner ses caches d'après sa propre limite, sans qu'on répète la valeur à deux endroits.

## En fichiers

Regardons comment le volume est construit :

```bash
kubectl exec lecteur -- ls -la /config /config/..data/
```

```sortie
/config:
total 12
drwxrwxrwx    3 root     root          4096 Sep 26 05:55 .
drwxr-xr-x    1 root     root          4096 Sep 26 05:55 ..
drwxr-xr-x    2 root     root          4096 Sep 26 05:55 ..2026_09_26_05_55_26.831967000
lrwxrwxrwx    1 root     root            31 Sep 26 05:55 ..data -> ..2026_09_26_05_55_26.831967000
lrwxrwxrwx    1 root     root            14 Sep 26 05:55 MESSAGE -> ..data/MESSAGE
lrwxrwxrwx    1 root     root            17 Sep 26 05:55 NIVEAU_LOG -> ..data/NIVEAU_LOG
lrwxrwxrwx    1 root     root            17 Sep 26 05:55 index.html -> ..data/index.html

/config/..data/:
total 20
drwxr-xr-x    2 root     root          4096 Sep 26 05:55 .
drwxrwxrwx    3 root     root          4096 Sep 26 05:55 ..
-rw-r--r--    1 root     root            19 Sep 26 05:55 MESSAGE
-rw-r--r--    1 root     root             4 Sep 26 05:55 NIVEAU_LOG
-rw-r--r--    1 root     root            94 Sep 26 05:55 index.html
```

Chaque clé est un lien symbolique vers `..data/<clé>`, et `..data` est lui-même un lien vers un dossier daté. Ce montage à double détente sert aux mises à jour : quand la ConfigMap change, le kubelet écrit tous les fichiers dans un **nouveau** dossier daté, puis fait pointer `..data` vers lui, d'un seul coup. Un programme qui lit plusieurs fichiers ne peut donc jamais voir un mélange d'ancienne et de nouvelle configuration.

## Modifier une ConfigMap

Changeons le message, et relevons au bout de combien de temps le Pod le voit :

```bash
kubectl patch configmap vitrine-config --type=merge -p '{"data":{"MESSAGE":"Nouvelle version"}}'
t0=$(date +%s)
until kubectl exec lecteur -- cat /config/MESSAGE | grep -q Nouvelle; do sleep 2; done
echo "fichier mis à jour après $(( $(date +%s)-t0 )) s"
kubectl logs lecteur | tail -1
```

```sortie
configmap/vitrine-config patched
fichier mis à jour après 63 s
05:56:35 env=Bienvenue sur Colis fichier=Nouvelle version subpath=Bienvenue sur Colis
```

Trois comportements différents, pour une même modification :

- le **fichier du volume** a changé, au bout de 63 secondes (77 lors d'un premier essai). Le kubelet ne surveille pas les ConfigMaps en continu : il les relit lors de sa synchronisation périodique des Pods (toutes les minutes par défaut), et s'appuie sur un cache. Le délai total peut atteindre la période de synchronisation plus celle du cache, soit une à deux minutes[^configmap] ;
- la **variable d'environnement** n'a pas changé, et ne changera jamais : l'environnement d'un processus est fixé à son démarrage, par le système d'exploitation lui-même ;
- le **fichier monté avec `subPath`** n'a pas changé non plus : un montage `subPath` est un montage direct du fichier, qui ne passe pas par les liens `..data`, et le kubelet ne le met jamais à jour.

Seul un nouveau Pod voit tout à jour :

```bash
kubectl delete pod lecteur
kubectl apply -f lecteur.yaml
kubectl wait --for=condition=Ready pod/lecteur
kubectl logs lecteur | tail -1
```

```sortie
05:57:11 env=Nouvelle version fichier=Nouvelle version subpath=Nouvelle version
```

Pour un Deployment, c'est `kubectl rollout restart` du chapitre 19 qui remplace tous les Pods, un par un, sans interruption.

<Figure svg={configmapConso} num="21.1" alt="La ConfigMap vitrine-config, dont MESSAGE passe de Bienvenue sur Colis à Nouvelle version, est lue de trois façons. En variable d'environnement (env, envFrom), lue au démarrage du conteneur : $MESSAGE ne change jamais. En volume, /config/MESSAGE, lien vers ..data remplacé d'un coup : à jour après 63 à 77 secondes. En volume avec subPath, /etc/message, copie figée au démarrage : ne change jamais. Pour les deux cas figés, seul un nouveau Pod (rollout restart) voit tout à jour.">
Trois façons de lire une ConfigMap, et ce que voit un Pod en cours d'exécution après une modification. Délais mesurés sur le cluster du cours.
</Figure>

Et même un fichier à jour ne suffit pas toujours. La page de `vitrine` est lue par nginx à chaque requête, donc la modification finit par apparaître :

```bash
kubectl patch configmap vitrine-config --type=merge -p '{"data":{"index.html":"<h1>Colis v2</h1>\n"}}'
P=$(kubectl get pods -l app=vitrine -o name)
for i in $(seq 1 40); do
  r=$(kubectl exec $P -- wget -q -O - http://localhost/ | head -1)
  case $r in *v2*) echo "page mise à jour après environ $((i*3)) s : $r"; break;; esac
  sleep 3
done
```

```sortie
configmap/vitrine-config patched
page mise à jour après environ 30 s : <h1>Colis v2</h1>
```

Mais un programme qui lit sa configuration **une fois**, au démarrage, comme nginx lit ses fichiers `.conf`, ne verra rien tant qu'on ne lui demande pas de la relire (exercice 2). Les options sont alors de lui envoyer un signal de rechargement, d'ajouter un sidecar qui surveille le fichier et le fait pour lui, ou, le plus simple et le plus sûr, de relancer les Pods. La partie IV montrera comment Helm automatise ce dernier point, en ajoutant au modèle de Pod une empreinte de la configuration, qui change quand elle change.

:::panne[CreateContainerConfigError et ContainerCreating]

Une ConfigMap ou une clé absente ne fait pas planter le conteneur : elle l'empêche de démarrer, avec deux symptômes différents selon la façon dont elle est utilisée.

```sortie
NAME          READY   STATUS                       RESTARTS   AGE
cle-absente   0/1     CreateContainerConfigError   0          6s
Error: couldn't find key INEXISTANTE in ConfigMap ch21/vitrine-config

NAME         READY   STATUS              RESTARTS   AGE
cm-absente   0/1     ContainerCreating   0          8s
MountVolume.SetUp failed for volume "c" : configmap "nexiste-pas" not found
```

Une référence dans `env` (clé ou ConfigMap absente) donne `CreateContainerConfigError`, avec la cause dans les événements. Un volume qui pointe vers une ConfigMap absente laisse le Pod en `ContainerCreating`, et l'événement `FailedMount` explique pourquoi. Dans les deux cas, créer l'objet manquant débloque le Pod, sans rien relancer. Si une valeur est facultative, `optional: true` sur la référence laisse démarrer le conteneur sans elle (exercice 3).

:::

Une ConfigMap peut enfin être déclarée **immuable** (`immutable: true`). Toute modification est alors refusée :

```sortie
The ConfigMap "figee" is invalid: data: Forbidden: field is immutable when `immutable` is set
```

On change de configuration en créant une ConfigMap sous un autre nom (`vitrine-config-v2`), puis en mettant à jour le Deployment pour qu'il l'utilise, ce qui déclenche une mise à jour progressive et permet un retour arrière. Le kubelet n'a plus besoin de surveiller une ConfigMap immuable, ce qui soulage l'API server dans les gros clusters.

## Le Secret

Un **Secret** ressemble à une ConfigMap, avec quelques précautions en plus pour les données sensibles : mots de passe, jetons, clés privées[^secret]. Voici les identifiants de la base de Colis :

```yaml title="secret-db.yaml"
apiVersion: v1
kind: Secret
metadata:
  name: colis-db
type: Opaque
stringData:
  POSTGRES_USER: colis
  POSTGRES_PASSWORD: change-moi-en-production
```

`type: Opaque` désigne un Secret générique. `stringData` accepte des valeurs en clair, pour la commodité de celui qui écrit le fichier ; l'API server les range dans le champ `data`, encodées en base64 :

```bash
kubectl apply -f secret-db.yaml
kubectl get secret colis-db
kubectl get secret colis-db -o yaml
kubectl get secret colis-db -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d; echo
```

```sortie
secret/colis-db created
NAME       TYPE     DATA   AGE
colis-db   Opaque   2      0s
data:
  POSTGRES_PASSWORD: Y2hhbmdlLW1vaS1lbi1wcm9kdWN0aW9u
  POSTGRES_USER: Y29saXM=
...
change-moi-en-production
```

Le **base64 n'est pas un chiffrement** : c'est un codage, qui permet de ranger des données binaires (une clé privée, un certificat) dans du texte, et que `base64 -d` défait sans aucune clé. N'importe qui ayant le droit de lire le Secret lit le mot de passe. La protection d'un Secret ne vient pas de son format, mais du fait que Kubernetes le traite à part : les droits d'accès (RBAC, chapitre 43) distinguent les Secrets des autres objets, et le kubelet ne les écrit jamais sur le disque du nœud.

Un Secret s'utilise comme une ConfigMap, avec `secretKeyRef` ou un volume de type `secret` :

```yaml title="utilise-secret.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: utilise-secret
spec:
  containers:
  - name: app
    image: busybox:1.37
    command: ["sleep", "3600"]
    env:
    - name: POSTGRES_PASSWORD
      valueFrom:
        secretKeyRef:
          name: colis-db
          key: POSTGRES_PASSWORD
    volumeMounts:
    - name: identifiants
      mountPath: /run/secrets/colis-db
      readOnly: true
  volumes:
  - name: identifiants
    secret:
      secretName: colis-db
      defaultMode: 0400
```

```bash
kubectl apply -f utilise-secret.yaml
kubectl wait --for=condition=Ready pod/utilise-secret
kubectl exec utilise-secret -- sh -c 'echo $POSTGRES_PASSWORD; ls -laL /run/secrets/colis-db/; mount | grep colis-db'
```

```sortie
change-moi-en-production
total 12
drwxrwxrwt    3 root     root           120 Sep 26 05:57 .
drwxr-xr-x    3 root     root          4096 Sep 26 05:57 ..
drwxr-xr-x    2 root     root            80 Sep 26 05:57 ..2026_09_26_05_57_58.3283531451
drwxr-xr-x    2 root     root            80 Sep 26 05:57 ..data
-r--------    1 root     root            24 Sep 26 05:57 POSTGRES_PASSWORD
-r--------    1 root     root             5 Sep 26 05:57 POSTGRES_USER
tmpfs on /run/secrets/colis-db type tmpfs (ro,relatime,size=15778000k,inode64,noswap)
```

Le volume d'un Secret est un **tmpfs**, un système de fichiers en mémoire : le mot de passe ne touche jamais le disque du nœud. `defaultMode: 0400` rend les fichiers lisibles par leur seul propriétaire. Des deux façons, le fichier est la meilleure. Une variable d'environnement est héritée par tous les processus enfants, s'affiche dans les journaux d'erreur de certains programmes, et ne se met jamais à jour ; un fichier, lui, suit les modifications du Secret, comme celui d'une ConfigMap. Beaucoup d'images officielles acceptent d'ailleurs les deux : l'image PostgreSQL lit `POSTGRES_PASSWORD`, ou `POSTGRES_PASSWORD_FILE` qui désigne un fichier.

### Ce que Kubernetes ne protège pas

Deux constats, sur le cluster du cours, sont moins rassurants. Le premier concerne `kubectl apply`, qui garde une copie du fichier appliqué dans l'annotation `last-applied-configuration` (chapitre 18) :

```bash
kubectl get secret colis-db -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}'
```

```sortie
{"apiVersion":"v1","kind":"Secret","metadata":{"annotations":{},"name":"colis-db","namespace":"ch21"},"stringData":{"POSTGRES_PASSWORD":"change-moi-en-production","POSTGRES_USER":"colis"},"type":"Opaque"}
```

Le mot de passe est dans une annotation, en clair, lisible par quiconque peut lire les métadonnées de l'objet. Pour un Secret, préférez `kubectl create secret` ou `kubectl apply --server-side`, qui ne créent pas cette annotation. Le second concerne etcd, où l'API server range les objets :

```bash
kubectl exec -n kube-system etcd-minikube -- etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/var/lib/minikube/certs/etcd/ca.crt --cert=/var/lib/minikube/certs/etcd/server.crt \
  --key=/var/lib/minikube/certs/etcd/server.key \
  get /registry/secrets/ch21/colis-db --print-value-only | strings -n 5 | tail -6
```

```sortie
{"f:data":{".":{},"f:POSTGRES_PASSWORD":{},"f:POSTGRES_USER":{}},"f:metadata":{"f:annotations":{".":{},"f:kubectl.kubernetes.io/last-applied-configuration":{}}},"f:type":{}}B
POSTGRES_PASSWORD
change-moi-en-production
POSTGRES_USER
colis
Opaque
```

Par défaut, les Secrets sont stockés dans etcd **sans chiffrement**. Qui accède aux fichiers d'etcd, ou à une de ses sauvegardes, lit tous les mots de passe du cluster. L'API server sait chiffrer les Secrets avant de les écrire ; il faut l'activer, et le chapitre 46 le fera, avec les outils qui permettent aussi de ranger des Secrets chiffrés dans Git.

<Figure svg={secretVisible} num="21.2" alt="Six endroits où se trouve le mot de passe du Secret colis-db. kubectl get secret -o yaml : en base64, qu'un simple base64 -d décode. L'annotation last-applied-configuration écrite par kubectl apply : le stringData en clair. etcd : stocké tel quel, sans chiffrement, voir chapitre 46. Dans le Pod en variable : visible par tout processus du conteneur. Dans le Pod en fichier : tmpfs en mémoire, mode 0400, la meilleure option. Le manifeste secret-db.yaml dans Git : à ne jamais faire, chiffrer au chapitre 46.">
Où le mot de passe du Secret <code>colis-db</code> est lisible, sur un cluster sans réglage particulier. En rouge, les endroits où il est en clair.
</Figure>

Kubernetes connaît aussi des types de Secrets spécialisés, qui imposent une structure. Le plus courant, `kubernetes.io/dockerconfigjson`, contient les identifiants d'un registre privé, que le kubelet utilise pour télécharger des images :

```bash
kubectl create secret docker-registry registre-prive --docker-server=registre.example \
  --docker-username=colis --docker-password=secret123 --dry-run=client -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d; echo
```

```sortie
{"auths":{"registre.example":{"username":"colis","password":"secret123","auth":"Y29saXM6c2VjcmV0MTIz"}}}
```

C'est exactement le contenu du fichier `~/.docker/config.json` que `docker login` écrit (chapitre 3). Un Pod s'en sert par le champ `imagePullSecrets`. Le type `kubernetes.io/tls`, avec les clés `tls.crt` et `tls.key`, servira aux certificats du chapitre 28.

## Exercices

:::exercice[Exercice 1 : une ConfigMap par dossier]

Créez un dossier `reglages` contenant deux fichiers, `niveau` (qui contient `info`) et `delai` (qui contient `30`). Créez une ConfigMap à partir du dossier entier. Quelles clés contient-elle ? Comment la monter pour que le programme retrouve exactement le même dossier ?

:::

<details>
<summary>Corrigé</summary>

```bash
mkdir reglages; printf 'info\n' > reglages/niveau; printf '30\n' > reglages/delai
kubectl create configmap depuis-dossier --from-file=reglages/
kubectl get configmap depuis-dossier -o jsonpath='{.data}'; echo
```

```sortie
configmap/depuis-dossier created
{"delai":"30\n","niveau":"info\n"}
```

Une clé par fichier, avec le contenu exact, saut de ligne final compris. Monté comme volume sans `items`, par exemple sur `/etc/colis/reglages`, il redonne un fichier par clé : `/etc/colis/reglages/niveau` et `/etc/colis/reglages/delai`. Les sous-dossiers, en revanche, ne sont pas repris : une ConfigMap est plate.

</details>

:::exercice[Exercice 2 : une configuration nginx]

Écrivez une ConfigMap `nginx-conf` avec une clé `default.conf` qui configure nginx pour répondre `ok` sur `/sante`, et un Pod nginx qui la monte sur `/etc/nginx/conf.d`. Vérifiez depuis le Pod avec `wget -q -O - http://localhost/sante`. Puis ajoutez une ligne à la configuration et appliquez : combien de temps faut-il pour que nginx l'applique ?

:::

<details>
<summary>Corrigé</summary>

```yaml title="nginx-sante.yaml"
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-conf
data:
  default.conf: |
    server {
      listen 80;
      location = /sante {
        default_type text/plain;
        return 200 "ok\n";
      }
      location / {
        root /usr/share/nginx/html;
      }
    }
---
apiVersion: v1
kind: Pod
metadata:
  name: nginx-sante
spec:
  containers:
  - name: nginx
    image: nginx:1.30-alpine
    volumeMounts:
    - name: conf
      mountPath: /etc/nginx/conf.d
  volumes:
  - name: conf
    configMap:
      name: nginx-conf
```

```bash
kubectl apply -f nginx-sante.yaml
kubectl exec nginx-sante -- wget -q -O - http://localhost/sante
kubectl exec nginx-sante -- wget -q -O - http://127.0.0.1/sante
kubectl exec nginx-sante -- getent hosts localhost
```

```sortie
wget: can't connect to remote host: Connection refused
command terminated with exit code 1
ok
::1               localhost  localhost
```

Premier piège, bien réel : dans Alpine, `localhost` désigne d'abord l'adresse IPv6 `::1`, et ce `server` n'écoute qu'en IPv4. La configuration d'origine de l'image écoute sur les deux, grâce à un script de démarrage qui ajoute `listen [::]:80;` à son `default.conf`, mais ce script ne touche pas un fichier fourni par une ConfigMap. Ajoutons la ligne, et appliquons :

```bash
sed -i 's/      listen 80;/      listen 80;\n      listen [::]:80;/' nginx-sante.yaml
kubectl apply -f nginx-sante.yaml
sleep 70
kubectl exec nginx-sante -- grep listen /etc/nginx/conf.d/default.conf
kubectl exec nginx-sante -- wget -q -O - http://localhost/sante
kubectl exec nginx-sante -- nginx -s reload
kubectl exec nginx-sante -- wget -q -O - http://localhost/sante
```

```sortie
  listen 80;
  listen [::]:80;
wget: can't connect to remote host: Connection refused
command terminated with exit code 1
2026/09/26 06:00:44 [notice] 79#79: signal process started
ok
```

Second piège : au bout de 70 secondes, le fichier contient bien la nouvelle ligne, mais nginx ne l'applique pas, car il ne relit sa configuration qu'au démarrage ou sur ordre. `nginx -s reload` le lui demande. Dans un Deployment, `kubectl rollout restart` est plus simple et plus sûr : les nouveaux Pods démarrent avec la configuration à jour, et une configuration invalide bloque la mise à jour au lieu de casser des Pods qui fonctionnaient.

</details>

:::exercice[Exercice 3 : une valeur facultative]

Un programme accepte une variable `X` facultative. Écrivez un Pod qui la lit dans la clé `INEXISTANTE` de `vitrine-config` sans bloquer le démarrage si elle n'existe pas. Que vaut `X` dans le conteneur ?

:::

<details>
<summary>Corrigé</summary>

```yaml
    env:
    - name: X
      valueFrom:
        configMapKeyRef:
          name: vitrine-config
          key: INEXISTANTE
          optional: true
```

Avec cette référence, le Pod démarre (`Running`), et le programme affiche `X=[]` : la variable n'est pas définie du tout, ce qui n'est pas tout à fait la même chose qu'une variable vide (`${X-défaut}` en shell fait la différence). Sans `optional: true`, le même Pod reste en `CreateContainerConfigError`, comme dans la section des pannes. À utiliser avec discernement : une valeur obligatoire déclarée facultative remplace une erreur claire au démarrage par un comportement étrange plus tard.

</details>

## Nettoyer

```bash
kubectl delete namespace ch21
kubectl config set-context --current --namespace=default
```

[^twelve]: Adam Wiggins, « The Twelve-Factor App », section III, *Config*. [12factor.net/config](https://12factor.net/config)

[^configmap]: Kubernetes, « ConfigMaps », sections *ConfigMaps and Pods*, *Mounted ConfigMaps are updated automatically* et *Immutable ConfigMaps*. [kubernetes.io/docs/concepts/configuration/configmap](https://kubernetes.io/docs/concepts/configuration/configmap/)

[^env-noms]: Kubernetes Enhancement Proposal 4369, « Allow almost all printable ASCII characters in environment variables ». [github.com/kubernetes/enhancements/issues/4369](https://github.com/kubernetes/enhancements/issues/4369)

[^downward]: Kubernetes, « Downward API ». [kubernetes.io/docs/concepts/workloads/pods/downward-api](https://kubernetes.io/docs/concepts/workloads/pods/downward-api/)

[^secret]: Kubernetes, « Secrets », sections *Uses for Secrets*, *Types of Secret* et *Information security for Secrets*, et « Good practices for Kubernetes Secrets ». [kubernetes.io/docs/concepts/configuration/secret](https://kubernetes.io/docs/concepts/configuration/secret/)
