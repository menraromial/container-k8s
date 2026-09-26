"""Vérifie que l'adresse de chaque Pod appartient au bloc (podCIDR) que Kubernetes a attribué à son nœud.

Usage : kubectl proxy --port=8011 &   puis   python3 adresses.py
"""
import ipaddress
import json
import urllib.request

API = "http://127.0.0.1:8011/api/v1"


def lire(chemin):
    with urllib.request.urlopen(API + chemin) as r:
        return json.load(r)


blocs = {n["metadata"]["name"]: ipaddress.ip_network(n["spec"]["podCIDR"])
         for n in lire("/nodes")["items"] if n["spec"].get("podCIDR")}
for nom, bloc in sorted(blocs.items()):
    print(f"{nom:12} podCIDR {bloc}")
for p in lire("/pods")["items"]:
    s = p["spec"]
    if s.get("hostNetwork") or not p["status"].get("podIP"):
        continue                                    # les Pods du réseau de l'hôte ont l'adresse du nœud
    ip = ipaddress.ip_address(p["status"]["podIP"])
    noeud = s["nodeName"]
    verdict = "oui" if ip in blocs[noeud] else "NON"
    print(f"  {p['metadata']['namespace'] + '/' + p['metadata']['name']:45} {noeud:12} {str(ip):15} {verdict}")
