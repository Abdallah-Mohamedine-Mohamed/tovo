import type { SupabaseClient } from '@supabase/supabase-js';

/**
 * L'heure d'arrivée affichée sur l'écran verrouillé et dans la Dynamic
 * Island (« Arrivée vers 14:35 »), calculée quand un livreur est EN ROUTE —
 * pas avant : tant que la boutique confirme ou cuisine, aucune heure ne
 * serait fiable, et l'app montre le temps écoulé depuis la commande.
 *
 * Une heure plutôt qu'un compte à rebours : elle ne défile pas vers zéro
 * sous les yeux du client, et se corrige sans bruit à chaque étape
 * (décision du client, 25/09).
 */

/** Moto en ville (Niamey) : ~22 km/h de moyenne, arrêts compris. */
const VITESSE_KMH = 22;
/** Les rues ne sont pas des lignes droites : +35 % sur la distance à vol d'oiseau. */
const DETOUR = 1.35;
/** Récupérer une commande ou un colis : quelques minutes sur place. */
const REMISE_MIN = 3;
/** Position du livreur inconnue : le temps moyen pour rejoindre le départ. */
const APPROCHE_INCONNUE_MIN = 8;

export type Point = { lat: number; lng: number };

/**
 * Un point PostGIS tel que PostgREST le renvoie : de l'EWKB en hexadécimal
 * (« 0101000020E6100000… »), ou déjà en GeoJSON selon la configuration.
 */
export function lirePoint(valeur: unknown): Point | null {
  if (!valeur) return null;
  if (typeof valeur === 'object') {
    const coordonnees = (valeur as { coordinates?: unknown }).coordinates;
    if (Array.isArray(coordonnees) && coordonnees.length >= 2) {
      return { lng: Number(coordonnees[0]), lat: Number(coordonnees[1]) };
    }
    return null;
  }
  if (typeof valeur !== 'string' || !/^[0-9a-fA-F]+$/.test(valeur)) return null;
  const octets = Buffer.from(valeur, 'hex');
  if (octets.length < 21) return null;
  const petitBoutiste = octets[0] === 1;
  const lireU32 = (o: number) => (petitBoutiste ? octets.readUInt32LE(o) : octets.readUInt32BE(o));
  const lireF64 = (o: number) => (petitBoutiste ? octets.readDoubleLE(o) : octets.readDoubleBE(o));
  const type = lireU32(1);
  if ((type & 0xffff) !== 1) return null;
  const debut = type & 0x20000000 ? 9 : 5; // un SRID suit le type
  return { lng: lireF64(debut), lat: lireF64(debut + 8) };
}

/** Distance à vol d'oiseau, en kilomètres. */
export function distanceKm(a: Point, b: Point): number {
  const rad = (d: number) => (d * Math.PI) / 180;
  const dLat = rad(b.lat - a.lat);
  const dLng = rad(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * 6371 * Math.asin(Math.sqrt(h));
}

/** Minutes de trajet à moto entre deux points. */
export function trajetMin(a: Point, b: Point): number {
  return (distanceKm(a, b) * DETOUR / VITESSE_KMH) * 60;
}

export type Course = {
  statut: string;
  colis: boolean;
  /** Colis : « deposer » (le livreur vient chez le client) ou « recuperer ». */
  mode: string;
  livreur: Point | null;
  depart: Point | null;
  arrivee: Point | null;
};

/**
 * Les minutes restantes, ou null si aucune heure fiable n'existe encore
 * (pas de livreur en route, ou pas de positions).
 */
export function minutesRestantes(c: Course): number | null {
  const enRoute = ['assigned', 'picked_up', 'delivering'].includes(c.statut);
  if (!enRoute) return null;

  const versDepart = (): number | null => {
    if (!c.depart) return null;
    return c.livreur ? trajetMin(c.livreur, c.depart) : APPROCHE_INCONNUE_MIN;
  };

  if (c.statut === 'assigned') {
    const approche = versDepart();
    if (approche == null) return null;
    // Colis « déposer » : pour le client, l'arrivée, c'est le livreur qui
    // vient chercher le colis chez lui — le point de départ.
    if (c.colis && c.mode !== 'recuperer') return approche;
    if (!c.depart || !c.arrivee) return null;
    return approche + REMISE_MIN + trajetMin(c.depart, c.arrivee);
  }

  // Récupéré, en route : du livreur (sinon du départ) jusqu'à l'arrivée.
  const origine = c.livreur ?? c.depart;
  if (!origine || !c.arrivee) return null;
  return trajetMin(origine, c.arrivee);
}

/**
 * L'heure d'arrivée, en secondes depuis 1970, arrondie aux 5 minutes
 * SUPÉRIEURES : « vers 14:35 » laisse une marge au lieu d'une promesse à la
 * minute près.
 */
export function heureArrivee(minutes: number, maintenant = Date.now()): number {
  const cinq = 5 * 60 * 1000;
  const brute = maintenant + Math.max(minutes, 1) * 60 * 1000;
  return Math.ceil(brute / cinq) * cinq / 1000;
}

/** Lit la course en base et renvoie l'heure d'arrivée, ou null. */
export async function estimerArrivee(db: SupabaseClient, orderId: string, statut: string): Promise<number | null> {
  if (!['assigned', 'picked_up', 'delivering'].includes(statut)) return null;
  const { data: commande } = await db
    .from('orders')
    .select('type, driver_id, dropoff_location, merchants(location), courier_details(pickup_location, mode)')
    .eq('id', orderId)
    .maybeSingle();
  if (!commande) return null;

  let livreur: Point | null = null;
  if (commande.driver_id) {
    const { data: profil } = await db
      .from('driver_profiles')
      .select('current_location, last_seen_at')
      .eq('id', commande.driver_id as string)
      .maybeSingle();
    // Une position de plus de 10 minutes ne dit plus où il est.
    const frais = profil?.last_seen_at
      ? Date.now() - new Date(profil.last_seen_at as string).getTime() < 10 * 60 * 1000
      : false;
    livreur = frais ? lirePoint(profil?.current_location) : null;
  }

  const colis = commande.type === 'courier';
  const details = (Array.isArray(commande.courier_details)
    ? commande.courier_details[0]
    : commande.courier_details) as { pickup_location?: unknown; mode?: string } | null;
  const boutique = (Array.isArray(commande.merchants)
    ? commande.merchants[0]
    : commande.merchants) as { location?: unknown } | null;

  const minutes = minutesRestantes({
    statut,
    colis,
    mode: details?.mode ?? 'deposer',
    livreur,
    depart: lirePoint(colis ? details?.pickup_location : boutique?.location),
    arrivee: lirePoint(commande.dropoff_location),
  });
  return minutes == null ? null : heureArrivee(minutes);
}
