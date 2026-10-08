"""Vérifie, sans cluster, que le span du worker appartient à la trace de la requête de l'API."""
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

import propagation


class FauxRedis:
    def __init__(self):
        self.listes = {}

    def rpush(self, cle, valeur):
        self.listes.setdefault(cle, []).append(valeur)

    def blpop(self, cles, timeout):
        liste = self.listes.get(cles[0])
        return (cles[0], liste.pop(0)) if liste else None


def test_le_worker_continue_la_trace_de_l_api():
    exporteur = InMemorySpanExporter()
    fournisseur = TracerProvider()
    fournisseur.add_span_processor(SimpleSpanProcessor(exporteur))
    traceur = fournisseur.get_tracer("test")
    redis = FauxRedis()

    with traceur.start_as_current_span("POST /colis"):
        propagation.deposer(redis, 42)
    print("message dans la file :", redis.listes[propagation.CLE][0])

    id_, parent = propagation.prendre(redis, attente_s=1)
    with traceur.start_as_current_span("estimer un colis", context=parent):
        pass

    api, worker = exporteur.get_finished_spans()
    print(f"API    : trace {api.context.trace_id:032x} span {api.context.span_id:016x}")
    print(f"worker : trace {worker.context.trace_id:032x} parent {worker.parent.span_id:016x}")
    assert id_ == 42
    assert worker.context.trace_id == api.context.trace_id
    assert worker.parent.span_id == api.context.span_id


def test_un_ancien_message_reste_lisible():
    redis = FauxRedis()
    redis.rpush(propagation.CLE, "17")
    id_, _ = propagation.prendre(redis, attente_s=1)
    assert id_ == 17
