export function normaliserIntention(texte: string): string {
  return texte
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .trim()
    .replace(/\s+/g, ' ');
}

const MOTS_RECHERCHE_VIDES = new Set([
  'a', 'ai', 'as', 'au', 'aux', 'autre', 'autres', 'avez', 'avoir',
  'catalogue', 'ce', 'cherche', 'chercher', 'commande', 'commander',
  'de', 'des', 'disponible', 'disponibles', 'donne', 'donnez', 'du',
  'en', 'est', 'il', 'importe', 'j', 'je', 'la', 'le', 'les', 'marque',
  'manger', 'moi', 'nous', 'ou', 'pour', 'prendre', 'produit', 'produits',
  'qu', 'que', 'quel', 'quelle', 'quelles', 'quels', 'quoi', 'recherche',
  'rechercher', 'soit', 'souhaite', 'svp', 'toutes', 'tous', 'trouve',
  'trouver', 'tu', 'un', 'une', 'veut', 'veux', 'voir', 'voudrais', 'vous',
  'y', 'acheter', 'article', 'articles', 'mais', 'c', 'ca', 'cela',
]);

/**
 * Les mots réellement demandés par le client, sans laisser le modèle les
 * remplacer par des synonymes ou des catégories supposées.
 *
 * « De la pommade » devient `pommade`, « avez-vous une autre montre ? »
 * devient `montre`. En revanche, `montre` reste intact quand il désigne
 * l'objet ; seul « montre-moi » est reconnu comme un verbe d'interface.
 */
export function requeteProduitUtilisateur(texte: string): string {
  let normalise = normaliserIntention(texte);
  normalise = normalise.replace(/^montre(?:z)? moi\b/, '').trim();
  const correction = normalise.lastIndexOf('en fait ');
  if (correction >= 0) normalise = normalise.slice(correction + 'en fait '.length);
  const mots = normalise
    .split(' ')
    .filter(Boolean)
    .filter((mot) => !MOTS_RECHERCHE_VIDES.has(mot))
    .filter((mot) => !['envie', 'dans', 'votre', 'comme', 'commander'].includes(mot));
  return (correction >= 0 ? [...new Set(mots)] : mots).join(' ');
}

/** Une phrase sociale ou émotionnelle ne doit jamais devenir un produit. */
export function messageConversationnel(texte: string): boolean {
  const normalise = normaliserIntention(texte);
  return /^(bonjour|bonsoir|salut|merci|ca va|comment vas tu|comment allez vous)\b/.test(normalise)
    || /^(tu es|vous etes|t es)\b/.test(normalise)
    || /\b(stupide|bete|idiot|nulle?|mauvais)\b/.test(normalise);
}

export function demandeDeRepas(texte: string): boolean {
  const normalise = normaliserIntention(texte);
  return /\b(manger|mange|faim|repas|restaurant|restaurants|resto|restos|plat|plats|dejeuner|diner|cuisine)\b/.test(
    normalise,
  );
}

export function demandeDeProximite(texte: string): boolean {
  const normalise = normaliserIntention(texte);
  return /\b(proche|proches|proximite|autour|alentours|coin|quartier|distance)\b/.test(
    normalise,
  );
}

export function demandeBoutiqueOuverte(texte: string): boolean {
  const normalise = normaliserIntention(texte);
  return /\b(boutique|boutiques|enseigne|enseignes|commerce|commerces|restaurant|restaurants|resto|restos)\b/.test(normalise)
    && /\b(ouvert|ouverte|ouverts|ouvertes|presentement|maintenant|actuellement)\b/.test(normalise);
}

export function nomBoutiqueApresMarqueur(texte: string): string | null {
  const normalise = normaliserIntention(texte);
  const marqueurs = [...normalise.matchAll(/\b(?:chez|boutique|enseigne|restaurant|resto)\b/g)];
  const marqueur = marqueurs.at(-1);
  const candidat = marqueur
    ? normalise.slice(marqueur.index + marqueur[0].length).trim()
      .split(/\b(?:en fait|je veux|j ai|qu est ce)\b/)[0]?.trim() ?? null
    : null;
  if (!candidat) return null;

  if (/^(?:en fait|un|une|des|du|de|la|le|les|que|qui|ou|pour|dans)\b/.test(candidat)) {
    return null;
  }

  // « une boutique ouverte présentement » décrit un besoin, pas une
  // enseigne appelée « ouverte présentement ». Si une enseigne suit « sur »,
  // on ne conserve que son vrai nom : « boutique ouverte sur Otakoss ».
  if (/^(?:ouvert|ouverte|ouverts|ouvertes)\b/.test(candidat)) {
    return candidat.match(/\bsur\s+(.+)$/)?.[1] ?? null;
  }

  return candidat;
}

const MOTS_REPAS_GENERAUX = new Set([
  'a',
  'ai',
  'aimerais',
  'bon',
  'de',
  'des',
  'du',
  'faim',
  'j',
  'je',
  'la',
  'le',
  'les',
  'mange',
  'manger',
  'maintenant',
  'moi',
  'on',
  'plat',
  'plats',
  'quelque',
  'quoi',
  'repas',
  'restaurant',
  'restaurants',
  'resto',
  'restos',
  'souhaite',
  'svp',
  'trouver',
  'un',
  'une',
  'veux',
  'voudrais',
]);

