#!/usr/bin/env python3
"""Interroge une adresse toutes les 200 ms et résume la disponibilité vue de l'extérieur.

Usage : python3 sonde.py http://IP:30080/ fichier.log      (s'arrête sur SIGTERM ou Ctrl+C)
        python3 sonde.py --resume fichier.log
"""
import signal
import sys
import time
import urllib.request


def sonder(url, chemin):
    arret = []
    signal.signal(signal.SIGTERM, lambda *_: arret.append(1))
    with open(chemin, "w") as f:
        while not arret:
            t = time.time()
            try:
                with urllib.request.urlopen(url, timeout=1) as r:
                    code = r.status
            except Exception as e:  # refus, délai dépassé, 5xx
                code = getattr(e, "code", 0)
            f.write(f"{t:.3f} {code}\n")
            f.flush()
            time.sleep(max(0, 0.2 - (time.time() - t)))


def resumer(chemin):
    mesures = [(float(t), int(c)) for t, c in (l.split() for l in open(chemin))]
    echecs = [m for m in mesures if m[1] != 200]
    t0 = mesures[0][0]
    coupures, debut = [], None
    for t, c in mesures:
        if c != 200 and debut is None:
            debut = t
        elif c == 200 and debut is not None:
            coupures.append((debut - t0, t - debut))
            debut = None
    if debut is not None:
        coupures.append((debut - t0, mesures[-1][0] - debut))
    duree = mesures[-1][0] - t0
    plus_long = max((d for _, d in coupures), default=0.0)
    print(f"{len(mesures)} requêtes en {duree:.0f} s, {len(echecs)} en échec "
          f"({100 * len(echecs) / len(mesures):.1f} %), plus longue interruption : {plus_long:.1f} s")
    for debut, d in coupures:
        if d >= 1:
            print(f"  interruption de {d:5.1f} s à partir de t+{debut:.0f} s")


if __name__ == "__main__":
    if sys.argv[1] == "--resume":
        resumer(sys.argv[2])
    else:
        sonder(sys.argv[1], sys.argv[2])
