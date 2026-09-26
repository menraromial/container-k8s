import React, {useMemo, useState, type ReactNode} from 'react';
import styles from './Ordonnanceur.module.css';

// « Où ira ce Pod ? » (chapitre 32). Un modèle réduit du scheduler, sur les trois nœuds du chapitre :
//  - filtrage : chaque nœud est écarté s'il n'a pas l'étiquette demandée (nodeSelector), s'il porte
//    un taint non toléré, s'il est marqué non planifiable (cordon), s'il manque de processeur,
//    ou s'il héberge déjà une réplique alors que l'anti-affinité l'interdit ;
//  - score : processeur libre (NodeResourcesFit, poids 1) plus l'affinité préférée pour le SSD
//    (NodeAffinity, poids 2), chacun ramené entre 0 et 100 ;
//  - préemption : si aucun nœud ne convient et que le Pod est prioritaire, un Pod de fond est évincé.
// Les messages reprennent ceux de kube-scheduler relevés sur le cluster du cours.

type Noeud = {
  nom: string;
  zone: string;
  ssd: boolean;
  replique: boolean; // une réplique du même Deployment y tourne déjà
  systeme: number; // cœurs déjà demandés par les Pods système (relevés sur le cluster du cours)
};

const NOEUDS: Noeud[] = [
  {nom: 'deux-noeuds', zone: 'zone-a', ssd: false, replique: true, systeme: 0.85},
  {nom: 'deux-noeuds-m02', zone: 'zone-b', ssd: false, replique: false, systeme: 0.1},
  {nom: 'deux-noeuds-m03', zone: 'zone-c', ssd: true, replique: true, systeme: 0.1},
];

const arrondi = (x: number) => Math.round(x * 100) / 100;
const fr = (x: number) => String(x).replace('.', ',');

function Case({v, set, children}: {v: boolean; set: (b: boolean) => void; children: ReactNode}): ReactNode {
  return (
    <label className={styles.case}>
      <input type="checkbox" checked={v} onChange={(e) => set(e.target.checked)} />
      <span>{children}</span>
    </label>
  );
}

const CPU_TOTAL = 22;

type Resultat = {
  noeud: Noeud;
  raison: string | null; // null : le nœud passe le filtrage
  cle: string | null; // morceau du message du scheduler
  libre: number;
  score: number | null;
};

