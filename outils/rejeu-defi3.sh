#!/usr/bin/env bash
# Défi III : déploiement cassé de Colis (namespace colis-defi), diagnostic puis réparation panne par panne.
# Suppose le chapitre 24 fait : registre démarré, hosts.toml dans le nœud, addon metallb et sa plage.
# Laisse Colis réparé en marche (http://192.168.49.101/).
cd "$(dirname "$0")"; O=$PWD/out/defi3; rm -rf $O; mkdir -p $O; cp -a ../kits/defi-3/colis-defi $O/m
C=$PWD/../kits/defi-3/corrige
export PATH=~/.local/opt/cours-k8s/bin:$PATH LC_ALL=C
K="kubectl --context minikube -n colis-defi"
H() { local n=$1; shift; echo "### $n : $*"; (cd $O/m && timeout 600 bash -c "$*") 2>&1 | grep -v '^W[0-9]' > $O/$n.txt; head -c 9000 $O/$n.txt; }
docker start registre >/dev/null 2>&1
kubectl --context minikube delete namespace colis-defi --wait=true >/dev/null 2>&1
kubectl --context minikube apply -f ../kits/colis-k8s/metallb-plage.yaml >/dev/null
H 01-deployer "kubectl --context minikube apply -f 00-namespace.yaml; $K create secret generic colis-db --from-literal=POSTGRES_PASSWORD=\$(head -c 18 /dev/urandom | base64 | tr -d '/+='); kubectl --context minikube apply -f .; sleep 90; $K get pods"
H 02-site "IP=\$($K get svc web -o jsonpath='{.status.loadBalancer.ingress[0].ip}'); echo IP=\$IP; curl -sS -m 5 http://\$IP/ -o /dev/null; echo \"code curl : \$?\"; $K get endpointslices; $K get endpointslices -l kubernetes.io/service-name=web -o jsonpath='{range .items[0].endpoints[*]}{.addresses[0]} ready={.conditions.ready}{\"\\n\"}{end}'"
H 03-postgres "$K describe pod -l app.kubernetes.io/name=postgres | sed -n '/^Events:/,\$p'; $K get pod -l app.kubernetes.io/name=postgres -o jsonpath='{.items[0].spec.containers[0].resources}'; echo; kubectl --context minikube get node minikube -o jsonpath='{.status.allocatable.cpu}'; echo"
H 04-reparer-postgres "cp $C/20-postgres.yaml .; kubectl --context minikube apply -f 20-postgres.yaml; $K rollout status deployment/postgres --timeout=180s; sleep 45; $K get pods"
H 05-api "$K logs deploy/api --previous --tail=3; $K logs deploy/postgres | grep -m2 FATAL; $K logs deploy/worker --tail=2 2>&1 | tail -2; P=\$($K get pods -l app.kubernetes.io/name=api -o name | head -1); $K get \$P -o jsonpath='{range .spec.containers[0].env[*]}{.name}{\"\\n\"}{end}'"
H 06-reparer-api "cp $C/30-api.yaml ./30-api-corrige.yaml; python3 - <<'PY'
s=open('30-api.yaml').read(); c=open('30-api-corrige.yaml').read()
# ne répare que l'ordre des variables, pas le Service
i=s.index('---'); j=c.index('---'); open('30-api.yaml','w').write(c[:j]+s[i:])
PY
rm 30-api-corrige.yaml; kubectl --context minikube apply -f 30-api.yaml; $K rollout status deployment/api --timeout=180s; $K get pods -l app.kubernetes.io/name=api"
H 07-worker "$K get pods -l app.kubernetes.io/name=worker; $K describe pod -l app.kubernetes.io/name=worker | grep -A4 'Last State'; $K get pod -l app.kubernetes.io/name=worker -o jsonpath='{.items[0].spec.containers[0].resources}'; echo"
H 08-reparer-worker "cp $C/31-worker.yaml .; kubectl --context minikube apply -f 31-worker.yaml; $K rollout status deployment/worker --timeout=180s; sleep 70; kubectl --context minikube top pod -n colis-defi -l app.kubernetes.io/name=worker"
H 09-web "$K get pods -l app.kubernetes.io/name=web; $K get events --field-selector reason=Unhealthy | grep web | tail -1 | cut -c1-250; $K get pods -l app.kubernetes.io/name=web -o jsonpath='{.items[0].spec.containers[0].ports}'; echo"
H 10-reparer-web "cp $C/40-web.yaml .; kubectl --context minikube apply -f 40-web.yaml; $K rollout status deployment/web --timeout=180s; IP=\$($K get svc web -o jsonpath='{.status.loadBalancer.ingress[0].ip}'); curl -s -o /dev/null -w 'site : %{http_code}\n' http://\$IP/; curl -s -w '\napi : %{http_code}\n' http://\$IP/api/pret"
H 11-service-api "$K get endpointslices -l kubernetes.io/service-name=api; $K get svc api -o jsonpath='{.spec.ports}'; echo; $K get pods -l app.kubernetes.io/name=api"
H 12-reparer-service "cp $C/30-api.yaml .; kubectl --context minikube apply -f 30-api.yaml; sleep 3; $K get endpointslices -l kubernetes.io/service-name=api; curl -s http://192.168.49.101/api/pret; echo"
H 13-purge "$K delete pod purge; kubectl --context minikube apply -f 50-purge.yaml; $K wait --for=jsonpath='{.status.phase}'=Succeeded pod/purge --timeout=90s; $K logs purge; diff -r . $C && echo identiques"
H 14-grille "IP=192.168.49.101; $K get pods; curl -s http://\$IP/api/pret; echo; curl -s -X POST http://\$IP/api/colis -H 'Content-Type: application/json' -d '{\"destinataire\":\"Grace Hopper\",\"depart\":\"Lyon\",\"arrivee\":\"Lille\",\"poids_kg\":1.2}' >/dev/null; sleep 5; curl -s http://\$IP/api/colis/1; echo; R=\"custom-columns=NOM:.metadata.name,REDEMARRAGES:.status.containerStatuses[0].restartCount\"; $K get pods -o \$R > r1.txt; sleep 120; $K get pods -o \$R > r2.txt; diff r1.txt r2.txt && echo 'aucun nouveau redémarrage'; cat r2.txt; $K get deploy -o jsonpath='{range .items[*]}{.metadata.name}{\" \"}{.spec.template.spec.containers[0].resources.limits.memory}{\" \"}{.spec.template.spec.containers[0].readinessProbe.httpGet.port}{.spec.template.spec.containers[0].readinessProbe.exec.command[0]}{\"\\n\"}{end}'; rm r1.txt r2.txt"
