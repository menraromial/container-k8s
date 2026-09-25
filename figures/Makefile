# Figures du cours : source TikZ (src/*.tex) -> PDF -> SVG intégré aux pages.
#   make          toutes les figures
#   make apercu   un PNG par figure dans build/, pour vérifier le rendu
SRC    := $(wildcard src/*.tex)
NOMS   := $(patsubst src/%.tex,%,$(SRC))
SVG    := $(patsubst %,../src/figures/%.svg,$(NOMS))
PNG    := $(patsubst %,build/%.png,$(NOMS))

all: $(SVG)

lib/quai-couleurs.tex ../src/css/figures.css: palette.tsv palette.py
	python3 palette.py

build/%.pdf: src/%.tex lib/quai.sty lib/quai-couleurs.tex
	@mkdir -p build
	cd build && TEXINPUTS=../lib:../src: lualatex -interaction=nonstopmode -halt-on-error ../src/$*.tex > $*.journal || (tail -30 $*.journal; false)

../src/figures/%.svg: build/%.pdf svgpost.py palette.tsv
	pdftocairo -svg $< build/$*-brut.svg
	python3 svgpost.py build/$*-brut.svg $@

build/%.png: build/%.pdf
	pdftocairo -png -r 160 -singlefile $< build/$*

apercu: $(PNG)

clean:
	rm -rf build

.PHONY: all apercu clean
.SECONDARY:
