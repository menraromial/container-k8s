#!/bin/sh
# Simuler trois zones de disponibilité : une par nœud du profil minikube « deux-noeuds » (chapitre 32).
kubectl label nodes --all disque-
kubectl label node deux-noeuds     topology.kubernetes.io/zone=zone-a --overwrite
kubectl label node deux-noeuds-m02 topology.kubernetes.io/zone=zone-b --overwrite
kubectl label node deux-noeuds-m03 topology.kubernetes.io/zone=zone-c --overwrite
kubectl label node deux-noeuds-m03 disque=ssd --overwrite
