# Rapport : l'IA conversationnelle de Tovo — ce qui a été fait, comment, avec quels résultats

**Auteur** : Claude (Opus), assistant de développement, à la demande du fondateur de Tovo.
**Date** : 2 octobre 2026.
**Dépôt** : `backend/` (Node/TypeScript, Fastify, Supabase), application `mobile/` (Flutter), `admin/` (React).

---

## 0. Ce qui est demandé à l'évaluateur

Le fondateur va faire relire ce travail par une autre IA. Je demande explicitement :

1. **Analyser** l'architecture décrite ici en lisant le code (les chemins de fichiers et les noms de fonctions sont exacts au 02/10).
2. **Corriger** ce qui est faux : bugs, mauvaises décisions, mesures trompeuses.
3. **Dire si je dévie de l'objectif** (section 1). Le fondateur m'a reproché de « tourner en rond » et de « corriger cas par cas ». Je pense que c'est en partie vrai : la section 6 dit où.
4. **Juger la méthode de mesure** (section 4). Je pense qu'elle a des angles morts sérieux, décrits en 6.1.

Les questions précises sont listées en section 9.

---

## 1. L'objectif du fondateur (ses mots)

Tovo est une application de livraison à Niamey (Niger) : repas, courses, colis, livreurs. Le client parle à un assistant, par écrit ou à la voix, en français parlé, avec des fautes, parfois en haoussa ou en zarma.

Ce que le fondateur attend :

- « C'est au cerveau de construire les phrases. » Aucune phrase adressée au client ne doit être un texte à trous écrit par du code.
- « Tu ne peux pas prendre cas par cas, il y a des milliers de phrases. » Des corrections générales, pas une règle par phrase signalée.
- « Tovo doit faciliter la vie aux gens. » Même quand Tovo n'a pas le produit ou la boutique : dire où le trouver, proposer qu'un livreur aille l'acheter.
- Ne rien inventer : ni prix, ni délai, ni horaire, ni démarche.
- Des preuves chiffrées avant de dire « c'est fait », et des tests bon marché (il a refusé 3 à 4 $ pour un test).