export default function Ordonnanceur(): ReactNode {
  const [taint, setTaint] = useState(false);
  const [cordon, setCordon] = useState(false);
  const [charges, setCharges] = useState(false);
  const [selecteur, setSelecteur] = useState(false);
  const [tolerance, setTolerance] = useState(false);
  const [preference, setPreference] = useState(false);
  const [antiAffinite, setAntiAffinite] = useState(false);
  const [cpu, setCpu] = useState(1);
  const [critique, setCritique] = useState(false);

  const resultats: Resultat[] = useMemo(
    () =>
      NOEUDS.map((n) => {
        const libre = arrondi(CPU_TOTAL - n.systeme - (charges ? 20 : 0));
        let raison: string | null = null;
        let cle: string | null = null;
        if (selecteur && !n.ssd) {
          raison = "pas d'étiquette disque=ssd";
          cle = "didn't match Pod's node affinity/selector";
        } else if (cordon && n.nom === 'deux-noeuds-m02') {
          raison = 'marqué non planifiable (cordon)';
          cle = 'were unschedulable';
        } else if (taint && n.ssd && !tolerance) {
          raison = 'taint dedie=calcul:NoSchedule non toléré';
          cle = 'had untolerated taint(s)';
        } else if (antiAffinite && n.replique) {
          raison = 'une réplique y tourne déjà';
          cle = "didn't match pod anti-affinity rules";
        } else if (cpu > libre) {
          raison = `${fr(libre)} cœur${libre > 1 ? 's' : ''} libre${libre > 1 ? 's' : ''} pour ${fr(cpu)} demandé${cpu > 1 ? 's' : ''}`;
          cle = 'Insufficient cpu';
        }
        let score: number | null = null;
        if (raison === null) {
          const ressources = Math.round(((libre - cpu) / CPU_TOTAL) * 100);
          const affinite = preference && n.ssd ? 100 : 0;
          score = ressources + 2 * affinite;
        }
        return {noeud: n, raison, cle, libre, score};
      }),
    [taint, cordon, charges, selecteur, tolerance, preference, antiAffinite, cpu],
  );

  const candidats = resultats.filter((r) => r.score !== null);
  const choisi = candidats.length
    ? candidats.reduce((a, b) => ((b.score as number) > (a.score as number) ? b : a))
    : null;

  // préemption : seul un manque de processeur peut se régler en évinçant des Pods de fond (10 cœurs chacun) ;
  // on retient le nœud qui aurait le plus de place une fois un Pod de fond parti
  const preemptables = resultats.filter((r) => r.cle === 'Insufficient cpu' && r.libre + 10 >= cpu);
  const preempte =
    !choisi && critique && charges && preemptables.length
      ? preemptables.reduce((a, b) => (b.libre > a.libre ? b : a))
      : null;

  let message: string;
  if (choisi) {
    message = `Le Pod va sur ${choisi.noeud.nom}.`;
  } else {
    const compte = new Map<string, number>();
    resultats.forEach((r) => r.cle && compte.set(r.cle, (compte.get(r.cle) ?? 0) + 1));
    // comme kube-scheduler : une raison par type, triées par ordre alphabétique
    const morceaux = [...compte.entries()]
      .map(([cle, nb]) => (cle.startsWith('Insufficient') ? `${cle}` : `node(s) ${cle}`) + `\u0000${nb}`)
      .sort()
      .map((t) => {
        const [texte, nb] = t.split('\u0000');
        return `${nb} ${texte}`;
      });
    message = `0/3 nodes are available: ${morceaux.join(', ')}.`;
  }

  return (
    <div className={styles.cadre}>
      <div className={styles.colonnes}>
        <fieldset className={styles.groupe}>
          <legend>Les nœuds</legend>
          <Case v={taint} set={setTaint}>
            taint <code>dedie=calcul:NoSchedule</code> sur m03
          </Case>
          <Case v={cordon} set={setCordon}>
            m02 marqué non planifiable (<code>cordon</code>)
          </Case>
          <Case v={charges} set={setCharges}>
            nœuds chargés par des Pods de fond (2 × 10 cœurs par nœud)
          </Case>
        </fieldset>
        <fieldset className={styles.groupe}>
          <legend>Le Pod</legend>
          <Case v={selecteur} set={setSelecteur}>
            <code>nodeSelector: disque=ssd</code>
          </Case>
          <Case v={tolerance} set={setTolerance}>
            tolère <code>dedie=calcul</code>
          </Case>
          <Case v={preference} set={setPreference}>
            préfère le SSD (affinité <code>preferred</code>)
          </Case>
          <Case v={antiAffinite} set={setAntiAffinite}>
            jamais avec une autre réplique (répliques sur a et c)
          </Case>
          <Case v={critique} set={setCritique}>
            <code>priorityClassName: critique</code>
          </Case>
          <label className={styles.choix}>
            <span>request de processeur</span>
            <select value={cpu} onChange={(e) => setCpu(Number(e.target.value))}>
              {[0.1, 1, 5].map((v) => (
                <option key={v} value={v}>
                  {v < 1 ? `${v * 1000}m` : v}
                </option>
              ))}
            </select>
          </label>
        </fieldset>
      </div>

      <table className={styles.table}>
        <thead>
          <tr>
            <th>nœud</th>
            <th>filtrage</th>
            <th>score</th>
          </tr>
        </thead>
        <tbody>
          {resultats.map((r) => (
            <tr
              key={r.noeud.nom}
              className={
                choisi?.noeud.nom === r.noeud.nom || preempte?.noeud.nom === r.noeud.nom
                  ? styles.retenu
                  : r.score === null
                    ? styles.ecarte
                    : undefined
              }>
              <td>
                <code>{r.noeud.nom}</code>
                <div className={styles.detail}>
                  {r.noeud.zone}
                  {r.noeud.ssd ? ', disque=ssd' : ''} ; {fr(r.libre)} cœurs libres
                </div>
              </td>
              <td>{r.raison === null ? 'retenu' : `écarté : ${r.raison}`}</td>
              <td>{r.score === null ? 'sans objet' : r.score}</td>
            </tr>
          ))}
        </tbody>
      </table>

      <p className={styles.verdict}>
        {choisi ? (
          <strong>{message}</strong>
        ) : (
          <>
            Le Pod reste <strong>Pending</strong> : <code>{message}</code>
          </>
        )}
      </p>
      {preempte && (
        <p className={styles.verdict}>
          Mais il est prioritaire : le scheduler évince un Pod de fond sur <code>{preempte.noeud.nom}</code> (
          <code>Preempted</code>), puis y place le Pod au cycle suivant.
        </p>
      )}
      {!choisi && critique && !preempte && (
        <p className={styles.note}>
          La priorité n'y change rien : évincer des Pods ne donne ni une étiquette, ni une tolérance, ni une
          place hors d'un nœud non planifiable.
        </p>
      )}
      <p className={styles.note}>
        Modèle simplifié : le vrai scheduler a une vingtaine d'extensions de filtrage et de score, avec leurs
        propres poids.
      </p>
    </div>
  );
}
