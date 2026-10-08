#!/usr/bin/env python3
"""Affiche une trace de Tempo en arbre, avec la durée de chaque span.

Usage : python3 arbre-trace.py <trace_id> [--tempo http://localhost:3201]
"""
import argparse
import json
import urllib.request


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("trace_id")
    p.add_argument("--tempo", default="http://localhost:3201")
    a = p.parse_args()
    with urllib.request.urlopen(f"{a.tempo}/api/v2/traces/{a.trace_id}", timeout=10) as r:
        trace = json.load(r)["trace"]
    spans = {}
    for rs in trace["resourceSpans"]:
        service = next((at["value"]["stringValue"] for at in rs["resource"]["attributes"]
                        if at["key"] == "service.name"), "?")
        for ss in rs["scopeSpans"]:
            for s in ss["spans"]:
                s["service"] = service
                spans[s["spanId"]] = s
    debut = min(int(s["startTimeUnixNano"]) for s in spans.values())

    def afficher(s, profondeur):
        d = (int(s["endTimeUnixNano"]) - int(s["startTimeUnixNano"])) / 1e6
        t0 = (int(s["startTimeUnixNano"]) - debut) / 1e6
        attrs = {at["key"]: list(at["value"].values())[0] for at in s.get("attributes", [])}
        detail = attrs.get("db.statement") or attrs.get("db.query.text") or attrs.get("http.route") or ""
        print(f"{'  ' * profondeur}{s['name'][:44]:<{46 - 2 * profondeur}} {s['service']:7} "
              f"+{t0:8.1f} ms {d:9.1f} ms  {str(detail)[:60]}")
        for enfant in sorted((e for e in spans.values() if e.get("parentSpanId") == s["spanId"]),
                             key=lambda e: int(e["startTimeUnixNano"])):
            afficher(enfant, profondeur + 1)

    for racine in (s for s in spans.values() if s.get("parentSpanId") not in spans):
        afficher(racine, 0)


if __name__ == "__main__":
    main()
