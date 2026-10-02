#!/usr/bin/env python3
"""Vérifie un jeton de ServiceAccount sans demander son avis à l'API server.

Usage : verifier-jeton.py FICHIER_JETON [AUDIENCE]

Les clés publiques et l'émetteur viennent de la découverte OIDC du cluster
(/.well-known/openid-configuration et /openid/v1/jwks), lues avec kubectl.
"""
import datetime
import json
import subprocess
import sys

import jwt  # PyJWT, avec le paquet cryptography pour RS256


def lire(chemin):
    sortie = subprocess.run(["kubectl", "get", "--raw", chemin],
                            capture_output=True, text=True, check=True).stdout
    return json.loads(sortie)


def main():
    jeton = open(sys.argv[1]).read().strip()
    audience = sys.argv[2] if len(sys.argv) > 2 else None

    emetteur = lire("/.well-known/openid-configuration")["issuer"]
    cles = {k["kid"]: jwt.PyJWK(k) for k in lire("/openid/v1/jwks")["keys"]}

    kid = jwt.get_unverified_header(jeton).get("kid")
    if kid not in cles:
        print(f"REFUSÉ : aucune clé publique ne porte le kid {kid}")
        sys.exit(1)

    try:
        revendications = jwt.decode(
            jeton, cles[kid], algorithms=["RS256"],
            issuer=emetteur,
            audience=audience or emetteur,
            options={"require": ["exp", "iat", "sub"]},
        )
    except jwt.InvalidTokenError as erreur:
        print(f"REFUSÉ : {type(erreur).__name__} : {erreur}")
        sys.exit(1)

    k8s = revendications.get("kubernetes.io", {})
    maintenant = datetime.datetime.now(datetime.timezone.utc)
    fin = datetime.datetime.fromtimestamp(revendications["exp"], datetime.timezone.utc)
    print("signature valide, émise par", emetteur)
    print("  sujet    :", revendications["sub"])
    print("  audience :", ", ".join(revendications["aud"]))
    print("  lié à    :", "Pod " + k8s["pod"]["name"] if "pod" in k8s else "rien d'autre que le ServiceAccount")
    reste = fin - maintenant
    reste = f"{reste.days} j" if reste.days >= 1 else f"{int(reste.total_seconds() // 60)} min"
    print("  expire   :", fin.isoformat(timespec="seconds"), f"(dans {reste})")
    if "warnafter" in k8s:
        alerte = datetime.datetime.fromtimestamp(k8s["warnafter"], datetime.timezone.utc)
        print("  périmé   :", "oui" if maintenant > alerte else "non",
              f"(durée demandée dépassée après {alerte.isoformat(timespec='seconds')})")


if __name__ == "__main__":
    main()
