"""Le worker : prend les colis dans la file et calcule leur date de livraison."""
from __future__ import annotations

import os
import signal
import socket
import sys
import time
from datetime import date

from opentelemetry import trace
from prometheus_client import start_http_server

from .config import file_depuis_env, stockage_depuis_env
from .delais import VilleInconnue, date_estimee, jours_de_livraison
from .observabilite import ESTIMES, configurer_traces, journal, mesurer_file

log = journal("colis.worker")
traceur = trace.get_tracer("colis.worker")

continuer = True


def arreter(signum: int, _frame: object) -> None:
    global continuer
    log.info(f"signal {signal.Signals(signum).name} reçu, arrêt après le colis en cours")
    continuer = False


def main() -> int:
    signal.signal(signal.SIGTERM, arreter)
    signal.signal(signal.SIGINT, arreter)
    file = file_depuis_env()
    if file is None:
        log.error("COLIS_REDIS n'est pas défini : le worker n'a pas de file à lire")
        return 1
    stockage = stockage_depuis_env()
    # temps de calcul simulé, pour rendre visible l'effet du nombre de workers
    pause = float(os.environ.get("COLIS_WORKER_PAUSE", "0.5"))
    nom = socket.gethostname()
    # métriques du worker sur un port à lui (le worker n'a pas de serveur HTTP)
    start_http_server(int(os.environ.get("COLIS_METRIQUES_PORT", "9101")))
    mesurer_file(file)
    configurer_traces()
    log.info(f"worker {nom} prêt (stockage : {stockage.nom})")
    while continuer:
        id_ = file.prendre(attente_s=2)
        if id_ is None:
            continue
        with traceur.start_as_current_span("estimer un colis", attributes={"colis.id": id_}):
            traiter(stockage, id_, pause)
    log.info(f"worker {nom} arrêté")
    return 0


def traiter(stockage, id_: int, pause: float) -> None:
    """Calcule et enregistre la date de livraison d'un colis pris dans la file."""
    colis = stockage.lire(id_)
    if colis is None:
        return
    time.sleep(pause)
    try:
        livraison = date_estimee(colis.depart, colis.arrivee, colis.poids_kg, date.today())
    except VilleInconnue as exc:
        log.warning(f"colis {id_} : ville inconnue {exc}")
        return
    stockage.estimer(id_, livraison)
    ESTIMES.labels("worker").inc()
    jours = jours_de_livraison(colis.depart, colis.arrivee, colis.poids_kg)
    log.info(f"colis {id_} : {colis.depart} -> {colis.arrivee}, {jours} jours, "
             f"livraison estimée le {livraison}",
             extra={"champs": {"colis": id_, "jours": jours}})


if __name__ == "__main__":
    sys.exit(main())
