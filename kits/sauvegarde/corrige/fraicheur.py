#!/usr/bin/env python3
"""Corrigé de l'exercice 3 du chapitre 52 : les sauvegardes Velero sont-elles fraîches et saines ?

Usage : python3 fraicheur.py [--age-max 26] [--namespace velero]
Pour chaque planification (Schedule), et pour les sauvegardes lancées à la main : la dernière
sauvegarde réussie, son âge, ses avertissements. Code de sortie 1 si une planification n'a pas de
sauvegarde réussie de moins de --age-max heures : de quoi en faire une tâche planifiée ou une alerte.
"""
import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone


def kubectl(*args):
    return json.loads(subprocess.run(["kubectl", *args, "-o", "json"], check=True,
                                     capture_output=True, text=True).stdout)["items"]


def date(texte):
    return datetime.fromisoformat(texte.replace("Z", "+00:00")) if texte else None


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--age-max", type=float, default=26, help="heures (une sauvegarde quotidienne, plus une marge)")
    p.add_argument("--namespace", default="velero")
    a = p.parse_args()
    maintenant = datetime.now(timezone.utc)
    sauvegardes = kubectl("-n", a.namespace, "get", "backups.velero.io")
    plans = [s["metadata"]["name"] for s in kubectl("-n", a.namespace, "get", "schedules.velero.io")]
    groupes = {nom: [] for nom in plans}
    groupes["(à la main)"] = []
    for b in sauvegardes:
        plan = b["metadata"].get("labels", {}).get("velero.io/schedule-name", "(à la main)")
        groupes.setdefault(plan, []).append(b)
    probleme = False
    print(f"{'PLANIFICATION':18} {'DERNIÈRE RÉUSSIE':20} {'ÂGE':>7}  {'AVERT.':>6}  ÉTAT")
    for plan, liste in groupes.items():
        reussies = sorted((b for b in liste if b.get("status", {}).get("phase") == "Completed"),
                          key=lambda b: b["status"]["completionTimestamp"])
        echecs = [b["metadata"]["name"] for b in liste
                  if b.get("status", {}).get("phase") in ("Failed", "PartiallyFailed", "FailedValidation")]
        if not reussies:
            etat = "AUCUNE SAUVEGARDE RÉUSSIE" if plan != "(à la main)" or liste else "-"
            probleme |= plan != "(à la main)"
            print(f"{plan:18} {'-':20} {'-':>7}  {'-':>6}  {etat}")
            continue
        derniere = reussies[-1]
        age = (maintenant - date(derniere["status"]["completionTimestamp"])).total_seconds() / 3600
        avert = derniere["status"].get("warnings", 0)
        trop_vieille = plan != "(à la main)" and age > a.age_max
        probleme |= trop_vieille
        etat = "TROP VIEILLE" if trop_vieille else "ok"
        if avert:
            etat += f", avertissements à lire (velero backup logs {derniere['metadata']['name']})"
        if echecs:
            etat += f", échecs : {', '.join(echecs)}"
        print(f"{plan:18} {derniere['metadata']['name']:20} {age:6.1f}h  {avert:>6}  {etat}")
    return 1 if probleme else 0


if __name__ == "__main__":
    sys.exit(main())
