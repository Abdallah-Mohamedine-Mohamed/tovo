import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { normaliserIntention } from '../ai/intents.js';

/**
 * Repérer un lieu de Niamey dans une phrase : « chez Moussa à Harobanda »,
 * « près de la pharmacie Nour à Yantala », « derrière le marché de Bobiel ».
 *
 * À Niamey, l'adresse postale n'existe pas : on donne un quartier et un
 * repère. Les lieux viennent d'OpenStreetMap (data/lieux-niamey.json, 6 600
 * quartiers, rues, pharmacies, marchés, mosquées, écoles, stations… ;
 * © les contributeurs d'OpenStreetMap, ODbL), chargés une fois en mémoire.
 *
 * Prudence : un repère n'est retenu que si son nom est reconnu en entier
 * (ou à une faute près, pour un mot long). Mieux vaut « quartier seul » ou
 * « rien » que d'envoyer un livreur au mauvais endroit.
 */

export interface Lieu {
  id: string;
  nom: string;
  nom_normalise: string;
  genre: string;
  quartier: string | null;
  lat: number;
  lng: number;
}

export interface Reperage {
  quartier: Lieu | null;
  repere: Lieu | null;
  /** Le point le plus précis connu : le repère, sinon le centre du quartier. */
  point: { lat: number; lng: number } | null;
  /** Lisible pour le livreur : « Pharmacie Nour (Yantala) ». */
  description: string | null;
}

let cache: Lieu[] | null = null;

export function chargerLieux(chemin = join(process.cwd(), 'data', 'lieux-niamey.json')): Lieu[] {
  if (cache) return cache;
  try {
    cache = (JSON.parse(readFileSync(chemin, 'utf8')) as { lieux: Lieu[] }).lieux;
  } catch {
    cache = [];
  }
  return cache;
}

/** Pour les tests. */
export function installerLieux(lieux: Lieu[] | null): void {
  cache = lieux;
}

// Les mots de liaison, ignorés dans un nom.
const LIAISONS = new Set(['de', 'du', 'des', 'la', 'le', 'les', 'l', 'd', 'et', 'a', 'au', 'aux', 'en']);

// Les mots qui ne suffisent jamais à reconnaître un lieu à eux seuls.
const MOTS_VIDES = new Set([
  ...LIAISONS, 'rue', 'avenue', 'boulevard', 'place', 'marche', 'pharmacie', 'ecole', 'college', 'lycee',
  'mosquee', 'eglise', 'station', 'banque', 'hotel', 'restaurant', 'boutique', 'centre', 'cite', 'quartier',
  'grand', 'grande', 'petit', 'petite', 'niamey', 'niger', 'chez', 'moi', 'mon', 'ma', 'mes', 'nord', 'sud',
  'est', 'ouest', 'haut', 'bas', 'nouveau', 'nouvelle', 'ancien', 'ancienne',
]);

function distance(a: string, b: string): number {
  const ligne = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    let precedent = ligne[0]!;
    ligne[0] = i;
    for (let j = 1; j <= b.length; j++) {
      const courant = ligne[j]!;
      ligne[j] = Math.min(ligne[j]! + 1, ligne[j - 1]! + 1, precedent + (a[i - 1] === b[j - 1] ? 0 : 1));
      precedent = courant;
    }
  }
  return ligne[b.length]!;
}

/**
 * Un mot du nom est-il dans la phrase ? À l'identique, ou à une faute près
 * pour un mot LONG (8 lettres et plus, même première lettre) : « Taladjé »
 * pour « Talladjé », mais jamais « livres » pour « livrer ».
 */
function motPresent(phrase: string[], m: string): boolean {
  return phrase.some((p) => p === m
    || (m.length >= 8 && p[0] === m[0] && Math.abs(p.length - m.length) <= 1 && distance(p, m) <= 1));
}

/**
 * Le nom du lieu apparaît-il dans la phrase ?
 *  - un quartier : chacun de ses mots significatifs ;
 *  - un repère : TOUS les mots de son nom, « pharmacie » ou « marché »
 *    compris, et au moins un vrai mot de 4 lettres ou plus. « Harobanda »
 *    seul n'est pas « Marché Harobanda » ; une lettre isolée (« Mosquée M »)
 *    ne suffit jamais.
 */
function apparait(phrase: string[], nom: string, repere: boolean): boolean {
  const mots = nom.split(' ').filter((m) => m && !LIAISONS.has(m));
  const significatifs = mots.filter((m) => !MOTS_VIDES.has(m));
  if (!significatifs.some((m) => m.length >= 4)) {
    // Un nom fait seulement de mots courants (« Grand Marché ») : tel quel.
    return mots.length >= 2 && ` ${phrase.filter((p) => !LIAISONS.has(p)).join(' ')} `.includes(` ${mots.join(' ')} `);
  }
  return (repere ? mots : significatifs).every((m) => motPresent(phrase, m));
}

