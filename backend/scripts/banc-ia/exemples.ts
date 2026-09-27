/**
 * Les exemples tirés au bon moment rendent-ils le cerveau meilleur ?
 *
 *   npm run banc:exemples                    → avec et sans exemples, k = 8
 *   npm run banc:exemples -- --k 5 --seuil 0.85
 *
 * L'examen : le jeu de référence (jeu.ts) + les phrases RÉSERVÉES de la
 * banque (une sur cinq, jamais montrées comme exemples). Les exemples : le
 * reste de la banque. Le même examen passe deux fois, avec et sans exemples.
 */
const { serviceClient } = await import('../../src/services/supabase.js');
const { comprendre, COUTEUSES } = await import('../../src/ai/decideur.js');
const { IndexExemples, estReserve, modeleLocal } = await import('../../src/ai/banc/exemples.js');
const { cleDe, memeSens } = await import('../../src/ai/banc/boucle.js');
const { JEU } = await import('../../src/ai/banc/jeu.js');
type Exemple = import('../../src/ai/banc/exemples.js').Exemple;
type Etiquette = import('../../src/ai/banc/guide.js').Etiquette;

const argv = process.argv.slice(2);
const valeur = (nom: string, defaut: number) => {
  const i = argv.indexOf(nom);
  return i >= 0 ? Number(argv[i + 1]) : defaut;
};
const K = valeur('--k', 8);
const SEUIL = valeur('--seuil', 0.8);

const db = serviceClient();
let lecture = await db.from('banc_cas').select('texte, avant, attendu, reponse, tuiles, cle').eq('statut', 'valide').limit(50_000);
if (lecture.error) lecture = await db.from('banc_cas').select('texte, avant, attendu, cle').eq('statut', 'valide').limit(50_000) as typeof lecture;
const banque: Exemple[] = ((lecture.data ?? []) as Array<Record<string, unknown>>).map((l) => ({
  texte: String(l.texte), avant: (l.avant as string | null) ?? null, attendu: String(l.attendu),
  reponse: (l.reponse as Exemple['reponse'] | undefined) ?? 'intention', tuiles: (l.tuiles as string[] | null) ?? null, cle: String(l.cle),
}));
const montrables = banque.filter((e) => !estReserve(e.cle));
const examen: Exemple[] = [
  ...JEU.map((c) => ({ texte: c.texte, avant: c.avant ?? null, attendu: c.attendu, reponse: 'intention' as const, tuiles: null, cle: cleDe(c.texte, c.avant) })),
  ...banque.filter((e) => estReserve(e.cle)),
];
console.log(`Banque : ${banque.length} phrases validées — ${montrables.length} montrables, examen ${examen.length} (${JEU.length} de référence + ${examen.length - JEU.length} réservées)`);

const empreinter = await modeleLocal();
const index = new IndexExemples();
let t = performance.now();
for (let i = 0; i < montrables.length; i += 64) {
  const lot = montrables.slice(i, i + 64);
  index.ajouter(lot, await empreinter(lot.map((e) => e.texte)));
}
console.log(`Index : ${index.taille} empreintes en ${Math.round(performance.now() - t)} ms`);

t = performance.now();
const vecteurs = await empreinter(examen.map((e) => e.texte));
console.log(`Empreinte d'un message : ${((performance.now() - t) / examen.length).toFixed(1)} ms en moyenne`);
const voisins = vecteurs.map((v, i) => index.proches(v, K, examen[i]!.cle, SEUIL));
console.log(`Exemples par message : ${(voisins.reduce((s, v) => s + v.length, 0) / examen.length).toFixed(1)} en moyenne (k=${K}, seuil ${SEUIL})`);

async function passer(avecExemples: boolean) {
  const resultats: Array<{ predit: string | null; doute: boolean; ms: number }> = new Array(examen.length);
  let suivant = 0;
  await Promise.all(Array.from({ length: 5 }, async () => {
    for (let i = suivant++; i < examen.length; i = suivant++) {
      const c = examen[i]!;
      const d = await comprendre(c.texte, { avant: c.avant, ...(avecExemples ? { exemples: voisins[i]! } : {}) });
      resultats[i] = {
        predit: d.intention && !d.sur && COUTEUSES.has(d.intention) ? 'tuiles' : d.intention,
        doute: !d.sur,
        ms: d.ms,
      };
    }
  }));
  const sansSens = (c: Exemple) => c.reponse !== 'intention';
  const juste = (c: Exemple, r: (typeof resultats)[number]) => sansSens(c)
    ? r.doute
    : r.predit === c.attendu || memeSens(r.predit as Etiquette, c.attendu as Etiquette);
  const aTort = examen.filter((c, i) => {
    const r = resultats[i]!;
    return r.predit && r.predit !== 'tuiles' && COUTEUSES.has(r.predit as never)
      && (sansSens(c) ? !r.doute : !memeSens(r.predit as Etiquette, c.attendu as Etiquette));
  });
  const ms = resultats.map((r) => r.ms).sort((a, b) => a - b);
  return {
    justesse: Math.round((1000 * examen.filter((c, i) => juste(c, resultats[i]!)).length) / examen.length) / 10,
    aTort: aTort.map((c) => c.texte),
    p50: Math.round(ms[Math.floor(ms.length / 2)]!),
    p95: Math.round(ms[Math.floor(ms.length * 0.95)]!),
    rates: examen.flatMap((c, i) => (juste(c, resultats[i]!)
      ? []
      : [`« ${c.texte} » → ${resultats[i]!.predit}, attendu ${c.reponse === 'intention' ? c.attendu : c.reponse}`])).slice(0, 25),
  };
}

const sans = await passer(false);
const avec = await passer(true);
console.log('\n| | Justesse | Actions coûteuses à tort | Médiane | 95 % |');
console.log('|---|---|---|---|---|');
console.log(`| Sans exemples | ${sans.justesse} % | ${sans.aTort.length} | ${sans.p50} ms | ${sans.p95} ms |`);
console.log(`| Avec exemples | ${avec.justesse} % | ${avec.aTort.length} | ${avec.p50} ms | ${avec.p95} ms |`);
console.log('\nActions coûteuses à tort, avec exemples :', avec.aTort.join(' ; ') || 'aucune');
console.log('\nRatées avec exemples :');
for (const r of avec.rates) console.log('  ', r);
