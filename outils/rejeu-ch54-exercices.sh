#!/usr/bin/env bash
# Chapitre 54, exercices. Suppose rejeu-ch54.sh passé (CRD v1 seule, objet principal dans ch54).
set -uo pipefail
export PATH=~/.local/opt/cours-k8s/bin:$PATH
export LC_ALL=C.UTF-8
RACINE=$(cd "$(dirname "$0")/.." && pwd)
KIT=$RACINE/kits/crd
O=$RACINE/outils/out/ch54r/exercices; rm -rf $O; mkdir -p $O && cd $O
section() { echo; echo "### $*"; }
essai() { # nom, spec en YAML d'une ligne
  printf 'apiVersion: cours.example.com/v1\nkind: Colis\nmetadata: {name: %s, namespace: ch54}\nspec: %s\n' "$1" "$2" > $1.yaml
  echo "\$ kubectl apply -f $1.yaml      # spec: $2"
  kubectl apply -f $1.yaml 2>&1 | sed -E 's/Invalid value: ".*": strict decoding error/Invalid value: "...": strict decoding error/'
  kubectl -n ch54 get colis $1 -o jsonpath='  enregistré : {.spec}{"\n"}' 2>/dev/null
}

section "ex1 schema"
essai essai-a '{version: "2.3.0", api: {replicas: 3, cpu: 200m}}'
echo "\$ kubectl apply -f essai-a.yaml --validate=false"
kubectl apply -f essai-a.yaml --validate=false; kubectl -n ch54 get colis essai-a -o jsonpath='  enregistré : {.spec}{"\n"}'
essai essai-b '{version: 2.3}'
essai essai-c '{version: "3.0.0", worker: {max: 3}}'
essai essai-d '{version: "3.0.0", worker: {min: 6}}'
kubectl -n ch54 delete colis essai-a essai-c --ignore-not-found >/dev/null

section "ex2 cel"
python3 - $KIT/06-colis-v1-seul.yaml > colis-ex2.yaml <<'EOF'
import sys
s = open(sys.argv[1]).read()
a = """            x-kubernetes-validations:
            - rule: '!has(oldSelf.version) || semver(self.version).compareTo(semver(oldSelf.version)) >= 0'
              message: pas de retour à une version antérieure
"""
assert a in s
print(s.replace(a, a + """            - rule: self.worker.max <= 4 * self.api.replicas
              messageExpression: "'worker.max doit rester sous 4 × api.replicas, soit %d'.format([4 * self.api.replicas])"
"""), end="")
EOF
grep -n -A3 "self.worker.max" colis-ex2.yaml
kubectl apply -f colis-ex2.yaml
sleep 3
essai essai-e '{version: "3.0.0", api: {replicas: 1}, worker: {max: 5}}'
essai essai-f '{version: "3.0.0", api: {replicas: 2}, worker: {max: 8}}'
echo "\$ kubectl -n ch54 scale colis essai-f --replicas=1"
kubectl -n ch54 scale colis essai-f --replicas=1 2>&1
kubectl -n ch54 delete colis essai-f --ignore-not-found >/dev/null
kubectl apply -f $KIT/06-colis-v1-seul.yaml

section "ex3 role"
cat > operateur.yaml <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata: {name: operateur, namespace: ch54}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: operateur, namespace: ch54}
rules:
- apiGroups: [cours.example.com]
  resources: [colis]
  verbs: [get, list, watch]
- apiGroups: [cours.example.com]
  resources: [colis/status]
  verbs: [get, update, patch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: operateur, namespace: ch54}
subjects: [{kind: ServiceAccount, name: operateur, namespace: ch54}]
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: operateur}
EOF
kubectl apply -f operateur.yaml
Q="--as=system:serviceaccount:ch54:operateur"
for v in "watch colis" "patch colis" "patch colis/status" "update colis/scale"; do
  r=${v#* }; sous=""; [ "${r#*/}" != "$r" ] && sous="--subresource=${r#*/}"
  echo "$v : $(kubectl auth can-i ${v% *} ${r%/*}.cours.example.com $sous -n ch54 $Q 2>/dev/null || true)"
done
echo "\$ kubectl -n ch54 patch colis principal --subresource=status --type=merge -p '{\"status\":{\"observedGeneration\":1}}' $Q"
kubectl -n ch54 patch colis principal --subresource=status --type=merge -p '{"status":{"observedGeneration":1}}' $Q 2>&1
echo "\$ kubectl -n ch54 patch colis principal --type=merge -p '{\"spec\":{\"api\":{\"replicas\":3}}}' $Q"
kubectl -n ch54 patch colis principal --type=merge -p '{"spec":{"api":{"replicas":3}}}' $Q 2>&1
kubectl delete -f operateur.yaml >/dev/null

section "ex4 versions"
# un état à migrer : on remet v1alpha1 en version stockée le temps de créer un objet
kubectl apply -f $KIT/05-colis-v1.yaml >/dev/null
kubectl patch crd colis.cours.example.com --type=json -p '[{"op":"replace","path":"/spec/versions/0/storage","value":true},{"op":"replace","path":"/spec/versions/1/storage","value":false}]' >/dev/null
printf 'apiVersion: cours.example.com/v1\nkind: Colis\nmetadata: {name: retardataire, namespace: ch54}\nspec: {version: 2.2.1}\n' | kubectl apply -f - 2>&1 | grep -v Warning
kubectl apply -f $KIT/05-colis-v1.yaml >/dev/null
sleep 2
echo "\$ python3 versions-crd.py --objets"
python3 $KIT/corrige/versions-crd.py --objets; echo "code de sortie : $?"
kubectl delete storageversionmigration colis-vers-v1 --ignore-not-found >/dev/null
kubectl apply -f $RACINE/outils/out/ch54r/migration.yaml >/dev/null
for i in $(seq 1 60); do [ "$(kubectl get storageversionmigration colis-vers-v1 -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}')" = True ] && break; sleep 2; done
echo "\$ python3 versions-crd.py --objets"
python3 $KIT/corrige/versions-crd.py --objets; echo "code de sortie : $?"
kubectl apply -f $KIT/06-colis-v1-seul.yaml >/dev/null
kubectl -n ch54 delete colis retardataire >/dev/null
echo "\$ python3 versions-crd.py --tout | grep -E 'DÉFINITION|v1beta1  |définitions'"
python3 $KIT/corrige/versions-crd.py --tout | grep -E 'DÉFINITION|  v1beta1  |définitions'
echo; echo "### fin"
