#!/usr/bin/env python3
"""Remplit docs/partie-8/crd.md à partir du modèle, des fichiers du kit et des journaux des rejeux."""
import re
from pathlib import Path

R = Path(__file__).resolve().parent.parent
OUT = R / "outils/out/ch54r"
KIT = R / "kits/crd"


def sections(fichier):
    res = {}
    for bloc in re.split(r"\n### ", "\n" + (OUT / fichier).read_text()):
        if bloc.strip():
            titre, _, corps = bloc.partition("\n")
            res[titre.strip()] = corps.strip("\n").splitlines()
    return res


def sous(lignes, debut, fin="--- "):
    """Les lignes après « --- debut », jusqu'à la prochaine ligne qui commence par fin."""
    i = lignes.index(f"--- {debut}") + 1
    j = next((k for k in range(i, len(lignes)) if lignes[k].startswith(fin)), len(lignes))
    return lignes[i:j]


def fichier(nom):
    return (KIT / nom).read_text().rstrip("\n").splitlines()


def bloc(nom, debut, fin):
    """Les lignes d'un fichier du kit, de la première qui contient debut à la première suivante qui contient fin (exclue)."""
    l = fichier(nom)
    i = next(k for k, x in enumerate(l) if debut in x)
    j = next(k for k in range(i + 1, len(l)) if fin in l[k])
    return l[i:j]


def commandes(lignes):
    return [re.sub(r"^\$ ", "# ", l) for l in lignes]


S = sections("rejeu-ch54.log")
X = sections("rejeu-ch54-exercices.log")
v = {}

av = S["avant"]
v["avant"] = av[:1]
m = re.search(r"types servis : (\d+), définitions : (\d+)", av[1])
v["nb-types"], v["nb-crd"] = [m.group(1)], [m.group(2)]

mi = S["minimal"]
v["minimal"] = mi[:4]
v["decouverte"] = mi[4:]

po = S["premier objet"]
v["premier"] = po[:4]
v["etcd-colis"] = [po[4]]
v["etcd-pod"] = ["# même lecture, pour la clé " + po[5]] + po[6:]

v["sans-schema"] = S["sans schema"]
sc = S["schema"]
v["schema-relu"] = [sc[0]] + ["# mauvais, relu"] + sous(sc, "mauvais, relu") + ["# principal, relu"] + sous(sc, "principal, relu")
v["schema-strict"] = sous(sc, "mauvais, réappliqué")
v["schema-ratchet"] = sous(sc, "mauvais, réappliqué sans validation côté client") + [
    "$ sed 's/name: mauvais/name: mauvais-2/' mauvais.yaml | kubectl apply --validate=false -f -"] + sous(sc, "la même chose, sous un autre nom")
v["schema-ratchet"] = commandes(v["schema-ratchet"])
v["schema-invalide"] = sous(sc, "invalide")
v["schema-vide"] = sous(sc, "sans spec")
v["schema-mini"] = sous(sc, "le minimum")

cp = S["cel pannes"]
v["cel-defaut"] = cp[:1]
v["cel-cout"] = ["# " + cp[1].strip()] + cp[2:]
ce = S["cel"]
i = ce.index("--- le fichier d'origine, réappliqué")
v["cel"] = commandes([l for l in ce[1:i]])
v["cel-fichier"] = ce[i + 1:]

co = S["complet"]
k = next(n for n, l in enumerate(co) if l.startswith("GROUP:"))
v["complet-get"] = co[1:k]
v["explain"] = [l for l in co[k:] if l.strip() or True]
while v["explain"] and not v["explain"][-1].strip():
    v["explain"].pop()
v["explain"] = re.sub(r"\n{3,}", "\n\n", "\n".join(v["explain"])).splitlines()

v["status"] = commandes(["$ kubectl -n ch54 get colis principal -o jsonpath='generation={.metadata.generation} status={.status}'"] + S["status"])
sca = S["scale"]
v["scale"] = sca[:-3]
v["champs"] = ["# --field-selector spec.version=2.10.0"] + sca[-3:-1] + ["# --field-selector spec.api.replicas=4"] + sca[-1:]

ve = S["versions"]
v["versions-a"] = ve[:3]
v["versions-lire"] = ["# lu en v1alpha1"] + sous(ve, "lu en v1alpha1") + ["# lu en v1"] + sous(ve, "lu en v1")
v["versions-etcd"] = commandes(["# dans etcd"] + sous(ve, "dans etcd"))
v["versions-ancien"] = (["# créé en v1alpha1"] + sous(ve, "un objet créé en v1alpha1")[:2]
                        + ["# dans etcd"] + sous(ve, "un objet créé en v1alpha1")[2:3]
                        + ["# relu en v1"] + sous(ve, "un objet créé en v1alpha1")[3:])
