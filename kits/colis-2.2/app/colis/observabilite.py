"""Ce que Colis dit de lui-même : métriques Prometheus, journaux JSON, traces OpenTelemetry.

Les métriques sont toujours actives. Les traces ne le sont que si OTEL_EXPORTER_OTLP_ENDPOINT
est défini (chapitre 51) : sans collecteur, Colis ne paie rien pour elles.
"""
from __future__ import annotations

import json
import logging
import os
import sys
import time

from prometheus_client import Counter, Gauge, Histogram

# --- métriques (chapitre 50)
# Les étiquettes restent en petit nombre et à valeurs bornées : la route est le modèle
# (/colis/{id_}), jamais l'URL réelle, sinon chaque identifiant créerait une série.
REQUETES = Counter("colis_http_requetes_total", "Requêtes HTTP traitées",
                   ["methode", "route", "code"])
DUREE = Histogram("colis_http_duree_secondes", "Durée de traitement des requêtes HTTP",
                  ["methode", "route"],
                  buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5))
ENREGISTRES = Counter("colis_enregistres_total", "Colis enregistrés par l'API")
ESTIMES = Counter("colis_estimes_total", "Colis dont la date de livraison a été calculée",
                  ["par"])
LIVRES = Counter("colis_livres_total", "Colis marqués livrés")
FILE = Gauge("colis_file_longueur", "Colis en attente d'estimation dans la file")


def mesurer_file(file) -> None:
    """La longueur de la file est lue au moment de la collecte, pas tenue à jour."""
    def longueur() -> float:
        try:
            return float(file.longueur())
        except Exception:  # file injoignable : pas de valeur plutôt qu'une collecte en erreur
            return float("nan")
    FILE.set_function(longueur)


class FormatJSON(logging.Formatter):
    """Une ligne JSON par message, avec l'identifiant de trace quand il y en a un."""

    def format(self, record: logging.LogRecord) -> str:
        ligne = {
            "moment": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(record.created))
                      + f".{int(record.msecs):03d}Z",
            "niveau": record.levelname.lower(),
            "service": os.environ.get("OTEL_SERVICE_NAME", "colis"),
            "message": record.getMessage(),
        }
        ligne.update(getattr(record, "champs", {}))
        trace = _trace_courante()
        if trace:
            ligne["trace_id"], ligne["span_id"] = trace
        return json.dumps(ligne, ensure_ascii=False)


def journal(nom: str) -> logging.Logger:
    """Le journal du composant, en JSON sur la sortie standard."""
    log = logging.getLogger(nom)
    if not log.handlers:
        sortie = logging.StreamHandler(sys.stdout)
        sortie.setFormatter(FormatJSON())
        log.addHandler(sortie)
        log.setLevel(logging.INFO)
        log.propagate = False
    return log


def _trace_courante() -> tuple[str, str] | None:
    try:
        from opentelemetry import trace
    except ImportError:
        return None
    ctx = trace.get_current_span().get_span_context()
    if not ctx.is_valid:
        return None
    return format(ctx.trace_id, "032x"), format(ctx.span_id, "016x")


def configurer_traces(app=None) -> bool:
    """Active OpenTelemetry si un collecteur est indiqué. Renvoie True si les traces sont actives."""
    if not os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT"):
        return False
    from opentelemetry import trace
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.instrumentation.psycopg import PsycopgInstrumentor
    from opentelemetry.instrumentation.redis import RedisInstrumentor
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    # OTEL_SERVICE_NAME et OTEL_RESOURCE_ATTRIBUTES sont lus par Resource.create()
    fournisseur = TracerProvider(resource=Resource.create())
    fournisseur.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(fournisseur)
    PsycopgInstrumentor().instrument(enable_commenter=False)
    RedisInstrumentor().instrument()
    if app is not None:
        from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
        FastAPIInstrumentor.instrument_app(app, excluded_urls="sante,pret,metrics")
    return True
