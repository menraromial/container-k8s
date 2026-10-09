#!/usr/bin/env python3
"""Mesure le retard de chaque réplique d'un cluster CloudNativePG, vu de la primaire.

Le script trouve la primaire dans le statut du Cluster, interroge pg_stat_replication par
kubectl exec, et affiche pour chaque réplique l'état, le retard en octets (WAL produit mais pas
encore rejoué) et en temps. Il sort avec le code 1 si une réplique dépasse le seuil, ou s'il en
manque une.

Usage : python3 retard-replication.py -n colis colis-pg [--seuil-octets 16777216] [--repetitions 1]
"""
import argparse
import json
import subprocess
import sys
import time

REQUETE = ("SELECT application_name, state, sync_state, "
           "pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)::bigint, "
           "COALESCE(extract(epoch FROM replay_lag), 0) FROM pg_stat_replication ORDER BY 1")


def kubectl(*args: str) -> str:
    return subprocess.run(["kubectl", *args], capture_output=True, text=True, check=True).stdout


def mesure(ns: str, cluster: str) -> tuple[str, int, list[tuple]]:
    statut = json.loads(kubectl("-n", ns, "get", "cluster", cluster, "-o", "json"))
    primaire = statut["status"]["currentPrimary"]
    attendues = statut["spec"]["instances"] - 1
    sortie = kubectl("-n", ns, "exec", primaire, "-c", "postgres", "--",
                     "psql", "-U", "postgres", "-qtAF", "|", "-c", REQUETE)
    lignes = [l.split("|") for l in sortie.splitlines() if l.strip()]
    return primaire, attendues, [(n, e, s, int(o), float(t)) for n, e, s, o, t in lignes]


def taille(octets: int) -> str:
    for unite in ("o", "Kio", "Mio", "Gio"):
        if octets < 1024 or unite == "Gio":
            return f"{octets:.0f} {unite}" if unite == "o" else f"{octets:.1f} {unite}"
        octets /= 1024
    return ""


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("cluster")
    p.add_argument("-n", "--namespace", default="default")
    p.add_argument("--seuil-octets", type=int, default=16 * 1024 * 1024)
    p.add_argument("--repetitions", type=int, default=1)
    p.add_argument("--intervalle", type=float, default=1.0)
    a = p.parse_args()
    code = 0
    for i in range(a.repetitions):
        primaire, attendues, repliques = mesure(a.namespace, a.cluster)
        print(f"{time.strftime('%H:%M:%S')}  primaire {primaire}, {len(repliques)}/{attendues} répliques connectées")
        for nom, etat, sync, octets, secondes in repliques:
            alerte = "  TROP EN RETARD" if octets > a.seuil_octets else ""
            print(f"    {nom:<14} {etat:<10} {sync:<6} {taille(octets):>10}  {secondes:6.2f} s{alerte}")
            if alerte:
                code = 1
        if len(repliques) < attendues:
            code = 1
        if i < a.repetitions - 1:
            time.sleep(a.intervalle)
    return code


if __name__ == "__main__":
    sys.exit(main())
