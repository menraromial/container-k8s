#!/usr/bin/env python3
"""Mesure la part du trafic reçue par chaque version, et la compare au poids annoncé par la route.

Le script envoie N requêtes à /version d'un hôte servi par la passerelle, compte les versions,
lit les poids de la HTTPRoute, et donne pour la version canari un intervalle de confiance à 95 %
(méthode de Wilson). Il sort avec le code 1 si le poids annoncé est hors de l'intervalle.

Usage : python3 repartition.py [-n 400] [--hote vitrine.local] [--passerelle 192.168.49.102]
                               [--route ch58/vitrine] [--canari vitrine-canari]
"""
import argparse
import json
import math
import socket
import subprocess
import sys
import urllib.request
from collections import Counter


def wilson(succes: int, n: int, z: float = 1.96) -> tuple[float, float]:
    if n == 0:
        return 0.0, 1.0
    p = succes / n
    centre = (p + z * z / (2 * n)) / (1 + z * z / n)
    marge = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / (1 + z * z / n)
    return max(0.0, centre - marge), min(1.0, centre + marge)


def poids(route: str, canari: str) -> tuple[int, int]:
    ns, nom = route.split("/")
    r = json.loads(subprocess.run(["kubectl", "-n", ns, "get", "httproute", nom, "-o", "json"],
                                  capture_output=True, text=True, check=True).stdout)
    refs = r["spec"]["rules"][0]["backendRefs"]
    total = sum(b.get("weight", 1) for b in refs)
    return next((b.get("weight", 1) for b in refs if b["name"] == canari), 0), total


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("-n", type=int, default=400)
    p.add_argument("--hote", default="vitrine.local")
    p.add_argument("--passerelle", default="192.168.49.102")
    p.add_argument("--route", default="ch58/vitrine")
    p.add_argument("--canari", default="vitrine-canari")
    a = p.parse_args()
    resoudre = socket.getaddrinfo
    socket.getaddrinfo = lambda h, *r, **k: resoudre(a.passerelle if h == a.hote else h, *r, **k)
    versions: Counter[str] = Counter()
    for _ in range(a.n):
        try:
            with urllib.request.urlopen(f"http://{a.hote}/version", timeout=2) as r:
                versions[json.load(r).get("version", "?")] += 1
        except OSError:
            versions["erreur"] += 1
    w, total = poids(a.route, a.canari)
    attendu = w / total if total else 0.0
    print(f"{a.n} requêtes vers {a.hote}, poids annoncé pour {a.canari} : {w}/{total} ({attendu:.0%})")
    for v, c in sorted(versions.items()):
        print(f"  {v:<10} {c:>5}  {c / a.n:6.1%}")
    # la version canari est la moins servie quand le poids est sous 50 %, la plus servie sinon
    candidates = [v for v in versions if v != "erreur"]
    if len(candidates) < 2:
        print("une seule version servie")
        return 0 if attendu in (0.0, 1.0) else 1
    canari = min(candidates, key=versions.get) if attendu < 0.5 else max(candidates, key=versions.get)
    bas, haut = wilson(versions[canari], a.n)
    ok = bas <= attendu <= haut
    print(f"part de {canari} : {versions[canari] / a.n:.1%}, intervalle à 95 % [{bas:.1%} ; {haut:.1%}] : "
          f"{'compatible' if ok else 'INCOMPATIBLE'} avec {attendu:.0%}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
