/**
 * FICHES DE RECHERCHE de Niger Beauté (19/10) : pour chaque article, une
 * description en français et des étiquettes, écrites par une IA d'après le nom
 * ET la photo du produit (l'étiquette dit les ingrédients, la contenance).
 *
 * Pourquoi : les descriptions de l'inventaire étaient creuses (« … est un gel
 * douche gommant destiné à un usage cosmétique ») et les noms en anglais ; la
 * contenance et la variante — ce qui sépare deux Purest Glow — n'étaient pas
 * des étiquettes. La recherche lit nom + description + étiquettes.
 *
 *   npx tsx --env-file=.env scripts/niger-beaute/decrire.ts --modele <m> [--ids NB-1,NB-2] [--sortie f.json]
 *     <m> : gemini:<modèle> ou openrouter:<modèle>
 *
 * Reprenable : ce qui est déjà dans la sortie n'est pas refait. N'écrit rien
 * dans Tovo — charger.ts lit le fichier produit.
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import sharp from 'sharp';

const args = process.argv.slice(2);
const opt = (nom: string) => { const i = args.indexOf(`--${nom}`); return i >= 0 ? args[i + 1] : undefined; };
const DOSSIER = 'C:\\Users\\abdal\\Documents\\niger beaute catalogue';
const MODELE = opt('modele') ?? 'gemini:gemini-3.8-flash';
const SORTIE = opt('sortie') ?? join(DOSSIER, 'descriptions.json');
const IDS = opt('ids')?.split(',');

function lireCsv(texte: string): Record<string, string>[] {
  const lignes: string[][] = [];
  let ligne: string[] = [], champ = '', g = false;
  texte = texte.replace(/^\uFEFF/, '');
  for (let i = 0; i < texte.length; i++) {
    const c = texte[i];
    if (g) { if (c === '"') { if (texte[i + 1] === '"') { champ += '"'; i++; } else g = false; } else champ += c; }
    else if (c === '"') g = true;
    else if (c === ';') { ligne.push(champ); champ = ''; }
    else if (c === '\n') { ligne.push(champ.replace(/\r$/, '')); lignes.push(ligne); ligne = []; champ = ''; }
    else champ += c;
  }
  if (champ || ligne.length) { ligne.push(champ); lignes.push(ligne); }
  const [h, ...r] = lignes.filter((l) => l.length > 1);
  return r.map((l) => Object.fromEntries(h.map((k, i) => [k.trim(), (l[i] ?? '').trim()])));
}

const CONSIGNE = `Tu écris la fiche de recherche d'un produit vendu par une boutique de cosmétiques à Niamey (Niger), pour une application de livraison. Les clients cherchent en français, parfois avec des fautes, parfois avec le nom anglais.

Tu reçois le nom du produit, sa fiche et sa photo. N'utilise QUE ce que disent le nom, la fiche et l'étiquette visible sur la photo. N'invente aucun bienfait, ingrédient, parfum ou contenance, et n'ajoute ni public (homme, femme, enfant) ni effet promis qui ne soit écrit sur l'étiquette ou dans le nom — même si tu crois connaître le produit. Si l'étiquette est en anglais, traduis fidèlement (whitening = éclaircissant, scrub = gommant, shower gel = gel douche, body lotion = lait corporel).

Rends un JSON :
- "description" : 1 ou 2 phrases en français (240 caractères au plus) qui disent ce qu'est le produit, ce qui le distingue (variante, ingrédients ou parfum nommés sur l'étiquette) et sa contenance. Recopie les dosages s'ils sont écrits sur l'étiquette (« niacinamide 35 % »). Ni slogan ni jugement (« généreux », « idéal », « parfait »), pas de point d'exclamation, et rien sur ce qui n'est pas indiqué.
- "etiquettes" : 6 à 12 mots ou expressions courts, en minuscules, que des clients taperaient pour le trouver : la nature du produit en français, la marque, la variante et ses ingrédients clés, la contenance sous ses formes usuelles (« 1000 ml », « 1 l »), et le nom anglais du type de produit si l'étiquette est en anglais.`;

const SCHEMA = { type: 'OBJECT', properties: { description: { type: 'STRING' }, etiquettes: { type: 'ARRAY', items: { type: 'STRING' } } }, required: ['description', 'etiquettes'] };

async function appeler(entree: string, image: string | null): Promise<{ description: string; etiquettes: string[]; jetons: [number, number] }> {
  const [fournisseur, ...reste] = MODELE.split(':');
  const modele = reste.join(':');
  if (fournisseur === 'gemini') {
    const parts: unknown[] = [{ text: entree }];
    if (image) parts.push({ inline_data: { mime_type: 'image/jpeg', data: image } });
    const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${modele}:generateContent`, {
      method: 'POST', headers: { 'content-type': 'application/json', 'x-goog-api-key': process.env.GEMINI_API_KEY! },
      signal: AbortSignal.timeout(60_000),
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: CONSIGNE }] }, contents: [{ role: 'user', parts }],
        // Réflexion basse : 2 s au lieu de 7 et ~500 jetons de réflexion facturés
        // en moins par fiche, pour une fiche courte tirée de l'étiquette.
        generationConfig: { temperature: 0.2, responseMimeType: 'application/json', responseSchema: SCHEMA, thinkingConfig: { thinkingLevel: 'low' } },
      }),
    });
    const j = await r.json() as { candidates?: Array<{ content?: { parts?: Array<{ text?: string; thought?: boolean }> } }>; usageMetadata?: { promptTokenCount?: number; candidatesTokenCount?: number }; error?: { message: string } };
    if (j.error) throw new Error(j.error.message);
    const texte = (j.candidates?.[0]?.content?.parts ?? []).filter((p) => !p.thought).map((p) => p.text ?? '').join('');
    return { ...JSON.parse(texte), jetons: [j.usageMetadata?.promptTokenCount ?? 0, j.usageMetadata?.candidatesTokenCount ?? 0] };
  }
  const contenu: unknown[] = [{ type: 'text', text: entree }];
  if (image) contenu.push({ type: 'image_url', image_url: { url: `data:image/jpeg;base64,${image}` } });
  const r = await fetch('https://openrouter.ai/api/v1/chat/completions', {
    method: 'POST', headers: { authorization: `Bearer ${process.env.OPENROUTER_API_KEY}`, 'content-type': 'application/json' },
    signal: AbortSignal.timeout(90_000),
    body: JSON.stringify({
      model: modele, reasoning: { effort: 'low' }, response_format: { type: 'json_object' },
      messages: [{ role: 'system', content: `${CONSIGNE}\nRéponds uniquement par le JSON.` }, { role: 'user', content: contenu }],
    }),
  });
  const j = await r.json() as { choices?: Array<{ message?: { content?: string } }>; usage?: { prompt_tokens?: number; completion_tokens?: number }; error?: { message: string } };
  if (j.error) throw new Error(j.error.message);
  const texte = (j.choices?.[0]?.message?.content ?? '').replace(/^```(?:json)?\s*|\s*```$/g, '');
  return { ...JSON.parse(texte), jetons: [j.usage?.prompt_tokens ?? 0, j.usage?.completion_tokens ?? 0] };
}

const inventaire = lireCsv(readFileSync(join(DOSSIER, 'inventaire.csv'), 'utf8'));
const deja: Record<string, unknown> = existsSync(SORTIE) ? JSON.parse(readFileSync(SORTIE, 'utf8')) : {};
const cibles = inventaire.filter((a) => (IDS ? IDS.includes(a.id) : true) && !deja[a.id]);
console.log(`${MODELE} — ${cibles.length} fiches à écrire → ${SORTIE}`);

let entrees = 0, sorties = 0, echecs = 0, faites = 0;
// Plusieurs fiches à la fois : une par une, 1 013 fiches prenaient 5 heures
// (15 à 20 s chacune, l'image comprise). L'écriture reste unique (Node n'a
// qu'un fil), donc sans collision.
const PARALLELE = Number(opt('parallele') ?? 8);
const file = [...cibles];
await Promise.all(Array.from({ length: PARALLELE }, async () => {
  for (let a = file.shift(); a; a = file.shift()) await traiter(a);
}));
console.log(`\n✓ ${cibles.length - echecs} fiches, ${echecs} échecs ; jetons ${entrees} entrée / ${sorties} sortie`);

async function traiter(a: Record<string, string>): Promise<void> {
  const fichier = join(DOSSIER, 'images', `${a.id}.jpg`);
  const image = existsSync(fichier)
    ? (await sharp(fichier).resize(768, 768, { fit: 'inside' }).jpeg({ quality: 85 }).toBuffer()).toString('base64')
    : null;
  const entree = JSON.stringify({
    nom: a.nom, marque: a.marque, gamme: a.gamme, contenance: a.contenance, variante: a.variante,
    rayon: a.sous_categorie, imitation_de_parfum: a.imitation === 'oui', mots_cles: a.mots_cles,
  });
  for (let essai = 1; essai <= 3; essai++) {
    try {
      const f = await appeler(entree, image);
      deja[a.id] = { description: f.description.trim(), etiquettes: f.etiquettes.map((e) => e.trim().toLowerCase()).filter(Boolean), modele: MODELE };
      entrees += f.jetons[0]; sorties += f.jetons[1];
      break;
    } catch (cause) {
      if (essai === 3) { echecs++; console.log(`\n✗ ${a.id} : ${(cause as Error).message.slice(0, 120)}`); }
      else await new Promise((ok) => setTimeout(ok, 4000 * essai));
    }
  }
  // Écrit à chaque fiche : une coupure ne perd rien.
  writeFileSync(SORTIE, JSON.stringify(deja, null, 1));
  process.stdout.write(`\r  ${++faites}/${cibles.length}`);
}
