#!/usr/bin/env python3
"""Webhook d'admission de validation : refuse un Pod, un Deployment ou un StatefulSet
dont une image du registre du cours n'existe pas (étiquette ou empreinte inconnue).

Une règle CEL ne peut pas le faire : il faut interroger le registre au moment de l'admission.
"""
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


def existe(image):
    """Demande au registre si l'image existe. Lève une exception s'il ne répond pas."""
    reste = image[len(REGISTRE) + 1:]
    if "@" in reste:
        nom, reference = reste.split("@", 1)
    elif ":" in reste.rsplit("/", 1)[-1]:
        nom, reference = reste.rsplit(":", 1)
    else:
        nom, reference = reste, "latest"
    requete = urllib.request.Request(f"http://{REGISTRE}/v2/{nom}/manifests/{reference}",
                                     method="HEAD", headers={"Accept": ACCEPT})
    try:
        urllib.request.urlopen(requete, timeout=2)
        return True
    except urllib.error.HTTPError as erreur:
        if erreur.code == 404:
            return False
        raise


class Gestionnaire(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        revue = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        requete = revue["request"]
        objet = requete["object"]
        a_verifier = [i for i in images(gabarit(objet)) if i.startswith(REGISTRE + "/")]
        manquantes = [i for i in a_verifier if not existe(i)]
        reponse = {"uid": requete["uid"], "allowed": not manquantes}
        if manquantes:
            reponse["status"] = {"code": 403, "message": "image absente du registre : " + ", ".join(manquantes)}
        print(f"{requete['operation']} {objet['kind']} {requete['namespace']}/{objet['metadata'].get('name', '?')} "
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
