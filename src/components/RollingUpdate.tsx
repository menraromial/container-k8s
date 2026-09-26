import React, {useMemo, useState, type ReactNode} from 'react';
import styles from './RollingUpdate.module.css';

// Pas-à-pas d'une mise à jour progressive (chapitre 19).
// La simulation reprend la logique du contrôleur de Deployment :
//  - le nouveau ReplicaSet grandit tant que le total des Pods reste <= replicas + maxSurge ;
//  - l'ancien rétrécit tant que les Pods disponibles restent >= replicas - maxUnavailable ;
//  - un « pas » correspond au moment où les nouveaux Pods deviennent disponibles.
// Arrondis de la documentation : maxSurge en pourcentage est arrondi au-dessus,
// maxUnavailable au-dessous. Les séquences produites sont celles relevées sur minikube.

type Etat = {
  anciens: number; // Pods de l'ancien ReplicaSet (tous disponibles)
  nouveaux: number; // Pods du nouveau ReplicaSet
  nouveauxDispo: number; // parmi eux, ceux qui sont disponibles
  note: string;
};

function valeur(texte: string, replicas: number, versLeHaut: boolean): number | null {
  const t = texte.trim();
  if (/^\d+%$/.test(t)) {
    const p = (parseInt(t, 10) * replicas) / 100;
    return versLeHaut ? Math.ceil(p) : Math.floor(p);
  }
  if (/^\d+$/.test(t)) {
    return parseInt(t, 10);
  }
  return null;
}

function simuler(replicas: number, surge: number, indispo: number): Etat[] {
  const etats: Etat[] = [];
  let anciens = replicas;
  let nouveaux = 0;
  let nouveauxDispo = 0;
  etats.push({anciens, nouveaux, nouveauxDispo, note: 'Avant la mise à jour : tous les Pods ont l\'ancienne version.'});
  for (let pas = 0; pas < 50 && (anciens > 0 || nouveauxDispo < replicas); pas++) {
    // le contrôleur réconcilie jusqu'à ne plus rien pouvoir faire
    let crees = 0;
    let retires = 0;
    for (let tour = 0; tour < 10; tour++) {
      const plus = Math.max(0, Math.min(replicas + surge - (anciens + nouveaux), replicas - nouveaux));
      nouveaux += plus;
      crees += plus;
      const moins = Math.max(0, Math.min(anciens, anciens + nouveauxDispo - (replicas - indispo)));
      anciens -= moins;
      retires += moins;
      if (plus === 0 && moins === 0) {
        break;
      }
    }
    if (crees > 0 || retires > 0) {
      const morceaux: string[] = [];
      if (crees > 0) morceaux.push(`${crees} nouveau${crees > 1 ? 'x' : ''} Pod${crees > 1 ? 's' : ''} créé${crees > 1 ? 's' : ''}`);
      if (retires > 0) morceaux.push(`${retires} ancien${retires > 1 ? 's' : ''} supprimé${retires > 1 ? 's' : ''}`);
      etats.push({anciens, nouveaux, nouveauxDispo, note: `Le contrôleur agit : ${morceaux.join(', ')}.`});
    }
    if (nouveauxDispo < nouveaux) {
      nouveauxDispo = nouveaux;
      etats.push({anciens, nouveaux, nouveauxDispo, note: 'Les nouveaux Pods deviennent disponibles.'});
    } else if (crees === 0 && retires === 0) {
      break; // blocage : rien ne peut avancer
    }
  }
  return etats;
}

function Pastilles({n, classe, titre}: {n: number; classe: string; titre: string}): ReactNode {
  return (
    <>
      {Array.from({length: n}, (_, i) => (
        <span key={i} className={`${styles.pod} ${classe}`} title={titre} />
      ))}
    </>
  );
}

export default function RollingUpdate(): ReactNode {
  const [replicas, setReplicas] = useState(4);
  const [surgeTexte, setSurge] = useState('25%');
  const [indispoTexte, setIndispo] = useState('25%');
  const [pas, setPas] = useState(0);

  const surge = valeur(surgeTexte, replicas, true);
  const indispo = valeur(indispoTexte, replicas, false);
  const erreur =
    surge === null || indispo === null
      ? 'Écrivez un entier (1) ou un pourcentage (25%).'
      : surge === 0 && indispo === 0
        ? 'maxSurge et maxUnavailable ne peuvent pas valoir 0 tous les deux : la mise à jour ne pourrait jamais commencer.'
        : null;

  const etats = useMemo(
    () => (erreur ? [] : simuler(replicas, surge as number, indispo as number)),
    [replicas, surge, indispo, erreur],
  );
  const e = etats[Math.min(pas, etats.length - 1)];

  const changer = (f: () => void) => {
    f();
    setPas(0);
  };

  return (
    <div className={styles.cadre}>
      <div className={styles.reglages}>
        <label>
          replicas
          <input type="number" min={1} max={12} value={replicas}
            onChange={(ev) => changer(() => setReplicas(Math.max(1, Math.min(12, Number(ev.target.value) || 1))))} />
        </label>
        <label>
          maxSurge
          <input type="text" value={surgeTexte} onChange={(ev) => changer(() => setSurge(ev.target.value))} />
        </label>
        <label>
          maxUnavailable
          <input type="text" value={indispoTexte} onChange={(ev) => changer(() => setIndispo(ev.target.value))} />
        </label>
      </div>
      {erreur ? (
        <p className={styles.erreur}>{erreur}</p>
      ) : (
        <>
          <p className={styles.bornes}>
            Au plus <b>{replicas + (surge as number)}</b> Pods en même temps, au moins <b>{Math.max(0, replicas - (indispo as number))}</b> disponibles.
          </p>
          <div className={styles.rangee}>
            <span className={styles.etiquette}>ancien ReplicaSet</span>
            <Pastilles n={e.anciens} classe={styles.ancien} titre="ancienne version, disponible" />
          </div>
          <div className={styles.rangee}>
            <span className={styles.etiquette}>nouveau ReplicaSet</span>
            <Pastilles n={e.nouveauxDispo} classe={styles.nouveau} titre="nouvelle version, disponible" />
            <Pastilles n={e.nouveaux - e.nouveauxDispo} classe={styles.attente} titre="nouvelle version, pas encore disponible" />
          </div>
          <p className={styles.note}>
            <b>Étape {Math.min(pas, etats.length - 1)} / {etats.length - 1}.</b> {e.note} Disponibles : {e.anciens + e.nouveauxDispo} sur {replicas} voulus ; Pods existants : {e.anciens + e.nouveaux}.
          </p>
          <div className={styles.boutons}>
            <button type="button" onClick={() => setPas(Math.max(0, pas - 1))} disabled={pas === 0}>Étape précédente</button>
            <button type="button" onClick={() => setPas(Math.min(etats.length - 1, pas + 1))} disabled={pas >= etats.length - 1}>Étape suivante</button>
            <button type="button" onClick={() => setPas(0)}>Recommencer</button>
          </div>
        </>
      )}
    </div>
  );
}
