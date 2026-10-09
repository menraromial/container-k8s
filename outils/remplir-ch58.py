#!/usr/bin/env python3
"""Remplit docs/partie-8/rollouts.md à partir du modèle, des fichiers du kit et des journaux des rejeux."""
import re
from pathlib import Path

R = Path(__file__).resolve().parent.parent
OUT = R / "outils/out/ch58r"
KIT = R / "kits/rollouts"


def sections(fichier):
    res = {}
    for bloc in re.split(r"\n### ", "\n" + (OUT / fichier).read_text()):
        if bloc.strip():
            titre, _, corps = bloc.partition("\n")
            res[titre.strip()] = corps.strip("\n").splitlines()
    return res


def fichier(chemin):
    return Path(chemin).read_text().rstrip("\n").splitlines()


def document(chemin, kind):
    """Le document YAML de ce kind dans un fichier à plusieurs documents, sans le séparateur."""
    for doc in Path(chemin).read_text().split("\n---\n"):
        if re.search(rf"^kind: {kind}$", doc, re.M):
            return [l for l in doc.strip("\n").splitlines() if not l.startswith("# ")]
    raise KeyError(kind)


def depuis(lignes, debut):
    i = next(k for k, l in enumerate(lignes) if l.startswith(debut))
    return lignes[i:]


def virgules(lignes):
    return [re.sub(r"(\d)\.(\d+) s\b", r"\1,\2 s", l) for l in lignes]


def avant(lignes, motif, commentaire):
    """Insère une ligne de commentaire avant chaque ligne qui correspond au motif."""
    res = []
    for l in lignes:
        if re.search(motif, l):
            res.append(commentaire)
        res.append(l)
    return res


def poids(lignes):
    return avant(lignes, r'^\["(vitrine|simple)-', "# poids")


S = sections("rejeu-ch58.log")
X = sections("rejeu-ch58-exercices.log")
v = {}

ins = S["installation"]
k = next(n for n, l in enumerate(ins) if "--server-side" in l)
v["installation-1"] = ["# kubectl create namespace argo-rollouts"] + [re.sub(r"^\$ ", "# ", l) for l in ins[:k]]
v["installation-2"] = [re.sub(r"^\$ ", "# ", l) for l in ins[k:]]
v["installation-2"] = avant(v["installation-2"], r"^analysisruns", "# kubectl get crd | grep argoproj (CRD d'Argo Rollouts)")
v["installation-2"] = avant(v["installation-2"], r"^kubectl-argo-rollouts", "# kubectl argo rollouts version --short")

v["f-greffon"] = document(KIT / "greffon-gateway.yaml", "ConfigMap")
g = S["greffon"]
g = avant(g, r"^\d+ gatewayapi", "# taille et empreinte du binaire téléchargé")
g = avant(g, r'^\{"tag_name"', "# la version créée dans le dépôt cours/outils de Gitea, avec le binaire en pièce jointe")
g = avant(g, r"^configmap/", "# kubectl apply -f greffon-gateway.yaml ; kubectl -n argo-rollouts rollout restart deployment/argo-rollouts")
g = avant(g, r"^Downloading plugin", "# kubectl -n argo-rollouts logs deploy/argo-rollouts | grep -i download")
g = avant(g, r"^NAME ", "# kubectl -n argo-rollouts get pods")
v["greffon"] = virgules(g)

v["f-route"] = document(KIT / "01-services-route.yaml", "HTTPRoute")
v["f-rollout"] = depuis(fichier(KIT / "02-rollout.yaml"), "  strategy:")

p = S["premier deploiement"]
p = ["# kubectl apply -f 01-services-route.yaml -f 02-rollout.yaml"] + p
p = avant(p, r"^Progressing - more", "# kubectl argo rollouts status vitrine -n ch58")
p = avant(p, r"^Name:", "# kubectl argo rollouts get rollout vitrine -n ch58")
v["premier"] = poids(p)

c = S["canari"]
c = avant(c, r"^Name:", "# kubectl argo rollouts get rollout vitrine -n ch58 (début)")
c = avant(c, r"^RS ", "# kubectl -n ch58 get rs")
c = avant(c, r"^étape 3", "# 20 s plus tard : étape, spec.paused, status.pauseConditions")
v["canari"] = poids(c)

pr = S["promotion"]
pr = ["# kubectl argo rollouts promote vitrine -n ch58"] + pr
pr = avant(pr, r"^Progressing - waiting for rollout", "# kubectl argo rollouts status vitrine -n ch58")
pr = avant(pr, r"^NAME ", "# kubectl argo rollouts get rollout vitrine -n ch58 (arbre)")
pr = avant(pr, r"^RS ", "# 35 s plus tard : kubectl -n ch58 get rs")
v["promotion"] = virgules(poids(pr))

v["f-moniteur"] = fichier(KIT / "03-moniteur.yaml")
v["f-analyse"] = [l for l in fichier(KIT / "04-analyse.yaml") if not l.startswith("# ")]
v["f-rollout-analyse"] = depuis(fichier(KIT / "05-rollout-analyse.yaml"), "  strategy:")

