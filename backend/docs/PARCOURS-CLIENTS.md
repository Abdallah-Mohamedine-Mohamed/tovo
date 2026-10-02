# Les trois parcours clients de Tovo

**Statut** : brouillon, à valider par le fondateur. Aucune ligne de code ne sera écrite avant sa validation.
**Date** : 2 octobre 2026.
**Origine** : l'évaluation externe du 02/10 — « repenser l'orchestration autour des parcours clients et des engagements réels de Tovo ».

Pour chaque parcours, ce document décrit :

- **ce que veut le client** ;
- **comment ça marche aujourd'hui**, d'après le code, avec ses défauts ;
- **le parcours cible**, étape par étape : qui décide, ce que voit le client, ce qui est confirmé ;
- **les engagements de Tovo** : ce qui doit rester exact et fixe ;
- **comment le mesurer**.

Les décisions qui vous reviennent sont regroupées dans la **section 5**.

---

## 1. Les principes communs (à valider d'abord)

1. **Un seul interprète.** Le cerveau lit la phrase et dit : l'intention, le produit, le rayon, la boutique nommée, et s'il est sûr.
   - Plus aucun détecteur à mots ne décide à sa place. Ils servent seulement de secours quand le cerveau est en panne, et ne déclenchent alors jamais d'action qui coûte.
   - Plus de court-circuit qui répond avant lui.
2. **Un état de parcours explicite.** Le serveur sait à chaque instant où en est le client.
   - Les états possibles : « choisit un produit », « choisit les options », « panier prêt », « confirme une course », « attend le livreur »…
   - Un message court (« le premier », « oui », « Centre aéré ») est compris par rapport à cet état, pas deviné.
3. **Une seule recherche catalogue**, la même partout. Elle reçoit ce que le cerveau a compris et rend : des produits pertinents, ou « Tovo n'en a pas » (→ parcours 3).
4. **L'IA écrit la conversation ; les cartes portent les engagements.**
   - L'IA rédige ce qui se dit : comprendre, reformuler, s'excuser, répondre à « Tu es sourd ? ».
   - Un prix, un total, des frais, un délai, une confirmation, une autorisation de dépense ou un état de livraison viennent **du serveur**. Ils sont affichés sur une carte, à l'identique, et l'IA n'a pas le droit de les reformuler.
   - ⚠️ C'est une **nuance à votre règle** « aucune phrase écrite par le code ». Voir la question D0.
5. **Aucune action qui coûte sans un geste du client sur une carte qui montre le prix.** Une action qui coûte : commander, faire déplacer un livreur, annuler, autoriser un achat.

---

## 2. Parcours A — Commander un repas personnalisable

> « Je veux un tacos poulet chez Otakoss Centre Aéré, sans oignons »

### Aujourd'hui

1. La phrase peut être traitée de trois façons :
   - par la recherche préalable de `chat.ts`, qui répond **avant le cerveau** si un mot trouve un produit exact ;
   - par l'orchestrateur, qui a sa propre recherche ;
   - par l'assistant et l'outil `rechercher_produits`, qui a encore la sienne.
2. Le produit s'affiche (`product_carousel`).
3. **Les options sont bien protégées** (`tools.ts`, `ajouterAuPanier`) : un produit à options ne s'ajoute jamais sans la carte de choix (`option_selector`). C'est le client qui touche « Ajouter au panier — prix ».
4. Le panier n'accepte qu'**une boutique à la fois**. Un produit d'une autre boutique affiche les tuiles « Vider et recommencer » / « Garder mon panier ».
5. **L'écran panier** (`cart_screen.dart`) :
   - propose l'adresse habituelle (ou une autre, sur la carte) ;
   - affiche le devis (frais de livraison compris) ;
   - propose le paiement en espèces ou par Nita ;
   - et le bouton « Commander — total ».
6. **Le serveur calcule seul le total** (`POST /orders`, `place_delivery_order`) : aucun montant n'est accepté du client. La boutique et les livreurs sont prévenus, puis la carte de suivi s'affiche.

**Ce qui est solide** : les étapes 3 à 6 (options, panier, devis, total calculé par le serveur).

**Ce qui ne l'est pas** :

- l'étape 1, avec ses trois chemins aux règles différentes ;
- « sans oignons » : s'il n'existe pas d'option « sans oignons », la demande se perd sans que le client le sache ;
- se corriger après coup (« non, plutôt bœuf ») dépend de l'assistant, sans état clair.

