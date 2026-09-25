import React, {type ReactNode} from 'react';
import Content from '@theme-original/DocItem/Content';
import type ContentType from '@theme/DocItem/Content';
import type {WrapperProps} from '@docusaurus/types';
import {useDoc} from '@docusaurus/plugin-content-docs/client';
import {numeroPartie} from '@site/src/components/partie';

type Props = WrapperProps<typeof ContentType>;

type Entete = {partie?: number | string; chapitre?: string; plaque?: string};

// Plaque « Partie · Chapitre » posée au-dessus du titre.
// front matter : partie (0 à 9), chapitre (« 0.2 », « 5 »), ou plaque
// pour un libellé libre (« Défi I », « Annexe B »).
export default function ContentWrapper(props: Props): ReactNode {
  const {frontMatter} = useDoc();
  const {partie, chapitre, plaque} = frontMatter as Entete;
  const second = plaque ?? (chapitre ? `Chapitre ${chapitre}` : undefined);
  return (
    <>
      {partie !== undefined && (
        <div className="plaque">
          <span>Partie {numeroPartie(partie)}</span>
          {second && <span>{second}</span>}
        </div>
      )}
      <Content {...props} />
    </>
  );
}
