import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { EXECUTORS } from '../../src/ai/tools.js';
import { cleanup, createUser, type TestUser } from '../rls/harness.js';

/**
 * L'outil qui permet à l'assistant de demander « je livre chez vous ? ».
 *
 * Ici l'adresse postale n'existe pas : on se repère par des indices, longs
 * à retaper sur un clavier de téléphone. Sans cet outil, l'assistant ne peut
 * que renvoyer le client vers un formulaire vide à chaque commande.
 */
describe('Outil mes_adresses', () => {
  let client: TestUser;
  let sansAdresse: TestUser;

  const contexte = (u: TestUser) => ({ db: u.db, userId: u.id });

  beforeAll(async () => {
    [client, sansAdresse] = await Promise.all([createUser('client'), createUser('client')]);

    await client.db.rpc('save_address', {
      p_label: 'Maison',
      p_text_hint: 'Yantala, derrière la pharmacie Al Nour',
      p_lat: 13.529,
      p_lng: 2.087,
      p_is_default: true,
    });
    await client.db.rpc('save_address', {
      p_label: 'Bureau',
      p_text_hint: 'Plateau, immeuble bleu',
      p_lat: 13.5137,
      p_lng: 2.1098,
      p_is_default: false,
    });
  }, 120_000);

  afterAll(cleanup);

  it('remonte les adresses, celle par défaut en tête', async () => {
    const sortie = await EXECUTORS['mes_adresses']!({}, contexte(client));
    const resume = sortie.summary as { adresses: Array<Record<string, unknown>> };

    expect(resume.adresses).toHaveLength(2);
    expect(resume.adresses[0]?.libelle).toBe('Maison');
    expect(resume.adresses[0]?.par_defaut).toBe(true);
    // Le repère complet part au modèle : c'est lui qui porte le sens.
    expect(resume.adresses[0]?.repere).toContain('Al Nour');
  }, 60_000);

  it('propose des boutons courts, pas le repère entier', async () => {
    // « Livrer à Maison » tient dans un bouton ; « Livrer à Yantala,
    // derrière la pharmacie Al Nour » déborde et devient illisible.
    const sortie = await EXECUTORS['mes_adresses']!({}, contexte(client));
    const boutons = (sortie.components[0]?.data as { items: Array<Record<string, string>> }).items;

    expect(sortie.components[0]?.type).toBe('quick_replies');
    expect(boutons[0]?.label).toBe('Livrer à Maison');
    expect(boutons[0]?.value).toMatch(/^adresse:[0-9a-f-]{36}$/);
    // Une porte de sortie, toujours : le client peut livrer ailleurs.
    expect(boutons.at(-1)).toEqual({ label: 'Ailleurs', value: 'adresse:nouvelle' });
  }, 60_000);

  it('ne voit pas les adresses des autres', async () => {
    // La RLS s'applique : l'outil reçoit le client Supabase du client, pas
    // la clé de service. Un manquement ici exposerait où habitent les gens.
    const sortie = await EXECUTORS['mes_adresses']!({}, contexte(sansAdresse));
    expect((sortie.summary as { adresses: number }).adresses).toBe(0);
    expect(sortie.components).toHaveLength(0);
  }, 60_000);

  it('reste muet quand il n’y a rien à proposer', async () => {
    // Sans composant, l'assistant n'affiche pas un sélecteur vide : il
    // laisse simplement le formulaire de commande demander la position.
    const sortie = await EXECUTORS['mes_adresses']!({}, contexte(sansAdresse));
    expect(sortie.components).toEqual([]);
  }, 60_000);
});
