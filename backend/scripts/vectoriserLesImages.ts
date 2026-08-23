/**
 * Vectorise les produits depuis leurs PHOTOS.
 *
 *     node node_modules/tsx/dist/cli.mjs --env-file=.env scripts/vectoriserLesImages.ts
 *
 * REPRENABLE. Il ne traite que les produits dont `image_embedded_at` est
 * nul, et l'écrit dès chaque succès. Interrompu à la 900e image, le
 * relancer reprend à la 901e — un rattrapage de 2 060 images dure une
 * quinzaine de minutes, et une coupure réseau à Niamey ne doit pas tout
 * remettre à zéro.
 *
 * Ne touche jamais `embedding`, qui vient du texte et sert la recherche
 * écrite. Les deux vecteurs coexistent et répondent à deux questions
 * différentes.
 */
import { createClient } from '@supabase/supabase-js';
import { embedImage } from '../src/services/embeddings.js';

/** Cinq à la fois : mesuré à 2,3 s l'image, c'est 80 min qui deviennent 16. */
const PARALLELE = 5;

/** Au-delà, l'image est probablement une erreur de saisie du boutiquier. */
const TAILLE_MAX = 8 * 1024 * 1024;

const db = createClient(
  process.env['SUPABASE_URL']!,
  process.env['SUPABASE_SERVICE_ROLE_KEY']!,
  { auth: { persistSession: false, autoRefreshToken: false } },
);

interface Produit {
  id: string;
  name: string;
  image_url: string;
}

async function aTraiter(): Promise<Produit[]> {
  const tous: Produit[] = [];
  let de = 0;
  for (;;) {
    const { data, error } = await db
      .from('products')
      .select('id, name, image_url')
      .not('image_url', 'is', null)
      .is('image_embedded_at', null)
      .range(de, de + 999);
    if (error) throw new Error(error.message);
    const lot = (data ?? []) as Produit[];
    tous.push(...lot);
    if (lot.length < 1000) break;
    de += 1000;
  }
  return tous;
}

/**
 * Une image, un vecteur.
 *
 * Un échec marque quand même la date : sans ça, une image définitivement
 * morte serait reprise à chaque passage et le rattrapage ne finirait jamais.
 * Le vecteur reste nul, ce qui suffit à distinguer « échoué » de « réussi ».
 */
async function traiter(p: Produit): Promise<'ok' | 'echec'> {
  try {
    const reponse = await fetch(p.image_url, { signal: AbortSignal.timeout(30_000) });
    if (!reponse.ok) throw new Error(`HTTP ${reponse.status}`);

    const octets = Buffer.from(await reponse.arrayBuffer());
    if (octets.byteLength > TAILLE_MAX) throw new Error('image trop lourde');

    const vecteur = await embedImage(
      octets,
      reponse.headers.get('content-type') ?? 'image/jpeg',
    );

    const { error } = await db
      .from('products')
      .update({ image_embedding: vecteur, image_embedded_at: new Date().toISOString() })
      .eq('id', p.id);
    if (error) throw new Error(error.message);

    return 'ok';
  } catch (cause) {
    const raison = cause instanceof Error ? cause.message : 'échec';
    console.log(`    ✗ ${p.name.slice(0, 40)} — ${raison.slice(0, 60)}`);
    await db
      .from('products')
      .update({ image_embedded_at: new Date().toISOString() })
      .eq('id', p.id);
    return 'echec';
  }
}

const produits = await aTraiter();
console.log(`  ${produits.length} produit(s) à vectoriser`);
if (produits.length === 0) {
  console.log('  Rien à faire.');
  process.exit(0);
}

const debut = Date.now();
let faits = 0;
let reussis = 0;

// Chaque ouvrier pioche dans la même file : une image lente n'immobilise
// pas les quatre autres, contrairement à un découpage en tranches fixes.
let curseur = 0;
const ouvrier = async (): Promise<void> => {
  for (;;) {
    const i = curseur++;
    if (i >= produits.length) return;
    const r = await traiter(produits[i]!);
    faits++;
    if (r === 'ok') reussis++;
    if (faits % 50 === 0 || faits === produits.length) {
      const ecoule = (Date.now() - debut) / 1000;
      const reste = Math.round((ecoule / faits) * (produits.length - faits) / 60);
      console.log(
        `  ${faits}/${produits.length}  (${reussis} vectorisés)  reste ~${reste} min`,
      );
    }
  }
};

await Promise.all(Array.from({ length: PARALLELE }, ouvrier));

console.log(
  `\n  Terminé : ${reussis} vectorisés, ${faits - reussis} en échec, ` +
    `${Math.round((Date.now() - debut) / 60000)} min.`,
);
process.exit(0);
