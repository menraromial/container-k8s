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
  ],
};

export default sidebars;
