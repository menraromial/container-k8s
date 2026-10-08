#!/usr/bin/env python3
"""Corrigé de l'exercice 3 du chapitre 50 : les requests de mémoire face à la consommation mesurée.

Usage : python3 dimensionner.py [namespace] [--prometheus http://localhost:9095] [--periode 1h]
Pour chaque conteneur (tous Pods confondus : les Pods d'un Deployment passent, le modèle reste) :
le maximum de mémoire utilisée sur la période (working set, ce que regarde le noyau avant de tuer),
la request et la limite déclarées par les Pods actuels, et une request proposée (maximum + 20 %).
"""
import argparse
import json
import urllib.parse
import urllib.request

MIO = 2 ** 20


def requete(base: str, promql: str) -> dict[tuple[str, str], float]:
    url = f"{base}/api/v1/query?" + urllib.parse.urlencode({"query": promql})
    with urllib.request.urlopen(url, timeout=10) as r:
        resultat = json.load(r)["data"]["result"]
    return {s["metric"]["container"]: float(s["value"][1]) for s in resultat}


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("namespace", nargs="?", default="colis")
    p.add_argument("--prometheus", default="http://localhost:9095")
    p.add_argument("--periode", default="1h")
    a = p.parse_args()
    ns, per = a.namespace, a.periode
    utilise = requete(a.prometheus, f'max by (container) (max_over_time('
                                    f'container_memory_working_set_bytes{{namespace="{ns}", container!=""}}[{per}]))')
    demande = requete(a.prometheus, f'max by (container) (kube_pod_container_resource_requests'
                                    f'{{namespace="{ns}", resource="memory"}})')
    limite = requete(a.prometheus, f'max by (container) (kube_pod_container_resource_limits'
                                   f'{{namespace="{ns}", resource="memory"}})')
    actuels = requete(a.prometheus, f'count by (container) (kube_pod_container_info{{namespace="{ns}"}})')
    print(f"{'CONTENEUR':12} {'PODS':>4} {'MAX':>7} {'REQUEST':>8} {'LIMITE':>7} {'UTILISÉ':>8}  PROPOSITION")
    for cle in sorted(utilise):
        u, d, l = utilise[cle] / MIO, demande.get(cle, 0) / MIO, limite.get(cle, 0) / MIO
        part = f"{u / d:7.0%}" if d else "      -"
        if cle not in actuels:
            avis = "aucun Pod en ce moment : requests inconnues"
        elif not d:
            avis = "aucune request : à déclarer"
        elif l and u > 0.9 * l:
            avis = "proche de la limite : risque d'OOMKilled"
        elif u < 0.5 * d:
            avis = f"request à ramener vers {u * 1.2:.0f} Mio"
        else:
            avis = "correct"
        print(f"{cle:12} {actuels.get(cle, 0):4.0f} {u:6.0f}M {d:7.0f}M {l:6.0f}M {part}  {avis}")


if __name__ == "__main__":
    main()
