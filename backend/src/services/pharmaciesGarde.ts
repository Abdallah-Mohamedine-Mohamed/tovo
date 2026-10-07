import { normaliserIntention } from '../ai/intents.js';
import type { Component } from '../components/builders.js';
import { chargerCommerces, pointDeMesure, type PointDeRecherche } from './commerces.js';
import { nomsCorrespondent, positionSurGoogle } from './googlePlaces.js';
import { reperer } from './lieux.js';
import { serviceClient } from './supabase.js';

/**
 * Les pharmacies de garde (01/10) — « très importantes pour aider les gens ».
 *
 * Pas d'API publique : la liste officielle (Ministère de la Santé, diffusée
 * chaque semaine par Lahiyata et d'autres) est saisie par l'équipe dans
 * l'admin, à partir de l'image de la semaine (table pharmacies_garde,
 * migration 0074). La garde court du samedi 8 h au samedi suivant 8 h.
 *
 * Le client voit les plus proches de sa position, avec le numéro et un
 * livreur. Les données sont publiques ; ce sont des faits ressaisis par Tovo.
 */

export interface PharmacieGarde {
  commune: string;
  nom: string;
  localisation: string;
  telephone: string;
  lat: number | null;
  lng: number | null;
  /**
   * Comment la position a été trouvée : sur Google (le plus sûr), la
   * pharmacie dans nos données, un repère, le quartier, ou collée à la main.
   */
  precision: 'google' | 'pharmacie' | 'repere' | 'quartier' | 'manuelle' | null;
}

/**
 * La position la plus sûre : Google d'abord (« Pharmacie Avenir Niamey »,
 * nom vérifié, en activité, à Niamey ; Google permet de garder une position
 * 30 jours, une garde en dure 7), sinon nos données (localiserPharmacie).
 * `nom_google` sert seulement à la vérification dans l'admin.
 */
export async function localiserPharmacieAvecGoogle(nom: string, localisation: string)
  : Promise<Pick<PharmacieGarde, 'lat' | 'lng' | 'precision'> & { nom_google?: string }> {
  const google = await positionSurGoogle(`Pharmacie ${nom} Niamey`, `Pharmacie ${nom}`);
  if (google) return { lat: google.lat, lng: google.lng, precision: 'google', nom_google: google.nom };
  return localiserPharmacie(nom, localisation);
}

export interface Garde {
  debut: string;
  fin: string;
  pharmacies: PharmacieGarde[];
}

/**
 * La position d'une pharmacie de garde : d'abord la pharmacie elle-même dans
 * nos données (« Avenir » = « Pharmacie de l'Avenir »), près du repère donné
 * s'il y en a plusieurs ; sinon le repère de sa localisation (« près du CSI
 * Deyzeibon ») ; sinon le quartier.
 */
export function localiserPharmacie(nom: string, localisation: string): Pick<PharmacieGarde, 'lat' | 'lng' | 'precision'> {
  const repere = reperer(`${localisation}`);
  const homonymes = chargerCommerces().filter((c) => c.type === 'pharmacie'
    && nomsCorrespondent(nom, c.nom.replace(/\bpha?r?macie\b/gi, '')));
  const proche = (p: { lat: number; lng: number }) => (repere.point
    ? Math.hypot((p.lat - repere.point.lat) * 111_000, (p.lng - repere.point.lng) * 108_000) : 0);
  const candidats = homonymes
    .filter((c) => !repere.point || proche(c) < 3000)
    .sort((a, b) => proche(a) - proche(b));
  if (candidats[0]) return { lat: candidats[0].lat, lng: candidats[0].lng, precision: 'pharmacie' };
  if (repere.repere) return { lat: repere.repere.lat, lng: repere.repere.lng, precision: 'repere' };
  if (repere.point) return { ...repere.point, precision: 'quartier' };
  return { lat: null, lng: null, precision: null };
}

let cache: { quand: number; garde: Garde | null } | null = null;

/** Pour les tests et après une publication dans l'admin. */
export function oublierGarde(): void {
  cache = null;
}

/** La garde en cours, ou null (table vide ou absente). Gardée en mémoire une minute. */
export async function gardeEnCours(maintenant = new Date()): Promise<Garde | null> {
  if (cache && Date.now() - cache.quand < 60_000) return cache.garde;
  let garde: Garde | null = null;
  try {
    const iso = maintenant.toISOString();
    const { data } = await serviceClient().from('pharmacies_garde')
      .select('debut, fin, commune, nom, localisation, telephone, lat, lng, precision')
      .lte('debut', iso).gt('fin', iso).order('commune').limit(200);
    const lignes = (data ?? []) as Array<PharmacieGarde & { debut: string; fin: string }>;
    if (lignes.length > 0) {
      garde = {
        debut: lignes[0]!.debut, fin: lignes[0]!.fin,
        pharmacies: lignes.map(({ debut: _d, fin: _f, ...p }) => p),
      };
    }
  } catch {
    garde = null;
  }
  cache = { quand: Date.now(), garde };
  return garde;
}

