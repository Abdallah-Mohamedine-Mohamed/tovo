/**
 * La salle de contrôle de l'admin (02/11) : ce qu'il faut voir et faire,
 * maintenant.
 *
 * Les données brutes viennent d'une seule lecture (migration 0089,
 * admin_salle_controle) ; ici, les RÈGLES : quelle commande devient une
 * alerte, depuis quand, avec quel geste pour la régler. Une fonction pure,
 * testée : l'écran n'invente rien.
 *
 * Pourquoi c'est la priorité avant le lancement : dans l'ancienne
 * application, les boutiques ne répondaient pas à 78 conversations sur 80 et
 * 21 % des commandes finissaient annulées. Une commande qui dérape doit se
 * voir en minutes, pas le lendemain.
 */

export interface Historique { status: string; le: string }

export interface CommandeBrute {
  id: string;
  type: string;
  status: string;
  total: number;
  delivery_fee: number;
  placed_at: string;
  delivered_at: string | null;
  scheduled_for: string | null;
  cancelled_reason: string | null;
  dropoff_hint: string | null;
  lat: number | null;
  lng: number | null;
  merchant_id: string | null;
  driver_id: string | null;
  client_nom: string | null;
  client_tel: string | null;
  historique: Historique[];
}

export interface BoutiqueBrute { id: string; nom: string; tel: string | null; lat: number; lng: number; ouverte: boolean }

export interface LivreurBrut {
  id: string; nom: string | null; tel: string | null;
  en_ligne: boolean; disponible: boolean; vu_le: string | null;
  lat: number | null; lng: number | null;
}

export interface SignalementBrut {
  id: string; message: string; le: string; order_id: string | null;
  client_nom: string | null; client_tel: string | null;
}

export interface DonneesBrutes {
  commandes: CommandeBrute[];
  boutiques: BoutiqueBrute[];
  livreurs: LivreurBrut[];
  signalements: SignalementBrut[];
}

/** Au-delà, une commande non acceptée ou sans livreur devient une alerte. */
export const SEUIL_ALERTE_MIN = 5;
/** Une commande qui dure plus d'une heure est signalée (aucune heure promise n'est enregistrée). */
export const SEUIL_LONGUE_MIN = 60;

const TERMINEES = new Set(['delivered', 'cancelled']);

/** Les cinq étapes que l'écran dessine : reçue, acceptée, prête, en route, livrée. */
export function etapeDe(status: string): number {
  switch (status) {
    case 'pending': return 0;
    case 'confirmed': case 'preparing': return 1;
    case 'ready': return 2;
    case 'assigned': case 'picked_up': case 'delivering': return 3;
    case 'delivered': return 4;
    default: return 0;
  }
}

const LIBELLE_STATUT: Record<string, string> = {
  pending: 'Reçue · pas encore acceptée',
  confirmed: 'Acceptée par la boutique',
  preparing: 'En préparation',
  ready: 'Prête · en attente d’un livreur',
  assigned: 'Livreur en route vers la boutique',
  picked_up: 'Récupérée par le livreur',
  delivering: 'En route vers le client',
  delivered: 'Livrée',
  cancelled: 'Annulée',
};

const minutes = (de: string | null | undefined, a: number): number =>
  de ? Math.max(0, Math.floor((a - Date.parse(de)) / 60_000)) : 0;

/** Depuis quand la commande est dans son statut actuel (historique, sinon la commande). */
function depuisLeStatut(c: CommandeBrute): string {
  const dernier = [...c.historique].reverse().find((h) => h.status === c.status);
  return dernier?.le ?? c.placed_at;
}

/** Le premier passage à « acceptée », pour le délai d'acceptation de la boutique. */
function accepteeLe(c: CommandeBrute): string | null {
  return c.historique.find((h) => h.status !== 'pending' && h.status !== 'cancelled')?.le ?? null;
}

export function mediane(valeurs: number[]): number | null {
  if (!valeurs.length) return null;
  const v = [...valeurs].sort((a, b) => a - b);
  const m = Math.floor(v.length / 2);
  return v.length % 2 ? v[m]! : Math.round((v[m - 1]! + v[m]!) / 2);
}

