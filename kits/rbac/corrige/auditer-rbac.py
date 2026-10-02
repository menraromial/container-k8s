#!/usr/bin/env python3
"""Repère, sujet par sujet, les permissions RBAC sensibles d'un cluster.

Usage : auditer-rbac.py [--tout]
Par défaut, les liaisons installées par Kubernetes lui-même (nom commençant par « system: »
ou « kubeadm: ») et les sujets « system:... » sont omis ; --tout les affiche aussi.
La liste des permissions suit « Role Based Access Control Good Practices » (kubernetes.io).
"""
import json
import subprocess
import sys
from collections import defaultdict

SENSIBLES = [
    # (libellé, verbes, groupe d'API, ressources)
    ("lire les Secrets", ["get", "list", "watch"], "", ["secrets"]),
    ("créer des Pods", ["create"], "", ["pods"]),
    ("créer des charges de travail", ["create"], "apps", ["deployments", "daemonsets", "statefulsets"]),
    ("créer des Jobs", ["create"], "batch", ["jobs", "cronjobs"]),
    ("exec ou attach dans les Pods", ["create"], "", ["pods/exec", "pods/attach"]),
    ("émettre des jetons de ServiceAccount", ["create"], "", ["serviceaccounts/token"]),
    ("agir sous une autre identité", ["impersonate"], "", ["users", "groups", "serviceaccounts"]),
    ("lier ou étendre des rôles", ["bind", "escalate"], "rbac.authorization.k8s.io", ["roles", "clusterroles"]),
    ("approuver des CSR", ["update", "patch"], "certificates.k8s.io", ["certificatesigningrequests/approval"]),
    ("API du kubelet (nodes/proxy)", ["get", "create"], "", ["nodes/proxy"]),
    ("créer des PersistentVolumes", ["create"], "", ["persistentvolumes"]),
    ("modifier les webhooks d'admission", ["create", "update", "patch"], "admissionregistration.k8s.io",
     ["validatingwebhookconfigurations", "mutatingwebhookconfigurations"]),
]


def lire(*types):
    sortie = subprocess.run(["kubectl", "get", ",".join(types), "-A", "-o", "json"],
                            capture_output=True, text=True, check=True).stdout
    return json.loads(sortie)["items"]


def couvre(liste, valeur):
    return "*" in liste or valeur in liste


def constats(regles):
    trouve = set()
    for r in regles or []:
        verbes, groupes, ressources = r.get("verbs", []), r.get("apiGroups", []), r.get("resources", [])
        if "*" in verbes and "*" in ressources:
            trouve.add("règle joker (tous verbes, toutes ressources)")
        for libelle, v_sens, g_sens, r_sens in SENSIBLES:
            if (any(couvre(verbes, v) for v in v_sens) and couvre(groupes, g_sens)
                    and any(couvre(ressources, x) for x in r_sens)):
                trouve.add(libelle + (" (noms restreints)" if r.get("resourceNames") else ""))
    return trouve


def main():
    tout = "--tout" in sys.argv
    roles = {(o["kind"], o["metadata"].get("namespace"), o["metadata"]["name"]): o.get("rules")
             for o in lire("clusterroles", "roles")}
    par_sujet = defaultdict(set)
    for b in lire("clusterrolebindings", "rolebindings"):
        ns = b["metadata"].get("namespace")
        ref = b["roleRef"]
        if not tout and b["metadata"]["name"].startswith(("system:", "kubeadm:")):
            continue
        trouve = constats(roles.get((ref["kind"], ns if ref["kind"] == "Role" else None, ref["name"])))
        if not trouve:
            continue
        portee = f"dans {ns}" if ns else "partout"
        for s in b.get("subjects") or []:
            nom = f"{s.get('namespace')}/{s['name']}" if s["kind"] == "ServiceAccount" else s["name"]
            if not tout and s["name"].startswith("system:"):
                continue
            for t in trouve:
                par_sujet[f"{s['kind']} {nom}"].add(f"{t}, {portee} ({b['kind']} {b['metadata']['name']})")
    for sujet in sorted(par_sujet):
        print(sujet)
        for c in sorted(par_sujet[sujet]):
            print("   -", c)
    print(f"{len(par_sujet)} sujets avec au moins une permission sensible")


if __name__ == "__main__":
    main()
