"""Ce que l'API reçoit et renvoie."""
from __future__ import annotations

from datetime import date, datetime

from pydantic import BaseModel, Field


class NouveauColis(BaseModel):
    destinataire: str = Field(min_length=1, max_length=120)
    depart: str
    arrivee: str
    poids_kg: float = Field(gt=0, le=70)


class Colis(BaseModel):
    id: int
    destinataire: str
    depart: str
    arrivee: str
    poids_kg: float
    statut: str
    cree_le: datetime
    livraison_estimee: date | None = None
    livre_le: datetime | None = None


ENREGISTRE = "enregistré"
ESTIME = "estimé"
LIVRE = "livré"
