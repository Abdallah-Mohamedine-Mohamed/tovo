/**
 * Transformations 6ammart → Tovo.
 *
 * Fonctions pures, sans base ni réseau : c'est ici que se concentrent les
 * risques d'erreur silencieuse — un polygone mal lu place une zone au
 * mauvais endroit, un prix mal converti fausse une facturation. Elles sont
 * donc testées séparément du chargement.
 */

// ---------------------------------------------------------------------
// Géométrie
// ---------------------------------------------------------------------

/**
 * Décode un polygone MySQL en WKT.
 *
 * MySQL stocke ses géométries en WKB précédé de 4 octets de SRID — un
 * en-tête maison qui n'existe pas dans le WKB standard. C'est le piège de
 * ce format : le lire comme du WKB pur décale tout d'un mot de 4 octets et
 * produit des coordonnées absurdes, sans erreur.
 *
 * @param hex chaîne `0x0000000001030000...` telle qu'écrite par mysqldump
 */
export function polygoneVersWkt(hex: string): string | null {
  const propre = hex.trim().replace(/^0x/i, '');
  if (propre.length < 50) return null;

  const octets = Buffer.from(propre, 'hex');

  // Lecture bornée : un polygone tronqué doit être écarté, pas faire
  // tomber la migration. Buffer lève une exception si l'on dépasse, ce qui
  // interromprait le chargement au milieu d'un lot.
  let pos = 4; // 4 octets de SRID, puis le WKB standard
  let deborde = false;

  const dispo = (n: number): boolean => {
    if (pos + n > octets.length) {
      deborde = true;
      return false;
    }
    return true;
  };

  if (!dispo(1)) return null;
  const petitBoutiste = octets.readUInt8(pos) === 1;
  pos += 1;

  const lireU32 = (): number => {
    if (!dispo(4)) return 0;
    const v = petitBoutiste ? octets.readUInt32LE(pos) : octets.readUInt32BE(pos);
    pos += 4;
    return v;
  };
  const lireDouble = (): number => {
    if (!dispo(8)) return 0;
    const v = petitBoutiste ? octets.readDoubleLE(pos) : octets.readDoubleBE(pos);
    pos += 8;
    return v;
  };

  const type = lireU32();
  if (deborde || type !== 3) return null; // 3 = Polygon

  const anneaux: string[] = [];
  const nbAnneaux = lireU32();
  if (deborde || nbAnneaux < 1 || nbAnneaux > 100) return null;

  for (let a = 0; a < nbAnneaux; a++) {
    const nbPoints = lireU32();
    if (deborde || nbPoints < 4 || nbPoints > 10000) return null;

    const points: string[] = [];
    for (let p = 0; p < nbPoints; p++) {
      const x = lireDouble();
      const y = lireDouble();
      if (deborde) return null;
      // Ordre WKB standard : X = longitude, Y = latitude, et WKT attend le
      // même. Je les avais inversés ; le contrôle de plausibilité l'a
      // signalé en plaçant toutes les zones hors du Niger.
      points.push(`${x} ${y}`);
    }
    anneaux.push(`(${points.join(', ')})`);
  }

  return deborde ? null : `POLYGON(${anneaux.join(', ')})`;
}

/**
 * Vérifie qu'un polygone tombe bien sur le Niger.
 *
 * Garde-fou contre une inversion de coordonnées passée inaperçue : le Niger
 * s'étend d'environ 0° à 16° est et de 11° à 24° nord.
 */
export function polygoneEstPlausible(wkt: string): boolean {
  const paires = [...wkt.matchAll(/(-?\d+\.?\d*)\s+(-?\d+\.?\d*)/g)];
  if (paires.length === 0) return false;

  return paires.every(([, lng, lat]) => {
    const x = Number(lng);
    const y = Number(lat);
    return x >= -2 && x <= 18 && y >= 10 && y <= 25;
  });
}

// ---------------------------------------------------------------------
// Téléphones
// ---------------------------------------------------------------------

/**
 * Normalise un numéro au format E.164, exigé par Supabase Auth.
 *
 * Les numéros du dump sont déjà préfixés `+227` dans leur immense majorité,
 * mais on ne s'y fie pas : un seul numéro mal formé fait échouer la création
 * du compte, et l'utilisateur ne pourra jamais se connecter.
 */
export function normaliserTelephone(brut: string | null): string | null {
  if (!brut) return null;

  const chiffres = brut.replace(/[^\d+]/g, '');
  if (chiffres.startsWith('+')) {
    return chiffres.length >= 11 && chiffres.length <= 16 ? chiffres : null;
  }

  // Numéro nigérien sans indicatif : 8 chiffres.
  if (chiffres.length === 8) return `+227${chiffres}`;
  if (chiffres.startsWith('227') && chiffres.length === 11) return `+${chiffres}`;

  return null;
}

