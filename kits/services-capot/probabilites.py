"""Lit la sortie de iptables-save (table nat) et calcule, pour chaque Service, la probabilité réelle
que kube-proxy envoie une connexion vers chacun de ses points de terminaison.

Usage : iptables-nft-save -t nat | python3 probabilites.py
"""
import re
import sys
from collections import defaultdict

regles = defaultdict(list)          # chaîne KUBE-SVC-... -> [(probabilité ou None, destination)]
for ligne in sys.stdin:
    m = re.match(r'-A (KUBE-SVC-\S+) .*--comment "([^"]+) -> ([^"]+)"(.*)', ligne)
    if not m:
        continue
    chaine, service, destination, reste = m.groups()
    p = re.search(r"--probability ([0-9.]+)", reste)
    regles[(chaine, service)].append((float(p.group(1)) if p else None, destination))

for (chaine, service), liste in sorted(regles.items(), key=lambda x: x[0][1]):
    print(f"{service} ({len(liste)} points de terminaison)")
    reste = 1.0                     # probabilité d'arriver jusqu'à cette règle
    for p, destination in liste:
        part = reste * (p if p is not None else 1.0)
        print(f"  {destination:22} tirage {p if p is not None else '(dernière)':>14}  part réelle {part:.3f}")
        reste -= part
