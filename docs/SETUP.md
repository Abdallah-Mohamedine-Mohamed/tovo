# Mise en route — pas à pas

Ordre à respecter. Chaque étape a un critère de validation : ne passe à la
suivante que s'il est vert.

Deux choses sont longues et ne dépendent pas de toi : **l'approbation du
template WhatsApp par Meta** (étape 5) et rien d'autre. Lance-la tôt — c'est
l'étape 5, mais tu peux la démarrer dès maintenant en parallèle du reste.

---

## Étape 0 — Ce que tu ne dois jamais faire

Ne colle **aucune clé** dans une conversation, un ticket ou un commit. Les clés
vont dans `backend/.env`, qui est déjà dans `.gitignore`. La `service_role key`
en particulier contourne toute la sécurité de la base : quiconque l'obtient lit
et modifie l'intégralité des données.

---

## Étape 1 — Créer le projet Supabase de staging

**Oui, il faut un nouveau projet.** Et à terme deux : `tovo-staging` et
`tovo-prod`. Commence par staging seul — on ne crée la production qu'au moment
du lancement.

1. https://supabase.com/dashboard → **New project**
2. Nom : `tovo-staging`
3. Région : la plus proche de l'Europe de l'Ouest proposée dans la liste
   (Irlande, Londres ou Francfort selon ce qui est offert). C'est le meilleur
   compromis de latence depuis Niamey.
4. Mot de passe de base de données : génère-le, **garde-le dans ton gestionnaire
   de mots de passe**. Il n'est pas récupérable ensuite.
5. Plan : Free suffit pour staging.

⏱ La création prend 2 à 3 minutes.

**Validation** : le projet apparaît « Active » (point vert) dans le dashboard.

---

## Étape 2 — Activer les extensions

**Database → Extensions**, cherche et active :

| Extension | Rôle |
|---|---|
| `postgis` | géolocalisation, zones, distances |
| `vector` | recherche sémantique produits |
| `pg_cron` | purge automatique des positions livreurs |

`pgcrypto` est déjà active par défaut.

**Validation** : les trois affichent « Enabled ».

> Si `pg_cron` n'apparaît pas, c'est qu'elle n'est pas disponible sur le plan
> Free de ta région. Dans ce cas, saute-la : le fichier `0002` échouera sur la
> ligne `create extension pg_cron` — retire alors les deux blocs
> `cron.schedule` et exécute le reste. La purge devra être branchée autrement
> plus tard ; signale-le-moi.

---

## Étape 3 — Exécuter le schéma

**SQL Editor → New query**. Trois fichiers, **dans cet ordre**, un par un.
Copie tout le contenu, colle, `Run`. Attends « Success » avant le suivant.

1. `supabase/schema.sql`
2. `supabase/migrations/0002_retention_and_maintenance.sql`
3. `supabase/seed.sql`

On passe par l'éditeur SQL et non par le CLI pour cette première pose : c'est
plus direct et ça ne dépend pas de l'authentification CLI. Les migrations
suivantes passeront par `supabase db push`.

**Validation** — exécute ceci, tu dois obtenir 9 catégories et 8 zones :

```sql
select
  (select count(*) from categories where parent_id is null) as categories,
  (select count(*) from delivery_zones)                     as zones,
  (select count(*) from pg_policies where schemaname='public') as policies;
```

Attendu : `categories = 9`, `zones = 8`, `policies` ≥ 35.

---

## Étape 4 — Créer les buckets Storage

**Storage → New bucket**, trois fois :

| Nom | Public |
|---|---|
| `products` | ✅ oui |
| `search-images` | ❌ non |
| `proofs` | ❌ non |

Puis, dans **SQL Editor**, exécute
`supabase/migrations/0003_storage_policies.sql`. Créer un bucket ne crée
aucune policy : sans ce fichier, personne ne peut téléverser dans `products`
et les deux buckets privés sont inaccessibles.

**Validation** : les trois buckets sont listés, `products` marqué « Public »,
et la requête suivante renvoie 9 :

```sql
select count(*) from pg_policies
where schemaname='storage' and tablename='objects' and policyname like 'tovo_%';
```

---

## Étape 5 — Le template WhatsApp (à lancer dès maintenant)

C'est la seule étape avec un délai externe : Meta doit approuver le template.
Compte quelques heures à quelques jours.

Dans **Meta Business Manager → WhatsApp → Modèles de messages** :

