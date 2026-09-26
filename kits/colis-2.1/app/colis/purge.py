"""La purge : supprime les colis livrés depuis plus de COLIS_PURGE_JOURS jours (30 par défaut)."""
from __future__ import annotations

import os
import sys

from .config import stockage_depuis_env


def main() -> int:
    jours = int(os.environ.get("COLIS_PURGE_JOURS", "30"))
    stockage = stockage_depuis_env()
    supprimes = stockage.purger(jours)
    print(f"purge : {supprimes} colis livrés depuis plus de {jours} jours supprimés", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
