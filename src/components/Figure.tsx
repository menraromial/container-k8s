import React, {type ComponentType, type ReactNode, type SVGProps} from 'react';

type Props = {
  // composant importé depuis src/figures (source : figures/src/<nom>.tex) :
  //   import colis from '@site/src/figures/colis-architecture.svg';
  //   <Figure svg={colis} num="0.1" alt="...">légende</Figure>
  svg: ComponentType<SVGProps<SVGSVGElement> & {title?: string}>;
  num: string;
  alt: string;
  children: ReactNode;
};

// Les SVG sont insérés dans la page (et non en <img>) pour que leurs couleurs,
// écrites en variables CSS, suivent le thème clair ou sombre.
export default function Figure({svg: Svg, num, alt, children}: Props): ReactNode {
  return (
    <figure className="figure">
      <Svg role="img" aria-label={alt} />
      <figcaption>
        <b>Figure {num}</b>
        {children}
      </figcaption>
    </figure>
  );
}
