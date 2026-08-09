/**
 * Dossier d'iconographie : une page construite depuis l'état réel de la base.
 *
 * Écrit plutôt que rédigé à la main pour une raison simple : une liste de 177
 * catégories recopiée est fausse dès la semaine suivante. Celle-ci se
 * régénère.
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { createClient } from '@supabase/supabase-js';

const db = createClient(
  process.env['SUPABASE_URL']!,
  process.env['SUPABASE_SERVICE_ROLE_KEY']!,
  { auth: { persistSession: false, autoRefreshToken: false } },
);

interface Cat {
  id: string;
  parent_id: string | null;
  name: string;
  slug: string;
  icon: string | null;
  is_active: boolean;
}

const { data, error } = await db
  .from('categories')
  .select('id, parent_id, name, slug, icon, is_active')
  .order('sort_order');
if (error) throw new Error(error.message);
const toutes = (data ?? []) as Cat[];

// Comptage en deux balayages plutôt qu'en 177 requêtes.
const produits = new Map<string, number>();
const boutiques = new Map<string, number>();
for (const table of ['products', 'merchants'] as const) {
  const cible = table === 'products' ? produits : boutiques;
  let de = 0;
  for (;;) {
    const page = await db.from(table).select('category_id').range(de, de + 999);
    if (page.error) throw new Error(page.error.message);
    for (const ligne of page.data ?? []) {
      const c = (ligne as { category_id: string | null }).category_id;
      if (c) cible.set(c, (cible.get(c) ?? 0) + 1);
    }
    if ((page.data?.length ?? 0) < 1000) break;
    de += 1000;
  }
}

// La liste que l'application affiche vraiment, et non celle de la table.
const vus = await db.rpc('browsable_categories');
const affichees = new Set(
  ((vus.data ?? []) as Array<{ id: string }>).map((c) => c.id),
);

const enfants = new Map<string | null, Cat[]>();
for (const c of toutes) {
  const l = enfants.get(c.parent_id) ?? [];
  l.push(c);
  enfants.set(c.parent_id, l);
}
const racines = enfants.get(null) ?? [];

interface Bloc {
  c: Cat;
  fils: Cat[];
  p: number;
  b: number;
}
const bloc = (c: Cat): Bloc => {
  const fils = enfants.get(c.id) ?? [];
  return {
    c,
    fils,
    // Le total inclut les enfants : les produits pendent aux feuilles, une
    // racine en compte presque toujours zéro en propre.
    p: (produits.get(c.id) ?? 0) + fils.reduce((s, f) => s + (produits.get(f.id) ?? 0), 0),
    b: (boutiques.get(c.id) ?? 0) + fils.reduce((s, f) => s + (boutiques.get(f.id) ?? 0), 0),
  };
};

const enLigne = racines.filter((r) => affichees.has(r.id)).map(bloc);
const fantomes = racines.filter((r) => !affichees.has(r.id)).map(bloc);

const rayons = enLigne
  .flatMap((m) =>
    m.fils
      .filter((f) => (produits.get(f.id) ?? 0) > 0 && f.is_active)
      .map((f) => ({ module: m.c.name, f, p: produits.get(f.id) ?? 0 })),
  )
  .sort((a, b) => b.p - a.p);

const police = (nom: string) =>
  readFileSync(`../mobile/assets/fonts/${nom}`).toString('base64');
const reg = police('DMSans-Regular.ttf');
const gras = police('DMSans-Bold.ttf');

const e = (s: string) =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const nb = (n: number) => n.toLocaleString('fr-FR').replace(/[  ]/g, ' ');

const date = new Date().toLocaleDateString('fr-FR', {
  day: 'numeric',
  month: 'long',
  year: 'numeric',
});

const emplacement = (nom: string, meta: string, icone: string | null) => `
        <div class="slot">
          <div class="cadre${icone ? ' pleine' : ''}">${
            icone ? e(icone) : '<span class="vide">?</span>'
          }</div>
          <div class="nom">${e(nom)}</div>
          <div class="meta">${meta}</div>
        </div>`;

const html = `<title>Icônes de catégories — Tovo</title>
<style>
@font-face{font-family:'DM Sans';src:url(data:font/ttf;base64,${reg}) format('truetype');font-weight:400;font-display:swap}
@font-face{font-family:'DM Sans';src:url(data:font/ttf;base64,${gras}) format('truetype');font-weight:700;font-display:swap}

:root{
  --fond:#FBFBFA; --carte:#FFFFFF; --encre:#12201F; --gris:#5E6664;
  --teal:#006666; --wash:#E8F2F1; --trait:#E4E8E7;
  --manque:#A85B0C; --manque-fond:#FBF1E6;
}
@media (prefers-color-scheme:dark){
  :root{--fond:#0E1514;--carte:#161F1E;--encre:#E8EDEC;--gris:#9AA5A3;
        --teal:#5FBDB5;--wash:#152423;--trait:#243130;
        --manque:#E0A264;--manque-fond:#241C12}
}
:root[data-theme="dark"]{--fond:#0E1514;--carte:#161F1E;--encre:#E8EDEC;--gris:#9AA5A3;
  --teal:#5FBDB5;--wash:#152423;--trait:#243130;--manque:#E0A264;--manque-fond:#241C12}
:root[data-theme="light"]{--fond:#FBFBFA;--carte:#FFFFFF;--encre:#12201F;--gris:#5E6664;
  --teal:#006666;--wash:#E8F2F1;--trait:#E4E8E7;--manque:#A85B0C;--manque-fond:#FBF1E6}

*{box-sizing:border-box}
body{margin:0;background:var(--fond);color:var(--encre);
  font-family:'DM Sans',system-ui,sans-serif;font-size:16px;line-height:1.55;
  -webkit-font-smoothing:antialiased}
.page{max-width:1060px;margin:0 auto;padding:56px 24px 96px;
  display:flex;flex-direction:column;gap:56px}

.tete{display:flex;flex-direction:column;gap:14px}
.eyebrow{font-size:12px;font-weight:700;letter-spacing:.14em;
  text-transform:uppercase;color:var(--teal)}
h1{margin:0;font-size:clamp(30px,5vw,46px);font-weight:700;
  letter-spacing:-.028em;line-height:1.08;text-wrap:balance}
.chapo{margin:0;max-width:62ch;color:var(--gris);font-size:17px}

.compteurs{display:flex;flex-wrap:wrap;gap:10px;margin-top:8px}
.compteur{background:var(--carte);border:1px solid var(--trait);border-radius:14px;
  padding:12px 18px;display:flex;flex-direction:column;gap:1px;min-width:130px}
.compteur b{font-size:27px;font-weight:700;letter-spacing:-.02em;
  font-variant-numeric:tabular-nums;line-height:1.15}
.compteur span{font-size:12px;color:var(--gris)}
.compteur.alerte{background:var(--manque-fond);border-color:transparent}
.compteur.alerte b{color:var(--manque)}

section{display:flex;flex-direction:column;gap:18px}
h2{margin:0;font-size:22px;font-weight:700;letter-spacing:-.018em}
.intro{margin:0;max-width:64ch;color:var(--gris);font-size:15px}

.grille{display:grid;grid-template-columns:repeat(auto-fill,minmax(148px,1fr));gap:14px}
.slot{display:flex;flex-direction:column;align-items:center;gap:9px;text-align:center;
  background:var(--carte);border:1px solid var(--trait);border-radius:20px;padding:20px 12px}
.cadre{width:62px;height:62px;border-radius:50%;display:grid;place-items:center;
  border:2px dashed var(--trait);font-size:27px}
.cadre.pleine{border-style:solid;border-color:transparent;background:var(--wash)}
.vide{font-size:23px;font-weight:700;color:var(--trait)}
.nom{font-weight:700;font-size:14px;line-height:1.25}
.meta{font-size:12px;color:var(--gris);font-variant-numeric:tabular-nums}

.tableau{overflow-x:auto;border:1px solid var(--trait);border-radius:18px;
  background:var(--carte)}
table{border-collapse:collapse;width:100%;min-width:520px}
th,td{text-align:left;padding:11px 18px;border-bottom:1px solid var(--trait);font-size:14px}
th{font-size:11px;text-transform:uppercase;letter-spacing:.1em;color:var(--gris);font-weight:700}
tr:last-child td{border-bottom:none}
td.n{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
td.mod{color:var(--gris);font-size:13px}
.pastille{display:inline-block;padding:2px 10px;border-radius:999px;
  font-size:11px;font-weight:700;background:var(--manque-fond);color:var(--manque)}
footer{color:var(--gris);font-size:13px;border-top:1px solid var(--trait);padding-top:22px}
</style>

<div class="page">
  <header class="tete">
    <div class="eyebrow">Dossier d'iconographie</div>
    <h1>Les catégories qui ont besoin d'une icône</h1>
    <p class="chapo">Relevé de la base au ${date}. Les catégories sont classées par ce qu'elles
      portent réellement : une catégorie sans produit ni boutique n'apparaît nulle part dans
      l'application, et n'a donc pas besoin d'être dessinée.</p>
    <div class="compteurs">
      <div class="compteur"><b>${toutes.length}</b><span>catégories en base</span></div>
      <div class="compteur"><b>${enLigne.length}</b><span>modules affichés</span></div>
      <div class="compteur alerte"><b>${enLigne.filter((m) => !m.c.icon).length}</b><span>sans icône</span></div>
      <div class="compteur"><b>${rayons.length}</b><span>rayons à catalogue</span></div>
    </div>
  </header>

  <section>
    <h2>1 &middot; Les modules de l'accueil</h2>
    <p class="intro">La grille que le client voit en ouvrant Tovo. C'est la seule iconographie
      visible dès le premier écran, et aucun de ces modules n'en a : l'application affiche
      aujourd'hui le même sac générique pour les ${enLigne.length}.</p>
    <div class="grille">${enLigne
      .map((m) => emplacement(m.c.name, `${nb(m.b)} boutiques · ${nb(m.p)} produits`, m.c.icon))
      .join('')}
    </div>
  </section>

  <section>
    <h2>2 &middot; Les rayons</h2>
    <p class="intro">Sous-catégories qui portent effectivement des produits. Elles s'affichent
      au second écran, en plus petit, quand on ouvre un module ou une boutique. Une icône y aide
      à repérer, mais le nom suffit à comprendre : à traiter après les modules, par ordre de volume.</p>
    <div class="tableau">
      <table>
        <thead><tr><th>Rayon</th><th>Module</th><th class="n">Produits</th></tr></thead>
        <tbody>
${rayons
  .map(
    (r) =>
      `          <tr><td><strong>${e(r.f.name)}</strong></td><td class="mod">${e(r.module)}</td><td class="n">${nb(r.p)}</td></tr>`,
  )
  .join('\n')}
        </tbody>
      </table>
    </div>
  </section>

  <section>
    <h2>3 &middot; À ne pas dessiner</h2>
    <p class="intro">Créées au démarrage du projet, jamais remplies. Plusieurs portent déjà un
      emoji — ce sont celles des maquettes, et elles font double emploi avec les modules
      ci-dessus. Elles méritent d'être supprimées plutôt qu'illustrées.</p>
    <div class="tableau">
      <table>
        <thead><tr><th>Catégorie</th><th>Icône posée</th><th class="n">Contenu</th></tr></thead>
        <tbody>
${fantomes
  .map(
    (m) =>
      `          <tr><td><strong>${e(m.c.name)}</strong></td><td>${
        m.c.icon ? e(m.c.icon) : '<span class="pastille">aucune</span>'
      }</td><td class="n">${
        m.p === 0 && m.b === 0
          ? '<span class="pastille">vide</span>'
          : `${nb(m.b)} boutiques · ${nb(m.p)} produits`
      }</td></tr>`,
  )
  .join('\n')}
        </tbody>
      </table>
    </div>
  </section>

  <footer>Généré depuis la base Tovo · ${toutes.length} catégories · composé en DM&nbsp;Sans,
    la police de l'application.</footer>
</div>`;

const sortie = process.argv[2];
if (!sortie) throw new Error('chemin de sortie attendu en argument');
writeFileSync(sortie, html, 'utf8');

console.log('page écrite :', sortie);
console.log(
  `  ${enLigne.length} modules affichés · ${rayons.length} rayons · ${fantomes.length} fantômes`,
);
process.exit(0);
