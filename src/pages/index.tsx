import React, {type ReactNode} from 'react';
import Link from '@docusaurus/Link';
import Layout from '@theme/Layout';
import styles from './index.module.css';

type Partie = {
  n: string;
  couleur: string;
  titre: string;
  resume: string;
  chapitres: string;
  lien?: string;
};

const PARTIES: Partie[] = [
  {n: '0', couleur: 'var(--p0)', titre: 'Démarrer', chapitres: 'Chapitres 0.1 à 0.3',
    resume: 'Comment le cours fonctionne, installer Docker, kubectl et minikube, démarrer son premier cluster.',
    lien: '/cours/demarrer/comment-ce-cours-fonctionne'},
  {n: 'I', couleur: 'var(--p1)', titre: 'Utiliser des conteneurs', chapitres: 'Chapitres 1 à 7',
    resume: 'Lancer, construire, brancher des volumes et des réseaux, assembler Colis avec Compose.',
    lien: '/cours/partie-1'},
  {n: 'II', couleur: 'var(--p2)', titre: 'Sous le capot des conteneurs', chapitres: 'Chapitres 8 à 14',
    resume: 'Namespaces, cgroups, overlayfs, runc : fabriquer un conteneur sans Docker, puis le sécuriser.',
    lien: '/cours/partie-2'},
  {n: 'III', couleur: 'var(--p3)', titre: 'Premiers pas avec Kubernetes', chapitres: 'Chapitres 15 à 24',
    resume: 'Pods, Deployments, Services, configuration, santé et ressources : Colis tourne sur minikube.',
    lien: '/cours/partie-3'},
  {n: 'IV', couleur: 'var(--p4)', titre: 'Kubernetes au quotidien', chapitres: 'Chapitres 25 à 33',
    resume: 'Stockage, StatefulSets, Gateway API, Helm, Kustomize, autoscaling, ordonnancement fin.',
    lien: '/cours/partie-4'},
  {n: 'V', couleur: 'var(--p5)', titre: 'Anatomie du cluster', chapitres: 'Chapitres 34 à 41',
    resume: 'API server, etcd, contrôleurs, scheduler, kubelet, réseau des Pods : ce qui se passe vraiment.',
    lien: '/cours/partie-5'},
  {n: 'VI', couleur: 'var(--p6)', titre: 'Sécurité', chapitres: 'Chapitres 42 à 47',
    resume: 'Authentification, RBAC, Pod Security, contrôle d’admission, secrets, signature d’images.'},
  {n: 'VII', couleur: 'var(--p7)', titre: 'Observer et exploiter', chapitres: 'Chapitres 48 à 53',
    resume: 'Déboguer, reconnaître les pannes, métriques, logs, traces, sauvegardes, montées de version.'},
  {n: 'VIII', couleur: 'var(--p8)', titre: 'Étendre Kubernetes et livrer', chapitres: 'Chapitres 54 à 60',
    resume: 'CRD, écrire un opérateur, GitOps avec Argo CD, déploiements progressifs, service mesh.'},
  {n: 'IX', couleur: 'var(--p9)', titre: 'Projet final', chapitres: 'Chapitres 61 à 63',
    resume: 'Colis « en production » sur un cluster multi-nœuds : tout ce que vous avez appris, ensemble.'},
];

function Pile(): ReactNode {
  const couleurs = ['p0', 'p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'p7', 'p8', 'p9'];
  return (
    <div className={styles.pile} aria-hidden="true">
      {couleurs.map((c) => (
        <div key={c} style={{background: `var(--${c})`}} />
      ))}
    </div>
  );
}

function Carte({p}: {p: Partie}): ReactNode {
  const contenu = (
    <>
      <div className={styles.num}>{p.n}</div>
      <h3>{p.titre}</h3>
      <p>{p.resume}</p>
      <div className={styles.chap}>{p.lien ? p.chapitres : `${p.chapitres} · en préparation`}</div>
    </>
  );
  const style = {'--c': p.couleur} as React.CSSProperties;
  return p.lien ? (
    <Link className={styles.carte} style={style} to={p.lien}>{contenu}</Link>
  ) : (
    <div className={`${styles.carte} ${styles.inactive}`} style={style}>{contenu}</div>
  );
}

export default function Accueil(): ReactNode {
  return (
    <Layout
      title="Du premier conteneur à l’expertise Kubernetes"
      description="Un cours complet sur les conteneurs et Kubernetes, du débutant à l’expert, entièrement exécutable sur un portable avec minikube.">
      <main className={styles.page}>
        <section className={styles.hero}>
          <div>
            <h1>
              Du premier conteneur
              <br />à <em>l’expertise</em> Kubernetes
            </h1>
            <p>
              Ce cours part d’une ligne de commande et s’arrête quand vous savez écrire votre
              propre opérateur. Entre les deux, on démonte tout ce qu’on utilise : les namespaces
              du noyau, l’API server, le scheduler, le réseau des Pods. Rien n’est présenté comme
              une boîte noire.
            </p>
            <p>
              Tout se fait sur votre portable, avec minikube. Pas de compte cloud, pas de carte
              bancaire. Chaque commande a été exécutée avant d’être écrite, et les sorties que
              vous lirez sont celles qu’elle a produites.
            </p>
            <div className={styles.boutons}>
              <Link className={styles.cta} to="/cours/demarrer/comment-ce-cours-fonctionne">
                Commencer
              </Link>
              <Link className={`${styles.cta} ${styles.alt}`} to="/cours/demarrer/preparer-son-poste">
                Préparer son poste
              </Link>
            </div>
          </div>
          <Pile />
        </section>
        <section className={styles.parties}>
          {PARTIES.map((p) => (
            <Carte key={p.n} p={p} />
          ))}
        </section>
      </main>
    </Layout>
  );
}
