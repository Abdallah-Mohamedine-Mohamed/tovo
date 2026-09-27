/**
 * Réétiqueter la banque après un changement d'intentions (27/09 : ajout de
 * aide, question, panier).
 *
 *   npm run banc:reetiqueter             → écrit en base
 *   npm run banc:reetiqueter -- --sec    → montre seulement ce qui changerait
 *
 * Seules les phrases dont le sens a pu glisser vers une nouvelle intention
 * sont reprises (social, suivi, designe). Les deux modèles forts les
 * étiquettent à l'aveugle avec le nouveau guide : d'accord → l'étiquette est
 * mise à jour ; en désaccord → la phrase part à trancher dans l'admin.
 */
const { serviceClient } = await import('../../src/services/supabase.js');
const { ecrivain, juge } = await import('../../src/ai/banc/modelesForts.js');
const { etiqueterALAveugle, memeSens } = await import('../../src/ai/banc/boucle.js');
const { toutLire } = await import('../../src/ai/banc/lire.js');
type Etiquette = import('../../src/ai/banc/guide.js').Etiquette;

const sec = process.argv.includes('--sec');
const db = serviceClient();
const { data, error } = await toutLire((de, a) => db.from('banc_cas').select('id, texte, avant, attendu, statut')
  .eq('statut', 'valide').in('attendu', ['social', 'suivi', 'designe']).order('id').range(de, a));
if (error) throw error;
const cas = (data ?? []) as Array<{ id: string; texte: string; avant: string | null; attendu: string }>;
console.log(`${cas.length} phrases à reprendre (social, suivi, designe)`);

async function parPaquets(modele: ReturnType<typeof juge>): Promise<Array<Etiquette | null>> {
  const sorties: Array<Etiquette | null> = [];
  const paquets: (typeof cas)[] = [];
  for (let i = 0; i < cas.length; i += 40) paquets.push(cas.slice(i, i + 40));
  const resultats: Array<Array<Etiquette | null>> = new Array(paquets.length);
  let suivant = 0;
  await Promise.all(Array.from({ length: 3 }, async () => {
    for (let i = suivant++; i < paquets.length; i = suivant++) {
      try {
        resultats[i] = await etiqueterALAveugle(modele, paquets[i]!);
      } catch (cause) {
        console.log(`panne ${modele.nom} : ${(cause as Error).message.slice(0, 100)}`);
        resultats[i] = paquets[i]!.map(() => null);
      }
    }
  }));
  for (const r of resultats) sorties.push(...r);
  return sorties;
}

const [a, b] = await Promise.all([parPaquets(juge()), parPaquets(ecrivain())]);
let changees = 0;
let aTrancher = 0;
const exemples: string[] = [];
for (let i = 0; i < cas.length; i++) {
  const c = cas[i]!;
  const ja = a[i] ?? null;
  const jb = b[i] ?? null;
  if (!ja || !jb) continue;
  if (memeSens(ja, jb) && ja !== 'ambigu') {
    if (ja === c.attendu || memeSens(ja, c.attendu as Etiquette)) continue;
    changees++;
    if (exemples.length < 25) exemples.push(`« ${c.texte} » : ${c.attendu} → ${ja}`);
    if (!sec) await db.from('banc_cas').update({ attendu: ja, juge: ja, etiqueteur: jb }).eq('id', c.id);
  } else {
    aTrancher++;
    if (!sec) {
      await db.from('banc_cas').update({
        statut: 'a_valider', juge: ja, etiqueteur: jb,
        note: `Nouvelles intentions (27/09) : GPT dit ${ja}, Gemini dit ${jb}, l'étiquette était ${c.attendu}.`,
      }).eq('id', c.id);
    }
  }
}
console.log(`\n${changees} étiquettes mises à jour, ${aTrancher} phrases envoyées à trancher${sec ? ' (essai : rien écrit)' : ''}`);
for (const e of exemples) console.log('  ', e);
