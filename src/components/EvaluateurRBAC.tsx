import React, {useState, type ReactNode} from 'react';
import styles from './EvaluateurRBAC.module.css';

// « Qui a le droit ? » (chapitre 43). Évalue une requête comme l'API server de minikube :
// groupe privilégié system:masters, puis RBAC, liaison par liaison. Les rôles et les liaisons
// sont ceux du chapitre (rejeu-ch43.sh) ; la ClusterRole view est réduite aux ressources proposées ici.

type Regle = {groupes: string[]; ressources: string[]; verbes: string[]; noms?: string[]};
type Role = {kind: 'Role' | 'ClusterRole'; nom: string; regles: Regle[]};
type Sujet = {kind: 'User' | 'Group' | 'ServiceAccount'; nom: string};
type Liaison = {kind: 'RoleBinding' | 'ClusterRoleBinding'; nom: string; ns?: string; role: Role; sujets: Sujet[]};

const LECTURE = ['get', 'list', 'watch'];

const ASTREINTE: Role = {kind: 'Role', nom: 'astreinte', regles: [
  {groupes: [''], ressources: ['pods', 'pods/log', 'services', 'endpoints', 'events', 'configmaps'], verbes: LECTURE},
  {groupes: ['apps'], ressources: ['deployments', 'statefulsets', 'replicasets'], verbes: LECTURE},
  {groupes: ['apps'], ressources: ['deployments'], noms: ['api', 'web', 'worker'], verbes: ['patch']},
]};
const DEPLOYEUR: Role = {kind: 'Role', nom: 'deployeur', regles: [
  {groupes: ['apps'], ressources: ['deployments'], verbes: LECTURE},
  {groupes: ['apps'], ressources: ['deployments'], noms: ['api', 'web', 'worker'], verbes: ['patch']},
]};
const JOURNAUX: Role = {kind: 'Role', nom: 'journaux', regles: [
  {groupes: [''], ressources: ['pods', 'pods/log'], verbes: ['get']},
]};
const VIEW: Role = {kind: 'ClusterRole', nom: 'view', regles: [
  {groupes: [''], ressources: ['pods', 'pods/log', 'services', 'configmaps', 'events'], verbes: LECTURE},
  {groupes: ['apps'], ressources: ['deployments', 'statefulsets', 'replicasets'], verbes: LECTURE},
  {groupes: ['keda.sh'], ressources: ['scaledobjects'], verbes: LECTURE},
]};
const LECTURE_COLIS: Role = {kind: 'ClusterRole', nom: 'lecture-colis', regles: [
  {groupes: [''], ressources: ['pods', 'pods/log', 'services', 'configmaps', 'events'], verbes: LECTURE},
  {groupes: ['apps'], ressources: ['deployments', 'statefulsets', 'replicasets'], verbes: LECTURE},
]};
const CLUSTER_ADMIN: Role = {kind: 'ClusterRole', nom: 'cluster-admin', regles: [
  {groupes: ['*'], ressources: ['*'], verbes: ['*']},
]};

const LIAISONS: Liaison[] = [
  {kind: 'ClusterRoleBinding', nom: 'cluster-admin', role: CLUSTER_ADMIN, sujets: [{kind: 'Group', nom: 'system:masters'}]},
  {kind: 'ClusterRoleBinding', nom: 'minikube-rbac', role: CLUSTER_ADMIN, sujets: [{kind: 'ServiceAccount', nom: 'kube-system/default'}]},
  {kind: 'RoleBinding', nom: 'astreinte', ns: 'colis', role: ASTREINTE, sujets: [{kind: 'Group', nom: 'equipe-colis'}]},
  {kind: 'RoleBinding', nom: 'deployeur', ns: 'colis', role: DEPLOYEUR, sujets: [{kind: 'ServiceAccount', nom: 'colis/deployeur'}]},
  {kind: 'RoleBinding', nom: 'journaux', ns: 'colis', role: JOURNAUX, sujets: [{kind: 'Group', nom: 'support'}]},
  {kind: 'RoleBinding', nom: 'cours-view-carla', ns: 'colis', role: VIEW, sujets: [{kind: 'User', nom: 'carla'}]},
  {kind: 'RoleBinding', nom: 'lecture-colis', ns: 'colis-dev', role: LECTURE_COLIS, sujets: [{kind: 'Group', nom: 'equipe-colis'}]},
  {kind: 'RoleBinding', nom: 'lecture-colis', ns: 'colis-helm', role: LECTURE_COLIS, sujets: [{kind: 'Group', nom: 'equipe-colis'}]},
];

