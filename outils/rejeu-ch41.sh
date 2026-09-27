#!/usr/bin/env bash
# Chapitre 41 : les NetworkPolicies. Partie B d'abord (profil cilium, namespace ch41 recréé), puis partie A sur le
# profil principal : retire puis réapplique les politiques de Colis (namespace colis), crée vitrine/intrus et keda/curieux.
# Un profil à la fois. Laisse le profil principal en marche, avec les politiques de Colis en place.
cd "$(dirname "$0")"; O=$PWD/out/ch41; rm -rf $O; mkdir -p $O; cp -a ../kits/politiques $O/m
export PATH=~/.local/opt/cours-k8s/bin:$PATH LC_ALL=C
H() { local n=$1; shift; echo "### $n : $*"; (cd $O/m && timeout 900 bash -c "$*") 2>&1 | grep -v '^W[0-9]' | grep -v 'docker context\|Docker CLI context' > $O/$n.txt; head -c 4000 $O/$n.txt; }
CA=$PWD/out/ch28/m/ca.crt; [ -f $CA ] || CA=$PWD/out/defi4/ca.crt; export CA

# --- B. Cilium, jusqu'aux requêtes HTTP ---
for p in minikube deux-noeuds calico; do minikube stop -p $p >/dev/null 2>&1; done
minikube start -p cilium >/dev/null 2>&1; kubectl config use-context cilium >/dev/null; kubectl -n kube-system rollout status ds/cilium --timeout=400s >/dev/null
kubectl delete namespace ch41 --ignore-not-found --wait=true >/dev/null 2>&1
t="K='kubectl -n ch41'; echo \"  client GET /hostname     : \$(\$K exec client -- curl -s -m 3 -w ' [%{http_code}]' http://serveur/hostname)\"; echo \"  client GET /echo?msg=x   : \$(\$K exec client -- curl -s -m 3 -w ' [%{http_code}]' 'http://serveur/echo?msg=x' | tr -d '\\n')\"; echo \"  autre  GET /hostname     : \$(\$K exec autre -- curl -s -m 3 -w ' [%{http_code}]' http://serveur/hostname 2>/dev/null; echo \" code \$?\")\""
H b01-sans "kubectl apply -f cilium-l7.yaml >/dev/null; kubectl -n ch41 wait --for=condition=Ready pod --all --timeout=240s >/dev/null; until kubectl -n ch41 exec client -- curl -s -m 2 http://serveur/hostname >/dev/null 2>&1; do sleep 2; done; $t"
H b02-avec "kubectl apply -f cilium-politique.yaml; sleep 8; $t"
H b03-verdicts "S=\$(kubectl -n ch41 get pod serveur -o jsonpath='{.spec.nodeName}'); A=\$(kubectl -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName=\$S -o name); kubectl -n kube-system exec \$A -c cilium-agent -- cilium-dbg endpoint list 2>/dev/null | grep -E 'ENDPOINT|app=serveur' | cut -c1-110; timeout 12 kubectl -n kube-system exec \$A -c cilium-agent -- cilium-dbg monitor --type drop --type l7 > mon.txt 2>&1 & sleep 3; kubectl -n ch41 exec autre -- curl -s -m 2 http://serveur/hostname >/dev/null; kubectl -n ch41 exec client -- curl -s -m 2 'http://serveur/echo?msg=x' >/dev/null; wait; grep -m1 'Policy denied' mon.txt | cut -c1-200; grep -E 'http' mon.txt | head -2 | sed -E 's/\\(\\[k8s:app=client[^]]*\\]\\)/([k8s:app=client ...])/; s/\\(\\[k8s:app=serveur[^]]*\\]\\)/([k8s:app=serveur ...])/g'"

