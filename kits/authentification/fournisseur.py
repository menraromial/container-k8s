#!/usr/bin/env python3
"""Un fournisseur d'identité OIDC réduit à l'essentiel, pour voir ce que l'API server en attend.

  fournisseur.py servir             publie la découverte et les clés sur https://ADRESSE:9443
  fournisseur.py emettre COURRIEL GROUPE... [--audience A] [--non-verifie]
                                    signe un jeton d'identité (le « login » d'un vrai fournisseur)

Fichiers attendus dans le dossier courant : idp.key (clé de signature RSA),
https.crt et https.key (certificat TLS du serveur), produits par preparer-fournisseur.sh.
"""
import argparse
import http.server
import json
import ssl
import time
import uuid

import jwt
from cryptography.hazmat.primitives import serialization

ADRESSE = "192.168.49.1"
PORT = 9443
EMETTEUR = f"https://{ADRESSE}:{PORT}"
KID = "cours-ch42"


def cle_privee():
    with open("idp.key", "rb") as f:
        return serialization.load_pem_private_key(f.read(), password=None)


def jwks():
    publique = jwt.algorithms.RSAAlgorithm.to_jwk(cle_privee().public_key(), as_dict=True)
    publique.update(kid=KID, use="sig", alg="RS256")
    return {"keys": [publique]}


class Gestionnaire(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/.well-known/openid-configuration":
            corps = {"issuer": EMETTEUR, "jwks_uri": EMETTEUR + "/jwks",
                     "id_token_signing_alg_values_supported": ["RS256"]}
        elif self.path == "/jwks":
            corps = jwks()
        else:
            self.send_error(404)
            return
        donnees = json.dumps(corps).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(donnees)))
        self.end_headers()
        self.wfile.write(donnees)


def servir():
    serveur = http.server.ThreadingHTTPServer((ADRESSE, PORT), Gestionnaire)
    contexte = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    contexte.load_cert_chain("https.crt", "https.key")
    serveur.socket = contexte.wrap_socket(serveur.socket, server_side=True)
    print("fournisseur prêt sur", EMETTEUR, flush=True)
    serveur.serve_forever()


def emettre(courriel, groupes, audience, verifie, duree):
    maintenant = int(time.time())
    revendications = {
        "iss": EMETTEUR, "aud": audience, "sub": str(uuid.uuid5(uuid.NAMESPACE_URL, courriel)),
        "email": courriel, "email_verified": verifie, "groups": groupes,
        "iat": maintenant, "nbf": maintenant, "exp": maintenant + duree,
    }
    print(jwt.encode(revendications, cle_privee(), algorithm="RS256", headers={"kid": KID}))


if __name__ == "__main__":
    analyseur = argparse.ArgumentParser()
    sous = analyseur.add_subparsers(dest="commande", required=True)
    sous.add_parser("servir")
    e = sous.add_parser("emettre")
    e.add_argument("courriel")
    e.add_argument("groupes", nargs="*")
    e.add_argument("--audience", default="cluster-cours")
    e.add_argument("--non-verifie", action="store_true")
    e.add_argument("--duree", type=int, default=900)
    args = analyseur.parse_args()
    if args.commande == "servir":
        servir()
    else:
        emettre(args.courriel, args.groupes, args.audience, not args.non_verifie, args.duree)
