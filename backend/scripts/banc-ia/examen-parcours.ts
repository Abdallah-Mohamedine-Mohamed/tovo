/**
 * L'EXAMEN PAR PARCOURS (02/10) — la référence avant toute refonte.
 *
 *   npx tsx --env-file=.env scripts/banc-ia/examen-parcours.ts
 *
 * Contrairement à examen-reponses.ts, il passe par la VRAIE route POST /chat
 * (app.inject, comme l'application), avec un vrai client de test. Il mesure
 * donc tout ce que vit le client : la recherche préalable de la route, les
 * réponses directes (livreur, colis, pharmacies de garde…), les tuiles.
 *
 * Et il juge par des VÉRIFICATIONS OBJECTIVES, sans IA : aucune course créée
 * sans un toucher du client (lu en base), aucun produit sans rapport, la
 * bonne agence, la bonne carte. Les règles viennent de docs/PARCOURS-
 * CLIENTS.md et des décisions du fondateur (D1 : une course part sur un
 * toucher, jamais sur une phrase ; D6 : on ne promet plus que le livreur
 * avance l'achat — il appelle le client).
 *
 * Chaque scénario a son propre client de test, supprimé à la fin (commandes
 * comprises). Coût : les appels du cerveau, du rédacteur et parfois de
 * l'assistant (~0,05 $), aucun juge.
 */
import { randomUUID } from 'node:crypto';
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import type { FastifyInstance } from 'fastify';
import type { TestUser } from '../../tests/rls/harness.js';

// AUCUN livreur réel ne doit être prévenu : une course créée par erreur
// (c'est précisément ce qu'on mesure) reste en base pour être comptée, mais
// sa recherche de livreur ne part pas. Sans Redis, les files s'exécutent sur
// place ; on remplace alors celle du dispatch par une tâche vide.
process.env.REDIS_URL = '';
process.env.LOG_LEVEL = 'error';
const { buildApp } = await import('../../src/app.js');
const { admin, cleanup, createUser } = await import('../../tests/rls/harness.js');
const { registerProcessor } = await import('../../src/services/queue.js');
const { DISPATCH_QUEUE } = await import('../../src/services/dispatch.js');

const POSITION = { lat: 13.52, lng: 2.11 };
const DOSSIER = 'scripts/banc-ia/resultats';

type Composant = { type: string; data: Record<string, unknown> };
interface Reponse { statut: number; texte: string; composants: Composant[] }
interface Contexte { client: TestUser; reponses: Reponse[] }
type Verification = [libelle: string, test: (r: Reponse, c: Contexte) => boolean | Promise<boolean>];
interface Etape {
  /** Ce que le client écrit… */
  dire?: string;
  /** … ou ce qu'il touche, d'après la réponse précédente (null : rien à toucher → échec). */
  toucher?: (precedente: Reponse) => { action: string; payload: Record<string, unknown> } | null;
  verifier: Verification[];
}
interface Scenario { id: string; parcours: 'A' | 'B' | 'C' | 'G'; titre: string; etapes: Etape[] }

// --- Lecture de ce que voit le client --------------------------------------

const types = (r: Reponse) => r.composants.map((c) => c.type);
const elements = (r: Reponse): Array<Record<string, unknown>> => r.composants.flatMap((c) =>
  Array.isArray(c.data.items) ? (c.data.items as Array<Record<string, unknown>>).map((i) => ({ ...i, _carte: c.type })) : []);
const produits = (r: Reponse) => elements(r).filter((i) => i._carte === 'product_carousel' || i._carte === 'product_list');
const commerces = (r: Reponse) => elements(r).filter((i) => i._carte === 'commerces_hors_tovo');
const nom = (i: Record<string, unknown>) => String(i.name ?? i.nom ?? i.label ?? '');
const sansAccents = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
/**
 * Au moins `part` des produits affichés correspondent au motif. Un produit
 * trouvé par le nom d'une de ses OPTIONS (« Tacos bowl », option merguez) est
 * marqué `requires_options` par la recherche : il compte aussi.
 */
