import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { decoderPolyline, itinerairePour } from '../services/itineraire.js';
import { distanceKm, type Point } from '../services/arrivee.js';
import { autourDe, chargerLieux, type Lieu } from '../services/lieux.js';

/**
 * La carte des commerces (07/10) : le tracé du client jusqu'au commerce
 * choisi, et de quoi s'y retrouver sans surcharger la carte (spécification
 * du fondateur, Documents/map-style.json) :
 *   - le QUARTIER du commerce, mis en avant par l'appli ;
 *   - 2 ou 3 REPÈRES proches du trajet (rond-point, marché, puis gare,
 *     station), seulement ceux qui sont près de l'itinéraire.
 * Le tracé vient de Google Routes (même cache que le suivi des commandes).
 */

const point = z.string().regex(/^-?\d+(\.\d+)?,-?\d+(\.\d+)?$/).transform((v) => {
  const [lat, lng] = v.split(',').map(Number);
  return { lat: lat!, lng: lng! };
});

/** Un repère utile pour se situer : marchés et ronds-points d'abord. */
function rangDuRepere(l: Lieu): number | null {
  if (l.genre === 'marché') return 0;
  if (l.genre === 'rue' && /rond[- ]?point/i.test(l.nom)) return 0;
  if (l.genre === 'gare') return 1;
  if (l.genre === 'station-service') return 2;
  return null;
}

export function reperesDuTrajet(trajet: Point[], lieux: Lieu[] = chargerLieux(), combien = 3): Array<{ nom: string; lat: number; lng: number }> {
  if (trajet.length < 2) return [];
  const debut = trajet[0]!, fin = trajet[trajet.length - 1]!;
  // Un point tous les ~40 m du trajet : la distance au trajet sans calcul lourd.
  const echantillon: Point[] = [];
  for (let i = 1; i < trajet.length; i++) {
    const a = trajet[i - 1]!, b = trajet[i]!;
    const pas = Math.max(1, Math.ceil((distanceKm(a, b) * 1000) / 40));
    for (let k = 0; k < pas; k++) echantillon.push({ lat: a.lat + ((b.lat - a.lat) * k) / pas, lng: a.lng + ((b.lng - a.lng) * k) / pas });
  }
  echantillon.push(fin);
  const lat0 = Math.min(...trajet.map((p) => p.lat)) - 0.002, lat1 = Math.max(...trajet.map((p) => p.lat)) + 0.002;
  const lng0 = Math.min(...trajet.map((p) => p.lng)) - 0.002, lng1 = Math.max(...trajet.map((p) => p.lng)) + 0.002;
  const candidats = lieux
    .filter((l) => l.lat > lat0 && l.lat < lat1 && l.lng > lng0 && l.lng < lng1)
    .map((l) => ({ l, rang: rangDuRepere(l) }))
    .filter((c): c is { l: Lieu; rang: number } => c.rang !== null)
    .map((c) => ({ ...c, ecart: Math.min(...echantillon.map((p) => distanceKm(p, c.l) * 1000)) }))
    // Près du trajet (70 m), mais pas sur le départ ni sur l'arrivée.
    .filter((c) => c.ecart <= 70 && distanceKm(c.l, debut) * 1000 > 120 && distanceKm(c.l, fin) * 1000 > 120)
    .sort((a, b) => a.rang - b.rang || a.ecart - b.ecart);
  const retenus: Lieu[] = [];
  for (const { l } of candidats) {
    if (retenus.length >= combien) break;
    // Deux repères trop proches l'un de l'autre se chevaucheraient.
    if (retenus.some((r) => distanceKm(r, l) * 1000 < 250)) continue;
    retenus.push(l);
  }
  return retenus.map((l) => ({ nom: l.nom, lat: l.lat, lng: l.lng }));
}

export async function carteRoutes(app: FastifyInstance): Promise<void> {
  app.get('/carte/itineraire', { preHandler: app.requireAuth }, async (request, reply) => {
    const q = z.object({ de: point, a: point }).safeParse(request.query);
    if (!q.success) return reply.code(400).send({ error: 'positions invalides (de=lat,lng & a=lat,lng)' });
    const { de, a } = q.data;
    // Un tracé fixe par couple de positions (arrondies à ~10 m).
    const cle = `carte:${de.lat.toFixed(4)},${de.lng.toFixed(4)}>${a.lat.toFixed(4)},${a.lng.toFixed(4)}`;
    const itineraire = await itinerairePour(cle, de, a).catch(() => null);
    const trajet = itineraire ? decoderPolyline(itineraire.polyline) : [de, a];
    return reply.send({
      polyline: itineraire?.polyline ?? null,
      distance_m: itineraire?.distanceM ?? Math.round(distanceKm(de, a) * 1000),
      duree_s: itineraire?.dureeS ?? null,
      quartier: autourDe(a).quartier,
      reperes: reperesDuTrajet(trajet),
    });
  });
}
