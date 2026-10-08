"""L'API HTTP de Colis."""
from __future__ import annotations

import os
import socket
import time
from datetime import date

from fastapi import FastAPI, HTTPException, Request, Response
from prometheus_client import make_asgi_app

from . import __doc__ as description
from .config import file_depuis_env, stockage_depuis_env
from .delais import VILLES, VilleInconnue, date_estimee
from .file import File
from .modele import Colis, NouveauColis
from .observabilite import (DUREE, ENREGISTRES, ESTIMES, LIVRES, REQUETES, configurer_traces,
                            journal, mesurer_file)
from .stockage import Stockage

VERSION = os.environ.get("COLIS_VERSION", "1.0.0")
SILENCIEUX = {"/sante", "/pret", "/metrics"}  # interrogés en boucle : ni journal ni métrique
log = journal("colis.api")


def creer_app(stockage: Stockage, file: File | None) -> FastAPI:
    app = FastAPI(title="Colis", description=description, version=VERSION)
    app.mount("/metrics", make_asgi_app())
    if file:
        mesurer_file(file)

    @app.middleware("http")
    async def mesurer(request: Request, suite):
        debut = time.perf_counter()
        code = 500
        try:
            reponse = await suite(request)
            code = reponse.status_code
            return reponse
        finally:
            route = getattr(request.scope.get("route"), "path", "inconnue")
            if route not in SILENCIEUX and not request.url.path.startswith("/metrics"):
                duree = time.perf_counter() - debut
                REQUETES.labels(request.method, route, str(code)).inc()
                DUREE.labels(request.method, route).observe(duree)
                log.info("requête", extra={"champs": {
                    "methode": request.method, "chemin": request.url.path, "route": route,
                    "code": code, "duree_ms": round(duree * 1000, 1)}})

    @app.get("/sante")
    def sante() -> dict:
        """Le processus répond : sert à savoir s'il faut le redémarrer."""
        return {"statut": "ok", "version": VERSION, "hote": socket.gethostname()}

    @app.get("/pret")
    def pret(response: Response) -> dict:
        """Les dépendances répondent : sert à savoir si on peut lui envoyer du trafic."""
        etat = {"stockage": stockage.nom, "file": file.nom if file else "aucune"}
        try:
            stockage.verifier()
            if file:
                file.verifier()
        except Exception as exc:  # une dépendance ne répond pas
            response.status_code = 503
            return {**etat, "pret": False, "erreur": str(exc)}
        return {**etat, "pret": True}

    @app.get("/villes")
    def villes() -> list[str]:
        return sorted(VILLES)

    @app.post("/colis", status_code=201)
    def enregistrer(nouveau: NouveauColis) -> Colis:
        for ville in (nouveau.depart, nouveau.arrivee):
            if ville not in VILLES:
                raise HTTPException(422, f"ville non desservie : {ville}")
        colis = stockage.creer(nouveau)
        ENREGISTRES.inc()
        if file:
            # le worker calculera la date de livraison
            file.deposer(colis.id)
        else:
            # sans file, on l'estime tout de suite
            try:
                stockage.estimer(colis.id, date_estimee(
                    colis.depart, colis.arrivee, colis.poids_kg, date.today()))
                ESTIMES.labels("api").inc()
            except VilleInconnue as exc:
                raise HTTPException(422, str(exc)) from exc
            colis = stockage.lire(colis.id) or colis
        return colis

    @app.get("/colis")
    def lister() -> list[Colis]:
        return stockage.lister()

    @app.get("/colis/{id_}")
    def lire(id_: int) -> Colis:
        colis = stockage.lire(id_)
        if colis is None:
            raise HTTPException(404, f"colis {id_} introuvable")
        return colis

    @app.post("/colis/{id_}/livraison")
    def livrer(id_: int) -> Colis:
        colis = stockage.livrer(id_)
        if colis is None:
            raise HTTPException(404, f"colis {id_} introuvable")
        LIVRES.inc()
        return colis

    return app


app = creer_app(stockage_depuis_env(), file_depuis_env())
if configurer_traces(app):
    log.info("traces actives", extra={"champs": {"collecteur": os.environ["OTEL_EXPORTER_OTLP_ENDPOINT"]}})
