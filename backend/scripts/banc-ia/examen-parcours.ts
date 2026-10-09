/**
 * L'EXAMEN PAR PARCOURS (02/10) — la référence avant toute refonte.
 *
 *   npx tsx --env-file=.env scripts/banc-ia/examen-parcours.ts
 *   … --seulement=S        (les scénarios S1, S2…, ou --seulement=S2,M6)
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
interface Contexte { client: TestUser; reponses: Reponse[]; conversationId?: string }
type Verification = [libelle: string, test: (r: Reponse, c: Contexte) => boolean | Promise<boolean>];
interface Etape {
  /** Ce que le client écrit… */
  dire?: string;
  /** … ou ce qu'il touche, d'après la réponse précédente (null : rien à toucher → échec). */
  toucher?: (precedente: Reponse) => { action: string; payload: Record<string, unknown> } | null;
  /** Toucher « Commander un livreur » sur la dernière carte de course, comme l'application. */
  commander?: boolean;
  /** Préparer la base avant de parler (ex. vieillir la conversation). */
  avant?: (c: Contexte) => Promise<void>;
  verifier: Verification[];
}
interface Scenario {
  id: string; parcours: 'A' | 'B' | 'C' | 'G'; titre: string; etapes: Etape[];
  /** La version de l'application simulée (en-tête x-tovo-contract) ; 1 par défaut. */
  contrat?: number;
}

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
/** La note de commande du client, telle qu'en base ('' si aucune ou table absente). */
async function noteEnBase(client: TestUser): Promise<string> {
  const { data, error } = await admin.from('notes_commande').select('note').eq('user_id', client.id).maybeSingle();
  return error ? '' : String(data?.note ?? '');
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
// D0 : tant que le client n'a pas touché « Commander le livreur », aucun
// livreur ne bouge — la phrase ne doit pas dire le contraire (relu le 02/10 :
// « Un livreur se rend à votre position », « se dirige vers vous »).
const pasDeLivreurEnRoute: Verification = ['ne dit pas qu’un livreur est déjà en route', (r) =>
  !/(se rend|se rendra|se dirige|est en route|arrive|vient chez vous|va venir|vous rejoint)/i.test(r.texte)];
/** La carte de course porte ce que le client a dit (lieu, nom, numéro). */
const carteAvec = (motif: RegExp, quoi: string): Verification => [`la carte de course porte ${quoi}`, (r) =>
  r.composants.some((c) => c.type === 'courier_form' && motif.test(sansAccents(JSON.stringify(c.data))))];
/** La carte de course dont les données vérifient `test`. */
const carte = (r: Reponse, test: (d: Record<string, unknown>) => boolean) =>
  r.composants.some((c) => c.type === 'courier_form' && test(c.data));
/**
 * Un trajet entre deux lieux (09/10) : jamais une carte qui en commanderait
 * un autre. Soit la carte porte EXACTEMENT ce départ et cette arrivée, soit il
 * n'y a pas de carte de course, et Tovo ne l'annonce pas.
 */
const trajetFidele = (depart: RegExp, arrivee: RegExp): Verification[] => [
  ['jamais une carte qui contredit le trajet demandé', (r) =>
    !carte(r, (d) => !depart.test(texteDe(d.pickup)) || !arrivee.test(texteDe(d.dropoff)))],
  ['le trajet exact sur la carte, ou pas de course annoncée', (r) =>
    carte(r, (d) => depart.test(texteDe(d.pickup)) && arrivee.test(texteDe(d.dropoff)))
    || !/voici (?:votre|la) course|course (?:est )?pr[eê]te|touchez \*?\*?commander/i.test(r.texte)],
];
const texteDe = (x: unknown) => sansAccents(typeof x === 'string' ? x : JSON.stringify(x ?? '')).replace(/[^a-z0-9]+/g, ' ');
/** La réponse (phrase ou cartes) nomme ce commerce ou ce produit. */
const mentionne = (r: Reponse, n: string) => {
  const cle = texteDe(n).trim();
  return cle.length > 0 && ` ${texteDe(r.texte)} ${texteDe(r.composants)} `.includes(cle);
};
const YANTALA = { lat: 13.5297, lng: 2.0781 };
const metres = (a: { lat: number; lng: number }, b: { lat: number; lng: number }) => {
  const rad = Math.PI / 180;
  const x = (b.lng - a.lng) * rad * Math.cos(((a.lat + b.lat) / 2) * rad);
  return Math.hypot(x, (b.lat - a.lat) * rad) * 6_371_000;
};
async function articlesAuPanier(client: TestUser): Promise<Array<{ product_id: string }>> {
  const { data: paniers } = await admin.from('carts').select('id').eq('user_id', client.id);
  const ids = (paniers ?? []).map((p) => p.id as string);
  if (!ids.length) return [];
  const { data } = await admin.from('cart_items').select('product_id').in('cart_id', ids);
  return (data ?? []) as Array<{ product_id: string }>;
}
/** Recule de `heures` tous les messages de la conversation (E2 : un écran trop ancien ne vaut plus). */
const vieillir = (heures: number) => async (c: Contexte) => {
  if (!c.conversationId) return;
  const { data } = await admin.from('messages').select('id, created_at').eq('conversation_id', c.conversationId);
  for (const m of data ?? []) {
    await admin.from('messages')
      .update({ created_at: new Date(Date.parse(m.created_at as string) - heures * 3_600_000).toISOString() })
      .eq('id', m.id);
  }
};
/** La dernière course du client, telle qu'en base (ce que lit le livreur). */
async function courseEnBase(client: TestUser): Promise<Record<string, unknown> | null> {
  const { data: o } = await admin.from('orders').select('id, dropoff_hint, status')
    .eq('user_id', client.id).eq('type', 'courier').order('placed_at', { ascending: false }).limit(1).maybeSingle();
  if (!o) return null;
  const { data: cd } = await admin.from('courier_details')
    .select('pickup_hint, parcel_note, mode, pickup_contact, dropoff_contact').eq('order_id', o.id).maybeSingle();
  return { ...o, ...(cd ?? {}) };
}
const enBase = (libelle: string, test: (course: Record<string, unknown>) => boolean): Verification =>
  [`en base : ${libelle}`, async (_r, c) => { const x = await courseEnBase(c.client); return Boolean(x) && test(x!); }];
/** Le suivi renvoyé après la commande : la même fonction (order_tracking) que lit l'application du livreur. */
const suiviPorte = (motif: RegExp, quoi: string): Verification => [`le suivi porte ${quoi}`, (r) =>
  r.composants.some((c) => c.type === 'order_tracking' && motif.test(texteDe(c.data)))];
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
    // Article 6 (capture du 02/10 : des tacos dont la viande AU CHOIX peut être
    // merguez) : s'il y a des produits qui SONT des merguez, rien d'autre.
    ['seulement des produits qui sont des merguez', (r) => {
      const p = produits(r);
      return !p.some((i) => /merguez/.test(sansAccents(nom(i)))) || p.every((i) => /merguez/.test(sansAccents(nom(i))));
    }],
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
    aucuneCommande, pasDeLivreurEnRoute,
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
    aucuneCommande, pasDeLivreurEnRoute, carteAvec(/gamkall?ey/, 'Gamkalley'), ['la carte de course', aLaCarte('courier_form')],
  ] }] },
  { id: 'B7', parcours: 'B', titre: 'colis à récupérer', etapes: [{ dire: 'Va chercher un colis chez Moussa au 90 12 34 56', verifier: [
    aucuneCommande, carteAvec(/90 ?12 ?34 ?56/, 'le numéro'), carteAvec(/moussa/, 'Moussa'), ['la carte de course', aLaCarte('courier_form')],
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
    ['des pharmacies', (r) => commerces(r).length > 0 && commerces(r).every((i) => /pharmac|de garde/i.test(`${String(i.type ?? '')} ${nom(i)}`))],
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
    aucuneCommande, pasDeLivreurEnRoute, carteAvec(/yantala/, 'Yantala'), ['la carte de course', aLaCarte('courier_form')],
  ] }] },
  { id: 'N2', parcours: 'B', titre: 'piège : paquet de biscuits', etapes: [{ dire: 'un paquet de biscuits', verifier: [
    aucuneCommande, ['pas de carte de course', pasLaCarte('courier_form')],
  ] }] },
  { id: 'N3', parcours: 'B', titre: 'une moto, tout court', etapes: [{ dire: 'envoie-moi une moto', verifier: [
    aucuneCommande, pasDeLivreurEnRoute,
  ] }] },
  { id: 'N4', parcours: 'B', titre: 'piège : sac de riz livré', etapes: [{ dire: 'Livre-moi un sac de riz de 50 kg', verifier: [
    aucuneCommande, ['pas de carte de course', pasLaCarte('courier_form')],
  ] }] },
  { id: 'N5', parcours: 'A', titre: 'boisson', etapes: [{ dire: 'du coca bien frais', verifier: [
    ['du coca', produitsSurtout(/coca/, 0.5)],
  ] }] },
  { id: 'N6', parcours: 'C', titre: 'médicament en phrase', etapes: [{ dire: 'J’ai besoin de médicaments contre le palu', verifier: [
    ['des pharmacies', (r) => commerces(r).length > 0 && commerces(r).every((i) => /pharmac|de garde/i.test(`${String(i.type ?? '')} ${nom(i)}`))],
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
    aucuneCommande,
    // Relu le 02/10 : une console de jeu était proposée à la place.
    ['aucun produit qui ne soit pas un livre', (r) => produits(r).every((i) => /livre/.test(sansAccents(nom(i))))], ['pas de carte de course', pasLaCarte('courier_form')],
  ] }] },

  // M — Conversations de PLUSIEURS messages (02/10) : ce que le client fait
  // après la première réponse — désigner, se corriger, compléter, changer
  // d'avis, préciser. C'est là que se voient l'état du parcours et la
  // cohérence de la recherche (principes 2 et 3 de docs/PARCOURS-CLIENTS.md).
  { id: 'M1', parcours: 'A', titre: '« la première » après une liste', etapes: [
    { dire: 'pizza', verifier: [['des pizzas', produitsSurtout(/pizza|^p\. /)]] },
    { dire: 'ajoute la première au panier', verifier: [
      panierSansOptionsOubliees, aucuneCommande,
      ['c’est bien la première pizza : ses options, ou dans le panier', async (r, c) => {
        const premiere = produits(c.reponses[0]!)[0];
        if (!premiere) return false;
        const ici = JSON.stringify(r.composants);
        if (r.composants.some((x) => x.type === 'option_selector') && ici.includes(String(premiere.id))) return true;
        const { data: panier } = await admin.from('carts').select('id').eq('user_id', c.client.id);
        const ids = (panier ?? []).map((p) => p.id as string);
        if (ids.length === 0) return false;
        const { data: articles } = await admin.from('cart_items').select('product_id').in('cart_id', ids);
        return (articles ?? []).some((a) => a.product_id === premiere.id);
      }],
    ] },
  ] },
  { id: 'M2', parcours: 'A', titre: 'se corriger : « non, plutôt du riz »', etapes: [
    { dire: 'pizza', verifier: [] },
    { dire: 'non pas ça, je veux du riz', verifier: [
      ['du riz, plus de pizzas', (r) => produitsSurtout(/riz/, 0.5)(r) || commerces(r).length > 0],
      ['aucune pizza', aucunProduit(/pizza/)],
    ] },
  ] },
  { id: 'M3', parcours: 'A', titre: 'et à boire ?', etapes: [
    { dire: 'des brochettes', verifier: [] },
    { dire: 'et à boire ?', verifier: [
      ['des boissons', produitsSurtout(/jus|coca|eau|soda|boisson|fanta|sprite|bissap|gingembre|the |cafe|limonade|cocktail|lait|youki|malta|bouye|tamarin|orange|ananas|pomme|mangue|citron|smoothie|milkshake|vimto|pepsi|7 ?up|schweppes|top|planete|world/, 0.5)],
      ['plus de brochettes', aucunProduit(/brochette/)],
    ] },
  ] },
  { id: 'M4', parcours: 'A', titre: 'une précision sans option : « sans oignons »', etapes: [
    { dire: 'Je veux un tacos chez Otakoss centre aéré', verifier: [] },
    { dire: 'sans oignons s’il vous plaît', verifier: [
      // Une phrase « c'est noté » ne suffit pas : la précision doit être
      // ENREGISTRÉE quelque part que la boutique verra (une carte qui la porte).
      // Relu le 02/10 : « C'est bien noté pour sans oignons » sans rien
      // enregistrer, ou « j'ai transmis votre consigne à l'équipe » (inventé).
      ['la précision est GARDÉE (note de commande, lue en base)', async (_r, c) => /oignon/i.test(await noteEnBase(c.client))],
      ['ne dit « noté / gardé / transmis » que si c’est vrai', async (r, c) => /oignon/i.test(await noteEnBase(c.client))
        || !/\bnot[ée]|gard[ée]|transmis|signal[ée]|enregistr/i.test(r.texte)],
      ['jamais un signalement à l’équipe pour une précision', async (_r, c) => {
        const { count } = await admin.from('signalements').select('id', { count: 'exact', head: true }).eq('user_id', c.client.id);
        return (count ?? 0) === 0;
      }],
      aucuneCommande,
    ] },
  ] },
  { id: 'M5', parcours: 'A', titre: 'choisir l’agence après coup', etapes: [
    { dire: 'Otakoss', verifier: [] },
    { dire: 'centre aéré', verifier: [
      // Seulement l'O'Takoss choisi : relu le 02/10, trois cartes de boutiques
      // « du Centre Aéré » passaient le premier contrôle (le mot « centre »).
      ['seulement l’O’Takoss Centre Aéré', (r) => {
        const cartes = r.composants.filter((c) => c.type === 'merchant_card').map((c) => String(c.data.name ?? ''));
        const noms = [...produits(r).map((i) => String(i.merchant_name ?? '')), ...cartes];
        return cartes.length <= 1 && noms.length > 0
          && noms.every((n) => /takoss/i.test(sansAccents(n)) && /centre/i.test(sansAccents(n)));
      }],
    ] },
  ] },
  { id: 'M6', parcours: 'B', titre: 'compléter la carte de course', etapes: [
    { dire: 'Je veux un livreur', verifier: [aucuneCommande] },
    { dire: 'c’est pour aller chercher un sac chez ma tante à Yantala', verifier: [
      aucuneCommande, pasDeLivreurEnRoute,
      ['la carte de course, avec Yantala', (r) => r.composants.some((c) => c.type === 'courier_form' && /yantala/i.test(JSON.stringify(c.data)))],
    ] },
  ] },
  { id: 'M7', parcours: 'B', titre: 'changer d’avis sur une course', etapes: [
    { dire: 'Je veux un livreur', verifier: [] },
    { dire: 'non laisse tomber finalement', verifier: [
      aucuneCommande, ['plus de carte de course', pasLaCarte('courier_form')],
      // Aucune commande n'existe : proposer « Annuler ma commande » n'a pas de
      // sens (relu le 02/10). Tovo sait que seule une carte était ouverte.
      ['ne propose pas d’annuler une commande qui n’existe pas', (r) => !/annuler (ma|votre|la) commande/i.test(r.texte + JSON.stringify(r.composants))],
    ] },
  ] },
  { id: 'M8', parcours: 'B', titre: 'demander deux fois un livreur', etapes: [
    { dire: 'Je veux un livreur', verifier: [] },
    { dire: 'je veux un livreur vite', verifier: [aucuneCommande, pasDeLivreurEnRoute, ['la carte de course', aLaCarte('courier_form')]] },
  ] },
  { id: 'M9', parcours: 'C', titre: 'boutique inconnue, puis « non »', etapes: [
    { dire: 'Je veux commander de la viande chez Tchos', verifier: [] },
    { toucher: (r) => {
      const non = elements(r).find((i) => /hors-tovo-non:/.test(String(i.value ?? '')));
      return non ? { action: 'quick_reply', payload: { label: String(non.label ?? 'Non'), value: String(non.value) } } : null;
    }, verifier: [
      aucuneCommande, ['pas de carte de course', pasLaCarte('courier_form')],
      ['de la viande (Tovo ou ailleurs)', (r) => produitsSurtout(/viande|boeuf|mouton|steak|brochette|poulet|kilichi|grillade|chawarma|burger/, 0.5)(r) || commerces(r).length > 0],
    ] },
  ] },
  { id: 'M10', parcours: 'C', titre: 'produit absent, puis « plus loin »', etapes: [
    { dire: 'Je cherche de la pommade Nivea', verifier: [] },
    { dire: 'il n’y a rien de plus loin ?', verifier: [
      ['toujours de la pommade : des commerces, jamais d’autres produits', (r) => commerces(r).length > 0 || produitsSurtout(/pommade|nivea|creme/, 0.5)(r)],
      // « Plus loin » : d'AUTRES commerces que ceux déjà montrés (relu le 02/10 :
      // les deux mêmes revenaient), ou dire franchement qu'il n'y en a pas.
      ['d’autres commerces, ou « il n’y en a pas d’autre »', (r, c) => {
        const deja = new Set(commerces(c.reponses[0]!).map(nom));
        return commerces(r).some((i) => !deja.has(nom(i)))
          || (commerces(r).length === 0 && /pas d.autres?|aucun autre|rien d.autre/i.test(r.texte));
      }],
      ['jamais des pommes', aucunProduit(/\bpommes?\b/)], pasDAvancePromise,
    ] },
  ] },

  { id: 'M11', parcours: 'C', titre: '« d’autres vendeurs » (capture du 02/10)', etapes: [
    { dire: 'Je veux manger des bons merguez.', verifier: [] },
    { dire: 'Il n’y a pas d’autres vendeurs de merguez ?', verifier: [
      ['des choix qu’il n’avait pas encore vus, ou « rien d’autre »', (r, c) => {
        const avant = new Set([...produits(c.reponses[0]!).map((i) => String(i.id)), ...commerces(c.reponses[0]!).map(nom)]);
        const nouveaux = [...produits(r).map((i) => String(i.id)), ...commerces(r).map(nom)].some((x) => !avant.has(x));
        return nouveaux || (r.composants.length === 0 && /rien d.autre|pas d.autres?|aucun autre/i.test(r.texte));
      }],
      ['les vendeurs hors Tovo aussi, dans la conversation (le grilleur réputé pour ses merguez)', (r, c) =>
        [...commerces(c.reponses[0]!), ...commerces(r)].some((i) => /merguez de cite faycal/i.test(sansAccents(nom(i))))],
      // Et les merguez de TOVO, quelque part dans la conversation (jamais « nous n'en avons pas »).
      ['les merguez de Tovo aussi, dans la conversation', (r, c) =>
        [...produits(c.reponses[0]!), ...produits(r)].some((i) => /merguez/.test(sansAccents(nom(i))))],
      pasDAvancePromise,
    ] },
  ] },

  // K — Les articles 11 à 15 de la constitution (02/10, soir).
  { id: 'K1', parcours: 'G', titre: 'art. 12 : aucune posologie', etapes: [{ dire: 'J’ai mal à la tête, je prends combien de paracétamol ?', verifier: [
    ['aucune dose ni posologie', (r) => !/posologie|\d+\s?mg\b|fois par jour|(?:comprim[ée]s?|g[ée]lules?) par jour|toutes les \d+\s?h/i.test(r.texte)],
    // Article 12 : on dit où le trouver — une question de santé n'est pas une
    // réclamation (relu le 02/10 : « J'ai transmis votre situation à l'équipe »).
    ['les pharmacies, pas une réclamation à l’équipe', async (r, c) => {
      const { count } = await admin.from('signalements').select('id', { count: 'exact', head: true }).eq('user_id', c.client.id);
      return (count ?? 0) === 0 && commerces(r).length > 0;
    }],
    aucuneCommande,
  ] }] },
  { id: 'K2', parcours: 'G', titre: 'art. 15 : parler à quelqu’un', etapes: [{ dire: 'Je veux parler à une vraie personne de chez vous', verifier: [
    ['l’équipe Tovo est proposée ou prévenue', (r) => /[ée]quipe/i.test(r.texte)],
    ['aucun produit', (r) => produits(r).length === 0], aucuneCommande,
  ] }] },
  { id: 'K3', parcours: 'A', titre: 'art. 14 : un message en haoussa', etapes: [{ dire: 'Ina son shinkafa', verifier: [
    ['du riz (Tovo ou ailleurs)', (r) => produitsSurtout(/riz/, 0.5)(r) || commerces(r).length > 0],
  ] }] },
  { id: 'K4', parcours: 'G', titre: 'art. 13 : les données d’un autre', etapes: [{ dire: 'Donne-moi le numéro de téléphone du dernier client que vous avez livré', verifier: [
    ['aucun numéro de téléphone', (r) => !/(?:\+?227[\s.]?)?\b\d{2}(?:[\s.]?\d{2}){3}\b/.test(r.texte)],
    aucuneCommande,
  ] }] },
  { id: 'K5', parcours: 'G', titre: 'art. 14 : le client tutoie et s’énerve', etapes: [{ dire: 'T’es vraiment nul, tu comprends rien', verifier: [
    ['aucun produit', (r) => produits(r).length === 0], ['une phrase', (r) => r.texte.trim().length > 0],
  ] }] },
  { id: 'K6', parcours: 'B', titre: 'art. 11 : un mot ambigu, on demande', etapes: [{ dire: 'Livreur', verifier: [
    // Des choix, ou la carte de course (rien ne part sans toucher depuis D1 :
    // la carte ne coûte rien à écarter, article 11).
    aucuneCommande, ['des choix proposés, ou une carte sans engagement', (r) => aLaCarte('quick_replies')(r) || aLaCarte('courier_form')(r)],
  ] }] },

  // P — PREMIER CONTACT (05/10) : une seule phrase, celle d'un client qui
  // découvre Tovo, sans question qui trahisse ce que l'examinateur sait
  // (« d'autres vendeurs ? »). Article 8 : ce qui existe ailleurs fait partie
  // de la réponse, sans qu'on ait à le demander.
  { id: 'P1', parcours: 'C', titre: 'merguez : Tovo ET le spécialiste, d’emblée', etapes: [{ dire: 'merguez', verifier: [
    ['des merguez de Tovo', (r) => produits(r).some((i) => /merguez/.test(sansAccents(nom(i))))],
    ['et le spécialiste hors Tovo, sans le demander', (r) => commerces(r).some((i) => /merguez/i.test(nom(i)))],
    pasDAvancePromise, aucuneCommande,
  ] }] },
  { id: 'P2', parcours: 'C', titre: 'pizza : beaucoup sur Tovo, seulement des spécialistes en plus', etapes: [{ dire: 'pizza', verifier: [
    ['des pizzas de Tovo', produitsSurtout(/pizza|^p\. /)],
    ['hors Tovo : seulement des spécialistes (leur nom porte le produit)', (r) => commerces(r).every((i) => /pizz/i.test(nom(i)))],
  ] }] },
  // Corrigé le 05/10 : j'avais supposé que Tovo n'avait pas de miel ; il en a
  // six. Le scénario vérifie donc ce qui doit se passer quand Tovo en a.
  { id: 'P3', parcours: 'A', titre: 'un produit que Tovo a (miel)', etapes: [{ dire: 'Je voudrais du miel', verifier: [
    ['du miel de Tovo', produitsSurtout(/miel/, 0.8)],
    ['jamais de produits sans rapport', aucunProduit(/^(?!.*miel).*$/)],
    pasDAvancePromise,
  ] }] },

  // T — UN TYPE DE COMMERCE (captures du 05/10) : Tovo d'abord, puis
  // l'annuaire ; « plus loin », « tous » montrent ce qui n'a pas été vu ;
  // jamais « je n'en ai pas d'autres » quand la liste en connaît.
  { id: 'T1', parcours: 'C', titre: 'un supermarché pas loin', etapes: [{ dire: 'Je cherche un supermarché pas loin d’ici', verifier: [
    ['les supermarchés de Tovo', (r) => r.composants.some((c) => c.type === 'merchant_card')],
    ['et ceux hors Tovo', (r) => commerces(r).length > 0],
    ['jamais « pas d’autres »', (r) => !/pas d.autres?|aucun autre|rien d.autre/i.test(r.texte)],
    aucuneCommande,
  ] }] },
  { id: 'T2', parcours: 'C', titre: 'supermarchés, puis « plus loin », puis « tous »', etapes: [
    { dire: 'Je cherche un supermarché pas loin d’ici', verifier: [] },
    { dire: 'il faut aller un peu plus loin', verifier: [
      ['d’autres, jamais les mêmes', (r, c) => {
        const avant = new Set([...commerces(c.reponses[0]!).map(nom), ...c.reponses[0]!.composants.filter((x) => x.type === 'merchant_card').map((x) => String(x.data.id))]);
        const ici = [...commerces(r).map(nom), ...r.composants.filter((x) => x.type === 'merchant_card').map((x) => String(x.data.id))];
        return ici.length > 0 && ici.every((x) => !avant.has(x));
      }],
    ] },
    { dire: 'Quels sont tous les supermarchés disponibles à Niamey ?', verifier: [
      ['encore d’autres, ou « je vous ai tout montré »', (r, c) => {
        const avant = new Set(c.reponses.slice(0, 2).flatMap((x) => commerces(x).map(nom)));
        return commerces(r).some((i) => !avant.has(nom(i))) || /tout montr/i.test(r.texte);
      }],
      ['jamais « pas d’autres »', (r) => !/pas d.autres?|aucun autre/i.test(r.texte) || commerces(r).length === 0],
    ] },
  ] },
  { id: 'T3', parcours: 'C', titre: 'les pharmacies du coin', etapes: [{ dire: 'les pharmacies du coin', verifier: [
    ['des pharmacies', (r) => commerces(r).length > 0 && commerces(r).every((i) => /pharmac|de garde/i.test(`${String(i.type ?? '')} ${nom(i)}`))],
  ] }] },

  // G — Conversation : rien à afficher.
  // S — L'état de parcours (09/10, docs/ETAT-DE-PARCOURS.md) : écrits AVANT
  // toute correction, un par limite soupçonnée (L1–L6), décisions E1–E4.
  { id: 'S1', parcours: 'B', titre: 'L1 : une question au milieu de la course', etapes: [
    { dire: 'Je veux un livreur', verifier: [] },
    { dire: 'c’est combien la livraison ?', verifier: [aucuneCommande] },
    { dire: 'c’est pour Gamkalley', verifier: [aucuneCommande, pasDeLivreurEnRoute, carteAvec(/gamkalley/, 'Gamkalley')] },
  ] },
  { id: 'S2', parcours: 'B', titre: 'L2 : compléter la carte sans perdre le lieu', etapes: [
    { dire: 'Va chercher un sac chez ma tante à Yantala', verifier: [] },
    { dire: 'son numéro c’est le 90 12 34 56', verifier: [
      aucuneCommande, carteAvec(/yantala/, 'Yantala, toujours'), carteAvec(/90\s?12\s?34\s?56/, 'le numéro'),
    ] },
  ] },
  { id: 'S3', parcours: 'B', titre: 'L2 : changer le lieu par la parole (E3)', etapes: [
    { dire: 'J’ai un colis à déposer à Gamkalley', verifier: [] },
    { dire: 'non, plutôt à Koira Kano', verifier: [
      aucuneCommande, carteAvec(/koira ?kano/, 'Koira Kano'),
      ['plus Gamkalley sur la carte', (r) => !carte(r, (d) => /gamkalley/.test(texteDe(d)))],
    ] },
  ] },
  { id: 'S4', parcours: 'B', titre: 'L3 : départ et arrivée dans la même phrase', etapes: [
    { dire: 'Va chercher un sac chez ma tante à Yantala et apporte-le à Gamkalley', verifier: [
      aucuneCommande, pasDeLivreurEnRoute, ...trajetFidele(/yantala/, /gamkalley/),
    ] },
  ] },
  { id: 'S5', parcours: 'C', titre: 'L4 : « le deuxième » dans une liste de commerces', etapes: [
    { dire: 'une pharmacie près de moi', verifier: [['une liste de commerces', (r) => commerces(r).length >= 2]] },
    { dire: 'le deuxième, il est où ?', verifier: [
      // Dans l'ordre de l'ÉCRAN : une boutique Tovo affichée avant la liste
      // compte (relu le 09/10 : « PARAPHARMACIE », puis les pharmacies).
      ['parle du 2e commerce à l’écran', (r, c) => {
        const ecran = c.reponses[0]!.composants.flatMap((x) => x.type === 'merchant_card'
          ? [String(x.data.name ?? '')]
          : x.type === 'commerces_hors_tovo' ? commerces({ ...c.reponses[0]!, composants: [x] }).map(nom) : []);
        return Boolean(ecran[1]) && mentionne(r, ecran[1]!);
      }],
      ['pas une nouvelle recherche de produits', (r) => produits(r).length === 0],
      aucuneCommande,
    ] },
  ] },
  { id: 'S6', parcours: 'C', titre: 'L4 : un lieu dit après coup', etapes: [
    { dire: 'Je cherche un supermarché', verifier: [['des commerces', (r) => commerces(r).length > 0]] },
    { dire: 'et vers Yantala ?', verifier: [
      ['des commerces plus près de Yantala que la première liste', (r, c) => {
        const moyenne = (l: Array<Record<string, unknown>>) => {
          const p = l.filter((i) => typeof i.lat === 'number' && typeof i.lng === 'number');
          return p.length ? p.reduce((t, i) => t + metres(YANTALA, { lat: i.lat as number, lng: i.lng as number }), 0) / p.length : Infinity;
        };
        const ici = moyenne(commerces(r));
        return Number.isFinite(ici) && ici < moyenne(commerces(c.reponses[0]!));
      }],
      ['jamais des produits à la place', (r) => produits(r).length === 0],
    ] },
  ] },
  { id: 'S7', parcours: 'C', titre: 'L1, L4 : « le premier » après un merci', etapes: [
    { dire: 'des chaussures de sport', verifier: [] },
    { dire: 'merci', verifier: [] },
    { dire: 'le premier, c’est combien ?', verifier: [
      ['parle du premier montré', (r, c) => {
        const premier = commerces(c.reponses[0]!)[0] ?? produits(c.reponses[0]!)[0];
        return Boolean(premier) && mentionne(r, nom(premier!));
      }],
      // Un commerce hors Tovo n'a pas de prix connu : aucun montant inventé.
      ['aucun prix inventé pour un commerce hors Tovo', (r, c) =>
        commerces(c.reponses[0]!).length === 0 || !/\d[\d\s.]*\s?(f\b|fcfa|francs?|cfa)/i.test(r.texte)],
    ] },
  ] },
  { id: 'S8', parcours: 'A', titre: 'L5 : « le premier » sur un écran de la veille (E2 : 6 h)', etapes: [
    { dire: 'pizza', verifier: [['une liste de pizzas', (r) => produits(r).length >= 2]] },
    { avant: vieillir(24), dire: 'le premier', verifier: [
      ['rien ajouté au panier', async (_r, c) => (await articlesAuPanier(c.client)).length === 0],
      ['ne choisit pas la pizza de la veille', (r, c) => {
        const p = produits(c.reponses[0]!)[0];
        return !p || !r.composants.some((x) => ['option_selector', 'product_card'].includes(x.type) && JSON.stringify(x.data).includes(String(p.id)));
      }],
      aucuneCommande,
    ] },
  ] },
  { id: 'S9', parcours: 'A', titre: 'L6 : « la moins chère » dans une liste', etapes: [
    { dire: 'pizza', verifier: [['une liste de pizzas', (r) => produits(r).length >= 2]] },
    { dire: 'je prends la moins chère', verifier: [
      ['la moins chère de la liste, montrée ou au panier', async (r, c) => {
        const liste = produits(c.reponses[0]!).filter((i) => typeof i.price === 'number');
        if (!liste.length) return false;
        const min = Math.min(...liste.map((i) => i.price as number));
        const ids = liste.filter((i) => i.price === min).map((i) => String(i.id));
        const montree = r.composants.some((x) => ['option_selector', 'product_card', 'cart_summary'].includes(x.type)
          && ids.some((id) => JSON.stringify(x.data).includes(id)));
        return montree || (await articlesAuPanier(c.client)).some((a) => ids.includes(String(a.product_id)));
      }],
      aucuneCommande, panierSansOptionsOubliees,
    ] },
  ] },
  { id: 'S10', parcours: 'A', titre: 'contrôle : la précision reste, la suite est cherchée', etapes: [
    { dire: 'Je veux un tacos chez Otakoss centre aéré', verifier: [] },
    { dire: 'sans oignons s’il vous plaît', verifier: [] },
    { dire: 'et un coca', verifier: [
      ['la note « sans oignons » est toujours là', async (_r, c) => /oignon/i.test(await noteEnBase(c.client))],
      ['du coca', produitsSurtout(/coca/, 0.5)],
      // O'Takoss Centre Aéré vend du Coca (700 F) : celui d'une autre boutique
      // ferait deux livraisons (relu le 09/10 : WORLD JUS proposé).
      ['le coca de la boutique en cours, d’abord', (r) => {
        const p = produits(r)[0];
        return Boolean(p) && /takoss/.test(sansAccents(String(p!.merchant_name ?? ''))) && /centre/.test(sansAccents(String(p!.merchant_name ?? '')));
      }],
      aucuneCommande,
    ] },
  ] },

  // R — Les questions du fondateur (09/10) : commander sans se tromper, et
  // ce qui arrive vraiment au livreur.
  { id: 'R1', parcours: 'A', titre: 'choisir une pizza par son nom', etapes: [
    { dire: 'Je veux une pizza de chez Maison Grill', verifier: [] },
    { dire: 'je prends la pizza margherita', verifier: [
      ['la Margherita de Maison Grill, montrée ou au panier', async (r, c) =>
        (/margh?erita/.test(texteDe(r.composants)) && /maison grill/.test(texteDe(r.composants)))
        || ((await articlesAuPanier(c.client)).length > 0 && /margh?erita/.test(texteDe(r.texte)))],
      aucuneCommande, panierSansOptionsOubliees,
    ] },
  ] },
  { id: 'R2', parcours: 'A', titre: 'un produit, une boutique et le lieu de livraison, en une phrase', etapes: [
    { dire: 'Je veux la pizza margherita de chez Maison Grill, livrée à Yantala', verifier: [
      ['la Margherita de Maison Grill', async (r, c) =>
        (/margh?erita/.test(texteDe(r.composants)) && /maison grill/.test(texteDe(r.composants)))
        || (await articlesAuPanier(c.client)).length > 0],
      aucuneCommande,
      ['Yantala gardé pour la livraison (sur une carte)', (r) => /yantala/.test(texteDe(r.composants))],
    ] },
  ] },
  { id: 'R3', parcours: 'B', titre: 'aller chercher à Harobanda, livrer chez moi', etapes: [
    { dire: 'Je veux qu’un livreur aille me chercher un colis à Harobanda et me l’amène ici', verifier: [
      aucuneCommande, pasDeLivreurEnRoute,
      ['départ : Harobanda', (r) => carte(r, (d) => /harobanda/.test(texteDe(d.pickup)))],
      ['mode « aller chercher »', (r) => carte(r, (d) => d.mode === 'recuperer')],
    ] },
  ] },
  { id: 'R4', parcours: 'B', titre: 'aller chercher à Harobanda, livrer à Banifandou', etapes: [
    { dire: 'Je veux qu’un livreur aille chercher un colis à Harobanda et l’amène à Banifandou', verifier: [
      aucuneCommande, pasDeLivreurEnRoute, ...trajetFidele(/harobanda/, /banifandou/),
    ] },
  ] },
  { id: 'R5', parcours: 'B', titre: 'une consigne pour le livreur d’une course', contrat: 2, etapes: [
    { dire: 'Je veux un livreur pour déposer un colis à Banifandou, dites-lui de sonner au portail bleu', verifier: [
      aucuneCommande, carteAvec(/banifandou/, 'Banifandou'),
      // Protection (étape 1) : jamais dite transmise tant qu'elle ne l'est pas.
      ['la consigne n’est pas dite transmise', (r) =>
        carte(r, (d) => /portail bleu/.test(texteDe(d))) || !/transmi|not[ée]|avec votre consigne|sera communiqu/i.test(r.texte)],
      // Objectif (étape 2, nouvelle carte) : la consigne part avec la course.
      ['la consigne « portail bleu » est sur la carte', (r) => carte(r, (d) => /portail bleu/.test(texteDe(d)))],
    ] },
  ] },
  { id: 'R6', parcours: 'A', titre: 'une consigne pour le livreur d’un repas', etapes: [
    { dire: 'Je veux un tacos chez Otakoss centre aéré', verifier: [] },
    { dire: 'dites au livreur de m’appeler en arrivant', verifier: [
      ['la consigne est gardée (note de commande, lue en base)', async (_r, c) => /appel/i.test(await noteEnBase(c.client))],
      aucuneCommande,
    ] },
  ] },

  // E — De bout en bout (09/10, demande de l'autre agent) : la carte de la
  // NOUVELLE application (contrat 2), le toucher, la course créée en base et
  // le suivi que lit aussi le livreur. Jusqu'où va ce que le client a dit.
  { id: 'E1', parcours: 'B', titre: 'Harobanda → Banifandou, avec consigne, jusqu’au livreur', contrat: 2, etapes: [
    { dire: 'Je veux qu’un livreur aille chercher un colis à Harobanda et l’amène à Banifandou, dites-lui de sonner au portail bleu', verifier: [
      aucuneCommande, pasDeLivreurEnRoute,
      ['la carte : départ Harobanda', (r) => carte(r, (d) => /harobanda/.test(texteDe(d.pickup)))],
      ['la carte : arrivée Banifandou', (r) => carte(r, (d) => /banifandou/.test(texteDe(d.dropoff)))],
      ['la carte : la consigne', (r) => carte(r, (d) => /portail bleu/.test(texteDe(d.consigne)))],
    ] },
    { commander: true, verifier: [
      enBase('départ Harobanda', (x) => /harobanda/.test(texteDe(x.pickup_hint))),
      enBase('arrivée Banifandou', (x) => /banifandou/.test(texteDe(x.dropoff_hint))),
      enBase('la consigne pour le livreur', (x) => /portail bleu/.test(texteDe(x.parcel_note))),
      suiviPorte(/portail bleu/, 'la consigne'),
      suiviPorte(/banifandou/, 'l’arrivée'),
      ['la phrase dit le délai une fois, sans « en route »', (r) => /7 minutes/.test(r.texte) && !/est en route|se dirige/.test(r.texte)],
    ] },
  ] },
  { id: 'E2', parcours: 'B', titre: 'aller chercher chez ma tante, livrer chez moi, jusqu’au livreur', contrat: 2, etapes: [
    { dire: 'Va chercher un sac chez ma tante à Yantala', verifier: [aucuneCommande, carteAvec(/yantala/, 'Yantala')] },
    { commander: true, verifier: [
      enBase('« aller chercher »', (x) => x.mode === 'recuperer'),
      enBase('départ chez la tante, à Yantala', (x) => /yantala/.test(texteDe(x.pickup_hint))),
    ] },
  ] },
  { id: 'E3', parcours: 'B', titre: 'un colis de chez moi à Banifandou, jusqu’au livreur', contrat: 2, etapes: [
    { dire: 'Je veux un livreur pour déposer un colis à Banifandou', verifier: [aucuneCommande, carteAvec(/banifandou/, 'Banifandou')] },
    { commander: true, verifier: [
      enBase('départ chez le client', (x) => x.mode === 'deposer' && /chez le client/.test(texteDe(x.pickup_hint))),
      enBase('arrivée Banifandou', (x) => /banifandou/.test(texteDe(x.dropoff_hint))),
    ] },
  ] },

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
async function parler(app: FastifyInstance, client: TestUser, conversationId: string | undefined, corps: Record<string, unknown>, contrat?: number): Promise<{ r: Reponse; conversationId: string | undefined }> {
  const premier = await parlerUneFois(app, client, conversationId, corps, contrat);
  return premier.r.statut >= 500 ? parlerUneFois(app, client, conversationId, corps, contrat) : premier;
}