a = S["analyse"]
i = next(n for n, l in enumerate(a) if l.startswith("--- une mauvaise"))
j = next(n for n, l in enumerate(a) if l.startswith("--- une bonne"))
m = a[i + 2:j]
m = ["# kubectl -n ch58 patch rollout vitrine ... --random-error=true"] + m
m = avant(m, r"^Name:", "# kubectl argo rollouts get rollout vitrine -n ch58 (début)")
m = avant(m, r"^ANALYSE ", "# kubectl -n ch58 get analysisrun")
m = avant(m, r'^\{"name"', "# mesures de l'analyse (status.metricResults)")
v["analyse-mauvaise"] = virgules(poids(m))
b = a[j + 2:]
b = ["# kubectl -n ch58 patch rollout vitrine ... (sans args, image 6.14.1)"] + b
b = avant(b, r"^ANALYSE ", "# kubectl -n ch58 get analysisrun")
b = avant(b, r'^\{"name"', "# mesures de la nouvelle analyse")
b = avant(b, r"^NAME ", "# kubectl argo rollouts get rollout vitrine -n ch58 (arbre)")
v["analyse-bonne"] = virgules(b)

v["f-bleuvert"] = depuis(fichier(KIT / "06-bleu-vert.yaml"), "  strategy:")
bv = S["bleu-vert"]
k = next(n for n, l in enumerate(bv) if l.startswith("NAME ") and "CPU" in l)
corps = bv[:k]
res = ["# kubectl apply -f 06-bleu-vert.yaml"]
client = False
for l in corps:
    if l.startswith("Progressing - more"):
        res.append("# kubectl argo rollouts status bv -n ch58")
    elif l.startswith("SERVICE "):
        res.append("# sélecteurs des deux Services")
    elif l.startswith('rollout "bv" image'):
        res.append("# kubectl argo rollouts set image bv podinfo=ghcr.io/stefanprodan/podinfo:6.15.0 -n ch58")
    elif l.startswith("Name:"):
        res.append("# kubectl argo rollouts get rollout bv -n ch58 (début)")
    elif re.match(r"^\d\d:\d\d:\d\d actif=", l) and not client:
        res.append("# journal du client (suite)" if any(x.startswith("# journal") for x in res) else "# journal du client, une requête par seconde sur chaque Service")
        client = True
    elif l.startswith("promotion à "):
        res.append("# " + l[len("promotion à "):] + " : kubectl argo rollouts promote bv -n ch58")
        client = False
        continue
    elif l.startswith("RS "):
        res.append("# kubectl -n ch58 get rs -l app=bv" if not any(x.startswith("RS ") for x in res) else "# 35 s plus tard")
    elif l.startswith("--- 35 s"):
        continue
    res.append(l)
v["bleuvert"] = res
v["top"] = ["# kubectl -n argo-rollouts top pods"] + bv[k:]

e1 = X["ex1 abandon"]
e1 = [re.sub(r"^\$ ", "# ", l) for l in e1 if not l.startswith("bv-")]
e1 = ["# suite de l'exercice 3 : le Rollout est à l'étape à 50 %"] + e1
e1 = avant(e1, r"^(Degraded|Paused) étape", "# phase et étape du Rollout")
e1 = avant(e1, r"^RS ", "# kubectl -n ch58 get rs (ReplicaSets non vides)")
e1 = avant(e1, r"^Healthy$", "# kubectl argo rollouts status vitrine -n ch58")
e1 = avant(e1, r"^vitrine-558fb9698f-5 ", "# les deux dernières analyses")
v["ex1"] = poids(e1)

e2 = [l for l in X["ex2 sans routage"]]
e2 = ["# kubectl apply -f sans-routage.yaml"] + e2
e2 = avant(e2, r"^Healthy$", "# kubectl argo rollouts status simple -n ch58")
e2 = avant(e2, r'^rollout "simple" image', "# kubectl argo rollouts set image simple podinfo=ghcr.io/stefanprodan/podinfo:6.15.0 -n ch58")
e2 = avant(e2, r"^  SetWeight", "# kubectl argo rollouts get rollout simple -n ch58 (extrait)")
e2 = avant(e2, r"^RS ", "# kubectl -n ch58 get rs -l app=simple")
v["ex2"] = e2

e3 = X["ex3 repartition"]
e3 = ["# kubectl argo rollouts set image vitrine podinfo=ghcr.io/stefanprodan/podinfo:6.15.0 -n ch58"] + e3
v["ex3"] = [re.sub(r"^\$ ", "# ", l) for l in e3]

e4 = X["ex4 bleu-vert annule"]
e4 = ["# kubectl argo rollouts set image bv podinfo=ghcr.io/stefanprodan/podinfo:6.14.1 -n ch58"] + e4
e4 = [re.sub(r"^\$ ", "# ", l) for l in e4]
e4 = [re.sub(r"^--- 35 s plus tard", "# 35 s plus tard", l) for l in e4]
e4 = avant(e4, r"^(Paused|Degraded)$", "# phase du Rollout")
e4 = avant(e4, r"^SERVICE ", "# sélecteurs des deux Services")
e4 = avant(e4, r"^RS ", "@@")
e4 = [l for l in e4 if l != "@@"]
v["ex4"] = e4


def remplace(mo):
    l = list(v[mo.group(1)])
    while l and not l[-1].strip():
        l.pop()
    return "\n".join(l)


page = re.sub(r"@@([a-z0-9-]+)@@", remplace, (R / "outils/modeles/rollouts.md.modele").read_text())
assert not re.search(r"@@[a-z0-9-]+@@", page)
(R / "docs/partie-8/rollouts.md").write_text(page)
print("rollouts.md écrit")
