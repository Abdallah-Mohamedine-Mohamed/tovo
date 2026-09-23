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

/**
 * Une envie ou une activité, pas un article : « faire mes courses », « un bon
 * restaurant », « une idée pour ce soir ».
 *
 * Testé sur la requête DÉJÀ extraite (« je cherche du riz » → « riz »), pour
 * que « cherche » ou « veux » ne détournent pas une vraie recherche. Envoyées à
 * la voie rapide, ces phrases devenaient la recherche littérale de « faire mes
 * courses » et le client lisait « introuvable » en touchant une suggestion de
 * l'accueil. Un faux positif ne coûte qu'un passage par le modèle.
 */
export function demandeOuverte(requete: string): boolean {
  return /\b(faire|preparer|aide|aider|conseil|conseille|conseiller|propose|proposer|suggere|suggestion|idee|idees|faim|soif|manger|boire|repas|restaurant|restaurants|resto|restos|courses|quelque|chose|bon|bonne|bons|bonnes|meilleur|meilleure|meilleurs|quoi|trouve|trouver)\b/
    .test(normaliserIntention(requete));
}

/**
 * Le client demande-t-il un livreur, tout court ?
 *
 * « Je veux un livreur », « envoie-moi un coursier », « un livreur svp ».
 * Pas « où est mon livreur » ni « appelle le livreur » (celui d'une commande
 * en cours), ni « je veux devenir livreur ». L'article « un » fait la
 * différence : on demande UN livreur, on parle DU sien.
 */
export function demandeUnLivreur(texte: string): boolean {
  const n = normaliserIntention(texte);
  if (!/\b(un|une|des) (livreur|livreurs|coursier|coursiers|livreuse)\b/.test(n)) return false;
  if (/\b(devenir|travailler|travail|emploi|recrute|recrutez|recrutement|inscrire|inscription|postuler)\b/.test(n)) {
    return false;
  }
  const demande = /\b(veux|voudrais|voulais|besoin|faut|envoie|envoyez|envoyer|trouve|trouvez|appelle|appelez|cherche|cherchez|commande|commander|donne|donnez|svp|stp|vite|urgent)\b/.test(n);
  // « Un livreur » seul, ou presque, est une demande aussi.
  return demande || n.split(' ').length <= 3;
}

/** Envoyer un colis, un paquet, un document. */
export function demandeUnColis(texte: string): boolean {
  const reduit = normaliserIntention(texte);
  const objet = /\b(colis|paquet|document|documents|courrier)\b/.test(reduit);
  const action = /\b(envoyer|livrer|expedier|deposer|remettre|transporter)\b/.test(reduit);
  return objet && action;
}

/** Une phrase sociale ou émotionnelle ne doit jamais devenir un produit. */
export function messageConversationnel(texte: string): boolean {
  const normalise = normaliserIntention(texte);
  return /^(bonjour|bonsoir|salut|merci|ca va|comment vas tu|comment allez vous|coucou|hello|salam|salamalekoum|assalamou)\b/.test(normalise)
    // Les abréviations et acquiescements, seuls : « cc » devenait la
    // recherche du produit « cc » (« Je ne trouve pas de cc »).
    || /^(cc|slt|bjr|bsr|hey|hi|ok|okay|d accord|dac|top|super|parfait|cool)$/.test(normalise)
    || /^(tu es|vous etes|t es)\b/.test(normalise)
    || /\b(stupide|bete|idiot|nulle?|mauvais)\b/.test(normalise);
}

/**
 * Le client désigne-t-il un résultat DÉJÀ affiché plutôt que d'en chercher un ?
 *
 * « Le deuxième », « celui à 2 000 », « ajoute-le », « le même » : ces phrases
 * ne contiennent aucun produit. Envoyées aux voies rapides, elles devenaient
 * une recherche du mot « ajoute » ou « deuxieme », et le client lisait
 * « introuvable » alors qu'il venait de faire son choix.
 *
 * Volontairement large : un faux positif ne coûte qu'un passage par le modèle,
 * qui sait aussi traiter une vraie recherche. L'orchestrateur ne s'en sert que
 * si des résultats ont effectivement été montrés au tour précédent.
 */
