import { createReadStream } from 'node:fs';
import { createInterface } from 'node:readline';

/**
 * Lecteur de dump MySQL, en flux.
 *
 * Le dump fait 65 Mo et 127 tables. Le charger en mémoire pour en extraire
 * six tables serait absurde ; on le parcourt ligne à ligne et on ne retient
 * que ce qui est demandé.
 *
 * Les insertions de mysqldump s'étalent sur plusieurs lignes : une première
 * ligne `INSERT INTO ... VALUES` puis des lignes de continuation commençant
 * par `(`. C'est ce qui a faussé mes premiers comptages — ne lire que la
 * première ligne donnait « 1 boutique » là où il y en a 81.
 */

export type Row = Record<string, string | null>;

/** Découpe un tuple SQL en valeurs, en respectant les échappements. */
function decouperTuple(tuple: string): (string | null)[] {
  const valeurs: (string | null)[] = [];
  let courant = '';
  let dansChaine = false;
  let echappe = false;

  for (let i = 0; i < tuple.length; i++) {
    const c = tuple[i]!;

    if (echappe) {
      // mysqldump échappe \' \" \\ \n \r \0 et \Z
      courant += c === 'n' ? '\n' : c === 'r' ? '\r' : c === '0' ? '\0' : c;
      echappe = false;
      continue;
    }

    if (c === '\\' && dansChaine) {
      echappe = true;
      continue;
    }

    if (c === "'") {
      // Deux apostrophes consécutives à l'intérieur d'une chaîne : une
      // apostrophe littérale, pas une fermeture.
      if (dansChaine && tuple[i + 1] === "'") {
        courant += "'";
        i++;
        continue;
      }
      dansChaine = !dansChaine;
      continue;
    }

    if (c === ',' && !dansChaine) {
      valeurs.push(normaliser(courant));
      courant = '';
      continue;
    }

    courant += c;
  }

  valeurs.push(normaliser(courant));
  return valeurs;
}

function normaliser(brut: string): string | null {
  const t = brut.trim();
  return t === 'NULL' || t === '' ? null : t;
}

/**
 * Découpe la partie VALUES d'une insertion en tuples.
 *
 * On ne peut pas se contenter de couper sur `),(` : une description de
 * produit peut très bien contenir cette séquence. Il faut suivre l'état de
 * la chaîne.
 */
function extraireTuples(segment: string, sortie: string[]): void {
  let profondeur = 0;
  let debut = -1;
  let dansChaine = false;
  let echappe = false;

  for (let i = 0; i < segment.length; i++) {
    const c = segment[i]!;

    if (echappe) {
      echappe = false;
      continue;
    }
    if (c === '\\' && dansChaine) {
      echappe = true;
      continue;
    }
    if (c === "'") {
      if (dansChaine && segment[i + 1] === "'") {
        i++;
        continue;
      }
      dansChaine = !dansChaine;
      continue;
    }
    if (dansChaine) continue;

    if (c === '(') {
      if (profondeur === 0) debut = i + 1;
      profondeur++;
    } else if (c === ')') {
      profondeur--;
      if (profondeur === 0 && debut >= 0) {
        sortie.push(segment.slice(debut, i));
        debut = -1;
      }
    }
  }
}

export interface ParseResult {
  /** Lignes par table, dans l'ordre du dump. */
  tables: Map<string, Row[]>;
  /** Colonnes déclarées par table. */
  colonnes: Map<string, string[]>;
}

/**
 * Extrait les tables demandées.
 *
 * @param chemin  fichier .sql
 * @param voulues noms de tables à retenir ; tout le reste est ignoré
 */
export async function parseDump(
  chemin: string,
  voulues: Set<string>,
): Promise<ParseResult> {
  const tables = new Map<string, Row[]>();
  const colonnes = new Map<string, string[]>();

  const flux = createInterface({
    input: createReadStream(chemin, { encoding: 'utf8' }),
    crlfDelay: Infinity,
  });

  let tableCourante: string | null = null;

  for await (const ligne of flux) {
    const debutInsert = /^INSERT INTO `([a-z_0-9]+)` \(([^)]+)\) VALUES/.exec(ligne);

    if (debutInsert) {
      const nom = debutInsert[1]!;
      if (!voulues.has(nom)) {
        tableCourante = null;
        continue;
      }

      tableCourante = nom;
      if (!colonnes.has(nom)) {
        colonnes.set(
          nom,
          debutInsert[2]!.split(',').map((c) => c.trim().replace(/`/g, '')),
        );
        tables.set(nom, []);
      }

      ajouter(ligne.slice(debutInsert[0].length), nom, tables, colonnes);
      continue;
    }

    if (tableCourante && ligne.startsWith('(')) {
      ajouter(ligne, tableCourante, tables, colonnes);
      continue;
    }

    // Toute autre instruction termine l'insertion en cours.
    if (/^(INSERT|CREATE|ALTER|DROP|LOCK|UNLOCK|--|\/\*)/.test(ligne)) {
      tableCourante = null;
    }
  }

  return { tables, colonnes };
}

function ajouter(
  segment: string,
  table: string,
  tables: Map<string, Row[]>,
  colonnes: Map<string, string[]>,
): void {
  const tuples: string[] = [];
  extraireTuples(segment, tuples);

  const noms = colonnes.get(table)!;
  const lignes = tables.get(table)!;

  for (const tuple of tuples) {
    const valeurs = decouperTuple(tuple);
    // Une ligne dont le nombre de valeurs ne correspond pas aux colonnes
    // signale un défaut de lecture. On la signale plutôt que de l'insérer
    // décalée — une erreur silencieuse ici décalerait tout un catalogue.
    if (valeurs.length !== noms.length) {
      throw new Error(
        `${table} : ${valeurs.length} valeurs pour ${noms.length} colonnes`,
      );
    }
    const ligne: Row = {};
    noms.forEach((nom, i) => {
      ligne[nom] = valeurs[i] ?? null;
    });
    lignes.push(ligne);
  }
}
