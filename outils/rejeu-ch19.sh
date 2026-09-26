#!/usr/bin/env bash
# Chapitre 19 : ReplicaSet et Deployment. Namespace « ch19 » (recréé), manifestes de kits/deployments.
cd "$(dirname "$0")"; O=$PWD/out/ch19; rm -rf $O; mkdir -p $O; cp -a ../kits/deployments $O/m
export PATH=~/.local/opt/cours-k8s/bin:$PATH
kubectl config use-context minikube >/dev/null
kubectl delete namespace ch19 --wait=true >/dev/null 2>&1; kubectl create namespace ch19 >/dev/null; kubectl config set-context --current --namespace=ch19 >/dev/null
H() { local n=$1; shift; echo "### $n : $*"; (cd $O/m && timeout 400 bash -c "$*") 2>&1 | grep -v '^W[0-9]' > $O/$n.txt; head -c 9000 $O/$n.txt; }
# suivre : affiche, à chaque changement, les ReplicaSets de vitrine (image : voulu/prêt/disponible), pendant $1 secondes
cat > $O/suivre.sh <<'EOS'
export LC_ALL=C; t0=$(date +%s%N); last=''; fin=$(( $(date +%s) + $1 ))
while [ $(date +%s) -lt $fin ]; do
  s=$(kubectl get rs -l app.kubernetes.io/name=vitrine -o jsonpath='{range .items[*]}{.spec.template.spec.containers[0].image}={.spec.replicas}/{.status.readyReplicas}/{.status.availableReplicas}  {end}' | sed 's/nginx://g; s/-alpine//g')
  if [ "$s" != "$last" ]; then printf 't=%5.1f s : %s\n' $(echo "($(date +%s%N)-$t0)/1000000000" | bc -l) "$s"; last=$s; fi
  sleep 0.3
done
EOS
chmod +x $O/suivre.sh; S=$O/suivre.sh
H 01-creer "kubectl apply -f vitrine.yaml; kubectl rollout status deployment/vitrine --timeout=120s; kubectl get deployment,rs,pods -o wide | cut -c1-150"
H 02-maj-defaut "kubectl set image deployment/vitrine nginx=nginx:1.30-alpine; $S 45"
H 03-rs-apres "kubectl get rs -o wide; kubectl rollout history deployment/vitrine"
H 04-surge0 "kubectl patch deployment vitrine -p '{\"spec\":{\"strategy\":{\"rollingUpdate\":{\"maxSurge\":0,\"maxUnavailable\":1}}}}' >/dev/null; kubectl set image deployment/vitrine nginx=nginx:1.29-alpine; $S 60"
H 05-surge100 "kubectl patch deployment vitrine -p '{\"spec\":{\"strategy\":{\"rollingUpdate\":{\"maxSurge\":\"100%\",\"maxUnavailable\":0}}}}' >/dev/null; kubectl set image deployment/vitrine nginx=nginx:1.30-alpine; $S 30"
H 06-recreate "kubectl patch deployment vitrine --type=json -p '[{\"op\":\"remove\",\"path\":\"/spec/strategy/rollingUpdate\"},{\"op\":\"replace\",\"path\":\"/spec/strategy/type\",\"value\":\"Recreate\"}]' >/dev/null; kubectl set image deployment/vitrine nginx=nginx:1.29-alpine; $S 30"
H 07-historique "kubectl annotate deployment vitrine kubernetes.io/change-cause='retour en 1.29, stratégie Recreate' >/dev/null; kubectl rollout history deployment/vitrine; kubectl rollout history deployment/vitrine --revision=3 | head -12"
H 08-undo "kubectl rollout undo deployment/vitrine; kubectl rollout status deployment/vitrine --timeout=120s; kubectl get deployment vitrine -o jsonpath='{.spec.template.spec.containers[0].image}{\"\n\"}'; kubectl rollout history deployment/vitrine; kubectl get rs"
H 09-bloque "kubectl patch deployment vitrine --type=merge -p '{\"spec\":{\"progressDeadlineSeconds\":30,\"strategy\":{\"type\":\"RollingUpdate\",\"rollingUpdate\":{\"maxSurge\":1,\"maxUnavailable\":1}}}}' >/dev/null; kubectl set image deployment/vitrine nginx=nginx:9.99-alpine; kubectl rollout status deployment/vitrine --timeout=90s; echo code=\$?; kubectl get deployment vitrine; kubectl get rs; kubectl get pods; kubectl get deployment vitrine -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{\"\n\"}{end}'"
H 10-undo-bloque "kubectl rollout undo deployment/vitrine; kubectl rollout status deployment/vitrine --timeout=120s; kubectl get pods"
H 11-pause "kubectl rollout pause deployment/vitrine; kubectl set image deployment/vitrine nginx=nginx:1.29-alpine; kubectl set env deployment/vitrine MESSAGE=bonjour; sleep 5; kubectl get rs; kubectl rollout resume deployment/vitrine; kubectl rollout status deployment/vitrine --timeout=120s; kubectl get rs; kubectl rollout history deployment/vitrine | tail -3"
H 12-restart "kubectl rollout restart deployment/vitrine; kubectl rollout status deployment/vitrine --timeout=120s; kubectl get deployment vitrine -o jsonpath='{.spec.template.metadata.annotations}{\"\n\"}'; kubectl get rs"
H 13-echelle-sans-rs "kubectl scale deployment vitrine --replicas=6; kubectl rollout status deployment/vitrine --timeout=60s; kubectl get rs"
H 14-selecteur "kubectl patch deployment vitrine --type=merge -p '{\"spec\":{\"selector\":{\"matchLabels\":{\"app.kubernetes.io/name\":\"autre\"}},\"template\":{\"metadata\":{\"labels\":{\"app.kubernetes.io/name\":\"autre\"}}}}}' 2>&1"
H 15-rs-adoption "kubectl run orpheline --image=nginx:1.30-alpine --labels=app=copies; kubectl apply -f replicaset.yaml; sleep 5; kubectl get pods -l app=copies -o custom-columns='NOM:.metadata.name,PROPRIETAIRE:.metadata.ownerReferences[0].name'"
H 16-rs-image "kubectl patch rs copies --type=json -p '[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"nginx:1.29-alpine\"}]'; sleep 3; kubectl get pods -l app=copies -o custom-columns='NOM:.metadata.name,IMAGE:.spec.containers[0].image'"