export function referenceAuxResultats(texte: string): boolean {
  const n = normaliserIntention(texte);
  if (!n) return false;
  return (
    // Rang : « le deuxième », « la 3e », « le dernier », « le numéro 2 », « le 2 ».
    /\b(premier|premiere|1er|1ere|deuxieme|2e|2eme|second|seconde|troisieme|3e|3eme|quatrieme|4e|4eme|cinquieme|5e|5eme|dernier|derniere)\b/.test(n)
    || /\b(numero|no) [1-8]\b/.test(n)
    || /\b(le|la) [1-8]\b/.test(n)
    // Démonstratifs : « celui-là », « celle à 2 000 ».
    || /\b(celui|celle|ceux|celles)\b/.test(n)
    // Pronom en fin de phrase : « ajoute-le », « prends-la », « mets-les ».
    || /\b(ajoute|ajoutez|ajouter|prends|prenez|prend|mets|mettez|met|garde|gardez|choisis|choisissez|donne|donnez)( moi)? (le|la|les|l)$/.test(n)
    // « je le prends », « je la veux ».
    || /\bje (le|la|les|l) (prends|prend|veux|garde|choisis|commande)\b/.test(n)
    // « je prends ça », « ajoute ça ».
    || /\b(prends|prend|veux|garde|choisis|ajoute|mets|commande) (ca|cela|ceci)\b/.test(n)
    // « le même », « pareil ».
    || /\b(le|la|les) memes?\b/.test(n)
    || /\bpareil\b/.test(n)
    // Superlatif sur ce qui est affiché : « le moins cher », « le plus proche ».
    || /\b(le|la) (moins|plus) (cher|chere|proche|grand|grande|petit|petite)\b/.test(n)
  );
}

/**
 * Le client veut-il reprendre une commande passée ?
 *
 * « Comme d'habitude », « la même chose que la dernière fois » : la demande
 * du client fidèle, le plus précieux. Envoyée aux voies rapides, elle devenait
 * une recherche du produit « d habitude » et répondait « introuvable ». Seul
 * le modèle, avec historique_commandes, sait y répondre.
 */
export function demandeDeCommandePassee(texte: string): boolean {
  const n = normaliserIntention(texte);
  return /\b(comme d habitude|d habitude|comme la derniere fois|la derniere fois|comme hier|comme la semaine derniere)\b/.test(n)
    || /\b(derniere|precedente|ancienne|meme) commande\b/.test(n)
    || /\bcommande (d hier|de la derniere fois|precedente)\b/.test(n)
    || /\b(recommander|recommande|recommandez|reprendre|reprends|reprenez|refaire|refais|refaites) (ma|mes|la|une|ce que|comme)\b/.test(n)
    || /\bmeme chose\b/.test(n)
    // Tap sur « Reprendre : Tacos XL » : la valeur du bouton est
    // « recommander:<uuid> », normalisée ici en « recommander 3a1ab2f3 … ».
    || /\brecommander [0-9a-f]{8}\b/.test(n);
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

  // « un restaurant à Niamey », « un resto près d'ici » : un lieu, pas le nom
  // d'une enseigne. La suggestion d'accueil « Trouve-moi un bon repas à
  // Niamey » répondait « Je ne trouve pas l'enseigne à Niamey ».
  if (/^(?:a|au|aux|en|pres|proche|autour|vers|ici|pas|a cote|dans le coin|du coin|sympa|bien)\b/.test(candidat)) {
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

/**
 * Distance d'édition où deux lettres INVERSÉES comptent pour une seule faute
 * (Damerau, variante « alignement optimal »). C'est la faute la plus
 * fréquente au pouce sur un téléphone : « lina hcips », « petit marhce ».
 * Comptée double, elle faisait échouer la reconnaissance de l'enseigne.
 */
function distanceLevenshtein(a: string, b: string): number {
  if (a === b) return 0;
  if (a.length === 0) return b.length;
  if (b.length === 0) return a.length;

  let avantDerniere: number[] = [];
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
      if (ligne > 1 && colonne > 1 && a[ligne - 1] === b[colonne - 2] && a[ligne - 2] === b[colonne - 1]) {
        courante[colonne] = Math.min(courante[colonne]!, avantDerniere[colonne - 2]! + 1);
      }
    }
    avantDerniere = precedente;
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
  // Le nom doit apparaître en MOTS ENTIERS dans ce que le client a écrit.
  // Espaces retirés, « scenario tacos » devenait « scenariotacos », qui
  // contient « otacos » — une variante légitime d'O'Takoss : l'enseigne
  // demandée se retrouvait noyée parmi trois fausses correspondances.
  if (` ${cibleNormalisee} `.includes(` ${nomNormalise} `)) return 0.98;

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
