# Supabase — mise en place

## Ordre d'exécution

Dans l'éditeur SQL, sur un projet **vierge**, dans cet ordre :

1. `schema.sql` — tables, RPC, RLS, triggers, Realtime
2. `migrations/0002_retention_and_maintenance.sql` — purges, verrou d'attribution, encaissement cash
3. `seed.sql` — catégories et zones de Niamey

Deux projets sont nécessaires : **staging** et **production**. On remplace le
backend d'une app déjà publiée sur les stores ; tester en production n'est pas
une option.

---

## Ce qui se configure dans le dashboard, pas en SQL

### 1. Extensions

`postgis`, `vector`, `pgcrypto` et `pg_cron` sont activées par les scripts, mais
`pg_cron` doit d'abord être autorisée dans **Database → Extensions**. Si le
`create extension pg_cron` échoue, c'est ça.

### 2. Auth — connexion par téléphone

**Authentication → Providers → Phone** : activer.
Ne pas configurer Twilio ni aucun autre fournisseur SMS.

**Authentication → Hooks → Send SMS Hook** : activer, type HTTP, pointer sur

```
https://<backend-railway>/hooks/auth/send-sms
```

Copier le secret généré (`v1,whsec_…`) dans la variable d'environnement
`AUTH_HOOK_SECRET` du backend.

Supabase génère le code, gère l'expiration, le rate-limit et la session. Notre
backend ne fait que **livrer** le message — par WhatsApp Cloud API. Le canal est
isolé dans `backend/src/services/whatsapp.ts` ; en ajouter un second (SMS de
secours pour les numéros sans WhatsApp) ne touche que ce fichier et
`OTP_CHANNEL`.

Régler **Phone OTP expiry** à 600 s et la longueur du code à 6 chiffres, pour
correspondre au template WhatsApp.

### 3. Storage

Trois buckets à créer :

| Bucket | Public | Usage |
|---|---|---|
| `products` | oui | images produits, servies dans les composants |
| `search-images` | non | photos de recherche client, TTL 24 h |
| `proofs` | non | preuves de livraison |

Policies sur `search-images` et `proofs` : l'utilisateur écrit dans son propre
dossier `{auth.uid()}/…`, le backend lit avec la `service_role`. Les images de
recherche ne transitent jamais en base64 par `/chat` — Flutter téléverse et ne
passe qu'un chemin.

### 4. Realtime

Déjà activé par `schema.sql` sur `orders`, `order_status_history`, `messages`,
`driver_locations`, `cart_items`. Vérifier dans **Database → Publications** que
`supabase_realtime` les liste bien.

Les policies RLS s'appliquent aux flux Realtime : un client abonné à
`driver_locations` ne reçoit que les pings du livreur de **sa** commande en
cours. C'est testé dans `backend/tests/rls/`.

---

## Vérifier avant de passer à la suite

```bash
cd backend
cp .env.example .env      # renseigner les clés du projet staging
npm install
npm run test:rls
```

Les tests créent quatre utilisateurs (client, livreur, boutiquier, admin) et
vérifient que chacun voit exactement ce qu'il doit voir. Tant qu'ils ne passent
pas, on ne construit pas la couche au-dessus.

---

## Notes de schéma

- **Montants** : entiers XOF partout. Aucune colonne `numeric` pour de l'argent.
- **`products.embedding`** est l'unique espace vectoriel interrogé. La recherche
  par image fait Vision → description → embedding texte et matche cette colonne.
  `products.image_embedding` existe pour un futur modèle multimodal, elle n'est
  ni peuplée ni indexée.
- **Index vectoriels en HNSW**, pas ivfflat : ivfflat construit ses listes à la
  création et donne un rappel médiocre tant que la table est vide.
- **`orders(user_id, client_order_id)`** est unique : c'est la clé d'idempotence.
  Flutter génère l'UUID avant l'envoi. Sur le réseau nigérien, sans ça, les
  doubles commandes sont garanties.
- **`driver_locations`** est séparée de `driver_profiles` pour que le ping de
  10 s ne réveille pas les triggers métier ni ne gonfle la WAL.
