#!/usr/bin/env bash
# Chapitre 27, DaemonSet : profil minikube « deux-noeuds » (2 nœuds de 2 Gio), démarré ; le profil principal arrêté
# pour rester sous 6 Gio. Ajoute puis retire un troisième nœud. Laisse le DaemonSet veilleur dans ch27.
cd "$(dirname "$0")"; O=$PWD/out/ch27n; rm -rf $O; mkdir -p $O; cp -a ../kits/taches $O/m
export PATH=~/.local/opt/cours-k8s/bin:$PATH LC_ALL=C
KK="kubectl --context deux-noeuds"; K="$KK -n ch27"
H() { local n=$1; shift; echo "### $n : $*"; (cd $O/m && timeout 600 bash -c "$*") 2>&1 | grep -v '^W[0-9]' > $O/$n.txt; head -c 9000 $O/$n.txt; }
$KK delete namespace ch27 --wait=true >/dev/null 2>&1; $KK create namespace ch27 >/dev/null
$KK label node deux-noeuds deux-noeuds-m02 disque- >/dev/null 2>&1
H 01-existants "$KK get daemonsets -A; $KK get nodes -o custom-columns=NOM:.metadata.name,TAINTS:.spec.taints"
H 02-veilleur "$K apply -f veilleur.yaml; $K rollout status ds/veilleur --timeout=120s >/dev/null; $K get ds veilleur; $K get pods -l app=veilleur -o wide | cut -c1-90; sleep 3; for p in \$($K get pods -l app=veilleur -o name); do $K logs \$p; done"
H 03-placement "P=\$($K get pods -l app=veilleur -o name | head -1); $K get \$P -o jsonpath='{.spec.affinity}{\"\\n\"}'; $K get \$P -o jsonpath='{range .spec.tolerations[*]}{.key} {.operator} {.effect}{\"\\n\"}{end}'"
H 04-ajout "d=\$(date +%s); minikube node add -p deux-noeuds 2>&1 | tail -1; $KK wait --for=condition=Ready node/deux-noeuds-m03 --timeout=180s; echo \"nœud prêt après \$(( \$(date +%s)-d )) s\"; until [ \"\$($K get pods -l app=veilleur --field-selector spec.nodeName=deux-noeuds-m03 -o jsonpath='{.items[0].status.phase}' 2>/dev/null)\" = Running ]; do sleep 1; done; echo \"veilleur en marche après \$(( \$(date +%s)-d )) s\"; $K get pods -l app=veilleur -o wide | cut -c1-90; $K get ds veilleur"
H 05-retrait "minikube node delete m03 -p deux-noeuds 2>&1 | tail -1; d=\$(date +%s); $K get pods -l app=veilleur -o wide | cut -c1-90; until [ -z \"\$($K get pods -l app=veilleur --field-selector spec.nodeName=deux-noeuds-m03 -o name)\" ]; do sleep 2; done; echo \"Pod retiré \$(( \$(date +%s)-d )) s après la suppression du nœud\"; $K get ds veilleur"
H 06-selection "$K get ds veilleur -o jsonpath='{.spec.updateStrategy}{\"\\n\"}'; $KK label node deux-noeuds-m02 disque=ssd; $K patch ds veilleur -p '{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"disque\":\"ssd\"}}}}}'; $K rollout status ds/veilleur --timeout=120s >/dev/null; $K get ds veilleur; $K get pods -l app=veilleur -o wide | cut -c1-90; $KK label node deux-noeuds disque=ssd; sleep 5; $K get pods -l app=veilleur -o wide | cut -c1-90"
