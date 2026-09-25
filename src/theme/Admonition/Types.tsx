import React, {type ReactNode} from 'react';
import DefaultAdmonitionTypes from '@theme-original/Admonition/Types';
import AdmonitionLayout from '@theme/Admonition/Layout';
import type {Props} from '@theme/Admonition';

// Encadrés propres au cours, en plus de note, tip, info, warning, danger :
//   :::podman     ce qui change quand on utilise Podman à la place de Docker
//   :::panne      un message d'erreur réel, sa cause, sa correction
//   :::exercice   un exercice, titré « Exercice N » : :::exercice[Exercice 0.1]
function encadre(type: string, titreParDefaut: string) {
  return function Encadre(props: Props): ReactNode {
    return (
      <AdmonitionLayout
        {...props}
        type={type}
        icon={null}
        title={props.title ?? titreParDefaut}>
        {props.children}
      </AdmonitionLayout>
    );
  };
}

const AdmonitionTypes = {
  ...DefaultAdmonitionTypes,
  podman: encadre('podman', 'Avec Podman'),
  panne: encadre('panne', 'Panne courante'),
  exercice: encadre('exercice', 'Exercice'),
};

export default AdmonitionTypes;
