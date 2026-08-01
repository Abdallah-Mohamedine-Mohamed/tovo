import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

/**
 * Socle des tests RLS.
 *
 * On ne teste pas la RLS à la main dans le dashboard : on crée quatre vrais
 * utilisateurs, on ouvre quatre vraies sessions, et on vérifie que chacun voit
 * exactement ce qu'il doit voir. Tant que ces tests ne passent pas, on ne
 * construit pas la couche au-dessus.
 *
 * Ces tests écrivent en base : les lancer UNIQUEMENT sur le projet staging.
 */

const url = process.env.SUPABASE_URL;
const anonKey = process.env.SUPABASE_ANON_KEY;
const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

// Dire laquelle manque, et non « il en manque une » : une variable présente
// mais vide dans .env produit exactement le même symptôme qu'un fichier
// absent, et les distinguer fait gagner un aller-retour.
const missing = (
  [
    ['SUPABASE_URL', url],
    ['SUPABASE_ANON_KEY', anonKey],
    ['SUPABASE_SERVICE_ROLE_KEY', serviceKey],
  ] as const
)
  .filter(([, value]) => !value)
  .map(([name]) => name);

if (missing.length > 0 || !url || !anonKey || !serviceKey) {
  throw new Error(
    `Tests RLS : variable(s) manquante(s) ou vide(s) dans backend/.env → ${missing.join(', ')}\n` +
      'Dashboard → Project Settings → API Keys → onglet « Publishable and secret API keys ».',
  );
}

// Après ce point, TypeScript sait que les trois valeurs sont définies.
const supabaseUrl: string = url;
const supabaseAnonKey: string = anonKey;

if (url.includes('prod')) {
  throw new Error('Refus de lancer les tests RLS sur un projet nommé « prod ».');
}

export const admin: SupabaseClient = createClient(supabaseUrl, serviceKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});

export type Role = 'client' | 'driver' | 'merchant' | 'admin';

export interface TestUser {
  id: string;
  email: string;
  role: Role;
  db: SupabaseClient;
  /** JWT de la session, pour les tests HTTP qui passent par les routes. */
  accessToken: string;
}

const created: string[] = [];

/**
 * Crée un utilisateur et ouvre sa session.
 *
 * On passe par email + mot de passe et non par téléphone : le rôle est forcé à
 * 'client' par le trigger, puis promu avec la service_role — exactement le
 * chemin qu'emprunte l'admin en production. Un test qui pourrait choisir son
 * propre rôle à l'inscription ne testerait pas la réalité.
 */
export async function createUser(role: Role): Promise<TestUser> {
  const email = `rls-${role}-${randomUUID()}@tovo.test`;
  const password = randomUUID();

  const { data, error } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { full_name: `Test ${role}` },
  });
  if (error || !data.user) throw error ?? new Error('création utilisateur impossible');

  created.push(data.user.id);

  if (role !== 'client') {
    const { error: promoteError } = await admin
      .from('profiles')
      .update({ role })
      .eq('id', data.user.id);
    if (promoteError) throw promoteError;
  }

  if (role === 'driver') {
    const { error: driverError } = await admin
      .from('driver_profiles')
      .insert({ id: data.user.id, is_online: true, is_available: true });
    if (driverError) throw driverError;
  }

  const session = createClient(supabaseUrl, supabaseAnonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: signIn, error: signInError } = await session.auth.signInWithPassword({
    email,
    password,
  });
  if (signInError || !signIn.session) throw signInError ?? new Error('session absente');

  return {
    id: data.user.id,
    email,
    role,
    db: session,
    accessToken: signIn.session.access_token,
  };
}

