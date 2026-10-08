#!/usr/bin/env python3
"""Remplit docs/partie-7/montee.md à partir du modèle et du journal du rejeu du chapitre 53."""
import re
from pathlib import Path

R = Path(__file__).resolve().parent.parent
OUT = R / "outils/out"


def sections(fichier):
    res = {}
    for bloc in re.split(r"\n### ", "\n" + (OUT / fichier).read_text()):
        if bloc.strip():
            titre, _, corps = bloc.partition("\n")
            res[titre.strip()] = [l for l in corps.strip("\n").splitlines() if not re.match(r"^W\d{4} ", l)]
    return res


S = sections("rejeu-ch53.log")
v = {}
v135 = S["versions 1.35"]
v["ouverture"] = v135[:3]
v["versions-135"] = [l for l in v135 if not re.fullmatch(r"\d+", l)]
v["deprecies-135"] = S["deprecies 1.35"]
v["sauvegarde"] = [l for l in S["sauvegarde"] if not l.startswith("ssh:")]
v["montee-136"] = S["montee 1.36"]
v["montee-137"] = S["montee 1.37"]
v["duree-136"] = ["Un peu plus de quatre minutes"]
v["duree-137"] = ["Moins de trois minutes"]
a = S["apres 1.36"]
i = next(k for k, l in enumerate(a) if l.startswith("Waiting for daemon set"))
j = next(k for k, l in enumerate(a) if l.startswith("POD "))
v["apres-136"] = a[:i] + a[j:]
v["apres-136-suite"] = a[i:j]
b = S["apres 1.37"]
v["apres-137"] = b[:b.index(next(l for l in b if l.startswith("21a22")))]
v["diff-api"] = b[b.index("--- 1.35 -> 1.37") + 1:]
d = S["deprecies 1.37"]
v["endpoints"] = [l for l in d if not l.startswith("{")]
rejeu = (R / "outils/rejeu-ch53.sh").read_text()
v["migration-yaml"] = re.search(r"cat > migration.yaml <<'YAML'\n(.*?)\nYAML", rejeu, re.S).group(1).splitlines()
v["migration"] = S["migration"]
v["retour"] = [l for l in S["retour arriere"] if not l.startswith("Server Version")]
v["ex2"] = (OUT / "ch53r/ex2.txt").read_text().rstrip("\n").splitlines()
m = S["montee 1.36"]
v["ex3"] = m[m.index(next(l for l in m if "requêtes en" in l)):]


def remplace(mo):
    l = list(v[mo.group(1)])
    while l and not l[-1].strip():
        l.pop()
    return "\n".join(l)


page = re.sub(r"@@([a-z0-9-]+)@@", remplace, (R / "outils/modeles/montee.md.modele").read_text())
assert not re.search(r"@@[a-z0-9-]+@@", page)
(R / "docs/partie-7/montee.md").write_text(page)
print("montee.md écrit")
