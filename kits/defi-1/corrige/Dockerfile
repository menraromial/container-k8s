FROM node:24-alpine

ENV NODE_ENV=production
WORKDIR /app

# les dépendances d'abord : cette couche reste en cache tant que les fichiers npm ne changent pas
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY server.js ./

# l'image officielle fournit un utilisateur non privilégié, « node »
USER node
EXPOSE 3000
CMD ["node", "server.js"]
