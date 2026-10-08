#!/usr/bin/env python3
"""Remplit docs/partie-7/metriques.md à partir du modèle, des fichiers du kit et des journaux des rejeux."""
import re
from pathlib import Path

R = Path(__file__).resolve().parent.parent
OUT = R / "outils/out"
KIT = R / "kits/metriques"


def sections(fichier):
    res = {}
    for bloc in re.split(r"\n### ", "\n" + (OUT / fichier).read_text()):
        if bloc.strip():
            titre, _, corps = bloc.partition("\n")
            res[titre.strip()] = corps.strip("\n").splitlines()
    return res


def sans(lignes, *motifs):
    return [l for l in lignes if not any(re.search(m, l) for m in motifs)]


def apres(lignes, marqueur):
    """Les lignes qui suivent « $ marqueur » jusqu'au marqueur suivant."""
    i = lignes.index(f"$ {marqueur}")
    fin = next((j for j in range(i + 1, len(lignes)) if lignes[j].startswith("$ ")), len(lignes))
    return lignes[i + 1:fin]


def entre(texte, debut, fin):
    i = texte.index(debut)
    return texte[i:texte.index(fin, i)].rstrip("\n").splitlines()


S = sections("rejeu-ch50.log")
E = sections("rejeu-ch50-exercices.log")
q = S["requetes"]
v = {}
v["valeurs"] = (KIT / "valeurs-supervision.yaml").read_text().rstrip("\n").splitlines()
inst = (OUT / "ch50r/installation.log").read_text().splitlines()
v["installation"] = [l for l in inst if l.startswith(("Pulled", "Digest", "Error"))]
v["cibles-avant"] = (OUT / "ch50r/cibles-avant.txt").read_text().rstrip("\n").splitlines()
up = (OUT / "ch50r/upgrade.log").read_text().splitlines()
v["upgrade"] = up[up.index(next(l for l in up if l.startswith("NAME"))):]
et = S["etat"]
v["etat"] = et[et.index(next(l for l in et if l.startswith("NAME") and "READY" in l)):
               et.index(next(l for l in et if l.startswith("NAMESPACE")))]
v["etat"] = sans(v["etat"], r"^pager-")  # le récepteur d'un passage précédent, en cours de suppression
obs = (R / "kits/colis-2.2/app/colis/observabilite.py").read_text()
v["code-metriques"] = entre(obs, "REQUETES = Counter", "\n\n\ndef mesurer_file")
app = (R / "kits/colis-2.2/app/colis/app.py").read_text()
v["code-middleware"] = entre(app, '    @app.middleware("http")', "\n\n    @app.get")
v["passage"] = S["passage en 2.2"]
v["brutes"] = sans(S["metriques brutes"], r"^Found \d+ pods", r"séries dans la réponse")
v["moniteurs-yaml"] = (KIT / "moniteurs.yaml").read_text().rstrip("\n").splitlines()
v["moniteurs"] = sans(S["moniteurs"], r"^après ")
v["politique-yaml"] = (KIT / "politique-supervision.yaml").read_text().rstrip("\n").splitlines()
v["politique"] = sans(S["politique"], r"^après ")
v["q-up"] = apres(q, 'up{namespace="colis"}')
v["q-taux"] = apres(q, "taux par route et code")
v["q-404"] = [l.strip() for l in apres(q, "part des 404")]
v["q-p95"] = apres(q, "p95 par route")
v["q-p50"] = apres(q, "p50 par route")
v["q-enregistree"] = apres(q, "regle enregistree")
v["q-memoire"] = ["# mémoire utilisée (Mio)"] + apres(q, "memoire") + ["# requests (Mio)"] + apres(q, "requests memoire")
v["q-worker"] = apres(q, "estimes")
v["q-series"] = [l.strip() for l in apres(q, "series") + apres(q, "series colis")]
regles = (KIT / "regles.yaml").read_text()
v["regles-enregistrement"] = entre(regles, "apiVersion:", "  - name: colis.alertes")
v["regles-alertes"] = regles[regles.index("  - name: colis.alertes"):].rstrip("\n").splitlines()
v["grafana"] = sans(S["grafana"], r"^mot de passe")
v["alertes-regles"] = S["alertes : regles"]
v["am-yaml"] = (KIT / "alertmanager-colis.yaml").read_text().rstrip("\n").splitlines()
v["alertes-routage"] = sans(S["alertes : routage"], r"^Waiting for", r"successfully rolled out")
dec = S["alertes : declenchement"]
v["alertes-declenchement"] = sans(dec, r"^NAME +SCALETARGET", r"^worker +apps/v1")
v["h-envoi"] = [next(l for l in dec if re.fullmatch(r"\d\d:\d\d:\d\d", l))]
v["alertes-retour"] = S["alertes : retour a la normale"]
v["memoire"] = S["memoire"]
e1 = E["ex1 cardinalite"]
v["ex1"] = [l.strip() for l in e1 if not l.startswith("$ ")]
total = int(float(apres(e1, "series de duree")[0]))
colis = int(e1[-1])
v["ex1-buckets"] = [str(total)]
v["ex1-colis"] = [f"{colis:,}".replace(",", "\u202f")]
v["ex1-calcul"] = [f"{colis:,} × 13 × 2 = {colis * 13 * 2:,}".replace(",", "\u202f")]
e2 = E["ex2 objectifs"]
v["ex2"] = ["# disponibilité"] + [l.strip() for l in apres(e2, "disponibilite 30 min")] + \
           ["# disponibilité, avec or vector(0)"] + [l.strip() for l in apres(e2, "disponibilite 30 min (corrigee)")] + \
           ["# part sous 25 ms"] + [l.strip() for l in apres(e2, "part sous 25 ms")]
v["ex3"] = E["ex3 dimensionner"]
ex = (R / "outils/rejeu-ch50-exercices.sh").read_text()
v["ex4-yaml"] = re.search(r"cat > muette.yaml <<'YAML'\n(.*?)\nYAML", ex, re.S).group(1).splitlines()
v["ex4"] = sans(E["ex4 cible muette"], r"colis-collecte\" deleted")

def remplace(mo):
    l = list(v[mo.group(1)])
    while l and not l[-1].strip():
        l.pop()
    return "\n".join(l)

modele = (R / "outils/modeles/metriques.md.modele").read_text()
# les marqueurs dans le texte courant (pas dans un bloc) ne prennent qu'une ligne
page = re.sub(r"@@([a-z0-9-]+)@@", remplace, modele)
assert not re.search(r"@@[a-z0-9-]+@@", page)
(R / "docs/partie-7/metriques.md").write_text(page)
print("metriques.md écrit")