const metres = (a: { lat: number; lng: number }, b: { lat: number; lng: number }) =>
  Math.hypot((a.lat - b.lat) * 111_000, (a.lng - b.lng) * 108_000);

/** « samedi 26/09 8 h » à l'heure de Niamey. */
function quand(iso: string): string {
  const d = new Date(new Date(iso).getTime() + 3_600_000); // UTC+1
  const jour = ['dimanche', 'lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi'][d.getUTCDay()];
  return `${jour} ${String(d.getUTCDate()).padStart(2, '0')}/${String(d.getUTCMonth() + 1).padStart(2, '0')} ${d.getUTCHours()} h`;
}

/**
 * La nuit (21 h – 8 h) ou le dimanche, à l'heure de Niamey : seules les
 * pharmacies de garde sont ouvertes.
 */
export function heuresDeGarde(maintenant = new Date()): boolean {
  const niamey = new Date(maintenant.getTime() + 3_600_000);
  const h = niamey.getUTCHours();
  return niamey.getUTCDay() === 0 || h >= 21 || h < 8;
}

/** Une demande de pharmacie de garde (« pharmacie de garde », « pharmacies ouvertes la nuit »). */
export function demandeDeGarde(message: string): boolean {
  const n = normaliserIntention(message);
  return /\bpharmacies? (de garde|ouvertes?|de nuit)\b/.test(n) || /\bgarde\b.*\bpharmacie/.test(n);
}

export const HORS_TOVO_GARDE = 'D’après la liste officielle des pharmacies de garde (Ministère de la Santé), '
  + 'sous réserve de modification : appelez avant de vous déplacer.';

/**
 * La réponse « pharmacies de garde » : les plus proches de la position du
 * client (5), sinon les 5 premières de la liste avec une invitation à
 * partager sa position. La carte est celle des commerces hors Tovo.
 */
export async function reponseGarde(
  position: PointDeRecherche | null | undefined,
  prefixeOui: string,
  combien = 5,
): Promise<{ content: string; summary: Record<string, unknown>; components: Component[] }> {
  const garde = await gardeEnCours();
  if (!garde || garde.pharmacies.length === 0) {
    return {
      content: 'La liste des pharmacies de garde de cette semaine n’est pas encore disponible sur Tovo. '
        + 'Réessayez un peu plus tard.',
      summary: { pharmacies_garde: 0 },
      components: [],
    };
  }
  const placees = garde.pharmacies.map((p) => ({
    p, d: position && p.lat !== null && p.lng !== null ? metres(position, { lat: p.lat, lng: p.lng }) : null,
  }));
  const choisies = position
    ? placees.sort((a, b) => (a.d ?? Infinity) - (b.d ?? Infinity)).slice(0, combien)
    : placees.slice(0, combien);
  // Choisies autour du lieu cherché ; la distance affichée, depuis le client.
  const mesure = pointDeMesure(position);
  const periode = `du ${quand(garde.debut)} au ${quand(garde.fin)}`;
  return {
    content: position
      ? `Les pharmacies de garde les plus proches de vous, ${periode} :`
      : `Les pharmacies de garde ${periode}. Partagez votre position pour voir les plus proches de vous :`,
    summary: { pharmacies_garde: choisies.map(({ p }) => p.nom), periode },
    components: [{
      type: 'commerces_hors_tovo',
      data: {
        items: choisies.map(({ p }) => {
          const nom = `Pharmacie ${p.nom}`;
          return {
            id: `garde:${normaliserIntention(p.nom).replace(/ /g, '-')}`,
            nom,
            type: `De garde · Commune ${p.commune}`,
            icone: 'lieu-pharmacie',
            adresse: p.localisation,
            ...(p.lat !== null && p.lng !== null ? { lat: p.lat, lng: p.lng } : {}),
            distance_m: mesure && p.lat !== null && p.lng !== null ? Math.round(metres(mesure, { lat: p.lat, lng: p.lng })) : null,
            telephone: p.telephone.replace(/(\d{2})(?=\d)/g, '$1 '),
            telephone_appel: `+227${p.telephone}`,
            livreur: {
              label: `Envoyer un livreur à la ${nom}`,
              value: `${prefixeOui}${`Acheter à la ${nom} (${p.localisation})`.replace(/\|/g, ' ').slice(0, 160)}|+227${p.telephone}`,
            },
          };
        }),
        note: HORS_TOVO_GARDE,
      },
    }],
  };
}
