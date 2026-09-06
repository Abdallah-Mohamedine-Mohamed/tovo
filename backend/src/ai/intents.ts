export function normaliserIntention(texte: string): string {
  return texte
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .trim()
    .replace(/\s+/g, ' ');
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

export function nomBoutiqueApresMarqueur(texte: string): string | null {
  return normaliserIntention(texte).match(
    /\b(?:chez|boutique|enseigne|restaurant|resto)\s+(.+)$/,
  )?.[1] ?? null;
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
  if (cible.length < 3 || nom.length < 3) return 0;

  if (cible === nom) return 1;
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