const produitsSurtout = (motif: RegExp, part = 0.6) => (r: Reponse) => {
  const p = produits(r);
  return p.length > 0 && p.filter((i) => motif.test(sansAccents(nom(i))) || i.requires_options === true).length / p.length >= part;
};
const aucunProduit = (motif: RegExp) => (r: Reponse) => !produits(r).some((i) => motif.test(sansAccents(nom(i))));
const aLaCarte = (type: string) => (r: Reponse) => types(r).includes(type);
const pasLaCarte = (type: string) => (r: Reponse) => !types(r).includes(type);

// --- Lecture en base ---------------------------------------------------------

async function commandes(client: TestUser): Promise<number> {
  const { count } = await admin.from('orders').select('id', { count: 'exact', head: true }).eq('user_id', client.id);
  return count ?? 0;
}
const aucuneCommande: Verification = ['aucune commande créée sans toucher', async (_r, c) => (await commandes(c.client)) === 0];

/** Un produit à options n'est jamais dans le panier sans ses choix. */
const panierSansOptionsOubliees: Verification = ['aucun produit à options ajouté sans ses choix', async (_r, c) => {
  const { data: panier } = await admin.from('carts').select('id').eq('user_id', c.client.id);
  const ids = (panier ?? []).map((p) => p.id as string);
  if (ids.length === 0) return true;
  const { data: articles } = await admin.from('cart_items').select('product_id, selections').in('cart_id', ids);
  for (const a of articles ?? []) {
    const choix = Array.isArray(a.selections) ? a.selections.length : 0;
    if (choix > 0) continue;
    const { count } = await admin.from('product_options').select('id', { count: 'exact', head: true }).eq('product_id', a.product_id);
    if ((count ?? 0) > 0) return false;
  }
  return true;
}];

// D6 : Tovo ne promet plus que le livreur avance l'achat ; il appelle le client.
const pasDAvancePromise: Verification = ['ne promet pas que le livreur avance l’achat', (r) => !/\bavance|rembours/i.test(r.texte)];

// --- Les scénarios -----------------------------------------------------------

