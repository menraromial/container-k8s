# Image de Colis : une seule image pour l'API, le worker et la purge.
# Construite au chapitre 4 ; allégée et durcie au défi II.
FROM python:3.14-slim

LABEL org.opencontainers.image.title="colis" \
      org.opencontainers.image.description="API, worker et purge de Colis, application fil rouge du cours" \
      org.opencontainers.image.source="https://github.com/menraromial/container-k8s" \
      org.opencontainers.image.version="1.0.0"

# PYTHONUNBUFFERED : les print() arrivent tout de suite dans docker logs
# PYTHONDONTWRITEBYTECODE : pas de fichiers .pyc écrits à l'exécution
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# les dépendances changent rarement : leur couche reste en cache
COPY requirements.txt .
RUN pip install -r requirements.txt

# un utilisateur sans privilèges, sans dossier personnel
RUN useradd --uid 10001 --user-group --no-create-home colis

# le code change souvent : il vient en dernier
COPY colis/ colis/

USER colis
EXPOSE 8000

# forme exec : uvicorn est le PID 1 et reçoit SIGTERM
CMD ["uvicorn", "colis.app:app", "--host", "0.0.0.0", "--port", "8000"]
