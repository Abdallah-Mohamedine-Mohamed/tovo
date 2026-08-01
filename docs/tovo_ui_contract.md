# Tovo — Contrat UI

**Version du contrat : `1`**
Protocole entre le backend (IA + routes REST) et le registre de composants Flutter.

---

## 1. Principes

**Le backend décrit, Flutter rend.** Le backend n'envoie jamais de HTML, de style
ni de position. Il envoie une liste de descripteurs typés ; Flutter décide de
l'apparence. Un changement visuel ne demande pas de déploiement backend.

**L'IA n'invente jamais un identifiant.** Elle ne connaît un produit, une
boutique ou une option que parce qu'un outil vient de le lui renvoyer. Cette
règle n'est pas qu'une consigne de prompt : le backend maintient, pour chaque
tour, le `Set` des IDs retournés par les outils et **valide chaque composant
émis contre ce Set** (schéma Zod + vérification référentielle). Un composant
citant un ID inconnu est rejeté, et le tour est rejoué une fois. Deux échecs →
réponse texte sans composant. Voir `backend/src/ai/validate.ts`.

**Dégradation gracieuse.** Une app publiée aujourd'hui doit survivre à un
composant ajouté demain. `ComponentRegistry.build()` retourne `null` pour un
`type` inconnu, et le fil de conversation ignore silencieusement les `null`.
Le backend n'émet un composant introduit après la v1 que si le client annonce
un `contract_version` suffisant (en-tête `X-Tovo-Contract`).

**Tous les montants sont des entiers XOF.** Pas de décimales, jamais. Le
formatage (`1 200 F`, espace insécable comme séparateur de milliers) est fait
côté Flutter par `Money.format()`, jamais côté backend.

---

## 2. Enveloppe

Réponse de `POST /chat` :

```json
{
  "message_id": "uuid",
  "content": "Voici ce que j'ai trouvé chez Chez Mariama.",
  "components": [ { "type": "...", "data": { } } ],
  "contract_version": 1
}
```

`content` est le texte de la bulle assistant. Il peut être vide si les
composants se suffisent. `components` peut être vide.

Requête de `POST /chat` :

```json
{
  "conversation_id": "uuid",
  "client_message_id": "uuid",
  "text": "je veux du tuo zaafi",
  "interaction": null,
  "context": { "lat": 13.5127, "lng": 2.1126 }
}
```

`text` **ou** `interaction`, jamais les deux. `client_message_id` rend l'appel
idempotent : un rejeu après coupure réseau renvoie la réponse déjà calculée.

---

## 3. Interactions — le retour vers le backend

Un tap sur un composant produit une interaction :

```json
{
  "action": "select_product",
  "payload": { "product_id": "uuid" }
}
```

Deux chemins distincts, et c'est important :

| Action | Chemin | Pourquoi |
|---|---|---|
| `select_category`, `select_product`, `select_merchant`, `quick_reply`, `search_by_image`, `compare_price` | `POST /chat` → tour LLM | Le suivant dépend de l'intention, l'IA doit décider. |
| `add_to_cart`, `update_qty`, `remove_from_cart`, `open_cart` | `POST /cart/*` → **pas de tour LLM** | Opérations déterministes. Le backend renvoie directement un `cart_summary`. |
| `place_order` | `POST /orders` → **pas de tour LLM** | Action à conséquence financière. Elle exige un tap explicite de l'utilisateur sur un `cart_summary` ; un modèle ne déclenche jamais un paiement seul. |

Les routes REST renvoient la même enveloppe (`content` + `components`) et
persistent un message dans la conversation, pour que le fil reste cohérent.
Le LLM n'est court-circuité que pour le calcul, pas pour l'historique.

Actions normalisées :

| Action | Payload | Émise par |
|---|---|---|
| `select_category` | `{ category_id }` | `category_grid` |
| `select_product` | `{ product_id }` | `product_carousel`, `product_list`, `product_card` |
| `select_merchant` | `{ merchant_id }` | `merchant_card` |
| `select_options` | `{ product_id, quantity, selections[] }` | `option_selector` |
| `add_to_cart` | `{ product_id, quantity, selections[] }` | `option_selector`, `product_card` |
| `update_qty` | `{ item_id, quantity }` | `cart_summary` |
| `remove_from_cart` | `{ item_id }` | `cart_summary` |
| `place_order` | `{ client_order_id, address_id? , location, payment_method }` | `cart_summary` |
| `quick_reply` | `{ value, label }` | `quick_replies` |
| `search_by_image` | `{ image_path }` | `image_search_prompt` |
| `open_external` | `{ url }` | `price_comparison` |
| `compare_price` | `{ query }` | `price_comparison`, `product_card` |
| `submit_courier` | `{ pickup, dropoff, parcel, scheduled_for }` | `courier_form` |
| `call_driver` | `{ phone }` | `order_tracking` |