// ---------------------------------------------------------------------
// Options de produits
// ---------------------------------------------------------------------

export interface OptionTransformee {
  nom: string;
  obligatoire: boolean;
  minSelect: number;
  maxSelect: number;
  valeurs: { nom: string; supplement: number }[];
}

interface VariationBrute {
  name?: string;
  type?: string;
  min?: number | string;
  max?: number | string;
  required?: string | boolean;
  values?: { label?: string; optionPrice?: string | number }[];
}

/**
 * Convertit les variations 6ammart en options Tovo.
 *
 * Le format source :
 *   [{"name":"VIANDES","type":"single","required":"on",
 *     "values":[{"label":"Poulet","optionPrice":"600"}]}]
 *
 * Deux pièges. `required` vaut la chaîne `"on"` et non un booléen — un test
 * de véracité naïf rendrait TOUTES les options obligatoires, y compris
 * celles où `required` est absent. Et `min`/`max` valent souvent 0 même sur
 * un choix unique obligatoire ; on les recalcule d'après `type`.
 */
export function transformerOptions(json: string | null): OptionTransformee[] {
  if (!json || json.trim() === '' || json.trim() === '[]') return [];

  let brut: unknown;
  try {
    brut = JSON.parse(json);
  } catch {
    return [];
  }
  if (!Array.isArray(brut)) return [];

  const options: OptionTransformee[] = [];

  for (const v of brut as VariationBrute[]) {
    const nom = (v.name ?? '').trim();
    if (!nom) continue;

    const valeurs = (v.values ?? [])
      .map((val) => ({
        nom: (val.label ?? '').trim(),
        supplement: Math.max(0, Math.round(Number(val.optionPrice ?? 0))),
      }))
      .filter((val) => val.nom.length > 0);

    // Une option sans valeur rendrait le produit incommandable : la base
    // refuse l'ajout au panier tant qu'une option obligatoire n'est pas
    // satisfiable. Mieux vaut ne pas la créer.
    if (valeurs.length === 0) continue;

    const multiple = (v.type ?? 'single').toLowerCase() !== 'single';
    const obligatoire = v.required === 'on' || v.required === true;

    options.push({
      nom,
      obligatoire,
      minSelect: obligatoire ? Math.max(1, Number(v.min ?? 0) || 1) : 0,
      maxSelect: multiple
        ? Math.max(Number(v.max ?? 0) || valeurs.length, 1)
        : 1,
      valeurs,
    });
  }

  return options;
}

interface ChoixBrut {
  title?: string;
  options?: string[];
}

interface VarianteBrute {
  type?: string;
  price?: number | string;
  stock?: number | string;
}

/** Résultat d'une conversion de variantes e-commerce. */
export interface VariantesTransformees {
  /** Prix de base à écrire sur le produit — il peut changer, voir plus bas. */
  prix: number;
  options: OptionTransformee[];
}

/** `« 1/2kg avec os »` et `« 1/2kgavecos »` désignent la même variante. */
function cleVariante(s: string): string {
  return s.replace(/\s+/g, '').toLowerCase();
}

/**
 * Convertit les variantes e-commerce en options Tovo.
 *
 * Format source, en deux morceaux qu'il faut recoller :
 *   choice_options : [{"title":"Quantité","options":["1/2Kg"," 1Kg"]}]
 *   variations     : [{"type":"1/2Kg","price":1750},{"type":"1Kg","price":3500}]
 *
 * Le piège central : `price` est le prix ABSOLU de la variante, pas un
 * supplément. « Viande de bœuf » affiche 3 000 F mais ses variantes valent
 * 1 250 à 3 000 F. Tovo, lui, additionne un prix de base et des suppléments.
 * On reconstruit donc : prix de base = la variante la moins chère, et chaque
 * supplément = l'écart à celle-ci. Le client paie exactement le même montant
 * qu'avant.
 *
 * L'exception qui rendrait des produits gratuits : quand 6ammart n'a pas de
 * prix par variante il écrit 0. Prendre ce 0 comme prix de base offrirait le
 * produit. Dès qu'un prix manque, on considère donc que ce ne sont pas des
 * prix absolus, on garde le prix du produit et les valeurs deviennent de
 * simples suppléments.
 *
 * @returns null si la structure est inattendue — au chargeur de le signaler
 *          pour reprise manuelle plutôt que d'inventer un prix.
 */
