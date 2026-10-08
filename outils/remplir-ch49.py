#!/usr/bin/env python3
"""Remplit docs/partie-7/pannes.md à partir du modèle et des journaux des rejeux du chapitre 49."""
import re
from pathlib import Path

RACINE = Path(__file__).resolve().parent.parent


def sections(fichier):
    texte = (RACINE / "outils/out" / fichier).read_text()
    res = {}
    for bloc in re.split(r"\n### ", "\n" + texte):
        if bloc.strip():
            titre, _, corps = bloc.partition("\n")
            res[titre.strip()] = corps.strip("\n").splitlines()
    return res


def avant(lignes, motif, dernier=False):
    idx = [i for i, l in enumerate(lignes) if re.search(motif, l)]
    i = idx[-1] if dernier else idx[0]
    return lignes[:i], lignes[i:]


def sans(lignes, *motifs):
    return [l for l in lignes if not any(re.search(m, l) for m in motifs)]


S = sections("rejeu-ch49.log")
E = sections("rejeu-ch49-exercices.log")
HEURE = r"^\d\d:\d\d:\d\d$"
v = {"vue": S["vue"], "capacite": S["noeud : capacite"]}
v["1-observer"], v["1-corriger"] = avant(S["1 trop-gourmand"], r"^pod/trop-gourmand created")
v["2-observer"], v["2-corriger"] = avant(S["2 mauvais-noeud"], r"^node/minikube labeled")
obs, reste = avant(S["3 volume-introuvable"], r"^\$ patch pvc")
v["3-observer"] = obs
v["3-refus"], v["3-corriger"] = avant(reste[1:], r"^persistentvolumeclaim/donnees created")
s4 = S["4 etiquette-absente"]
v["4-observer"] = [s4[0]] + [l for l in s4 if l.startswith('{"name"')]
v["4-corriger"] = avant(s4, r"image updated")[1]
v["5-observer"], v["5-corriger"] = avant(S["5 registre-injoignable"], r"image updated")
v["6-observer"], v["6-corriger"] = avant(S["6 cle-manquante"], HEURE)
v["7-observer"], v["7-corriger"] = avant(S["7 configmap-absente"], HEURE)
v["8-observer"], v["8-corriger"] = avant(S["8 memoire"], r"resource requirements updated")
obs, cor = avant(S["9 tache-finie"], r'^deployment.apps "tache-finie" deleted')
v["9-observer"], v["9-corriger"] = obs, sans(cor, r"^NAME +READY", r"^purge-")
obs, cor = avant(S["10 vie-impatiente"], r"vie-impatiente patched")
v["10-observer"], v["10-corriger"] = obs, sans(cor, HEURE)
v["11-observer"], v["11-corriger"] = avant(S["11 pas-prete"], r"pas-prete patched")
v["12-observer"], v["12-corriger"] = avant(S["12 dns-coupe"], r"networkpolicy.networking.k8s.io/dns created")
rejeu = (RACINE / "outils/rejeu-ch49.sh").read_text()
v["dns-yaml"] = re.search(r"cat > dns.yaml <<'EOF'\n(.*?)\nEOF", rejeu, re.S).group(1).splitlines()
obs, cor = avant(S["13 suppression-bloquee"], r"^configmap/regles-tarifaires patched")
v["13-observer"], v["13-corriger"] = sans(obs, r"^\$ "), cor

e1 = E["ex1 quota"]
debut = next(i for i, l in enumerate(e1) if l.startswith("NAME"))
v["ex1-observer"], v["ex1-corriger"] = avant(e1[debut:], r"resource requirements updated")
v["ex2"] = sans(E["ex2 init"], r"^namespace/", r"^pod/.* created")
e3 = E["ex3 palmares"]
v["ex3"] = e3[next(i for i, l in enumerate(e3) if l.strip().startswith("NB")):]
e4 = E["ex4 namespace bloque"]
e4 = e4[next(i for i, l in enumerate(e4) if l.startswith('namespace "ch49-fin" deleted')) + 1:]
v["ex4-observer"], v["ex4-corriger"] = avant(e4, r"^configmap/archive patched", dernier=True)


def remplace(mo):
    lignes = list(v[mo.group(1)])
    while lignes and not lignes[-1].strip():
        lignes.pop()
    return "\n".join(lignes)


page = re.sub(r"@@([a-z0-9-]+)@@", remplace, (RACINE / "outils/modeles/pannes.md.modele").read_text())
assert not re.search(r"@@[a-z0-9-]+@@", page)
(RACINE / "docs/partie-7/pannes.md").write_text(page)
print("pannes.md écrit")
