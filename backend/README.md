# Tovo — backend

Node 20+, TypeScript strict, Fastify. Déployé sur Railway.

```bash
cp .env.example .env    # renseigner les clés du projet staging
npm install
npm run dev             # http://localhost:3000/health
npm run typecheck
npm run test:rls        # tests RLS contre le projet staging
```

---

## Authentification

La connexion se fait par **OTP livré sur WhatsApp**, via le *Send SMS Hook* de
Supabase Auth.

```
Flutter ──signInWithOtp(phone)──▶ Supabase Auth (GoTrue)
                                       │  génère le code, gère expiration,
                                       │  rate-limit et session
                                       ▼
                            POST /hooks/auth/send-sms  (signé)
                                       │
                                       ▼
                          WhatsApp Cloud API (Meta)  ──▶  utilisateur
```

Le backend ne génère, ne stocke et ne vérifie **aucun** code : il transporte.
C'est la raison d'être de ce choix — on ne réimplémente pas de la sécurité
d'authentification quand GoTrue la fait déjà correctement.

Le template Meta doit être de catégorie **AUTHENTICATION** avec un bouton
« copier le code ». Meta exige alors que le code soit passé deux fois, dans le
corps *et* dans le paramètre du bouton — c'est fait dans
[src/services/whatsapp.ts](src/services/whatsapp.ts).

Changer de canal (ajouter un SMS de secours pour les numéros sans WhatsApp) ne
touche que ce fichier et la variable `OTP_CHANNEL`.

`OTP_CHANNEL=log` affiche le code en console pour le développement. Le démarrage
échoue si cette valeur est utilisée en production : un code de connexion dans
les logs Railway est lisible par tous ceux qui y ont accès.

---

## Les deux clients Supabase

Distinction non négociable, dans [src/services/supabase.ts](src/services/supabase.ts) :

| Client | Quand | RLS |
|---|---|---|
| `userClient(jwt)` | toute opération déclenchée par un utilisateur, **y compris les outils de l'IA** | active |
| `serviceClient()` | dispatch, embeddings, ETL, hook d'auth — traitements sans utilisateur | contournée |

**Un appel à `serviceClient()` dans `src/ai/` est un bug.** Les noms de produits
sont saisis par des boutiquiers, donc du texte tiers entre dans le contexte du
modèle ; si le modèle est manipulé, la RLS doit rester la dernière barrière.

---

## Structure

```
src/
├── config/env.ts          validation zod au démarrage, refus de démarrer si invalide
├── plugins/auth.ts        vérification du JWT, request.user + request.supabase
├── routes/
│   └── authHook.ts        POST /hooks/auth/send-sms (signature standard-webhooks)
├── services/
│   ├── supabase.ts        userClient / serviceClient / anonClient
│   └── whatsapp.ts        livraison OTP, canal remplaçable
└── index.ts               serveur, capture du corps brut, arrêt propre
```

Le corps brut de la requête est conservé sur `request.rawBody` : la signature du
hook porte sur les octets d'origine, un JSON reparsé puis re-sérialisé ne
produit pas la même signature.

---

## Tests RLS

`tests/rls/` crée quatre vrais utilisateurs, ouvre quatre vraies sessions, et
vérifie que chacun voit exactement ce qu'il doit voir. Couvert :

- un client ne voit que ses commandes ; un boutiquier celles de sa boutique ;
  un livreur les siennes plus le pool ouvert **de sa zone uniquement** ;
- l'idempotence : le même `client_order_id` ne crée pas deux commandes ;
- l'attribution atomique : deux livreurs qui acceptent en même temps, un seul gagne ;
- le suivi live : le client lit la position du livreur de **sa** commande, et
  cesse de la lire une fois livrée — ces policies sont exactement celles qui
  s'appliquent au flux Realtime ;
- un utilisateur ne peut pas se promouvoir `admin` ;
- un boutiquier ne peut pas modifier le catalogue d'un autre.

Ces tests écrivent en base. Le harness refuse de démarrer si `SUPABASE_URL`
contient « prod ».

---

## À venir

Phase 2 : `routes/cart.ts`, `routes/orders.ts`, `services/dispatch.ts` (BullMQ),
`services/pricing.ts`. Le backend émettra des `components[]` **scriptés**, sans
LLM, pour valider le contrat UI avant d'ajouter l'IA.

Phase 4 : `src/ai/` — `llmClient.ts`, `systemPrompt.ts`, `tools.ts`,
`validate.ts` (garde-fou anti-ID inventé), `orchestrator.ts`.
