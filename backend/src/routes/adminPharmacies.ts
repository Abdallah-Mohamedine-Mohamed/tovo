import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { z } from 'zod';
import { env } from '../config/env.js';
import { viaLigneGoogle } from '../lib/ligneGoogle.js';
import { serviceClient } from '../services/supabase.js';
import { localiserPharmacieAvecGoogle, oublierGarde } from '../services/pharmaciesGarde.js';

/**
 * La mise à jour hebdomadaire des pharmacies de garde (01/10), par l'admin :
 *
 *  1. POST /admin/pharmacies-garde/lire : l'image de la semaine (celle que
 *     Lahiyata publie sur Facebook) → Gemini en lit le tableau → chaque
 *     pharmacie est placée (localiserPharmacie). Rien n'est enregistré.
 *  2. L'équipe vérifie, corrige au besoin (un numéro, une position collée
 *     depuis Google Maps).
 *  3. POST /admin/pharmacies-garde : publie la semaine (remplace celle qui
 *     commence à la même date).
 */

const CONSIGNE = `Cette image est la liste officielle des pharmacies de garde de Niamey (Niger).
Recopie-la EXACTEMENT, sans rien inventer ni corriger :
- debut et fin : les dates de la période (« DU 26/09 AU 03/10/2026 ») au format AAAA-MM-JJ ;
- pour chaque ligne : la commune (chiffre romain : I, II, III, IV ou V), le nom de la pharmacie tel qu'écrit,
  la localisation telle qu'écrite, et le téléphone (8 chiffres, sans espaces).
Une ligne illisible : recopie ce que tu lis, ne devine pas.`;

const SCHEMA = {
  type: 'OBJECT',
  properties: {
    debut: { type: 'STRING' },
    fin: { type: 'STRING' },
    pharmacies: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: {
          commune: { type: 'STRING' },
          nom: { type: 'STRING' },
          localisation: { type: 'STRING' },
          telephone: { type: 'STRING' },
        },
        required: ['commune', 'nom', 'localisation', 'telephone'],
      },
    },
  },
  required: ['debut', 'fin', 'pharmacies'],
};

const lireSchema = z.object({
  mime: z.enum(['image/jpeg', 'image/png', 'image/webp']),
  // ~6 Mo d'image en base64.
  data: z.string().min(100).max(8_000_000),
});

const pharmacieSchema = z.object({
  commune: z.string().trim().min(1).max(10),
  nom: z.string().trim().min(1).max(120),
  localisation: z.string().trim().max(200).default(''),
  telephone: z.string().transform((t) => t.replace(/\D/g, '').replace(/^227(?=\d{8}$)/, '')).pipe(z.string().regex(/^\d{8}$/, 'numéro à 8 chiffres')),
  lat: z.number().min(13.2).max(13.8).nullable(),
  lng: z.number().min(1.8).max(2.4).nullable(),
  precision: z.enum(['google', 'pharmacie', 'repere', 'quartier', 'manuelle']).nullable(),
});

const publierSchema = z.object({
  debut: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  fin: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  pharmacies: z.array(pharmacieSchema).min(1).max(200),
});

/** « 2026-09-26 » → le samedi 8 h, heure de Niamey. */
const a8h = (jour: string) => `${jour}T08:00:00+01:00`;

export async function adminPharmaciesRoutes(app: FastifyInstance): Promise<void> {
  const exigerAdmin = async (request: FastifyRequest, reply: FastifyReply): Promise<void> => {
    if (request.user?.role !== 'admin') {
      return reply.code(403).send({ error: 'réservé à l’administration' });
    }
  };
  const admin = { preHandler: [app.requireAuth, exigerAdmin] };

  app.post('/admin/pharmacies-garde/lire', { ...admin, bodyLimit: 9 * 1024 * 1024 }, async (request, reply) => {
    const body = lireSchema.safeParse(request.body);
    if (!body.success) return reply.code(400).send({ error: 'image invalide (JPEG, PNG ou WebP)' });
    if (!env.GEMINI_API_KEY) return reply.code(503).send({ error: 'lecture d’image indisponible (clé Gemini absente)' });

    const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${env.GEMINI_MODEL}:generateContent`, {
      method: 'POST',
      ...viaLigneGoogle,
      headers: { 'content-type': 'application/json', 'x-goog-api-key': env.GEMINI_API_KEY },
      body: JSON.stringify({
        contents: [{ role: 'user', parts: [{ text: CONSIGNE }, { inlineData: { mimeType: body.data.mime, data: body.data.data } }] }],
        generationConfig: { temperature: 0, responseMimeType: 'application/json', responseSchema: SCHEMA, maxOutputTokens: 8192 },
      }),
      signal: AbortSignal.timeout(60_000),
    }).catch(() => null);
    if (!r?.ok) return reply.code(502).send({ error: 'Gemini n’a pas pu lire l’image. Réessayez, ou saisissez la liste.' });
    const corps = (await r.json()) as { candidates?: Array<{ content?: { parts?: Array<{ text?: string; thought?: boolean }> } }> };
    const texte = corps.candidates?.[0]?.content?.parts?.filter((p) => !p.thought).map((p) => p.text ?? '').join('') ?? '';
    let lu: { debut: string; fin: string; pharmacies: Array<{ commune: string; nom: string; localisation: string; telephone: string }> };
    try {
      lu = JSON.parse(texte);
    } catch {
      return reply.code(502).send({ error: 'Lecture illisible. Réessayez avec une image plus nette.' });
    }
    // Chaque pharmacie placée, Google d'abord (en parallèle, ~1 s en tout).
    const pharmacies = await Promise.all(lu.pharmacies.map(async (p) => ({
      commune: p.commune.trim(),
      nom: p.nom.trim(),
      localisation: p.localisation.trim(),
      telephone: p.telephone.replace(/\D/g, ''),
      ...(await localiserPharmacieAvecGoogle(p.nom.trim(), p.localisation.trim())),
    })));
    return reply.send({ debut: lu.debut, fin: lu.fin, pharmacies });
  });

  app.post('/admin/pharmacies-garde', admin, async (request, reply) => {
    const body = publierSchema.safeParse(request.body);
    if (!body.success) {
      const premiere = body.error.issues[0];
      return reply.code(400).send({ error: `liste invalide : ${premiere?.path.join(' › ')} — ${premiere?.message}` });
    }
    const debut = a8h(body.data.debut);
    const fin = a8h(body.data.fin);
    if (new Date(fin) <= new Date(debut)) return reply.code(400).send({ error: 'la fin doit suivre le début' });

    const db = serviceClient();
    const suppression = await db.from('pharmacies_garde').delete().eq('debut', debut);
    if (suppression.error) return reply.code(500).send({ error: `${suppression.error.message} — la migration 0074 est-elle appliquée ?` });
    const insertion = await db.from('pharmacies_garde').insert(body.data.pharmacies.map((p) => ({ ...p, debut, fin })));
    if (insertion.error) return reply.code(500).send({ error: insertion.error.message });
    oublierGarde();
    request.log.info({ debut, pharmacies: body.data.pharmacies.length }, 'pharmacies de garde publiées');
    return reply.send({ publiees: body.data.pharmacies.length, debut, fin });
  });
}
