#!/usr/bin/env python3
"""Remplit docs/partie-7/sauvegarde.md à partir du modèle, du kit et des journaux des rejeux du chapitre 52."""
import re
from pathlib import Path

R = Path(__file__).resolve().parent.parent
OUT = R / "outils/out"
KIT = R / "kits/sauvegarde"
BRUIT = (r"^W\d{4} ", r"^(real|user|sys)\s", r"^\{\"level\"", r"^\d{4}-\d\d-\d\dT.*\t(info|warn)\t")


def sections(fichier):
    res = {}
    for bloc in re.split(r"\n### ", "\n" + (OUT / fichier).read_text()):
        if bloc.strip():
            titre, _, corps = bloc.partition("\n")
            res[titre.strip()] = [re.sub(r"\x1b\[[0-9;]*m", "", l) for l in corps.strip("\n").splitlines()]
    return res


def sans(lignes, *motifs):
    return [l for l in lignes if not any(re.search(m, l) for m in motifs + BRUIT)]


def lire(chemin):
    return chemin.read_text().rstrip("\n").splitlines()


def commentaires(lignes):
    return [re.sub(r"^\$ ", "# ", l) for l in lignes]


ET = sections("rejeu-ch52-etcd.log")
VE = sections("rejeu-ch52-velero.log")
ES = sections("rejeu-ch52-essais.log")
EX = sections("rejeu-ch52-exercices.log")
v = {}
sv = sans(ET["sauvegarde"])
v["ouverture"] = [l for l in sv if l[:1] in "┌│├└"]
v["sauvegarde-etcd"] = [l for l in sv if not re.match(r"^(total |-rw)", l)]
v["contenu"] = ET["contenu"]
v["restauration-etcd"] = sans(ET["restauration"], r"^\d\d:\d\d:\d\d$")
ve = ET["verification"]
v["verification-etcd"] = sans(ve[:ve.index(next(l for l in ve if "apres" in l)) + 1], r"^NAME +STATUS +ROLES", r"^minikube ")
v["valeurs-velero"] = lire(KIT / "valeurs-velero.yaml")
v["installation"] = ES["installation"]
eh = sans(ES["essai hostpath"])
i = eh.index(next(l for l in eh if l.startswith("Restore completed")))
v["essai-hostpath"] = [re.sub(r'^level=warning msg="([^"]*)".*', r'level=warning msg="\1"', l) for l in eh[:i]]
v["essai-hostpath-restauration"] = eh[i:]
v["essai-csi"] = sans(ES["essai csi"], r"^PVC +CLASSE", r"^carnet +csi")
v["aide-yaml"] = lire(KIT / "aide-restauration.yaml")
v["miroir"] = ES["miroir"]
v["crochets"] = lire(KIT / "postgres-crochets.yaml")
v["colis-avant"] = [l for l in VE["colis avant"] if "|" in l]
v["colis-sauvegarde"] = sans(VE["colis sauvegarde"], r"^Phase:")
cc = VE["colis contenu"]
v["colis-contenu"] = [l for l in cc if not re.search(r"mot de passe|^backups/", l)]
v["catastrophe"] = sans(VE["colis catastrophe"], r"^\d\d:\d\d:\d\d$")
v["coince"] = lire(OUT / "ch52r/coince.txt")
lb = lire(OUT / "ch52r/liberer-pv.txt")
v["liberer"] = lb[lb.index(next(l for l in lb if l.startswith("$ kubectl patch"))) + 1:]
rc = sans(VE["colis restauration"])
v["restauration-colis"] = rc[:rc.index(next(l for l in rc if l.startswith("NAME") and "READY" in l))]
kd = lire(OUT / "ch52r/keda.txt")
v["keda"] = commentaires(kd[kd.index(next(l for l in kd if "delete hpa" in l)) + 1:])
v["keda"] = [l for l in v["keda"] if not l.startswith("# velero restore")]
ap = VE["colis apres"]
apres = lire(OUT / "ch52r/apres.txt")
v["colis-apres"] = apres + [l for l in ap if re.match(r"^\d+\.\d+\.\d+\.\d+$|^(cours/|passerelle=|pod-security)|^(networkpolicy|horizontal|servicemonitor|prometheusrule)", l)]
pl = VE["planification"]
v["planification"] = pl[:pl.index(next(l for l in pl if l.startswith("NAME") and "ERRORS" in l))]
v["ex2"] = EX["ex2 autre namespace"]
v["ex3"] = EX["ex3 fraicheur avant"] + EX["ex3 fraicheur apres"]
v["ex4"] = EX["ex4 sauvegarde plus propre"]


def remplace(mo):
    l = list(v[mo.group(1)])
    while l and not l[-1].strip():
        l.pop()
    return "\n".join(l)


page = re.sub(r"@@([a-z0-9-]+)@@", remplace, (R / "outils/modeles/sauvegarde.md.modele").read_text())
assert not re.search(r"@@[a-z0-9-]+@@", page)
(R / "docs/partie-7/sauvegarde.md").write_text(page)
print("sauvegarde.md écrit")