### Parcours cible

| # | Le client | Tovo (qui décide) | Ce que voit le client |
|---|---|---|---|
| A1 | Dit ce qu'il veut | **Cerveau** : recherche, produit « tacos poulet », boutique « O'Takoss Centre Aéré » | — |
| A2 | — | **Recherche unique**, dans cette agence | La phrase de l'IA, puis les produits correspondants. Une seule agence possible (si elle est nommée), sinon le choix de l'agence |
| A3 | Touche un produit | **Serveur** : le produit a des options | La carte de choix, avec les options obligatoires marquées et le prix qui suit les choix |
| A4 | Une demande sans option prévue (« sans oignons ») | **Cerveau** : la reconnaît comme une précision | Une ligne « Note pour la boutique : sans oignons », visible et modifiable. **Jamais avalée** |
| A5 | « Ajouter au panier — prix » | **Serveur** | Le panier, avec son total |
| A6 | Se corrige (« plutôt bœuf », « enlève le coca ») | **Cerveau** et **état** (« panier ouvert ») | Le panier modifié, ou la carte de choix rouverte |
| A7 | Ouvre le panier | **Serveur** : adresse, devis, frais | Adresse, frais, total, paiement |
| A8 | « Commander — total » | **Serveur** | Le suivi. Une phrase de l'IA, mais **le total et l'état viennent de la carte** |

### Engagements de Tovo (fixes, venus du serveur)

Le prix de chaque article et des options, les frais de livraison, le total, le moyen de paiement, l'état de la commande.

### Comment le mesurer

Des scénarios de **plusieurs messages**, envoyés à la vraie route `/chat`, avec des **vérifications objectives** plutôt qu'un juge.

- La bonne boutique et le bon produit sont-ils affichés ?
- La carte d'options est-elle apparue avant l'ajout ?
- Le total du panier est-il égal au calcul du serveur ?
- Aucune commande n'est-elle créée sans le geste du client ?

Le juge IA ne note plus que la **qualité de la phrase**.

---

## 3. Parcours B — Faire venir un livreur (course, colis)

> « Je veux un livreur » · « Envoie un colis à ma mère à Gamkalley » · « Va chercher un sac chez Moussa, 90 12 34 56 »

### Aujourd'hui

1. **« Je veux un livreur », avec la position connue → la course est commandée immédiatement, sans carte ni confirmation** (`livreur.ts`, `commanderUnLivreur`).
   - Message : « C'est parti. Un livreur vous appelle dans les N minutes ».
   - C'était votre choix (« un livreur, pas un formulaire »).
   - Le prix est le tarif ville fixe, **mais le client ne le voit qu'après**.
2. Sans position : la carte `courier_form` en mode automatique. Elle prend la position et commande d'elle-même.
3. **Colis à déposer ou à récupérer** : la carte `courier_form`, en mode « déposer » ou « récupérer ».
   - Elle contient : départ, destination, contact sur place, taille, paiement.
   - Le client touche « Commander le livreur ».
   - Avec des détails dans la phrase (un nom, un numéro), c'est l'assistant qui pré-remplit la carte.
4. **Garde-fous actuels** :
   - le cerveau classe « livreur », « colis » et « annuler » comme actions coûteuses ;
   - s'il n'est pas sûr, il propose des tuiles au lieu d'agir ;
   - une course déjà en cours n'est jamais doublée.
5. **Faille relevée par l'évaluation** : si le cerveau répond sans le champ « sûr » (cela peut arriver avec le secours OpenAI), la décision compte comme certaine, et un livreur peut partir.

**Ce qui est solide** : l'idempotence (un même message ne commande jamais deux livreurs), le prix calculé par le serveur, et la carte de colis.

**Ce qui ne l'est pas** :

