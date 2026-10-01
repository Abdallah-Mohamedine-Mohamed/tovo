import { env } from '../config/env.js';
import { normaliserIntention } from '../ai/intents.js';
import type { Commerce, TypeCommerce } from './commerces.js';

/**
 * Le complément Google (01/10) : un commerce NOMMÉ par le client, que notre
 * annuaire ne connaît pas (« chez Tchos »), est cherché sur Google Places
 * (API « Places API (New) », même clé que les itinéraires).
 *
 * Règles de Google, respectées ici :
 *  - rien n'est conservé sauf l'identifiant du lieu (place_id, autorisé sans
 *    limite) : le nom, l'adresse et le numéro sont redemandés à chaque fois ;
 *  - l'affichage porte la mention « Google Maps » (discrète, voir NOTE_GOOGLE).
 *
 * Choix de Tovo : jamais d'étoiles, de notes, d'avis ni de photos (on ne les
 * demande même pas) ; l'icône 3D du type de commerce à la place.
 *
 * Données pas toujours fiables : seulement des lieux EN ACTIVITÉ, à Niamey,
 * dont le nom ressemble vraiment à celui demandé (fautes et mots inversés
 * tolérés, pas « Tchoco Bar » pour « Tchos »). Pharmacies incluses (01/10).
 */

export const NOTE_GOOGLE = 'D’après Google Maps. Ces informations peuvent avoir changé : appelez avant de vous déplacer.';

// Le strict nécessaire : ni note, ni avis, ni photo.
const CHAMPS = ['id', 'displayName', 'formattedAddress', 'shortFormattedAddress', 'location', 'businessStatus',
  'nationalPhoneNumber', 'primaryType', 'types'];

// Niamey et sa périphérie.
const NIAMEY = { low: { latitude: 13.40, longitude: 1.95 }, high: { latitude: 13.65, longitude: 2.25 } };

interface LieuGoogle {
  id: string;
  displayName?: { text?: string };
  formattedAddress?: string;
  shortFormattedAddress?: string;
  location?: { latitude: number; longitude: number };
  businessStatus?: string;
  nationalPhoneNumber?: string;
  primaryType?: string;
  types?: string[];
}

const cle = () => env.GOOGLE_PLACE_API_KEY ?? env.GOOGLE_ROUTES_API_KEY;

/** Les mots qui décrivent un commerce sans le nommer. */
const GENERIQUES = new Set(['chez', 'le', 'la', 'les', 'de', 'du', 'des', 'l', 'd', 'et', 'restaurant', 'resto', 'boutique',
  'magasin', 'supermarche', 'super', 'market', 'ets', 'etablissement', 'etablissements', 'sarl', 'niamey', 'niger']);
const mots = (s: string) => normaliserIntention(s).split(' ').filter((m) => m.length > 1 && !GENERIQUES.has(m));

