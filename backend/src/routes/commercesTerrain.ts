import { randomUUID } from 'node:crypto';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { z } from 'zod';
import { cleDeCategorie, dejaConnu, type Categorie } from '../services/commercesTerrain.js';
import { serviceClient } from '../services/supabase.js';

/**
 * Le livreur relève un commerce sur le terrain (07/10) : il est devant la
 * devanture. POST /livreur/commerces dépose la fiche (« proposée ») ;
 * GET /livreur/commerces lui montre les siennes et leur statut. L'admin
 * valide dans sa page « Commerces du terrain » (migration 0076).
 */

const ficheSchema = z.object({
  nom: z.string().trim().min(2).max(120),
  // Une à cinq catégories (clés de categories_commerce, migration 0078).
  categories: z.array(z.string().regex(/^[a-z0-9-]{2,60}$/)).min(1).max(5),
  telephone: z.string().optional().nullable()
    .transform((t) => (t ? t.replace(/\D/g, '').replace(/^227(?=\d{8}$)/, '') : null))
    .refine((t) => t === null || t === '' || /^\d{8}$/.test(t), 'numéro à 8 chiffres')
    .transform((t) => t || null),
  lat: z.number().min(13.2).max(13.8),
  lng: z.number().min(1.8).max(2.4),
  precision_m: z.number().nonnegative().max(10_000).optional().nullable(),
  repere: z.string().trim().max(200).optional().nullable(),
  // La photo de la devanture, en JPEG (compressée par l'application).
  photo: z.object({
    mime: z.enum(['image/jpeg', 'image/png', 'image/webp']),
    data: z.string().min(100).max(4_000_000),
  }).optional().nullable(),
});

export async function commercesTerrainRoutes(app: FastifyInstance): Promise<void> {
  const exigerLivreur = async (request: FastifyRequest, reply: FastifyReply): Promise<void> => {
    if (request.user?.role !== 'driver' && request.user?.role !== 'admin') {
      return reply.code(403).send({ error: 'réservé aux livreurs' });
    }
  };
  const livreur = { preHandler: [app.requireAuth, exigerLivreur] };

  app.post('/livreur/commerces', { ...livreur, bodyLimit: 5 * 1024 * 1024 }, async (request, reply) => {
    const body = ficheSchema.safeParse(request.body);
    if (!body.success) {
      const premiere = body.error.issues[0];
      return reply.code(400).send({ error: `fiche invalide : ${premiere?.path.join(' › ')} — ${premiere?.message}` });
    }
    const fiche = body.data;
    // Les catégories : validées, ou proposées par CE livreur.
    const { data: cats, error: errCats } = await serviceClient().from('categories_commerce')
      .select('slug, libelle, type, statut, propose_par').in('slug', fiche.categories);
    if (errCats) return reply.code(500).send({ error: `${errCats.message} — la migration 0078 est-elle appliquée ?` });
    const connues = ((cats ?? []) as Array<Categorie & { propose_par: string | null }>)
      .filter((c) => c.statut === 'valide' || c.propose_par === request.user!.id);
    const inconnue = fiche.categories.find((c) => !connues.some((k) => k.slug === c));
    if (inconnue) return reply.code(400).send({ error: `catégorie inconnue : ${inconnue}` });
    // Le type de l'annuaire : celui de la première catégorie qui en a un.
    const type = fiche.categories.map((c) => connues.find((k) => k.slug === c)?.type).find((t) => t) ?? 'boutique';
    // Déjà connu à cet endroit : pas de doublon.
    const connu = await dejaConnu(fiche.nom, fiche);
    if (connu) return reply.code(409).send({ error: `« ${connu} » est déjà connu à cet endroit.`, deja_connu: connu });

    const db = serviceClient();
    let photo: string | null = null;
    if (fiche.photo) {
      const extension = fiche.photo.mime === 'image/png' ? 'png' : fiche.photo.mime === 'image/webp' ? 'webp' : 'jpg';
      const chemin = `${request.user!.id}/${randomUUID()}.${extension}`;
      const envoi = await db.storage.from('terrain').upload(chemin, Buffer.from(fiche.photo.data, 'base64'), {
        contentType: fiche.photo.mime, upsert: false,
      });
      // Sans photo, la fiche reste utile : l'admin vérifiera autrement.
      if (envoi.error) request.log.warn({ erreur: envoi.error.message }, 'photo du terrain non enregistrée');
      else photo = chemin;
    }
    const { data, error } = await db.from('commerces_terrain').insert({
      nom: fiche.nom,
      type,
      categories: fiche.categories,
      telephone: fiche.telephone,
      lat: fiche.lat,
      lng: fiche.lng,
      precision_m: fiche.precision_m != null ? Math.round(fiche.precision_m) : null,
      repere: fiche.repere || null,
      photo,
      propose_par: request.user!.id,
    }).select('id, statut').single();
    if (error) return reply.code(500).send({ error: `${error.message} — la migration 0076 est-elle appliquée ?` });
    request.log.info({ id: data.id, type, categories: fiche.categories, photo: Boolean(photo) }, 'commerce relevé sur le terrain');
    return reply.code(201).send({ id: data.id, statut: data.statut });
  });

  // Les catégories que le livreur peut choisir : les validées, et celles
  // qu'il a lui-même proposées (en attente de l'admin).
  app.get('/livreur/categories', livreur, async (request, reply) => {
    const { data, error } = await serviceClient().from('categories_commerce')
      .select('slug, libelle, statut, propose_par')
      .or(`statut.eq.valide,propose_par.eq.${request.user!.id}`)
      .order('libelle');
    if (error) return reply.code(500).send({ error: `${error.message} — la migration 0078 est-elle appliquée ?` });
    return reply.send({ categories: (data ?? []).map(({ slug, libelle, statut }) => ({ slug, libelle, statut })) });
  });

  // Une catégorie qui manque : le livreur la propose, et l'utilise aussitôt.
  app.post('/livreur/categories', livreur, async (request, reply) => {
    const body = z.object({ libelle: z.string().trim().min(2).max(60) }).safeParse(request.body);
    if (!body.success) return reply.code(400).send({ error: 'nom de catégorie : 2 à 60 caractères' });
    const libelle = body.data.libelle.charAt(0).toUpperCase() + body.data.libelle.slice(1);
    const slug = cleDeCategorie(libelle);
    if (slug.length < 2) return reply.code(400).send({ error: 'nom de catégorie illisible' });
    const db = serviceClient();
    // Elle existe déjà (même nom, accents et majuscules mis à part) : on la rend.
    const { data: existe } = await db.from('categories_commerce').select('slug, libelle, statut').eq('slug', slug).maybeSingle();
    if (existe) return reply.send({ categorie: existe, existait: true });
    const { data, error } = await db.from('categories_commerce')
      .insert({ slug, libelle, statut: 'propose', propose_par: request.user!.id })
      .select('slug, libelle, statut').single();
    if (error) return reply.code(500).send({ error: error.message });
    request.log.info({ slug }, 'catégorie proposée par un livreur');
    return reply.code(201).send({ categorie: data, existait: false });
  });

  app.get('/livreur/commerces', livreur, async (request, reply) => {
    const { data, error } = await serviceClient().from('commerces_terrain')
      .select('id, nom, type, categories, statut, motif_refus, cree_le')
      .eq('propose_par', request.user!.id)
      .order('cree_le', { ascending: false })
      .limit(100);
    if (error) return reply.code(500).send({ error: error.message });
    const fiches = data ?? [];
    return reply.send({
      fiches,
      validees: fiches.filter((f) => f.statut === 'valide').length,
    });
  });
}