/**
 * Un quartier que la carte ne connaît pas comme tel, mais dont plusieurs
 * lieux portent le nom (« Harobanda » : Marché Harobanda, École Harobanda…) :
 * la zone est le centre de ces lieux, s'ils sont proches les uns des autres.
 */
function zone(phrase: string[], lieux: Lieu[]): Lieu | null {
  for (const mot of phrase.filter((m) => m.length >= 6 && !MOTS_VIDES.has(m))) {
    const portant = lieux.filter((l) => l.nom_normalise.split(' ').includes(mot));
    if (portant.length < 3) continue;
    // Le point médian, puis les lieux à moins de 2 km de lui : un lieu isolé
    // portant le même nom (un marché à bétail à 4 km) ne déplace pas la zone.
    const mediane = (v: number[]) => [...v].sort((a, b) => a - b)[Math.floor(v.length / 2)]!;
    const centre = { lat: mediane(portant.map((l) => l.lat)), lng: mediane(portant.map((l) => l.lng)) };
    const groupe = portant.filter((l) => Math.hypot((l.lat - centre.lat) * 111, (l.lng - centre.lng) * 108) <= 2);
    // Pas de vrai regroupement : ce n'est pas une zone.
    if (groupe.length < 3 || groupe.length < portant.length / 2) continue;
    const lat = groupe.reduce((s, l) => s + l.lat, 0) / groupe.length;
    const lng = groupe.reduce((s, l) => s + l.lng, 0) / groupe.length;
    const nom = mot.charAt(0).toUpperCase() + mot.slice(1);
    return { id: `zone:${mot}`, nom, nom_normalise: mot, genre: 'quartier', quartier: nom, lat, lng };
  }
  return null;
}

export function reperer(texte: string, lieux: Lieu[] = chargerLieux()): Reperage {
  const vide: Reperage = { quartier: null, repere: null, point: null, description: null };
  const phrase = normaliserIntention(texte).split(' ').filter(Boolean);
  if (phrase.length === 0 || lieux.length === 0) return vide;

  const estQuartier = (l: Lieu) => l.genre === 'quartier' || l.genre === 'village';
  const nomsDeQuartiers = new Set(lieux.filter(estQuartier).map((l) => l.nom_normalise));
  const candidats = lieux.filter((l) => l.nom_normalise.length >= 3
    // Une école nommée « Talladjé » n'est pas un repère : c'est le quartier.
    && (estQuartier(l) || !nomsDeQuartiers.has(l.nom_normalise))
    && apparait(phrase, l.nom_normalise, !estQuartier(l)));
  if (candidats.length === 0) {
    const z = zone(phrase, lieux);
    return z ? { quartier: z, repere: null, point: { lat: z.lat, lng: z.lng }, description: z.nom } : vide;
  }
  // Le plus long nom reconnu EN ENTIER l'emporte (« Talladjé Koado » avant
  // « Talladjé ») ; à défaut, le plus court reconnu en partie (« Yantala »
  // → « Yantala Haut »), jamais un plus long qui ajoute un mot non dit
  // (« Lazaret » n'est pas « Nord Lazaret »).
  const parLongueur = (a: Lieu, b: Lieu) => b.nom_normalise.length - a.nom_normalise.length;
  const quartiersVus = candidats.filter(estQuartier);
  const entiers = quartiersVus.filter((q) => apparait(phrase, q.nom_normalise, true));
  const quartier = entiers.sort(parLongueur)[0]
    ?? quartiersVus.sort((a, b) => a.nom_normalise.length - b.nom_normalise.length)[0]
    ?? zone(phrase, lieux);
  // Un repère (pas une rue : trop longues pour situer un point) ; dans le
  // quartier nommé s'il y en a un.
  const reperes = candidats
    .filter((l) => l.genre !== 'quartier' && l.genre !== 'village' && l.genre !== 'rue')
    .filter((l) => !quartier || l.quartier === quartier.nom)
    .sort(parLongueur);
  // Plusieurs lieux du même nom dans des quartiers différents, sans quartier
  // dit : on ne devine pas.
  const repere = reperes.length > 0 && (quartier || new Set(reperes.filter((r) => r.nom_normalise === reperes[0]!.nom_normalise).map((r) => r.quartier)).size === 1)
    ? reperes[0]!
    : null;

  const precis = repere ?? quartier;
  return {
    quartier,
    repere,
    point: precis ? { lat: precis.lat, lng: precis.lng } : null,
    description: repere
      ? `${repere.nom}${repere.quartier ? ` (${repere.quartier})` : ''}`
      : quartier?.nom ?? null,
  };
}
