import type {SidebarsConfig} from '@docusaurus/plugin-content-docs';

// Une catégorie par partie. La classe « partie-N » donne sa couleur de
// conteneur à la catégorie (pastille, lien actif) : voir src/css/custom.css.
const sidebars: SidebarsConfig = {
  cours: [
    {
      type: 'category',
      label: '0 · Démarrer',
      className: 'partie-0',
      collapsed: false,
      items: [
        'demarrer/comment-ce-cours-fonctionne',
        'demarrer/preparer-son-poste',
        'demarrer/versions',
      ],
    },
    {
      type: 'category',
      label: 'I · Utiliser des conteneurs',
      className: 'partie-1',
      collapsed: false,
      link: {type: 'doc', id: 'partie-1/index'},
      items: [
        'partie-1/le-probleme',
        'partie-1/premier-conteneur',
        'partie-1/images',
        'partie-1/dockerfile',
        'partie-1/donnees',
        'partie-1/reseau',
        'partie-1/compose',
        'partie-1/defi',
      ],
    },
    {
      type: 'category',
      label: 'II · Sous le capot',
      className: 'partie-2',
      collapsed: false,
      link: {type: 'doc', id: 'partie-2/index'},
      items: [
        'partie-2/namespaces',
        'partie-2/cgroups',
        'partie-2/overlayfs',
        'partie-2/runtimes',
        'partie-2/securite',
        'partie-2/images-production',
        'partie-2/chaine-approvisionnement',
        'partie-2/defi',
      ],
    },
    {
      type: 'category',
      label: 'III · Premiers pas avec Kubernetes',
      className: 'partie-3',
      collapsed: false,
      link: {type: 'doc', id: 'partie-3/index'},
      items: [
        'partie-3/orchestrateur',
        'partie-3/minikube-kubectl',
        'partie-3/pod',
        'partie-3/declaratif',
        'partie-3/deployment',
        'partie-3/services',
        'partie-3/configuration',
        'partie-3/sante',
        'partie-3/ressources',
        'partie-3/colis-minikube',
      ],
    },
  ],
};

export default sidebars;
