"""Un client de watch minimal : suit les ConfigMaps d'un namespace et affiche chaque événement.

Usage : python3 surveiller.py ch34
Passe par « kubectl proxy » (port 8011), qui s'occupe de l'identité.
"""
import json
import sys
import urllib.request

ns = sys.argv[1] if len(sys.argv) > 1 else "default"
base = f"http://127.0.0.1:8011/api/v1/namespaces/{ns}/configmaps"

# 1. une liste, pour connaître l'état actuel et sa resourceVersion
with urllib.request.urlopen(base) as r:
    liste = json.load(r)
rv = liste["metadata"]["resourceVersion"]
print(f"{len(liste['items'])} ConfigMap(s) à la version {rv}", flush=True)

# 2. un watch à partir de cette version : une ligne JSON par événement
with urllib.request.urlopen(f"{base}?watch=true&resourceVersion={rv}") as flux:
    for ligne in flux:
        ev = json.loads(ligne)
        obj = ev["object"]
        print(ev["type"], obj["metadata"]["name"], obj["metadata"].get("resourceVersion"), flush=True)
