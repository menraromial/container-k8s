#!/usr/bin/env python3
"""Webhook d'admission, corrigé de l'exercice 3 du chapitre 45.

  /valider   refuse un objet dont une image du registre du cours n'existe pas ;
  /epingler  remplace l'étiquette de chaque image du registre par son empreinte (mutation).
"""
import base64
import http.server
import json
import ssl
import urllib.error
import urllib.request

REGISTRE = "host.minikube.internal:5001"
ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])


def gabarit(objet):
    return objet["spec"] if objet["kind"] == "Pod" else objet["spec"]["template"]["spec"]


def images(spec):
    return [c["image"] for c in spec.get("initContainers", []) + spec["containers"]]


def decomposer(image):
    reste = image[len(REGISTRE) + 1:]
    if "@" in reste:
        nom, reference = reste.split("@", 1)
    elif ":" in reste.rsplit("/", 1)[-1]:
        nom, reference = reste.rsplit(":", 1)
    else:
        nom, reference = reste, "latest"
    return nom, reference


def empreinte(image):
    """Empreinte du manifeste de l'image, ou None si elle n'existe pas. Lève une exception
    si le registre ne répond pas."""
    nom, reference = decomposer(image)
    requete = urllib.request.Request(f"http://{REGISTRE}/v2/{nom}/manifests/{reference}",
                                     method="HEAD", headers={"Accept": ACCEPT})
    try:
        with urllib.request.urlopen(requete, timeout=2) as reponse:
            return reponse.headers["Docker-Content-Digest"]
    except urllib.error.HTTPError as erreur:
        if erreur.code == 404:
            return None
        raise


def existe(image):
    return empreinte(image) is not None


def chemin_gabarit(objet):
    return "/spec" if objet["kind"] == "Pod" else "/spec/template/spec"


def epingler(objet):
    """Opérations JSON Patch qui remplacent chaque image étiquetée du registre par nom@empreinte."""
    operations = []
    spec = gabarit(objet)
    for liste in ("initContainers", "containers"):
        for i, conteneur in enumerate(spec.get(liste, [])):
            image = conteneur["image"]
            if not image.startswith(REGISTRE + "/") or "@" in image:
                continue
            nom, _ = decomposer(image)
            condense = empreinte(image)
            if condense:
                operations.append({"op": "replace", "path": f"{chemin_gabarit(objet)}/{liste}/{i}/image",
                                   "value": f"{REGISTRE}/{nom}@{condense}"})
    return operations


class Gestionnaire(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        revue = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        requete = revue["request"]
        objet = requete["object"]
        nom_objet = f"{requete['namespace']}/{objet['metadata'].get('name', objet['metadata'].get('generateName', '?'))}"
        if self.path.startswith("/epingler"):
            operations = epingler(objet)
            reponse = {"uid": requete["uid"], "allowed": True}
            if operations:
                reponse["patchType"] = "JSONPatch"
                reponse["patch"] = base64.b64encode(json.dumps(operations).encode()).decode()
            print(f"épinglage {objet['kind']} {nom_objet} : {len(operations)} image(s)", flush=True)
        else:
            a_verifier = [i for i in images(gabarit(objet)) if i.startswith(REGISTRE + "/")]
            manquantes = [i for i in a_verifier if not existe(i)]
            reponse = {"uid": requete["uid"], "allowed": not manquantes}
            if manquantes:
                reponse["status"] = {"code": 403, "message": "image absente du registre : " + ", ".join(manquantes)}
            print(f"{requete['operation']} {objet['kind']} {nom_objet} "
                  f"vérifiées={len(a_verifier)} refusées={len(manquantes)}", flush=True)
        corps = json.dumps({"apiVersion": "admission.k8s.io/v1", "kind": "AdmissionReview",
                            "response": reponse}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(corps)))
        self.end_headers()
        self.wfile.write(corps)

    def log_message(self, *args):
        pass  # une ligne par revue suffit, imprimée dans do_POST


if __name__ == "__main__":
    serveur = http.server.ThreadingHTTPServer(("0.0.0.0", 8443), Gestionnaire)
    contexte = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    contexte.load_cert_chain("/certs/tls.crt", "/certs/tls.key")
    serveur.socket = contexte.wrap_socket(serveur.socket, server_side=True)
    print("webhook prêt sur le port 8443", flush=True)
    serveur.serve_forever()
