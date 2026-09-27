#!/usr/bin/env bash
# Défi V : suivre un Deployment de kubectl apply au processus. Profil principal. Namespace defi5 (recréé).
cd "$(dirname "$0")"; O=$PWD/out/defi5; rm -rf $O; mkdir -p $O; cp -a ../kits/defi-5 $O/m
export PATH=~/.local/opt/cours-k8s/bin:$PATH LC_ALL=C
kubectl config use-context minikube >/dev/null
(cd $O/m/corrige && ./chronologie.sh) > $O/01-chronologie.txt 2>&1
(cd $O/m && ./verifier.sh defi5 temoin) > $O/02-grille.txt 2>&1
kubectl -n defi5 get rs -o jsonpath='{.items[0].metadata.ownerReferences[0].kind}/{.items[0].metadata.ownerReferences[0].name}{"\n"}' > $O/03-proprietaires.txt
kubectl -n defi5 get pods -o jsonpath='{range .items[*]}{.metadata.name} <- {.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}{end}' >> $O/03-proprietaires.txt
cat $O/01-chronologie.txt $O/02-grille.txt