type Identite = {cle: string; libelle: string; nom: string; groupes: string[]; sa?: string};
const IDENTITES: Identite[] = [
  {cle: 'alice', libelle: 'alice (certificat, O=equipe-colis)', nom: 'alice', groupes: ['equipe-colis', 'system:authenticated']},
  {cle: 'carla', libelle: 'carla (aucun groupe)', nom: 'carla', groupes: ['system:authenticated']},
  {cle: 'sam', libelle: 'sam (groupe support)', nom: 'sam', groupes: ['support', 'system:authenticated']},
  {cle: 'deployeur', libelle: 'ServiceAccount colis/deployeur', nom: 'system:serviceaccount:colis:deployeur',
    groupes: ['system:serviceaccounts', 'system:serviceaccounts:colis', 'system:authenticated'], sa: 'colis/deployeur'},
  {cle: 'ksdefault', libelle: 'ServiceAccount kube-system/default', nom: 'system:serviceaccount:kube-system:default',
    groupes: ['system:serviceaccounts', 'system:serviceaccounts:kube-system', 'system:authenticated'], sa: 'kube-system/default'},
  {cle: 'minikube', libelle: 'minikube-user (O=system:masters)', nom: 'minikube-user', groupes: ['system:masters', 'system:authenticated']},
];

const RESSOURCES: {cle: string; groupe: string}[] = [
  {cle: 'pods', groupe: ''}, {cle: 'pods/log', groupe: ''}, {cle: 'secrets', groupe: ''}, {cle: 'configmaps', groupe: ''},
  {cle: 'deployments', groupe: 'apps'}, {cle: 'statefulsets', groupe: 'apps'}, {cle: 'scaledobjects', groupe: 'keda.sh'},
];
const VERBES = ['get', 'list', 'watch', 'create', 'patch', 'delete'];
const NAMESPACES = ['colis', 'colis-dev', 'colis-helm', 'ch43'];

const contient = (liste: string[], v: string) => liste.includes('*') || liste.includes(v);

function sujetCorrespond(s: Sujet, id: Identite): boolean {
  if (s.kind === 'User') return s.nom === id.nom;
  if (s.kind === 'Group') return id.groupes.includes(s.nom);
  return s.nom === id.sa;
}

type Requete = {verbe: string; ressource: string; groupe: string; ns: string; nom: string};

// Une règle couvre la requête si verbe, groupe et ressource correspondent ; une règle à noms
// ne couvre ni create ni une requête sans nom (list sans sélecteur de champ, par exemple).
function regleCorrespond(r: Regle, q: Requete): boolean {
  if (!contient(r.verbes, q.verbe) || !contient(r.groupes, q.groupe) || !contient(r.ressources, q.ressource)) return false;
  if (r.noms) return q.verbe !== 'create' && q.nom !== '' && r.noms.includes(q.nom);
  return true;
}

type Ligne = {liaison: Liaison; portee: boolean; sujet: Sujet | undefined; regle: Regle | undefined};

function evaluer(id: Identite, q: Requete) {
  if (id.groupes.includes('system:masters')) return {masters: true, lignes: [] as Ligne[], accorde: undefined};
  const lignes: Ligne[] = LIAISONS.map((l) => ({
    liaison: l,
    portee: l.kind === 'ClusterRoleBinding' || l.ns === q.ns,
    sujet: l.sujets.find((s) => sujetCorrespond(s, id)),
    regle: l.role.regles.find((r) => regleCorrespond(r, q)),
  }));
  const accorde = lignes.find((l) => l.portee && l.sujet && l.regle);
  return {masters: false, lignes, accorde};
}

function texteSujet(s: Sujet): string {
  if (s.kind === 'ServiceAccount') {
    const [ns, nom] = s.nom.split('/');
    return `ServiceAccount "${nom}/${ns}"`;
  }
  return `${s.kind} "${s.nom}"`;
}

function messageRefus(id: Identite, q: Requete): string {
  const [principale] = q.ressource.split('/');
  const objet = q.nom ? `${principale}${q.groupe ? '.' + q.groupe : ''} "${q.nom}"` : `${principale}${q.groupe ? '.' + q.groupe : ''}`;
  return `Error from server (Forbidden): ${objet} is forbidden: User "${id.nom}" cannot ${q.verbe} resource "${q.ressource}" in API group "${q.groupe}" in the namespace "${q.ns}"`;
}

function Choix({libelle, valeur, options, onChange}: {libelle: string; valeur: string; options: {v: string; t: string}[]; onChange: (v: string) => void}): ReactNode {
  return (
    <label className={styles.choix}>
      <span>{libelle}</span>
      <select value={valeur} onChange={(e) => onChange(e.target.value)}>
        {options.map((o) => <option key={o.v} value={o.v}>{o.t}</option>)}
      </select>
    </label>
  );
}

