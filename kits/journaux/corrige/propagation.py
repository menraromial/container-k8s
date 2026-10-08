"""Corrigé de l'exercice 3 du chapitre 51 : faire suivre le contexte de trace dans la file.

L'API dépose dans Redis, à côté de l'identifiant du colis, l'en-tête W3C `traceparent` de la
requête en cours ; le worker le relit et ouvre son span comme enfant de cette requête.
Les deux fonctions remplacent `FileRedis.deposer` et `FileRedis.prendre` (colis/file.py).
"""
from __future__ import annotations

import json

from opentelemetry import context, propagate

CLE = "colis:a-estimer"


def deposer(redis, id_: int) -> None:
    porteur: dict[str, str] = {}
    propagate.inject(porteur)                 # {"traceparent": "00-<trace>-<span>-01"} s'il y a une trace
    redis.rpush(CLE, json.dumps({"id": id_, **porteur}))


def prendre(redis, attente_s: int) -> tuple[int, context.Context] | None:
    resultat = redis.blpop([CLE], timeout=attente_s)
    if not resultat:
        return None
    message = resultat[1]
    if message.isdigit():                     # un message déposé par une API 2.2 : pas de contexte
        return int(message), context.get_current()
    donnees = json.loads(message)
    return int(donnees.pop("id")), propagate.extract(donnees)

# Dans le worker :
#     pris = file.prendre(attente_s=2)
#     if pris is None: continue
#     id_, parent = pris
#     with traceur.start_as_current_span("estimer un colis", context=parent, attributes={"colis.id": id_}):
#         traiter(stockage, id_, pause)
