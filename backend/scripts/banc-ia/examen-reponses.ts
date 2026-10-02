/**
 * L'EXAMEN DES RÉPONSES (02/10) — passé avant chaque livraison.
 *
 *   npx tsx --env-file=.env scripts/banc-ia/examen-reponses.ts
 *
 * Chaque phrase porte, écrit à l'avance, le comportement attendu. Elle passe
 * dans la chaîne réelle (cerveau → recherche → rédacteur / assistant), puis un
 * juge (Gemini Pro) dit si la réponse est CONFORME à l'attendu, la note sur 5,
 * et signale toute invention. Rien n'est livré qui fasse moins bien que la
 * version précédente (le résultat est enregistré pour comparer).
 *
 * Sans effet réel : aucune phrase qui commande, annule, signale ou touche au
 * panier ; chaque phrase dans sa propre conversation de test, supprimée après.
 * Coût : ~0,20 $ par passage.
 */
import { randomUUID } from 'node:crypto';
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { orchestrate } from '../../src/ai/orchestrator.js';
import { comprendre } from '../../src/ai/decideur.js';
import { serviceClient } from '../../src/services/supabase.js';
import type { Component } from '../../src/components/builders.js';

const db = serviceClient();
const POSITION = { lat: 13.52, lng: 2.11 };
const JUGE = 'gemini-3.1-pro-preview';
const DOSSIER = 'scripts/banc-ia/resultats';

interface Question { texte: string; avant?: string; attendu: string }

