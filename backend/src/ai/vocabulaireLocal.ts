import { readFileSync } from 'node:fs';
import { join } from 'node:path';

/**
 * LE VOCABULAIRE LOCAL (05/10) : les plats et aliments dont le nom n'est pas
 * du français courant (placali, dambou, kilichi…), et la façon dont une
 * transcription française les déforme (« plat cali »).
 *
 * Construit à partir du catalogue par scripts/voix/vocabulaire-local.ts
 * (data/vocabulaire-local.json), plus les mots locaux déjà connus. Servi :
 *  - à la transcription, comme liste de mots à reconnaître en priorité
 *    (voixDirecte.ts, vocabulaire) ;
 *  - au cerveau, pour qu'il écrive le vrai nom dans « produit » même quand le
 *    texte le déforme (decideur.ts).
 * Pas de remplacement aveugle dans le texte : « ma fait » (mafé) ou « tout
 * haut » (tuo) sont aussi des expressions françaises ; c'est le cerveau qui
 * juge, d'après la phrase.
 */

export interface MotLocal { mot: string; variantes: string[] }

/** Les mots locaux connus avant le vocabulaire construit (enseignes et quartiers à part). */
const DEJA_CONNUS: MotLocal[] = ['attiéké', 'doukounou', 'kilichi', 'dambou', 'fura', 'massa', 'tuo', 'garba', 'alloco',
  'bissap', 'dèguè', 'tchapalo', 'wassa-wassa', 'chawarma'].map((mot) => ({ mot, variantes: [] }));

function charger(): MotLocal[] {
  let construits: MotLocal[] = [];
  try {
    const brut = JSON.parse(readFileSync(join(process.cwd(), 'data', 'vocabulaire-local.json'), 'utf8')) as { mots?: MotLocal[] };
    construits = brut.mots ?? [];
  } catch {
    // Fichier absent : les mots déjà connus suffisent.
  }
  const sans = (s: string) => s.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
  const parMot = new Map<string, MotLocal>();
  for (const m of [...construits, ...DEJA_CONNUS]) {
    const cle = sans(m.mot);
    const deja = parMot.get(cle);
    parMot.set(cle, deja ? { mot: deja.mot, variantes: [...new Set([...deja.variantes, ...m.variantes])] } : m);
  }
  return [...parMot.values()];
}

export const MOTS_LOCAUX: readonly MotLocal[] = charger();

/** Pour la consigne du cerveau : « placali (« plat cali »), dambou (« dans bout »)… ». */
export function vocabulairePourCerveau(): string {
  return MOTS_LOCAUX
    .map((m) => (m.variantes.length ? `${m.mot} (${m.variantes.slice(0, 3).map((v) => `« ${v} »`).join(', ')})` : m.mot))
    .join(', ');
}
