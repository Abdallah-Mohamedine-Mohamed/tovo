/**
 * Catalogue de test sur le projet STAGING : trois boutiques connues, dont un
 * tacos bowl à options, pour que les scénarios aient toujours les mêmes
 * produits sous la main.
 *
 *   npm run staging:semer
 *
 * Idempotent (legacy_id « scenario-… ») : relancer ne crée pas de doublon.
 * Refuse de tourner sur la production (garde.ts).
 */
import { createClient } from '@supabase/supabase-js';
import { exigerStaging } from './garde.js';

const { url, service } = exigerStaging();
const admin = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });

type Option = { nom: string; requis: boolean; min: number; max: number; valeurs: Array<[string, number]> };
type Produit = { nom: string; prix: number; categorie: string; options?: Option[] };
type Boutique = { cle: string; nom: string; categorie: string; produits: Produit[] };

const VIANDE: Option = { nom: 'Viande', requis: true, min: 1, max: 1, valeurs: [['Poulet', 0], ['Bœuf', 0], ['Mixte', 500]] };

const BOUTIQUES: Boutique[] = [
  {
    cle: 'scenario-otakoss', nom: 'Scénario Tacos', categorie: 'repas',
    produits: [
      {
        nom: 'Tacos Bowl', prix: 3500, categorie: 'repas', options: [
          VIANDE,
          { nom: 'Sauce', requis: false, min: 0, max: 2, valeurs: [['Algérienne', 0], ['Samouraï', 0], ['Fromagère', 0]] },
          { nom: 'Suppléments', requis: false, min: 0, max: 3, valeurs: [['Frites', 500], ['Fromage', 300]] },
        ],
      },
      { nom: 'Tacos XL', prix: 4000, categorie: 'repas', options: [VIANDE] },
      { nom: 'Coca-Cola 33 cl', prix: 600, categorie: 'boissons' },
      { nom: 'Jus de bissap', prix: 500, categorie: 'boissons' },
    ],
  },
  {
    cle: 'scenario-garba', nom: 'Scénario Garba', categorie: 'repas',
    produits: [
      { nom: 'Garba', prix: 1500, categorie: 'repas' },
      {
        nom: 'Attiéké poulet', prix: 2500, categorie: 'repas',
        options: [{ nom: 'Piment', requis: false, min: 0, max: 1, valeurs: [['Sans piment', 0], ['Pimenté', 0]] }],
      },
    ],
  },
  {
    cle: 'scenario-issa', nom: 'Scénario Épicerie', categorie: 'epicerie',
    produits: [
      { nom: 'Riz parfumé 5 kg', prix: 4500, categorie: 'epicerie' },
      { nom: 'Lait en poudre 400 g', prix: 2200, categorie: 'epicerie' },
      { nom: 'Pain baguette', prix: 250, categorie: 'boulangerie' },
      { nom: 'Huile 1 L', prix: 1500, categorie: 'epicerie' },
    ],
  },
];

/** Le résultat, ou une erreur explicite — jamais `null` en silence. */
async function verifier<R extends { data: unknown; error: unknown }>(
  promesse: PromiseLike<R>,
  quoi: string,
): Promise<NonNullable<R['data']>> {
  const { data, error } = await promesse;
  if (error) throw new Error(`${quoi} : ${(error as { message?: string }).message ?? String(error)}`);
  if (data === null || data === undefined) throw new Error(`${quoi} : aucun résultat`);
  return data as NonNullable<R['data']>;
}

// Le propriétaire des boutiques de test.
const EMAIL = 'boutiques-scenario@tovo.test';
const existants = await verifier(admin.auth.admin.listUsers({ perPage: 1000 }), 'lecture des comptes');
let proprietaire = existants.users.find((u) => u.email === EMAIL)?.id;
if (!proprietaire) {
  const cree = await verifier(admin.auth.admin.createUser({
    email: EMAIL, password: crypto.randomUUID(), email_confirm: true, user_metadata: { full_name: 'Boutiques scénario' },
  }), 'création du propriétaire');
  proprietaire = cree.user!.id;
}
const role = await admin.from('profiles').update({ role: 'merchant' }).eq('id', proprietaire);
if (role.error) throw new Error(`rôle boutiquier : ${role.error.message}`);

const categories = await verifier(admin.from('categories').select('id, slug'), 'catégories (seed.sql appliqué ?)');
const categorie = (slug: string) => categories.find((c) => c.slug === slug)?.id ?? null;
const zone = (await admin.from('delivery_zones').select('id').order('name').limit(1).maybeSingle()).data;

for (const b of BOUTIQUES) {
  const boutique = await verifier(admin.from('merchants').upsert({
    legacy_id: b.cle, owner_id: proprietaire, name: b.nom, category_id: categorie(b.categorie),
    address_hint: 'Niamey', location: 'SRID=4326;POINT(2.1098 13.5137)', zone_id: zone?.id ?? null,
    is_open: true, is_approved: true,
  }, { onConflict: 'legacy_id' }).select('id').single(), `boutique ${b.nom}`);

  for (const p of b.produits) {
    const produit = await verifier(admin.from('products').upsert({
      legacy_id: `${b.cle}:${p.nom}`, merchant_id: boutique.id, category_id: categorie(p.categorie),
      name: p.nom, price: p.prix, is_available: true,
    }, { onConflict: 'legacy_id' }).select('id').single(), `produit ${p.nom}`);

    // Options : on repart de zéro à chaque semis, plus simple qu'un diff.
    const purge = await admin.from('product_options').delete().eq('product_id', produit.id);
    if (purge.error) throw new Error(`purge des options : ${purge.error.message}`);
    for (const [rang, o] of (p.options ?? []).entries()) {
      const option = await verifier(admin.from('product_options').insert({
        product_id: produit.id, name: o.nom, is_required: o.requis, min_select: o.min, max_select: o.max, sort_order: rang,
      }).select('id').single(), `option ${o.nom}`);
      const valeurs = await admin.from('product_option_values').insert(o.valeurs.map(([nom, delta], i) => ({
        option_id: option.id, name: nom, price_delta: delta, sort_order: i,
      })));
      if (valeurs.error) throw new Error(`valeurs ${o.nom} : ${valeurs.error.message}`);
    }
  }
  console.log(`✓ ${b.nom} — ${b.produits.length} produits`);
}
console.log('Catalogue de test prêt.');
