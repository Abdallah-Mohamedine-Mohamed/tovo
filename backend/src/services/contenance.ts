/**
 * Les CONTENANCES d'un texte, en quantités comparables : « 12kg », « 12 kg »
 * → 12 000 g ; « 1 litre », « 1L », « 100 cl », « 1000 ml » → 1 000 ml.
 *
 * Pourquoi : la recherche par mots ignore les mots d'une lettre
 * (catalog_products_page, `length(word) >= 2`) — « gaz 6 kg » cherchait
 * « gaz kg », et les bouteilles de 12 kg sortaient au même rang que celles
 * de 6 kg (banc-clients, 19/10). Une contenance demandée est une EXIGENCE :
 * elle se compare en nombres, pas en morceaux de texte (« 1 kg » n'est pas
 * dans « 11 kg » ; « 1 litre » vaut « 1000 ml »).
 *
 * Un lot (« 6 x 1 L », « pack de 6 ») garde la contenance de l'unité : six
 * bouteilles d'un litre ne sont pas un bidon de 6 litres.
 */

export type Unite = 'ml' | 'g';
export interface Quantite { valeur: number; unite: Unite }

const UNITES: Record<string, { unite: Unite; facteur: number }> = {
  ml: { unite: 'ml', facteur: 1 },
  cl: { unite: 'ml', facteur: 10 },
  dl: { unite: 'ml', facteur: 100 },
  l: { unite: 'ml', facteur: 1000 },
  litre: { unite: 'ml', facteur: 1000 },
  litres: { unite: 'ml', facteur: 1000 },
  g: { unite: 'g', facteur: 1 },
  gr: { unite: 'g', facteur: 1 },
  gramme: { unite: 'g', facteur: 1 },
  grammes: { unite: 'g', facteur: 1 },
  kg: { unite: 'g', facteur: 1000 },
  kilo: { unite: 'g', facteur: 1000 },
  kilos: { unite: 'g', facteur: 1000 },
  kilogramme: { unite: 'g', facteur: 1000 },
  kilogrammes: { unite: 'g', facteur: 1000 },
};

const MOTIF = /(?:^|[^a-z0-9.,/])(\d+(?:[.,]\d+)?|\d+\/\d+)\s*(kilogrammes?|kilos?|kg|grammes?|gr|g|litres?|l|dl|cl|ml)(?![a-z0-9])/g;

function nombre(brut: string): number {
  if (brut.includes('/')) {
    const [a, b] = brut.split('/').map(Number);
    return a! / b!;
  }
  return Number(brut.replace(',', '.'));
}

/** Toutes les contenances écrites dans le texte (sans doublon). */
export function quantites(texte: string): Quantite[] {
  const t = ` ${texte.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()} `;
  const vues = new Map<string, Quantite>();
  for (const m of t.matchAll(MOTIF)) {
    const u = UNITES[m[2]!];
    const n = nombre(m[1]!);
    if (!u || !Number.isFinite(n) || n <= 0) continue;
    // « 4G », « 5G » : le réseau, pas des grammes.
    if (/^[2-5]g$/.test(m[0].trim().replace(/^[^0-9]/, ''))) continue;
    const q = { valeur: Math.round(n * u.facteur * 1000) / 1000, unite: u.unite };
    vues.set(`${q.valeur}${q.unite}`, q);
  }
  return [...vues.values()];
}

/** La contenance demandée par le client, s'il en donne une seule. */
export function quantiteDemandee(requete: string): Quantite | null {
  const toutes = quantites(requete);
  return toutes.length === 1 ? toutes[0]! : null;
}

function egales(a: Quantite, b: Quantite): boolean {
  return a.unite === b.unite && Math.abs(a.valeur - b.valeur) <= b.valeur * 0.01;
}

/**
 * Un produit, face à la contenance demandée : `conforme` s'il l'affiche,
 * `autre` s'il n'affiche que des contenances différentes de même nature
 * (masse ou volume), `inconnue` sinon (un plat, un parfum sans format).
 */
export function selonQuantite(nomProduit: string, demandee: Quantite): 'conforme' | 'autre' | 'inconnue' {
  const memeNature = quantites(nomProduit).filter((q) => q.unite === demandee.unite);
  if (memeNature.length === 0) return 'inconnue';
  return memeNature.some((q) => egales(q, demandee)) ? 'conforme' : 'autre';
}
