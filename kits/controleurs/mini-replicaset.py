"""Un contrôleur minimal : un « ReplicaSet » fait main, en Python, bibliothèque standard seulement.

Le souhait est un ConfigMap étiqueté cours/mini-rs=oui, avec data.repliques (nombre de Pods).
Le contrôleur maintient ce nombre de Pods, étiquetés cours/proprietaire=<nom du ConfigMap>,
dont le ConfigMap est le propriétaire (ownerReferences).

Usage : kubectl proxy --port=8011 &   puis   python3 mini-replicaset.py ch36
"""
import json
import queue
import sys
import threading
import time
import urllib.error
import urllib.request

NS = sys.argv[1] if len(sys.argv) > 1 else "default"
API = f"http://127.0.0.1:8011/api/v1/namespaces/{NS}"
IMAGE = "registry.k8s.io/e2e-test-images/agnhost:2.61"
file_attente = queue.Queue()        # des noms de ConfigMap à réconcilier
cache = {"configmaps": {}, "pods": {}}   # l'état connu, tenu à jour par les watches
verrou = threading.Lock()


def requete(methode, chemin, corps=None):
    donnees = json.dumps(corps).encode() if corps is not None else None
    req = urllib.request.Request(API + chemin, data=donnees, method=methode,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req) as r:
        return json.load(r)


def lister_puis_surveiller(ressource, selecteur, cle_de):
    """Le schéma list puis watch : remplit le cache, puis le tient à jour, et met en file les clés touchées."""
    while True:
        liste = requete("GET", f"/{ressource}?labelSelector={selecteur}")
        with verrou:
            cache[ressource] = {o["metadata"]["name"]: o for o in liste["items"]}
        for o in liste["items"]:
            file_attente.put(cle_de(o))
        rv = liste["metadata"]["resourceVersion"]
        try:
            with urllib.request.urlopen(f"{API}/{ressource}?watch=true&labelSelector={selecteur}"
                                        f"&resourceVersion={rv}&timeoutSeconds=300") as flux:
                for ligne in flux:
                    ev = json.loads(ligne)
                    o = ev["object"]
                    if ev["type"] == "ERROR":
                        break                       # 410 : on reliste
                    with verrou:
                        if ev["type"] == "DELETED":
                            cache[ressource].pop(o["metadata"]["name"], None)
                        else:
                            cache[ressource][o["metadata"]["name"]] = o
                    file_attente.put(cle_de(o))
        except (urllib.error.URLError, ConnectionError):
            time.sleep(1)


def reconcilier(nom):
    """Compare le souhait à la réalité, lue dans le cache, et corrige l'écart. Rien d'autre."""
    with verrou:
        cm = cache["configmaps"].get(nom)
        pods = [p for p in cache["pods"].values()
                if p["metadata"]["labels"].get("cours/proprietaire") == nom
                and not p["metadata"].get("deletionTimestamp")]
    if cm is None:
        return                                      # plus de souhait : le ramasse-miettes s'occupe des Pods
    voulu, reel = int(cm["data"].get("repliques", "0")), len(pods)
    if reel < voulu:
        for _ in range(voulu - reel):
            pod = {"apiVersion": "v1", "kind": "Pod",
                   "metadata": {"generateName": f"{nom}-", "labels": {"cours/proprietaire": nom},
                                "ownerReferences": [{"apiVersion": "v1", "kind": "ConfigMap", "name": nom,
                                                     "uid": cm["metadata"]["uid"], "controller": True,
                                                     "blockOwnerDeletion": True}]},
                   "spec": {"containers": [{"name": "c", "image": IMAGE, "args": ["pause"]}],
                            "terminationGracePeriodSeconds": 1}}
            cree = requete("POST", "/pods", pod)
            print(f"{time.strftime('%H:%M:%S')} {nom} : {reel} Pod(s) pour {voulu} voulus, je crée {cree['metadata']['name']}", flush=True)
            reel += 1
    elif reel > voulu:
        for p in sorted(pods, key=lambda p: p["metadata"]["creationTimestamp"])[voulu:]:
            requete("DELETE", f"/pods/{p['metadata']['name']}")
            print(f"{time.strftime('%H:%M:%S')} {nom} : {reel} Pod(s) pour {voulu} voulus, je supprime {p['metadata']['name']}", flush=True)
            reel -= 1


threading.Thread(target=lister_puis_surveiller, daemon=True,
                 args=("configmaps", "cours/mini-rs=oui", lambda o: o["metadata"]["name"])).start()
threading.Thread(target=lister_puis_surveiller, daemon=True,
                 args=("pods", "cours/proprietaire", lambda o: o["metadata"]["labels"]["cours/proprietaire"])).start()
print(f"contrôleur démarré dans {NS}", flush=True)
while True:
    nom = file_attente.get()
    time.sleep(0.2)                                 # laisse le cache rattraper les watches
    while not file_attente.empty() and file_attente.queue[0] == nom:
        file_attente.get()                          # dédoublonne les clés identiques qui se suivent
    reconcilier(nom)
