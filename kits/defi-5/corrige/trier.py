"""Trie les écritures d'un watch etcd horodaté (« époque JSON » par ligne) et n'en garde que celles d'un namespace.
Usage : python3 trier.py watch.txt defi5"""
import base64
import datetime
import json
import re
import sys

fichier, ns = sys.argv[1], sys.argv[2]
lignes = []
for l in open(fichier):
    t, j = l.split(" ", 1)
    try:
        lot = json.loads(j)
    except ValueError:
        continue
    for ev in lot.get("Events", []):
        kv = ev["kv"]
        cle = base64.b64decode(kv["key"]).decode()
        if f"/{ns}/" not in cle:
            continue
        op = "SUPPR" if ev.get("type") == 1 else ("CRÉE " if kv.get("version") == 1 else "MODIF")
        if "/events/" in cle and "value" in kv:     # la raison d'un événement se lit dans sa valeur protobuf
            m = re.search(rb"(ScalingReplicaSet|SuccessfulCreate|Scheduled|Pulling|Pulled|Created|Started)",
                          base64.b64decode(kv["value"]))
            cle += f"  ({m.group(1).decode()})" if m else ""
        lignes.append((kv["mod_revision"], float(t), op, cle))
lignes.sort()
debut = lignes[0][1]
noms = {}                                           # Pod réel -> « Pod 1 », « Pod 2 »
def court(cle):
    for m in re.findall(r"temoin-[a-z0-9]+-[a-z0-9]{5}", cle):
        noms.setdefault(m, f"<Pod {len(noms) + 1}>")
        cle = cle.replace(m, noms[m])
    return re.sub(r"\.[0-9a-f]{16}(  |$)", r"...\1", cle)
for rev, t, op, cle in lignes:
    h = datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%H:%M:%S.%f")[:-3]
    print(f"{rev}  {h}  +{(t - debut) * 1000:5.0f} ms  {op}  {court(cle)}")
print("; ".join(f"{v} = {k}" for k, v in noms.items()))
