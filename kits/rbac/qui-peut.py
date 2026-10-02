#!/usr/bin/env python3
"""Qui peut faire VERBE sur RESSOURCE ? Lit les objets RBAC du cluster avec kubectl.

Usage : qui-peut.py VERBE RESSOURCE[.GROUPE][/SOUS-RESSOURCE] [NAMESPACE]
  qui-peut.py get secrets colis
  qui-peut.py patch deployments.apps colis
  qui-peut.py create pods/exec colis
Sans NAMESPACE, seules les autorisations valables dans tout le cluster sont listées.
"""
import json
import subprocess
import sys


def lire(*types):
    sortie = subprocess.run(["kubectl", "get", ",".join(types), "-A", "-o", "json"],
                            capture_output=True, text=True, check=True).stdout
    return json.loads(sortie)["items"]


def couvre(liste, valeur):
    return "*" in liste or valeur in liste


def ressource_couverte(ressources, ressource):
    if couvre(ressources, ressource):
        return True
    if "/" in ressource:
        principale, sous = ressource.split("/", 1)
        return f"{principale}/*" in ressources or f"*/{sous}" in ressources
    return False


def regles_qui_permettent(regles, verbe, groupe, ressource):
    for r in regles or []:
        if (couvre(r.get("verbs", []), verbe)
                and couvre(r.get("apiGroups", []), groupe)
                and ressource_couverte(r.get("resources", []), ressource)):
            yield r


def main():
    verbe, cible = sys.argv[1], sys.argv[2]
    namespace = sys.argv[3] if len(sys.argv) > 3 else None
    nom, _, sous = cible.partition("/")
    ressource, _, groupe = nom.partition(".")
    ressource = f"{ressource}/{sous}" if sous else ressource

    roles = {}
    for o in lire("clusterroles", "roles"):
        cle = (o["kind"], o["metadata"].get("namespace"), o["metadata"]["name"])
        roles[cle] = o.get("rules")

    lignes = []
    for b in lire("clusterrolebindings", "rolebindings"):
        ns_liaison = b["metadata"].get("namespace")
        if b["kind"] == "RoleBinding" and ns_liaison != namespace:
            continue
        ref = b["roleRef"]
        ns_role = ns_liaison if ref["kind"] == "Role" else None
        regles = list(regles_qui_permettent(roles.get((ref["kind"], ns_role, ref["name"])),
                                            verbe, groupe, ressource))
        if not regles:
            continue
        noms = sorted({n for r in regles for n in r.get("resourceNames", [])})
        restriction = "seulement " + ", ".join(noms) if all(r.get("resourceNames") for r in regles) else ""
        portee = f"namespace {ns_liaison}" if ns_liaison else "tout le cluster"
        for s in b.get("subjects") or []:
            sujet = f"{s['kind']} {s.get('namespace') + '/' if s['kind'] == 'ServiceAccount' else ''}{s['name']}"
            role = "" if ref["name"] == b["metadata"]["name"] else f" -> {ref['name']}"
            lignes.append((sujet, f"{b['kind']} {b['metadata']['name']}{role}", portee, restriction))

    largeurs = [max(len(l[i]) for l in lignes) for i in range(3)] if lignes else [0] * 3
    for l in sorted(set(lignes)):
        print("  ".join(c.ljust(largeurs[i]) for i, c in enumerate(l[:3])), l[3])
    print(f"{len(set(lignes))} autorisations, plus le groupe system:masters, que RBAC ne consulte jamais")


if __name__ == "__main__":
    main()
