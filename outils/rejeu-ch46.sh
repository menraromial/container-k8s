#!/usr/bin/env bash
# Rejeu du chapitre 46 (les secrets pour de vrai) sur le profil minikube principal. Sorties dans outils/out/ch46r.
# La remise à zéro déchiffre d'abord tous les Secrets si le chiffrement au repos est actif,
# puis retire la configuration. En sortant, le chiffrement reste actif (clé cle2 de l'exercice 1),
# et la configuration en vigueur est recopiée dans outils/out/ch46-cle-actuelle.yaml (à garder !).
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/secrets
O=$RACINE/outils/out/ch46r
SS=0.40.0
CONF_NOEUD=/var/lib/minikube/certs/cours-chiffrement/chiffrement.yaml
section() { echo; echo "### $*"; }
source $RACINE/kits/etcd/etcd-minikube.sh
brut() { E get "$1" --print-value-only | head -c "${2:-40}" | od -An -c | tr -s ' ' | head -2; }
nb_rechargements() { kubectl get --raw /metrics | awk '/^apiserver_encryption_config_controller_automatic_reloads_total\{.*success/ {print $2}' | head -1; }
attendre_rechargement() {   # $1 : valeur précédente du compteur
  until [ "$(nb_rechargements)" != "$1" ] && [ -n "$(nb_rechargements)" ]; do sleep 3; done
}
sauver() {   # $1 : fichier local ; affiche le nombre d'occurrences du mot de passe de Colis
  E snapshot save /var/lib/minikube/etcd/s.db > /dev/null 2>&1
  docker cp minikube:/var/lib/minikube/etcd/s.db "$1" >/dev/null
  minikube ssh -- "sudo rm -f /var/lib/minikube/etcd/s.db" 2>/dev/null
  echo "$1 : $(stat -c %s "$1") octets, $(grep -a -o "$MDP" "$1" | wc -l) occurrence(s) du mot de passe"
}

# --- remise à zéro
mkdir -p "$O.tmp"
if minikube ssh -- "sudo test -f $CONF_NOEUD" 2>/dev/null; then
  minikube ssh -- "sudo cat $CONF_NOEUD" 2>/dev/null | tr -d '\r' > "$O.tmp/en-vigueur.yaml"
  python3 - "$O.tmp/en-vigueur.yaml" "$O.tmp/dechiffrer.yaml" <<'PY'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))
for r in c["resources"]:
    r["providers"] = [{"identity": {}}] + [p for p in r["providers"] if "identity" not in p]
yaml.safe_dump(c, open(sys.argv[2], "w"), sort_keys=False)
PY
  avant=$(nb_rechargements)
  (cd $KIT/chiffrement && bash brancher-chiffrement.sh "$O.tmp/dechiffrer.yaml") >/dev/null 2>&1
  attendre_rechargement "$avant"
  kubectl get secrets -A -o json | kubectl replace -f - >/dev/null
  (cd $KIT/chiffrement && FORCER=oui bash brancher-chiffrement.sh --retirer) >/dev/null 2>&1
fi
kubectl delete ns ch46 coffre --wait=false >/dev/null 2>&1
kubectl -n colis delete externalsecret colis-partenaire --ignore-not-found >/dev/null 2>&1
kubectl -n colis delete secretstore vault --ignore-not-found >/dev/null 2>&1
kubectl -n colis delete sa eso-colis --ignore-not-found >/dev/null
kubectl -n colis delete pod lecteur --ignore-not-found >/dev/null
kubectl -n colis delete sealedsecret --all >/dev/null 2>&1
kubectl -n colis delete secret colis-scelle colis-scelle-renomme colis-partenaire --ignore-not-found >/dev/null
kubectl delete clusterrolebinding cours-vault-tokenreview --ignore-not-found >/dev/null
if kubectl -n kube-system get deploy sealed-secrets-controller >/dev/null 2>&1; then
  kubectl delete -f "https://github.com/bitnami-labs/sealed-secrets/releases/download/v$SS/controller.yaml" >/dev/null 2>&1
  kubectl -n kube-system delete secret -l sealedsecrets.bitnami.com/sealed-secrets-key >/dev/null
