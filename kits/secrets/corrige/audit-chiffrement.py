#!/usr/bin/env python3
"""Classe chaque Secret stocké dans etcd : en clair, ou chiffré (fournisseur et nom de clé).

Lit etcd par etcdctl dans le Pod etcd de minikube (comme la fonction E du chapitre 35).
Code de sortie 1 si au moins un Secret est stocké en clair.
"""
import base64
import collections
import json
import subprocess
import sys

CERTS = "/var/lib/minikube/certs/etcd"
ETCDCTL = ["kubectl", "-n", "kube-system", "exec", "etcd-minikube", "--", "etcdctl",
           f"--cacert={CERTS}/ca.crt", f"--cert={CERTS}/server.crt", f"--key={CERTS}/server.key"]


def secrets_bruts():
    sortie = subprocess.run(ETCDCTL + ["get", "/registry/secrets/", "--prefix", "-w", "json"],
                            capture_output=True, check=True).stdout
    for kv in json.loads(sortie).get("kvs", []):
        yield base64.b64decode(kv["key"]).decode(), base64.b64decode(kv["value"])


def classer(valeur):
    if valeur.startswith(b"k8s:enc:"):
        # k8s:enc:<fournisseur>:v1:<nom de clé>:<données chiffrées>
        _, _, fournisseur, _, cle = valeur.split(b":", 5)[:5]
        return f"chiffré ({fournisseur.decode()}, clé {cle.decode()})"
    if valeur.startswith(b"k8s\x00"):
        return "EN CLAIR"
    return "format inconnu"


def main():
    par_etat = collections.defaultdict(list)
    for cle, valeur in secrets_bruts():
        par_etat[classer(valeur)].append(cle.removeprefix("/registry/secrets/"))
    for etat in sorted(par_etat):
        print(f"{len(par_etat[etat]):4d}  {etat}")
    for nom in sorted(par_etat.get("EN CLAIR", [])):
        print(f"      en clair : {nom}")
    sys.exit(1 if par_etat.get("EN CLAIR") else 0)


if __name__ == "__main__":
    main()
