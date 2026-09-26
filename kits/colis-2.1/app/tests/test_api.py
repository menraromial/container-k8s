from fastapi.testclient import TestClient

from colis.app import creer_app
from colis.stockage import StockageMemoire


class FileMemoire:
    nom = "mémoire"

    def __init__(self):
        self.ids = []

    def deposer(self, id_):
        self.ids.append(id_)

    def prendre(self, attente_s):
        return self.ids.pop(0) if self.ids else None

    def longueur(self):
        return len(self.ids)

    def verifier(self):
        return None


NOUVEAU = {"destinataire": "Ada Lovelace", "depart": "Paris", "arrivee": "Brest", "poids_kg": 2.5}


def client(file=None):
    return TestClient(creer_app(StockageMemoire(), file))


def test_sante_et_pret():
    c = client()
    assert c.get("/sante").json()["statut"] == "ok"
    assert c.get("/pret").json() == {"stockage": "mémoire", "file": "aucune", "pret": True}


def test_sans_file_la_date_est_estimee_tout_de_suite():
    c = client()
    r = c.post("/colis", json=NOUVEAU)
    assert r.status_code == 201
    assert r.json()["statut"] == "estimé"
    assert r.json()["livraison_estimee"] is not None


def test_avec_file_le_colis_attend_le_worker():
    file = FileMemoire()
    c = client(file)
    r = c.post("/colis", json=NOUVEAU)
    assert r.json()["statut"] == "enregistré"
    assert file.ids == [r.json()["id"]]


def test_ville_non_desservie():
    r = client().post("/colis", json={**NOUVEAU, "arrivee": "Atlantis"})
    assert r.status_code == 422


def test_lire_lister_livrer():
    c = client()
    id_ = c.post("/colis", json=NOUVEAU).json()["id"]
    assert c.get(f"/colis/{id_}").json()["destinataire"] == "Ada Lovelace"
    assert [x["id"] for x in c.get("/colis").json()] == [id_]
    assert c.post(f"/colis/{id_}/livraison").json()["statut"] == "livré"
    assert c.get("/colis/999").status_code == 404