fi
for ns in ch46 coffre; do while kubectl get ns $ns >/dev/null 2>&1; do sleep 2; done; done
helm status external-secrets -n external-secrets >/dev/null 2>&1 || helm install external-secrets oci://ghcr.io/external-secrets/charts/external-secrets \
  --version 2.12.0 -n external-secrets --create-namespace --set installCRDs=true --set webhook.create=false \
  --set certController.create=false --wait --timeout 10m >/dev/null
rm -rf "$O" "$O.tmp"; mkdir -p "$O"; cd "$O"
# garde-fou : si le rejeu s'arrête alors que le chiffrement a été retiré, on remet la dernière configuration
remettre() {
  minikube ssh -- "sudo test -f $CONF_NOEUD" 2>/dev/null && return
  for f in rotation-etape2.yaml rotation-etape1.yaml chiffrement.yaml; do
    [ -f "$O/$f" ] && { (cd $KIT/chiffrement && bash brancher-chiffrement.sh "$O/$f") >/dev/null 2>&1; return; }
  done
}
trap remettre EXIT
MDP=$(kubectl -n colis get secret colis-db -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)

section "ouverture"
sauver sauvegarde.db
strings sauvegarde.db | grep -B3 "$MDP" | head -6

section "base64"
kubectl -n colis get secret colis-db -o jsonpath='{.data}{"\n"}'
kubectl -n colis get secret colis-db -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d; echo

section "avant chiffrement"
brut /registry/secrets/colis/colis-db 48

section "brancher le chiffrement"
sed "s|CLE1|$(bash $KIT/chiffrement/nouvelle-cle.sh)|" $KIT/chiffrement/chiffrement.yaml.modele > chiffrement.yaml
grep -v 'secret:' chiffrement.yaml
(cd $KIT/chiffrement && bash brancher-chiffrement.sh $O/chiffrement.yaml) 2>&1 | grep -v -i docker
kubectl -n kube-system get pod kube-apiserver-minikube -o json | jq -r '.spec.containers[0].command[]' | grep encryption
kubectl create ns ch46 >/dev/null
kubectl -n ch46 create secret generic essai --from-literal=motdepasse=ultra-secret-46
echo "== essai (écrit après)"; brut /registry/secrets/ch46/essai 60
echo "== colis-db (écrit avant)"; brut /registry/secrets/colis/colis-db 48
kubectl -n ch46 get secret essai -o jsonpath='{.data.motdepasse}' | base64 -d; echo

section "réécrire"
kubectl get secrets -A -o json | kubectl replace -f - 2>&1 | awk '{print $NF}' | sort | uniq -c
brut /registry/secrets/colis/colis-db 48
sauver apres-reecriture.db
REV=$(E endpoint status -w json | jq -r '.[0].Status.header.revision')
E compact "$REV"
sauver apres-compactage.db
E defrag
sauver apres-defragmentation.db

section "clé perdue"
(cd $KIT/chiffrement && bash brancher-chiffrement.sh --retirer) 2>&1 | grep -v -i docker
(cd $KIT/chiffrement && FORCER=oui bash brancher-chiffrement.sh --retirer) 2>&1 | grep -v -i docker
kubectl get --raw '/readyz?verbose' 2>&1 | grep -E '^\[-\]' | head -3
kubectl -n ch46 get secret essai
kubectl -n colis get pods --no-headers | head -2
kubectl -n kube-system logs kube-apiserver-minikube --since=2m | grep -o 'cacher (secrets).*' | head -1 | cut -c1-260
(cd $KIT/chiffrement && bash brancher-chiffrement.sh $O/chiffrement.yaml) 2>&1 | grep -v -i docker
kubectl -n ch46 get secret essai -o jsonpath='{.data.motdepasse}' | base64 -d; echo

