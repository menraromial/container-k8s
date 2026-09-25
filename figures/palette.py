"""Génère les couleurs des figures à partir de palette.tsv.

Une seule source pour trois usages :
  - lib/quai-couleurs.tex : \\definecolor pour TikZ (valeurs du thème clair) ;
  - ../src/css/figures.css : variables CSS des deux thèmes ;
  - la table hex -> variable utilisée par svgpost.py.
"""
from pathlib import Path

ICI = Path(__file__).parent


def lire_palette():
    lignes = []
    for ligne in (ICI / "palette.tsv").read_text().splitlines():
        if not ligne.strip() or ligne.startswith("#"):
            continue
        nom, clair, var, sombre = ligne.split("\t")
        lignes.append((nom, clair.upper(), var, sombre.upper()))
    return lignes


def main():
    pal = lire_palette()
    tex = ["% Fichier généré par palette.py : ne pas modifier à la main."]
    tex += [f"\\definecolor{{{n}}}{{HTML}}{{{c}}}" for n, c, _, _ in pal]
    (ICI / "lib" / "quai-couleurs.tex").write_text("\n".join(tex) + "\n")

    css = ["/* Fichier généré par figures/palette.py : ne pas modifier à la main. */", ":root {"]
    css += [f"  {v}: #{c};" for _, c, v, _ in pal]
    css += ["}", "[data-theme='dark'] {"]
    css += [f"  {v}: #{s};" for _, _, v, s in pal]
    css += ["}"]
    (ICI.parent / "src" / "css" / "figures.css").write_text("\n".join(css) + "\n")


if __name__ == "__main__":
    main()
