import {themes as prismThemes} from 'prism-react-renderer';
import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';

const config: Config = {
  title: 'Conteneurs et Kubernetes',
  tagline: 'Du premier conteneur à l’expertise Kubernetes, sur votre portable avec minikube',
  favicon: 'img/favicon.svg',

  future: {
    v4: true,
  },

  url: 'https://menraromial.com',
  baseUrl: '/container-k8s/',
  trailingSlash: false,

  onBrokenLinks: 'throw',
  markdown: {
    // notes de bas de page (sources) : libellés en français
    remarkRehypeOptions: {
      footnoteLabel: 'Sources et notes',
      footnoteBackLabel: 'Retour au texte',
    },
    hooks: {
      onBrokenMarkdownLinks: 'throw',
    },
  },

  i18n: {
    defaultLocale: 'fr',
    locales: ['fr'],
  },

  presets: [
    [
      'classic',
      {
        docs: {
          routeBasePath: 'cours',
          sidebarPath: './sidebars.ts',
          breadcrumbs: false,
          admonitions: {
            keywords: ['podman', 'panne', 'exercice'],
            extendDefaults: true,
          },
        },
        blog: false,
        theme: {
          customCss: ['./src/css/custom.css', './src/css/figures.css'],
        },
        // Les SVG des figures sont déjà préparés par figures/svgpost.py
        // (couleurs en variables CSS, identifiants préfixés) : SVGO les
        // abîmerait en fusionnant les identifiants de deux figures.
        svgr: {
          svgrConfig: {
            svgo: false,
          },
        },
      } satisfies Preset.Options,
    ],
  ],

  themes: [
    [
      '@easyops-cn/docusaurus-search-local',
      {
        hashed: true,
        language: ['fr'],
        indexBlog: false,
        docsRouteBasePath: 'cours',
        highlightSearchTermsOnTargetPage: true,
        searchBarShortcutHint: false,
      },
    ],
  ],

  themeConfig: {
    colorMode: {
      respectPrefersColorScheme: true,
    },
    docs: {
      sidebar: {
        hideable: true,
      },
    },
    navbar: {
      title: 'Conteneurs & Kubernetes',
      logo: {
        alt: '',
        src: 'img/logo.svg',
      },
      items: [
        {
          type: 'docSidebar',
          sidebarId: 'cours',
          position: 'left',
          label: 'Le cours',
        },
        {
          to: '/cours/demarrer/versions',
          label: 'Versions',
          position: 'left',
        },
      ],
    },
    footer: {
      style: 'dark',
      copyright: `Conteneurs et Kubernetes, cours de Romial Menra. Toutes les commandes ont été exécutées sur minikube avant d’être publiées.`,
    },
    prism: {
      theme: prismThemes.oneLight,
      darkTheme: prismThemes.oneDark,
      additionalLanguages: ['bash', 'docker', 'yaml', 'json', 'python', 'go', 'toml', 'ini'],
    },
    tableOfContents: {
      minHeadingLevel: 2,
      maxHeadingLevel: 3,
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
