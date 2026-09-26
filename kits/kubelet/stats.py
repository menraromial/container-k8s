"""Lit les statistiques d'un kubelet (/stats/summary) à travers l'API server et affiche la mémoire de chaque Pod.

Usage : kubectl proxy --port=8011 &   puis   python3 stats.py deux-noeuds-m02
"""
import json
import sys
import urllib.request

noeud = sys.argv[1]
url = f"http://127.0.0.1:8011/api/v1/nodes/{noeud}/proxy/stats/summary"
with urllib.request.urlopen(url) as r:
    resume = json.load(r)

n = resume["node"]
print(f"nœud {noeud} : {n['memory']['workingSetBytes'] / 2**20:.0f} Mio de mémoire utilisée, "
      f"{n['cpu']['usageNanoCores'] / 1e6:.0f} millicœurs")
lignes = []
for pod in resume["pods"]:
    ref = pod["podRef"]
    memoire = pod.get("memory", {}).get("workingSetBytes", 0) / 2**20
    cpu = pod.get("cpu", {}).get("usageNanoCores", 0) / 1e6
    lignes.append((memoire, f"{ref['namespace']}/{ref['name']}", cpu))
for memoire, nom, cpu in sorted(lignes, reverse=True):
    print(f"  {memoire:6.1f} Mio  {cpu:6.1f} m  {nom}")