- un livreur part **sur une seule interprétation de l'IA**, sans que le client ait vu le prix ;
- « un colis de riz de 25 kg » est encore lu comme un colis (échec stable de l'examen).

### Parcours cible

| # | Le client | Tovo (qui décide) | Ce que voit le client |
|---|---|---|---|
| B1 | Demande un livreur ou un colis | **Cerveau** : livreur ou colis, **sûr ou non** (sans le champ = pas sûr) | Pas sûr : deux ou trois tuiles (« Faire venir un livreur » / « Chercher du riz »…) |
| B2 | — | **Serveur** : tarif, délai de rappel, course déjà en cours ? | **La carte de course pré-remplie** : où le livreur va, le prix, le délai, le paiement. Un seul bouton : « Commander le livreur — prix » (**voir D1**) |
| B3 | Complète ou corrige (« plutôt à Yantala », « c'est un gros sac ») | **Cerveau** et **état** (« confirme une course ») | La même carte, mise à jour. Jamais une nouvelle commande |
| B4 | Touche « Commander le livreur » | **Serveur** : commande, recherche d'un livreur | Le suivi : prix et état venus de la carte |
| B5 | « Il ne répond pas », « annule » | **Cerveau** : aide ou annuler, puis **confirmation** | « Oui, annuler » / « Non, la garder ». L'annulation n'est faite qu'au toucher |

### Engagements de Tovo

Le prix de la course (tarif ville ou calculé), le délai de rappel annoncé, l'état de la course, les conditions d'annulation.

### Comment le mesurer

- **Aucune phrase de l'examen ne doit créer de course sans le toucher du client** : c'est vérifié directement en base.
- Les pièges : « un colis de riz », « je veux devenir livreur », « un livre », « appelle-moi un taxi ».
- La correction d'une carte ne crée jamais de deuxième course.

---

## 4. Parcours C — Ce que Tovo n'a pas (boutique, produit ou médicament ailleurs)

> « De la viande chez Tchos » · « Haddad Khalil » · « De la pommade Nivea » · « paracétamol »

### Aujourd'hui

**Quatre entrées** :

1. **Une boutique nommée que Tovo ne connaît pas** (Tchos) : « **Tchos** n'est pas encore sur Tovo. Voulez-vous qu'un livreur aille vous acheter **de la viande** là-bas ? ». Avec deux tuiles : « Oui, envoyez un livreur » / « Non, voir ce que Tovo propose ».
2. **Une boutique connue de l'annuaire public ou de Google** (Haddad Khalil) : une carte avec où elle est, son numéro, et les boutons « Envoyer un livreur » et « Appeler ».
3. **Un produit que Tovo n'a pas** (pommade) : les commerces du bon type les plus proches, qui en ont « probablement ».
4. **Un médicament** : les pharmacies proches. La nuit et le dimanche, les pharmacies de garde.

**Puis « Oui, envoyez un livreur » → une course « récupérer » ordinaire** (`catalogue.ts`, `reponseHorsTovo`). La seule trace de l'achat est un **texte libre** (« Acheter de la viande chez Tchos »).

**Le problème relevé par l'évaluation, vérifié dans `orders.ts`** : la commande ne contient **ni le prix de l'achat, ni un plafond, ni l'accord du client sur ce montant, ni de preuve** (ticket).

- Tovo promet pourtant : « il avance l'achat, vous le lui remboursez à la livraison ».
- Si le livreur avance 30 000 F et que le client conteste, rien ne permet de trancher.
- Le prix affiché au client ne comprend que la course.

**C'est un engagement financier que Tovo prend sans l'encadrer.**

**Ce qui est solide** :

- l'annuaire, Google et les pharmacies de garde ;
- rien n'est commandé sans le « Oui » du client ;
- un commerce Tovo n'est jamais présenté « hors Tovo » ;
- chaque demande nourrit la liste de prospection « Boutiques demandées ».

### Parcours cible : un vrai service « Achat pour moi »

| # | Le client | Tovo (qui décide) | Ce que voit le client |
|---|---|---|---|
| C1 | Nomme une boutique ou un produit absents | **Cerveau** : produit, boutique. **Recherche unique** : Tovo n'en a pas | La phrase de l'IA, puis la carte du commerce (adresse, numéro) ou les commerces proches. Pour un médicament : les pharmacies, ou celles de garde |
| C2 | « Envoyer un livreur » | **Serveur** | **La carte « Achat pour moi »** : quoi acheter (modifiable), où, **un budget maximum** (voir D2), le prix de la course, le paiement de l'achat (voir D4) |
| C3 | Ajuste et touche « Commander — course X F + achat jusqu'à Y F » | **Serveur** : une commande d'un **type à part**, avec description de l'achat, plafond et accord horodaté | Le suivi : « Le livreur va chez Tchos » |
| C4 | — | **Livreur sur place** : il trouve l'article et saisit le **prix réel** dans son application, avec une **photo du ticket** (voir D3) | Si prix réel ≤ plafond : « Viande achetée : 4 500 F », avec la photo. **Si prix réel > plafond ou article absent : le client doit accepter, sinon rien n'est acheté** (voir D5) |
| C5 | Reçoit | **Serveur** : total = course + prix réel | Le reçu : course, achat, total. En espèces au livreur ou par Nita |

### Engagements de Tovo

Le prix de la course, le plafond d'achat accepté par le client, le prix réel avec sa preuve, et le total final. **Tovo ne présente jamais un commerce hors Tovo comme sûr d'avoir l'article** (« probablement »).

### Ce que ce parcours demande de construire (après validation)

- **Base de données** : un type de commande « achat pour moi », avec description, plafond, prix réel, photo du ticket et accord du client. C'est une nouvelle migration.
- **Application livreur** : saisir le prix réel, photographier le ticket, signaler « article absent ».
- **Application client** : la carte C2, et la demande d'accord en C4.
- **Admin** : les litiges d'achat.

C'est le plus gros des trois parcours. Je recommande de le **construire après A et B**, et en attendant de **ne plus promettre l'avance** (voir D6).

### Comment le mesurer

- Aucune course « achat » sans plafond accepté.
- Le total final est égal à la course plus le prix réel.
- Jamais d'achat au-dessus du plafond sans un nouvel accord.
- Les phrases : « viande chez Tchos », « Haddad Khalil », « pommade », « paracétamol » la nuit et le jour, « gâteau d'anniversaire » (qui doit mener aux pâtisseries, pas aux supermarchés).

---

## 5 bis. Décisions du fondateur (02/10)

- **D0 : oui.** L'IA écrit la conversation ; les prix, confirmations et états viennent du serveur, sur les cartes.
- **D1 : un seul toucher.** « Je veux un livreur » affiche la carte de course pré-remplie, prix compris. La course part au toucher, jamais sur une phrase.
- **D2 à D5 et D7 (achat hors Tovo) : le livreur appelle le client**, et c'est le client qui lui dit ce qu'il veut. Volontairement **pas de règle figée** (plafond, preuve, prix plus élevé, frais) : ce point en mêle plusieurs, que le fondateur garde à sa main.
  - Conséquence pour le parcours C : **pas de nouveau type de commande** pour l'instant. La course « récupérer » reste, avec ce que le client veut acheter et où.
- **D6 : suivre la recommandation.** Tovo ne promet plus que « le livreur avance l'achat, vous le remboursez ». Il dit que **le livreur appelle le client** pour convenir de l'achat.
- **D8 : suivre la recommandation.** À vérifier auprès d'un pharmacien. En attendant, le livreur appelle le client, comme pour tout achat.

## 5. Les décisions qui vous reviennent (questions d'origine)

Pour chaque question, ma recommandation est entre parenthèses. Je n'ai inventé **aucun chiffre** : les montants sont à vous.

- **D0 — La règle des phrases.** L'IA écrit la conversation, mais les prix, totaux, délais, confirmations et états restent exacts, sur les cartes, venus du serveur. Acceptez-vous cette nuance à « aucune phrase écrite par le code » ? *(Je recommande oui.)*
- **D1 — « Je veux un livreur ».** Faut-il garder la commande immédiate, sans confirmation ? Ou montrer d'abord la carte pré-remplie, prix compris, avec un seul toucher « Commander le livreur — prix » ? *(Je recommande le toucher unique : le client voit le prix avant, et une erreur de l'IA ne fait jamais déplacer un livreur.)*
- **D2 — Le plafond de l'achat.** Quel montant maximum un livreur peut-il avancer ? Un plafond unique pour toute la ville, ou choisi par le client sous une limite fixée par Tovo ?
- **D3 — La preuve.** Faut-il une photo du ticket obligatoire, l'appel du livreur au client avant de payer, ou les deux ? *(Je recommande la photo obligatoire : c'est la seule preuve en cas de litige.)*
- **D4 — Le paiement de l'achat.** En espèces au livreur seulement, ou aussi par Nita ? Avant ou après l'achat ?
- **D5 — Prix plus élevé ou article absent.** Le livreur appelle-t-il le client, ou le client accepte-t-il dans l'application ? Si l'article est absent, la course est-elle due ?
- **D6 — En attendant le parcours C complet.** Faut-il continuer à proposer « un livreur avance l'achat » sans plafond ni preuve ? Ou le limiter dès maintenant, par exemple « le livreur vous appelle pour convenir du montant » ? *(Je recommande de limiter dès maintenant : c'est le seul risque d'argent réel.)*
- **D7 — Les frais de l'achat.** L'avance est-elle gratuite pour le client, ou y a-t-il des frais d'achat en plus de la course ?
- **D8 — Médicaments.** Pour un médicament sur ordonnance, le livreur doit-il récupérer l'ordonnance chez le client d'abord, ou en recevoir une photo ? *(À vérifier aussi auprès d'un pharmacien : ce qui est permis au Niger.)*

---

## 6. L'ordre de travail proposé (après vos réponses)

1. **L'examen par parcours**, par la vraie route `/chat`, avec des vérifications objectives. Il donne une référence honnête **avant** tout changement.
2. **Les principes communs** : un seul interprète, l'état de parcours, une seule recherche. Plus les deux corrections de sécurité de l'évaluation : le vérificateur d'inventions, et une décision sans champ « sûr » traitée comme incertaine.
3. **Parcours B** (le plus court, et il touche à la sécurité), puis **A**, puis **C**. Chacun est mesuré avant et après, et annulé s'il n'est pas meilleur.

---

## 7. Avancement (02/10, après les décisions)

### L'examen par parcours : `scripts/banc-ia/examen-parcours.ts`

- Il passe par la **vraie route** `POST /chat` (comme l'application), avec un vrai client de test par scénario, supprimé à la fin avec ses commandes.
- Il juge par des **vérifications objectives**, sans IA : aucune course créée en base sans toucher, aucun produit sans rapport, la bonne agence, la bonne carte, aucune promesse d'avance.
- **Aucun livreur réel n'est prévenu** : la recherche de livreur est remplacée par une tâche vide pendant l'examen.
- Une erreur serveur est retentée une fois, car la connexion à Supabase expire parfois depuis le poste de développement. Une panne technique est notée à part, hors score.
- Coût : environ 0,05 $ par passage (le cerveau, le rédacteur et parfois l'assistant ; aucun juge).

### Résultats

| | Référence (avant) | Après |
|---|---|---|
| 24 scénarios d'origine | 18 puis 17 / 24 | 23 puis 24 / 24 |
| + 10 scénarios **nouveaux**, écrits après les corrections et avant de les passer | — | 10 / 10 |
| Total, dernier passage | — | **34 / 34** |

Reste instable : « deux litres de lait » (A4). Le jugement de pertinence du rédacteur varie d'un passage à l'autre : une fois des supermarchés, une fois des céréales et de la pâte à tartiner.

### Ce qui a été changé

- **Un seul interprète** (`orchestrator.ts`) :
  - quand le cerveau a compris « recherche » ou « boutique », le filtre à mots (`rechercheProduitRapide`) ne peut plus refuser la recherche : « un colis de riz » contient « colis » ;
  - l'assistant ne reçoit plus les outils d'action que le cerveau n'a pas choisis (`outilsPermis` : carte de course, annulation, recommande). Il ouvrait la carte de course pour « un colis de riz » trois fois sur quatre.
- **D1** (`chat.ts`, `livreur.ts`) : « Je veux un livreur » affiche la carte pré-remplie, prix compris. Plus de commande immédiate, plus de carte qui commande d'elle-même (`auto`). Une course déjà en route est montrée au lieu d'en préparer une seconde.
- **D6** (`catalogue.ts`) : plus aucune promesse « le livreur avance l'achat, vous le remboursez ». Le livreur appelle le client pour convenir de l'achat, et les consignes interdisent au rédacteur de le promettre.
- **Commerces hors Tovo** (`commerces.ts`) : le type de commerce le plus probable passe d'abord (la boulangerie pour un gâteau). Les autres types ne servent que s'il n'y en a aucun à portée.
- **Sécurité, suite à l'évaluation** :
  - le vérificateur ne tient plus les mots du client pour des faits chiffrés (`ajouterParole`) ;
  - une décision du cerveau sans « sûr » est incertaine ;
  - un échec de lecture d'un rayon n'est plus mémorisé ;
  - l'ancien examen calcule correctement sa médiane et refuse un passage avec moins de 90 % de phrases jugées.

### Pas encore fait

- **L'état de parcours explicite** et **la recherche unique** (principes 2 et 3).
  - Aucun scénario ne les met en défaut aujourd'hui. Selon la méthode, on ne refait pas l'architecture sans échec mesuré.
  - Il faut d'abord des scénarios de **plusieurs messages** : se corriger (« plutôt bœuf »), « le premier » après une liste, compléter une carte de course.
- **A4** : rendre stable le jugement de pertinence du rédacteur.
- **« Sans oignons »** : une précision sans option prévue ne doit pas se perdre (A4 cible du parcours A).

### Scénarios sur plusieurs messages (02/10, suite)

Dix conversations (M1 à M10) ont été ajoutées : désigner, se corriger, compléter, changer d'avis, préciser.

**Une leçon de méthode.** Au premier passage, l'examen affichait 44/44. En **relisant les réponses une par une**, j'ai trouvé des réponses fausses que mes vérifications laissaient passer :
- « C'est bien noté pour sans oignons » alors que rien n'est enregistré ;
- trois boutiques au lieu de l'agence choisie ;
- « Annuler ma commande » sans commande ;
- « un livreur se rend à votre position » avant tout toucher ;
- une console de jeu proposée pour des livres pour enfants ;
- une carte de course vide alors que le client avait dit où aller.

Les vérifications ont été durcies. **Relire les réponses reste obligatoire : un score ne suffit pas.**

**Référence honnête : 37 puis 38 sur 44.** Six échecs sont stables.

| Échec | Ce que fait Tovo | Cause | Principe en jeu |
|---|---|---|---|
| B6, N1 | « Sac à déposer à Gamkalley », « clés à mon frère à Yantala » → carte de course **vide**, et « un livreur se rend à votre position » | Le chemin rapide ouvre la carte sans ce que le client a dit ; le cerveau ne donne que l'intention | 1. Un seul interprète, qui doit aussi extraire le lieu et le destinataire |
| M5 | « Otakoss » → choix de l'agence → « centre aéré » → **trois boutiques** « du Centre Aéré » (Boba, O'Takoss, Baaklini) | Le choix en attente passe après la reconnaissance des enseignes | 2. État de parcours |
| M4 | « sans oignons » après des tacos → compris comme une **réclamation** : « j'ai transmis votre consigne à notre équipe » (un signalement est réellement créé) | Aucun état « choisit un produit », donc une précision devient une plainte | 2. État de parcours, et précision sans option (A4 cible) |
| M10 | « plus loin ? » → les deux mêmes commerces | L'annuaire n'a que 2 boutiques de beauté, et « plus loin » n'ouvre pas les types suivants (supermarché, pharmacie) | 3. Recherche cohérente |
| N10 | « livres pour enfants » → une console de jeu | Un résultat approximatif sans rapport est affiché | 3. Recherche cohérente (pertinence) |

Instable : M7 (« laisse tomber » propose parfois « Annuler ma commande » sans commande) et A4 (lait).

### La constitution (02/10, soir)

À la demande du fondateur (« des règles, pas du cas par cas »), dix articles généraux ont été écrits dans `src/ai/constitution.ts`. Les trois IA les lisent, et le serveur garantit chacun d'eux là où il se vérifie sans IA (voir `docs/CONSTITUTION.md`).

**Résultat : 44/45 sur trois passages**, contre 37 à 38/44 avant (dernier passage : `parcours-2026-10-02-21-45.json`). Le seul échec du dernier passage est une erreur technique (401). Toutes les réponses ont été **relues**.

La relecture a encore permis de corriger trois inventions qui passaient les vérifications :
- « librairies du centre-ville » ;
- « c'est annulé » sans commande ;
- « 21 options » annoncées pour un seul produit affiché.

La migration 0075 a été appliquée :
- « merguez » ne renvoie plus que l'assiette et la pizza merguez, sans les tacos ;
- la note « sans oignons » est enregistrée en base.

**Côté application** (à reconstruire) :
- un seul bouton « Parcourir les N autres produits » ;
- plus d'icône dans « Envoyer un livreur » ;
- la note pour la boutique, sur la carte du panier et dans l'écran du panier.

**Points ouverts** :
- Le juge retire la « Pizza merguez » quand on demande des merguez : article 6, un produit se juge par ce qu'il est. À confirmer par le fondateur.
- Une réponse de conversation a tutoyé (« si tu as besoin »).
- Deux tests mobiles cherchent encore la carte d'accueil « Explorer les boutiques », remplacée le 01/10. Ils échouaient déjà avant aujourd'hui.
