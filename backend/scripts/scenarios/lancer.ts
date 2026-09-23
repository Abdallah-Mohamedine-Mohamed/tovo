/**
 * Rejoue les scénarios contre un serveur Tovo branché sur la base de TEST.
 *
 *   Terminal 1 : npm run dev:staging          (serveur local sur .env.staging)
 *   Terminal 2 : npm run scenarios            (tous)
 *                npm run scenarios -- tacos   (ceux dont le nom contient « tacos »)
 *
 * Crée un client de test, joue chaque scénario dans une conversation neuve
 * avec un panier vide, puis supprime le client. Code de sortie 1 si un
 * scénario échoue. Refuse de tourner sur la production (garde.ts).
 */
import { randomUUID } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';
import { exigerStaging } from './garde.js';
import { SCENARIOS, type Attendu, type Contexte } from './scenarios.js';

const { url, anon, service } = exigerStaging();
const API = (process.env.SCENARIO_API ?? 'http://localhost:3000').replace(/\/$/, '');
const NIAMEY = { lat: 13.5137, lng: 2.1098 };
const filtre = process.argv[2]?.toLowerCase();

const admin = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });

// Un client neuf par exécution : aucun historique ne fausse « comme d'habitude ».
const email = `scenario-${randomUUID()}@tovo.test`;
const motDePasse = randomUUID();
const { data: cree, error: erreurCreation } = await admin.auth.admin.createUser({
  email, password: motDePasse, email_confirm: true, user_metadata: { full_name: 'Client Scénario' },
});
if (erreurCreation || !cree.user) throw new Error(`création du client de test : ${erreurCreation?.message}`);
const session = await createClient(url, anon, { auth: { persistSession: false } })
  .auth.signInWithPassword({ email, password: motDePasse });
if (!session.data.session) throw new Error(`connexion du client de test : ${session.error?.message}`);
const jeton = session.data.session.access_token;

interface Reponse { statut: number; texte: string; composants: Array<{ type: string; data?: Record<string, unknown> }>; conversation?: string }

async function appeler(methode: string, chemin: string, corps?: unknown): Promise<Reponse> {
  const res = await fetch(`${API}${chemin}`, {
    method: methode,
    headers: { authorization: `Bearer ${jeton}`, ...(corps === undefined ? {} : { 'content-type': 'application/json' }) },
    body: corps === undefined ? undefined : JSON.stringify(corps),
    signal: AbortSignal.timeout(60_000),
  });
  const json = (await res.json().catch(() => ({}))) as Record<string, unknown>;
  return {
    statut: res.status,
    texte: String(json.content ?? json.error ?? ''),
    composants: (json.components as Reponse['composants'] | undefined) ?? [],
    conversation: json.conversation_id as string | undefined,
  };
}

function verifier(r: Reponse, a: Attendu): string[] {
  const types = r.composants.map((c) => c.type);
  const fautes: string[] = [];
  if (a.statut !== undefined && r.statut !== a.statut) fautes.push(`statut ${r.statut}, attendu ${a.statut}`);
  if (a.statut === undefined && r.statut >= 400) fautes.push(`statut ${r.statut}`);
  for (const t of a.composants ?? []) if (!types.includes(t)) fautes.push(`composant « ${t} » absent`);
  for (const t of a.sansComposants ?? []) if (types.includes(t)) fautes.push(`composant « ${t} » présent`);
  if (a.texte && !a.texte.test(r.texte)) fautes.push(`texte sans ${a.texte}`);
  if (a.sansTexte && a.sansTexte.test(r.texte)) fautes.push(`texte contient ${a.sansTexte}`);
  return fautes;
}

let echecs = 0;
const scenarios = SCENARIOS.filter((s) => !filtre || s.nom.toLowerCase().includes(filtre));

try {
  for (const s of scenarios) {
    await appeler('DELETE', '/cart');
    const ctx: Contexte = {};
    let conversation: string | undefined;
    const lignes: string[] = [];
    let ok = true;

    for (const etape of s.etapes) {
      const debut = performance.now();
      let r: Reponse;
      let libelle: string;
      if ('dire' in etape) {
        libelle = `« ${etape.dire} »`;
        r = await appeler('POST', '/chat', {
          client_message_id: randomUUID(),
          ...(conversation ? { conversation_id: conversation } : {}),
          text: etape.dire,
          ...(etape.position ? { context: NIAMEY } : {}),
        });
        conversation = r.conversation ?? conversation;
      } else {
        const q = etape.requete(ctx);
        libelle = `${q.methode} ${q.chemin}`;
        r = await appeler(q.methode, q.chemin, q.corps);
      }
      const suivi = r.composants.find((c) => c.type === 'order_tracking');
      if (suivi?.data?.order_id) ctx.commande = String(suivi.data.order_id);

      const fautes = verifier(r, etape.attendu);
      const ms = Math.round(performance.now() - debut);
      if (fautes.length) {
        ok = false;
        lignes.push(`   ✗ ${libelle} (${ms} ms) : ${fautes.join(' ; ')}`);
        lignes.push(`     réponse : « ${r.texte.slice(0, 160)} » [${r.composants.map((c) => c.type).join(', ')}]`);
        break; // la suite dépend de cette étape
      }
      lignes.push(`   ✓ ${libelle} (${ms} ms)`);
    }

    if (!ok) echecs++;
    console.log(`${ok ? '✓' : '✗'} ${s.nom}`);
    if (!ok) console.log(`   protège : ${s.protege}`);
    for (const l of lignes) console.log(l);
  }
} finally {
  // Commandes d'abord : elles bloquent la suppression du compte (on delete
  // restrict), et aucun livreur ne doit les voir traîner.
  await admin.from('orders').delete().eq('user_id', cree.user.id);
  const { error } = await admin.auth.admin.deleteUser(cree.user.id);
  if (error) console.log(`⚠ Client de test non supprimé (${error.message}) : npm run staging:nettoyer`);
}

console.log(`\n${scenarios.length - echecs}/${scenarios.length} scénarios réussis.`);
process.exit(echecs ? 1 : 0);
