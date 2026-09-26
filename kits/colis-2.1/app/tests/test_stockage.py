"""La reconnexion de StockagePostgres (version 2.1), sans serveur PostgreSQL : psycopg est simulé."""
import psycopg
import pytest

from colis.stockage import StockagePostgres


class Curseur:
    def __init__(self, lignes=()):
        self.lignes = list(lignes)
        self.rowcount = len(self.lignes)

    def fetchone(self):
        return self.lignes[0] if self.lignes else None

    def fetchall(self):
        return self.lignes


class Connexion:
    """Une connexion simulée. Comme avec psycopg, une connexion coupée par le serveur
    ne le sait qu'à la requête suivante, qui échoue et la marque « broken »."""

    def __init__(self, journal):
        self.closed = False
        self.broken = False
        self.coupee = False
        self.journal = journal

    def execute(self, sql, params=()):
        if self.coupee:
            self.broken = True
            raise psycopg.OperationalError("the connection is closed")
        self.journal.append(sql.split()[0])
        return Curseur()


@pytest.fixture
def stockage(monkeypatch):
    connexions = []
    journal = []

    def connect(*args, **kwargs):
        c = Connexion(journal)
        connexions.append(c)
        return c

    monkeypatch.setattr(psycopg, "connect", connect)
    s = StockagePostgres("postgresql://essai")
    return s, connexions, journal


def test_la_verification_rouvre_une_connexion_coupee(stockage):
    s, connexions, journal = stockage
    connexions[0].coupee = True  # PostgreSQL a redémarré
    s.verifier()
    assert len(connexions) == 2
    assert journal[-1] == "SELECT"


def test_une_lecture_est_rejouee_une_fois(stockage):
    s, connexions, _ = stockage
    connexions[0].coupee = True
    assert s.lister() == []
    assert len(connexions) == 2


def test_une_ecriture_n_est_pas_rejouee(stockage):
    s, connexions, journal = stockage
    connexions[0].coupee = True
    with pytest.raises(psycopg.OperationalError):
        s.purger(30)
    assert "DELETE" not in journal
    # mais la requête suivante repart sur une connexion neuve
    assert s.purger(30) == 0
    assert len(connexions) == 2
