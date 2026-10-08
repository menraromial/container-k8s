#!/usr/bin/env python3
"""Un peu de trafic sur Colis, par la passerelle HTTPS du chapitre 28.

Usage : python3 charge.py [--duree 120] [--debit 8] [--ca ca.crt] [--passerelle 192.168.49.102]
Mélange : 20 % d'enregistrements, 50 % de listes, 20 % de lectures, 10 % de colis inexistants (404).
"""
import argparse
import json
import random
import socket
import ssl
import time
import urllib.error
import urllib.request

VILLES = ["Paris", "Lyon", "Marseille", "Brest", "Lille", "Toulouse"]


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--duree", type=float, default=120, help="secondes")
    p.add_argument("--debit", type=float, default=8, help="requêtes par seconde")
    p.add_argument("--base", default="https://colis.local/api")
    p.add_argument("--ca", help="certificat de l'autorité du chapitre 28 (sinon, pas de vérification)")
    p.add_argument("--passerelle", default="192.168.49.102",
                   help="adresse de la passerelle, utilisée pour colis.local (comme curl --resolve)")
    a = p.parse_args()
    resoudre = socket.getaddrinfo
    socket.getaddrinfo = lambda hote, *r, **k: resoudre(a.passerelle if hote == "colis.local" else hote, *r, **k)
    ctx = ssl.create_default_context(cafile=a.ca) if a.ca else ssl._create_unverified_context()
    codes: dict[int, int] = {}
    ids: list[int] = []
    fin = time.monotonic() + a.duree
    while time.monotonic() < fin:
        tirage = random.random()
        if tirage < 0.2:
            corps = {"destinataire": f"Client {random.randint(1, 500)}", "poids_kg": round(random.uniform(0.2, 30), 1),
                     "depart": random.choice(VILLES), "arrivee": random.choice(VILLES)}
            req = urllib.request.Request(a.base + "/colis", data=json.dumps(corps).encode(), method="POST",
                                         headers={"Content-Type": "application/json"})
        elif tirage < 0.7:
            req = urllib.request.Request(a.base + "/colis")
        elif tirage < 0.9 and ids:
            req = urllib.request.Request(f"{a.base}/colis/{random.choice(ids)}")
        else:
            req = urllib.request.Request(f"{a.base}/colis/{random.randint(900000, 999999)}")
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=5) as r:
                code = r.status
                if req.get_method() == "POST":
                    ids.append(json.load(r)["id"])
        except urllib.error.HTTPError as e:
            code = e.code
        except OSError:
            code = 0  # pas de réponse
        codes[code] = codes.get(code, 0) + 1
        time.sleep(1 / a.debit)
    print("réponses :", ", ".join(f"{c} x{n}" for c, n in sorted(codes.items())))


if __name__ == "__main__":
    main()
