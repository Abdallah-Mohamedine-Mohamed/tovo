import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { z } from 'zod';
import { toHttpFailure } from '../lib/errors.js';
import { envelope } from '../components/builders.js';
import { serviceClient } from '../services/supabase.js';

/**
 * Création de livreurs et de boutiques par l'administration.
 *
 * Jusqu'ici, entrer dans Tovo supposait de s'inscrire soi-même depuis
 * l'application — donc d'être client. Un livreur recruté ou une boutique
 * démarchée n'avaient aucun chemin : il fallait qu'ils installent l'app
 * client, s'inscrivent, puis qu'on modifie leur rôle à la main en base.
 *
 * LE NUMÉRO EST L'IDENTITÉ. Il n'y a ni mot de passe ni email : on crée le
 * compte téléphone, la personne se connecte par code WhatsApp. C'est aussi
 * pourquoi ces routes commencent toutes par chercher un compte existant —
 * un livreur qui commandait déjà son déjeuner sur Tovo ne doit pas se
 * retrouver avec deux comptes, il doit garder le sien.
 */

/** Format E.164, la seule forme que Supabase Auth accepte. */
function normaliser(brut: string): string | null {
  const chiffres = brut.replace(/[^\d+]/g, '');
  if (chiffres.startsWith('+')) {
    return chiffres.length >= 11 && chiffres.length <= 16 ? chiffres : null;
  }
  if (chiffres.length === 8) return `+227${chiffres}`;
  if (chiffres.startsWith('227') && chiffres.length === 11) return `+${chiffres}`;
  return null;
}

interface Compte {
  id: string;
  nouveau: boolean;
  ancienRole: string;
}

/**
 * Trouve le compte derrière un numéro, ou le crée.
 *
 * Ne rétrograde jamais : un admin qui livre le samedi reste admin. Le rôle
 * n'est élevé que s'il apporte des droits — sans quoi confier une course à
 * un administrateur lui retirerait l'accès à sa propre administration.
 */
async function trouverOuCreer(
  telephone: string,
  nom: string,
  role: 'driver' | 'merchant',
): Promise<Compte | { erreur: string; statut: number }> {
  const service = serviceClient();

  // Supabase Auth enregistre le numéro SANS le « + », `profiles` aussi.
  // Comparer sur la forme E.164 ne trouverait jamais personne.
  const sansPlus = telephone.slice(1);

  const { data: existant } = await service
    .from('profiles')
    .select('id, role, full_name')
    .eq('phone', sansPlus)
    .maybeSingle();

  if (existant) {
    const ancienRole = String(existant.role);
    const aDejaPlus = ancienRole === 'admin' || ancienRole === role;

    const { error } = await service
      .from('profiles')
      .update({
        ...(aDejaPlus ? {} : { role }),
        // On ne remplace pas un nom déjà renseigné : celui saisi par la
        // personne vaut mieux que celui tapé par l'administration.
        ...((existant.full_name as string | null)?.trim() ? {} : { full_name: nom }),
      })
      .eq('id', existant.id as string);

    if (error) return { erreur: error.message, statut: 500 };
    return { id: existant.id as string, nouveau: false, ancienRole };
  }

  const { data: cree, error: erreurAuth } = await service.auth.admin.createUser({
    phone: telephone,
    // Confirmé d'office : le compte est créé par l'administration, pas par
    // quelqu'un qui doit prouver qu'il détient la ligne. La preuve viendra
    // à la première connexion, par le code WhatsApp.
    phone_confirm: true,
    user_metadata: { full_name: nom },
  });

  if (erreurAuth || !cree.user) {
    return { erreur: erreurAuth?.message ?? 'création refusée', statut: 502 };
  }

  // Le trigger d'inscription crée le profil avec le rôle `client` par
  // défaut : on le corrige juste après, plutôt que de dupliquer sa logique.
  const { error: erreurProfil } = await service
    .from('profiles')
    .update({ role, full_name: nom, phone: sansPlus })
    .eq('id', cree.user.id);

  if (erreurProfil) return { erreur: erreurProfil.message, statut: 500 };
  return { id: cree.user.id, nouveau: true, ancienRole: 'client' };
}

const livreurSchema = z.object({
  full_name: z.string().min(2).max(80),
  phone: z.string().min(6).max(30),
  vehicle_type: z.enum(['moto', 'velo', 'voiture']).default('moto'),
  plate_number: z.string().max(20).nullable().default(null),
});

const boutiqueSchema = z.object({
  name: z.string().min(2).max(120),
  /** Numéro public, affiché au client. */
  phone: z.string().min(6).max(30),
  /** Numéro de connexion du propriétaire. Le même par défaut. */
  owner_phone: z.string().min(6).max(30).optional(),
  owner_name: z.string().min(2).max(80),
  category_id: z.string().uuid(),
  address_hint: z.string().min(2).max(300),
  lat: z.number().min(-90).max(90),
  lng: z.number().min(-180).max(180),
  prep_time_min: z.number().int().min(0).max(180).default(20),
});