export default function EvaluateurRBAC(): ReactNode {
  const [idCle, setId] = useState('alice');
  const [verbe, setVerbe] = useState('patch');
  const [ressource, setRessource] = useState('deployments');
  const [ns, setNs] = useState('colis');
  const [nom, setNom] = useState('api');

  const id = IDENTITES.find((i) => i.cle === idCle)!;
  const groupe = RESSOURCES.find((r) => r.cle === ressource)!.groupe;
  const q: Requete = {verbe, ressource, groupe, ns, nom: nom.trim()};
  const {masters, lignes, accorde} = evaluer(id, q);

  return (
    <div className={styles.cadre}>
      <div className={styles.formulaire}>
        <Choix libelle="Qui" valeur={idCle} onChange={setId} options={IDENTITES.map((i) => ({v: i.cle, t: i.libelle}))} />
        <Choix libelle="Verbe" valeur={verbe} onChange={setVerbe} options={VERBES.map((v) => ({v, t: v}))} />
        <Choix libelle="Ressource" valeur={ressource} onChange={setRessource}
          options={RESSOURCES.map((r) => ({v: r.cle, t: r.groupe ? `${r.cle}.${r.groupe}` : r.cle}))} />
        <Choix libelle="Namespace" valeur={ns} onChange={setNs} options={NAMESPACES.map((n) => ({v: n, t: n}))} />
        <label className={styles.choix}>
          <span>Nom (facultatif)</span>
          <input type="text" value={nom} onChange={(e) => setNom(e.target.value)} placeholder="api, redis, colis-db…" />
        </label>
      </div>

      <p className={styles.requete}>
        <code>{id.nom}</code> demande <code>{verbe}</code> sur <code>{groupe ? `${ressource}.${groupe}` : ressource}{q.nom ? `/${q.nom}` : ''}</code> dans <code>{ns}</code>, avec les groupes <code>{id.groupes.join(', ')}</code>.
      </p>

      <ol className={styles.etapes}>
        <li>
          <strong>Groupes privilégiés.</strong>{' '}
          {masters
            ? <>membre de <code>system:masters</code> : la requête est autorisée ici, sans que RBAC soit consulté.</>
            : <>pas membre de <code>system:masters</code> : on continue.</>}
        </li>
        {!masters && (
          <>
            <li><strong>Node.</strong> pas une identité de nœud (<code>system:nodes</code>) : cet autorisateur n'a pas d'avis.</li>
            <li>
              <strong>RBAC</strong>, liaison par liaison :
              <table className={styles.table}>
                <thead>
                  <tr><th>liaison</th><th>rôle</th><th>portée</th><th>sujet</th><th>règle</th></tr>
                </thead>
                <tbody>
                  {lignes.map((l) => {
                    const ok = l === accorde;
                    return (
                      <tr key={`${l.liaison.nom}-${l.liaison.ns ?? ''}`} className={ok ? styles.accorde : undefined}>
                        <td><code>{l.liaison.ns ? `${l.liaison.ns}/` : ''}{l.liaison.nom}</code></td>
                        <td><code>{l.liaison.role.nom}</code></td>
                        <td className={l.portee ? styles.oui : styles.non}>{l.portee ? 'oui' : 'non'}</td>
                        <td className={l.sujet ? styles.oui : styles.non}>{l.sujet ? texteSujet(l.sujet) : 'non'}</td>
                        <td className={l.regle ? styles.oui : styles.non}>{l.regle ? (l.regle.noms ? `oui, noms ${l.regle.noms.join(', ')}` : 'oui') : 'non'}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </li>
          </>
        )}
      </ol>

      <div className={masters || accorde ? styles.verdictOui : styles.verdictNon}>
        {masters && <>Autorisé : le groupe <code>system:masters</code> passe avant tout autre autorisateur.</>}
        {!masters && accorde && (
          <>Autorisé. Raison donnée par un SubjectAccessReview :<br />
            <code>RBAC: allowed by {accorde.liaison.kind} "{accorde.liaison.nom}{accorde.liaison.ns ? `/${accorde.liaison.ns}` : ''}" of {accorde.liaison.role.kind} "{accorde.liaison.role.nom}" to {texteSujet(accorde.sujet!)}</code></>
        )}
        {!masters && !accorde && (
          <>Refusé : aucune liaison ne réunit la bonne portée, le bon sujet et une règle qui couvre la requête. kubectl afficherait :<br />
            <code>{messageRefus(id, q)}</code></>
        )}
      </div>
    </div>
  );
}
