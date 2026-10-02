import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { normaliserIntention } from '../ai/intents.js';
import type { Component } from '../components/builders.js';

/**
 * L'annuaire des commerces de Niamey qui ne sont PAS sur Tovo (01/10).
 *
 * Quand Tovo n'a pas un produit, ou qu'un client nomme une boutique absente,
 * Tovo dit où le trouver : les commerces du bon type les plus proches, avec un
 * livreur d'abord et le numéro ensuite. Tovo n'est pas seulement là où l'on
 * commande, c'est aussi celui à qui l'on demande.
 *
 * Données publiques (data/commerces-niamey.json, scripts/commerces/) :
 * Overture Maps (pages Facebook des commerces, CDLA Permissive 2.0) et
 * OpenStreetMap (ODbL). Elles connaissent le TYPE d'un commerce, pas ce qu'il
 * a en rayon : on dit « probablement », jamais « certainement ». Pharmacies
 * incluses depuis le 01/10 (d'abord écartées).
 */

export type TypeCommerce =
  | 'supermarche' | 'marche' | 'boucherie' | 'boulangerie' | 'beaute'
  | 'electronique' | 'vetements' | 'quincaillerie' | 'restaurant' | 'grillades' | 'pharmacie' | 'boutique';

export interface Commerce {
  id: string;
  nom: string;
  nom_normalise: string;
  type: TypeCommerce;
  adresse: string | null;
  quartier: string | null;
  telephone: string | null;
  telephone_appel: string | null;
  lat: number;
  lng: number;
  fiabilite: number;
  /** « tovo » : ajouté à la main (data/commerces-ajouts.json) ; « google » : demandé à Google, jamais conservé. */
  source: 'overture' | 'osm' | 'tovo' | 'google';
  /** Ce qui fait sa réputation (« merguez ») : demandé, il passe en premier. */
  specialites?: string[];
  /** Les autres noms sous lesquels on le connaît (« Vendeur de merguez de la place Toumo »). */
  alias?: string[];
}

const LIBELLES: Record<TypeCommerce, { un: string; des: string; icone: string }> = {
  supermarche: { un: 'Supermarché', des: 'supermarchés', icone: 'supermarche' },
  marche: { un: 'Marché', des: 'marchés', icone: 'marche' },
  boucherie: { un: 'Boucherie', des: 'boucheries', icone: 'viande' },
  boulangerie: { un: 'Boulangerie', des: 'boulangeries', icone: 'pain' },
  beaute: { un: 'Beauté', des: 'boutiques de beauté', icone: 'beaute' },
  electronique: { un: 'Électronique', des: 'magasins d’électronique', icone: 'electronique' },
  vetements: { un: 'Vêtements', des: 'boutiques de vêtements', icone: 'vetements' },
  quincaillerie: { un: 'Quincaillerie', des: 'quincailleries', icone: 'boutiques' },
  restaurant: { un: 'Restaurant', des: 'restaurants', icone: 'restaurants' },
  grillades: { un: 'Grillades', des: 'grilleurs', icone: 'grillades' },
  pharmacie: { un: 'Pharmacie', des: 'pharmacies', icone: 'lieu-pharmacie' },
  boutique: { un: 'Boutique', des: 'boutiques', icone: 'boutiques' },
};

/**
 * Quel produit envoie vers quel commerce (validé le 01/10). L'ordre compte :
 * la beauté avant l'épicerie (« lait corporel », « savon »).
 */
