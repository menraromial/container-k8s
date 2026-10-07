#!/usr/bin/env python3
"""Remplace la ligne CLE_PUBLIQUE d'un modèle de politique par une clé publique PEM, correctement indentée.
Usage : avec-cle.py MODELE CLE.pub > politique.yaml"""
import sys

modele, cle = open(sys.argv[1]).read(), open(sys.argv[2]).read().strip().splitlines()
sortie = []
for ligne in modele.splitlines():
    if ligne.strip() == "CLE_PUBLIQUE":
        retrait = " " * (len(ligne) - len(ligne.lstrip()))
        sortie += [retrait + l for l in cle]
    else:
        sortie.append(ligne)
print("\n".join(sortie))
