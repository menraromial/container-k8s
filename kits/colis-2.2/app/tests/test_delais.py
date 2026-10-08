from datetime import date

import pytest

from colis.delais import VilleInconnue, date_estimee, distance_km, jours_de_livraison


def test_distance_symetrique_et_nulle_sur_place():
    assert distance_km("Paris", "Brest") == pytest.approx(distance_km("Brest", "Paris"))
    assert distance_km("Lyon", "Lyon") == 0


def test_paris_brest():
    # 505 km à vol d'oiseau, environ 657 km par la route
    assert distance_km("Paris", "Brest") == pytest.approx(657, abs=5)
    assert jours_de_livraison("Paris", "Brest", 2.0) == 3


def test_un_colis_lourd_prend_un_jour_de_plus():
    assert jours_de_livraison("Paris", "Lyon", 25.0) == jours_de_livraison("Paris", "Lyon", 5.0) + 1


def test_date_estimee():
    assert date_estimee("Paris", "Lille", 1.0, date(2026, 9, 25)) == date(2026, 9, 27)


def test_ville_inconnue():
    with pytest.raises(VilleInconnue):
        distance_km("Paris", "Atlantis")
