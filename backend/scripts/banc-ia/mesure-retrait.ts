/**
 * Mesure par familles (10/10) : l'action que le client demande, quelle que
 * soit l'origine de la commande dont il parle. Chaque phrase passe 6 fois (3 ne suffisaient pas : le même code donnait 3/3 puis 1/3) ;
 * « tuiles » = le cerveau n'est pas sûr d'une action coûteuse (Tovo demande).
 *
 *   npx tsx --env-file=.env scripts/banc-ia/mesure-retrait.ts avant
 *   npx tsx --env-file=.env scripts/banc-ia/mesure-retrait.ts apres avant   → compare, phrase par phrase
 */
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { comprendre } from '../../src/ai/decideur.js';

const ESSAIS = 6;
const COURSE = ['livreur', 'colis'];
const COUTEUSES = new Set(['livreur', 'colis', 'annuler', 'habitude']);
type Cas = { p: string; attendu: string[]; depart?: string };

const FAMILLES: Record<string, Cas[]> = {
  'Demandes évidentes de livreur (jamais de clarification)': [
    { p: 'Je veux un livreur', attendu: COURSE },
    { p: 'Je veux envoyer un livreur.', attendu: COURSE },
    { p: 'Envoie-moi un livreur', attendu: COURSE },
    { p: 'Il me faut un coursier maintenant', attendu: COURSE },
    { p: "J'ai un paquet à envoyer à Yantala", attendu: COURSE },
  ],
  "Retraits d'un achat fait hors de Tovo": [
    { p: "J'ai commandé chez Boba, envoie un livreur récupérer ma commande", attendu: COURSE, depart: 'boba' },
    { p: "Va me chercher ma commande chez French Tacos, je l'ai déjà payée", attendu: COURSE, depart: 'french tacos' },
    { p: "J'ai déjà payé mon repas chez Garba d'Or, il faut juste aller le chercher", attendu: COURSE, depart: 'garba' },
    { p: "Ma commande est prête chez O'Takoss, quelqu'un peut aller la récupérer ?", attendu: COURSE, depart: 'takoss' },
    { p: "J'ai commandé par téléphone au Radisson, envoyez un livreur la prendre", attendu: COURSE, depart: 'radisson' },
    { p: "Ma pizza m'attend chez Maison Grill, c'est réglé, faut juste la ramener", attendu: COURSE, depart: 'maison grill' },
    { p: "J'ai payé par Nita chez Boba Plateau, envoie quelqu'un chercher ça", attendu: COURSE, depart: 'boba' },
    { p: "Récupère ma commande chez le pharmacien de Yantala, c'est déjà payé", attendu: COURSE, depart: 'yantala' },
    { p: 'Le restaurant a fini ma commande mais ils ne livrent pas, tu peux envoyer un livreur chez French Tacos ?', attendu: COURSE, depart: 'french tacos' },
    { p: "J'ai acheté un téléphone à la boutique Orange du Grand Marché, va le chercher pour moi", attendu: COURSE, depart: 'grand marche' },
  ],
  'Vraies plaintes': [
    { p: "Ma commande n'est toujours pas arrivée alors que j'ai payé", attendu: ['aide', 'suivi'] },
    { p: "J'ai payé par Nita mais ma commande est bloquée", attendu: ['aide'] },
    { p: "Le livreur ne m'a pas rendu ma monnaie", attendu: ['aide'] },
    { p: "Ajoutez un coca à ma commande que j'ai déjà payée", attendu: ['aide'] },
    { p: "On m'a livré du poulet au lieu du poisson", attendu: ['aide'] },
  ],
  "Demandes d'aide générales": [
    { p: "Je veux parler à quelqu'un de chez vous", attendu: ['aide'] },
    { p: "Ça fait trois fois que je demande et personne ne m'aide", attendu: ['aide'] },
    { p: "J'ai payé chez un commerçant qui ne m'a jamais rien donné, vous pouvez m'aider ?", attendu: ['aide'] },
  ],
  'Achats sur Tovo': [
    { p: 'Je veux commander chez Boba', attendu: ['boutique'] },
    { p: 'Livre-moi une pizza', attendu: ['recherche'] },
  ],
};

const norm = (s: string) => s.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase();
const [nom = 'mesure', reference] = process.argv.slice(2);
const dossier = 'scripts/banc-ia/resultats';
const avant: Record<string, string[]> = reference
  ? JSON.parse(readFileSync(`${dossier}/retrait-${reference}.json`, 'utf8')) : {};
const sortie: Record<string, string[]> = {};
const regressions: string[] = [];
const progres: string[] = [];
const n = (r: string[]) => r.filter((x) => x.startsWith('✓')).length;

for (const [famille, cas] of Object.entries(FAMILLES)) {
  let bons = 0;
  console.log(`\n## ${famille}`);
  for (const c of cas) {
    const res: string[] = [];
    for (let i = 0; i < ESSAIS; i++) {
      const d = await comprendre(c.p);
      const dep = norm((d as { details?: { depart?: string } }).details?.depart ?? '');
      const predit = !d.sur && COUTEUSES.has(d.intention ?? '') ? 'tuiles' : (d.intention ?? 'rien');
      const ok = c.attendu.includes(predit) && (!c.depart || dep.includes(c.depart));
      if (ok) bons++;
      res.push(`${ok ? '✓' : '✗'} ${predit}${dep ? ` [${dep}]` : ''}`);
    }
    sortie[c.p] = res;
    const ref = avant[c.p];
    if (ref && n(res) < n(ref)) regressions.push(`${c.p} : ${n(ref)}/${ESSAIS} → ${n(res)}/${ESSAIS}`);
    if (ref && n(res) > n(ref)) progres.push(`${c.p} : ${n(ref)}/${ESSAIS} → ${n(res)}/${ESSAIS}`);
    const delta = ref ? (n(res) < n(ref) ? '  ⚠ RÉGRESSION' : n(res) > n(ref) ? '  ↑ mieux' : '') : '';
    console.log(`${c.p}\n   ${res.join('  ·  ')}${ref ? `   (avant ${n(ref)}/${ESSAIS})` : ''}${delta}`);
  }
  console.log(`   → ${bons} / ${cas.length * ESSAIS}`);
}
mkdirSync(dossier, { recursive: true });
writeFileSync(`${dossier}/retrait-${nom}.json`, JSON.stringify(sortie, null, 1));
if (reference) {
  console.log(`\nRégressions (${regressions.length}) :${regressions.map((r) => `\n  ⚠ ${r}`).join('') || ' aucune'}`);
  console.log(`Progrès (${progres.length}) :${progres.map((r) => `\n  ↑ ${r}`).join('') || ' aucun'}`);
}
process.exit(0);
