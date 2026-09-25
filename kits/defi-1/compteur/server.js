// Compteur de visites : chaque GET /visite incrémente un compteur stocké dans Redis.
const http = require('node:http');
const os = require('node:os');
const { createClient } = require('redis');

const port = Number(process.env.PORT ?? 3000);
const redis = createClient({ url: process.env.REDIS_URL ?? 'redis://localhost:6379' });
redis.on('error', (err) => console.error(`redis : ${err.message}`));

const serveur = http.createServer(async (req, res) => {
  if (req.url === '/sante') {
    const pret = redis.isReady;
    res.writeHead(pret ? 200 : 503, { 'Content-Type': 'text/plain' });
    res.end(pret ? 'ok\n' : 'redis injoignable\n');
    return;
  }
  if (req.url === '/visite') {
    const visites = await redis.incr('visites');
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ visites, hote: os.hostname() }) + '\n');
    return;
  }
  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('introuvable\n');
});

async function main() {
  await redis.connect();
  serveur.listen(port, () => console.log(`compteur à l'écoute sur le port ${port}`));
}

main().catch((err) => {
  console.error(`démarrage impossible : ${err.message}`);
  process.exit(1);
});
