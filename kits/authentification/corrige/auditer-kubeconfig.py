#!/usr/bin/env python3
"""Passe en revue les identités d'un kubeconfig et signale les plus risquées.

Usage : auditer-kubeconfig.py [FICHIER]   (sinon, le kubeconfig de kubectl)
"""
import base64
import datetime
import json
import subprocess
import sys

from cryptography import x509
from cryptography.x509.oid import NameOID

MAINTENANT = datetime.datetime.now(datetime.timezone.utc)
UN_JOUR = datetime.timedelta(days=1)


def configuration(fichier):
    commande = ["kubectl", "config", "view", "--raw", "-o", "json"]
    if fichier:
        commande.insert(1, f"--kubeconfig={fichier}")
    return json.loads(subprocess.run(commande, capture_output=True, text=True, check=True).stdout)


def duree(delta):
    if abs(delta) >= UN_JOUR:
        return f"{delta.days} j"
    if abs(delta) >= datetime.timedelta(hours=1):
        return f"{int(delta.total_seconds() // 3600)} h"
    return f"{int(delta.total_seconds() // 60)} min"


def certificat(utilisateur):
    if "client-certificate-data" in utilisateur:
        pem = base64.b64decode(utilisateur["client-certificate-data"])
    else:
        pem = open(utilisateur["client-certificate"], "rb").read()
    c = x509.load_pem_x509_certificate(pem)
    nom = ", ".join(a.value for a in c.subject.get_attributes_for_oid(NameOID.COMMON_NAME))
    groupes = [a.value for a in c.subject.get_attributes_for_oid(NameOID.ORGANIZATION_NAME)]
    fin = c.not_valid_after_utc
    alertes = []
    if "system:masters" in groupes:
        alertes.append("membre de system:masters : tous les droits, irrévocable")
    if fin - c.not_valid_before_utc > datetime.timedelta(days=90):
        alertes.append(f"valable {duree(fin - c.not_valid_before_utc)} au total")
    if fin < MAINTENANT:
        alertes.append("expiré")
    detail = f"certificat CN={nom} groupes={groupes or '[]'}, fin dans {duree(fin - MAINTENANT)}"
    return detail, alertes


def jeton(utilisateur):
    brut = utilisateur.get("token") or open(utilisateur["tokenFile"]).read().strip()
    parties = brut.split(".")
    if len(parties) != 3:
        return "jeton opaque (jeton d'amorçage ou fichier de jetons)", ["impossible d'en connaître la durée"]
    charge = json.loads(base64.urlsafe_b64decode(parties[1] + "=" * (-len(parties[1]) % 4)))
    sujet = charge.get("sub", "?")
    if "exp" not in charge:
        return f"jeton JWT {sujet}, sans date d'expiration", ["ancien jeton de Secret : valable tant que le Secret existe"]
    fin = datetime.datetime.fromtimestamp(charge["exp"], datetime.timezone.utc)
    debut = datetime.datetime.fromtimestamp(charge.get("iat", charge["exp"]), datetime.timezone.utc)
    alertes = []
    if fin - debut > UN_JOUR:
        alertes.append(f"jeton longue durée ({duree(fin - debut)})")
    if fin < MAINTENANT:
        alertes.append("expiré")
    return f"jeton JWT {sujet}, fin dans {duree(fin - MAINTENANT)}", alertes


def main():
    config = configuration(sys.argv[1] if len(sys.argv) > 1 else None)
    for entree in config.get("users", []):
        u = entree.get("user", {})
        if "client-certificate-data" in u or "client-certificate" in u:
            detail, alertes = certificat(u)
        elif "token" in u or "tokenFile" in u:
            detail, alertes = jeton(u)
        elif "exec" in u:
            detail, alertes = f"greffon {u['exec']['command']}", []
        else:
            detail, alertes = "aucune pièce d'identité (anonyme)", ["requêtes traitées en system:anonymous"]
        print(f"{'!!' if alertes else 'ok'} {entree['name']:<10} {detail}")
        for a in alertes:
            print(f"     - {a}")


if __name__ == "__main__":
    main()
