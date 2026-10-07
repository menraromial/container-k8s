#!/usr/bin/env python3
"""Corrigé de l'exercice 3 du chapitre 48 : un résumé des Pods qui vont mal, une ligne par conteneur.

Usage : python3 etat-pods.py [namespace]     (sans argument : tous les namespaces)
Lit `kubectl get pods -o json` et `kubectl get events -o json`, et affiche pour chaque conteneur
qui n'est pas prêt son état, son dernier arrêt, une piste, et le dernier avertissement du Pod.
"""
import json
import signal
import subprocess
import sys

# Les codes de sortie les plus fréquents. Au-delà de 128, le processus a été tué par le signal (code - 128).
PISTES = {
    1: "erreur de l'application : lire les journaux",
    2: "mauvaise utilisation de la commande (option, argument)",
    126: "fichier trouvé mais non exécutable",
    127: "commande introuvable (dans le shell)",
    128: "le runtime n'a pas pu lancer le processus",
}
RAISONS = {
    "OOMKilled": "tué pour dépassement de sa limite mémoire",
    "StartError": "le runtime n'a pas pu démarrer le conteneur (commande, montage)",
    "ContainerCannotRun": "le runtime n'a pas pu démarrer le conteneur",
    "CrashLoopBackOff": "redémarre en boucle, le kubelet espace les essais",
    "ImagePullBackOff": "image introuvable ou inaccessible",
    "ErrImagePull": "image introuvable ou inaccessible",
    "CreateContainerConfigError": "ConfigMap, Secret ou clé manquants",
}


def kubectl(*args):
    return json.loads(subprocess.run(["kubectl", *args, "-o", "json"], check=True,
                                     capture_output=True, text=True).stdout)


def piste(code, raison):
    if raison in RAISONS:
        return RAISONS[raison]
    if code is None:
        return ""
    if code in PISTES:
        return PISTES[code]
    if code > 128:
        try:
            nom = signal.Signals(code - 128).name
        except ValueError:
            nom = f"signal {code - 128}"
        return f"tué par {nom}" + (" (OOM, sonde de vie, ou kill)" if nom == "SIGKILL" else "")
    return "code propre à l'application"


def etat(cs):
    """L'état courant d'un conteneur, en quelques mots."""
    s = cs.get("state", {})
    if "running" in s:
        return "en marche"
    if "waiting" in s:
        return "attend : " + s["waiting"].get("reason", "?")
    t = s.get("terminated", {})
    return f"arrêté : {t.get('reason', '?')} ({t.get('exitCode')})"


def main():
    portee = ["-n", sys.argv[1]] if len(sys.argv) > 1 else ["-A"]
    pods = kubectl("get", "pods", *portee)["items"]
    alertes = {}
    for ev in kubectl("get", "events", *portee)["items"]:
        if ev.get("type") == "Warning" and ev["involvedObject"].get("kind") == "Pod":
            cle = (ev["involvedObject"].get("namespace"), ev["involvedObject"]["name"])
            quand = ev.get("lastTimestamp") or ev.get("eventTime") or ""
            if quand >= alertes.get(cle, ("",))[0]:
                alertes[cle] = (quand, ev["reason"], ev["message"])
    for p in pods:
        ns, nom = p["metadata"]["namespace"], p["metadata"]["name"]
        if p["status"].get("phase") == "Succeeded":
            continue
        statuts = p["status"].get("containerStatuses") or []
        if not statuts:  # pas encore de conteneur : ordonnancement, image...
            cond = {c["type"]: c for c in p["status"].get("conditions", [])}
            raison = cond.get("PodScheduled", {}).get("reason", p["status"].get("phase"))
            print(f"{ns}/{nom}  aucun conteneur créé : {raison}")
        for cs in statuts:
            if cs.get("ready"):
                continue
            dernier = cs.get("lastState", {}).get("terminated")
            courant = cs.get("state", {}).get("terminated") or {}
            ref = dernier or courant
            code, raison = ref.get("exitCode"), ref.get("reason")
            attente = cs.get("state", {}).get("waiting", {}).get("reason")
            ligne = f"{ns}/{nom} [{cs['name']}]  {etat(cs)}, {cs.get('restartCount', 0)} redémarrage(s)"
            if dernier:
                ligne += f", dernier arrêt : {raison} ({code})"
            print(ligne)
            indice = piste(code, raison) if ref else RAISONS.get(attente, "")
            if attente in RAISONS and attente != "CrashLoopBackOff":
                indice = RAISONS[attente]
            if indice:
                print(f"    piste : {indice}")
        if (ns, nom) in alertes and any(not cs.get("ready") for cs in statuts):
            _, raison, message = alertes[(ns, nom)]
            print(f"    dernier avertissement : {raison} : {message[:110]}")


if __name__ == "__main__":
    main()
