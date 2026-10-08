#!/usr/bin/env python3
"""Mesure l'impact de l'incident pour les utilisateurs : combien de colis ont attendu leur date de
livraison, et combien de temps.

La création vient de la base (colonne cree_le), l'estimation du journal du worker dans Loki
(ligne « colis N : ... livraison estimée », champ colis). Le retard d'un colis est l'écart entre les deux.

Usage : python3 impact.py [--debut 2026-10-08T18:00:00Z] [--fin ...] [--loki http://localhost:3101]
(--debut lu dans debut-incident par défaut ; Loki joint par kubectl port-forward svc/loki 3101:3100)
"""
import argparse
import json
import statistics
import subprocess
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

NORMAL_S = 30  # au-delà, le colis a attendu plus que d'habitude (quelques secondes, démarrage du worker compris)


def instant(texte: str) -> datetime:
    return datetime.fromisoformat(texte.replace("Z", "+00:00"))


def creations(debut: datetime, fin: datetime) -> dict[int, datetime]:
    sql = (f"SELECT id, extract(epoch FROM cree_le) FROM colis "
           f"WHERE cree_le >= '{debut.isoformat()}' AND cree_le < '{fin.isoformat()}'")
    sortie = subprocess.run(["kubectl", "-n", "colis", "exec", "postgres-0", "--", "psql", "-U", "colis",
                             "-d", "colis", "-AtF", " ", "-c", sql], capture_output=True, text=True, check=True)
    res = {}
    for ligne in sortie.stdout.splitlines():
        id_, epoch = ligne.split()
        res[int(id_)] = datetime.fromtimestamp(float(epoch), timezone.utc)
    return res


def estimations(loki: str, debut: datetime, fin: datetime) -> dict[int, datetime]:
    requete = '{service_name="worker", k8s_namespace_name="colis"} | json | colis != ""'
    res: dict[int, datetime] = {}
    curseur = debut
    while True:  # Loki rend au plus 5000 lignes par appel : on avance par tranches
        params = urllib.parse.urlencode({"query": requete, "limit": 5000, "direction": "forward",
                                         "start": int(curseur.timestamp() * 1e9),
                                         "end": int(fin.timestamp() * 1e9)})
        with urllib.request.urlopen(f"{loki}/loki/api/v1/query_range?{params}", timeout=30) as r:
            flux = json.load(r)["data"]["result"]
        lignes = [(int(ts), json.loads(texte)) for f in flux for ts, texte in f["values"]]
        for _, l in lignes:
            id_, moment = int(l["colis"]), instant(l["moment"])
            res[id_] = min(res.get(id_, moment), moment)  # un colis estimé deux fois : la première compte
        if len(lignes) < 5000:
            return res
        curseur = datetime.fromtimestamp(max(ts for ts, _ in lignes) / 1e9 + 1e-6, timezone.utc)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--debut", help="début de l'incident (ISO 8601) ; défaut : fichier debut-incident")
    p.add_argument("--fin", help="fin de la période d'enregistrement étudiée ; défaut : maintenant")
    p.add_argument("--loki", default="http://localhost:3101")
    a = p.parse_args()
    debut = instant(a.debut or (Path(__file__).resolve().parent.parent / "debut-incident").read_text().strip())
    fin = instant(a.fin) if a.fin else datetime.now(timezone.utc)
    crees = creations(debut, fin)
    estimes = estimations(a.loki, debut, datetime.now(timezone.utc) + timedelta(minutes=1))
    retards = sorted((estimes[i] - c).total_seconds() for i, c in crees.items() if i in estimes)
    jamais = [i for i in crees if i not in estimes]
    print(f"période : {debut:%H:%M:%S} -> {fin:%H:%M:%S} UTC")
    print(f"colis enregistrés : {len(crees)}")
    print(f"  estimés         : {len(retards)}")
    print(f"  jamais estimés  : {len(jamais)}{' (' + ', '.join(map(str, sorted(jamais)[:10])) + ')' if jamais else ''}")
    if retards:
        en_retard = [r for r in retards if r > NORMAL_S]
        print(f"retard médian     : {statistics.median(retards):.0f} s")
        print(f"retard p95        : {retards[min(len(retards) - 1, int(0.95 * len(retards)))]:.0f} s")
        print(f"retard maximal    : {retards[-1]:.0f} s ({retards[-1] / 60:.1f} min)")
        print(f"plus de {NORMAL_S} s     : {len(en_retard)} colis ({100 * len(en_retard) / len(retards):.0f} %)")


if __name__ == "__main__":
    main()
