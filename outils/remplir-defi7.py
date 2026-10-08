#!/usr/bin/env python3
"""Remplit docs/partie-7/defi.md à partir du modèle, des fichiers du kit et des journaux du rejeu."""
import re
from pathlib import Path

R = Path(__file__).resolve().parent.parent
OUT = R / "outils/out/defi7"
KIT = R / "kits/defi-7"


def sections(fichier):
    res = {}
    for bloc in re.split(r"\n### ", "\n" + (OUT / fichier).read_text()):
        if bloc.strip():
            titre, _, corps = bloc.partition("\n")
            res[titre.strip()] = corps.strip("\n").splitlines()
    return res


def sans(lignes, *motifs):
    return [l for l in lignes if not any(re.search(m, l) for m in motifs)]


S = sections("rejeu-defi7.log")
S.update(sections("rejeu-defi7-impact.log"))
S.update(sections("rejeu-defi7-grille.log"))
v = {}

v["page"] = S["page"]
v["declenchement"] = [l for l in S["declenchement"] if l.startswith("mise en production")]
v["grille-pendant"] = [re.sub(r"/\S*/aucun-post-mortem\.md", "post-mortem.md", l) for l in S["grille pendant"]]

sy = S["symptomes"]
fin_pods = next(i for i, l in enumerate(sy) if not re.match(r"^(NAME|\S+-\S+\s+\d+/\d+)", l))
v["symptomes-pods"] = sy[:fin_pods]
prom = sy[fin_pods:]
v["symptomes-prom"] = (["# la file"] + [prom[0].strip()]
                       + ["# les erreurs 5xx : aucune série"]
                       + ["# le 95e centile, en secondes"] + [l.replace("p95 : ", "") for l in prom if l.startswith("p95")]
                       + ["# les alertes actives de colis"] + [l for l in prom if l.startswith("alertname")])

wk = S["worker"]
i = next(k for k, l in enumerate(wk) if l.startswith("RAISON"))
v["worker-describe"] = [l for l in wk[:i] if "colis-config" not in l]
v["worker-evenements"] = wk[i:]

ch = S["changements"]
v["changements"] = [l for l in ch[:ch.index("")] if l.strip()]
reste = ch[ch.index("") + 1:]
v["champs"] = [l for l in reste[:reste.index("")] if l.strip()]
v["rs"] = (["$ kubectl -n colis rollout history deployment/worker | tail -2"]
           + [l for l in reste[reste.index("") + 1:] if re.match(r"^\d+\s", l)]
           + ["$ kubectl -n colis get rs -l 'app.kubernetes.io/name in (worker,api)' --sort-by=.metadata.creationTimestamp \\", "#     -o custom-columns=RS:.metadata.name,CREE:.metadata.creationTimestamp,VOULUS:.spec.replicas,MEMOIRE:.spec.template.spec.containers[0].resources.requests.memory | tail -5"]
           + [l for l in reste if re.match(r"^(api|worker)-", l)])
v["rs"] = [re.sub(r"^\$ ", "# ", l) for l in v["rs"]]

c1 = S["premier correctif"]
v["correctif-1"] = [re.sub(r"^file :\s+", "file d'estimation : ", l) for l in c1 if not l.startswith("[")]
v["worker-apres"] = S["worker apres"]

lk = S["loki"]
ph2 = lk.index("# phase 2 : les dernières lignes d'un worker")
v["loki-phase1"] = [l for l in lk[:ph2] if not l.startswith("#")]
v["loki-phase2"] = lk[ph2 + 1:]
v["reseau"] = S["reseau"]
v["correctif-2"] = sans(S["second correctif"], r"^Defaulted container")
v["correctif-2"] = [re.sub(r"^\[(\d\d:\d\d:\d\d)\] ", r"# \1 UTC : ", l) for l in v["correctif-2"]]
v["page-fin"] = S["page fin"]
v["purge"] = [l for l in S["purge"] if not l.startswith("[")]
v["impact"] = S["impact final"]

ip = S["impact"]
def nombre(motif, arrondi=0):
    l = next(l for l in ip if l.startswith(motif))
    x = float(l.split()[-1])
    return f"{x:.{arrondi}f}"
codes = sorted((l.split("=")[1].split()[0], float(l.split()[-1])) for l in ip if l.strip().startswith("code="))
pic = float(next(l for l in ip if l.startswith("pic mémoire")).split()[-1])
p95 = max(float(l.split()[-1]) for l in ip if l.startswith("p95 au plus haut"))
v["impact-prom"] = [
    f"fenêtre                       : {next(l for l in ip if l.startswith('fenêtre')).split(':')[1].strip()}",
    f"file au plus haut             : {nombre('file au plus haut')} colis",
    f"requêtes                      : {nombre('requêtes')}",
] + [f"  code {c}                    : {n:.0f}" for c, n in codes] + [
    f"95e centile au plus haut      : {p95 * 1000:.0f} ms",
    f"redémarrages du worker        : {nombre('redémarrages du worker', 1)}",
    f"pic de mémoire du worker      : {pic / 2**20:.0f} Mi",
]
ev = S["evenements"]
v["evenements"] = ev[:ev.index("# premiers événements des Pods du worker")]
v["grille-finale"] = [l.replace("kits/defi-7/corrige/post-mortem.md", "post-mortem.md") for l in S["grille finale"]]
v["post-mortem"] = (KIT / "corrige/post-mortem.md").read_text().rstrip("\n").splitlines()
v["impact-py"] = (KIT / "corrige/impact.py").read_text().rstrip("\n").splitlines()


def remplace(mo):
    l = list(v[mo.group(1)])
    while l and not l[-1].strip():
        l.pop()
    return "\n".join(l)


page = re.sub(r"@@([a-z0-9-]+)@@", remplace, (R / "outils/modeles/defi7.md.modele").read_text())
assert not re.search(r"@@[a-z0-9-]+@@", page)
(R / "docs/partie-7/defi.md").write_text(page)
print("defi.md écrit")
