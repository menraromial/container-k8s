import React, {useState, type ReactNode} from 'react';
import styles from './ParcoursService.module.css';

// « Où va cette connexion ? » (chapitre 40). Le trajet d'une connexion vers le Service web du chapitre,
// selon trois façons de faire : les règles iptables de kube-proxy, sa table nftables, et Cilium sans kube-proxy.
// Les adresses, les noms de chaînes et les probabilités sont ceux relevés sur minikube (rejeu-ch40.sh).

type Mode = 'iptables' | 'nftables' | 'cilium';

const SERVICE = {nom: 'web', ip: '10.101.223.47', port: 80};
const POINTS = [
  {pod: 'web-...-ft499', ip: '10.244.0.9', sep: 'KUBE-SEP-5UXWIQPGM76JJN4E'},
  {pod: 'web-...-dhmtd', ip: '10.244.1.7', sep: 'KUBE-SEP-ZEO37YB32KABCENC'},
  {pod: 'web-...-7x8bd', ip: '10.244.1.8', sep: 'KUBE-SEP-6STEJ6R4P2SZLFDQ'},
];
const SVC_CHAIN = 'KUBE-SVC-LJMWSUCFDC3EU5W3';
const NFT_CHAIN = 'service-KQQRD225-ch40/web/tcp/http';

type Etape = {texte: ReactNode; lieu: string};

// iptables : une règle par point de terminaison, la i-ème tire avec la probabilité 1/(n-i)
function tirageIptables(): {choix: number; etapes: Etape[]} {
  const etapes: Etape[] = [];
  const n = POINTS.length;
  for (let i = 0; i < n; i++) {
    if (i === n - 1) {
      etapes.push({lieu: 'nœud', texte: <>dernière règle de <code>{SVC_CHAIN}</code>, sans tirage : <code>{POINTS[i].sep}</code></>});
      return {choix: i, etapes};
    }
    const p = 1 / (n - i);
    const r = Math.random();
    const pris = r < p;
    etapes.push({
      lieu: 'nœud',
      texte: (
        <>
          règle {i + 1} de <code>{SVC_CHAIN}</code> : tirage {r.toFixed(3)} {pris ? '<' : '≥'} {p.toFixed(3)}
          {pris ? <> : saut vers <code>{POINTS[i].sep}</code></> : ' : règle suivante'}
        </>
      ),
    });
    if (pris) return {choix: i, etapes};
  }
  return {choix: n - 1, etapes};
}