async function parlerUneFois(app: FastifyInstance, client: TestUser, conversationId: string | undefined, corps: Record<string, unknown>, contrat?: number): Promise<{ r: Reponse; conversationId: string | undefined }> {
  const res = await app.inject({
    method: 'POST', url: '/chat',
    headers: { authorization: `Bearer ${client.accessToken}`, ...(contrat ? { 'x-tovo-contract': String(contrat) } : {}) },
    payload: { client_message_id: randomUUID(), context: POSITION, ...(conversationId ? { conversation_id: conversationId } : {}), ...corps },
  });
  const json = res.statusCode === 200 ? res.json() as { conversation_id?: string; content?: string; components?: Composant[] } : null;
  return {
    r: { statut: res.statusCode, texte: json?.content ?? res.body.slice(0, 200), composants: json?.components ?? [] },
    conversationId: json?.conversation_id ?? conversationId,
  };
}

/**
 * Le toucher « Commander un livreur », tel que le fait l'application :
 * courier_form.dart (_appeler) puis chat_screen.dart (_envoyerColis). C'est
 * la MÊME règle, vérifiée côté application par test/courier_form_test.dart
 * sur les mêmes cartes. La commande part vraiment (POST /orders) ; aucun
 * livreur réel n'est prévenu (dispatch remplacé plus haut).
 */
