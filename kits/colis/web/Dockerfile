# Image web de Colis : nginx sert la page et relaie /api/ vers l'API.
FROM nginx:1.30-alpine

LABEL org.opencontainers.image.title="colis-web" \
      org.opencontainers.image.description="Site web de Colis, servi par nginx" \
      org.opencontainers.image.source="https://github.com/menraromial/container-k8s" \
      org.opencontainers.image.version="1.0.0"

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY site/ /usr/share/nginx/html/