/** Client anonyme, pour vérifier ce qui fuit sans authentification. */
export function anonymous(): SupabaseClient {
  return createClient(supabaseUrl, supabaseAnonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/** Première zone du seed, pour rattacher boutiques et commandes. */
export async function firstZoneId(): Promise<string> {
  const { data, error } = await admin.from('delivery_zones').select('id').limit(1).single();
  if (error) throw error;
  return data.id as string;
}

export interface SeededShop {
  merchantId: string;
  productId: string;
}

/** Boutique approuvée + produit disponible, créés avec la service_role. */
export async function seedShop(ownerId: string, zoneId: string): Promise<SeededShop> {
  const { data: merchant, error: merchantError } = await admin
    .from('merchants')
    .insert({
      owner_id: ownerId,
      name: `Boutique test ${randomUUID().slice(0, 8)}`,
      address_hint: 'Yantala',
      location: 'SRID=4326;POINT(2.0870 13.5290)',
      zone_id: zoneId,
      is_open: true,
      is_approved: true,
    })
    .select('id')
    .single();
  if (merchantError) throw merchantError;

  const { data: product, error: productError } = await admin
    .from('products')
    .insert({
      merchant_id: merchant.id,
      name: 'Tuo zaafi sauce arachide',
      description: 'Pâte de mil, sauce arachide',
      price: 1500,
      is_available: true,
    })
    .select('id')
    .single();
  if (productError) throw productError;

  return { merchantId: merchant.id as string, productId: product.id as string };
}

export interface SeededOptions {
  productId: string;
  portionOptionId: string;
  portionSimple: string;
  portionDouble: string;   // +700 XOF
  sauceOptionId: string;
  sauceArachide: string;   // +0
}

/**
 * Produit à 1500 XOF avec une option obligatoire (Portion, choix unique) et
 * une option facultative (Sauce). De quoi vérifier le calcul de prix et le
 * refus d'une commande à laquelle il manque un choix obligatoire.
 */
export async function seedProductWithOptions(merchantId: string): Promise<SeededOptions> {
  const { data: product, error: productError } = await admin
    .from('products')
    .insert({ merchant_id: merchantId, name: 'Tuo zaafi', price: 1500, is_available: true })
    .select('id')
    .single();
  if (productError) throw productError;

  const { data: portion, error: portionError } = await admin
    .from('product_options')
    .insert({
      product_id: product.id,
      name: 'Portion',
      is_required: true,
      min_select: 1,
      max_select: 1,
      sort_order: 1,
    })
    .select('id')
    .single();
  if (portionError) throw portionError;

  const { data: portionValues, error: pvError } = await admin
    .from('product_option_values')
    .insert([
      { option_id: portion.id, name: 'Simple', price_delta: 0, sort_order: 1 },
      { option_id: portion.id, name: 'Double', price_delta: 700, sort_order: 2 },
    ])
    .select('id, name');
  if (pvError) throw pvError;

  const { data: sauce, error: sauceError } = await admin
    .from('product_options')
    .insert({
      product_id: product.id,
      name: 'Sauce',
      is_required: false,
      min_select: 0,
      max_select: 2,
      sort_order: 2,
    })
    .select('id')
    .single();
  if (sauceError) throw sauceError;

  const { data: sauceValues, error: svError } = await admin
    .from('product_option_values')
    .insert([{ option_id: sauce.id, name: 'Arachide', price_delta: 0, sort_order: 1 }])
    .select('id');
  if (svError) throw svError;

  const simple = portionValues?.find((v) => v.name === 'Simple');
  const double = portionValues?.find((v) => v.name === 'Double');
  if (!simple || !double || !sauceValues?.[0]) throw new Error('seed options incomplet');

  return {
    productId: product.id as string,
    portionOptionId: portion.id as string,
    portionSimple: simple.id as string,
    portionDouble: double.id as string,
    sauceOptionId: sauce.id as string,
    sauceArachide: sauceValues[0].id as string,
  };
}

/** Commande prête à être prise par un livreur de la zone. */
export async function seedOrder(params: {
  userId: string;
  merchantId: string;
  zoneId: string;
  status?: string;
}): Promise<string> {
  const { data, error } = await admin
    .from('orders')
    .insert({
      client_order_id: randomUUID(),
      type: 'delivery',
      user_id: params.userId,
      merchant_id: params.merchantId,
      zone_id: params.zoneId,
      status: params.status ?? 'ready',
      dropoff_hint: 'Plateau, immeuble bleu',
      dropoff_location: 'SRID=4326;POINT(2.1098 13.5137)',
      items_total: 3000,
      delivery_fee: 500,
      total: 3500,
      payment_method: 'cash',
    })
    .select('id')
    .single();
  if (error) throw error;
  return data.id as string;
}

/** Supprime tous les utilisateurs créés — la cascade emporte le reste. */
export async function cleanup(): Promise<void> {
  for (const id of created.splice(0)) {
    await admin.auth.admin.deleteUser(id).catch(() => undefined);
  }
}
