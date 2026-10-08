#!/usr/bin/env python3
"""Corrigé de l'exercice 2 du chapitre 53 : des manifestes que le cluster ne saurait pas appliquer.

Usage : python3 apis-manquantes.py <dossier> [--contexte montee]
Lit tous les fichiers .yaml du dossier (documents multiples compris), relève les couples
apiVersion et kind, et les compare à ce que sert le cluster (kubectl api-resources).
Un couple absent est soit une API retirée, soit une ressource personnalisée non installée.
"""
import argparse
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

import yaml


def servis(contexte):
    sortie = subprocess.run(["kubectl", "--context", contexte, "api-resources", "--no-headers"],
                            check=True, capture_output=True, text=True).stdout
    couples = set()
    for ligne in sortie.splitlines():
        champs = ligne.split()
        # NAME [SHORTNAMES] APIVERSION NAMESPACED KIND : la colonne des abréviations peut manquer
        couples.add((champs[-3], champs[-1]))
    return couples


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("dossier")
    p.add_argument("--contexte", default="montee")
    a = p.parse_args()
    connus = servis(a.contexte)
    manquants = defaultdict(list)
    lus, illisibles = 0, []
    for f in sorted(Path(a.dossier).rglob("*.yaml")):
        try:
            documents = list(yaml.safe_load_all(f.read_text()))
        except yaml.YAMLError:
            illisibles.append(f)          # gabarits Helm, par exemple
            continue
        for d in documents:
            if not isinstance(d, dict) or "apiVersion" not in d or "kind" not in d:
                continue
            lus += 1
            if (d["apiVersion"], d["kind"]) not in connus:
                manquants[(d["apiVersion"], d["kind"])].append(str(f.relative_to(a.dossier)))
    print(f"{lus} objets lus, {len(illisibles)} fichiers illisibles (gabarits), "
          f"{sum(map(len, manquants.values()))} objets non servis par « {a.contexte} »")
    for (version, kind), fichiers in sorted(manquants.items()):
        print(f"  {version:42} {kind:28} {len(fichiers):3} fichier(s), ex. {fichiers[0]}")
    return 1 if manquants else 0


if __name__ == "__main__":
    sys.exit(main())
