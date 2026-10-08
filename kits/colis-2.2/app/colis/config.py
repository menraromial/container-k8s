"""Configuration lue dans les variables d'environnement, comme il se doit dans un conteneur."""
from __future__ import annotations

import os

from .file import File, FileRedis
from .stockage import Stockage, StockageMemoire, StockagePostgres


def stockage_depuis_env() -> Stockage:
    dsn = os.environ.get("COLIS_DB")
    return StockagePostgres(dsn) if dsn else StockageMemoire()


def file_depuis_env() -> File | None:
    url = os.environ.get("COLIS_REDIS")
    return FileRedis(url) if url else None