const EXAMEN: Question[] = [
  // Les captures de l'utilisateur (01–02/10).
  { texte: 'Je voudrais bien manger des merguez', attendu: 'Des plats ou produits AVEC des merguez du catalogue Tovo (Tovo en a). Phrase qui parle de merguez, sans « bien manger ».' },
  { texte: 'On y va sur autre chose. Je veux manger du bon merguez', attendu: 'Des plats ou produits AVEC des merguez du catalogue Tovo. Pas de grillades sans merguez, pas de « je n’ai pas trouvé ».' },
  { texte: 'Haddad Khalil', attendu: 'Haddad Khalil (supermarché) n’est pas sur Tovo : sa carte (où il est, son numéro) et la proposition d’y envoyer un livreur. Aucun quartier ni détail inventé.' },
  { texte: 'Marina market', attendu: 'Marina market n’est pas sur Tovo : dire où il est s’il est connu, ou proposer d’y envoyer un livreur. Jamais « je ne trouve pas de marina market » comme un produit.' },
  { texte: 'Tu es sourd ?', attendu: 'Une réponse brève et aimable à la remarque, qui invite à dire ce qu’il veut. Aucune carte produit, aucun bouton « Reprendre ».' },
  { texte: 'Je cherche de la pommade Nivea', attendu: 'Tovo n’en a pas : les commerces proches qui en ont probablement (pharmacie, supermarché, beauté) avec livreur / numéro. Jamais de produits sans rapport (pomme, boissons).' },
  { texte: 'Quels sont tous les commerces hors de Tovo actuellement ?', attendu: 'Réponse honnête à la question : Tovo ne liste pas tous les commerces, mais peut dire où trouver un produit ou une boutique précise et y envoyer un livreur. Jamais « Voici les boutiques ouvertes » avec des boutiques Tovo.' },
  { texte: 'Je veux commander de la viande chez Tchos', attendu: 'Tchos n’est pas sur Tovo : proposer qu’un livreur aille y acheter de la viande (boutons oui / non). Pas une liste d’autres supermarchés à la place.' },
  { texte: 'Tu peux tout me trouver, c’est cela ?', attendu: 'Explique brièvement ce que Tovo peut faire (repas, courses, colis, livreur, commerces hors Tovo). Si des boutons « Reprendre » apparaissent, ils nomment un produit, jamais « 1000 F », et jamais en double.' },
  // La pertinence : le sens, pas le mot.
  { texte: 'deux litres de lait', attendu: 'Du lait À BOIRE (produits laitiers) du catalogue, ou à défaut les commerces qui en vendent. JAMAIS de savons, crèmes ou cosmétiques « au lait ».' },
  { texte: 'Il me faut un litre d’huile', attendu: 'De l’huile DE CUISINE du catalogue, ou à défaut les commerces qui en vendent. JAMAIS d’huiles pour le corps ou les cheveux.' },
  { texte: 'Avez-vous une autre montre ? Quelle que soit la marque ?', attendu: 'Des montres si Tovo en a ; sinon le dire simplement (et éventuellement des commerces qui en vendent). JAMAIS de boissons ni de produits sans rapport.' },
  { texte: 'Je cherche un livre de cuisine', attendu: 'Tovo n’a pas de livres : le dire simplement. Jamais de plats ou de produits alimentaires à la place.' },
  { texte: 'chargeur iphone', attendu: 'Des chargeurs de téléphone (électronique) si Tovo en a, sinon le dire ou proposer des magasins d’électronique. Jamais de nourriture.' },
  { texte: 'Je cherche des écouteurs', attendu: 'Des écouteurs (électronique) si Tovo en a, sinon le dire ou proposer des magasins d’électronique. Jamais de produits sans rapport.' },
  { texte: 'Je veux du riz', attendu: 'Du riz (sacs de riz, riz à cuire, ou plats de riz) du catalogue.' },
  { texte: 'un sac de sucre de 50 kg', attendu: 'Du sucre du catalogue (ou les commerces qui en vendent). Pas un formulaire de livreur.' },
  { texte: 'un colis de riz de 25 kg', attendu: 'Du riz en sac du catalogue (un « colis de riz » est un produit). PAS le formulaire « Un livreur vient chez vous ».' },
  { texte: 'pizza', attendu: 'Des pizzas du catalogue.' },
  { texte: 'Je veux un gâteau d’anniversaire', attendu: 'Des gâteaux du catalogue, ou à défaut des pâtisseries / boulangeries. Pas de produits sans rapport.' },
  // Boutiques et contexte.
  { texte: 'Otakoss centre aéré', attendu: 'Directement la boutique O’Takoss Centre Aéré (sa carte). Ne PAS redemander de choisir entre les agences : le client l’a dite.' },
  { texte: 'bobiel', avant: 'Dans quel quartier cherchez-vous du poulet ?', attendu: 'Comprendre que Bobiel est le quartier : du poulet (de préférence près de Bobiel). Jamais « je ne trouve pas de bobiel ».' },
  { texte: 'va plus loin que la distance annoncée', avant: 'Je ne trouve pas de pommade à moins de 3 km.', attendu: 'Chercher la POMMADE plus loin : des commerces qui en ont, même au-delà de 3 km. Jamais de pommes ou de produits sans rapport.' },
  { texte: 'Quelles boutiques sont ouvertes ?', attendu: 'Les boutiques Tovo ouvertes en ce moment.' },
  { texte: 'Je veux manger', attendu: 'Les restaurants disponibles, avec une phrase accueillante.' },
  // Bavardage, suivi, Tovo lui-même.
  { texte: 'Le livreur a été très gentil merci', attendu: 'Un remerciement chaleureux et bref. Aucune carte.' },
  { texte: 'Le livreur est en retard', attendu: 'Sans commande en cours : le dire et demander une précision. Jamais de produits ni de boutons « Reprendre ».' },
  { texte: 'Je veux devenir livreur', attendu: 'Réponse honnête et utile à la candidature, sans inventer de démarche, d’adresse ni de numéro. Pas « c’est noté » (rien n’est transmis).' },
  { texte: 'paracétamol', attendu: 'Tovo n’en vend pas : les pharmacies proches (de garde si c’est la nuit), avec numéro / livreur. Aucun conseil médical.' },
  { texte: 'Bonjour', attendu: 'Une salutation brève qui invite à demander. S’il y a des boutons « Reprendre », ils nomment un produit, sans doublon.' },
];

const { data: compte } = await db.from('conversations').select('user_id').order('created_at', { ascending: false }).limit(1).single();
const userId = compte!.user_id as string;

/** Ce que voit le client : chaque carte et ses éléments (nom, prix, boutique). */
function cartes(composants: Component[]): string {
  return composants.map((c) => {
    const d = c.data as Record<string, unknown>;
    const items = Array.isArray(d.items) ? (d.items as Array<Record<string, unknown>>) : [];
    const noms = items.slice(0, 6).map((i) => [
      i.name ?? i.nom ?? i.label, i.merchant_name ?? i.type, i.adresse,
      i.telephone ? `tél. ${i.telephone}` : null, i.livreur ? 'bouton Envoyer un livreur' : null,
      typeof i.distance_m === 'number' ? `${i.distance_m} m` : null,
    ].filter(Boolean).join(' — ')).join(' ; ');
    // Le total RÉEL trouvé : sans lui, le juge prenait « 21 options » pour
    // une invention parce qu'il ne voyait que les premières cartes.
    const parcourir = d.browse as { total?: unknown } | undefined;
    const total = typeof parcourir?.total === 'number' ? parcourir.total : typeof d.total === 'number' ? d.total : items.length;
    return `${c.type}${d.name ? ` « ${d.name} »` : ''}${noms ? ` [${noms}${total > 6 ? ` … ${total} trouvés en tout (le reste en faisant défiler)` : ''}]` : ''}`;
  }).join(' | ') || 'aucune carte';
}