1. **Créer un modèle**
2. Catégorie : **Authentification** (surtout pas Marketing ni Utilitaire —
   les templates d'authentification ont un traitement et un tarif à part)
3. Nom : `tovo_otp`
4. Langue : **Français**
5. Type de bouton : **Copier le code**
6. Durée de validité du code : **10 minutes**
7. Coche l'avertissement de sécurité (« Ne partagez pas ce code »)

Le corps d'un template d'authentification est imposé par Meta, tu n'as pas à le
rédiger — c'est normal.

Récupère ensuite, dans **WhatsApp → Configuration de l'API** :

- l'**ID du numéro de téléphone** (`WHATSAPP_PHONE_NUMBER_ID`)
- un **token d'accès permanent** : crée un *Utilisateur système* avec le rôle
  admin sur l'app, puis génère un token sans expiration avec les permissions
  `whatsapp_business_messaging` et `whatsapp_business_management`.
  Un token temporaire de 24 h te fera perdre du temps.

**Validation** : le template passe en « Approuvé ».

---

## Étape 6 — Renseigner le backend et valider les RLS

Dans **Project Settings → API** du projet Supabase, relève l'URL, la clé `anon`
et la clé `service_role`.

```bash
cd backend
cp .env.example .env
```

Renseigne dans `.env` :

```
SUPABASE_URL=https://xxxx.supabase.co
SUPABASE_ANON_KEY=...
SUPABASE_SERVICE_ROLE_KEY=...
AUTH_HOOK_SECRET=placeholder   # rempli à l'étape 8
OTP_CHANNEL=log
```

Puis :

```bash
npm install
npm run test:rls
```

**Validation** : tous les tests passent. C'est le jalon de la Phase 1 — la
sécurité de la base est démontrée, pas supposée.

Si un test échoue, envoie-moi la sortie complète : c'est une policy à corriger,
pas un test à contourner.

---

## Étape 7 — Déployer le backend sur Railway

Le hook d'authentification Supabase a besoin d'une URL publique. Il faut donc
déployer avant de configurer l'auth.

1. https://railway.app → **New Project → Deploy from GitHub repo**
   (crée d'abord le dépôt : `git init`, commit, push — le `.gitignore` est prêt)
2. Racine du service : `backend`
3. Build : `npm run build` · Start : `npm start`
4. Variables : recopie ton `.env`, avec ces deux différences —
   `NODE_ENV=production` et `OTP_CHANNEL=whatsapp`
   (le démarrage échoue volontairement si tu laisses `log` en production : un
   code de connexion dans les logs Railway est lisible par tous ceux qui y ont
   accès)
5. Ajoute les variables WhatsApp de l'étape 5.

**Validation** : `https://ton-app.up.railway.app/health` renvoie
`{"status":"ok","contract":1}`.

---

## Étape 8 — Brancher l'authentification par WhatsApp

Dans le dashboard Supabase :

1. **Authentication → Providers → Phone** : activer.
   **Ne configure aucun fournisseur SMS** (pas de Twilio, pas de Vonage).
2. **Authentication → Hooks → Send SMS Hook** : activer, type **HTTPS**, URL :
   `https://ton-app.up.railway.app/hooks/auth/send-sms`
3. Copie le secret généré (`v1,whsec_…`) dans la variable `AUTH_HOOK_SECRET`
   sur Railway, et redéploie.
4. **Authentication → Providers → Phone** : OTP expiry `600` s, longueur `6`.

**Validation** : depuis un client Supabase, `signInWithOtp({ phone: '+227…' })`
sur ton propre numéro. Tu dois recevoir le code sur WhatsApp en quelques
secondes, et `verifyOtp` doit ouvrir une session.

Si rien n'arrive, regarde les logs Railway : le message est explicite
(signature invalide, template refusé, numéro non autorisé). Tant que ton compte
WhatsApp est en mode test, seuls les numéros ajoutés en destinataires autorisés
reçoivent les messages — c'est la cause la plus fréquente.

---

## Étape 9 — Authentifier le CLI Supabase

Utile pour la suite (migrations versionnées plutôt que copier-coller).

1. https://supabase.com/dashboard/account/tokens → **Generate new token**,
   nom `tovo-cli`
2. Dans PowerShell, à la racine du dépôt :

```powershell
$env:SUPABASE_ACCESS_TOKEN = "sbp_..."
npx supabase link --project-ref <ref-du-projet>
```

Le `project-ref` est la chaîne dans l'URL du dashboard :
`https://supabase.com/dashboard/project/`**`abcdefghijklmnop`**

Pour le rendre permanent : `setx SUPABASE_ACCESS_TOKEN "sbp_..."` puis rouvre
le terminal.

**Validation** : `npx supabase projects list` affiche `tovo-staging`.

---

## Où on en est ensuite

Les étapes 1 à 8 closent la **Phase 1** : base posée, sécurité vérifiée,
connexion fonctionnelle.

Je peux alors attaquer la **Phase 2** — `/cart`, `/orders`, le dispatch BullMQ
et les composants scriptés côté backend, sans IA, pour prouver qu'une vraie
commande passe de bout en bout.

Deux choses que tu peux préparer en parallèle et qui me seront utiles :

- **Le Bundle ID iOS et le package name Android de l'app actuelle.** Ils sont
  dans le dépôt `sanjayjangid1404/tovo` (`android/app/build.gradle` →
  `applicationId`, et `ios/Runner.xcodeproj` → `PRODUCT_BUNDLE_IDENTIFIER`), ou
  dans App Store Connect et la Google Play Console. Sans eux, la mise à jour
  devient une nouvelle fiche store et on perd les utilisateurs existants.
- **Un accès en lecture à l'ancienne base MySQL** (dump suffit), pour écrire
  l'ETL de migration des boutiques, produits et numéros de téléphone.
