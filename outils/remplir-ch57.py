#!/usr/bin/env python3
"""Remplit docs/partie-8/gitops.md à partir du modèle, des fichiers du kit et des journaux des rejeux."""
import re
from pathlib import Path

R = Path(__file__).resolve().parent.parent
OUT = R / "outils/out/ch57r"
KIT = R / "kits/gitops"


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


def virgules(lignes):
    return [re.sub(r"(\d)\.(\d+) s\b", r"\1,\2 s", re.sub(r"(?<![\d.])\.(\d+) s\b", r"0,\1 s", l)) for l in lignes]


S = sections("rejeu-ch57.log")
X = sections("rejeu-ch57-exercices.log")
v = {}

g = fichier(KIT / "gitea.yaml")
i = next(k for k, l in enumerate(g) if l.strip() == "containers:")
j = next(k for k in range(i, len(g)) if g[k].strip().startswith("ports:"))
v["f-gitea"] = g[i:j]
v["f-overlay"] = fichier(KIT / "depot/overlays/staging/kustomization.yaml")
v["gitea"] = sans(S["gitea"], r"^Waiting for")
ar = S["argocd"]
k = next(n for n, l in enumerate(ar) if "scaled" in l)
v["argocd"] = ar[:k]
v["argocd-top"] = ar[k:]
v["connexion"] = S["connexion"]
v["application"] = S["application"]
v["synchronisation"] = virgules(S["synchronisation"])
ch = S["changement"]
v["changement"] = virgules([re.sub(r'^\{"level":"fatal","msg":"([^"]*)".*', r'\1', l) for l in ch])
au = S["automatique"]
v["automatique"] = virgules(au)
v["webhook-refus"] = X["webhook"][:1]
v["webhook-ok"] = virgules(sans(X["webhook"][1:], r"Deprecation", r"^Warning: metadata.finalizers"))
v["derive"] = virgules(S["derive"])
v["selfheal"] = virgules([l for l in X["self-heal"] if l.startswith("écart")])
v["elagage"] = virgules(S["elagage"])
v["f-hpa"] = fichier(KIT / "hpa.yaml")
v["f-application"] = fichier(KIT / "application.yaml")
v["hpa"] = virgules(S["hpa"])
v["f-racine"] = fichier(KIT / "racine.yaml")
v["appofapps"] = sans(S["app of apps"], r"^Warning: metadata.finalizers")
v["cascade-1"] = [
    "$ kubectl -n argocd delete application racine",
    'application.argoproj.io "racine" deleted from argocd namespace',
    "$ kubectl -n argocd get applications",
    "No resources found in argocd namespace.",
    "$ kubectl -n colis-staging get all",
    "NAME                          READY   STATUS    RESTARTS        AGE",
    "pod/api-7979fb6dc9-87kbt      1/1     Running   2 (3m28s ago)   22m",
    "pod/api-7979fb6dc9-hbjqc      1/1     Running   0               9m44s",
    "pod/postgres-0                1/1     Running   0               26m",
    "pod/redis-578785659c-9wjc2    1/1     Running   0               26m",
    "...",
]
v["cascade-1"] = [re.sub(r"^\$ ", "# ", l) for l in v["cascade-1"]]
e1 = X["ex1 retour arriere"]
v["ex1"] = virgules([re.sub(r"^\$ ", "# ", l) for l in e1 if not re.search(r"trois répliques$", l)])
v["ex2"] = virgules(X["ex2 prune false"]) + ["# après la suppression de l'Application"] + [l for l in X["cascade"] if not l.startswith("namespace")]
v["ex3"] = [re.sub(r"^\$ ", "# ", l) for l in virgules(X["ex3 etat"])]


def remplace(mo):
    l = list(v[mo.group(1)])
    while l and not l[-1].strip():
        l.pop()
    return "\n".join(l)


page = re.sub(r"@@([a-z0-9-]+)@@", remplace, (R / "outils/modeles/gitops.md.modele").read_text())
assert not re.search(r"@@[a-z0-9-]+@@", page)
(R / "docs/partie-8/gitops.md").write_text(page)
print("gitops.md écrit")
