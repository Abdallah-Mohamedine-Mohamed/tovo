/**
 * LA MÉMOIRE DE CONVERSATION (étape 4, 09/10, docs/ETAT-DE-PARCOURS.md).
 *
 * Tovo ne gardait que le dernier message : une question au milieu d'une
 * course la faisait oublier (S1), un numéro ajouté perdait le lieu (S2),
 * « le premier » après un merci ne désignait plus rien (S7), une liste de la
 * veille valait encore (S8), et « et un coca » partait chez une autre
 * boutique (S10).
 *
 * La mémoire n'est PAS une copie : elle est RELUE dans la conversation, qui
 * enregistre déjà chaque carte affichée, son contenu et son heure. Rien en
 * double, rien qui puisse s'écraser (une seule source, écrite par chaque
 * réponse). Le panier, les commandes et les prix restent dans leurs tables.
 *
 * Trois choses, et rien d'autre :
 *  - la TÂCHE en cours : une course pas encore commandée (le contenu de sa
 *    dernière carte), ou un repas chez une boutique ;
 *  - l'ÉCRAN : la dernière liste réellement affichée, dans l'ordre de l'écran ;
 *  - au-delà de 6 heures, plus rien ne compte (décision E2 du fondateur).
 *
 * Code pur, sans base ni IA : testé dans tests/unit/conversation.test.ts.
 */

export const DUREE_DE_VIE_MS = 6 * 3_600_000;

/** Un message tel qu'enregistré (table messages). */
export interface Ligne {
  role: string;
  content?: string | null;
  components?: unknown;
  created_at: string;
}

export interface Reference {
  rang: number;
  genre: 'produit' | 'boutique' | 'commerce';
  id: string | null;
  nom: string;
  prix?: number | null;
  boutique?: string | null;
}

export interface Ecran {
  montre_le: string;
  references: Reference[];
}

/** « chez le client » : le client lui-même, pas un lieu. */
export const CHEZ_LE_CLIENT = 'chez le client';

export interface Course {
  depart: string | null;
  arrivee: string | null;
  contact_depart: string | null;
  destinataire: string | null;
  consigne: string | null;
}

export type Tache =
  | { genre: 'course'; depuis: string; course: Course }
  | { genre: 'repas'; depuis: string; boutique: { id: string; nom: string } };

export interface Memoire {
  tache: Tache | null;
  ecran: Ecran | null;
}

type Brut = Record<string, unknown>;
type Composant = { type?: unknown; data?: unknown };

const texte = (v: unknown): string => (typeof v === 'string' ? v.trim() : '');
const composantsDe = (l: Ligne): Composant[] => (Array.isArray(l.components) ? (l.components as Composant[]) : []);
const donnees = (c: Composant): Brut => (c.data && typeof c.data === 'object' ? (c.data as Brut) : {});

const LIEUX_DU_CLIENT = new Set(['', 'chez le client', 'chez vous', 'chez moi', 'position du client', 'ma position actuelle', 'à voir avec le client']);
const estLeClient = (lieu: string) => LIEUX_DU_CLIENT.has(lieu.trim().toLowerCase())
  // « Chez le client · Niamey 2000 » (09/10) : le client, avec son quartier.
  || lieu.trim().toLowerCase().startsWith('chez le client')
  || lieu.trim().toLowerCase().startsWith('position du client');

/** Les éléments affichés, dans l'ordre de l'écran. */
export function referencesDe(components: unknown): Reference[] {
  const refs: Reference[] = [];
  const ajouter = (r: Omit<Reference, 'rang'>) => { if (r.nom) refs.push({ rang: refs.length + 1, ...r }); };
  for (const c of Array.isArray(components) ? (components as Composant[]) : []) {
    const d = donnees(c);
    switch (c.type) {
      case 'merchant_card':
        if (d.choose_branch !== true) ajouter({ genre: 'boutique', id: texte(d.id) || null, nom: texte(d.name) });
        break;
      case 'product_carousel':
      case 'product_list':
        for (const i of Array.isArray(d.items) ? (d.items as Brut[]) : []) {
          ajouter({
            genre: 'produit', id: texte(i.id) || null, nom: texte(i.name),
            prix: typeof i.price === 'number' ? i.price : null, boutique: texte(i.merchant_name) || null,
          });
        }
        break;
      case 'product_card':
      case 'option_selector':
        ajouter({
          genre: 'produit', id: texte(d.id) || texte(d.product_id) || null, nom: texte(d.name) || texte(d.product_name),
          prix: typeof d.price === 'number' ? d.price : typeof d.base_price === 'number' ? d.base_price : null,
        });
        break;
      case 'commerces_hors_tovo':
        for (const i of Array.isArray(d.items) ? (d.items as Brut[]) : []) {
          ajouter({ genre: 'commerce', id: texte(i.id) || null, nom: texte(i.nom) || texte(i.name), boutique: null });
        }
        break;
      default:
        break;
    }
  }
  return refs;
}

