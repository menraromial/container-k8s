#!/usr/bin/env python3
"""Fait l'état des Applications d'Argo CD, comparées à leur dépôt.

Pour chaque Application : son état de synchronisation et de santé, la révision déployée, et la
dernière révision de la branche suivie, lue directement dans le dépôt par git ls-remote. Signale
les applications en retard sur leur dépôt, désynchronisées ou en mauvaise santé, et sort avec
le code 1 s'il en trouve.

Usage : python3 etat-gitops.py [--depot-local URL_DU_DEPOT=URL_JOIGNABLE ...]
(le dépôt déclaré dans l'Application est l'adresse vue du cluster ; --depot-local donne une
adresse joignable depuis le poste, par exemple à travers une redirection de port)
"""
import argparse
import json
import subprocess
import sys


def kubectl(*args: str) -> str:
    return subprocess.run(["kubectl", *args], capture_output=True, text=True, check=True).stdout


def tete(url: str, branche: str) -> str:
    sortie = subprocess.run(["git", "ls-remote", url, branche], capture_output=True, text=True, timeout=20)
    if sortie.returncode != 0 or not sortie.stdout.strip():
        return "?"
    return sortie.stdout.split()[0]


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--depot-local", action="append", default=[], metavar="URL=URL")
    a = p.parse_args()
    traduction = dict(x.split("=", 1) for x in a.depot_local)
    apps = json.loads(kubectl("get", "applications.argoproj.io", "-A", "-o", "json"))["items"]
    lignes, en_defaut = [], 0
    for app in sorted(apps, key=lambda x: x["metadata"]["name"]):
        source = app["spec"].get("source", {})
        statut = app.get("status", {})
        url, branche = source.get("repoURL", ""), source.get("targetRevision", "HEAD")
        # status.sync.revision est la dernière révision COMPARÉE ; la révision DÉPLOYÉE est celle
        # de la dernière synchronisation réussie, en tête de l'historique
        historique = statut.get("history") or []
        deployee = historique[-1].get("revision", "") if historique else "?"
        derniere = tete(traduction.get(url, url), branche)
        sync = statut.get("sync", {}).get("status", "?")
        sante = statut.get("health", {}).get("status", "?")
        auto = "auto" if app["spec"].get("syncPolicy", {}).get("automated") is not None else "manuel"
        problemes = []
        if derniere != "?" and deployee != derniere:
            problemes.append("en retard sur le dépôt")
        if sync != "Synced":
            problemes.append("désynchronisée")
        if sante != "Healthy":
            problemes.append(f"santé {sante}")
        en_defaut += bool(problemes)
        lignes.append((app["metadata"]["name"], auto, sync, sante, deployee[:7], derniere[:7],
                       ", ".join(problemes) or "ok"))
    entete = ("APPLICATION", "MODE", "SYNC", "SANTÉ", "DÉPLOYÉE", "DÉPÔT", "ÉTAT")
    largeurs = [max(len(l[i]) for l in [entete, *lignes]) for i in range(len(entete))]
    for l in [entete, *lignes]:
        print("  ".join(c.ljust(w) for c, w in zip(l, largeurs)).rstrip())
    print(f"\n{len(lignes)} applications, {en_defaut} à regarder")
    return 1 if en_defaut else 0


if __name__ == "__main__":
    sys.exit(main())