section "sealed secrets"
curl -sSL -o controller.yaml "https://github.com/bitnami-labs/sealed-secrets/releases/download/v$SS/controller.yaml"
kubectl apply -f controller.yaml | sort | uniq -c | sort -rn | head -3
kubectl -n kube-system rollout status deploy/sealed-secrets-controller --timeout=180s
kubectl -n kube-system logs deploy/sealed-secrets-controller | grep -E 'New key written|Certificate generated' | sed 's/certificate=.*/certificate=.../'
kubeseal --version
kubeseal --fetch-cert > cle-publique.pem
openssl x509 -in cle-publique.pem -noout -dates
kubectl -n colis create secret generic colis-scelle --from-literal=JETON_API=jeton-de-demonstration-46 --dry-run=client -o yaml > secret-clair.yaml
kubeseal --format yaml < secret-clair.yaml > colis-scelle.yaml
sed -E 's/(JETON_API: .{60}).*/\1.../' colis-scelle.yaml
kubectl apply -f colis-scelle.yaml
sleep 5
kubectl -n colis get sealedsecret,secret colis-scelle
kubectl -n colis get secret colis-scelle -o jsonpath='{.data.JETON_API}' | base64 -d; echo
sed 's/namespace: colis/namespace: ch46/' colis-scelle.yaml | kubectl apply -f -
sleep 5
kubectl -n ch46 get secret colis-scelle
kubectl -n ch46 get events --field-selector involvedObject.name=colis-scelle -o custom-columns=RAISON:.reason,MESSAGE:.message
kubectl -n kube-system get secrets -l sealedsecrets.bitnami.com/sealed-secrets-key -o custom-columns=NOM:.metadata.name,TYPE:.type

section "vault"
kubectl apply -f $KIT/externe/vault-dev.yaml
kubectl -n coffre rollout status deploy/vault --timeout=240s
kubectl -n coffre logs deploy/vault | grep -E 'Storage:|Version:|WARNING! dev mode|Root Token'
bash $KIT/externe/configurer-vault.sh 2>&1 | grep -E '^(version|Success)'

section "external secrets"
helm list -n external-secrets -o json | jq -r '.[] | "\(.name) \(.chart) \(.app_version) \(.status)"'
kubectl -n external-secrets get pods
kubectl apply -f $KIT/externe/colis-vault.yaml
for i in $(seq 1 30); do [ "$(kubectl -n colis get externalsecret colis-partenaire -o jsonpath='{.status.conditions[0].status}' 2>/dev/null)" = True ] && break; sleep 2; done
kubectl -n colis get secretstore,externalsecret
kubectl -n colis get secret colis-partenaire -o jsonpath='{.data.JETON_PARTENAIRE}' | base64 -d; echo
kubectl -n colis get secret colis-partenaire -o json | jq -c '{managed: .metadata.labels["reconcile.external-secrets.io/managed"], proprietaire: [.metadata.ownerReferences[]? | .kind + "/" + .name]}'
kubectl -n coffre logs deploy/vault --since=2m | grep -i -E 'login|auth' | head -2

section "rotation et consommateurs"
kubectl apply -f $KIT/externe/lecteur.yaml
kubectl -n colis wait --for=condition=Ready pod/lecteur --timeout=90s
lire() { kubectl -n colis exec lecteur -- sh -c 'echo "variable : $JETON_PARTENAIRE ; fichier : $(cat /secrets/JETON_PARTENAIRE)"'; }
lire
kubectl -n coffre exec deploy/vault -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=jeton-racine-du-cours vault kv put secret/colis/api jeton-partenaire=jeton-partenaire-v2 | grep -E '^version'
d=$(date +%s)
until [ "$(kubectl -n colis get secret colis-partenaire -o jsonpath='{.data.JETON_PARTENAIRE}' | base64 -d)" = jeton-partenaire-v2 ]; do sleep 1; done
echo "Secret mis à jour après $(( $(date +%s) - d )) s"
until kubectl -n colis exec lecteur -- grep -q v2 /secrets/JETON_PARTENAIRE 2>/dev/null; do sleep 2; done
echo "fichier mis à jour après $(( $(date +%s) - d )) s"
lire

