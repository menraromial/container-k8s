#!/usr/bin/env python3
"""Inventaire des images qui tournent dans le cluster : pour celles du registre du cours,
signature vérifiée par cosign et résumé de l'analyse de vulnérabilités signée.

Usage : inventaire-images.py CLE_PUBLIQUE
"""
import base64
import collections
import json
import subprocess
import sys

REGISTRE_CLUSTER = "host.minikube.internal:5001/"
REGISTRE_POSTE = "localhost:5001/"   # le même registre, vu depuis le poste
OPTIONS = ["--insecure-ignore-tlog=true", "--new-bundle-format=false", "--allow-http-registry"]


def images_en_cours():
    pods = json.loads(subprocess.run(["kubectl", "get", "pods", "-A", "-o", "json"],
                                     capture_output=True, text=True, check=True).stdout)["items"]
    usages = collections.defaultdict(set)
    for p in pods:
        if p["status"].get("phase") != "Running":
            continue
        for c in p["spec"]["containers"] + p["spec"].get("initContainers", []):
            usages[c["image"]].add(p["metadata"]["namespace"])
    return usages


def cosign(*args):
    return subprocess.run(["cosign", *args], capture_output=True, text=True)


def verifier(image, cle):
    ref = REGISTRE_POSTE + image[len(REGISTRE_CLUSTER):]
    if cosign("verify", "--key", cle, *OPTIONS, ref).returncode != 0:
        return "NON SIGNÉE", ""
    att = cosign("verify-attestation", "--key", cle, "--type", "vuln", *OPTIONS, ref)
    if att.returncode != 0:
        return "signée", "pas d'analyse signée"
    # une ligne JSON par attestation ; on garde la plus récente
    analyses = []
    for ligne in att.stdout.splitlines():
        charge = json.loads(base64.b64decode(json.loads(ligne)["payload"]))["predicate"]
        analyses.append(charge)
    derniere = max(analyses, key=lambda a: a["metadata"]["scanFinishedOn"])
    severites = collections.Counter(v["Severity"] for r in derniere["scanner"]["result"].get("Results", [])
                                    for v in r.get("Vulnerabilities") or [])
    resume = ", ".join(f"{n} {s}" for s, n in sorted(severites.items())) or "aucune faille connue"
    return "signée", f"{resume} (analyse du {derniere['metadata']['scanFinishedOn'][:10]})"


def main():
    cle = sys.argv[1]
    for image, namespaces in sorted(images_en_cours().items()):
        if image.startswith(REGISTRE_CLUSTER):
            statut, analyse = verifier(image, cle)
        else:
            statut, analyse = "hors registre du cours", ""
        print(f"{image}\n    {statut:<24} {analyse}  [{', '.join(sorted(namespaces))}]")


if __name__ == "__main__":
    main()
