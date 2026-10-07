#!/usr/bin/env python3
"""Remplit docs/partie-7/deboguer.md à partir du modèle et du journal du rejeu (outils/out/rejeu-ch48.log)."""
import re
from pathlib import Path

RACINE = Path(__file__).resolve().parent.parent
journal = (RACINE / "outils/out/rejeu-ch48.log").read_text()
sections = {}
for bloc in re.split(r"\n### ", "\n" + journal):
    if bloc.strip():
        titre, _, corps = bloc.partition("\n")
        sections[titre.strip()] = corps.strip("\n")

def sec(nom):
    return sections[nom].splitlines()

def sans(lignes, *motifs):
    return [l for l in lignes if not any(re.search(m, l) for m in motifs)]

BRUIT = (r"^All commands", r"^If you don't", r"^warning: couldn't attach", r"^Forwarding from", r"^error: lost connection")

def marque(lignes):  # les repères du script deviennent des commentaires lisibles
    return [re.sub(r"^\$ logs( \(courant\))?$", "(logs)", re.sub(r"^\$ logs --previous$", "(logs --previous)", l)) for l in lignes]

v = {}
v["installation"] = sec("installation")
v["symptome"] = sec("symptome")
v["vue"] = sec("vue d'ensemble")
v["web-journal"] = sec("web : journal")
m = re.search(r'upstream: "http://([0-9.]+:\d+)/', sections["web : journal"])
v["upstream"] = None
upstream = m.group(1)
v["service"] = sans(sec("service api"), r"^\$ ")
v["selecteur"] = sans(sec("selecteur corrige"), r"^\d{4}/", r"^127\.0\.0\.1")
v["describe"] = sec("api : describe")
v["events-warning"] = sec("api : events warning")
v["api-logs"] = marque(sec("api : logs"))
w = marque(sec("worker"))[2:]
w = [l.split("{")[0] if l.startswith("unable to retrieve") else l for l in w]
v["worker-logs"] = [l for l in w if not l.startswith("{")]
fin = sec("message de fin")
v["fin"] = fin[:4]
dns = sec("api : dns depuis un conteneur ephemere")
v["dns"] = [l for l in dns if not re.match(r"^dns busybox", l)]
corr = []
for l in sec("api : correction"):
    if re.match(r"^(NAME|api-)", l):
        continue
    mm = re.match(r"^/api/\S+\s+\d+ (.*)$", l)
    corr.append(mm.group(1) if mm else l)
v["api-correction"] = corr
ex = sans(sec("annuaire : exec"), *BRUIT)
erreur = [l for l in ex if l.startswith("error:")]
v["annuaire-exec"] = [l for l in ex if not l.startswith("error:")] + erreur
v["annuaire-ephemere"] = sec("annuaire : ephemere")
v["annuaire-correction"] = sans(sec("annuaire : correction"), *BRUIT, r"^conteneurs éphémères")
cp = sans(sec("worker : copie"), r"^NAME ", r"^worker-enquete ")
v["copie"] = cp
v["worker-correction"] = sec("worker : correction")
v["noeud"] = sans(sec("noeud"), r"^\(Pod node-debugger")
v["logquery"] = sans(sec("journaux du noeud par l'API"), *BRUIT)
codes = sec("exercice 2 : codes de sortie")
i = next(k for k, l in enumerate(codes) if l.startswith("ch48/"))
v["codes"] = [l for l in codes[:i] if not l.startswith('["sh"')]
v["codes-etat"] = [l for l in codes[i:] if l != "--"]
v["etat-pods"] = sec("exercice 3 : etat-pods")
c4 = sec("exercice 4 : copie et service")
j = next(k for k, l in enumerate(c4) if "--container=web" in l)
v["copie-service-1"] = sans(c4[:j], r"^\$ ", r"^Error from server")
v["copie-service-2"] = sans(c4[j:], r"^\$ ", r"^\(aucun propriétaire\)")

modele = (RACINE / "outils/modeles/deboguer.md.modele").read_text()
modele = modele.replace("@@upstream@@", f"`{upstream}`")
def remplace(mo):
    nom = mo.group(1)
    lignes = list(v[nom])
    while lignes and not lignes[-1].strip():
        lignes.pop()
    return "\n".join(lignes)
page = re.sub(r"@@([a-z0-9-]+)@@", remplace, modele)
assert "@@" not in page
(RACINE / "docs/partie-7/deboguer.md").write_text(page)
print("deboguer.md écrit")
