import { normaliserIntention } from '../ai/intents.js';
import { chargerCommerces, installerTerrain, type Commerce, type TypeCommerce } from './commerces.js';
import { autourDe } from './lieux.js';
import { serviceClient } from './supabase.js';

/**
 * Les commerces relevés SUR LE TERRAIN par les livreurs (07/10, migration
 * 0076) : photo de la devanture, point GPS, nom, type, téléphone. Proposés
 * par le livreur, validés par l'admin (page « Commerces du terrain »).
 *
 * Validés, ils rejoignent l'annuaire hors Tovo sans redéploiement : relus
 * au démarrage puis toutes les 5 minutes. Ce sont les plus fiables de
 * l'annuaire — quelqu'un de Tovo s'est tenu devant.
 */

export const TYPES_TERRAIN: TypeCommerce[] = ['supermarche', 'marche', 'boucherie', 'boulangerie', 'beaute',
  'electronique', 'vetements', 'quincaillerie', 'restaurant', 'grillades', 'pharmacie', 'boutique'];

interface Ligne {
  id: string;
  nom: string;
  type: TypeCommerce;
  telephone: string | null;
  lat: number;
  lng: number;
  repere: string | null;
}

const enCommerce = (l: Ligne): Commerce => ({
  id: `terrain:${l.id}`,
  nom: l.nom,
  nom_normalise: normaliserIntention(l.nom),
  type: l.type,
  adresse: l.repere,
  quartier: autourDe({ lat: l.lat, lng: l.lng }).quartier,
  telephone: l.telephone ? l.telephone.replace(/(\d{2})(?=\d)/g, '$1 ') : null,
  telephone_appel: l.telephone ? `+227${l.telephone}` : null,
  lat: l.lat,
  lng: l.lng,
  fiabilite: 1,
  source: 'terrain',
});

/** Relit les fiches validées ; jamais bloquant (l'annuaire garde les précédentes). */
export async function rafraichirCommercesTerrain(): Promise<number | null> {
  try {
    const { data, error } = await serviceClient().from('commerces_terrain')
      .select('id, nom, type, telephone, lat, lng, repere')
      .eq('statut', 'valide')
      .limit(20_000);
    if (error) return null;
    const commerces = ((data ?? []) as Ligne[]).map(enCommerce);
    installerTerrain(commerces);
    return commerces.length;
  } catch {
    return null;
  }
}

let minuterie: ReturnType<typeof setInterval> | null = null;
/** Au démarrage du serveur : une lecture, puis toutes les 5 minutes. */
export function suivreCommercesTerrain(): void {
  if (minuterie) return;
  void rafraichirCommercesTerrain();
  minuterie = setInterval(() => void rafraichirCommercesTerrain(), 5 * 60_000);
  minuterie.unref();
}

const metres = (a: { lat: number; lng: number }, b: { lat: number; lng: number }) =>
  Math.hypot((a.lat - b.lat) * 111_000, (a.lng - b.lng) * 108_000);

/**
 * Déjà connu ? Le même nom à moins de 150 m, dans l'annuaire ou parmi les
 * fiches déjà proposées. Le livreur le voit tout de suite, plutôt que de
 * créer un doublon que l'admin devra refuser.
 */
export async function dejaConnu(nom: string, point: { lat: number; lng: number }): Promise<string | null> {
  const cle = normaliserIntention(nom);
  const proche = chargerCommerces().find((c) => c.nom_normalise === cle && metres(c, point) <= 150);
  if (proche) return proche.nom;
  const { data } = await serviceClient().from('commerces_terrain')
    .select('nom, lat, lng')
    .in('statut', ['propose', 'valide'])
    .gte('lat', point.lat - 0.002).lte('lat', point.lat + 0.002)
    .gte('lng', point.lng - 0.002).lte('lng', point.lng + 0.002)
    .limit(50);
  const fiche = ((data ?? []) as Array<{ nom: string; lat: number; lng: number }>)
    .find((f) => normaliserIntention(f.nom) === cle && metres(f, point) <= 150);
  return fiche?.nom ?? null;
}
