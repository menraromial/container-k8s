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
  ],
};

export default sidebars;
