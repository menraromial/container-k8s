"""Où vivent les colis : en mémoire (pour essayer, pour les tests) ou dans PostgreSQL."""
from __future__ import annotations

import threading
from datetime import date, datetime, timezone
from typing import Protocol

from .modele import ENREGISTRE, ESTIME, LIVRE, Colis, NouveauColis

SCHEMA = """
CREATE TABLE IF NOT EXISTS colis (
    id                serial PRIMARY KEY,
    destinataire      text        NOT NULL,
    depart            text        NOT NULL,
    arrivee           text        NOT NULL,
    poids_kg          real        NOT NULL,
    statut            text        NOT NULL,
    cree_le           timestamptz NOT NULL DEFAULT now(),
    livraison_estimee date,
    livre_le          timestamptz
)
"""
COLONNES = "id, destinataire, depart, arrivee, poids_kg, statut, cree_le, livraison_estimee, livre_le"


class Stockage(Protocol):
    nom: str

    def creer(self, nouveau: NouveauColis) -> Colis: ...
    def lire(self, id_: int) -> Colis | None: ...
    def lister(self, limite: int = 50) -> list[Colis]: ...
    def estimer(self, id_: int, livraison: date) -> None: ...
    def livrer(self, id_: int) -> Colis | None: ...
    def purger(self, jours: int) -> int: ...
    def verifier(self) -> None: ...


def _maintenant() -> datetime:
    return datetime.now(timezone.utc)


class StockageMemoire:
    """Tout est perdu à l'arrêt du processus : c'est voulu, et c'est l'objet du chapitre 5."""

    nom = "mémoire"

    def __init__(self) -> None:
        self._colis: dict[int, Colis] = {}
        self._verrou = threading.Lock()

    def creer(self, nouveau: NouveauColis) -> Colis:
        with self._verrou:
            id_ = len(self._colis) + 1
            colis = Colis(id=id_, statut=ENREGISTRE, cree_le=_maintenant(), **nouveau.model_dump())
            self._colis[id_] = colis
            return colis

    def lire(self, id_: int) -> Colis | None:
        return self._colis.get(id_)

    def lister(self, limite: int = 50) -> list[Colis]:
        return sorted(self._colis.values(), key=lambda c: c.id, reverse=True)[:limite]

    def estimer(self, id_: int, livraison: date) -> None:
        with self._verrou:
            colis = self._colis[id_]
            self._colis[id_] = colis.model_copy(update={"livraison_estimee": livraison, "statut": ESTIME})

    def livrer(self, id_: int) -> Colis | None:
        with self._verrou:
            colis = self._colis.get(id_)
            if colis is None:
                return None
            colis = colis.model_copy(update={"statut": LIVRE, "livre_le": _maintenant()})
            self._colis[id_] = colis
            return colis

    def purger(self, jours: int) -> int:
        limite = _maintenant().timestamp() - jours * 86400
        with self._verrou:
            anciens = [i for i, c in self._colis.items()
                       if c.statut == LIVRE and c.livre_le and c.livre_le.timestamp() < limite]
            for i in anciens:
                del self._colis[i]
            return len(anciens)

    def verifier(self) -> None:
        return None


class StockagePostgres:
    """Les colis dans une table PostgreSQL ; la table est créée au premier démarrage.

    Version 2.1 : la connexion se rouvre quand PostgreSQL a redémarré. Une lecture
    qui échoue sur une connexion coupée est rejouée une fois sur une connexion neuve ;
    une écriture ne l'est jamais, car on ne sait pas si elle a abouti avant la coupure.
    """

    nom = "postgres"

    def __init__(self, dsn: str) -> None:
        import psycopg

        self._psycopg = psycopg
        self._dsn = dsn
        self._connexion = None
        self._verrou = threading.Lock()
        with self._verrou:
            self._executer(SCHEMA)

    def _connecter(self):
        from psycopg.rows import dict_row

        if self._connexion is None or self._connexion.closed or self._connexion.broken:
            self._connexion = self._psycopg.connect(
                self._dsn, autocommit=True, row_factory=dict_row, connect_timeout=3)
        return self._connexion

    def _executer(self, sql: str, params: tuple = (), rejouable: bool = False):
        """Exécute une requête (le verrou doit être pris). Rejoue une fois si rejouable."""
        try:
            return self._connecter().execute(sql, params)
        except self._psycopg.OperationalError:
            # connexion perdue : on l'abandonne, la prochaine requête en ouvrira une autre
            self._connexion = None
            if not rejouable:
                raise
            return self._connecter().execute(sql, params)

    def _un(self, sql: str, params: tuple = (), rejouable: bool = False) -> Colis | None:
        with self._verrou:
            ligne = self._executer(sql, params, rejouable).fetchone()
        return Colis(**ligne) if ligne else None

    def creer(self, nouveau: NouveauColis) -> Colis:
        colis = self._un(
            f"INSERT INTO colis (destinataire, depart, arrivee, poids_kg, statut) "
            f"VALUES (%s, %s, %s, %s, %s) RETURNING {COLONNES}",
            (nouveau.destinataire, nouveau.depart, nouveau.arrivee, nouveau.poids_kg, ENREGISTRE),
        )
        assert colis is not None
        return colis

    def lire(self, id_: int) -> Colis | None:
        return self._un(f"SELECT {COLONNES} FROM colis WHERE id = %s", (id_,), rejouable=True)

    def lister(self, limite: int = 50) -> list[Colis]:
        with self._verrou:
            lignes = self._executer(
                f"SELECT {COLONNES} FROM colis ORDER BY id DESC LIMIT %s", (limite,),
                rejouable=True).fetchall()
        return [Colis(**l) for l in lignes]

    def estimer(self, id_: int, livraison: date) -> None:
        # rejouable : écrire deux fois la même date donne le même résultat
        with self._verrou:
            self._executer(
                "UPDATE colis SET livraison_estimee = %s, statut = %s WHERE id = %s",
                (livraison, ESTIME, id_), rejouable=True)

    def livrer(self, id_: int) -> Colis | None:
        return self._un(
            f"UPDATE colis SET statut = %s, livre_le = now() WHERE id = %s RETURNING {COLONNES}",
            (LIVRE, id_))

    def purger(self, jours: int) -> int:
        with self._verrou:
            cur = self._executer(
                "DELETE FROM colis WHERE statut = %s AND livre_le < now() - make_interval(days => %s)",
                (LIVRE, jours))
        return cur.rowcount

    def verifier(self) -> None:
        with self._verrou:
            self._executer("SELECT 1", rejouable=True)