const PRODUITS: Array<[RegExp, TypeCommerce[]]> = [
  [/\b(merguez|brochettes?|dibi|grillades?|kilichi|soya|suya)\b/, ['grillades', 'boucherie']],
  // Les produits de pharmacie (01/10) : Tovo ne sait pas ce qu'elles ont en
  // stock, il montre les plus proches et invite à appeler.
  [/\b(pharmacies?|medicaments?|medocs?|paracetamol|doliprane|efferalgan|ibuprofene|aspirine|antibiotiques?|sirops?|comprimes?|gelules?|antipaludi\w*|coartem|quinine|vitamines?|pansements?|compresses?|betadine|alcool a 90|thermometres?|test de grossesse|preservatifs?|insuline|collyre|seringues?|ordonnance)\b/, ['pharmacie']],
  [/\b(pommades?|cremes?|savons?|parfums?|lotions?|deodorants?|shampo\w*|maquillage|vaseline|lait corporel|karite|rouge a levres|vernis|gel douche)\b/, ['beaute', 'supermarche', 'pharmacie']],
  [/\b(viande|boeuf|mouton|chevre|poulets?|poissons?|saucisses?|steak|abats)\b/, ['boucherie', 'supermarche']],
  [/\b(pains?|baguettes?|croissants?|gateaux?|patisseries?|viennoiseries?)\b/, ['boulangerie', 'supermarche']],
  [/\b(riz|sucre|huile|lait|pates|spaghetti|macaroni|farine|cafe|the|conserves?|biscuits?|couches?|lessive|omo|eau|boissons?|jus|coca|sodas?|yaourts?|fromages?|chocolat|mayonnaise|ketchup|maggi|sel|cereales?|confiture|beurre|oeufs?|semoule|lentilles|haricots?)\b/, ['supermarche', 'marche']],
  [/\b(telephones?|portables?|smartphones?|chargeurs?|ecouteurs?|cables?|batteries?|powerbank|ordinateurs?|laptop|clavier|souris|televisions?|tele|radio|enceintes?|carte memoire|cle usb)\b/, ['electronique']],
  [/\b(vetements?|chemises?|pantalons?|robes?|jupes?|t shirts?|tee shirts?|chaussures?|baskets?|sandales?|pagnes?|boubous?|tissus?|bazin|wax|sacs? a main|ceintures?)\b/, ['vetements']],
  [/\b(outils?|marteau|tournevis|ampoules?|peinture|clous?|cadenas|tuyaux?|robinets?|ciment|serrures?)\b/, ['quincaillerie']],
];

let cache: Commerce[] | null = null;

export function chargerCommerces(chemin = join(process.cwd(), 'data', 'commerces-niamey.json')): Commerce[] {
  if (cache) return cache;
  try {
    cache = (JSON.parse(readFileSync(chemin, 'utf8')) as { commerces: Commerce[] }).commerces;
  } catch {
    cache = [];
  }
  return cache;
}

/** Pour les tests. */
export function installerCommerces(commerces: Commerce[] | null): void {
  cache = commerces;
}

const metres = (a: { lat: number; lng: number }, b: { lat: number; lng: number }) =>
  Math.hypot((a.lat - b.lat) * 111_000, (a.lng - b.lng) * 108_000);

// Ce qui décrit un commerce sans le nommer : « Haddad Khalil Super Market »
// se dit « Haddad Khalil ».
const GENERIQUES = new Set(['super', 'market', 'supermarche', 'supermarket', 'restaurant', 'boutique', 'magasin',
  'ets', 'etablissement', 'etablissements', 'sarl', 'sa', 'niamey', 'niger', 'le', 'la', 'les', 'de', 'du', 'des', 'chez']);
const coeur = (n: string) => n.split(' ').filter((m) => m.length > 1 && !GENERIQUES.has(m));

/**
 * Les commerces de l'annuaire qui portent ce nom (« haddad khalil »), le
 * plus fiable d'abord. Tous les mots du nom demandé doivent y être : « tchos »
 * ne doit pas ramener « Tchoco Bar ».
 */
export function commercesNommes(nomNormalise: string, exclure: (c: Commerce) => boolean = () => false): Commerce[] {
  const demande = coeur(nomNormalise);
  if (demande.length === 0 || demande.join('').length < 3) return [];
  return chargerCommerces()
    .filter((c) => {
      const noms = [c.nom_normalise, ...(c.alias ?? []).map((a) => normaliserIntention(a))];
      return noms.some((nom) => demande.every((m) => coeur(nom).includes(m))) && !exclure(c);
    })
    .sort((a, b) => b.fiabilite - a.fiabilite)
    .slice(0, 3);
}

