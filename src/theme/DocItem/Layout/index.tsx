import React, {type ReactNode} from 'react';
import Layout from '@theme-original/DocItem/Layout';
import type LayoutType from '@theme/DocItem/Layout';
import type {WrapperProps} from '@docusaurus/types';
import {useDoc} from '@docusaurus/plugin-content-docs/client';
import {classePartie} from '@site/src/components/partie';

type Props = WrapperProps<typeof LayoutType>;

// Donne à toute la page (texte, encadrés, sorties, table des matières) la
// couleur de sa partie, lue dans le front matter « partie ».
export default function LayoutWrapper(props: Props): ReactNode {
  const {frontMatter} = useDoc();
  const partie = (frontMatter as {partie?: number | string}).partie;
  return (
    <div className={classePartie(partie)}>
      <Layout {...props} />
    </div>
  );
}