const SCENARIOS: Scenario[] = [
  // A — Trouver et commander un repas, un produit.
  { id: 'A1', parcours: 'A', titre: 'agence nommée', etapes: [{ dire: 'Je veux un tacos chez Otakoss centre aéré', verifier: [
    ['jamais les deux agences à choisir', (r) => elements(r).length + r.composants.length > 0
      && !(r.composants.filter((c) => c.type === 'merchant_card').length > 1)],
    ['seulement l’agence Centre Aéré', (r) => {
      const noms = [...produits(r).map((i) => String(i.merchant_name ?? '')), ...r.composants.filter((c) => c.type === 'merchant_card').map((c) => String(c.data.name ?? ''))];
      return noms.length > 0 && noms.every((n) => /centre/i.test(sansAccents(n)));
    }],
  ] }] },
  { id: 'A2', parcours: 'A', titre: 'produit simple', etapes: [{ dire: 'pizza', verifier: [
    // « P. Charcuterie » : les cartes abrègent parfois « Pizza ».
    ['des pizzas', produitsSurtout(/pizza|^p\. /)],
  ] }] },
  { id: 'A3', parcours: 'A', titre: 'huile de cuisine', etapes: [{ dire: 'Il me faut un litre d’huile', verifier: [
    ['une réponse affichée', (r) => r.composants.length > 0],
    ['aucune huile pour le corps', aucunProduit(/argan|corps|cheveu|massage|visage|essentielle|ricin|coco.*(peau|cheveu)/)],
  ] }] },
  { id: 'A4', parcours: 'A', titre: 'lait à boire', etapes: [{ dire: 'deux litres de lait', verifier: [
    ['une réponse affichée', (r) => r.composants.length > 0],
    ['aucun cosmétique au lait', aucunProduit(/savon|creme|lotion|corps|gel|douche|soin|beurre de karite/)],
  ] }] },
  { id: 'A5', parcours: 'A', titre: 'le sens, pas les mots', etapes: [{ dire: 'Je voudrais bien manger des merguez', verifier: [
    ['des plats aux merguez', produitsSurtout(/merguez/, 0.5)],
    ['ne reprend pas « bien manger »', (r) => !/bien manger/i.test(r.texte)],
  ] }] },
  { id: 'A6', parcours: 'A', titre: 'électronique', etapes: [{ dire: 'chargeur iphone', verifier: [
    ['jamais de nourriture', aucunProduit(/poulet|pizza|riz|tacos|jus|boisson|burger|viande|poisson/)],
  ] }] },
  { id: 'A7', parcours: 'A', titre: 'envie générale', etapes: [{ dire: 'Je veux manger', verifier: [
    ['des restaurants affichés', (r) => r.composants.length > 0],
    ['pas une recherche du mot « manger »', (r) => !/manger/i.test(produits(r).map(nom).join(' '))],
  ] }] },
  { id: 'A8', parcours: 'A', titre: 'options protégées', etapes: [
    { dire: 'Je veux un tacos chez Otakoss centre aéré', verifier: [] },
    { dire: 'ajoute le premier au panier', verifier: [panierSansOptionsOubliees, aucuneCommande] },
  ] },

  // B — Faire venir un livreur. D1 : une course part sur un toucher, jamais sur une phrase.
  { id: 'B1', parcours: 'B', titre: '« je veux un livreur » (D1)', etapes: [{ dire: 'Je veux un livreur', verifier: [
    aucuneCommande,
    ['la carte de course, prix visible', aLaCarte('courier_form')],
  ] }] },
  { id: 'B2', parcours: 'B', titre: 'piège : colis de riz', etapes: [{ dire: 'un colis de riz de 25 kg', verifier: [
    aucuneCommande, ['pas de carte de course', pasLaCarte('courier_form')],
  ] }] },
  { id: 'B3', parcours: 'B', titre: 'piège : devenir livreur', etapes: [{ dire: 'Je veux devenir livreur', verifier: [
    aucuneCommande, ['pas de carte de course', pasLaCarte('courier_form')],
  ] }] },
  { id: 'B4', parcours: 'B', titre: 'piège : un livre', etapes: [{ dire: 'Je cherche un livre de cuisine', verifier: [
    aucuneCommande, ['pas de carte de course', pasLaCarte('courier_form')],
  ] }] },
  { id: 'B5', parcours: 'B', titre: 'piège : un taxi', etapes: [{ dire: 'Appelle-moi un taxi pour la gare', verifier: [
    aucuneCommande, ['pas de carte de course', pasLaCarte('courier_form')],
  ] }] },
  { id: 'B6', parcours: 'B', titre: 'colis à déposer', etapes: [{ dire: 'J’ai un sac à faire déposer à Gamkalley', verifier: [
    aucuneCommande, ['la carte de course', aLaCarte('courier_form')],
  ] }] },
  { id: 'B7', parcours: 'B', titre: 'colis à récupérer', etapes: [{ dire: 'Va chercher un colis chez Moussa au 90 12 34 56', verifier: [
    aucuneCommande, ['la carte de course', aLaCarte('courier_form')],
  ] }] },

  // C — Ce que Tovo n'a pas. D6 : le livreur appelle le client, pas d'avance promise.
  { id: 'C1', parcours: 'C', titre: 'boutique inconnue, puis « oui »', etapes: [
    { dire: 'Je veux commander de la viande chez Tchos', verifier: [
      aucuneCommande, pasDAvancePromise,
      ['propose un livreur', (r) => elements(r).some((i) => /hors-tovo-oui:/.test(String(i.value ?? (i.livreur as { value?: string } | undefined)?.value ?? '')))],
    ] },
    { toucher: (r) => {
      const oui = elements(r).find((i) => /hors-tovo-oui:/.test(String(i.value ?? (i.livreur as { value?: string } | undefined)?.value ?? '')));
      if (!oui) return null;
      const value = String(oui.value ?? (oui.livreur as { value: string }).value);
      return { action: 'quick_reply', payload: { label: 'Oui, envoyez un livreur', value } };
    }, verifier: [aucuneCommande, pasDAvancePromise, ['la carte de course', aLaCarte('courier_form')]] },
  ] },
  { id: 'C2', parcours: 'C', titre: 'commerce de l’annuaire', etapes: [{ dire: 'Haddad Khalil', verifier: [
    ['la carte du commerce', (r) => commerces(r).some((i) => /haddad/i.test(nom(i)))], pasDAvancePromise,
  ] }] },
  { id: 'C3', parcours: 'C', titre: 'produit absent', etapes: [{ dire: 'Je cherche de la pommade Nivea', verifier: [
    ['des commerces ou de la pommade', (r) => commerces(r).length > 0 || produitsSurtout(/pommade|nivea/, 0.5)(r)],
    ['jamais des pommes', aucunProduit(/\bpommes?\b/)], pasDAvancePromise,
  ] }] },
  { id: 'C4', parcours: 'C', titre: 'médicament', etapes: [{ dire: 'paracétamol', verifier: [
    ['des pharmacies', (r) => commerces(r).length > 0 && commerces(r).every((i) => /pharmac/i.test(String(i.type ?? i.nom)))],
    ['pas de produits de parapharmacie à la place', (r) => produits(r).length === 0],
  ] }] },
  { id: 'C5', parcours: 'C', titre: 'gâteau d’anniversaire', etapes: [{ dire: 'Je veux un gâteau d’anniversaire', verifier: [
    ['des gâteaux, ou des boulangeries / pâtisseries', (r) => produitsSurtout(/gateau|cake|patisserie/, 0.5)(r)
      || (commerces(r).length > 0 && commerces(r).every((i) => /boulang|patiss/i.test(sansAccents(String(i.type ?? '')))))],
  ] }] },
  { id: 'C6', parcours: 'C', titre: 'pharmacies de garde', etapes: [{ dire: 'Pharmacies de garde près de moi', verifier: [
    ['des pharmacies', (r) => commerces(r).length > 0],
  ] }] },

  // N — Phrases NOUVELLES (écrites après les corrections du 02/10, avant de les
  // passer) : elles vérifient que les corrections tiennent sur des phrases
  // jamais vues, pas seulement sur celles qui ont servi à corriger.
  { id: 'N1', parcours: 'B', titre: 'coursier pour des clés', etapes: [{ dire: 'Il me faut un coursier pour amener des clés à mon frère à Yantala', verifier: [
    aucuneCommande, ['la carte de course', aLaCarte('courier_form')],
  ] }] },
  { id: 'N2', parcours: 'B', titre: 'piège : paquet de biscuits', etapes: [{ dire: 'un paquet de biscuits', verifier: [
    aucuneCommande, ['pas de carte de course', pasLaCarte('courier_form')],
  ] }] },
  { id: 'N3', parcours: 'B', titre: 'une moto, tout court', etapes: [{ dire: 'envoie-moi une moto', verifier: [
    aucuneCommande,
  ] }] },
  { id: 'N4', parcours: 'B', titre: 'piège : sac de riz livré', etapes: [{ dire: 'Livre-moi un sac de riz de 50 kg', verifier: [
    aucuneCommande, ['pas de carte de course', pasLaCarte('courier_form')],
  ] }] },
  { id: 'N5', parcours: 'A', titre: 'boisson', etapes: [{ dire: 'du coca bien frais', verifier: [
    ['du coca', produitsSurtout(/coca/, 0.5)],
  ] }] },
  { id: 'N6', parcours: 'C', titre: 'médicament en phrase', etapes: [{ dire: 'J’ai besoin de médicaments contre le palu', verifier: [
    ['des pharmacies', (r) => commerces(r).length > 0 && commerces(r).every((i) => /pharmac/i.test(String(i.type ?? i.nom)))],
    pasDAvancePromise,
  ] }] },
  { id: 'N7', parcours: 'C', titre: 'chaussures', etapes: [{ dire: 'des chaussures de sport', verifier: [
    ['jamais de nourriture', aucunProduit(/poulet|pizza|riz|tacos|jus|boisson|burger|viande|poisson/)],
    ['une réponse affichée', (r) => r.composants.length > 0], pasDAvancePromise,
  ] }] },
  { id: 'N8', parcours: 'C', titre: 'boutique inconnue (pain)', etapes: [{ dire: 'Je veux du pain chez Boulangerie Lahiya', verifier: [
    aucuneCommande, pasDAvancePromise,
  ] }] },
  { id: 'N9', parcours: 'G', titre: 'question sur Tovo', etapes: [{ dire: 'C’est combien la livraison ?', verifier: [
    ['aucun produit', (r) => produits(r).length === 0], aucuneCommande,
  ] }] },
  { id: 'N10', parcours: 'B', titre: 'piège : livre', etapes: [{ dire: 'Avez-vous des livres pour enfants ?', verifier: [
    aucuneCommande, ['pas de carte de course', pasLaCarte('courier_form')],
  ] }] },

  // G — Conversation : rien à afficher.
  { id: 'G1', parcours: 'G', titre: 'remarque', etapes: [{ dire: 'Tu es sourd ?', verifier: [
    ['aucun produit', (r) => produits(r).length === 0], ['une phrase', (r) => r.texte.trim().length > 0],
  ] }] },
  { id: 'G2', parcours: 'G', titre: 'remerciement', etapes: [{ dire: 'Le livreur a été très gentil merci', verifier: [
    ['aucune carte', (r) => r.composants.length === 0], aucuneCommande,
  ] }] },
  { id: 'G3', parcours: 'G', titre: 'salutation', etapes: [{ dire: 'Bonjour', verifier: [
    ['aucun produit', (r) => produits(r).length === 0], ['une phrase', (r) => r.texte.trim().length > 0],
  ] }] },
];