function levenshtein(a: string, b: string): number {
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

/** Fautes tolérées selon la longueur du mot : 0 jusqu'à 3 lettres, 1 jusqu'à 6, 2 au-delà. */
const tolerance = (m: string) => (m.length <= 3 ? 0 : m.length <= 6 ? 1 : 2);
const motProche = (a: string, b: string) => a === b || levenshtein(a, b) <= Math.min(tolerance(a), tolerance(b));

/**
 * Le nom trouvé est-il bien celui demandé ? Chaque mot demandé doit se
 * retrouver dans le nom trouvé, à une faute près et dans n'importe quel ordre
 * (« Merguez Nouhou » = « Nouhou Merguez », « Nouho » = « Nouhou »). Les mots
 * collés ou séparés aussi (« Garbador » = « Garba d'Or »).
 */
export function nomsCorrespondent(demande: string, trouve: string): boolean {
  const d = mots(demande);
  const t = mots(trouve);
  if (d.length === 0 || t.length === 0) return false;
  if (d.every((m) => t.some((n) => motProche(m, n)))) return true;
  const colleD = d.join('');
  const colleT = t.join('');
  return colleD.length >= 5 && levenshtein(colleD, colleT) <= tolerance(colleD);
}

/** Le type Google le plus parlant → nos types (pour l'icône), ou null s'il est écarté. */
function typeDepuisGoogle(l: LieuGoogle): TypeCommerce | null {
  const types = [l.primaryType ?? '', ...(l.types ?? [])].join(' ');
  if (/hospital|doctor|dentist/.test(types)) return null;
  if (/pharmacy|drugstore/.test(types)) return 'pharmacie';
  if (/butcher/.test(types)) return 'boucherie';
  if (/bakery/.test(types)) return 'boulangerie';
  if (/supermarket|grocery|convenience_store|food_store|market/.test(types)) return 'supermarche';
  if (/clothing|shoe_store|jewelry/.test(types)) return 'vetements';
  if (/electronics|cell_phone|computer/.test(types)) return 'electronique';
  if (/hardware|home_improvement/.test(types)) return 'quincaillerie';
  if (/beauty|cosmetic|perfume/.test(types)) return 'beaute';
  if (/barbecue|grill/.test(types)) return 'grillades';
  if (/restaurant|meal_|food|cafe|bar\b/.test(types)) return 'restaurant';
  return 'boutique';
}

/** « 20 73 61 60 » et « +22720736160 » depuis le numéro national de Google. */
function telephone(national: string | undefined): { affiche: string; appel: string } | null {
  const chiffres = (national ?? '').replace(/\D/g, '').replace(/^227(?=\d{8}$)/, '');
  if (chiffres.length !== 8) return null;
  return { affiche: chiffres.replace(/(\d{2})(?=\d)/g, '$1 '), appel: `+227${chiffres}` };
}

/** Un lieu Google présenté comme un commerce de notre annuaire (rien n'est conservé). */
function enCommerce(l: LieuGoogle, type: TypeCommerce): Commerce & { place_id: string } {
  const tel = telephone(l.nationalPhoneNumber);
  const nom = l.displayName?.text ?? '';
  const adresse = (l.shortFormattedAddress ?? l.formattedAddress ?? '')
    .replace(/(,\s*(niamey|niger))+\s*$/i, '').replace(/^[A-Z0-9]{4}\+[A-Z0-9]{2,3},?\s*/, '').trim();
  return {
    id: `google:${l.id}`, place_id: l.id, nom, nom_normalise: normaliserIntention(nom), type,
    adresse: adresse || null, quartier: null,
    telephone: tel?.affiche ?? null, telephone_appel: tel?.appel ?? null,
    lat: l.location?.latitude ?? 0, lng: l.location?.longitude ?? 0, fiabilite: 0.7, source: 'google',
  };
}

function acceptable(l: LieuGoogle, demande: string): TypeCommerce | null {
  if (!l.displayName?.text || !l.location) return null;
  if (l.businessStatus && l.businessStatus !== 'OPERATIONAL') return null;
  const { latitude: lat, longitude: lng } = l.location;
  if (lat < NIAMEY.low.latitude || lat > NIAMEY.high.latitude || lng < NIAMEY.low.longitude || lng > NIAMEY.high.longitude) return null;
  if (!nomsCorrespondent(demande, l.displayName.text)) return null;
  return typeDepuisGoogle(l);
}

/**
 * Cherche sur Google le commerce que le client a nommé. Le plus pertinent
 * d'abord, 3 au plus ; [] si Google ne répond pas à temps, n'a rien de
 * sûr, ou si la clé manque. Jamais bloquant.
 */
export async function chercherSurGoogle(demande: string, delaiMs = 2500): Promise<Array<Commerce & { place_id: string }>> {
  if (!cle() || mots(demande).length === 0) return [];
  try {
    const r = await fetch('https://places.googleapis.com/v1/places:searchText', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'X-Goog-Api-Key': cle()!,
        'X-Goog-FieldMask': CHAMPS.map((c) => `places.${c}`).join(','),
      },
      body: JSON.stringify({
        textQuery: demande,
        languageCode: 'fr',
        regionCode: 'NE',
        pageSize: 5,
        locationRestriction: { rectangle: NIAMEY },
      }),
      signal: AbortSignal.timeout(delaiMs),
    });
    if (!r.ok) return [];
    const { places = [] } = (await r.json()) as { places?: LieuGoogle[] };
    return places
      .map((l) => ({ l, type: acceptable(l, demande) }))
      .filter((x): x is { l: LieuGoogle; type: TypeCommerce } => x.type !== null)
      .slice(0, 3)
      .map(({ l, type }) => enCommerce(l, type));
  } catch {
    return [];
  }
}

/**
 * La position exacte d'un lieu sur Google, et rien d'autre (formule la moins
 * chère : ni téléphone, ni horaires). Pour placer les pharmacies de garde :
 * Google autorise à garder une position 30 jours, une garde en dure 7.
 *
 * `nomAttendu` doit correspondre au nom trouvé (fautes tolérées), et le lieu
 * doit être en activité, à Niamey.
 */
export async function positionSurGoogle(
  recherche: string,
  nomAttendu: string,
  delaiMs = 4000,
): Promise<{ lat: number; lng: number; place_id: string; nom: string } | null> {
  if (!cle()) return null;
  try {
    const r = await fetch('https://places.googleapis.com/v1/places:searchText', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'X-Goog-Api-Key': cle()!,
        'X-Goog-FieldMask': 'places.id,places.displayName,places.location,places.businessStatus',
      },
      body: JSON.stringify({
        textQuery: recherche, languageCode: 'fr', regionCode: 'NE', pageSize: 5,
        locationRestriction: { rectangle: NIAMEY },
      }),
      signal: AbortSignal.timeout(delaiMs),
    });
    if (!r.ok) return null;
    const { places = [] } = (await r.json()) as { places?: LieuGoogle[] };
    const bon = places.find((l) => l.location && l.displayName?.text
      && (!l.businessStatus || l.businessStatus === 'OPERATIONAL')
      && nomsCorrespondent(nomAttendu, l.displayName.text));
    return bon ? { lat: bon.location!.latitude, lng: bon.location!.longitude, place_id: bon.id, nom: bon.displayName!.text! } : null;
  } catch {
    return null;
  }
}

/**
 * Redemande un lieu déjà identifié (place_id conservé dans
 * boutiques_demandees) : moins cher qu'une recherche, et toujours à jour.
 */
export async function lieuGoogle(placeId: string, demande: string, delaiMs = 2500): Promise<(Commerce & { place_id: string }) | null> {
  if (!cle() || !/^[\w-]+$/.test(placeId)) return null;
  try {
    const r = await fetch(`https://places.googleapis.com/v1/places/${placeId}?languageCode=fr&regionCode=NE`, {
      headers: { 'X-Goog-Api-Key': cle()!, 'X-Goog-FieldMask': CHAMPS.join(',') },
      signal: AbortSignal.timeout(delaiMs),
    });
    if (!r.ok) return null;
    const l = (await r.json()) as LieuGoogle;
    const type = acceptable(l, demande);
    return type ? enCommerce(l, type) : null;
  } catch {
    return null;
  }
}
