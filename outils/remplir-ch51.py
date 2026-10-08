#!/usr/bin/env python3
"""Remplit docs/partie-7/journaux.md à partir du modèle, des fichiers du kit et des journaux des rejeux."""
import json
import re
from pathlib import Path

R = Path(__file__).resolve().parent.parent
OUT = R / "outils/out"
KIT = R / "kits/journaux"


def sections(fichier):
    res = {}
    for bloc in re.split(r"\n### ", "\n" + (OUT / fichier).read_text()):
        if bloc.strip():
            titre, _, corps = bloc.partition("\n")
            res[titre.strip()] = corps.strip("\n").splitlines()
    return res


def sans(lignes, *motifs):
    return [l for l in lignes if not any(re.search(m, l) for m in motifs)]


def entre(lignes, debut, fin=None):
    """Les lignes après la première qui commence par debut, jusqu'à celle qui commence par fin."""
    i = next(k for k, l in enumerate(lignes) if l.startswith(debut)) + 1
    j = next((k for k in range(i, len(lignes)) if fin and lignes[k].startswith(fin)), len(lignes))
    return lignes[i:j]


def commentaires(lignes):
    return [re.sub(r"^\$ ", "# ", l) for l in lignes]


def fichier(nom):
    return (KIT / nom).read_text().rstrip("\n").splitlines()


I = sections("rejeu-ch51-installation.log")
S = sections("rejeu-ch51.log")
E = sections("rejeu-ch51-exercices.log")
REPONSES = r"^réponses : "
v = {}

lentes = [json.loads(l) for l in (OUT / "ch51r/lentes.txt").read_text().splitlines() if l.strip()]
v["ouverture"] = [json.dumps(l, ensure_ascii=False).replace('", "', '", "') for l in lentes[:2]]
durees = sorted(l["duree_ms"] / 1000 for l in lentes[:2])
tx = [f"{d:.1f}".replace(".", ",") for d in durees]
v["ouverture-durees"] = [f"{tx[0]} secondes chacune" if tx[0] == tx[1] else f"{tx[0]} et {tx[1]} secondes"]
p95 = float(next(l for l in S["enquete : metriques"] if l.startswith("p95")).split(":")[-1])
v["ouverture-p95"] = [f"{p95 * 1000:.0f} ms"]

av = I["avant"]
v["avant"] = [l for l in av if re.match(r"^\s*\d+$", l) or l.startswith("job=")]
v["allegees"] = fichier("valeurs-allegees.yaml")
al = I["allegement"]
v["allegement"] = sans(al, r"mémoire anonyme")
v["valeurs-loki"] = fichier("valeurs-loki.yaml")
v["valeurs-collecteur"] = fichier("valeurs-collecteur.yaml")
ap = I["apres"]
v["installation"] = ap[ap.index(next(l for l in ap if l.startswith("NAME") and "READY" in l)):
                       ap.index(next(l for l in ap if l.startswith("NAME") and "VOLUME" in l))]

et = sans(S["etiquettes"], REPONSES)
v["etiquettes"] = et[:2]
v["flux"] = et[2:4]
v["ligne"] = S["une ligne"]
v["filtres"] = S["logql filtres"]
v["erreur-json"] = (OUT / "ch51r/erreur-json.txt").read_text().rstrip("\n").splitlines()
v["erreur-lignes"] = (OUT / "ch51r/erreur-lignes.txt").read_text().rstrip("\n").splitlines()
lm = S["logql metriques"]
v["metriques-logql"] = commentaires(lm[lm.index("$ par code, sans les lignes non JSON") + 1:])
v["metriques-logql"] = ["# réponses par code"] + v["metriques-logql"]

bl = sans(S["traces bloquees"], REPONSES, r"^Found \d+ pods")
v["bloquees"] = [re.sub(r"^\(traces trouvées : (\d+)\)$", r"\1", l) for l in bl]
v["politique"] = fichier("politique-traces.yaml")
tr = sans(S["traces"], REPONSES)
v["premieres"] = tr[:tr.index(next(l for l in tr if l.startswith("$ arbre-trace.py")))]
v["arbre-22"] = entre(tr, "$ arbre-trace.py", "$ journal")
v["journal-22"] = entre(tr, "$ journal", "$ worker")
v["racines-22"] = entre(tr, "$ racines")
v["ordre"] = S["ordre"]

patch = (KIT / "colis-2.2.1.patch").read_text().splitlines()
garde, dedans = [], False
for l in patch:
    if l.startswith("--- "):
        dedans = "app.py" in l or "worker.py" in l
    if dedans:
        garde.append(l)
v["patch"] = garde
co = sans(S["correctif"], REPONSES, r"^Waiting for", r"successfully rolled out", r"^\d+$",
          r"^(configmap|deployment|cronjob)")
v["arbres-221"] = commentaires(co)

inc = S["incident"]
v["incident"] = inc[inc.index(next(l for l in inc if l.strip().startswith("pid"))):
                    inc.index(next(l for l in inc if re.match(r"^\(\d+ rows?\)", l))) + 1]
me = S["enquete : metriques"]
v["metriques"] = [l for l in me if not l.startswith("p99")]
v["lentes"] = [l.replace("# requetes de plus d une seconde", "# requêtes de plus d'une seconde, par route") for l in commentaires(S["enquete : journaux"])]
tl = S["enquete : trace"]
v["trace-lente"] = entre(tl, "$ arbre-trace.py", "$ traceql")
v["traceql"] = commentaires(tl[tl.index("$ traceql api"):])
v["grafana"] = S["grafana"] or (OUT / "ch51r/grafana.txt").read_text().rstrip("\n").splitlines()
v["memoire"] = [l for l in S["memoire"] if not re.search(r"mémoire anonyme|^loki_", l)]

v["ex1"] = commentaires(sans(E["ex1 journaux et metriques"], REPONSES))
v["ex3"] = (OUT / "ch51r/propagation.txt").read_text().rstrip("\n").splitlines()
v["ex4"] = sans(E["ex4 echantillonnage"], REPONSES, r"env updated")


def remplace(mo):
    l = list(v[mo.group(1)])
    while l and not l[-1].strip():
        l.pop()
    return "\n".join(l)


page = re.sub(r"@@([a-z0-9-]+)@@", remplace, (R / "outils/modeles/journaux.md.modele").read_text())
assert not re.search(r"@@[a-z0-9-]+@@", page)
(R / "docs/partie-7/journaux.md").write_text(page)
print("journaux.md écrit")