# --- A. Colis, sur le profil principal ---
minikube stop -p cilium >/dev/null 2>&1
docker start registre >/dev/null 2>&1
minikube start >/dev/null 2>&1; kubectl config use-context minikube >/dev/null; kubectl wait --for=condition=Ready node --all --timeout=300s >/dev/null
kubectl apply -f ../kits/colis-k8s/metallb-plage.yaml >/dev/null
kubectl -n colis delete networkpolicy --all >/dev/null 2>&1
for d in api web redis; do kubectl -n colis rollout status deploy/$d --timeout=300s >/dev/null; done; kubectl -n colis rollout status sts/postgres --timeout=300s >/dev/null
until [ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' http://192.168.49.100/)" = 200 ]; do sleep 3; done
until curl -s -m 3 --cacert $CA --resolve colis.local:443:192.168.49.102 https://colis.local/api/pret | grep -q pret; do sleep 3; done
verifs="echo \"  site (LoadBalancer)       : \$(curl -s -m 3 -o /dev/null -w '%{http_code}' http://192.168.49.100/)\"; echo \"  API par le site           : \$(curl -s -m 3 http://192.168.49.100/api/pret)\"; echo \"  API par la passerelle     : \$(curl -s -m 3 --cacert \$CA --resolve colis.local:443:192.168.49.102 https://colis.local/api/pret)\"; echo \"  intrus vers PostgreSQL    : \$(kubectl -n vitrine exec intrus -- sh -c 'nc -z -w 2 postgres.colis.svc.cluster.local 5432 && echo ouvert || echo fermé' 2>&1 | tail -1)\"; echo \"  intrus vers Redis         : \$(kubectl -n vitrine exec intrus -- sh -c 'printf \"PING\\r\\nLLEN colis:a-estimer\\r\\n\" | nc -w 2 redis.colis.svc.cluster.local 6379 || echo \"(pas de réponse)\"' 2>&1 | tr -d '\\r' | tr '\\n' ' ')\""
H a01-sans "kubectl apply -f intrus.yaml >/dev/null; kubectl -n vitrine wait --for=condition=Ready pod/intrus --timeout=240s >/dev/null; $verifs"
H a02-refus "kubectl apply -f 00-refus-par-defaut.yaml; sleep 5; $verifs; kubectl -n colis exec deploy/web -- sh -c 'wget -qO- -T 3 http://api:8000/pret 2>&1'; kubectl -n colis get pods -o custom-columns=POD:.metadata.name,PRET:.status.containerStatuses[0].ready --no-headers | grep -v purge"
H a03-toutes "kubectl apply -f 10-dns.yaml -f 20-web.yaml -f 30-api.yaml -f 40-postgres.yaml -f 50-redis.yaml -f 60-worker-purge.yaml; sleep 5; $verifs; kubectl -n colis get networkpolicy"
H a04-flux "K='kubectl -n colis'; for i in \$(seq 1 12); do curl -s -o /dev/null -X POST http://192.168.49.100/api/colis -H 'Content-Type: application/json' -d \"{\\\"destinataire\\\":\\\"Essai \$i\\\",\\\"depart\\\":\\\"Paris\\\",\\\"arrivee\\\":\\\"Lyon\\\",\\\"poids_kg\\\":1}\"; done; t0=\$(date +%s); until [ \"\$(\$K get deploy worker -o jsonpath='{.spec.replicas}')\" != 0 ]; do sleep 1; done; echo \"worker réveillé par KEDA après \$(( \$(date +%s)-t0 )) s\"; \$K rollout status deploy/worker --timeout=120s >/dev/null; sleep 20; echo \"file : \$(\$K exec deploy/redis -- redis-cli LLEN colis:a-estimer)\"; curl -s http://192.168.49.100/api/colis | python3 -c \"import json,sys; l=[c for c in json.load(sys.stdin) if c['destinataire'].startswith('Essai')]; print(len(l),'colis d essai,', sum(1 for c in l if c['statut']=='estimé'),'estimés')\"; \$K delete job purge-essai --ignore-not-found >/dev/null; \$K create job purge-essai --from=cronjob/purge >/dev/null; \$K wait --for=condition=Complete job/purge-essai --timeout=120s; \$K logs job/purge-essai | tail -1; echo '# l API vers Internet'; \$K exec deploy/api -- python3 -c \"import urllib.request; urllib.request.urlopen('http://example.com', timeout=4)\" 2>&1 | grep -v 'command terminated' | tail -1"
H a05-describe "kubectl -n colis describe networkpolicy api | sed -n '/^Spec:/,\$p'"
H a06-kindnet "minikube ssh -- 'sudo nft list table inet kindnet-network-policies' 2>/dev/null | sed -n '/set podips-v4/,/}/p;/chain postrouting/,/}/p'; kubectl -n colis get pods -o custom-columns=POD:.metadata.name,IP:.status.podIP --no-headers | grep -v '<none>'; kubectl -n kube-system logs ds/kindnet 2>/dev/null | grep -m3 'kube-network-policies\\|Policy engine'"
H a07-et-ou "kubectl apply -f curieux.yaml >/dev/null; kubectl -n keda wait --for=condition=Ready pod/curieux --timeout=240s >/dev/null; t() { kubectl -n keda exec curieux -- sh -c 'printf \"PING\\r\\n\" | nc -w 2 redis.colis.svc.cluster.local 6379 || echo \"(pas de réponse)\"' | tr -d '\\r' | tail -1; }; echo \"politique correcte : \$(t)\"; kubectl apply -f 50-redis-erreur.yaml; sleep 4; echo \"politique erronée   : \$(t)\"; kubectl apply -f 50-redis.yaml; sleep 4; echo \"politique corrigée  : \$(t)\"; kubectl -n keda delete pod curieux --wait=false >/dev/null"
H a08-ex-matrice "kubectl proxy --port=8011 >/dev/null & Q=\$!; sleep 1; python3 matrice.py colis; kill \$Q"
H a09-ex-https "K='kubectl -n colis'; o() { \$K exec deploy/api -- python3 -c \"import urllib.request
for u in ('https://example.com', 'http://example.com'):
    try: print(u, urllib.request.urlopen(u, timeout=4).status)
    except Exception as e: print(u, e)\" 2>&1 | grep -v 'command terminated'; }; echo '# avant'; o; kubectl apply -f api-https-sortant.yaml; sleep 4; echo '# après'; o; kubectl -n colis delete networkpolicy api-https-sortant >/dev/null"