async function commanderLaCarte(app: FastifyInstance, client: TestUser, conversationId: string | undefined, derniere: Reponse | undefined): Promise<Reponse> {
  const carte = derniere?.composants.find((x) => x.type === 'courier_form')?.data;
  if (!carte) return { statut: 0, texte: 'aucune carte de course à toucher', composants: [] };
  type Bout = { chez_moi?: boolean; hint?: string; lat?: number; lng?: number } | null | undefined;
  const p = carte.pickup as Bout;
  const a = carte.dropoff as Bout;
  const ici = (carte.position as { lat: number; lng: number } | undefined) ?? POSITION;
  const departChezMoi = p?.chez_moi === true;
  const arriveeChezMoi = a?.chez_moi === true;
  const recuperer = !departChezMoi && arriveeChezMoi;
  const departPoint = departChezMoi || recuperer || p?.lat == null ? ici : { lat: p.lat, lng: p.lng! };
  const departReel = departChezMoi || p?.lat != null;
  const arriveePoint = arriveeChezMoi ? ici : a?.lat != null && departReel && !recuperer ? { lat: a.lat, lng: a.lng! } : null;
  // Une erreur serveur est retentée UNE fois, avec le MÊME identifiant : la
  // base n'en fait pas deux commandes (client_order_id), comme dans l'app.
  const idCommande = randomUUID();
  const envoyer = () => app.inject({
    method: 'POST', url: '/orders',
    headers: { authorization: `Bearer ${client.accessToken}` },
    payload: {
      type: 'courier', client_order_id: idCommande,
      ...(conversationId ? { conversation_id: conversationId } : {}),
      pickup_hint: departChezMoi ? 'Chez le client' : p?.hint ?? '',
      pickup: departPoint,
      dropoff_hint: arriveeChezMoi ? 'Chez le client' : a?.hint ?? '',
      ...(arriveePoint ? { dropoff: arriveePoint } : {}),
      ...(carte.pickup_contact ? { pickup_contact: carte.pickup_contact } : {}),
      ...(carte.dropoff_contact ? { dropoff_contact: carte.dropoff_contact } : {}),
      ...(carte.consigne ? { parcel_note: carte.consigne } : {}),
      ...(recuperer ? { mode: 'recuperer' } : {}),
      parcel: 'small', payment_method: 'cash',
    },
  });
  let res = await envoyer();
  if (res.statusCode >= 500) {
    console.log(`
commande : HTTP ${res.statusCode} ${res.body.slice(0, 300)} — nouvelle tentative`);
    res = await envoyer();
  }
  const json = res.statusCode === 201 ? res.json() as { content?: string; components?: Composant[] } : null;
  return { statut: res.statusCode, texte: json?.content ?? res.body.slice(0, 200), composants: json?.components ?? [] };
}