async function repondre(q: Question) {
  const { data: conv } = await db.from('conversations').insert({ user_id: userId }).select('id').single();
  const conversationId = conv!.id as string;
  try {
    if (q.avant) await db.from('messages').insert({ conversation_id: conversationId, role: 'assistant', content: q.avant });
    const debut = Date.now();
    // Comme la route : l'intention ET le produit compris par le cerveau.
    const d = await comprendre(q.texte, { avant: q.avant ?? null });
    const r = await orchestrate({
      db, userId, conversationId, clientMessageId: randomUUID(), message: q.texte, position: POSITION,
      ...(d.intention ? { intention: d.intention } : {}),
      ...(d.produit ? { requete: d.produit } : {}),
      ...(d.rayon ? { rayon: d.rayon } : {}),
    });
    return { reponse: r.content, cartes: cartes(r.components), ms: Date.now() - debut, intention: d.intention, produit: d.produit ?? null };
  } catch (e) {
    return { reponse: `ERREUR : ${(e as Error).message.slice(0, 160)}`, cartes: '', ms: 0, intention: null, produit: null };
  } finally {
    await db.from('messages').delete().eq('conversation_id', conversationId);
    await db.from('conversations').delete().eq('id', conversationId);
  }
}

type Note = { conforme: boolean; note: number; invention: boolean; raison: string };

/** Le juge, relancé s'il ne répond pas (3 essais). */
async function juger(q: Question, r: { reponse: string; cartes: string }): Promise<Note | null> {
  for (let essai = 0; essai < 3; essai++) {
    const n = await jugerUneFois(q, r);
    if (n) return n;
  }
  return null;
}

async function jugerUneFois(q: Question, r: { reponse: string; cartes: string }): Promise<Note | null> {
  const consigne = [
    'Tu juges la réponse de Tovo (livraison à Niamey : repas, courses, colis, livreurs, commerces hors Tovo) à un message de client.',
    'Sous le texte, l’application affiche les cartes décrites. On te donne le COMPORTEMENT ATTENDU, écrit à l’avance.',
    '« conforme » : true seulement si la réponse (texte ET cartes) fait ce qui est attendu et ne fait rien de ce qui est interdit.',
    '« note » de 1 à 5 : utilité réelle pour ce client. « invention » : true si elle affirme un fait qu’elle ne peut pas savoir.',
    'Réponds en JSON : {"conforme": bool, "note": n, "invention": bool, "raison": "une phrase"}.',
  ].join('\n');
  const entree = JSON.stringify({
    ...(q.avant ? { dernier_message_de_tovo: q.avant } : {}),
    heure_a_niamey: new Date(Date.now() + 3_600_000).toISOString().slice(11, 16),
    message_du_client: q.texte, comportement_attendu: q.attendu,
    reponse: { texte: r.reponse, cartes: r.cartes },
  });
  const rep = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${JUGE}:generateContent`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-goog-api-key': process.env.GEMINI_API_KEY! },
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: consigne }] },
      contents: [{ role: 'user', parts: [{ text: entree }] }],
      generationConfig: { temperature: 0, responseMimeType: 'application/json', maxOutputTokens: 2048, thinkingConfig: { thinkingLevel: 'low' } },
    }),
  }).catch(() => null);
  // Quota du jour épuisé chez Google (250 requêtes, vu le 02/10) : le MÊME
  // modèle par OpenRouter, pour que les notes restent comparables.
  if (rep?.status === 429 && process.env.OPENROUTER_API_KEY) {
    const relais = await fetch('https://openrouter.ai/api/v1/chat/completions', {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${process.env.OPENROUTER_API_KEY}` },
      body: JSON.stringify({
        model: `google/${JUGE}`, temperature: 0, max_tokens: 2048, reasoning: { effort: 'low' },
        response_format: { type: 'json_object' },
        messages: [{ role: 'system', content: consigne }, { role: 'user', content: entree }],
      }),
    }).catch(() => null);
    if (!relais?.ok) return null;
    const c = (await relais.json()) as { choices?: Array<{ message?: { content?: string } }> };
    const brut = c.choices?.[0]?.message?.content ?? '';
    try { return JSON.parse(brut.match(/\{[\s\S]*\}/)?.[0] ?? '') as Note; } catch { return null; }
  }
  if (!rep?.ok) return null;
  const corps = (await rep.json()) as { candidates?: Array<{ content?: { parts?: Array<{ text?: string; thought?: boolean }> } }> };
  const texte = corps.candidates?.[0]?.content?.parts?.filter((p) => !p.thought).map((p) => p.text ?? '').join('') ?? '';
  try { return JSON.parse(texte) as Note; } catch { return null; }
}

