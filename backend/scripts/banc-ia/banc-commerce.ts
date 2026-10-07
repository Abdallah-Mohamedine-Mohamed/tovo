/**
 * Le TYPE de commerce compris par le cerveau (champ « commerce »), mesuré.
 *
 * Moitié des phrases nomment un genre de commerce, avec des mots variés
 * (« prêt-à-porter », « officine », « dibiterie »…) ; l'autre moitié ne
 * demande qu'un produit ou une boutique nommée, et ne doit en donner aucun
 * (« pizza » n'est pas « restaurant », 05/10).
 *
 * Ce qui est mesuré, c'est ce que le client obtient : le genre lu, ou, s'il a
 * aussi nommé un produit (article 6 : le produit d'abord), les commerces du
 * rayon compris (« un magasin de chaussures » → vêtements par le rayon).
 *
 *   npx tsx --env-file=.env scripts/banc-ia/banc-commerce.ts [passages]
 */
const { comprendre } = await import('../../src/ai/decideur.js');
const { typesDuRayon } = await import('../../src/services/catalogue.js');

const JEU: Array<[phrase: string, attendu: string]> = [
  ['Un supermarché pas loin', 'supermarche'],
  ['Les pharmacies du coin', 'pharmacie'],
  ['Boutique de prêt à porter pour femmes', 'vetements'],
  ['Un magasin de chaussures', 'vetements'],
  ['Il y a une friperie vers Yantala ?', 'vetements'],
  ['Où trouver un salon de coiffure ?', 'beaute'],
  ['Une boutique de téléphones près de moi', 'electronique'],
  ['Je cherche une officine ouverte', 'pharmacie'],
  ['Une alimentation dans mon quartier', 'supermarche'],
  ['Les maquis de Niamey', 'restaurant'],
  ['Une dibiterie pas loin', 'grillades'],
  ['Je cherche une quincaillerie', 'quincaillerie'],
  ['Une boulangerie près d’ici', 'boulangerie'],
  ['Un magasin de cosmétiques', 'beaute'],
  ['Où est la boucherie la plus proche ?', 'boucherie'],
  ['Un atelier de couture', 'vetements'],
  ['Une épicerie ouverte', 'supermarche'],
  ['Un marché pour acheter des légumes', 'marche'],
  ['Les restaurants autour de moi', 'restaurant'],
  ['Un magasin d’électroménager', 'electronique'],
  ['Je veux une pizza', 'aucun'],
  ['Je veux manger des bons merguez', 'aucun'],
  ['Je cherche un vendeur de merguez', 'aucun'],
  ['Otakoss', 'aucun'],
  ['Je veux manger chez Garba d’Or', 'aucun'],
  ['Du doliprane', 'aucun'],
  ['Des chaussures pour homme', 'aucun'],
  ['Du pain', 'aucun'],
  ['Un poulet braisé', 'aucun'],
  ['Un téléphone Samsung', 'aucun'],
  ['Du ciment', 'aucun'],
  ['Je veux manger', 'aucun'],
  ['Des tenues pour femmes', 'aucun'],
  ['Un litre d’huile', 'aucun'],
];

const passages = Number(process.argv[2] ?? 2);
let justes = 0;
let pannes = 0;
const fautes = new Map<string, string[]>();
// 6 à la fois : 34 appels simultanés expiraient (06/10), et une panne
// comptait comme « aucun ». Une panne est mise à part, hors score.
async function lire(phrase: string): Promise<string | null> {
  const d = await comprendre(phrase);
  if (!d.intention) return null;
  if (d.commerce) return d.commerce;
  // Un produit : l'annuaire passe par les types du rayon, s'il en faut.
  return d.produit ? `aucun|${typesDuRayon(d.rayon).join('|')}` : 'aucun';
}
for (let p = 0; p < passages; p++) {
  for (let i = 0; i < JEU.length; i += 6) {
    const lot = JEU.slice(i, i + 6);
    const lus = await Promise.all(lot.map(([phrase]) => lire(phrase)));
    lot.forEach(([phrase, attendu], k) => {
      if (lus[k] === null) pannes++;
      else if (lus[k] === attendu || (attendu !== 'aucun' && lus[k]!.split('|').includes(attendu))
        || (attendu === 'aucun' && lus[k]!.startsWith('aucun'))) justes++;
      else fautes.set(phrase, [...(fautes.get(phrase) ?? []), lus[k]!]);
    });
  }
}
const total = JEU.length * passages - pannes;
const genres = JEU.filter(([, a]) => a !== 'aucun').length;
console.log(`Type de commerce : ${justes} / ${total} (${Math.round((100 * justes) / total)} %) — ${genres} phrases à genre, ${JEU.length - genres} sans${pannes ? ` — ${pannes} pannes hors score` : ''}`);
for (const [phrase, lus] of fautes) {
  console.log(`  ✗ « ${phrase} » attendu ${JEU.find(([q]) => q === phrase)![1]}, lu ${lus.join(', ')}`);
}
