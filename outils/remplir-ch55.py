#!/usr/bin/env python3
"""Remplit docs/partie-8/operateur.md à partir du modèle, du code du kit et des journaux des rejeux."""
import re
from pathlib import Path

R = Path(__file__).resolve().parent.parent
OUT = R / "outils/out/ch55r"
KIT = R / "kits/operateur"
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def sections(fichier):
    res = {}
    texte = ANSI.sub("", (OUT / fichier).read_text())
    for bloc in re.split(r"\n### ", "\n" + texte):
        if bloc.strip():
            titre, _, corps = bloc.partition("\n")
            res[titre.strip()] = corps.strip("\n").splitlines()
    return res


def source(nom):
    return (KIT / nom).read_text().splitlines()


def de_a(lignes, debut, fin=None, inclure_fin=False):
    """De la première ligne qui commence par debut jusqu'à fin (exclue, ou incluse), ou jusqu'au « } » qui ferme."""
    i = next(k for k, l in enumerate(lignes) if l.startswith(debut))
    if fin is None:
        j = next(k for k in range(i, len(lignes)) if lignes[k] == "}")
        return lignes[i:j + 1]
    j = next(k for k in range(i + 1, len(lignes)) if lignes[k].startswith(fin))
    return lignes[i:j + 1] if inclure_fin else lignes[i:j]


def sans(lignes, *motifs):
    return [l for l in lignes if not any(re.search(m, l) for m in motifs)]


def virgule(x):
    return x.replace(".", ",")


S = sections("rejeu-ch55.log")
X = sections("rejeu-ch55-exercices.log")
v = {}

v["outils"] = S["outils"]
v["init"] = (["# kubebuilder init ..."] + S["init"] + ["# kubebuilder create api ..."]
             + sans(S["create api"], r"^Downloading", r"controller-gen\" object"))
v["init"] = [re.sub(r"^\$ ", "  $ ", l) for l in v["init"]]
v["init"] = [re.sub(r"durée : (\S+) s", lambda m: "durée : " + virgule(m.group(1)) + " s", l) for l in v["init"]]
ar = S["arbre"]
m = re.search(r"fichiers : (\d+), dont (\d+) en Go", ar[-1])
v["nb-fichiers"] = [f"{m.group(1)} fichiers hors du dossier bin/, dont {m.group(2)} en Go"]
v["arbre"] = ar[:-1]
ge = S["generation"]
v["generation"] = [re.sub(r'^"[^"]*/bin/controller-gen"', "bin/controller-gen", l) for l in ge]
v["nb-lignes-crd"] = [ge[-1]]

na = S["naif"]
v["naif"] = sans(na, r"created$")

la = S["lancement"]
v["lancement"] = [re.sub(r"^\.", "0.", l) for l in la if re.match(r"^[\d.]+ s", l) or l.startswith(("NAME", "principal"))]
v["lancement"] = [re.sub(r"^(\d+)\.(\d+) s ", r"\1,\2 s ", l) for l in v["lancement"]]
v["lancement"] = [l for l in v["lancement"] if not re.match(r"^0,\d+ s\s+:\s*$", l)]

ob = S["objets"]
fin = next(k for k, l in enumerate(ob) if l.startswith("      7 objet") or re.match(r"^\s+\d+ objet", l))
v["objets"] = ob[:fin]

ap = S["application"]
v["application"] = [re.sub(r"après ([\d.]+) s", lambda m: "après " + virgule(m.group(1)) + " s", l) for l in ap]

de = S["derive"]
d = re.search(r"après \.?([\d.]+) s", next(l for l in de if "recréé" in l)).group(1)
v["delai-recreation"] = [virgule(("0." + d) if not d.startswith("0") and d.startswith(("1", "2", "3", "4", "5", "6", "7", "8", "9")) and len(d.split(".")[0]) > 1 else d) + " s"]
v["delai-recreation"] = [virgule(re.sub(r"^\.", "0.", re.search(r"après (\S+) s", next(l for l in de if "recréé" in l)).group(1))) + " s"]
v["derive"] = [re.sub(r"après \.(\d+) s", r"après 0,\1 s", l) for l in de]

v["echelle"] = S["echelle"]
ve = S["version"]
attente = [l for l in ve if l.startswith("Waiting for")]
v["version"] = ([l for l in ve if not l.startswith("Waiting for")][:1] + attente[:1] + ["..."] + attente[-1:]
                + [l for l in ve if not l.startswith("Waiting for")][1:])
