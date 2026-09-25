// Toutes les requêtes passent par nginx, qui relaie /api/ vers l'API.
const API = '/api';

async function appeler(chemin, options) {
  const reponse = await fetch(API + chemin, options);
  if (!reponse.ok) {
    throw new Error(`${reponse.status} ${await reponse.text()}`);
  }
  return reponse.json();
}

async function afficherEtat() {
  try {
    const sante = await appeler('/sante');
    const pret = await appeler('/pret');
    document.getElementById('etat').textContent =
      `API ${sante.version}, servie par ${sante.hote} ; stockage : ${pret.stockage}, file : ${pret.file}`;
  } catch (e) {
    document.getElementById('etat').textContent = `API injoignable (${e.message})`;
  }
}

async function remplirVilles() {
  const villes = await appeler('/villes');
  for (const nom of ['depart', 'arrivee']) {
    const select = document.querySelector(`select[name=${nom}]`);
    select.innerHTML = villes.map((v) => `<option>${v}</option>`).join('');
  }
  document.querySelector('select[name=arrivee]').value = villes[1];
}

function ligne(c) {
  const tr = document.createElement('tr');
  const cellules = [c.id, c.destinataire, `${c.depart} → ${c.arrivee}`, `${c.poids_kg} kg`, c.statut, c.livraison_estimee ?? 'en cours de calcul'];
  for (const valeur of cellules) {
    const td = document.createElement('td');
    td.textContent = valeur;
    tr.appendChild(td);
  }
  return tr;
}

async function afficherColis() {
  try {
    const colis = await appeler('/colis');
    document.getElementById('liste').replaceChildren(...colis.map(ligne));
  } catch (e) {
    /* l'état de l'API est déjà affiché en haut de la page */
  }
}

document.getElementById('formulaire').addEventListener('submit', async (evenement) => {
  evenement.preventDefault();
  const donnees = Object.fromEntries(new FormData(evenement.target));
  donnees.poids_kg = Number(donnees.poids_kg);
  const message = document.getElementById('message');
  try {
    const colis = await appeler('/colis', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify(donnees),
    });
    message.textContent = `Colis n° ${colis.id} enregistré.`;
    afficherColis();
  } catch (e) {
    message.textContent = `Échec : ${e.message}`;
  }
});

afficherEtat();
remplirVilles().catch(() => {});
afficherColis();
setInterval(afficherColis, 2000);