export async function adminComptesRoutes(app: FastifyInstance): Promise<void> {
  const exigerAdmin = async (request: FastifyRequest, reply: FastifyReply): Promise<void> => {
    if (request.user?.role !== 'admin') {
      return reply.code(403).send({ error: 'réservé à l’administration' });
    }
  };

  const admin = { preHandler: [app.requireAuth, exigerAdmin] };

  /** Recrute un livreur. */
  app.post('/admin/drivers', admin, async (request, reply) => {
    const body = livreurSchema.safeParse(request.body);
    if (!body.success) {
      return reply.code(400).send({ error: 'requête invalide', details: body.error.issues });
    }

    const telephone = normaliser(body.data.phone);
    if (!telephone) return reply.code(400).send({ error: 'numéro invalide' });

    const compte = await trouverOuCreer(telephone, body.data.full_name, 'driver');
    if ('erreur' in compte) {
      return reply.code(compte.statut).send({ error: 'création impossible', message: compte.erreur });
    }

    const service = serviceClient();
    // `upsert` et non `insert` : un ancien livreur qu'on réactive a déjà sa
    // fiche, et un `insert` échouerait sur la clé primaire.
    const { error } = await service.from('driver_profiles').upsert(
      {
        id: compte.id,
        vehicle_type: body.data.vehicle_type,
        plate_number: body.data.plate_number,
        // Hors ligne à la création : c'est au livreur de se déclarer
        // disponible depuis son application, jamais à l'administration.
        is_online: false,
        is_available: false,
      },
      { onConflict: 'id' },
    );

    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }

    return reply.send(
      envelope(
        compte.nouveau
          ? `${body.data.full_name} peut se connecter à l’app livreur avec le ${telephone}.`
          : `Le compte existant de ${body.data.full_name} est devenu livreur.`,
        [],
      ),
    );
  });

  /** Ouvre une boutique. */
  app.post('/admin/merchants', admin, async (request, reply) => {
    const body = boutiqueSchema.safeParse(request.body);
    if (!body.success) {
      return reply.code(400).send({ error: 'requête invalide', details: body.error.issues });
    }

    const publique = normaliser(body.data.phone);
    if (!publique) return reply.code(400).send({ error: 'numéro public invalide' });

    // Sans numéro de connexion distinct, le propriétaire se connecte avec le
    // numéro de la boutique. C'est le cas des 77 boutiques reprises de
    // 6ammart, qui n'en avaient qu'un.
    const connexion = normaliser(body.data.owner_phone ?? body.data.phone);
    if (!connexion) return reply.code(400).send({ error: 'numéro de connexion invalide' });

    const compte = await trouverOuCreer(connexion, body.data.owner_name, 'merchant');
    if ('erreur' in compte) {
      return reply.code(compte.statut).send({ error: 'création impossible', message: compte.erreur });
    }

    const service = serviceClient();

    // La zone se déduit du point : elle décide quels livreurs voient les
    // courses. Une boutique hors de toute zone reste créable — l'admin
    // dessinera la zone plus tard — mais elle ne sera dispatchée à personne.
    const { data: zone } = await service.rpc('zone_for_point', {
      p_lat: body.data.lat,
      p_lng: body.data.lng,
    });
    const zoneId = (zone as { id?: string } | null)?.id ?? null;

    const { data: creee, error } = await service
      .from('merchants')
      .insert({
        owner_id: compte.id,
        category_id: body.data.category_id,
        name: body.data.name,
        phone: publique,
        address_hint: body.data.address_hint,
        location: `SRID=4326;POINT(${body.data.lng} ${body.data.lat})`,
        zone_id: zoneId,
        prep_time_min: body.data.prep_time_min,
        // Approuvée d'emblée : c'est l'administration qui la crée, la
        // validation a donc déjà eu lieu hors de l'écran.
        is_approved: true,
        // Fermée en revanche : le boutiquier ouvre lui-même quand il est
        // prêt à recevoir des commandes. Ouvrir à sa place ferait passer
        // des commandes que personne n'attend.
        is_open: false,
      })
      .select('id, name')
      .single();

    if (error) {
      const failure = toHttpFailure(error);
      return reply.code(failure.status).send(failure.body);
    }

    return reply.send(
      envelope(
        `${creee.name} est créée. ${body.data.owner_name} se connecte à l’app boutique avec le ${connexion}. ` +
          `Elle reste fermée tant qu’il ne l’ouvre pas.` +
          (zoneId ? '' : ' Attention : aucune zone de livraison ne couvre ce point.'),
        [],
      ),
    );
  });
}