v["second"] = S["second"]
ar2 = S["operateur arrete"]
v["arret"] = (["# opérateur arrêté"] + ar2[:2] + ["# opérateur relancé"]
              + [re.sub(r"recréé \.(\d+) s", r"recréé 0,\1 s", l) for l in ar2[2:]])
v["suppression"] = [re.sub(r"après ([\d.]+) s", lambda m: "après " + virgule(m.group(1)) + " s", l)
                    for l in S["suppression"] if l.strip()]

te = S["tests"]
v["taille-envtest"] = [re.search(r"binaires envtest : (\S+)", te[0]).group(1).replace("M", " Mo")]
v["tests"] = [l for l in te[1:] if not l.startswith(("Random Seed", "etcd", "kube-apiserver", "kubectl"))]
v["tests"] = [re.sub(r"^Le contrôleur Colis ", "Le contrôleur Colis ", l) for l in v["tests"]]

im = S["image"]
v["image"] = [re.sub(r"durée : ([\d.]+) s", lambda m: "durée : " + virgule(m.group(1)) + " s", l) for l in im]
dp = S["deploiement"]
v["deploiement"] = sans(dp, r"^Waiting for", r"^\"/")
mem = next(l for l in dp if re.match(r"^colis-operateur-controller-manager-\S+\s+\d+m\s+\d+Mi", l))
v["memoire-operateur"] = [mem.split()[2].replace("Mi", " Mi")]
v["metriques"] = S["metriques"]

v["f-principal"] = (OUT / "principal.yaml").read_text().rstrip("\n").splitlines()

types = source("api/v1/colis_types.go")
v["code-types"] = de_a(types, "// ColisSpec décrit", "// Colis est une installation")
while v["code-types"] and not v["code-types"][-1].strip():
    v["code-types"].pop()
ctl = source("internal/controller/colis_controller.go")
v["code-reconcile"] = de_a(ctl, "// Reconcile compare")
v["code-deploiement"] = de_a(ctl, "// deploiement applique")
v["code-setup"] = de_a(ctl, "// SetupWithManager")
v["code-rbac"] = [l for l in ctl if l.startswith("// +kubebuilder:rbac")]
v["code-remplacer"] = de_a(ctl, "// remplacer n'écrit")
w = de_a(ctl, "// worker : le nombre", "\tso := &unstructured.Unstructured{}")
v["code-worker"] = w + ["\t// ... puis le ScaledObject de KEDA, avec spec.worker.min et spec.worker.max", "}"]
test = source("internal/controller/colis_controller_test.go")
v["code-test"] = de_a(test, '\tIt("corrige une modification', '\tIt("refuse un second')
while v["code-test"] and not v["code-test"][-1].strip():
    v["code-test"].pop()
patch = (KIT / "corrige/suspendu.patch").read_text().splitlines()
i = next(k for k, l in enumerate(patch) if l.startswith("+++ b/internal/controller/colis_controller.go"))
j = next(k for k in range(i + 1, len(patch)) if patch[k].startswith("--- "))
v["code-suspendu"] = [l[1:] for l in patch[i + 1:j] if l.startswith("+") and not l.startswith("+++")]
while v["code-suspendu"] and not v["code-suspendu"][-1].strip():
    v["code-suspendu"].pop()


def sans_attente(lignes):
    return [l for l in lignes if not l.startswith("Waiting for")]


v["ex1"] = (["# tests"] + [l for l in X["ex1 tests"] if l.startswith(("Le contrôleur", "Ran", "ok"))]
            + ["# sur le cluster : opérateur du cluster arrêté, version modifiée lancée sur le poste"]
            + sans_attente([l for l in X["ex1 cluster"] if "colis-operateur-controller-manager" not in l
                            and "customresourcedefinition" not in l]))
v["ex1"] = [l for l in v["ex1"] if not l.startswith("deployment \"colis-operateur")]
e2 = sans_attente(X["ex2 secret"])
v["ex2"] = [re.sub(r"^--- ", "# ", l) for l in e2]
v["ex3"] = X["ex3 droits"]


def remplace(mo):
    l = list(v[mo.group(1)])
    while l and not l[-1].strip():
        l.pop()
    return "\n".join(l)


page = re.sub(r"@@([a-z0-9-]+)@@", remplace, (R / "outils/modeles/operateur.md.modele").read_text())
assert not re.search(r"@@[a-z0-9-]+@@", page)
(R / "docs/partie-8/operateur.md").write_text(page)
print("operateur.md écrit")