**Méthode acceptée le 02/10** (après « franchement c'est quoi tous ces problèmes ? On tourne en rond… tu me déçois ») :

- plus aucune nouvelle fonction ;
- un examen fixe passé avant chaque livraison ;
- un chantier à la fois : (1) la pertinence de la recherche, (2) le choix d'agence (« Otakoss centre aéré »), (3) une fiche officielle de Tovo (contenu à fournir par le fondateur) ;
- ne dire « c'est fait » qu'avec un score avant/après, et annuler si ce n'est pas mieux.

Le produit n'est **pas en production** : les « clients » en base sont les tests du fondateur.

---

## 2. Architecture actuelle, de bout en bout

### 2.1 Le chemin d'un message texte : `src/routes/chat.ts` (POST /chat)

Dans l'ordre réel du code :

1. **En parallèle, dès l'arrivée du message** (l. 363-392) :
   - le **cerveau** `comprendre()` (decideur.ts) reçoit le message et le dernier message de Tovo ;
   - une **recherche préalable** à mots dans le catalogue, `cataloguePage(q = requeteProduitUtilisateur(texte))`, sans IA.
2. **Interactions directes** (boutons) : recherche par image, comparer les prix, tuiles « Oui, envoyez un livreur » / « Non », confirmation d'annulation. Ces réponses ne passent pas par l'IA.
3. **Pharmacies de garde** (`demandeDeGarde`, un détecteur à mots) : réponse directe avec les 5 plus proches, phrase mise en mots par le rédacteur.
4. **Court-circuit « recherche exacte »** (l. 571-577) : si la recherche préalable trouve une correspondance **exacte**, l'intention devient `recherche` **sans attendre le cerveau**. ⚠️ Dans ce cas, ni le produit ni le rayon compris par le cerveau ne sont utilisés (voir 6.1).
5. Sinon, **décision du cerveau** → `routeDuCerveau` : une intention, ou des tuiles « clarifier » quand il n'est pas sûr d'une action coûteuse.
6. **Routes directes sans assistant**, chacune avec sa phrase mise en mots par le rédacteur (`enMots`) :
   - `livreur` avec position : un livreur est commandé directement ;
   - `colis` / `livreur` sans détails : la carte `courier_form` ;
   - `annuler` : la carte de la commande et une confirmation ;
   - `aide` : excuses et signalement dans la table `signalements` ;
   - `panier` ;
   - « Je veux manger » (`demandeGeneraleDeRepas`, détecteur à mots) : la liste des restaurants.
7. Tout le reste → **`orchestrate()`** (orchestrator.ts), avec `intention`, `requete` (le produit compris par le cerveau), `rayon` et `pageInitiale`.

Si le cerveau est en panne, les détecteurs à mots (`intents.ts`) ne déclenchent **jamais** une action coûteuse : `motsPermis = !cerveau`.

### 2.2 Le cerveau : `src/ai/decideur.ts`

- **Modèle** : `gemini-3.1-flash-lite` sans réflexion (`thinkingBudget: 0`).
  - Relance en parallèle vers `gemini-3.5-flash-lite` (réflexion courte) si aucune réponse après 1 300 ms.
  - Secours `gpt-5.5` (OpenAI).
  - Plafond de 4 s, puis `intention: null`.
- **Sortie JSON contrainte par schéma** : `{intention, sur, produit, rayon}`.
  - `intention` : une des 13 intentions de `jev.ts`, `INTENTIONS` : recherche, envie, boutique, livreur, colis, designe, panier, habitude, suivi, annuler, aide, question, social.
  - `sur` : false si une autre lecture raisonnable existe, surtout vers une action coûteuse. Les **actions coûteuses** (`COUTEUSES`) sont livreur, colis, annuler, habitude.
  - `produit` (ajouté le 02/10) : ce que le client cherche, en 1 à 5 mots, complété par le dernier message de Tovo (« Bobiel » après « Dans quel quartier cherchez-vous du poulet ? » → « poulet »).
  - `rayon` (ajouté le 02/10) : un des 8 rayons racines du catalogue, ou « aucun ». La correspondance rayon → catégorie est dans `SLUG_DU_RAYON`.
- La consigne `CONSIGNE_CERVEAU` est exportée : le banc mesure exactement celle-ci.
- `lireDecision` valide le JSON ; `comprendre` orchestre la relance et les pannes, et ne lève jamais.

### 2.3 L'orchestrateur : `src/ai/orchestrator.ts`, `orchestrate()`

1. Il charge l'historique : 10 messages, et le choix d'agence en attente (`pending`).
2. **Requête initiale** : le `produit` du cerveau, nettoyé par `requeteProduitUtilisateur`, sauf si une boutique est nommée (`nomBoutiqueApresMarqueur`, ajouté aujourd'hui) ; à défaut, le message lui-même.
3. **Rayon** : `idDuRayon()` donne l'identifiant de la catégorie racine (gardé en mémoire), sauf boutique nommée.
4. **Recherche initiale lexicale** (sans vecteurs) dans ce rayon. Si elle trouve un résultat **exact**, `produitsOuAilleurs()` est appelé :
   - le rédacteur écrit la phrase **et juge si les produits sont pertinents** (`redigerEtJuger`) ;
   - si ce n'est pas pertinent, `horsTovo()` prend le relais : les commerces hors Tovo.
5. Sinon, **`resolveCatalogueIntent`** (catalogue.ts) reconnaît une boutique nommée parmi les enseignes approuvées, avec tolérance aux fautes et alias.
   - `merchantIntentAnswer` répond directement : boutique hors Tovo → `enseigneHorsTovo`, plusieurs agences → choix, menu.
6. Sinon, une recherche filtrée par boutique ou par rayon. Si elle est vide ou seulement approximative (`match_type: 'similar'`), `horsTovo()` est appelé.
7. « Quelles boutiques sont ouvertes ? » (`demandeBoutiqueOuverte`, détecteur à mots) → `boutiques_proches`.
8. Sinon, **l'assistant** (`GEMINI_MODEL = gemini-3.8-flash`, `llmClient.ts`) prend la main :
   - 18 outils (`tools.ts`), au plus 3 cycles (`MAX_CYCLES`) ;
   - les outils : rechercher_produits, produits_de_boutique, obtenir_produit, lister_categories, lister_restaurants, boutiques_proches, comparer_prix, rechercher_par_image, ajouter_au_panier, retirer_du_panier, voir_panier, preparer_course, appeler_livreur, suivre_commande, annuler_commande, historique_commandes, recommander_commande, mes_adresses ;
   - si un seul outil a répondu avec une phrase de base, le **rédacteur** la réécrit au lieu d'un deuxième appel à l'assistant (gain de temps).
9. **Garde-fous de sortie** :
   - `validateComponents` (validate.ts) rejette toute carte dont l'identifiant n'a pas été renvoyé par un outil ;
   - `sansPromesseVide` retire « voici » quand aucune carte ne s'affiche ;
   - `verifierTexte` (verificateur.ts) retire toute phrase qui contient un montant, une durée ou un nom en gras absent des faits.

### 2.4 Le rédacteur : `src/ai/redacteur.ts` (ajouté le 02/10)

- **Rôle** : écrire **toute** phrase des chemins rapides (orchestrateur et routes directes) à partir du message exact du client, de ce qui a été trouvé (les faits) et du *sens* de la phrase prévue par le code. La phrase prévue sert aussi de secours.
- **Modèle** : `gemini-3.1-flash-lite`, température 0,4, sans réflexion, délai de 2,5 s.
- **`redigerEtJuger`** : dans le même appel, un JSON `{pertinent, texte}`. `pertinent: false` déclenche le repli hors Tovo (« deux litres de lait » ramenait des savons au lait).
- Sa sortie passe par le vérificateur anti-invention, puis par `sansPromesseVide`.
- `REDACTEUR=0` le coupe dans les tests (`vitest.config.ts`).

### 2.5 Hors Tovo : `src/services/catalogue.ts`, `commerces.ts`, `googlePlaces.ts`, `pharmaciesGarde.ts`

- **Annuaire public** `data/commerces-niamey.json` : 466 commerces, dont 118 pharmacies, construits depuis Overture Maps et OpenStreetMap par `scripts/commerces/construire.ts`. Les ajouts manuels sont dans `data/commerces-ajouts.json` (par exemple Nouhou Merguez, avec alias).
- **`horsTovo(db, message, requete, position, {boutique})`**, une seule règle :
  1. un nom connu de l'annuaire → `commerceConnu` (où il est, son numéro, un livreur) ;
  2. sinon, si le cerveau a compris « boutique » → Google Places (`trouverSurGoogle` : seul le place_id est gardé, pas de nouvelle demande pendant 7 jours si Google ne connaît pas le nom) ;
  3. sinon → `alternativesHorsTovo` : les commerces du bon type les plus proches (`commercesPourProduit`, `typesPourProduit`). La nuit et le dimanche, un médicament mène aux pharmacies de garde.
- **`enseigneHorsTovo`** : boutique nommée inconnue (« viande chez Tchos ») → tuiles « Oui, envoyez un livreur » / « Non, voir ce que Tovo propose ». Le livreur avance l'achat, le client rembourse à la livraison.
- **`estSurTovo`** : un commerce qui est en réalité sur Tovo n'est jamais présenté « hors Tovo ». Le résultat est mémorisé, car le calcul prenait 10 s.
- **Boutiques demandées** (table `boutiques_demandees`, migrations 0072-0073) : une liste de prospection pour l'admin.
- **Pharmacies de garde** (table `pharmacies_garde`, migration 0074) : chaque semaine, l'admin dépose l'image Lahiyata, Gemini la lit, les positions viennent de Google, puis l'admin publie. Une carte d'accueil côté mobile permet d'y accéder.
- **Mobile** : le widget `commerces_hors_tovo.dart` et l'action locale `call_phone`.

### 2.6 La recherche catalogue : `cataloguePageBrute`

- **RPC `catalog_products_page`** : correspondance lexicale, puis vectorielle si `semantic`. Elle renvoie `match_type` (`exact` ou `similar`) et filtre par catégorie, sous-rayons compris.
- `filtrerSuggestionsProches` / `filtrerSuggestionsTextuelles` écartent les ressemblances absurdes.
- **Si rien n'est trouvé et que la requête est un seul mot égal au nom d'une catégorie** (« boissons »), toute la catégorie est affichée.
  - **Corrigé aujourd'hui** : ce repli s'appliquait aussi au rayon imposé par le cerveau. « Montre » affichait alors les 59 vêtements, et « paracétamol » les 17 produits de parapharmacie.

---

## 3. Les bancs d'essai et examens

### 3.1 Banc du cerveau (le tri des intentions)

- **Jeu de référence** `src/ai/banc/jeu.ts` : 202-203 phrases, des vraies et des pièges, avec un champ `aussi` pour les réponses acceptables.
- La table `banc_cas` contient environ 2 400 phrases validées, dont MASSIVE d'Amazon.
- **Passage** `src/ai/banc/passage.ts`, lancé par `npm run banc:ia -- cerveau`. Deux métriques :
  - la **justesse** : `memeSens` accepte des intentions équivalentes ;
  - les **actions coûteuses à tort** : la métrique de sécurité.
- **Boucle continue** (`services/bancIa.ts`, `banc/boucle.ts`) : Gemini Pro écrit de nouvelles phrases, GPT-5.5 juge. **En pause depuis le 30/09** : elle a épuisé les crédits Gemini.
- **Comparateur de modèles** : `scripts/banc-ia/banc.ts`, avec les candidats openrouter, vertex et claude.

### 3.2 Comparaison d'architectures : `scripts/banc-ia/comparer-architectures.ts`

- **Question posée** : l'assistant seul (Gemini 3.8 Flash avec outils) contre « cerveau + chemins rapides + rédacteur ».
- **Méthode** : environ 30 phrases (captures du fondateur, pièges, contexte, vraies phrases). Un juge, Gemini 3.1 Pro, compare **à l'aveugle** (ordre tiré au hasard), note sur 5 et signale les inventions. Coût : environ 0,30 $.
- L'option `--contre <fichier>` compare la version actuelle à des réponses enregistrées.

### 3.3 Examen des réponses : `scripts/banc-ia/examen-reponses.ts` (la règle de livraison)

- **30 phrases**, chacune avec un **comportement attendu écrit à l'avance**.
- Chaque phrase passe par `comprendre()`, puis `orchestrate()`. Un juge (Gemini 3.1 Pro, température 0) dit si la réponse est conforme, la note sur 5 et signale les inventions.
- Les scores sont comparés automatiquement au passage précédent ; le détail est dans `scripts/banc-ia/resultats/examen-*.json`.
- Coût : environ 0,20 $.
- ⚠️ **Il n'appelle pas la route `chat.ts`** : voir 6.1.

### 3.4 Tests unitaires

- `npx vitest run` : 432 tests, 431 passent.
- L'échec, `fulfillment.test.ts` « un livreur hors ligne n'est pas candidat », dépend des livreurs en ligne dans la base de test partagée. Il ne touche ni la recherche ni l'IA. Ce n'est pas prouvé : je n'ai pas remis le code d'avant pour comparer.

---

## 4. Chronologie : ce qui a été essayé, et les résultats

### 4.1 Le choix du modèle de tri (26-30/09) : on garde Gemini 3.1 Flash-Lite

Mesures sur les ~203 phrases de référence :

| Candidat | Justesse | Coûteuses à tort | Médiane | Verdict |
|---|---|---|---|---|
| Gemini 3.1 Flash-Lite (consigne actuelle) | 94-96 % | 0-1 | 0,7-1,6 s | **retenu** |
| Ancienne cascade (classifieur local + Jev) | 85 % | 6 | — | remplacée |
| CLM-8B à nu (RunPod A40, vLLM) | 8 % | 61 | 57 ms | rejeté |
| CLM-8B avec têtes entraînées (2 407 phrases) | 60 % | 14 | 57 ms | rejeté |
| Claude Sonnet 5.5 (OpenRouter) | 93 % | 1 | 2,0 s | rejeté, environ 10× le coût |
| Gemini Flash-Lite entraîné sur Vertex (1 799 phrases, ~2 $) | 93 % | 2 | 1,25 s | rejeté |
| Exemples proches injectés (e5-small) | 95,3 % contre 95,8 % | — | — | sans gain, désactivé |

### 4.2 Le rédacteur et le produit compris par le cerveau (02/10)

- **Déclencheur** : des captures du fondateur.
  - « Tovo ne propose pas encore de bien manger des merguez » : une phrase à trous qui recopiait les mots du client.
  - « 1278 produits correspondent » en réponse à « Tu es sourd ? ».
- **Décision** : le cerveau extrait le `produit`, et le rédacteur IA écrit les phrases.
- **Comparaison d'architectures** (juge à l'aveugle) : l'assistant seul fait à peu près la même qualité, mais il est plus lent et coûte environ 2× plus. On garde donc cerveau + chemins rapides + rédacteur. Après corrections : **4,13/5 contre 3,77**.

### 4.3 Chantier 1 : la pertinence de la recherche (02/10), suivi par l'examen fixe

| Passage | Conformes | Note /5 | Inventions | Médiane | 95 % |
|---|---|---|---|---|---|
| Référence (avant rayon) `examen-…-03-39` | 22/30 | 3,73 | 6 | 3,8 s | 8,5 s |
| + rayon, 1er essai `examen-…-03-50` | **19/30** (régression) | 3,71 | 8 | 3,2 s | 4,5 s |
| + 2 corrections `examen-…-04-03` | **24/30** | **4,23** | **3** | 3,3 s | 4,7 s |

**Le 1er essai a régressé, pour deux causes** :

- Rayon imposé sans correspondance : tout le rayon s'affichait, et le repli hors Tovo était bloqué. Exemples : « montre » → 59 vêtements ; « paracétamol » → 17 produits de parapharmacie ; « va plus loin » (pommade) → des cosmétiques.
- Le cerveau mettait le nom de la boutique dans le produit (« viande Tchos »), et Tovo affichait Maison Grill au lieu des tuiles Tchos.

**Les corrections** :

- `cataloguePageBrute` : le rayon entier ne s'affiche plus que pour une catégorie **nommée** par le client.
- `orchestrate` : une boutique nommée l'emporte sur le produit et le rayon du cerveau.

**Gagnés** : « viande chez Tchos », « une autre montre », « Je veux manger », « paracétamol ».

**« Régression » signalée** : « Quelles boutiques sont ouvertes ? ». La réponse est **identique mot pour mot** entre la référence (jugée conforme, 4/5) et ce passage (jugée non conforme, 1/5). C'est le juge qui varie, pas Tovo.

**Banc du cerveau avec le rayon** :

- Le script a affiché environ 96 %, avec `memeSens`.
- Mon recompte strict donne **189/202 avec le rayon, contre 195/202 avant**. Six phrases sont perdues :
  - « annule » → tuiles ;
  - « je cherche un tacos poulet chez otakoss » → boutique au lieu de recherche ;
  - « otakoss j'ai dit… takos bien spécifique » → boutique ;
  - « montre moi le début de toutes les catégories » → question ;
  - « Sur ? Et avez-vous d'autres choses ? » → social ;
  - « Je veux commander de la viande, de la bouffe de street » → recherche.
- **Je ne l'avais pas signalé clairement au fondateur.** Ajouter le champ `rayon` au schéma a probablement un peu dégradé le tri. Ce n'est pas tranché : je n'ai fait qu'un passage, et il faudrait le refaire plusieurs fois pour séparer l'effet du bruit.

### 4.4 Chantier 2 : le choix d'agence (02/10, après le premier envoi de ce rapport)

**Cause.** « otakoss » correspond à la variante « O TAKOSS », que les **deux** agences (« O'TAKOSS ( Centre Aéré ) » et « O'TAKOSS ( Nouveau Marché ) ») partagent. `boutiquesMentionnees` les retenait donc toutes les deux, et les mots qui les distinguent n'étaient jamais regardés. Même « otakoss nouveau marché » redemandait l'agence.

**Correction générale** : `agenceNommee(message, candidates)`, dans catalogue.ts, appelée dans `resolveCatalogueIntent`.

- Quand plusieurs enseignes restent, on garde celles dont les mots **propres à leur nom** (absents du nom de toutes les autres, 3 lettres ou plus) figurent dans le message.
- Les variantes (alias) sont volontairement ignorées : elles ne distinguent rien.
- Sans mot distinctif, toutes restent, et le client choisit comme avant.
- Le test unitaire est dans `tests/unit/catalogue.test.ts`.

**L'instrument de mesure corrigé en même temps** (`examen-reponses.ts`) :

- **Le total réel trouvé est transmis au juge.** Avant, il ne voyait que les 6 premières cartes et prenait « 21 options » pour une invention : les inventions passaient de 3 à 8 sans qu'aucune réponse n'ait changé.
- **Le juge est relancé 3 fois** s'il ne répond pas. Les phrases toujours non jugées sont **exclues** du score au lieu d'être comptées comme échecs.
- **Le quota journalier de Gemini 3.1 Pro (250 requêtes par jour) a été atteint** pendant les essais : deux passages se sont retrouvés presque sans notes. Leur fichier a été renommé `invalide-…` pour ne pas servir de référence. Le juge passe désormais par OpenRouter quand Google répond 429, avec le **même modèle** (`google/gemini-3.1-pro-preview`).

**Résultats** (deux passages consécutifs, pour mesurer le bruit) :

| Passage | Conformes | Note | Inventions | Médiane |
|---|---|---|---|---|
| Référence chantier 1 (`…-04-03`, Otakoss en échec) | 24/30 | 4,23 | 3 | 3,3 s |
| Chantier 2, passage A (`…-04-28`) | 23/30 | 4,20 | 2 | 3,0 s |
| Chantier 2, passage B (`…-04-31`) | 25/30 | 4,33 | 3 | 3,3 s |

- « Otakoss centre aéré » est conforme dans les deux passages. Le juge l'a noté 5/5 : la carte de la bonne agence et sa grille de catégories.
- Entre les passages A et B, sans aucun changement de code, trois phrases ont changé de verdict : « Tu peux tout me trouver », « deux litres de lait » et « Quels sont tous les commerces hors de Tovo ». **Le bruit de l'ensemble (assistant + juge) est donc d'au moins ±1 à 2 phrases sur 30.** Un écart de cet ordre ne prouve rien.

### 4.5 Les échecs restants (stables sur les deux passages)

1. « Quels sont tous les commerces hors de Tovo ? » : la réponse ne dit pas qu'un livreur peut aller dans une boutique précise.
2. « un colis de riz de 25 kg » : le formulaire de colis au lieu du riz. Le cerveau ou l'assistant lit « colis ».
3. « Je veux un gâteau d'anniversaire » : des supermarchés au lieu de pâtisseries ou boulangeries (`typesPourProduit`).
4. « va plus loin que la distance annoncée » : Tovo propose des commerces plus proches au lieu d'élargir.
5. « Quelles boutiques sont ouvertes ? » : le juge y voit une invention. WORLD JUS vient pourtant de `boutiques_proches` (des données réelles) ; il faut vérifier son horaire réel à 4-5 h du matin.

---

## 5. Les erreurs que j'ai commises (liste honnête)

### 5.1 Erreurs techniques

- **Schéma JSON avec une valeur vide** (`enum: ['', ...]`) : Gemini renvoyait 400, et **le cerveau était à 0 %** (`2026-10-02-03-46.json`). Le banc l'a détecté avant toute livraison ; j'ai remplacé la valeur vide par « aucun ».
- **Le rayon, 1er essai** : régression de 22 à 19/30 (voir 4.3). Le repli « afficher la catégorie entière » n'avait pas été prévu pour un filtre imposé.
- **Le produit du cerveau, v1** : plusieurs régressions, corrigées avant la livraison.
  - « viande chez Tchos » perdu ;
  - l'assistant muet sur « devenir livreur » ;
  - « va plus loin » mal compris.
- **Le rédacteur appelait le réseau pendant les tests unitaires** : corrigé avec `REDACTEUR=0`.
- **« pommade » donnait « pomme »** : des suggestions approximatives passaient avant les commerces qui ont vraiment le produit.
- **`estSurTovo` prenait 10 s** : la comparaison tolérante était faite sur 466 × toutes les enseignes. Corrigé par la mémorisation et une exclusion paresseuse.

### 5.2 Erreurs de méthode

- **Du 30/09 au 02/10, j'ai enchaîné des corrections au fil des captures** (phrases à trous, détecteurs à mots) au lieu d'une approche d'ensemble mesurée. C'est le « cas par cas » reproché, à raison.
- **Banc continu laissé tourner** (27-30/09) : il a épuisé les crédits Gemini sans gain proportionné.
- **J'ai d'abord affirmé que Claude n'était pas utilisable** (problème de compte), alors qu'OpenRouter était déjà configuré et que je l'avais moi-même utilisé.
- **Affirmation « le banc est revenu à 96 % »** sans signaler la baisse stricte de 195 à 189/202 (voir 4.3).
- **Annonces de résultats avant la mesure** à plusieurs reprises, avant que la règle « score avant/après » soit adoptée.

### 5.3 Erreurs d'environnement (non liées au code de Tovo)

- **vLLM sur RunPod** : un pilote CUDA 12.8 trop ancien ; il a fallu un nouveau pod CUDA 13.
- **Collage dans le terminal Jupyter** : il insérait des caractères parasites (`^[[200~`).
- **Claude 5.x tronqué à 60 jetons** : il raisonne avant son JSON ; il a fallu 400 jetons et l'effort « low ».
- **Vertex** : erreurs 429 en parallèle, et un hôte régional à utiliser.

### 5.4 Incidents de production observés le 02/10 (à vérifier par le fondateur)

- Gemini a répondu 403 « project denied access » entre 00:52 et 00:53 UTC.
- OpenAI n'a plus de crédit : le secours du cerveau est inopérant.
- Erreurs Redis (bullmq) sur Railway.

---

## 6. Autocritique : angles morts et déviations possibles

### 6.1 Ce que l'examen ne voit pas (le plus grave)

1. **L'examen appelle `orchestrate()` directement, pas la route `chat.ts`.** Les chemins suivants **ne sont pas testés** par l'examen :
   - le court-circuit « recherche exacte » ;
   - les routes directes livreur, colis, annuler, aide et panier ;
   - « Je veux manger » via `demandeGeneraleDeRepas` ;
   - les pharmacies de garde ;
   - les tuiles hors Tovo.
   Le score de 24/30 mesure donc l'orchestrateur, **pas exactement ce que vit le client**.
2. **En production, le court-circuit « recherche exacte » (`chat.ts` l. 571-577) ignore le cerveau.** Si « Il me faut un litre d'huile » trouve un résultat exact par les mots, `pageInitiale` est utilisée **sans rayon**. Les huiles pour le corps peuvent alors revenir. Seul le jugement de pertinence du rédacteur sert encore de filet. L'amélioration mesurée par l'examen n'est donc peut-être pas entièrement vraie en production.
3. **Les 30 phrases et leurs « attendus » ont été écrits par moi**, puis tranchés par le fondateur sur les cas contestés. Il y a un risque d'optimiser pour cet examen : 3 des 4 gains d'aujourd'hui sont des phrases que j'avais analysées une par une.
4. **Le juge est Gemini 3.1 Pro**, de la même famille que les modèles jugés. Il est **non déterministe** malgré la température 0 : la même réponse a reçu 4/5 puis 1/5. Avec un seul passage par phrase, un écart de ±2 sur 30 n'est **pas significatif**. Deux passages identiques en code ont donné 23 puis 25/30 (section 4.4).
5. **L'heure du passage change les réponses** : la nuit et le dimanche, les pharmacies de garde et les restaurants fermés entrent en jeu. Les passages comparés étaient tous entre 4 h et 5 h du matin à Niamey.
6. **La position est fixe** (13,52 ; 2,11) et il n'y a pas d'historique réel, sauf la variable `avant`.

### 6.2 Contradictions avec l'objectif du fondateur

- **« Le cerveau décide, pas les mots »**, mais `intents.ts` (448 lignes) contient encore beaucoup de détecteurs à mots qui décident de routes : `demandeDeGarde`, `demandeGeneraleDeRepas`, `demandeBoutiqueOuverte`, `nomBoutiqueApresMarqueur`, `referenceAuxResultats`, `demandeDeCommandePassee`, `rechercheProduitRapide`, `requeteProduitUtilisateur`…
  - **La correction de Tchos d'aujourd'hui en est un nouveau** : elle repose sur le mot « chez ». C'est une règle à mots, même si elle est générale (toute boutique introduite par chez, boutique ou restaurant).
- **« Aucune phrase écrite par du code »** : c'est vrai pour ce que voit le client quand le rédacteur répond. Mais la phrase prévue par le code reste **le secours** (panne, délai de 2,5 s, invention détectée) et **le sens imposé** au rédacteur.
  - Certaines réponses ne passent pas du tout par le rédacteur : `reponseHorsTovo` (tuiles Oui/Non), la confirmation d'annulation, les interactions directes.
- **Complexité** : `chat.ts` (1 026 lignes) et `orchestrator.ts` (624 lignes) empilent de nombreux chemins rapides, chacun ajouté pour un cas observé.
  - Il y a trois endroits où l'on cherche : la recherche préalable de la route, la recherche initiale de l'orchestrateur, et l'outil `rechercher_produits`. Chacun a ses propres règles (rayon ou non, sémantique ou non).
  - Cette dispersion explique sans doute une bonne part du « on tourne en rond » : corriger un chemin ne corrige pas les autres.

### 6.3 Coût et latence

- Un message de recherche fait 2 appels d'IA en série (cerveau, puis rédacteur), ou 3 s'il passe par l'assistant. La médiane mesurée est de 3,3 s, et 4,7 s au 95e percentile.
- La recherche lexicale et le rédacteur pourraient partir plus tôt, mais ce n'est pas fait.

### 6.4 Ce que je pense être la vraie direction (à valider ou contredire)

1. **Un seul chemin de recherche** : la recherche préalable, la recherche initiale et l'outil devraient partager une même fonction qui prend `{produit, rayon, boutique}` du cerveau. Supprimer le court-circuit qui ignore le cerveau, ou y appliquer le rayon.
2. **Faire passer l'examen par la vraie route HTTP** (`app.inject` sur POST /chat), pas par `orchestrate()`, et répéter chaque phrase 2 à 3 fois pour mesurer le bruit du juge.
3. **Que le cerveau dise aussi `boutique` (le nom)** au lieu de compter sur le mot « chez ». Le schéma porterait alors `{intention, sur, produit, rayon, boutique}`, et les détecteurs à mots deviendraient de simples filets.
4. **Agrandir l'examen** avec des phrases que je n'ai pas vues, par exemple tirées de `banc_cas`, en gardant les 30 actuelles comme socle.

---

## 7. État des fichiers modifiés aujourd'hui (non commités)

`git status` dans `backend/` :

- **src/ai/decideur.ts** : champs `produit` et `rayon`, `RAYONS`, `SLUG_DU_RAYON`, consignes ajoutées.
- **src/ai/orchestrator.ts** : `boutiqueNommee`, `rayonId`, `produitsOuAilleurs`, `enMots`, `horsTovo` sur un résultat vide ou approximatif.
- **src/ai/redacteur.ts** : `redigerEtJuger`, `sansPromesseVide`.
- **src/ai/tools.ts** : `ctx.requete`, `ctx.rayonId`, recherche limitée au rayon.
- **src/ai/systemPrompt.ts** : « rien d'inventé sur Tovo », « jamais "voici" sans carte ».
- **src/routes/chat.ts** : transmission de `requeteCerveau` et `rayonCerveau`.
- **src/services/catalogue.ts** : `idDuRayon`, le correctif du repli « catégorie entière », et `agenceNommee` (chantier 2).
- **tests/unit/catalogue.test.ts** : un test pour `agenceNommee`.
- **scripts/banc-ia/comparer-architectures.ts**, **scripts/banc-ia/examen-reponses.ts** : nouveaux. Le second transmet désormais le total réel au juge, relance le juge, exclut les phrases non jugées et passe par OpenRouter quand Google répond 429.
- **docs/RAPPORT-IA-2026-10-02.md** : ce rapport.

---

## 8. Comment reproduire

```bash
cd backend
npx tsc --noEmit -p .                                        # types
npx vitest run                                                # 432 tests (~6 min)
npm run banc:ia -- cerveau                                    # tri des intentions, 202 phrases
npx tsx --env-file=.env scripts/banc-ia/examen-reponses.ts    # examen fixe, ~0,20 $
npx tsx --env-file=.env scripts/banc-ia/comparer-architectures.ts -- --contre <fichier>
```

Les résultats sont dans `scripts/banc-ia/resultats/` : `examen-*.json`, `architectures-*.json`, et `AAAA-MM-JJ-HH-MM.json` pour le banc du cerveau.

---

## 9. Questions précises pour l'évaluateur

1. L'architecture **cerveau (tri) → chemins rapides → rédacteur**, avec l'assistant à outils en dernier recours, est-elle la bonne pour cet objectif ? Ou un seul assistant bien outillé serait-il plus simple et plus juste, malgré la mesure de 4.2 ?
2. La multiplication des chemins (section 6.2) est-elle la cause principale des régressions en série ? Que faut-il supprimer en priorité ?
3. L'examen de 30 phrases jugé par Gemini Pro est-il une mesure fiable pour décider de livrer ? Quelle méthode, peu coûteuse (moins de 1 $ par passage), serait plus solide ?
4. Le champ `rayon` ajouté au cerveau est-il une bonne idée, vu la baisse stricte du tri (195 → 189/202) ? Ou faut-il plutôt filtrer après coup, par le jugement de pertinence du rédacteur ?
5. Les correctifs d'aujourd'hui sont-ils généraux, ou du cas par cas déguisé ?
   - `cataloguePageBrute` : pas de catégorie entière pour un rayon imposé ;
   - `boutiqueNommee` : le mot « chez » l'emporte sur le cerveau ;
   - `agenceNommee` : les mots propres au nom d'une agence la désignent.
6. Y a-t-il des bugs que je n'ai pas vus dans `orchestrate()`, `horsTovo()`, `redigerEtJuger()` ou `comprendre()` ?
7. Est-ce que je dévie de l'objectif du fondateur, et où ?
