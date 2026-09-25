# syntax=docker/dockerfile:1
# Image de Colis, version 2.0 : allégée et durcie (défi II).

# 1. Les dépendances, dans un environnement virtuel sans pip
FROM python:3.14-alpine AS dependances
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_ROOT_USER_ACTION=ignore
RUN python -m venv --without-pip /opt/venv
COPY requirements.txt .
RUN --mount=type=cache,target=/root/.cache/pip \
    pip --python /opt/venv/bin/python install -r requirements.txt

# 2. Les tests, dans une étape à part : la construction échoue s'ils échouent
FROM dependances AS tests
ENV PYTHONDONTWRITEBYTECODE=1
COPY requirements-dev.txt .
RUN --mount=type=cache,target=/root/.cache/pip \
    pip --python /opt/venv/bin/python install -r requirements-dev.txt
WORKDIR /app
COPY colis/ colis/
COPY tests/ tests/
RUN /opt/venv/bin/python -m pytest -q -p no:cacheprovider

# 3. L'image finale : l'interpréteur, l'environnement virtuel, le code testé
FROM python:3.14-alpine
LABEL org.opencontainers.image.title="colis" \
      org.opencontainers.image.source="https://github.com/menraromial/container-k8s" \
      org.opencontainers.image.version="2.0.0"
# PYTHONDONTWRITEBYTECODE d'abord : sinon, faire tourner pip écrit 4 Mo de .pyc
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH=/opt/venv/bin:$PATH
# pip ne sert plus à rien à l'exécution, et embarque des bibliothèques vulnérables
RUN python -m pip uninstall -y -q pip \
 && adduser -D -H -u 10001 colis
COPY --from=dependances /opt/venv /opt/venv
WORKDIR /app
# le code vient de l'étape de tests : sans tests réussis, pas d'image
COPY --from=tests /app/colis/ colis/
USER 10001:10001
EXPOSE 8000
CMD ["uvicorn", "colis.app:app", "--host", "0.0.0.0", "--port", "8000"]