section "ex2 audit"
python3 $KIT/corrige/audit-chiffrement.py; echo "code de sortie : $?"

section "ex1 rotation de la clé"
CLE1=$(awk '/secret:/ {print $2}' chiffrement.yaml)
CLE2=$(bash $KIT/chiffrement/nouvelle-cle.sh)
python3 - "$CLE1" "$CLE2" <<'PY'
import sys
c1, c2 = sys.argv[1:]
gabarit = """apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources: [secrets]
  providers:
  - secretbox:
      keys:
{cles}
  - identity: {{}}
"""
cle = lambda n, s: f"      - name: {n}\n        secret: {s}"
open("rotation-etape1.yaml", "w").write(gabarit.format(cles=cle("cle2", c2) + "\n" + cle("cle1", c1)))
open("rotation-etape2.yaml", "w").write(gabarit.format(cles=cle("cle2", c2)))
PY
avant=$(nb_rechargements)
(cd $KIT/chiffrement && bash brancher-chiffrement.sh $O/rotation-etape1.yaml) 2>&1 | grep -v -i docker
d=$(date +%s); attendre_rechargement "$avant"; echo "configuration rechargée après $(( $(date +%s) - d )) s"
kubectl get --raw /metrics | grep '^apiserver_encryption_config_controller_automatic_reloads_total' | sed 's/apiserver_id_hash="[^"]*",//'
kubectl -n ch46 create secret generic apres-rotation --from-literal=a=b
python3 $KIT/corrige/audit-chiffrement.py
kubectl get secrets -A -o json | kubectl replace -f - 2>&1 | awk '{print $NF}' | sort | uniq -c
python3 $KIT/corrige/audit-chiffrement.py
avant=$(nb_rechargements)
(cd $KIT/chiffrement && bash brancher-chiffrement.sh $O/rotation-etape2.yaml) 2>&1 | grep -v -i docker
attendre_rechargement "$avant"
kubectl -n colis get secret colis-db -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d | wc -c
curl -s http://192.168.49.100/api/sante; echo
cp rotation-etape2.yaml ../ch46-cle-actuelle.yaml

section "ex3 portée"
kubeseal --format yaml --scope namespace-wide < secret-clair.yaml > colis-scelle-ns.yaml
grep -A1 annotations colis-scelle-ns.yaml
sed 's/name: colis-scelle$/name: colis-scelle-renomme/' colis-scelle-ns.yaml | kubectl apply -f -
sed 's/name: colis-scelle$/name: colis-scelle-renomme-strict/' colis-scelle.yaml | kubectl apply -f -
sleep 5
kubectl -n colis get secret colis-scelle-renomme -o jsonpath='{.data.JETON_API}' | base64 -d; echo
kubectl -n colis get sealedsecret colis-scelle-renomme-strict -o json | jq -r '.status.conditions[0].message'
kubectl -n colis delete sealedsecret colis-scelle-renomme-strict >/dev/null

section "ex4 coffre en panne"
kubectl -n coffre scale deploy/vault --replicas=0
kubectl -n coffre wait --for=delete pod -l app=vault --timeout=90s >/dev/null
sleep 45
kubectl -n colis get externalsecret colis-partenaire
kubectl -n colis get secret colis-partenaire -o jsonpath='{.data.JETON_PARTENAIRE}' | base64 -d; echo
kubectl -n colis get events --field-selector involvedObject.name=colis-partenaire,reason=UpdateFailed -o custom-columns=MESSAGE:.message | tail -1 | cut -c1-200
kubectl -n coffre scale deploy/vault --replicas=1 >/dev/null
kubectl -n coffre rollout status deploy/vault --timeout=120s >/dev/null
kubectl -n coffre exec deploy/vault -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=jeton-racine-du-cours vault kv get secret/colis/api 2>&1 | tail -1
JETON=jeton-partenaire-v2 bash $KIT/externe/configurer-vault.sh >/dev/null 2>&1
sleep 40
kubectl -n colis get externalsecret colis-partenaire

echo; echo "### fin"