/** Le contenu d'une carte de course, anciennes et nouvelles cartes comprises. */
export function courseDeLaCarte(d: Brut): Course {
  const pickup = (d.pickup && typeof d.pickup === 'object' ? d.pickup : {}) as Brut;
  const dropoff = (d.dropoff && typeof d.dropoff === 'object' ? d.dropoff : null) as Brut | null;
  const recuperer = d.mode === 'recuperer';
  const departHint = texte(pickup.hint);
  const arriveeHint = texte(dropoff?.hint);
  const departClient = pickup.chez_moi === true || (pickup.chez_moi === undefined && !recuperer && estLeClient(departHint));
  const arriveeClient = dropoff?.chez_moi === true || (dropoff?.chez_moi === undefined && recuperer);
  return {
    depart: departClient ? CHEZ_LE_CLIENT : departHint || null,
    arrivee: arriveeClient ? CHEZ_LE_CLIENT : arriveeHint && !estLeClient(arriveeHint) ? arriveeHint : null,
    contact_depart: texte(d.pickup_contact) || null,
    destinataire: texte(d.dropoff_contact) || null,
    consigne: texte(d.consigne) || null,
  };
}

/** Une seule boutique dans ce qui est affiché : celle du repas en cours. */
function boutiqueUnique(components: Composant[]): { id: string; nom: string } | null {
  const boutiques = new Map<string, string>();
  for (const c of components) {
    const d = donnees(c);
    if (c.type === 'product_carousel' || c.type === 'product_list') {
      for (const i of Array.isArray(d.items) ? (d.items as Brut[]) : []) {
        if (texte(i.merchant_id)) boutiques.set(texte(i.merchant_id), texte(i.merchant_name));
      }
    }
  }
  if (boutiques.size !== 1) return null;
  const [id, nom] = [...boutiques][0]!;
  return { id, nom };
}

/** Une liste qui n'est pas d'une seule boutique : une autre recherche, le repas en cours s'arrête là. */
const autreRecherche = (components: Composant[]) =>
  components.some((c) => c.type === 'commerces_hors_tovo')
  || (components.some((c) => c.type === 'product_carousel' || c.type === 'product_list') && !boutiqueUnique(components));

/**
 * Relit la mémoire dans les derniers messages (du plus RÉCENT au plus
 * ancien, comme la base les rend). Ce qui a plus de 6 heures ne compte pas.
 */
export function lireConversation(lignes: Ligne[], maintenant: Date = new Date()): Memoire {
  const recentes = lignes.filter((l) => {
    const t = Date.parse(l.created_at);
    return Number.isFinite(t) && maintenant.getTime() - t <= DUREE_DE_VIE_MS;
  });
  let ecran: Ecran | null = null;
  for (const l of recentes) {
    if (l.role !== 'assistant') continue;
    const references = referencesDe(l.components);
    if (references.length > 0) {
      ecran = { montre_le: l.created_at, references };
      break;
    }
  }

  let tache: Tache | null = null;
  for (const l of recentes) {
    if (l.role !== 'assistant') continue;
    const comps = composantsDe(l);
    // Une commande passée ou suivie : la tâche est faite.
    if (comps.some((c) => c.type === 'order_tracking')) break;
    const carte = comps.find((c) => c.type === 'courier_form');
    if (carte) {
      if (donnees(carte).utilise !== true) tache = { genre: 'course', depuis: l.created_at, course: courseDeLaCarte(donnees(carte)) };
      break;
    }
    const boutique = boutiqueUnique(comps);
    if (boutique) {
      tache = { genre: 'repas', depuis: l.created_at, boutique };
      break;
    }
    if (autreRecherche(comps)) break;
  }
  return { tache, ecran };
}

