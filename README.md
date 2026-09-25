# Conteneurs et Kubernetes, du premier conteneur à l'expertise

Cours complet sur les conteneurs et Kubernetes, du débutant à l'expert, entièrement
exécutable sur un portable avec minikube. Publié sur
[menraromial.com/container-k8s](https://menraromial.com/container-k8s/).

## Travailler sur le site

```bash
npm ci            # dépendances, versions figées
npm start         # aperçu avec rechargement à chaud
npm run build     # construction complète (échoue sur un lien cassé)
```

Le site est déployé sur GitHub Pages par `.github/workflows/deploy.yml` à chaque
poussée sur `main`.

## Organisation

| Dossier | Contenu |
|---|---|
| `docs/` | les chapitres, un dossier par partie |
| `src/figures/` | les figures SVG intégrées aux pages (générées, versionnées) |
| `figures/` | sources TikZ des figures, palette, polices, chaîne de conversion |
| `src/theme/`, `src/components/`, `src/css/` | thème « Quai » : plaque de chapitre, encadrés, figures |
| `outils/` | scripts de validation des chapitres |
| `PROMPT.md` | cahier des charges et plan du cours |

## Figures

Les figures sont écrites en TikZ (`figures/src/*.tex`) et converties en SVG dont
les couleurs sont des variables CSS, pour suivre le thème clair ou sombre :

```bash
make -C figures          # lualatex, pdftocairo, puis figures/svgpost.py
make -C figures apercu   # un PNG par figure dans figures/build/
```

Il faut LuaLaTeX, pdftocairo (poppler-utils) et Python 3. Les couleurs autorisées
sont listées dans `figures/palette.tsv` ; `python3 figures/palette.py` régénère
`figures/lib/quai-couleurs.tex` et `src/css/figures.css`.

## Licences des polices

Barlow Condensed, Atkinson Hyperlegible Next et Red Hat Mono sont distribuées sous
SIL Open Font License (textes dans `figures/fonts/`).
