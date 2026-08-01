# Tovo — Document maître

Version 1.1 — Juillet 2026
Fondateur : Mohamedine · Niamey, Niger

---

## 1. Le produit

Tovo est une application de livraison dont l'interface est une **conversation**,
pas un catalogue. Toile blanche, barre de saisie en bas, comme Claude ou ChatGPT
— sauf que l'IA ne répond pas qu'en texte : elle émet des **composants
interactifs natifs** (cartes produits, sélecteurs d'options, panier, suivi live)
qui s'affichent dans le fil.

Ce que personne d'autre ne fait sur ce marché :

- recherche en langage naturel **et par image** (photo → où l'acheter, à quel prix) ;
- comparateur de prix hybride : boutiques partenaires **et** offres externes ;
- langues locales : haoussa, zarma, français nigérien ;
- produits locaux indexés : tuo zaafi, fura, dèguè, acha, bouillie ;
- adressage par épingle GPS — à Niamey l'adresse postale n'existe pas ;
- paiement espèces et mobile money (Nita) ;
- **service Coursier** : un colis d'un point A à un point B, sans catalogue.

Identité visuelle : blanc `#FFFFFF`, accent teal `#006666`, typo DM Sans.

### Trois services, une conversation

| Service | Flux | Modèle |
|---|---|---|
| **Livraison** | catégorie ou recherche → produit → options → panier → commande | `orders.type = 'delivery'` |
| **Coursier** | départ → arrivée → taille colis → estimation → confirmation | `orders.type = 'courier'` + `courier_details` |
| **Comparateur** | requête texte ou photo → tableau de prix | lecture seule, débouche sur une commande partenaire |

Le comparateur est **hybride et honnête** : les boutiques partenaires sont
commandables, les offres externes (Jumia, Amazon…) sont consultables. La
distinction est visuelle et jamais ambiguë — on ne fait pas croire qu'on peut
commander chez un marchand hors plateforme.

---

## 2. Les quatre interfaces

| Rôle | Ce qu'il voit |
|---|---|
| **Client** | Le fil conversationnel generative-UI. Le cœur du projet. |
| **Livreur** | Interface terrain, offline-first. Une seule chose à la fois. |
| **Boutiquier** | Catalogue, stock, commandes entrantes en temps réel. |
| **Admin** | Dashboard Refine.js. Voit tout, contrôle tout. |

---

## 3. Stack

**Backend** — Node.js + TypeScript sur Railway. Supabase (Postgres, PostGIS,
pgvector, Realtime, Auth, Storage). Redis + BullMQ pour le dispatch et les
notifications. Firebase FCM pour le push. Gemini 2.5 Flash derrière une
abstraction swappable. OpenAI `text-embedding-3-small` (1536) pour les
embeddings. Nita pour le mobile money.

**Mobile** — Flutter, une codebase, trois flavors : `main_client.dart`,
`main_driver.dart`, `main_merchant.dart`. L'app client **conserve le Bundle ID
iOS et le package name Android existants** : c'est une mise à jour, pas une
nouvelle fiche store.

**Admin** — Refine.js avec le connecteur Supabase natif.

---

## 4. Structure des dépôts

```
tovo/
├── supabase/
│   ├── schema.sql              ← à exécuter en premier
│   └── migrations/
├── backend/src/
│   ├── ai/
│   │   ├── systemPrompt.ts
│   │   ├── tools.ts            ← définitions + exécuteurs
│   │   ├── orchestrator.ts     ← la boucle
│   │   ├── validate.ts         ← garde-fou anti-ID inventé
│   │   └── llmClient.ts        ← abstraction LLM
│   ├── routes/
│   │   ├── chat.ts             ← POST /chat
│   │   ├── cart.ts             ← panier, SANS tour LLM
│   │   ├── orders.ts           ← commande, SANS tour LLM
│   │   └── webhooks.ts         ← callback Nita
│   ├── services/
│   │   ├── supabase.ts         ← client par-JWT + client service
│   │   ├── embeddings.ts
│   │   ├── vision.ts
│   │   ├── dispatch.ts         ← BullMQ
│   │   ├── pricing.ts          ← frais de livraison, estimation coursier
│   │   └── notifications.ts    ← FCM
│   └── index.ts
├── mobile/lib/
│   ├── main_client.dart · main_driver.dart · main_merchant.dart
│   ├── core/                   ← supabase, auth, thème #006666, config
│   ├── components/
│   │   ├── registry.dart       ← le dispatcher (écrit)
│   │   ├── register_all.dart   ← enregistre les 12 builders
│   │   └── widgets/            ← un fichier par composant
│   └── features/
│       ├── chat/ catalog/ cart/ orders/ courier/ driver/ merchant/
├── admin/
└── docs/
    ├── tovo_ui_contract.md
    ├── tovo_project.md
    └── TOVO_AGENT_BRIEFING.md
```

---

## 5. Le cerveau IA

### 5.1 Principe

L'IA est un **orchestrateur**, jamais une base de connaissances. Elle n'a
jamais le catalogue en contexte. Elle interroge la base par des outils, reçoit
5 à 8 résultats maximum, et compose une réponse en composants.

### 5.2 Le prompt système

```
Tu es l'assistant de commande de Tovo, un service de livraison à Niamey (Niger).
Ton rôle : aider l'utilisateur à trouver des produits, composer sa commande,
envoyer un colis, comparer des prix, et suivre sa livraison — dans une
conversation fluide et interactive.

CONDUITE
- Parle français. Si l'utilisateur écrit en haoussa ou zarma, adapte-toi.
- Va droit au but. Une question à la fois. Pas de longs paragraphes.
- Connais les produits locaux : tuo zaafi, fura, dèguè, acha, bouillie.
- Les repères sont des quartiers : Plateau, Yantala, Koira Kano,
  Niamey 2000, Aéroport, Talladjé, Saga.

RÈGLE ABSOLUE — TU N'INVENTES RIEN
- Tu ne connais QUE ce que tes outils te renvoient.
- N'invente jamais un produit, un prix, une boutique, ni un identifiant.
- Si un outil ne renvoie rien, dis-le et propose une alternative.
- Tous les montants sont en francs CFA (XOF), entiers.

TU T'EXPRIMES EN COMPOSANTS
- Catégories → category_grid
- Produits → product_carousel ou product_list
- Options → TOUJOURS option_selector avant tout ajout au panier
- Panier → cart_summary
- Comparaison → price_comparison
- Colis → courier_form
- Après commande → order_tracking, et laisse-le vivre via Realtime

TU NE COMMANDES JAMAIS À LA PLACE DE L'UTILISATEUR
- Tu prépares la commande, tu n'as pas d'outil pour la valider.
- La validation est un tap explicite sur cart_summary ou courier_form.

DÉROULÉ TYPIQUE
accueil (category_grid) → recherche ou catégorie → product_carousel
→ option_selector → cart_summary → [tap utilisateur] → order_tracking
```

Le texte des produits vient des boutiquiers, donc d'un tiers. Il est encadré par
des délimiteurs explicites dans le contexte et n'est jamais traité comme une
instruction. Voir `validate.ts`.

### 5.3 Les outils

Douze outils, tous en lecture ou en préparation. **Aucun outil ne valide une
commande** — c'est délibéré : une action à conséquence financière ne doit pas
dépendre d'un modèle probabiliste.

| # | Outil | Émet |
|---|---|---|
| 1 | `lister_categories()` | `category_grid` |
| 2 | `rechercher_produits(requete, categorie_id?, rayon_m?)` | `product_carousel` |
| 3 | `rechercher_par_image(image_path)` | `product_carousel` ou `price_comparison` |
| 4 | `boutiques_proches(lat, lng, rayon_m?, categorie_id?)` | `merchant_card` |
| 5 | `obtenir_produit(product_id)` | `option_selector` ou `product_card` |
| 6 | `comparer_prix(requete, lat, lng)` | `price_comparison` |
| 7 | `ajouter_au_panier(product_id, quantite, selections)` | `cart_summary` |
| 8 | `voir_panier()` | `cart_summary` |
| 9 | `retirer_du_panier(item_id)` | `cart_summary` |
| 10 | `suivre_commande(order_id?)` | `order_tracking` |
| 11 | `historique_commandes(limite?)` | `product_list` + `quick_replies` |
| 12 | `preparer_course(depart?, arrivee?, colis?, quand?)` | `courier_form` |

Les outils 7 à 9 n'existent que pour le **texte libre** (« ajoute deux coca »).
Un tap sur un bouton du panier ne passe pas par eux : il appelle `POST /cart/*`
directement et le backend renvoie le `cart_summary` recalculé. Économie d'un
aller-retour LLM sur l'action la plus fréquente de l'app.

`rechercher_par_image` reçoit un **chemin Storage**, jamais du base64. L'image
est analysée par Gemini Vision côté backend, la description obtenue est
transformée en embedding texte, et ce vecteur interroge `products.embedding`.
L'octet d'image n'entre jamais dans le contexte du modèle.

`preparer_course` ne fait qu'estimer et pré-remplir. L'envoi part par
`POST /orders` avec `type: 'courier'`.

### 5.4 La boucle

```
1. Flutter POST /chat { conversation_id, client_message_id, text | interaction, context }
2. Backend construit : [prompt système] + [10 derniers messages] + [tour courant]
3. Appel Gemini avec les 12 outils
4. Gemini demande des outils → exécution avec le JWT de l'utilisateur
   → au plus 8 résultats par outil → retour au modèle
   → maximum 3 cycles d'outils, puis on force une réponse
5. Gemini produit { content, components[] }
6. validate.ts : schéma Zod + chaque ID cité doit appartenir au Set des IDs
   renvoyés par les outils de CE tour. Sinon, un rejeu. Deux échecs → texte seul.
7. Persistance dans `messages` (content + components jsonb)
8. Réponse à Flutter → ComponentRegistry.buildAll()
```

**Sécurité.** Chaque requête déclenchée par un outil utilise le JWT de
l'utilisateur, jamais la `service_role`. La RLS reste donc la dernière ligne de
défense même si le modèle est manipulé. La `service_role` est réservée aux jobs
sans utilisateur : dispatch, génération d'embeddings, ETL.

**Cache.** Le prompt système fait ~350 tokens, en dessous du seuil de cache de
Gemini ; ce sont les définitions d'outils qui pèsent. Mesurer avant de budgéter
une économie — ne pas partir du principe que le cache s'applique.

---

## 6. Flux de commande, de bout en bout

```
Client tape « je veux du tuo zaafi »
  → rechercher_produits → product_carousel (3 résultats)
Client tape une carte
  → obtenir_produit → option_selector (Portion, Sauce)
Client choisit et confirme
  → POST /cart/items  [pas de LLM]  → cart_summary
Client tape « Commander — 4 900 F »
  → POST /orders { client_order_id, type: 'delivery', … }  [pas de LLM]
  → insertion orders (status pending) → trigger log_order_status
  → BullMQ : notification FCM au boutiquier
Boutiquier accepte → status confirmed → preparing → ready
  → BullMQ dispatch : livreurs online, disponibles, dans la zone, par distance
  → FCM aux 3 plus proches, premier arrivé premier servi (verrou Redis)
Livreur accepte → status assigned, driver_id posé, is_available = false
  → l'app livreur envoie sa position dans driver_locations toutes les 10 s
  → order_tracking côté client se met à jour seul via Realtime
Livreur récupère → picked_up → delivering → delivered
  → si paiement cash : ligne 'collection' dans driver_cash_ledger
  → is_available = true, la course sort du solde à reverser le soir
```

L'idempotence tient sur `orders(user_id, client_order_id)` : Flutter génère
l'UUID avant l'envoi, un rejeu après coupure réseau retombe sur la même ligne.

---

## 7. App livreur — principes non négociables

**Offline-first.** Le réseau coupe. Accepter une course, confirmer une
récupération, confirmer une livraison doivent fonctionner sans réseau et se
synchroniser au retour du signal. File locale Isar, rejeu ordonné, résolution
de conflit côté serveur (une course déjà prise reste prise — l'app le dit
clairement au retour de connexion plutôt que de faire semblant).

**Un seul écran actif.** Pas de course → liste des courses `ready` de sa zone.
Course acceptée → détail. En livraison → confirmation avec photo optionnelle.

**Position live.** Online et en course → un ping toutes les 10 s dans
`driver_locations`. Online sans course → 60 s. Hors ligne → rien. La batterie et
le forfait data d'un livreur sont des ressources réelles.

**Cash.** Le livreur est auto-entrepreneur, rémunéré à la course. Il encaisse
les espèces et reverse sa collecte. L'écran d'accueil affiche le solde du jour,
calculé par `driver_daily_balance()`.

---

## 8. Migration depuis l'ancienne app

L'ancienne app tourne sur une stack 6ammart (PHP/Laravel + MySQL).

**On récupère** : le Bundle ID iOS et le package name Android ; les comptes
(numéros de téléphone → `profiles.phone`, aucun mot de passe migré, l'utilisateur
re-vérifie par OTP à la première ouverture) ; les boutiques et produits, avec
génération d'embedding à l'import.

**On ne migre pas** l'historique des commandes. L'ancienne base est archivée.

Chaque ligne importée garde son `legacy_id`, ce qui rend l'ETL rejouable et
permet de retrouver la correspondance en cas d'incident.

### Le point le plus risqué : la coexistence

Un déploiement progressif 5 % → 25 % → 100 % avec le même Bundle ID signifie que
**les deux systèmes tournent en parallèle pendant des semaines**. Un boutiquier
ne peut pas surveiller deux tableaux de bord, et un livreur ne peut pas avoir
deux apps ouvertes.

La bascule se fait donc **par boutique, pas par utilisateur** : une boutique est
soit sur l'ancien système, soit sur le nouveau. Le pourcentage de rollout store
ne contrôle que la version d'app cliente ; le catalogue visible dépend de la
boutique. Une boutique migrée disparaît de l'ancien système le jour même. À
trancher définitivement avant la Phase 8.

Il faut aussi un **projet Supabase de staging** distinct de la production : on
remplace le backend d'une app déjà en production sur les stores.

L'auth par OTP suppose un fournisseur SMS couvrant le Niger (Airtel, Zamani,
Moov). Coût par SMS et taux de délivrabilité à valider **avant** la Phase 1 :
c'est une dépendance bloquante du lancement, pas un détail d'intégration.

---

## 9. Roadmap

### Phase 1 — Fondation Supabase
Exécuter `schema.sql`. Vérifier les RLS avec les quatre rôles, par des tests
d'intégration exécutables, pas à la main. Configurer Realtime et Storage
(buckets `search-images`, `products`, `proofs`). Créer le projet staging.

### Phase 2 — Pipeline nu, composants scriptés, sans IA
Prouver que le pipeline tient de bout en bout avant d'ajouter l'IA — mais **en
émettant déjà des `components[]` depuis le backend**, en dur, sans LLM. Flutter
les rend via `ComponentRegistry`. On valide le contrat UI trois semaines plus
tôt et on ne jette rien : la Phase 4 se contente de changer la *source* des
composants.

Livrable : app client (fil + registre), app livreur minimale, routes
`/cart` et `/orders`, dispatch BullMQ, suivi Realtime.
**Jalon validé quand une vraie commande passe de A à Z.**

### Phase 3 — Les douze composants
Un fichier par composant dans `components/widgets/`, enregistrés dans
`register_all.dart`. Golden tests sur données mockées. `order_tracking` branché
sur Realtime.

### Phase 4 — Cerveau IA
`llmClient.ts`, `systemPrompt.ts`, `tools.ts`, `validate.ts`, `orchestrator.ts`,
`embeddings.ts`, `vision.ts`. Le backend bascule de composants scriptés à
composants générés. Le contrat ne bouge pas.

### Phase 5 — App livreur offline-first
File de synchronisation Isar, position adaptative, solde cash du jour.

### Phase 6 — App boutiquier
Catalogue CRUD avec génération d'embedding à chaque écriture, commandes
entrantes en temps réel, disponibilité produit.

### Phase 7 — Admin Refine.js
Commandes en cours, boutiques, livreurs, rapprochement des collectes cash,
analytics.

### Phase 8 — Lancement
Bascule par boutique. Rollout store progressif. Migration des comptes.

**Transverse dès la Phase 1** : logs structurés, Sentry sur les trois apps et le
backend, tests d'intégration RLS en CI. Un flux de paiement et de dispatch sans
observabilité n'est pas exploitable.

---

## 10. Règles de développement

- TypeScript strict côté backend. Pas de `any` sauvage.
- Un fichier, une responsabilité. Pas de fichier de mille lignes.
- Les RLS sont testées avant de passer à la couche suivante.
- Les montants sont des entiers XOF partout, du Postgres au widget.
- L'IA n'invente jamais d'identifiant, et ce n'est pas le prompt qui le
  garantit : c'est `validate.ts`. Du code qui fait confiance au modèle sur ce
  point est un bug.
- Toute action à conséquence financière exige un geste explicite de
  l'utilisateur.