/** Ce que le cerveau lit : la tâche en cours et la dernière liste affichée, en clair. */
export function decrireMemoire(m: Memoire): string {
  const lignes: string[] = [];
  if (m.tache?.genre === 'course') {
    const c = m.tache.course;
    const lieu = (l: string | null) => (l === CHEZ_LE_CLIENT ? 'chez le client' : l ?? 'à préciser');
    lignes.push(
      `Tâche en cours : une COURSE pas encore commandée (sa carte est ouverte). Départ : ${lieu(c.depart)}. Arrivée : ${lieu(c.arrivee)}.`
      + `${c.contact_depart ? ` Numéro sur place : ${c.contact_depart}.` : ''}${c.destinataire ? ` Destinataire : ${c.destinataire}.` : ''}`
      + `${c.consigne ? ` Consigne : ${c.consigne}.` : ''}`
      + ' Un lieu, un numéro ou une consigne que le client ajoute COMPLÈTE cette course (même après une question entre deux).',
    );
  } else if (m.tache?.genre === 'repas') {
    // Pas « une commande » : rien n'est commandé, et le cerveau prenait alors
    // « dites au livreur de m'appeler » pour une réclamation (R6, 09/10).
    lignes.push(`Tâche en cours : le client compose un repas chez « ${m.tache.boutique.nom} » (rien n’est encore commandé). `
      + 'Une précision (« sans oignons », « appelez en arrivant ») va dans la note de la future commande ; '
      + 'un produit demandé se cherche d’abord dans cette boutique.');
  }
  if (m.ecran) {
    const genres = { produit: '', boutique: ' (boutique Tovo)', commerce: ' (commerce hors Tovo)' } as const;
    const liste = m.ecran.references.slice(0, 8).map((r) =>
      `${r.rang}. ${r.nom}${genres[r.genre]}${typeof r.prix === 'number' ? ` — ${r.prix} F` : ''}`).join(' ; ');
    lignes.push(`Dernière liste affichée, dans l’ordre de l’écran (« le premier », « le deuxième », « la moins chère » s’y rapportent) : ${liste}.`);
  }
  return lignes.length ? lignes.join(' ') : 'Aucune tâche en cours, aucune liste affichée depuis moins de 6 heures.';
}

/**
 * Ce que le client vient de dire COMPLÈTE la course en cours : champ par
 * champ, ce qu'il dit remplace l'ancien (décision E3), le reste est gardé.
 */
export function completerCourse(
  course: Course,
  dit: { depart?: string | undefined; arrivee?: string | undefined; telephone?: string | undefined; precision?: string | undefined },
): Course {
  const depart = dit.depart?.trim() || course.depart;
  const arrivee = dit.arrivee?.trim() || course.arrivee;
  const departAilleurs = Boolean(depart && depart !== CHEZ_LE_CLIENT);
  // Un numéro dit : celui de l'endroit où le livreur prend le colis s'il
  // n'est pas chez le client, sinon celui du destinataire.
  const tel = dit.telephone?.trim();
  return {
    depart,
    arrivee,
    contact_depart: tel && departAilleurs ? tel : course.contact_depart,
    destinataire: tel && !departAilleurs ? tel : course.destinataire,
    consigne: dit.precision?.trim() || course.consigne,
  };
}

/** Les arguments de preparer_course pour une course (complétée). */
export function argumentsDeLaCourse(c: Course): Record<string, unknown> {
  const departAilleurs = c.depart && c.depart !== CHEZ_LE_CLIENT ? c.depart : null;
  const arriveeAilleurs = c.arrivee && c.arrivee !== CHEZ_LE_CLIENT ? c.arrivee : null;
  return {
    mode: departAilleurs ? 'recuperer' : 'deposer',
    ...(departAilleurs ? { ou_recuperer: departAilleurs } : {}),
    ...(arriveeAilleurs ? { arrivee: { hint: arriveeAilleurs } } : {}),
    ...(c.contact_depart ? { contact_sur_place: c.contact_depart } : {}),
    ...(c.destinataire ? { destinataire: c.destinataire } : {}),
    ...(c.consigne ? { consigne: c.consigne } : {}),
  };
}
