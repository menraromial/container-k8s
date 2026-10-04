#!/usr/bin/env python3
"""Pour chaque namespace : les étiquettes Pod Security actuelles, et le niveau le plus strict
que tous ses Pods respectent déjà.

La vérification est confiée à l'API server : un étiquetage à blanc (--dry-run=server) renvoie
un avertissement par namespace dont des Pods violeraient le niveau demandé.
"""
import json
import re
import subprocess

NIVEAUX = ["restricted", "baseline"]
CLE = "pod-security.kubernetes.io/"


def kubectl(*args):
    r = subprocess.run(["kubectl", *args], capture_output=True, text=True, check=True)
    return r.stdout, r.stderr


def namespaces_en_infraction(niveau):
    _, erreurs = kubectl("label", "--dry-run=server", "--overwrite", "ns", "--all",
                         f"{CLE}enforce={niveau}")
    return set(re.findall(r'existing pods in namespace "([^"]+)" violate', erreurs))


def main():
    sortie, _ = kubectl("get", "ns", "-o", "json")
    espaces = {n["metadata"]["name"]: n["metadata"].get("labels", {}) for n in json.loads(sortie)["items"]}
    infractions = {niveau: namespaces_en_infraction(niveau) for niveau in NIVEAUX}
    sortie, _ = kubectl("get", "pods", "-A", "-o", "json")
    pods = {}
    for p in json.loads(sortie)["items"]:
        pods[p["metadata"]["namespace"]] = pods.get(p["metadata"]["namespace"], 0) + 1

    print(f"{'namespace':<22} {'Pods':>4}  {'enforce':<12} {'warn':<12} {'niveau atteint':<14}")
    for nom in sorted(espaces):
        etiquettes = espaces[nom]
        atteint = next((n for n in NIVEAUX if nom not in infractions[n]), "privileged")
        enforce = etiquettes.get(CLE + "enforce", "-")
        warn = etiquettes.get(CLE + "warn", "-")
        conseil = ""
        if not pods.get(nom):
            atteint, conseil = "-", "  (aucun Pod : rien à vérifier)"
        elif enforce == "-" and atteint != "privileged":
            conseil = f"  <- prêt pour enforce={atteint}"
        print(f"{nom:<22} {pods.get(nom, 0):>4}  {enforce:<12} {warn:<12} {atteint:<14}{conseil}")


if __name__ == "__main__":
    main()
