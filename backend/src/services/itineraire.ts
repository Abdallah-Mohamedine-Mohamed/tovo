import { env } from '../config/env.js';
import { distanceKm, type Point } from './arrivee.js';

/**
 * Les itinéraires de la carte de suivi du client.
 *
 * Deux tracés (maquette « Suivi Commande », 27/09) :
 *   - le TRAJET, du départ (boutique, ou colis à récupérer) jusqu'au
 *     client : visible dès la commande confirmée ; une fois la commande
 *     récupérée, c'est lui que le livreur suit ;
 *   - l'APPROCHE, du livreur jusqu'au départ, tant qu'il n'a rien récupéré.
 *
 * Google Routes API (Compute Routes), en voiture et sans trafic : la
 * formule « Essentials », 10 000 calculs gratuits par mois. Le trafic ou
 * les deux-roues la feraient passer en « Pro », plus chère, pour un gain
 * nul à Niamey — une moto y emprunte les mêmes rues qu'une voiture.
 *
 * Un calcul coûte : on n'en refait un que s'il le faut vraiment.
 *   - un tracé suivi par le livreur reste valable tant qu'il est dessus (à
 *     moins de 50 m d'un de ses points) ;
 *   - un tracé fixe (boutique → client) ne change pas tant que ses deux
 *     bouts ne bougent pas ;
 *   - jamais plus d'un calcul toutes les 20 s par tracé.
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
  depart: Point;
  destination: Point;
  calculeLe: number;
};

const ECART_MAX_M = 50;
const INTERVALLE_MIN_MS = 20_000;
const VIE_SUIVI_MS = 15 * 60_000;
const VIE_FIXE_MS = 6 * 60 * 60_000;

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
      polylineQuality: 'HIGH_QUALITY',
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
 * Un tracé, ou null (pas de clé, Google injoignable, ou trop tôt pour
 * recalculer et rien en réserve).
 *
 * `cle` identifie le tracé (« <commande>:trajet », « <commande>:approche »).
 * `suivi` : la position du livreur, quand c'est lui qui suit ce tracé — il
 * reste valable tant qu'il est dessus. Sans `suivi`, le tracé est fixe et
 * ne change qu'avec ses deux bouts.
 */
export async function itinerairePour(
  cle: string,
  depart: Point,
  destination: Point,
  options: { suivi?: Point; maintenant?: number } = {},
): Promise<Itineraire | null> {
  const maintenant = options.maintenant ?? Date.now();
  const connu = cache.get(cle);
  if (connu && memeEndroit(connu.destination, destination)) {
    const valable = options.suivi
      ? maintenant - connu.calculeLe < VIE_SUIVI_MS && surLeTrace(options.suivi, connu.points)
      : maintenant - connu.calculeLe < VIE_FIXE_MS && memeEndroit(connu.depart, depart);
    if (valable) return connu.itineraire;
  }
  const dernier = dernierCalcul.get(cle) ?? 0;
  if (maintenant - dernier < INTERVALLE_MIN_MS) return connu?.itineraire ?? null;
  dernierCalcul.set(cle, maintenant);

  const itineraire = await calculer(depart, destination).catch(() => null);
  if (!itineraire) return connu?.itineraire ?? null;
  cache.delete(cle);
  cache.set(cle, {
    itineraire,
    points: decoderPolyline(itineraire.polyline),
    depart,
    destination,
    calculeLe: maintenant,
  });
  // Un cache jamais purgé finirait par peser : au-delà de 1 000 tracés, on
  // oublie les plus anciens.
  if (cache.size > 1000) {
    const plusAncien = cache.keys().next().value;
    if (plusAncien) {
      cache.delete(plusAncien);
      dernierCalcul.delete(plusAncien);
    }
  }
  return itineraire;
}

/** Pour les tests. */
export function viderCacheItineraires(): void {
  cache.clear();
  dernierCalcul.clear();
}