const resultats: Array<Record<string, unknown>> = [];
const file = [...EXAMEN];
await Promise.all(Array.from({ length: 4 }, async () => {
  for (let q = file.shift(); q; q = file.shift()) {
    const r = await repondre(q);
    const n = await juger(q, r);
    resultats.push({ ...q, ...r, ...(n ?? { conforme: null, note: null, invention: null, raison: 'juge indisponible' }) });
    process.stdout.write(n?.conforme ? '✓' : '✗');
  }
}));
resultats.sort((a, b) => EXAMEN.findIndex((q) => q.texte === a.texte) - EXAMEN.findIndex((q) => q.texte === b.texte));

// Une phrase que le juge n'a pas pu noter ne compte ni pour ni contre.
const n = resultats.filter((r) => r.conforme !== null).length;
const nonJugees = resultats.length - n;
if (nonJugees) console.log(`\n\n${nonJugees} phrase(s) non jugée(s) : exclues du score.`);
// Trop de phrases sans note : le score ne veut plus rien dire (évaluation externe, 02/10).
if (n < Math.ceil(resultats.length * 0.9)) {
  console.log(`⚠️ Seulement ${n} / ${resultats.length} phrases jugées : passage NON VALABLE, non enregistré. À relancer.`);
  process.exit(1);
}
const conformes = resultats.filter((r) => r.conforme === true).length;
const notes = resultats.map((r) => Number(r.note)).filter((x) => x > 0);
const temps = resultats.map((r) => Number(r.ms)).sort((a, b) => a - b);
const resume = {
  conformes, total: n,
  note: Number((notes.reduce((s, x) => s + x, 0) / notes.length).toFixed(2)),
  inventions: resultats.filter((r) => r.invention === true).length,
  mediane_ms: temps[Math.floor(temps.length / 2)], p95_ms: temps[Math.min(temps.length - 1, Math.floor(0.95 * temps.length))],
};

// La version précédente, pour comparer.
const precedents = readdirSync(DOSSIER).filter((f) => f.startsWith('examen-')).sort();
const precedent = precedents.length ? JSON.parse(readFileSync(`${DOSSIER}/${precedents.at(-1)}`, 'utf8')) as { resume: typeof resume; resultats: Array<{ texte: string; conforme: boolean }> } : null;

console.log(`\n\nConformes : ${conformes} / ${n}${precedent ? `   (avant : ${precedent.resume.conformes} / ${precedent.resume.total})` : ''}`);
console.log(`Note moyenne : ${resume.note} / 5${precedent ? `   (avant : ${precedent.resume.note})` : ''}`);
console.log(`Inventions : ${resume.inventions}${precedent ? `   (avant : ${precedent.resume.inventions})` : ''}`);
console.log(`Temps : médiane ${resume.mediane_ms} ms, 95 % ${resume.p95_ms} ms${precedent ? `   (avant : ${precedent.resume.mediane_ms} / ${precedent.resume.p95_ms})` : ''}`);
if (precedent) {
  const avant = new Map(precedent.resultats.map((r) => [r.texte, r.conforme]));
  const gagnes = resultats.filter((r) => r.conforme && avant.get(r.texte as string) === false).map((r) => r.texte);
  const perdus = resultats.filter((r) => r.conforme === false && avant.get(r.texte as string) === true).map((r) => r.texte);
  console.log(`Nouvelles réussites : ${gagnes.length ? gagnes.join(' · ') : 'aucune'}`);
  console.log(`RÉGRESSIONS : ${perdus.length ? perdus.join(' · ') : 'aucune'}`);
}
console.log('\nNon conformes :');
for (const r of resultats.filter((x) => x.conforme !== true)) console.log(`  ✗ « ${r.texte} » — ${r.raison}`);

mkdirSync(DOSSIER, { recursive: true });
const fichier = `${DOSSIER}/examen-${new Date().toISOString().slice(0, 16).replace(/[:T]/g, '-')}.json`;
writeFileSync(fichier, JSON.stringify({ resume, resultats }, null, 1));
console.log(`\nDétail : ${fichier}`);