// --- Exécution ----------------------------------------------------------------

/**
 * Une erreur serveur (5xx) est retentée UNE fois : depuis ce poste, la
 * connexion à Supabase expire parfois (ConnectTimeoutError, vu le 02/10).
 * Un vrai défaut de Tovo échoue aussi la seconde fois, et reste compté.
 */
async function parler(app: FastifyInstance, client: TestUser, conversationId: string | undefined, corps: Record<string, unknown>): Promise<{ r: Reponse; conversationId: string | undefined }> {
  const premier = await parlerUneFois(app, client, conversationId, corps);
  return premier.r.statut >= 500 ? parlerUneFois(app, client, conversationId, corps) : premier;
}

async function parlerUneFois(app: FastifyInstance, client: TestUser, conversationId: string | undefined, corps: Record<string, unknown>): Promise<{ r: Reponse; conversationId: string | undefined }> {
  const res = await app.inject({
    method: 'POST', url: '/chat',
    headers: { authorization: `Bearer ${client.accessToken}` },
    payload: { client_message_id: randomUUID(), context: POSITION, ...(conversationId ? { conversation_id: conversationId } : {}), ...corps },
  });
  const json = res.statusCode === 200 ? res.json() as { conversation_id?: string; content?: string; components?: Composant[] } : null;
  return {
    r: { statut: res.statusCode, texte: json?.content ?? res.body.slice(0, 200), composants: json?.components ?? [] },
    conversationId: json?.conversation_id ?? conversationId,
  };
}