/** Distance à vol d'oiseau, en mètres. */
export function distanceM(a: { lat: number; lng: number }, b: { lat: number; lng: number }): number {
  const r = 6_371_000, rad = Math.PI / 180;
  const dLat = (b.lat - a.lat) * rad, dLng = (b.lng - a.lng) * rad;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLng / 2) ** 2;
  return 2 * r * Math.asin(Math.sqrt(h));
}

const km = (m: number) => `${(m / 1000).toFixed(1).replace('.', ',')} km`;
const francs = (n: number) => `${Math.round(n).toLocaleString('fr-FR').replace(/\s/g, ' ')} F`;

export type Gravite = 'rouge' | 'orange' | 'gris';

export interface Alerte {
  id: string;
  type: 'pas_acceptee' | 'sans_livreur' | 'longue' | 'signalement';
  gravite: Gravite;
  titre: string;
  detail: string;
  depuis_min: number;
  commande_id: string | null;
  /** Le geste qui règle le problème : un numéro à appeler, ou une page à ouvrir. */
  action: { libelle: string; tel?: string | null; page?: string };
}

/** Une commande programmée pour plus tard ne doit pas sonner avant son heure. */
function programmeePlusTard(c: CommandeBrute, maintenant: number): boolean {
  return !!c.scheduled_for && Date.parse(c.scheduled_for) - maintenant > 45 * 60_000;
}

