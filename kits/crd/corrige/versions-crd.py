#!/usr/bin/env python3
"""Fait l'état des versions de chaque CustomResourceDefinition d'un cluster.

Pour chaque définition : la version stockée, les versions servies (dépréciées marquées d'une *),
et les versions encore présentes dans etcd (status.storedVersions). Signale celles qui demandent
une migration avant qu'on puisse retirer une version, et compte les objets si --objets est donné.

Usage : python3 versions-crd.py [--objets] [--tout]
(--tout affiche aussi les définitions sans rien à signaler)
"""
import argparse
import json
import subprocess
import sys


def kubectl(*args: str) -> str:
    return subprocess.run(["kubectl", *args], capture_output=True, text=True, check=True).stdout


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--objets", action="store_true", help="compter les objets de chaque type (plus lent)")
    p.add_argument("--tout", action="store_true", help="afficher aussi les définitions en règle")
    a = p.parse_args()
    crds = json.loads(kubectl("get", "crd", "-o", "json"))["items"]
    a_migrer = 0
    lignes = []
    for crd in sorted(crds, key=lambda c: c["metadata"]["name"]):
        nom = crd["metadata"]["name"]
        versions = crd["spec"]["versions"]
        stockee = next(v["name"] for v in versions if v["storage"])
        servies = [v["name"] + ("*" if v.get("deprecated") else "") for v in versions if v["served"]]
        dans_etcd = crd.get("status", {}).get("storedVersions", [])
        anciennes = [v for v in dans_etcd if v != stockee]
        if anciennes:
            a_migrer += 1
        if not (anciennes or a.tout):
            continue
        objets = ""
        if a.objets:
            sortie = subprocess.run(["kubectl", "get", nom, "-A", "--no-headers", "--ignore-not-found"],
                                    capture_output=True, text=True).stdout
            objets = str(len(sortie.splitlines()))
        etat = f"migrer {','.join(anciennes)} -> {stockee}" if anciennes else "ok"
        lignes.append((nom, stockee, ",".join(servies), ",".join(dans_etcd), objets, etat))
    entete = ("DÉFINITION", "STOCKÉE", "SERVIES", "DANS ETCD", "OBJETS" if a.objets else "", "ÉTAT")
    largeurs = [max(len(l[i]) for l in [entete, *lignes]) for i in range(6)]
    for l in [entete, *lignes]:
        print("  ".join(c.ljust(w) for c, w in zip(l, largeurs) if w).rstrip())
    print(f"\n{len(crds)} définitions, {a_migrer} à migrer")
    return 1 if a_migrer else 0


if __name__ == "__main__":
    sys.exit(main())
