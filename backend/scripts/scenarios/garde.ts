import { readFileSync } from 'node:fs';

/**
 * Garde-fou : les scénarios ÉCRIVENT (comptes, paniers, commandes). Ils ne
 * tournent QUE sur le projet Supabase de test, jamais sur la production.
 *
 * Deux verrous indépendants :
 *   1. TOVO_ENV=staging doit figurer dans .env.staging ;
 *   2. l'URL Supabase chargée doit DIFFÉRER de celle de backend/.env
 *      (la production), relue sur disque.
 * Aucune URL ni clé n'est affichée.
 */
export function exigerStaging(): { url: string; anon: string; service: string } {
  const url = process.env.SUPABASE_URL ?? '';
  const anon = process.env.SUPABASE_ANON_KEY ?? '';
  const service = process.env.SUPABASE_SERVICE_ROLE_KEY ?? '';

  if (process.env.TOVO_ENV !== 'staging') {
    throw new Error('Refus : TOVO_ENV=staging absent. Lancez avec --env-file=.env.staging.');
  }
  if (!url || !anon || !service) {
    throw new Error('Refus : SUPABASE_URL, SUPABASE_ANON_KEY ou SUPABASE_SERVICE_ROLE_KEY manquant dans .env.staging.');
  }

  let production = '';
  try {
    production = readFileSync('.env', 'utf8').match(/^SUPABASE_URL=(.*)$/m)?.[1]?.trim() ?? '';
  } catch {
    // Pas de .env : aucune production à confondre.
  }
  if (production && production.replace(/\/$/, '') === url.replace(/\/$/, '')) {
    // Tant que Tovo n'est pas lancé, la base de .env est une base de
    // développement : le fondateur l'autorise explicitement. À RETIRER de
    // .env.staging le jour où cette base sert de vrais clients.
    if (process.env.TOVO_AUTORISER_BASE_DEV !== 'oui') {
      throw new Error('Refus : .env.staging pointe sur le même projet Supabase que .env (la production).');
    }
    console.log('⚠ Base de .env utilisée (autorisée : TOVO_AUTORISER_BASE_DEV=oui).');
  }
  return { url, anon, service };
}
