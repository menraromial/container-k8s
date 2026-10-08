"""Ordre d'activation des traces et connexion à PostgreSQL : avant ou après."""
import sys
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from colis.config import stockage_depuis_env

exporteur = InMemorySpanExporter()
fournisseur = TracerProvider()
fournisseur.add_span_processor(SimpleSpanProcessor(exporteur))
trace.set_tracer_provider(fournisseur)

def activer():
    from opentelemetry.instrumentation.psycopg import PsycopgInstrumentor
    PsycopgInstrumentor().instrument(enable_commenter=False)

if sys.argv[1] == "connexion-avant":      # l'ordre de Colis 2.2
    stockage = stockage_depuis_env()
    activer()
else:                                     # l'ordre de Colis 2.2.1
    activer()
    stockage = stockage_depuis_env()
with fournisseur.get_tracer("essai").start_as_current_span("requête"):
    stockage.lister()
print(f"{sys.argv[1]:16} spans : {[s.name for s in exporteur.get_finished_spans()]}")