**L'image ne transite jamais en base64 dans `/chat`.** Flutter compresse
(max 1024 px, JPEG q75), envoie vers Supabase Storage bucket `search-images`,
et ne transmet que `image_path`. L'octet d'image n'entre donc jamais dans le
contexte ni dans l'historique du modèle.

---

## 4. Les composants

### 4.1 `category_grid` — v1

```json
{
  "type": "category_grid",
  "data": {
    "title": "Que cherchez-vous ?",
    "items": [
      { "id": "uuid", "name": "Repas", "icon": "🍛", "image_url": null }
    ]
  }
}
```
Grille 2 ou 3 colonnes. Tap → `select_category`.

---

### 4.2 `product_carousel` — v1

```json
{
  "type": "product_carousel",
  "data": {
    "title": "Tuo zaafi près de vous",
    "items": [
      {
        "id": "uuid",
        "name": "Tuo zaafi sauce arachide",
        "merchant_id": "uuid",
        "merchant_name": "Chez Mariama",
        "image_url": "https://…",
        "price": 1500,
        "is_available": true,
        "distance_m": 350
      }
    ]
  }
}
```
Liste horizontale scrollable. 8 items maximum. Tap → `select_product`.

---

### 4.3 `product_list` — v1

Même forme d'items que `product_carousel`, rendu en liste verticale avec
vignette à gauche. À utiliser au-delà de 4 résultats ou quand la comparaison
prix compte plus que l'image.

```json
{ "type": "product_list", "data": { "title": "…", "items": [ … ] } }
```

---

### 4.4 `product_card` — v1

```json
{
  "type": "product_card",
  "data": {
    "id": "uuid",
    "name": "Tuo zaafi sauce arachide",
    "description": "Pâte de mil, sauce arachide maison",
    "image_url": "https://…",
    "price": 1500,
    "merchant_id": "uuid",
    "merchant_name": "Chez Mariama",
    "is_available": true,
    "actions": ["add_to_cart", "compare_price"]
  }
}
```
`actions` pilote les boutons affichés. Un produit avec des options requises ne
doit **jamais** exposer `add_to_cart` directement — le backend émet un
`option_selector` à la place.

---

### 4.5 `option_selector` — v1

```json
{
  "type": "option_selector",
  "data": {
    "product_id": "uuid",
    "product_name": "Tuo zaafi",
    "base_price": 1500,
    "quantity": 1,
    "options": [
      {
        "id": "uuid",
        "name": "Portion",
        "required": true,
        "min_select": 1,
        "max_select": 1,
        "values": [
          { "id": "uuid", "name": "Simple", "price_delta": 0, "available": true },
          { "id": "uuid", "name": "Double", "price_delta": 700, "available": true }
        ]
      }
    ],
    "confirm_label": "Ajouter au panier"
  }
}
```

`max_select == 1` → chips radio. `max_select > 1` → chips multi.
Le bouton de confirmation reste désactivé tant qu'une option `required` n'a pas
son `min_select` satisfait. Le total affiché se recalcule **côté Flutter** en
temps réel ; le backend refait le calcul à la réception et fait autorité.
Tap → `add_to_cart`.

---

### 4.6 `quick_replies` — v1

```json
{
  "type": "quick_replies",
  "data": {
    "items": [
      { "label": "Oui, commander", "value": "confirmer" },
      { "label": "Voir autre chose", "value": "autre" }
    ]
  }
}
```
Puces horizontales sous le message. 4 maximum. Tap → `quick_reply`.

---

### 4.7 `cart_summary` — v1

```json
{
  "type": "cart_summary",
  "data": {
    "cart_id": "uuid",
    "merchant_name": "Chez Mariama",
    "items": [
      {
        "item_id": "uuid",
        "product_name": "Tuo zaafi",
        "selections_label": "Portion double · Sauce arachide",
        "unit_price": 2200,
        "quantity": 2,
        "line_total": 4400
      }
    ],
    "items_total": 4400,
    "delivery_fee": 500,
    "discount": 0,
    "total": 4900,
    "currency": "XOF",
    "can_checkout": true,
    "checkout_label": "Commander — 4 900 F"
  }
}
```
`can_checkout: false` (boutique fermée, produit indisponible) grise le bouton et
affiche `blocked_reason` si présent. Tap items → `update_qty` / `remove_from_cart`.
Tap bouton → `place_order`, avec un `client_order_id` généré par Flutter.

---

### 4.8 `merchant_card` — v1

```json
{
  "type": "merchant_card",
  "data": {
    "id": "uuid",
    "name": "Chez Mariama",
    "description": "Cuisine nigérienne",
    "logo_url": "https://…",
    "address_hint": "Yantala, face à la station",
    "is_open": true,
    "rating": 4.6,
    "prep_time_min": 20,
    "distance_m": 350
  }
}
```
Tap → `select_merchant`.

---

### 4.9 `order_tracking` — v1