export function transformerVariantes(
  choiceOptionsJson: string | null,
  variationsJson: string | null,
  prixBase: number,
): VariantesTransformees | null {
  if (!choiceOptionsJson || choiceOptionsJson.trim() === '' || choiceOptionsJson.trim() === '[]') {
    return null;
  }

  let choix: ChoixBrut[];
  let variantes: VarianteBrute[];
  try {
    choix = JSON.parse(choiceOptionsJson) as ChoixBrut[];
    variantes = JSON.parse(variationsJson ?? '[]') as VarianteBrute[];
  } catch {
    return null;
  }

  // Tous les produits du dump n'ont qu'un attribut. Au-delà, les prix
  // portent sur des combinaisons (« Rouge + XL ») que le modèle de Tovo ne
  // sait pas représenter : mieux vaut refuser que fausser une facturation.
  if (!Array.isArray(choix) || choix.length !== 1 || !Array.isArray(variantes)) return null;

  const attribut = choix[0];
  const libelles = (attribut?.options ?? []).map((o) => o.trim()).filter((o) => o.length > 0);
  if (libelles.length === 0) return null;

  const prixParCle = new Map<string, number>();
  for (const v of variantes) {
    if (!v.type) continue;
    prixParCle.set(cleVariante(v.type), Math.max(0, Math.round(Number(v.price ?? 0))));
  }

  const prixTrouves = libelles.map((l) => prixParCle.get(cleVariante(l)));
  const absolus = prixTrouves.every((p) => p !== undefined && p > 0);

  const plancher = absolus ? Math.min(...(prixTrouves as number[])) : 0;

  return {
    prix: absolus ? plancher : prixBase,
    options: [
      {
        nom: (attribut?.title ?? 'Choix').trim() || 'Choix',
        obligatoire: true,
        minSelect: 1,
        maxSelect: 1,
        valeurs: libelles.map((nom, i) => ({
          nom,
          supplement: Math.max(0, (prixTrouves[i] ?? 0) - plancher),
        })),
      },
    ],
  };
}

// ---------------------------------------------------------------------
// Montants
// ---------------------------------------------------------------------

/**
 * Convertit un prix 6ammart en entier XOF.
 *
 * 6ammart stocke des décimaux ; le franc CFA n'a pas de subdivision. On
 * arrondit à l'entier le plus proche plutôt que de tronquer — tronquer
 * 1499,99 donnerait 1499 et ferait perdre un franc au boutiquier à chaque
 * vente.
 */
export function versXof(brut: string | null): number {
  const n = Number(brut ?? 0);
  return Number.isFinite(n) ? Math.max(0, Math.round(n)) : 0;
}

/**
 * Nom complet à partir des deux champs 6ammart.
 *
 * Beaucoup de comptes n'ont qu'un prénom. Renvoyer une chaîne vide plutôt
 * qu'un « null null » qui finirait affiché dans l'app.
 */
export function nomComplet(prenom: string | null, nom: string | null): string {
  return [prenom, nom]
    .map((p) => (p ?? '').trim())
    .filter((p) => p.length > 0 && p.toLowerCase() !== 'null')
    .join(' ');
}

/**
 * Délai de préparation en minutes.
 *
 * 6ammart écrit des chaînes libres : « 30-40 », « 20 min », « 1 heure ».
 * On prend le premier nombre trouvé, avec une valeur par défaut plausible.
 */
export function delaiPreparation(brut: string | null): number {
  const trouve = /(\d+)/.exec(brut ?? '');
  const n = trouve ? Number(trouve[1]) : 0;
  return n >= 5 && n <= 180 ? n : 20;
}

/**
 * Stock réellement suivi, ou null.
 *
 * Les boutiquiers écrivent 999999 pour dire « illimité ». Le reprendre tel
 * quel afficherait « 999999 en stock » dans l'app ; et `null` a justement le
 * sens « stock non suivi » côté Tovo.
 */
export function stockUtile(brut: string | null): number | null {
  const n = Number(brut ?? '');
  if (!Number.isFinite(n) || n <= 0 || n >= 10000) return null;
  return Math.round(n);
}

/**
 * Identifiant d'URL lisible, unique grâce au suffixe.
 *
 * Deux catégories peuvent porter le même nom dans deux modules différents
 * (« Boissons » chez les restaurants et à l'épicerie) ; le slug étant unique
 * en base, le suffixe évite un échec de chargement à mi-parcours.
 */
export function slug(nom: string, suffixe: string): string {
  const base = nom
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '') // accents décomposés par NFD
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60);
  return `${base || 'categorie'}-${suffixe}`;
}
