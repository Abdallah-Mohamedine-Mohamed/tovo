/**
 * Un passage de la boucle du banc IA, à la main (le serveur le fait tout
 * seul toutes les 30 minutes : src/services/bancIa.ts).
 *
 *   npm run banc:boucle                  → un passage (écrit en base)
 *   npm run banc:boucle -- --sec         → sans rien écrire en base (essai)
 *   npm run banc:boucle -- --phrases 40  → plus ou moins de phrases écrites
 *   npm run banc:boucle -- --jours 3     → récolter 3 jours en arrière
 */
import { mkdirSync, writeFileSync } from 'node:fs';

const { passageDuBanc } = await import('../../src/ai/banc/passage.js');

const argv = process.argv.slice(2);
const valeur = (nom: string) => {
  const i = argv.indexOf(nom);
  return i >= 0 ? Number(argv[i + 1]) : undefined;
};
const sec = argv.includes('--sec');
const phrases = valeur('--phrases');
const scenarios = valeur('--scenarios');
const echantillon = valeur('--echantillon');
const jours = valeur('--jours');

const { rapport, nouveaux, failles } = await passageDuBanc({
  sec,
  ...(phrases !== undefined ? { phrases } : {}),
  ...(scenarios !== undefined ? { scenarios } : {}),
  ...(echantillon !== undefined ? { echantillon } : {}),
  ...(jours !== undefined ? { jours } : {}),
  journal: (m) => console.log(m),
});

mkdirSync('scripts/banc-ia/resultats', { recursive: true });
const fichier = `scripts/banc-ia/resultats/passage-${rapport.passage.slice(0, 16).replace(/[:T]/g, '-')}${sec ? '-sec' : ''}.json`;
writeFileSync(fichier, JSON.stringify({ rapport, nouveaux }, null, 1));
console.log(`\n# Passage du ${rapport.passage.slice(0, 16).replace('T', ' à ')}${sec ? ' (essai, rien en base)' : ''}`);
console.log(`Vraies phrases : ${rapport.reels.recoltees} récoltées, ${rapport.reels.dans_examen} dans l'examen, ${rapport.reels.a_valider} à trancher`);
console.log(`Phrases écrites : ${rapport.synthetiques.ecrites}, ${rapport.synthetiques.gardees} gardées, ${rapport.synthetiques.ecartees} écartées`);
console.log(`Examen : ${rapport.examen.phrases} phrases, justesse ${rapport.examen.justesse} %, ${rapport.examen.actions_couteuses_a_tort} actions coûteuses à tort`);
console.log(`Nouvelles failles du cerveau : ${failles.length}`);
for (const f of failles.slice(0, 15)) console.log(`   « ${f.texte} » → ${f.cerveau}, attendu ${f.attendu} [${f.scenario}]`);
console.log(`\nDétail : ${fichier}`);