const resume = (r: Reponse) => `${r.texte.replace(/\s+/g, ' ').slice(0, 160)} || ${r.composants.map((c) => {
  const items = Array.isArray(c.data.items) ? (c.data.items as Array<Record<string, unknown>>) : [];
  return `${c.type}${items.length ? ` [${items.slice(0, 4).map(nom).join(' ; ')}${items.length > 4 ? ' …' : ''}]` : ''}`;
}).join(' | ') || 'aucune carte'}`;

/** Un client de test ; une coupure réseau passagère ne fait pas tout échouer. */
async function nouveauClient(): Promise<TestUser> {
  for (let essai = 1; ; essai++) {
    try { return await createUser('client'); } catch (e) { if (essai >= 3) throw e; await new Promise((ok) => setTimeout(ok, 2000 * essai)); }
  }
}

const app = await buildApp();
await app.ready();
registerProcessor(DISPATCH_QUEUE, async () => undefined);

interface Resultat {
  id: string; parcours: string; titre: string; reussi: boolean; echecs: string[]; vu: string[]; ms: number;
  /** Une panne technique (réseau, base) : ni réussite ni échec de Tovo, hors score. */
  technique?: string | null;
}
const resultats: Resultat[] = [];
const file = [...SCENARIOS];
// Le nettoyage (clients de test et leurs commandes) a lieu même en cas d'erreur.
try {
await Promise.all(Array.from({ length: 4 }, async () => {
  for (let s = file.shift(); s; s = file.shift()) {
    let technique: string | null = null;
    const client = await nouveauClient().catch((e: Error) => { technique = e.message.slice(0, 200); return null; });
    if (!client) {
      resultats.push({ id: s.id, parcours: s.parcours, titre: s.titre, reussi: false, echecs: [], vu: [], ms: 0, technique });
      process.stdout.write('?');
      continue;
    }
    const contexte: Contexte = { client, reponses: [] };
    const echecs: string[] = [];
    const vu: string[] = [];
    let conversationId: string | undefined;
    const debut = Date.now();
    try {
    for (const [n, etape] of s.etapes.entries()) {
      let corps: Record<string, unknown> | null = etape.dire ? { text: etape.dire } : null;
      if (!corps && etape.toucher) {
        const geste = etape.toucher(contexte.reponses.at(-1)!);
        if (geste) corps = { interaction: geste };
      }
      if (!corps) { echecs.push(`étape ${n + 1} : rien à toucher`); break; }
      const { r, conversationId: c } = await parler(app, client, conversationId, corps);
      conversationId = c;
      contexte.reponses.push(r);
      vu.push(`${etape.dire ? `« ${etape.dire} »` : '[toucher]'} → ${r.statut !== 200 ? `HTTP ${r.statut} ` : ''}${resume(r)}`);
      if (r.statut !== 200) { echecs.push(`étape ${n + 1} : HTTP ${r.statut}`); break; }
      for (const [libelle, test] of etape.verifier) {
        if (!(await test(r, contexte))) echecs.push(`étape ${n + 1} : ${libelle}`);
      }
    }
    } catch (e) {
      technique = (e as Error).message.slice(0, 200);
    }
    resultats.push({ id: s.id, parcours: s.parcours, titre: s.titre, reussi: !technique && echecs.length === 0, echecs, vu, ms: Date.now() - debut, technique });
    process.stdout.write(technique ? '?' : echecs.length === 0 ? '✓' : '✗');
  }
}));
} finally {
  await cleanup();
  await app.close();
}
resultats.sort((a, b) => SCENARIOS.findIndex((s) => s.id === a.id) - SCENARIOS.findIndex((s) => s.id === b.id));

