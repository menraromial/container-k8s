#!/usr/bin/env python3
"""Corrigé de l'exercice 3 du chapitre 49 : le palmarès des avertissements d'un cluster.

Usage : python3 palmares.py [namespace] [--top N]
Regroupe les événements Warning dont le message ne diffère que par des détails variables
(adresses, nombres, identifiants, noms de Pods générés), et les classe par nombre d'occurrences.
"""
import argparse
import json
import re
import subprocess
from collections import defaultdict

VARIABLES = [
    (re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"), "<uid>"),
    (re.compile(r"\b(\d{1,3}\.){3}\d{1,3}(:\d+)?\b"), "<ip>"),
    (re.compile(r"\b[0-9a-f]{12,64}\b"), "<id>"),
    (re.compile(r"\b[a-z0-9-]+-[a-z0-9]{8,10}-[a-z0-9]{5}(?![a-z0-9-])"), "<pod>"),  # nom de Pod d'un Deployment
    (re.compile(r"\b\d+(\.\d+)?(ms|s|m|h|Mi|Gi|Ki)?\b"), "<n>"),
]


def normaliser(message: str) -> str:
    for motif, remplacement in VARIABLES:
        message = motif.sub(remplacement, message)
    return message


def occurrences(ev: dict) -> int:
    serie = ev.get("series") or {}
    return serie.get("count") or ev.get("count") or 1


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("namespace", nargs="?")
    p.add_argument("--top", type=int, default=10)
    a = p.parse_args()
    portee = ["-n", a.namespace] if a.namespace else ["-A"]
    evs = json.loads(subprocess.run(["kubectl", "get", "events", *portee, "-o", "json"],
                                    check=True, capture_output=True, text=True).stdout)["items"]
    groupes = defaultdict(lambda: {"total": 0, "objets": set()})
    for ev in evs:
        if ev.get("type") != "Warning":
            continue
        cle = (ev.get("reason", "?"), normaliser(ev.get("message", "")))
        groupes[cle]["total"] += occurrences(ev)
        objet = ev["involvedObject"]
        groupes[cle]["objets"].add(f"{objet.get('kind')}/{objet.get('name')}")
    classes = sorted(groupes.items(), key=lambda g: g[1]["total"], reverse=True)[: a.top]
    print(f"{'NB':>4} {'OBJ':>3}  RAISON : MESSAGE")
    for (raison, message), g in classes:
        print(f"{g['total']:>4} {len(g['objets']):>3}  {raison} : {message[:120]}")


if __name__ == "__main__":
    main()