export function construireSalle(donnees: DonneesBrutes, maintenant: number, debutJour: number) {
  const boutiques = new Map(donnees.boutiques.map((b) => [b.id, b]));
  const livreurs = new Map(donnees.livreurs.map((l) => [l.id, l]));
  const nomBoutique = (c: CommandeBrute) =>
    c.merchant_id ? boutiques.get(c.merchant_id)?.nom ?? 'Boutique' : 'Course';
  const lieu = (c: CommandeBrute) => (c.dropoff_hint ?? '').split(',')[0]?.trim() || 'adresse non précisée';
  const client = (c: CommandeBrute) => (c.client_nom ?? '').trim().split(/\s+/)[0] || 'Client';

  const duJour = donnees.commandes.filter((c) => Date.parse(c.placed_at) >= debutJour);
  const actives = donnees.commandes.filter((c) => !TERMINEES.has(c.status) && !programmeePlusTard(c, maintenant));
  const livrees = duJour.filter((c) => c.status === 'delivered');
  const annulees = duJour.filter((c) => c.status === 'cancelled');
  const enLigne = donnees.livreurs.filter((l) => l.en_ligne);
  const libres = enLigne.filter((l) => l.disponible);

  // ---- Les alertes ------------------------------------------------------------
  const alertes: Alerte[] = [];
  for (const c of actives) {
    const depuis = minutes(depuisLeStatut(c), maintenant);
    const age = minutes(c.placed_at, maintenant);
    const b = c.merchant_id ? boutiques.get(c.merchant_id) : undefined;
    if (c.status === 'pending' && c.merchant_id && depuis >= SEUIL_ALERTE_MIN) {
      alertes.push({
        id: `pas_acceptee:${c.id}`, type: 'pas_acceptee', commande_id: c.id, depuis_min: depuis,
        gravite: depuis >= 2 * SEUIL_ALERTE_MIN ? 'rouge' : 'orange',
        titre: 'Pas acceptée par la boutique',
        detail: `${nomBoutique(c)} n’a pas répondu à la commande de ${client(c)} (${lieu(c)}, ${francs(c.total)}).`,
        action: { libelle: 'Appeler la boutique', tel: b?.tel ?? null },
      });
    } else if (c.status === 'ready' && depuis >= SEUIL_ALERTE_MIN) {
      const plusProche = b
        ? libres.filter((l) => l.lat !== null && l.lng !== null)
          .map((l) => distanceM(b, { lat: l.lat!, lng: l.lng! }))
          .sort((x, y) => x - y).at(0)
        : undefined;
      alertes.push({
        id: `sans_livreur:${c.id}`, type: 'sans_livreur', commande_id: c.id, depuis_min: depuis,
        gravite: depuis >= 2 * SEUIL_ALERTE_MIN ? 'rouge' : 'orange',
        titre: 'Aucun livreur trouvé',
        detail: `${nomBoutique(c)} : commande prête pour ${client(c)}. `
          + (plusProche === undefined ? 'Aucun livreur libre en ligne.' : `Le livreur libre le plus proche est à ${km(plusProche)}.`),
        action: { libelle: 'Assigner un livreur', page: '/dispatch' },
      });
    } else if (age >= SEUIL_LONGUE_MIN) {
      const l = c.driver_id ? livreurs.get(c.driver_id) : undefined;
      alertes.push({
        id: `longue:${c.id}`, type: 'longue', commande_id: c.id, depuis_min: age,
        gravite: 'gris',
        titre: 'Commande longue',
        detail: `${nomBoutique(c)} → ${lieu(c)} : passée il y a ${age} min, ${LIBELLE_STATUT[c.status]?.toLowerCase() ?? c.status}`
          + (l?.nom ? ` (${l.nom.split(/\s+/)[0]}).` : '.'),
        action: { libelle: 'Prévenir le client', tel: c.client_tel },
      });
    }
  }
  for (const s of donnees.signalements) {
    const depuis = minutes(s.le, maintenant);
    alertes.push({
      id: `signalement:${s.id}`, type: 'signalement', commande_id: s.order_id, depuis_min: depuis,
      gravite: depuis >= 30 ? 'rouge' : 'orange',
      titre: 'Client en attente de réponse',
      detail: `${(s.client_nom ?? 'Un client').split(/\s+/)[0]} : « ${s.message.length > 110 ? `${s.message.slice(0, 107)}…` : s.message} »`,
      action: { libelle: 'Répondre', page: '/signalements' },
    });
  }
  const rang: Record<Gravite, number> = { rouge: 0, orange: 1, gris: 2 };
  alertes.sort((a, b) => rang[a.gravite] - rang[b.gravite] || b.depuis_min - a.depuis_min);
  const enAlerte = new Set(alertes.map((a) => a.commande_id).filter(Boolean));

  // ---- Les chiffres du jour --------------------------------------------------------
  const durees = livrees.filter((c) => c.delivered_at).map((c) => minutes(c.placed_at, Date.parse(c.delivered_at!)));
  const motifs = new Map<string, number>();
  for (const c of annulees) {
    const m = (c.cancelled_reason ?? 'sans motif').trim().toLowerCase();
    motifs.set(m, (motifs.get(m) ?? 0) + 1);
  }
  const chiffres = {
    commandes: duJour.length,
    en_cours: actives.length,
    en_cours_a_traiter: actives.filter((c) => enAlerte.has(c.id)).length,
    livrees: livrees.length,
    duree_mediane_min: mediane(durees),
    annulees: annulees.length,
    motifs_annulation: [...motifs].sort((a, b) => b[1] - a[1]).map(([motif, nombre]) => ({ motif, nombre })),
    chiffre_affaires: livrees.reduce((s, c) => s + c.total, 0),
    livraison: livrees.reduce((s, c) => s + c.delivery_fee, 0),
    livreurs_en_ligne: enLigne.length,
    livreurs_total: donnees.livreurs.length,
    livreurs_libres: libres.length,
  };

  // ---- Les commandes en cours -------------------------------------------------------
  const enCours = actives
    .map((c) => ({
      id: c.id,
      boutique: nomBoutique(c),
      client: client(c),
      lieu: lieu(c),
      total: c.total,
      etape: etapeDe(c.status),
      statut: LIBELLE_STATUT[c.status] ?? c.status,
      livreur: c.driver_id ? livreurs.get(c.driver_id)?.nom ?? null : null,
      age_min: minutes(c.placed_at, maintenant),
      en_alerte: enAlerte.has(c.id),
    }))
    .sort((a, b) => Number(b.en_alerte) - Number(a.en_alerte) || b.age_min - a.age_min);

  // ---- Les boutiques ------------------------------------------------------------------
  const parBoutique = new Map<string, CommandeBrute[]>();
  for (const c of duJour) if (c.merchant_id) parBoutique.set(c.merchant_id, [...(parBoutique.get(c.merchant_id) ?? []), c]);
  const tableBoutiques = donnees.boutiques
    .filter((b) => parBoutique.has(b.id) || b.ouverte)
    .map((b) => {
      const siennes = parBoutique.get(b.id) ?? [];
      const delais = siennes.map((c) => { const a = accepteeLe(c); return a ? minutes(c.placed_at, Date.parse(a)) : null; })
        .filter((d): d is number => d !== null);
      const silence = alertes.find((a) => a.type === 'pas_acceptee' && siennes.some((c) => c.id === a.commande_id));
      return {
        id: b.id,
        nom: b.nom,
        ouverte: b.ouverte,
        commandes: siennes.length,
        delai_acceptation_min: mediane(delais),
        annulees: siennes.filter((c) => c.status === 'cancelled').length,
        note: silence ? `Ne répond pas depuis ${silence.depuis_min} min` : null,
      };
    })
    .sort((a, b) => Number(!!b.note) - Number(!!a.note) || b.commandes - a.commandes || a.nom.localeCompare(b.nom, 'fr'));

  // ---- Les livreurs ---------------------------------------------------------------------
  const coursesDuJour = new Map<string, number>();
  for (const c of livrees) if (c.driver_id) coursesDuJour.set(c.driver_id, (coursesDuJour.get(c.driver_id) ?? 0) + 1);
  const enCourse = new Map<string, CommandeBrute>();
  for (const c of actives) if (c.driver_id) enCourse.set(c.driver_id, c);
  const tableLivreurs = donnees.livreurs
    .map((l) => {
      const course = enCourse.get(l.id);
      const etat = !l.en_ligne ? 'hors_ligne' : course ? 'en_course' : 'libre';
      return {
        id: l.id,
        nom: l.nom ?? 'Livreur',
        tel: l.tel,
        etat,
        detail: etat === 'en_course' ? `${nomBoutique(course!)} → ${lieu(course!)}`
          : etat === 'libre' ? 'Libre'
            : l.vu_le ? `Hors ligne depuis ${minutes(l.vu_le, maintenant)} min` : 'Hors ligne',
        courses_du_jour: coursesDuJour.get(l.id) ?? 0,
      };
    })
    .sort((a, b) => ['en_course', 'libre', 'hors_ligne'].indexOf(a.etat) - ['en_course', 'libre', 'hors_ligne'].indexOf(b.etat)
      || b.courses_du_jour - a.courses_du_jour);

  // ---- La carte -------------------------------------------------------------------------
  const carte = {
    commandes: actives.filter((c) => c.lat !== null && c.lng !== null).map((c) => {
      const b = c.merchant_id ? boutiques.get(c.merchant_id) : undefined;
      return {
        id: c.id, lat: c.lat!, lng: c.lng!, en_alerte: enAlerte.has(c.id),
        depart: b ? { lat: b.lat, lng: b.lng } : null,
        titre: `${nomBoutique(c)} → ${lieu(c)}`,
      };
    }),
    // Seulement les boutiques qui ont travaillé aujourd'hui : toutes les ouvertes
    // couvraient la carte de carrés noirs (capture du 02/11).
    boutiques: donnees.boutiques.filter((b) => parBoutique.has(b.id) || actives.some((c) => c.merchant_id === b.id))
      .map((b) => ({ id: b.id, nom: b.nom, lat: b.lat, lng: b.lng, ouverte: b.ouverte })),
    livreurs: tableLivreurs.filter((l) => l.etat !== 'hors_ligne').map((l) => {
      const brut = livreurs.get(l.id)!;
      return brut.lat === null || brut.lng === null ? null : { id: l.id, nom: l.nom, lat: brut.lat, lng: brut.lng, en_course: l.etat === 'en_course' };
    }).filter(Boolean),
  };

  return { chiffres, alertes, en_cours: enCours, boutiques: tableBoutiques, livreurs: tableLivreurs, carte };
}

/** Minuit à Niamey (UTC+1, sans heure d'été), en millisecondes. */
export function debutDuJourANiamey(maintenant: number): number {
  const decalage = 3_600_000;
  const local = new Date(maintenant + decalage);
  return Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate()) - decalage;
}
