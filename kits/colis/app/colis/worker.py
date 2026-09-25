"""Le worker : prend les colis dans la file et calcule leur date de livraison."""
from __future__ import annotations

import os
import signal
import socket
import sys
import time
from datetime import date

from .config import file_depuis_env, stockage_depuis_env
from .delais import VilleInconnue, date_estimee, jours_de_livraison

continuer = True


def arreter(signum: int, _frame: object) -> None:
    global continuer
    print(f"signal {signal.Signals(signum).name} reçu, arrêt après le colis en cours", flush=True)
    continuer = False


def main() -> int:
    signal.signal(signal.SIGTERM, arreter)
    signal.signal(signal.SIGINT, arreter)
    file = file_depuis_env()
    if file is None:
        print("COLIS_REDIS n'est pas défini : le worker n'a pas de file à lire", file=sys.stderr)
        return 1
    stockage = stockage_depuis_env()
    # temps de calcul simulé, pour rendre visible l'effet du nombre de workers
    pause = float(os.environ.get("COLIS_WORKER_PAUSE", "0.5"))
    nom = socket.gethostname()
    print(f"worker {nom} prêt (stockage : {stockage.nom})", flush=True)
    while continuer:
        id_ = file.prendre(attente_s=2)
        if id_ is None:
            continue
        colis = stockage.lire(id_)
        if colis is None:
            continue
        time.sleep(pause)
        try:
            livraison = date_estimee(colis.depart, colis.arrivee, colis.poids_kg, date.today())
        except VilleInconnue as exc:
            print(f"colis {id_} : ville inconnue {exc}", flush=True)
            continue
        stockage.estimer(id_, livraison)
        jours = jours_de_livraison(colis.depart, colis.arrivee, colis.poids_kg)
        print(f"colis {id_} : {colis.depart} -> {colis.arrivee}, {jours} jours, "
              f"livraison estimée le {livraison}", flush=True)
    print(f"worker {nom} arrêté", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
