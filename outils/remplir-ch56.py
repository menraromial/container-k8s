#!/usr/bin/env python3
"""Remplit docs/partie-8/cnpg.md à partir du modèle, des fichiers du kit et des journaux des rejeux."""
import re
from pathlib import Path

R = Path(__file__).resolve().parent.parent
OUT = R / "outils/out/ch56r"
KIT = R / "kits/cnpg"


def sections(fichier):
    res = {}
    for bloc in re.split(r"\n### ", "\n" + (OUT / fichier).read_text()):
        if bloc.strip():
            titre, _, corps = bloc.partition("\n")
            res[titre.strip()] = corps.strip("\n").splitlines()
    return res


def sans(lignes, *motifs):
    return [l for l in lignes if not any(re.search(m, l) for m in motifs)]


def fichier(chemin):
    return Path(chemin).read_text().rstrip("\n").splitlines()


def attente(lignes):
    """Ne garde que la première et la dernière ligne « Waiting for ... »."""
    w = [l for l in lignes if l.startswith("Waiting for")]
    res, vu = [], False
    for l in lignes:
        if l.startswith("Waiting for"):
            if not vu:
                res.append(l)
                vu = True
            continue
        res.append(l)
    return res


D = sections("rejeu-ch56-demo.log")
C = sections("rejeu-ch56-colis.log")
T = sections("rejeu-ch56-retrait.log")
X = sections("rejeu-ch56-exercices.log")
v = {}

v["operateur"] = attente(D["operateur"])
v["greffon"] = attente(sans(D["greffon et stockage"], r"kill: "))
v["f-01"] = fichier(KIT / "01-cluster.yaml")
v["cluster"] = D["cluster"]
an = D["anatomie"]
v["anatomie-1"] = (["$ kubectl -n ch56 get statefulsets,deployments"] + an[:1]
                   + ["$ kubectl -n ch56 get pod essai-1 -o json | jq -c '{proprietaire, initContainers, containers}'"] + an[1:2])
v["anatomie-1"] = [re.sub(r"^\$ ", "# ", l) for l in v["anatomie-1"]]
i = an.index(next(l for l in an if l.startswith("Cluster Summary")))
v["anatomie-2"] = ["# kubectl -n ch56 get pods -L cnpg.io/instanceRole"] + an[2:6] + ["# les Services et leurs sélecteurs"] + an[6:10] + ["# les clés du Secret essai-app"] + an[10:i]
v["status"] = an[i:]
v["replication"] = D["replication"]
ec = fichier(KIT / "ecrivain.yaml")
j = next(k for k, l in enumerate(ec) if l.strip().startswith("env:"))
v["f-ecrivain"] = ec[j - 2:]
ba = D["bascule"]
v["bascule"] = sans(ba, r"^pod/ecrivain")
v["bascule-programmee"] = D["bascule programmee"]
v["f-02"] = fichier(KIT / "02-sauvegarde.yaml")
v["f-03"] = fichier(KIT / "03-cluster-sauvegarde.yaml")[-5:]
sa = D["sauvegarde continue"]
k = next(n for n, l in enumerate(sa) if l.startswith("backup.postgresql.cnpg.io/premiere"))
v["sauvegarde"] = sa[:k]
v["f-04"] = fichier(KIT / "04-sauvegarde-complete.yaml")
v["sauvegarde-complete"] = sa[k:-2] + ["# le contenu du compartiment, par préfixe"] + sa[-2:] if False else sa[k:]
v["accident"] = D["accident"]
v["f-05"] = fichier(OUT / "demo/05-restauration.yaml")
v["restauration"] = [l for l in D["restauration"] if not l.startswith("19:")]

v["avant"] = C["avant"]
v["images"] = C["images"]
pol = fichier(KIT / "colis/11-politiques.yaml")
v["f-politique"] = pol[:pol.index("---")]
v["politiques"] = C["politiques"]
v["maintenance"] = C["maintenance"]
v["f-colis-pg"] = fichier(KIT / "colis/13-colis-pg.yaml")
v["creation"] = C["creation"]
v["verification"] = C["verification"]
ba = fichier(KIT / "colis/basculer.sh")
v["f-basculer"] = [l for l in ba if not l.startswith("#!")]
v["bascule-colis"] = attente(C["bascule"])
v["fonctionnement"] = C["fonctionnement"] + ["# sauvegarde complète de colis-pg"] + C["sauvegarde colis"]
v["memoire-noeud"] = [re.search(r"mémoire du nœud : (\S+)", "\n".join(T["apres"])).group(1).replace("GiB", " Gio").replace(".", ",")]
v["retrait"] = T["retrait"] + ["# après le retrait"] + T["apres"] + ["# la purge, par la nouvelle base"] + T["purge apres"]

e1 = X["ex1 bascule sous charge"]
a = e1.index("--- réglage par défaut")
b = e1.index("--- smartShutdownTimeout à 10 s")
v["ex1-defaut"] = e1[a + 1:b]
v["ex1-court"] = ["$ kubectl -n colis patch cluster colis-pg --type=merge -p '{\"spec\":{\"smartShutdownTimeout\":10}}'"] + e1[b + 1:]
v["ex1-court"] = [re.sub(r"^\$ ", "# ", l) for l in v["ex1-court"]]
v["ex2"] = [re.sub(r"^\$ ", "# ", l) for l in X["ex2 planification"]]
v["ex3"] = X["ex3 retard"]
v["ex4"] = X["ex4 metriques"]


def remplace(mo):
    l = list(v[mo.group(1)])
    while l and not l[-1].strip():
        l.pop()
    return "\n".join(l)


page = re.sub(r"@@([a-z0-9-]+)@@", remplace, (R / "outils/modeles/cnpg.md.modele").read_text())
assert not re.search(r"@@[a-z0-9-]+@@", page)
(R / "docs/partie-8/cnpg.md").write_text(page)
print("cnpg.md écrit")