export function demandeGeneraleDeRepas(texte: string): boolean {
  if (!demandeDeRepas(texte)) return false;

  const motsSpecifiques = normaliserIntention(texte)
    .split(' ')
    .filter(Boolean)
    .filter((mot) => !MOTS_REPAS_GENERAUX.has(mot));

  return motsSpecifiques.length === 0;
}

function distanceLevenshtein(a: string, b: string): number {
  if (a === b) return 0;
  if (a.length === 0) return b.length;
  if (b.length === 0) return a.length;

  let precedente = Array.from({ length: b.length + 1 }, (_, index) => index);

  for (let ligne = 1; ligne <= a.length; ligne++) {
    const courante = [ligne];
    for (let colonne = 1; colonne <= b.length; colonne++) {
      const cout = a[ligne - 1] === b[colonne - 1] ? 0 : 1;
      courante[colonne] = Math.min(
        courante[colonne - 1]! + 1,
        precedente[colonne]! + 1,
        precedente[colonne - 1]! + cout,
      );
    }
    precedente = courante;
  }

  return precedente[b.length]!;
}

function scoreNomBoutique(saisi: string, catalogue: string): number {
  const cibleNormalisee = normaliserIntention(saisi);
  const nomNormalise = normaliserIntention(catalogue);
  const cible = cibleNormalisee.replace(/ /g, '');
  const nom = nomNormalise.replace(/ /g, '');
  const nomEnseigne = normaliserIntention(catalogue.replace(/\([^)]*\)/g, '')).replace(/ /g, '');
  if (cible.length < 3 || nom.length < 3) return 0;

  if (cible === nom) return 1;
  const phonetique = (valeur: string) => valeur
    .replace(/qu/g, 'k')
    .replace(/c(?=[aou])/g, 'k')
    .replace(/(.)\1+/g, '$1');
  if (cible.length >= 5 && phonetique(cible) === phonetique(nomEnseigne)) return 0.97;
  if (nom.includes(cible)) return 0.99;
  if (cible.includes(nom)) return 0.98;

  let meilleur = 1 - distanceLevenshtein(cible, nom) / Math.max(cible.length, nom.length);

  // « Garda d'Or dans le coin » : les mots de contexte ne doivent pas
  // diluer la seule faute qui compte. On compare aussi chaque fenêtre ayant
  // le même nombre de mots que le nom du catalogue.
  const motsCible = cibleNormalisee.split(' ');
  const motsNom = nomNormalise.split(' ');
  if (motsCible.length >= motsNom.length) {
    for (let debut = 0; debut <= motsCible.length - motsNom.length; debut++) {
      const fenetre = motsCible.slice(debut, debut + motsNom.length).join('');
      const score = 1 - distanceLevenshtein(fenetre, nom) / Math.max(fenetre.length, nom.length);
      meilleur = Math.max(meilleur, score);
    }
  }

  return meilleur;
}

export function boutiquesCorrespondantes<T extends { id: string; name: string }>(
  nomSaisi: string,
  boutiques: T[],
): T[] {
  const classees = boutiques
    .map((boutique) => ({ boutique, score: scoreNomBoutique(nomSaisi, boutique.name) }))
    .sort((a, b) => b.score - a.score);

  const meilleur = classees[0]?.score ?? 0;
  if (meilleur < 0.82) return [];

  return classees
    .filter(({ score }) => score >= meilleur - 0.02)
    .map(({ boutique }) => boutique);
}

export function boutiquesMentionnees<T extends { id: string; name: string }>(
  message: string,
  boutiques: T[],
): T[] {
  const normalise = normaliserIntention(message);
  if (!normalise) return [];

  // Apres « chez », « boutique » ou « restaurant », le client est en train
  // de nommer une enseigne. On conserve alors la tolerance aux apostrophes
  // et aux petites fautes de frappe du rapprochement existant.
  const apresMarqueur = nomBoutiqueApresMarqueur(message);
  if (apresMarqueur) return boutiquesCorrespondantes(apresMarqueur, boutiques);

  // Une enseigne composee ecrite en entier est une intention forte, meme
  // au milieu d'une phrase : « les plats de GARBA D'OR » ne doit jamais
  // devenir une recherche globale sur le mot « garba ». Pour un nom d'un
  // seul mot, on exige en revanche une formulation sans vocabulaire de
  // repas : sinon une boutique POULET capturerait « manger du poulet ».
  const exactes = boutiques.filter((boutique) => {
    const nom = normaliserIntention(boutique.name);
    const nomCompose = nom.split(' ').length > 1;
    return nom.length >= 5 && nomCompose && normalise.includes(nom);
  });
  if (exactes.length > 0) return exactes;

  // Un message court sans vocabulaire de repas est souvent simplement le
  // nom de la boutique (« Garba d'or », « Garda d'or »). En revanche,
  // « je veux manger du poulet » ne doit surtout pas se verrouiller sur une
  // boutique qui s'appellerait POULET.
  if (!demandeDeRepas(message) && normalise.split(' ').length <= 6) {
    return boutiquesCorrespondantes(message, boutiques).filter(
      (boutique) => normaliserIntention(boutique.name).split(' ').length > 1,
    );
  }

  return [];
}