// --- Bilan -------------------------------------------------------------------

const jugeables = resultats.filter((r) => !r.technique);
const pannes = resultats.filter((r) => r.technique);
const parParcours = Object.fromEntries(['A', 'B', 'C', 'G'].map((p) => {
  const l = jugeables.filter((r) => r.parcours === p);
  return [p, { reussis: l.filter((r) => r.reussi).length, total: l.length }];
}));
const reussis = jugeables.filter((r) => r.reussi).length;
const bilan = { reussis, total: jugeables.length, pannes: pannes.length, parParcours };
if (pannes.length) {
  console.log(`\n\n${pannes.length} scénario(s) en panne technique, hors score : ${pannes.map((p) => `${p.id} (${p.technique})`).join(' ; ')}`);
  if (pannes.length > 2) console.log('⚠️ Trop de pannes : passage NON VALABLE, à relancer.');
}

const precedents = readdirSync(DOSSIER).filter((f) => f.startsWith('parcours-')).sort();
const precedent = precedents.length
  ? JSON.parse(readFileSync(`${DOSSIER}/${precedents.at(-1)}`, 'utf8')) as { bilan: typeof bilan; resultats: Resultat[] }
  : null;

console.log(`\n\nScénarios réussis : ${reussis} / ${jugeables.length}${precedent ? `   (avant : ${precedent.bilan.reussis} / ${precedent.bilan.total})` : ''}`);
for (const [p, v] of Object.entries(parParcours)) console.log(`  ${p} : ${v.reussis} / ${v.total}`);
if (precedent) {
  const avant = new Map(precedent.resultats.map((r) => [r.id, r.reussi]));
  const gagnes = jugeables.filter((r) => r.reussi && avant.get(r.id) === false).map((r) => r.id);
  const perdus = jugeables.filter((r) => !r.reussi && avant.get(r.id) === true).map((r) => r.id);
  console.log(`Nouvelles réussites : ${gagnes.join(' · ') || 'aucune'}`);
  console.log(`RÉGRESSIONS : ${perdus.join(' · ') || 'aucune'}`);
}
console.log('\nÉchecs :');
for (const r of jugeables.filter((x) => !x.reussi)) {
  console.log(`  ✗ ${r.id} ${r.titre} — ${r.echecs.join(' ; ')}`);
  for (const v of r.vu) console.log(`      ${v}`);
}

mkdirSync(DOSSIER, { recursive: true });
const fichier = `${DOSSIER}/parcours-${new Date().toISOString().slice(0, 16).replace(/[:T]/g, '-')}.json`;
writeFileSync(fichier, JSON.stringify({ bilan, resultats }, null, 1));
console.log(`\nDétail : ${fichier}`);
process.exit(0);
