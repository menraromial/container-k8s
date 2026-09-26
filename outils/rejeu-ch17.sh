#!/usr/bin/env bash
# Chapitre 17 : le Pod. Namespace « ch17 » (recréé), manifestes de kits/pods.
cd "$(dirname "$0")"; O=$PWD/out/ch17; rm -rf $O; mkdir -p $O
export PATH=~/.local/opt/cours-k8s/bin:$PATH
K="kubectl --context minikube -n ch17"; M=$PWD/../kits/pods
H() { local n=$1; shift; echo "### $n : $*"; timeout 600 bash -c "$*" 2>&1 | grep -v '^W[0-9]' > $O/$n.txt; head -c 8000 $O/$n.txt; }
kubectl --context minikube delete namespace ch17 --wait=true >/dev/null 2>&1; kubectl --context minikube create namespace ch17 >/dev/null
# le Pod qui plante tourne en arrière-plan pendant tout le script, pour mesurer le recul exponentiel
$K apply -f $M/plantage.yaml >/dev/null; T0=$(date +%s)
( last=''; while [ $(( $(date +%s)-T0 )) -lt 420 ]; do s=$($K get pod plantage -o jsonpath='{.status.containerStatuses[0].restartCount} {.status.containerStatuses[0].state.waiting.reason}{.status.containerStatuses[0].state.running.startedAt}{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null); if [ "$s" != "$last" ]; then echo "t=$(( $(date +%s)-T0 )) s : $s"; last=$s; fi; sleep 1; done > $O/plantage-chrono.txt ) &
H 01-simple "$K apply -f $M/simple.yaml; $K get pod simple -o wide -w --request-timeout=0 & p=\$!; sleep 6; kill \$p; echo; $K get pod simple -o jsonpath='{.status.phase}{\"\n\"}{range .status.conditions[*]}{.type}={.status} {.lastTransitionTime}{\"\n\"}{end}'"
H 02-simple-status "$K get pod simple -o yaml | sed -n '/^status:/,\$p' | head -60"
H 03-tache "$K apply -f $M/tache.yaml; sleep 12; $K get pod tache; $K logs tache; $K get pod tache -o jsonpath='{.status.phase} {.status.containerStatuses[0].state.terminated.exitCode} {.status.containerStatuses[0].state.terminated.reason}{\"\n\"}'"
H 04-echec "$K apply -f $M/echec.yaml; sleep 8; $K get pod echec; $K logs echec; $K get pod echec -o jsonpath='{.status.phase} {.status.containerStatuses[0].state.terminated.exitCode} {.status.containerStatuses[0].state.terminated.reason}{\"\n\"}'"
H 05-image "$K apply -f $M/image-absente.yaml; sleep 25; $K get pod image-absente; $K describe pod image-absente | sed -n '/^Events:/,\$p' | cut -c1-220"
H 06-pending "$K apply -f $M/trop-gros.yaml; sleep 5; $K get pod trop-gros; $K describe pod trop-gros | sed -n '/^Events:/,\$p' | cut -c1-240; kubectl --context minikube get node minikube -o jsonpath='{.status.allocatable.cpu}{\"\n\"}'"
H 07-duo "$K apply -f $M/duo.yaml; $K wait --for=condition=Ready pod/duo --timeout=90s; sleep 16; $K get pod duo -o wide; $K logs duo -c compteur | tail -3; $K exec duo -c web -- sh -c 'hostname; ip -4 addr show eth0 | grep inet'; $K exec duo -c compteur -- sh -c 'hostname; ip -4 addr show eth0 | grep inet'; $K logs duo 2>&1 | head -2"
H 08-init "$K apply -f $M/init.yaml; for i in 1 2 3 4 5 6; do $K get pod init --no-headers; sleep 2; done; $K wait --for=condition=Ready pod/init --timeout=60s; $K exec init -- wget -q -O - http://localhost/"
H 09-sidecar-ancien "$K apply -f $M/sidecar-ancien.yaml; sleep 20; $K get pod sidecar-ancien; $K get pod sidecar-ancien -o jsonpath='{range .status.containerStatuses[*]}{.name}: {.state}{\"\n\"}{end}'"
H 10-sidecar-natif "$K apply -f $M/sidecar-natif.yaml; for i in 1 2 3 4 5 6 7 8 9 10; do $K get pod sidecar-natif --no-headers; sleep 2; done; $K logs sidecar-natif -c expediteur; $K get pod sidecar-natif -o jsonpath='{.status.phase}{\"\n\"}{range .status.initContainerStatuses[*]}{.name}: {.state.terminated.reason} {.state.terminated.exitCode}{\"\n\"}{end}{range .status.containerStatuses[*]}{.name}: {.state.terminated.reason} {.state.terminated.exitCode}{\"\n\"}{end}'"
H 11-pause "minikube ssh -- sudo crictl pods --namespace ch17 --name duo; minikube ssh -- 'sudo crictl ps --pod \$(sudo crictl pods --namespace ch17 --name duo -q)'"
echo "attente de la fin de la mesure du recul"; wait
H 12-plantage "cat $O/plantage-chrono.txt; $K get pod plantage; $K logs plantage --previous; $K describe pod plantage | sed -n '/Last State/,/Restart Count/p'; $K get events --field-selector involvedObject.name=plantage,reason=BackOff -o custom-columns=NB:.count,MESSAGE:.message"