/** Les types de commerce où l'on trouve probablement ce produit, ou [] si on ne sait pas. */
export function typesPourProduit(texte: string): TypeCommerce[] {
  const n = normaliserIntention(texte);
  return PRODUITS.find(([motif]) => motif.test(n))?.[1] ?? [];
}

/**
 * Les commerces où chercher ce produit : du bon type, les plus proches (8 km
 * au plus) si l'on connaît la position du client, sinon les plus fiables.
 */
export function commercesPourProduit(
  texte: string,
  position: { lat: number; lng: number } | null | undefined,
  exclure: (c: Commerce) => boolean = () => false,
  combien = 3,
): Commerce[] {
  const n = normaliserIntention(texte);
  const mots = new Set(n.split(' '));
  // Ceux dont c'est la réputation (« le vendeur de merguez de la place
  // Toumo ») passent devant, où qu'ils soient dans la ville.
  const reputes = chargerCommerces().filter((c) =>
    (c.specialites ?? []).some((s) => mots.has(normaliserIntention(s)) || mots.has(`${normaliserIntention(s)}s`)));
  const types = typesPourProduit(texte);
  const candidats = chargerCommerces().filter((c) => types.includes(c.type) && !reputes.includes(c));
  const proches = position
    ? candidats
      .map((c) => ({ c, d: metres(position, c) }))
      .filter(({ d }) => d <= 8000)
      .sort((a, b) => a.d - b.d)
      .map(({ c }) => c)
    : candidats.sort((a, b) => b.fiabilite - a.fiabilite);
  // `exclure` (« est-il en fait sur Tovo ? ») coûte cher : seulement sur les
  // premiers, jusqu'à en avoir assez.
  const retenus: Commerce[] = [];
  for (const c of [...reputes, ...proches]) {
    if (retenus.length >= combien) break;
    if (!exclure(c)) retenus.push(c);
  }
  return retenus;
}

/** « supermarchés » si tous sont du même type, sinon « commerces ». */
export function libelleDes(commerces: Commerce[]): string {
  const types = new Set(commerces.map((c) => c.type));
  return types.size === 1 ? LIBELLES[[...types][0]!].des : 'commerces';
}

export const NOTE_SOURCE = 'Commerces hors Tovo, d’après des informations publiques. '
  + 'Ils peuvent avoir changé : appelez avant de vous déplacer.';

/**
 * La carte « Commerces hors Tovo » (maquette validée le 01/10) : pour chacun,
 * le nom, le type, la rue ou le quartier, la distance, puis « Envoyer un
 * livreur » (d'abord) et le numéro (ensuite, s'il est connu).
 *
 * `achat` : ce que le livreur doit faire là-bas (« Acheter de la pommade »).
 * La valeur de « Envoyer un livreur » est celle de la tuile « Oui » de
 * catalogue.ts (HORS_TOVO_OUI) : la même carte livreur s'ouvre, déjà remplie.
 */
export function carteCommerces(
  commerces: Commerce[],
  achat: string,
  prefixeOui: string,
  position?: { lat: number; lng: number } | null,
  note: string = NOTE_SOURCE,
): Component {
  return {
    type: 'commerces_hors_tovo',
    data: {
      items: commerces.map((c) => {
        const ou = [c.adresse, c.quartier].filter(Boolean).join(', ');
        const consigne = `${achat} chez ${c.nom}${ou ? ` (${ou})` : ''}`.replace(/\|/g, ' ').slice(0, 160);
        return {
          id: c.id,
          nom: c.nom,
          type: LIBELLES[c.type].un,
          icone: LIBELLES[c.type].icone,
          adresse: ou || null,
          distance_m: position ? Math.round(metres(position, c)) : null,
          telephone: c.telephone,
          telephone_appel: c.telephone_appel,
          livreur: {
            label: `Envoyer un livreur chez ${c.nom}`,
            value: `${prefixeOui}${consigne}${c.telephone_appel ? `|${c.telephone_appel}` : ''}`,
          },
        };
      }),
      note,
    },
  };
}
