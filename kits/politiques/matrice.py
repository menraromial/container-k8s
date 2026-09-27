"""Calcule, à partir des NetworkPolicies d'un namespace, quels groupes de Pods peuvent ouvrir une connexion
vers quels autres groupes du même namespace. Un groupe = une valeur de l'étiquette app.kubernetes.io/name,
lue dans les gabarits des Deployments, StatefulSets et CronJobs.

Usage : kubectl proxy --port=8011 &   puis   python3 matrice.py colis
Simplifications : sélecteurs matchLabels et matchExpressions (In, NotIn, Exists, DoesNotExist) ; les ports
et les sources d'autres namespaces sont ignorés (une règle qui ne vise qu'eux n'ouvre rien ici).
"""
import json
import sys
import urllib.request

NS = sys.argv[1]
API = f"http://127.0.0.1:8011/apis/networking.k8s.io/v1/namespaces/{NS}/networkpolicies"


def lire(url):
    with urllib.request.urlopen(url) as r:
        return json.load(r)["items"]


def choisit(selecteur, etiquettes):
    """Le sélecteur choisit-il un Pod qui porte ces étiquettes ?"""
    for k, v in (selecteur.get("matchLabels") or {}).items():
        if etiquettes.get(k) != v:
            return False
    for e in selecteur.get("matchExpressions") or []:
        k, op, vals = e["key"], e["operator"], e.get("values", [])
        if op == "In" and etiquettes.get(k) not in vals: return False
        if op == "NotIn" and etiquettes.get(k) in vals: return False
        if op == "Exists" and k not in etiquettes: return False
        if op == "DoesNotExist" and k in etiquettes: return False
    return True


def autorise(pols, pod, pair, sens):
    """sens = 'ingress' (pair est la source) ou 'egress' (pair est la destination)."""
    concernees = [p for p in pols if choisit(p["spec"]["podSelector"], pod)
                  and (sens.capitalize() in p["spec"].get("policyTypes", ["Ingress"]))]
    if not concernees:
        return True                                 # aucune politique : tout est permis dans ce sens
    for p in concernees:
        for regle in p["spec"].get(sens) or []:
            pairs = regle.get("from" if sens == "ingress" else "to")
            if pairs is None:
                return True                         # règle sans from/to : toute source ou destination
            for x in pairs:
                if "podSelector" in x and "namespaceSelector" not in x and "ipBlock" not in x \
                        and choisit(x["podSelector"], pair):
                    return True
    return False


pols = lire(API)
# les groupes viennent des gabarits des charges de travail, pour compter aussi celles qui n'ont aucun Pod en ce moment
groupes = {}
gabarits = [d["spec"]["template"] for d in lire(f"http://127.0.0.1:8011/apis/apps/v1/namespaces/{NS}/deployments")]
gabarits += [s["spec"]["template"] for s in lire(f"http://127.0.0.1:8011/apis/apps/v1/namespaces/{NS}/statefulsets")]
gabarits += [c["spec"]["jobTemplate"]["spec"]["template"] for c in lire(f"http://127.0.0.1:8011/apis/batch/v1/namespaces/{NS}/cronjobs")]
for g in gabarits:
    etiq = g["metadata"].get("labels", {})
    if "app.kubernetes.io/name" in etiq:
        groupes.setdefault(etiq["app.kubernetes.io/name"], etiq)
noms = sorted(groupes)
print(f"{len(pols)} politiques dans {NS} ; ligne = source, colonne = destination")
print(" " * 12 + "".join(f"{n[:10]:>11}" for n in noms))
for s in noms:
    ligne = ""
    for d in noms:
        ok = s != d and autorise(pols, groupes[s], groupes[d], "egress") and autorise(pols, groupes[d], groupes[s], "ingress")
        ligne += f"{'oui' if ok else '.':>11}"
    print(f"{s[:11]:12}{ligne}")
