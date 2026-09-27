import { env } from '../config/env.js';
import { distanceKm, type Point } from './arrivee.js';

/**
 * L'itinéraire du livreur, tracé sur la carte de suivi du client.
 *
 * Google Routes API (Compute Routes), en voiture et sans trafic : c'est la
 * formule « Essentials », 10 000 calculs gratuits par mois. Le trafic ou
 * les deux-roues la feraient passer en « Pro », plus chère, pour un gain
 * nul à Niamey — une moto y emprunte les mêmes rues qu'une voiture.
 *
 * Un calcul coûte : on n'en refait un que s'il le faut vraiment.
 *   - même destination, et le livreur est encore SUR le tracé (à moins de
 *     60 m d'un de ses points) : on renvoie le tracé déjà calculé ;
 *   - sinon, jamais plus d'un calcul toutes les 20 s par commande ;
 *   - un tracé de plus de 15 minutes est refait (le livreur a pu couper).
 */

export type Itineraire = {
  /** Polyligne encodée (format Google), décodée par l'app. */
  polyline: string;
  distanceM: number;
  dureeS: number;
};

type Entree = {
  itineraire: Itineraire;
  points: Point[];
  destination: Point;
  calculeLe: number;
};

const ECART_MAX_M = 60;
const INTERVALLE_MIN_MS = 20_000;
const DUREE_DE_VIE_MS = 15 * 60_000;

const cache = new Map<string, Entree>();
const dernierCalcul = new Map<string, number>();

/** Décode une polyligne Google (précision 1e-5). */
export function decoderPolyline(code: string): Point[] {
  const points: Point[] = [];
  let i = 0;
  let lat = 0;
  let lng = 0;
  while (i < code.length) {
    for (const axe of ['lat', 'lng'] as const) {
      let resultat = 0;
      let decalage = 0;
      let octet: number;
      do {
        octet = code.charCodeAt(i++) - 63;
        resultat |= (octet & 0x1f) << decalage;
        decalage += 5;
      } while (octet >= 0x20 && i < code.length);
      const delta = resultat & 1 ? ~(resultat >> 1) : resultat >> 1;
      if (axe === 'lat') lat += delta;
      else lng += delta;
    }
    points.push({ lat: lat / 1e5, lng: lng / 1e5 });
  }
  return points;
}

/** Le livreur est-il encore sur le tracé ? */
export function surLeTrace(livreur: Point, points: Point[], ecartMaxM = ECART_MAX_M): boolean {
  return points.some((p) => distanceKm(livreur, p) * 1000 <= ecartMaxM);
}

function memeEndroit(a: Point, b: Point): boolean {
  return distanceKm(a, b) * 1000 < 25;
}

async function calculer(depart: Point, destination: Point): Promise<Itineraire | null> {
  const cle = env.GOOGLE_ROUTES_API_KEY;
  if (!cle) return null;
  const reponse = await fetch('https://routes.googleapis.com/directions/v2:computeRoutes', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Goog-Api-Key': cle,
      'X-Goog-FieldMask': 'routes.polyline.encodedPolyline,routes.distanceMeters,routes.duration',
    },
    body: JSON.stringify({
      origin: { location: { latLng: { latitude: depart.lat, longitude: depart.lng } } },
      destination: { location: { latLng: { latitude: destination.lat, longitude: destination.lng } } },
      travelMode: 'DRIVE',
      routingPreference: 'TRAFFIC_UNAWARE',
      languageCode: 'fr',
    }),
    signal: AbortSignal.timeout(6000),
  });
  if (!reponse.ok) return null;
  const corps = (await reponse.json()) as {
    routes?: { polyline?: { encodedPolyline?: string }; distanceMeters?: number; duration?: string }[];
  };
  const route = corps.routes?.[0];
  const polyline = route?.polyline?.encodedPolyline;
  if (!polyline) return null;
  return {
    polyline,
    distanceM: route.distanceMeters ?? 0,
    dureeS: Number.parseInt(route.duration ?? '0', 10) || 0,
  };
}

/**
 * Le tracé du livreur jusqu'à sa destination, ou null (pas de clé, Google
 * injoignable, ou trop tôt pour recalculer et rien en réserve).
 */
export async function itinerairePour(
  commande: string,
  livreur: Point,
  destination: Point,
  maintenant = Date.now(),
): Promise<Itineraire | null> {
  const connu = cache.get(commande);
  if (
    connu &&
    memeEndroit(connu.destination, destination) &&
    maintenant - connu.calculeLe < DUREE_DE_VIE_MS &&
    surLeTrace(livreur, connu.points)
  ) {
    return connu.itineraire;
  }
  const dernier = dernierCalcul.get(commande) ?? 0;
  if (maintenant - dernier < INTERVALLE_MIN_MS) return connu?.itineraire ?? null;
  dernierCalcul.set(commande, maintenant);

  const itineraire = await calculer(livreur, destination).catch(() => null);
  if (!itineraire) return connu?.itineraire ?? null;
  cache.set(commande, {
    itineraire,
    points: decoderPolyline(itineraire.polyline),
    destination,
    calculeLe: maintenant,
  });
  // Un cache par commande, jamais purgé, finirait par peser : au-delà de
  // 500 commandes suivies, on oublie les plus anciennes.
  if (cache.size > 500) {
    const plusAncienne = cache.keys().next().value;
    if (plusAncienne) {
      cache.delete(plusAncienne);
      dernierCalcul.delete(plusAncienne);
    }
  }
  return itineraire;
}

/** Pour les tests. */
export function viderCacheItineraires(): void {
  cache.clear();
  dernierCalcul.clear();
}