function simuler(mode: Mode): {choix: number; etapes: Etape[]} {
  const debut: Etape[] = [
    {lieu: 'Pod client', texte: <>le résolveur demande <code>web.ch40.svc.cluster.local</code> à CoreDNS, qui répond <code>{SERVICE.ip}</code></>},
  ];
  if (mode === 'cilium') {
    const choix = Math.floor(Math.random() * POINTS.length);
    const p = POINTS[choix];
    return {
      choix,
      etapes: [
        ...debut,
        {lieu: 'Pod client', texte: <>l'application appelle <code>connect({SERVICE.ip}:{SERVICE.port})</code></>},
        {lieu: 'noyau (eBPF)', texte: <>le programme attaché aux sockets intercepte l'appel, tire un point de terminaison au hasard et réécrit la destination : <code>{p.ip}:8080</code></>},
        {lieu: 'Pod client', texte: <>le SYN quitte le Pod déjà adressé au Pod <code>{p.ip}</code> : aucune traduction ne l'attend en route</>},
        {lieu: 'réseau des Pods', texte: <>le paquet va au Pod <code>{p.pod}</code> comme n'importe quel paquet de Pod à Pod (chapitre 39)</>},
      ],
    };
  }
  const commun: Etape[] = [
    ...debut,
    {lieu: 'Pod client', texte: <>le SYN part vers <code>{SERVICE.ip}:{SERVICE.port}</code>, une adresse qu'aucune interface ne porte</>},
  ];
  if (mode === 'nftables') {
    const choix = Math.floor(Math.random() * POINTS.length);
    const p = POINTS[choix];
    return {
      choix,
      etapes: [
        ...commun,
        {lieu: 'nœud', texte: <>une seule recherche dans la table <code>service-ips</code> : <code>{SERVICE.ip} . tcp . {SERVICE.port}</code> mène à la chaîne <code>{NFT_CHAIN}</code></>},
        {lieu: 'nœud', texte: <><code>numgen random mod {POINTS.length}</code> donne {choix}, la table associée donne <code>{p.ip} . 8080</code></>},
        {lieu: 'nœud', texte: <>DNAT vers <code>{p.ip}:8080</code> ; conntrack retient la traduction pour la réponse</>},
        {lieu: 'réseau des Pods', texte: <>le paquet va au Pod <code>{p.pod}</code></>},
      ],
    };
  }
  const t = tirageIptables();
  const p = POINTS[t.choix];
  return {
    choix: t.choix,
    etapes: [
      ...commun,
      {lieu: 'nœud', texte: <>chaîne <code>KUBE-SERVICES</code> : la règle de <code>{SERVICE.ip}/32 tcp dpt:{SERVICE.port}</code> saute vers <code>{SVC_CHAIN}</code> (les règles des autres Services sont lues avant elle)</>},
      ...t.etapes,
      {lieu: 'nœud', texte: <><code>{p.sep}</code> : DNAT vers <code>{p.ip}:8080</code> ; conntrack retient la traduction pour la réponse</>},
      {lieu: 'réseau des Pods', texte: <>le paquet va au Pod <code>{p.pod}</code></>},
    ],
  };
}

export default function ParcoursService(): ReactNode {
  const [mode, setMode] = useState<Mode>('iptables');
  const [etapes, setEtapes] = useState<Etape[]>([]);
  const [compte, setCompte] = useState<number[]>(POINTS.map(() => 0));
  const total = compte.reduce((a, b) => a + b, 0);

  const une = () => {
    const r = simuler(mode);
    setEtapes(r.etapes);
    setCompte((c) => c.map((v, i) => (i === r.choix ? v + 1 : v)));
  };
  const trois = () => {
    const c = [...compte];
    let derniere: Etape[] = [];
    for (let k = 0; k < 300; k++) {
      const r = simuler(mode);
      c[r.choix]++;
      derniere = r.etapes;
    }
    setCompte(c);
    setEtapes(derniere);
  };
  const changer = (m: Mode) => {
    setMode(m);
    setEtapes([]);
    setCompte(POINTS.map(() => 0));
  };

  return (
    <div className={styles.cadre}>
      <div className={styles.modes} role="radiogroup" aria-label="Façon de traduire l'adresse du Service">
        {(['iptables', 'nftables', 'cilium'] as Mode[]).map((m) => (
          <label key={m} className={mode === m ? styles.actif : undefined}>
            <input type="radio" name="mode-service" checked={mode === m} onChange={() => changer(m)} />
            {m === 'cilium' ? 'Cilium sans kube-proxy' : `kube-proxy, ${m}`}
          </label>
        ))}
      </div>

      <div className={styles.boutons}>
        <button type="button" onClick={une}>une connexion</button>
        <button type="button" onClick={trois}>300 connexions</button>
        <button type="button" onClick={() => changer(mode)} disabled={total === 0}>remettre à zéro</button>
      </div>

      {etapes.length > 0 ? (
        <ol className={styles.etapes}>
          {etapes.map((e, i) => (
            <li key={i}>
              <span className={styles.lieu}>{e.lieu}</span>
              <span>{e.texte}</span>
            </li>
          ))}
        </ol>
      ) : (
        <p className={styles.note}>Envoyez une connexion vers <code>http://web/</code> pour suivre son trajet.</p>
      )}

      <table className={styles.table}>
        <thead>
          <tr>
            <th>Pod</th>
            <th>adresse</th>
            <th>connexions</th>
            <th aria-hidden="true" />
          </tr>
        </thead>
        <tbody>
          {POINTS.map((p, i) => (
            <tr key={p.ip}>
              <td><code>{p.pod}</code></td>
              <td><code>{p.ip}</code></td>
              <td>{compte[i]}{total > 0 ? ` (${Math.round((100 * compte[i]) / total)} %)` : ''}</td>
              <td className={styles.barre}>
                <span style={{width: total > 0 ? `${(100 * compte[i]) / total}%` : '0%'}} />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      <p className={styles.note}>
        Les tirages sont faits dans votre navigateur. Sur le cluster, 300 connexions en mode iptables ont donné 88, 112
        et 100 : les écarts d'une série à l'autre sont ceux du hasard, pas d'un défaut de répartition.
      </p>
    </div>
  );
}