v["retrait"] = S["retrait trop tot"]
mg = S["migration"]
v["migration"] = (mg[:3] + ["# dans etcd"] + [l for l in mg if l.startswith("/registry/")]
                  + ["# storedVersions"] + [l for l in mg if l.startswith("[")]
                  + ["$ kubectl apply -f 06-colis-v1-seul.yaml"] + [l for l in mg if "configured" in l]
                  + ["$ kubectl api-resources --api-group=cours.example.com"] + [l for l in mg if l.startswith(("NAME", "colis "))]
                  + ["$ kubectl -n ch54 get colis.v1alpha1.cours.example.com principal"] + [l for l in mg if l.startswith("error")])
v["migration"] = commandes(v["migration"])
v["f-migration"] = (OUT / "migration.yaml").read_text().rstrip("\n").splitlines()

rb = S["rbac"]
v["rbac-avant"] = [l for l in rb[:4] if l.startswith("list")]
v["rbac-apres"] = commandes(["$ kubectl apply -f 07-roles.yaml"] + rb[4:6] + [
    "$ kubectl auth can-i list colis.cours.example.com -n ch54 --as=system:serviceaccount:ch54:lecteur"] + [rb[6]] + [
    "$ kubectl auth can-i create colis.cours.example.com -n ch54 --as=system:serviceaccount:ch54:lecteur"] + [rb[7]] + [
    "$ kubectl get clusterrole view -o json | jq -c '[.rules[] | select(.apiGroups | index(\"cours.example.com\"))]'"] + rb[8:])
v["rbac-apres"] = [l.replace("list colis : ", "").replace("create colis : ", "") for l in v["rbac-apres"]]
v["rbac-avant"] = [l.replace("list colis : ", "") for l in v["rbac-avant"]]

cu = S["cout"]
v["cout"] = [l for l in cu if l.startswith(("avant", "50 ", "après"))]
v["cout"] = [l.replace("50 définitions établies en 11.0 s", "50 définitions établies en 11,0 s").replace("10.9 s", "10,9 s") for l in v["cout"]]

su = S["suppression"]
v["suppression"] = ["# " + su[0], "# finaliseurs : " + (su[1] or "[]")] + su[2:4] + ["# clés restantes sous /registry/cours.example.com : " + su[4]]
v["ensemble"] = commandes(["$ kubectl apply -f ensemble.yaml      # la définition, puis un objet Colis"] + S["ensemble"][:3]
                          + ["$ kubectl apply -f ensemble.yaml"] + S["ensemble"][3:5])

v["f-01"] = fichier("01-colis-minimal.yaml")
v["f-principal"] = fichier("principal.yaml")
v["f-mauvais"] = fichier("mauvais.yaml")
v["f-02"] = fichier("02-colis-schema.yaml")
v["f-invalide"] = fichier("invalide.yaml")
f3 = fichier("03-colis-cel.yaml")
morceaux = []
for i, l in enumerate(f3):
    if "x-kubernetes-validations" in l:
        j = i + 1
        while j < len(f3) and f3[j].strip().startswith(("- rule", "message")):
            j += 1
        champ = next(f3[k] for k in range(i - 1, 0, -1) if f3[k].rstrip().endswith(":") and "properties" not in f3[k] and "type" not in f3[k])
        morceaux += ["# ...", champ] + [f3[k] for k in range(i - 1, j) if "x-kubernetes-validations" in f3[k] or k >= i]
v["f-03"] = morceaux[1:]
v["f-04"] = bloc("04-colis-complet.yaml", "    plural: colis", "  versions:") + ["  versions:"] + bloc("04-colis-complet.yaml", "  - name: v1alpha1", "    schema:")
f5 = fichier("05-colis-v1.yaml")
v["f-05"] = [l for l in f5 if re.match(r"^(  - name: |    served|    storage|    deprecat|  conversion|    strategy)", l)]
v["f-05"] = v["f-05"][:5] + ["    # ... sous-ressources, colonnes, schéma de v1alpha1"] + v["f-05"][5:8] + [
    "    # ... les mêmes, plus spec.web dans le schéma"] + v["f-05"][8:]
v["f-07"] = fichier("07-roles.yaml")

def ex(titre):
    return [re.sub(r"^\$ ", "# ", l) for l in X[titre]]

v["ex1"] = ex("ex1 schema")
e2 = X["ex2 cel"]
v["ex2"] = commandes([l for l in e2 if not re.match(r"^\d+[:-]", l) and "customresourcedefinition" not in l])
v["ex3"] = commandes([l for l in X["ex3 role"] if not re.match(r"^(serviceaccount|role|rolebinding)", l)])
v["ex4"] = commandes([l for l in X["ex4 versions"] if not l.startswith("colis.cours.example.com/retardataire")])
v["versions-py"] = fichier("corrige/versions-crd.py")


def remplace(mo):
    l = list(v[mo.group(1)])
    while l and not l[-1].strip():
        l.pop()
    return "\n".join(l)


page = re.sub(r"@@([a-z0-9-]+)@@", remplace, (R / "outils/modeles/crd.md.modele").read_text())
assert not re.search(r"@@[a-z0-9-]+@@", page)
(R / "docs/partie-8").mkdir(exist_ok=True)
(R / "docs/partie-8/crd.md").write_text(page)
print("crd.md écrit")
