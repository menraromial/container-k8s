"""Un scheduler minimal : place au hasard, sur un nœud prêt, les Pods qui le désignent (schedulerName: hasard).

Usage : kubectl proxy --port=8011 &   puis   python3 ordonnanceur-hasard.py
"""
import json
import random
import time
import urllib.request

API = "http://127.0.0.1:8011/api/v1"


def requete(methode, chemin, corps=None):
    donnees = json.dumps(corps).encode() if corps is not None else None
    req = urllib.request.Request(API + chemin, data=donnees, method=methode,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req) as r:
        return json.load(r)


def noeuds_prets():
    return [n["metadata"]["name"] for n in requete("GET", "/nodes")["items"]
            if any(c["type"] == "Ready" and c["status"] == "True" for c in n["status"]["conditions"])
            and not n["spec"].get("unschedulable")]


def placer(pod):
    ns, nom = pod["metadata"]["namespace"], pod["metadata"]["name"]
    noeud = random.choice(noeuds_prets())
    requete("POST", f"/namespaces/{ns}/pods/{nom}/binding",
            {"apiVersion": "v1", "kind": "Binding", "metadata": {"name": nom},
             "target": {"apiVersion": "v1", "kind": "Node", "name": noeud}})
    print(f"{time.strftime('%H:%M:%S')} {ns}/{nom} -> {noeud}", flush=True)


# les Pods qui nous sont confiés et qui n'ont pas encore de nœud
selecteur = "fieldSelector=spec.schedulerName%3Dhasard,spec.nodeName%3D"
liste = requete("GET", f"/pods?{selecteur}")
for pod in liste["items"]:
    placer(pod)
with urllib.request.urlopen(f"{API}/pods?{selecteur}&watch=true"
                            f"&resourceVersion={liste['metadata']['resourceVersion']}") as flux:
    for ligne in flux:
        ev = json.loads(ligne)
        if ev["type"] == "ADDED":
            placer(ev["object"])
