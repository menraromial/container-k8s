"""Incrémente N fois un compteur rangé dans un ConfigMap, par concurrence optimiste.

Usage : python3 compteur.py <nom> <N> [sans-version]
(avec « kubectl proxy --port=8011 » lancé, namespace ch35)
Chaque tour lit le ConfigMap, ajoute 1, et le réécrit avec la resourceVersion lue.
Si quelqu'un a écrit entre-temps, l'API server répond 409 : on relit et on recommence.
Avec « sans-version », la resourceVersion est retirée avant l'écriture : plus de contrôle.
"""
import json
import sys
import urllib.error
import urllib.request

URL = "http://127.0.0.1:8011/api/v1/namespaces/ch35/configmaps/compteur"
nom, n = sys.argv[1], int(sys.argv[2])
sans_version = len(sys.argv) > 3 and sys.argv[3] == "sans-version"
conflits = 0
for _ in range(n):
    while True:
        with urllib.request.urlopen(URL) as r:
            cm = json.load(r)
        cm["data"]["valeur"] = str(int(cm["data"]["valeur"]) + 1)
        if sans_version:
            del cm["metadata"]["resourceVersion"]
        req = urllib.request.Request(URL, data=json.dumps(cm).encode(), method="PUT",
                                     headers={"Content-Type": "application/json"})
        try:
            urllib.request.urlopen(req).close()
            break
        except urllib.error.HTTPError as e:
            if e.code != 409:
                raise
            conflits += 1
print(f"{nom} : {n} incréments, {conflits} conflits")