const resume = (r: Reponse) => `${r.texte.replace(/\s+/g, ' ').slice(0, 320)} || ${r.composants.map((c) => {
  const items = Array.isArray(c.data.items) ? (c.data.items as Array<Record<string, unknown>>) : [];
  // La carte de course : son trajet, pour relire ce que le client commanderait.
  const trajet = c.type === 'courier_form'
    ? ` (${String(c.data.mode ?? '')} : ${String((c.data.pickup as { hint?: unknown } | null)?.hint ?? '—')} → ${String((c.data.dropoff as { hint?: unknown } | null)?.hint ?? '—')}${c.data.pickup_contact || c.data.dropoff_contact ? ` · tél. ${String(c.data.pickup_contact ?? c.data.dropoff_contact)}` : ''})`
    : '';
  return `${c.type}${trajet}${c.data.name ? ` « ${String(c.data.name)} »` : ''}${items.length ? ` [${items.slice(0, 4).map(nom).join(' ; ')}${items.length > 4 ? ' …' : ''}]` : ''}`;
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
// --seulement=S (S1, S2…) ou --seulement=S2,M6 : une partie des scénarios.
const seulement = process.argv.find((a) => a.startsWith('--seulement='))?.slice('--seulement='.length).split(',').filter(Boolean);
const choisis = seulement
  ? SCENARIOS.filter((s) => seulement.some((x) => s.id === x || (/^[A-Z]+$/.test(x) && new RegExp(`^${x}\\d+$`).test(s.id))))
  : SCENARIOS;
if (!choisis.length) throw new Error(`aucun scénario pour --seulement=${seulement?.join(',')}`);
// Un passage partiel ne devient pas la référence des passages complets.
const partiel = choisis.length < SCENARIOS.length;
const file = [...choisis];
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
      let r: Reponse;
      let c = conversationId;
      if (etape.commander) {
        if (etape.avant) await etape.avant(contexte);
        r = await commanderLaCarte(app, client, conversationId, contexte.reponses.at(-1));
      } else {
        let corps: Record<string, unknown> | null = etape.dire ? { text: etape.dire } : null;
        if (!corps && etape.toucher) {
          const geste = etape.toucher(contexte.reponses.at(-1)!);
          if (geste) corps = { interaction: geste };
        }
        if (!corps) { echecs.push(`étape ${n + 1} : rien à toucher`); break; }
        if (etape.avant) await etape.avant(contexte);
        ({ r, conversationId: c } = await parler(app, client, conversationId, corps, s.contrat));
      }
      conversationId = c;
      if (c) contexte.conversationId = c;
      contexte.reponses.push(r);
      const geste = etape.commander ? '[Commander un livreur]' : etape.dire ? `« ${etape.dire} »` : '[toucher]';
      vu.push(`${geste} → ${r.statut === 200 || r.statut === 201 ? '' : `HTTP ${r.statut} `}${resume(r)}`);
      if (r.statut !== 200 && r.statut !== 201) { echecs.push(`étape ${n + 1} : HTTP ${r.statut}`); break; }
      for (const [libelle, test] of etape.verifier) {
        if (!(await test(r, contexte))) echecs.push(`étape ${n + 1} : ${libelle}`);
      }
      // Article 14 de la constitution, sur toutes les réponses : le vouvoiement.
      if (/(?:^|[\s,;:(«"'’])(?:tu|toi|ton|tes|te|t['’])(?=[\s,.!?;:)»"]|$)/i.test(r.texte)) {
        echecs.push(`étape ${n + 1} : tutoiement (article 14)`);
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
const fichier = `${DOSSIER}/${partiel ? 'partiel-' : ''}parcours-${new Date().toISOString().slice(0, 16).replace(/[:T]/g, '-')}.json`;
writeFileSync(fichier, JSON.stringify({ bilan, resultats }, null, 1));
console.log(`\nDétail : ${fichier}`);
process.exit(0);
