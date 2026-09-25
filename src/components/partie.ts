// Numérotation des parties : 0 pour « Démarrer », chiffres romains ensuite.
const ROMAINS = ['0', 'I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX'];

export function numeroPartie(partie: number | string): string {
  if (typeof partie === 'number') {
    return ROMAINS[partie] ?? String(partie);
  }
  return partie;
}

export function classePartie(partie: number | string | undefined): string | undefined {
  if (partie === undefined) {
    return undefined;
  }
  return typeof partie === 'number' ? `partie-${partie}` : `partie-${partie.toLowerCase()}`;
}
