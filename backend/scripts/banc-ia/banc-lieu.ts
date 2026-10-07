/**
 * Le LIEU de recherche compris par le cerveau (« une friperie vers Yantala »),
 * mesuré, puis situé par services/lieux.ts comme le fait la route /chat.
 *
 * Les pièges comptent autant que les lieux : le trajet d'une course n'est
 * JAMAIS un lieu de recherche (il déplacerait toute la recherche). Le lieu de
 * livraison d'un ACHAT en est un (« livrez-moi des brochettes à Yantala » :
 * les commerces proches de Yantala, décidé le 07/10).
 *
 *   npx tsx --env-file=.env scripts/banc-ia/banc-lieu.ts [passages]
 */
const { comprendre } = await import('../../src/ai/decideur.js');
const { reperer } = await import('../../src/services/lieux.js');
const { normaliserIntention } = await import('../../src/ai/intents.js');

// [phrase, quartier attendu (tel que reperer le décrit, en partie) ou '' si aucun]
const JEU: Array<[phrase: string, attendu: string]> = [
  ['Il y a une friperie vers Yantala ?', 'yantala'],
  ['Une pharmacie à Bobiel', 'bobiel'],
  ['Des brochettes du côté de Talladjé', 'talladje'],
  ['Un supermarché au Plateau', 'plateau'],
  ['Je cherche un restaurant à Kouara Kano', 'kouara kano'],
  ['Une boulangerie vers Lazaret', 'lazaret'],
  ['Où acheter du pain à Harobanda ?', 'harobanda'],
  ['Une boutique de téléphones à Banifandou', 'banifandou'],
  ['Une friperie pas loin', ''],
  ['Je veux une pizza', ''],
  ['Livrez-moi des brochettes à Yantala', 'yantala'],
  ['Envoie un livreur chercher un colis à Bobiel', ''],
  ['Apporte ces clés à mon frère à Talladjé', ''],
  ['Je veux manger chez Garba d’Or', ''],
  ['Une pharmacie de garde', ''],
  ['Du riz parfumé', ''],
];

const passages = Number(process.argv[2] ?? 2);
let justes = 0;
let pannes = 0;
let deplaceATort = 0;
const fautes = new Map<string, string[]>();
async function lire(phrase: string): Promise<string | null> {
  const d = await comprendre(phrase);
  if (!d.intention) return null;
  // Comme la route : seulement pour une recherche.
  const recherche = d.intention === 'recherche' || d.intention === 'boutique' || d.intention === 'envie' || d.commerce;
  if (!d.lieu || !recherche) return '';
  return normaliserIntention(reperer(d.lieu).description ?? `?${d.lieu}`);
}
for (let p = 0; p < passages; p++) {
  for (let i = 0; i < JEU.length; i += 6) {
    const lot = JEU.slice(i, i + 6);
    const lus = await Promise.all(lot.map(([phrase]) => lire(phrase)));
    lot.forEach(([phrase, attendu], k) => {
      const lu = lus[k];
      if (lu === null) { pannes++; return; }
      const juste = attendu === '' ? lu === '' : lu.includes(attendu);
      if (juste) justes++;
      else fautes.set(phrase, [...(fautes.get(phrase) ?? []), lu || 'aucun']);
      if (attendu === '' && lu !== '') deplaceATort++;
    });
  }
}
const total = JEU.length * passages - pannes;
console.log(`Lieu de recherche : ${justes} / ${total} (${Math.round((100 * justes) / total)} %) — recherches déplacées à tort : ${deplaceATort}${pannes ? ` — ${pannes} pannes hors score` : ''}`);
for (const [phrase, lus] of fautes) {
  console.log(`  ✗ « ${phrase} » attendu ${JEU.find(([q]) => q === phrase)![1] || 'aucun'}, lu ${lus.join(', ')}`);
}
