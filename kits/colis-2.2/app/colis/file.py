"""La file des colis dont il faut estimer la date de livraison."""
from __future__ import annotations

from typing import Protocol

CLE = "colis:a-estimer"


class File(Protocol):
    nom: str

    def deposer(self, id_: int) -> None: ...
    def prendre(self, attente_s: int) -> int | None: ...
    def longueur(self) -> int: ...
    def verifier(self) -> None: ...


class FileRedis:
    nom = "redis"

    def __init__(self, url: str) -> None:
        import redis

        self._redis = redis.Redis.from_url(url, decode_responses=True)

    def deposer(self, id_: int) -> None:
        self._redis.rpush(CLE, id_)

    def prendre(self, attente_s: int) -> int | None:
        resultat = self._redis.blpop([CLE], timeout=attente_s)
        return int(resultat[1]) if resultat else None

    def longueur(self) -> int:
        return int(self._redis.llen(CLE))

    def verifier(self) -> None:
        self._redis.ping()
