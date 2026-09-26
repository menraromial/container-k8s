#!/usr/bin/env bash
# Affiche, à chaque changement, les ReplicaSets de « vitrine » du namespace courant :
# image=voulus/prêts/disponibles. Usage : ./suivre.sh <durée en secondes>
export LC_ALL=C
t0=$(date +%s%N); last=''; fin=$(( $(date +%s) + ${1:-60} ))
while [ $(date +%s) -lt $fin ]; do
  s=$(kubectl get rs -l app.kubernetes.io/name=vitrine -o jsonpath='{range .items[*]}{.spec.template.spec.containers[0].image}={.spec.replicas}/{.status.readyReplicas}/{.status.availableReplicas}  {end}' | sed 's/nginx://g; s/-alpine//g')
  if [ "$s" != "$last" ]; then printf 't=%5.1f s : %s\n' "$(echo "($(date +%s%N)-$t0)/1000000000" | bc -l)" "$s"; last=$s; fi
  sleep 0.3
done
