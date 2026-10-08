"""Estimation du délai de livraison entre deux villes.

Le calcul est volontairement simple : distance à vol d'oiseau, majorée de
30 % pour tenir compte des routes, puis un jour de transport par tranche
de 500 km, plus un jour de préparation. Un colis de plus de 20 kg part
par un circuit plus lent et prend un jour de plus.
"""
from __future__ import annotations

import math
from datetime import date, timedelta

# latitude, longitude en degrés
VILLES: dict[str, tuple[float, float]] = {
    "Bordeaux": (44.8378, -0.5792),
    "Brest": (48.3904, -4.4861),
    "Bruxelles": (50.8503, 4.3517),
    "Genève": (46.2044, 6.1432),
    "Lille": (50.6292, 3.0573),
    "Luxembourg": (49.6116, 6.1319),
    "Lyon": (45.7640, 4.8357),
    "Marseille": (43.2965, 5.3698),
    "Nantes": (47.2184, -1.5536),
    "Nice": (43.7102, 7.2620),
    "Paris": (48.8566, 2.3522),
    "Rennes": (48.1173, -1.6778),
    "Strasbourg": (48.5734, 7.7521),
    "Toulouse": (43.6047, 1.4442),
}

RAYON_TERRE_KM = 6371.0
FACTEUR_ROUTE = 1.3
KM_PAR_JOUR = 500
POIDS_LOURD_KG = 20.0


class VilleInconnue(ValueError):
    """La ville n'est pas desservie."""


def distance_km(depart: str, arrivee: str) -> float:
    """Distance routière estimée entre deux villes desservies."""
    try:
        (lat1, lon1), (lat2, lon2) = VILLES[depart], VILLES[arrivee]
    except KeyError as exc:
        raise VilleInconnue(str(exc.args[0])) from exc
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * RAYON_TERRE_KM * math.asin(math.sqrt(a)) * FACTEUR_ROUTE


def jours_de_livraison(depart: str, arrivee: str, poids_kg: float) -> int:
    """Nombre de jours entre l'enregistrement et la livraison."""
    jours = 1 + math.ceil(distance_km(depart, arrivee) / KM_PAR_JOUR)
    if poids_kg > POIDS_LOURD_KG:
        jours += 1
    return jours


def date_estimee(depart: str, arrivee: str, poids_kg: float, le: date) -> date:
    """Date de livraison estimée pour un colis enregistré le jour « le »."""
    return le + timedelta(days=jours_de_livraison(depart, arrivee, poids_kg))
