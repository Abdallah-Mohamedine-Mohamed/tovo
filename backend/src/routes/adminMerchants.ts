import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { z } from 'zod';
import { toHttpFailure } from '../lib/errors.js';
import { envelope } from '../components/builders.js';
import { serviceClient } from '../services/supabase.js';

/**
 * Retouches d'une boutique par l'administration.
 *
 * Deux numéros cohabitent sur une boutique, et les confondre serait une
 * faute :
 *
 *   `merchants.phone`  — le numéro PUBLIC, celui qu'on affiche au client et
 *                        qu'il compose pour joindre le commerce. Une simple
 *                        colonne, modifiable comme n'importe quelle donnée.
 *
 *   téléphone du propriétaire — celui qui OUVRE LA SESSION dans l'app
 *                        boutiquier. C'est une identité d'authentification :
 *                        le changer déplace le compte, et seul le service
 *                        peut y toucher.
 *
 * Chez les 77 boutiques migrées les deux sont identiques, parce que 6ammart
 * n'en avait qu'un. Rien ne les y oblige.
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

const majSchema = z.object({
  phone: z.string().max(30).nullable().optional(),
  owner_phone: z.string().max(30).optional(),
});

export async function adminMerchantRoutes(app: FastifyInstance): Promise<void> {
  const exigerAdmin = async (request: FastifyRequest, reply: FastifyReply): Promise<void> => {
    if (request.user?.role !== 'admin') {
      return reply.code(403).send({ error: 'réservé à l’administration' });
    }
  };

  const admin = { preHandler: [app.requireAuth, exigerAdmin] };

  app.patch('/admin/merchants/:merchantId', admin, async (request, reply) => {
    const params = z.object({ merchantId: z.string().uuid() }).safeParse(request.params);
    if (!params.success) return reply.code(400).send({ error: 'identifiant invalide' });

    const body = majSchema.safeParse(request.body);
    if (!body.success) {
      return reply.code(400).send({ error: 'requête invalide', details: body.error.issues });
    }

    const db = request.supabase!;

    const { data: boutique, error: erreurLecture } = await db
      .from('merchants')
      .select('id, name, owner_id, phone')
      .eq('id', params.data.merchantId)
      .maybeSingle();

    if (erreurLecture) {
      const failure = toHttpFailure(erreurLecture);
      return reply.code(failure.status).send(failure.body);
    }
    if (!boutique) return reply.code(404).send({ error: 'boutique introuvable' });

    // --- Le numéro public -------------------------------------------
    if (body.data.phone !== undefined) {
      const valeur = body.data.phone ? normaliser(body.data.phone) : null;
      if (body.data.phone && !valeur) {
        return reply.code(400).send({ error: 'numéro public invalide' });
      }

      const { error } = await db
        .from('merchants')
        .update({ phone: valeur })
        .eq('id', params.data.merchantId);

      if (error) {
        const failure = toHttpFailure(error);
        return reply.code(failure.status).send(failure.body);
      }
    }

    // --- Le numéro de connexion du propriétaire ----------------------
    if (body.data.owner_phone) {
      const valeur = normaliser(body.data.owner_phone);
      if (!valeur) return reply.code(400).send({ error: 'numéro de connexion invalide' });

      const service = serviceClient();
      // Supabase Auth enregistre le numéro sans « + » : on compare sur la
      // même forme, sinon aucune collision n'est jamais détectée.
      const sansPlus = valeur.slice(1);

      const { data: occupant } = await service
        .from('profiles')
        .select('id, full_name, role')
        .eq('phone', sansPlus)
        .maybeSingle();

      // Un numéro ne désigne qu'une personne : c'est lui l'identité. Le
      // déplacer sur un compte déjà pris couperait l'accès à son titulaire.
      if (occupant && occupant.id !== boutique.owner_id) {
        return reply.code(409).send({
          error: 'numéro déjà utilisé',
          message: `Ce numéro appartient déjà au compte de ${occupant.full_name} (${occupant.role}).`,
        });
      }

      const { error: erreurAuth } = await service.auth.admin.updateUserById(
        boutique.owner_id as string,
        { phone: valeur, phone_confirm: true },
      );

      if (erreurAuth) {
        return reply.code(502).send({
          error: 'changement de connexion impossible',
          message: erreurAuth.message,
        });
      }

      // Le trigger d'inscription ne recopie le numéro qu'à la création : il
      // faut le reporter nous-mêmes, sinon le profil garderait l'ancien et
      // toute recherche par téléphone tomberait à côté.
      const { error: erreurProfil } = await service
        .from('profiles')
        .update({ phone: sansPlus })
        .eq('id', boutique.owner_id as string);

      if (erreurProfil) {
        const failure = toHttpFailure(erreurProfil);
        return reply.code(failure.status).send(failure.body);
      }
    }

    return reply.send(envelope(`${boutique.name} mise à jour.`, []));
  });

  /** Le numéro de connexion actuel du propriétaire, pour l'afficher. */
  app.get('/admin/merchants/:merchantId/owner', admin, async (request, reply) => {
    const params = z.object({ merchantId: z.string().uuid() }).safeParse(request.params);
    if (!params.success) return reply.code(400).send({ error: 'identifiant invalide' });

    const { data: boutique } = await request.supabase!
      .from('merchants')
      .select('owner_id')
      .eq('id', params.data.merchantId)
      .maybeSingle();

    if (!boutique) return reply.code(404).send({ error: 'boutique introuvable' });

    const { data: profil } = await serviceClient()
      .from('profiles')
      .select('id, full_name, phone, role')
      .eq('id', boutique.owner_id as string)
      .maybeSingle();

    return reply.send({ owner: profil ?? null });
  });
}