```json
{
  "type": "order_tracking",
  "data": {
    "order_id": "uuid",
    "type": "delivery",
    "status": "delivering",
    "status_label": "En route vers vous",
    "steps": ["confirmed", "preparing", "ready", "picked_up", "delivering", "delivered"],
    "eta_min": 18,
    "total": 4900,
    "payment_method": "cash",
    "merchant_name": "Chez Mariama",
    "driver": {
      "name": "Ibrahim",
      "phone": "+227…",
      "avatar_url": null,
      "vehicle": "moto",
      "rating": 4.8
    },
    "pickup": { "lat": 13.51, "lng": 2.11, "hint": "Yantala" },
    "dropoff": { "lat": 13.52, "lng": 2.12, "hint": "Plateau, immeuble bleu" },
    "realtime": {
      "orders_channel": "orders:uuid",
      "driver_channel": "driver_locations:uuid"
    }
  }
}
```

**Composant vivant.** À la construction, il s'abonne à Supabase Realtime sur les
canaux indiqués et se met à jour seul : progression des étapes via `orders`, et
position du livreur via `driver_locations`. Le backend ne renvoie pas de nouveau
composant à chaque changement de statut.

Il se désabonne à la destruction, et sur `delivered` / `cancelled`.

---

### 4.10 `price_comparison` — v1

```json
{
  "type": "price_comparison",
  "data": {
    "product_query": "huile de palme 1L",
    "currency": "XOF",
    "results": [
      {
        "source_kind": "partner",
        "ref_id": "uuid",
        "seller_name": "Épicerie Mariama",
        "product_name": "Huile de palme 1L",
        "price": 1200,
        "distance_m": 350,
        "in_stock": true,
        "is_orderable": true,
        "source_url": null
      },
      {
        "source_kind": "external",
        "ref_id": "uuid",
        "seller_name": "Jumia",
        "product_name": "Huile de palme 1L",
        "price": 1100,
        "distance_m": null,
        "in_stock": true,
        "is_orderable": false,
        "source_url": "https://…"
      }
    ]
  }
}
```

Rendu en tableau, partenaires d'abord, meilleur prix partenaire badgé
« Meilleure offre ». La distinction est visuelle et non négociable :
`is_orderable: true` → bouton plein **Commander** (`select_product`) ;
`is_orderable: false` → bouton discret **Voir** (`open_external`), avec la
source nommée. On ne fait jamais croire à l'utilisateur qu'il peut commander
chez un marchand hors plateforme.

---

### 4.11 `image_search_prompt` — v1

```json
{
  "type": "image_search_prompt",
  "data": {
    "message": "Montrez-moi une photo, je trouve où l'acheter",
    "allow_camera": true,
    "allow_gallery": true
  }
}
```
Affiche une zone camera/galerie. Flutter compresse, envoie vers Storage, puis
émet `search_by_image` avec le `image_path`.

---

### 4.12 `courier_form` — v1

Le service Coursier : un colis d'un point A à un point B, sans catalogue.

```json
{
  "type": "courier_form",
  "data": {
    "pickup": { "lat": 13.51, "lng": 2.11, "hint": "Plateau, boutique Issa" },
    "dropoff": null,
    "parcel": "small",
    "parcel_options": [
      { "value": "small",  "label": "Petit",  "icon": "📍", "hint": "documents, clés" },
      { "value": "medium", "label": "Moyen",  "icon": "📦", "hint": "sac, carton" },
      { "value": "large",  "label": "Grand",  "icon": "🗃", "hint": "encombrant" }
    ],
    "scheduling": ["now", "later"],
    "estimate": { "price": 1500, "eta_min": 45, "distance_m": 4200 },
    "confirm_label": "Confirmer l'envoi — 1 500 F"
  }
}
```

Les champs se remplissent progressivement au fil de la conversation : le backend
réémet le composant complété à chaque tour plutôt que d'ouvrir un formulaire
modal. `estimate` reste `null` tant que les deux points ne sont pas connus, et
le bouton de confirmation est masqué. Tap → `submit_courier`.

---

## 5. Récapitulatif des versions

| Composant | Introduit en | Client minimum |
|---|---|---|
| `category_grid`, `product_carousel`, `product_list`, `product_card`, `option_selector`, `quick_replies`, `cart_summary`, `merchant_card`, `order_tracking` | contrat v1 | 1 |
| `price_comparison`, `image_search_prompt`, `courier_form` | contrat v1 | 1 |

Tout composant ajouté après le lancement incrémente le contrat et n'est émis
qu'aux clients annonçant la version correspondante.

---

## 6. Ce que le contrat interdit

- Émettre un ID qui ne vient pas d'un outil du tour courant.
- Passer un prix en décimal, en chaîne, ou dans une autre devise que XOF.
- Émettre `cart_summary` avec des totaux calculés par le LLM : le total vient
  toujours de la base.
- Émettre plus de 8 items dans un carousel ou une liste.
- Faire dépendre le rendu d'un champ absent du contrat : Flutter ignore les
  champs qu'il ne connaît pas, il ne devine pas.
