# L'état de parcours : bilan et suite

**Statut** : brouillon, à valider par le fondateur. Aucune ligne de code avant sa validation.
**Date** : 9 octobre 2026.
**Suite de** : `PARCOURS-CLIENTS.md` (principe 2) et `CONSTITUTION.md` (article 2).

---

## 1. En une phrase

Une première forme d'état de parcours existe depuis le 02/10 et le dernier examen la donne sans échec (57/57, le 07/10). **Je ne propose donc pas de refonte**, mais une série de nouveaux scénarios qui visent ses limites connues, puis des corrections seulement là où un échec est mesuré.

> Correction : le 08/10, j'ai présenté l'état de parcours comme un chantier à ouvrir, en citant les échecs du 02/10 (37–38/44). Ces échecs ont été corrigés le soir même par la constitution. Ma note de travail était périmée.

---

## 2. Ce qui existe aujourd'hui

À chaque message écrit, en parallèle du reste (`routes/chat.ts`), le cerveau reçoit :

| Ce qu'il reçoit | D'où | Exemple |
|---|---|---|
| Le **texte** du dernier message de Tovo | `dernierMessageTovo` | « Où faut-il récupérer le colis ? » |
| L'**écran** : les cartes du dernier message de Tovo, décrites en clair | `ai/etat.ts`, `decrireEcran` | « Tovo attend que le client CHOISISSE une adresse entre : … » ; « Une carte de course est ouverte : elle n'est PAS commandée » |
| La **commande en cours** (48 h, ni livrée ni annulée) | `etatDuParcours` | « Commande en cours : aucune. » |

Ce qui est **garanti par le serveur**, sans dépendre de l'IA :

- un choix d'agence en attente l'emporte sur les autres boutiques au nom proche (`agenceNommee`) ;
- les précisions extraites par le cerveau (départ, arrivée, téléphone) remplissent la carte de course (`argumentsDeCourse`) ;
- une précision comme « sans oignons » est rangée dans la note de commande (`noteCommande.ts`).

Le reste est **lu par le cerveau** : il comprend « le premier », « centre aéré », « laisse tomber » grâce à la description de l'écran.

**Mesure** : examen par parcours (`scripts/banc-ia/examen-parcours.ts`), 57 scénarios dont 11 sur plusieurs messages (M1–M11) et 2 en trois messages (T2) ; dernier passage 57/57 (`resultats/parcours-2026-10-07-09-43.json`).

---

## 3. Ses limites, lues dans le code

Ce sont des **hypothèses** : aucun scénario ne les a encore mises en défaut. Chacune a son scénario à la section 4.

| # | Limite | Pourquoi je la soupçonne |
|---|---|---|
| L1 | **La mémoire ne dure qu'un tour.** L'écran décrit est celui du *dernier* message de Tovo. Une question au milieu (« c'est combien la livraison ? ») fait oublier la carte ouverte juste avant. | `etatDuParcours` lit `limit(1)` sur les messages de Tovo. |
| L2 | **La carte de course est décrite sans son contenu.** Le cerveau lit « une carte de course est ouverte », pas « départ : Yantala ». Un complément (« le numéro de ma tante c'est le 90 12 34 56 ») peut produire une carte où Yantala a disparu. | `decrireEcran`, cas `courier_form` ; `argumentsDeCourse` ne part que des précisions du message courant. |
| L3 | **Départ et arrivée dans la même phrase.** « Va chercher un sac chez ma tante à Yantala et apporte-le à Gamkalley » : la carte reçoit le départ, l'arrivée est perdue. | `argumentsDeCourse` : s'il y a un départ, l'arrivée n'est pas transmise. |
| L4 | **Les listes de commerces hors Tovo** n'ont pas été testées avec une désignation (« le deuxième », « celui de Yantala »), ni avec un lieu ajouté après coup (« et vers Koira Kano ? »), fonction ajoutée le 07/10. | Aucun scénario M ou T ne le fait. |
| L5 | **Un écran ancien vaut encore.** Une conversation rouverte le lendemain : « le premier » désigne la liste d'hier. | Aucune limite de temps sur l'écran lu (seule la commande en cours a ses 48 h). |
| L6 | **« le premier » est d'abord repéré par des mots** (`referenceAuxResultats`, expressions régulières) pour sauter la recherche préalable. Une tournure imprévue (« je prends celui à 2 000 », « le moins cher ») lance une recherche inutile. | `intents.ts`. Ce n'est qu'un raccourci de vitesse : le cerveau décide quand même. À mesurer, pas à supposer. |

---

## 4. La série de scénarios proposée (S1–S10)

Écrits **avant** toute correction, ajoutés à `examen-parcours.ts`, avec des vérifications objectives (sans IA).

| # | Limite | Conversation | Ce qui doit être vrai |
|---|---|---|---|
| S1 | L1 | « Je veux un livreur » → « c'est combien la livraison ? » → « c'est pour Gamkalley » | La carte de course revient, avec Gamkalley ; aucune commande. |
| S2 | L2 | « Va chercher un sac chez ma tante à Yantala » → « son numéro c'est le 90 12 34 56 » | Carte avec Yantala **et** le numéro. |
| S3 | L2 | « J'ai un colis à déposer à Gamkalley » → « non, plutôt à Koira Kano » | Carte avec Koira Kano, plus Gamkalley. |
| S4 | L3 | « Va chercher un sac chez ma tante à Yantala et apporte-le à Gamkalley » | Carte avec Yantala en départ **et** Gamkalley en arrivée. |
| S5 | L4 | « une pharmacie près de moi » → « le deuxième, il est où ? » | La réponse parle du 2ᵉ commerce de la liste, pas d'une nouvelle recherche. |
| S6 | L4 | « un supermarché » → « et vers Yantala ? » | Des supermarchés autour de Yantala, distances depuis Yantala. |
| S7 | L1, L4 | « des chaussures de sport » → « merci » → « le premier, c'est combien ? » | Pas d'invention de prix (le commerce est hors Tovo) ; il s'agit bien du premier. |
| S8 | L5 | Une liste de pizzas, puis (date du message vieillie de 24 h dans l'examen) « le premier » | Tovo redemande ou repart de zéro, sans ajouter une pizza au panier. |
| S9 | L6 | Une liste de pizzas → « je prends la moins chère » | La moins chère de la liste, sans nouvelle recherche. |
| S10 | contrôle | Un tacos → « sans oignons » → « et un coca » | La note « sans oignons » reste sur le tacos ; le coca est cherché. |

**Coût** : un passage des 10 scénarios ≈ 25 messages ≈ 75 appels d'IA, environ 0,04 $. Puis un passage complet (67 scénarios) pour vérifier que rien d'autre ne casse, environ 0,15 $. Sur les mêmes clés que l'application : un passage à la fois, arrêt immédiat à la moindre erreur 402/429.

**Relecture** : chaque réponse relue, pas seulement le score (leçon du 02/10).

---

## 5. Les corrections possibles, seulement si un échec est mesuré

Préparées, mais **rien n'est fait tant qu'un scénario n'échoue pas** :

| Si échoue | Correction envisagée | Où |
|---|---|---|
| S1, S7 | L'écran lu est le dernier écran **qui attend quelque chose** (choix, carte ouverte, liste), même s'il y a eu une question entre deux. Au plus 3 messages en arrière. | `etat.ts` |
| S2, S3 | La carte de course décrite **avec son contenu** (« départ : Yantala, numéro : — ») ; le serveur **fusionne** : le nouveau champ remplace l'ancien, le reste est gardé. | `etat.ts`, `argumentsDeCourse` |
| S4 | `argumentsDeCourse` transmet départ **et** arrivée quand le cerveau a les deux. | `chat.ts` |
| S5, S6 | La liste de commerces décrite avec son rang et son quartier ; le lieu dit après coup relance la même recherche autour du nouveau lieu. | `etat.ts`, `catalogue.ts` |
| S8 | Un écran de plus de N heures n'est plus lu (« Rien n'est à l'écran »). | `etat.ts` |
| S9 | Le cerveau désigne le produit (rang ou critère) ; le serveur le retrouve dans la liste. | `decideur.ts`, `chat.ts` |

Ce sont des règles générales (constitution, article 2 et article 9), jamais une règle par phrase.

Économie au passage, sans effet sur le sens : `dernierMessageTovo` et `etatDuParcours` lisent le même message en base ; une seule lecture suffit (contenu et cartes).

---

## 6. Les décisions qui vous reviennent

- **E1 — La méthode.** Mesurer d'abord (S1–S10), corriger ensuite, sans refonte. *Ma recommandation : oui.*
- **E2 — La durée de validité d'un écran** (S8). Au-delà, « le premier » ne désigne plus rien et Tovo repart de zéro. *Ma proposition : 6 heures.*
- **E3 — Corriger la carte de course par la parole** (S3). Le dernier lieu dit remplace le précédent pour le même champ, sans redemander. *Ma recommandation : oui ; la carte reste de toute façon à confirmer d'un geste, avec son prix.*
- **E4 — Le coût** : environ 0,20 $ pour les deux passages, sur les clés de l'application. À lancer quand les crédits le permettent.

---

## 6 bis. Résultats du premier passage (09/10)

E1 à E4 validés par le fondateur. Passages : `resultats/partiel-parcours-2026-10-09-04-43.json` (S1–S10), puis `…-04-45.json` (S5 et S10, vérifications corrigées après relecture). Toutes les réponses ont été **relues**.

**Bilan honnête : 5 réussites sur 10.**

| # | Résultat | Ce que fait Tovo | Limite |
|---|---|---|---|
| S1 | ✗ | « c'est pour Gamkalley » après une question → **aucune carte**, et la phrase dit pourtant « la carte qui s'affiche » | **L1 confirmée** (et une phrase qui décrit un écran absent) |
| S2 | ✓ | Yantala et le numéro sur la carte | L2 non confirmée |
| S3 | ✓ | Koira Kano remplace Gamkalley | L2 non confirmée |
| S4 | ✗ | La phrase dit « de **Yantala** à **Gamkalley** », la carte livre **« Chez vous »** : le client lit un trajet et en commanderait un autre | **L3 confirmée, grave** |
| S5 | ✓ | « le deuxième » → la Pharmacie Deyzeibon, 2ᵉ à l'écran (après la boutique Tovo PARAPHARMACIE) | L4 non confirmée. *Faux échec au 1ᵉʳ passage : ma vérification ignorait la boutique affichée avant la liste.* |
| S6 | ✓ | « et vers Yantala ? » → des supermarchés autour de Yantala | L4 non confirmée |
| S7 | ✗ | « le premier, c'est combien ? » après « merci » → « Je n'ai pas d'article affiché à l'écran » | **L1 confirmée** |
| S8 | ✗ | « le premier » sur la liste d'hier → la Pizza 3 Fromage de la veille | **L5 confirmée** (E2 : 6 h) |
| S9 | ✓ | « la moins chère » → la Pizza Margerita, la moins chère de la liste, ajoutée au panier | L6 non confirmée |
| S10 | ✗ | « et un coca » pendant une commande chez O'Takoss Centre Aéré (qui vend du Coca à 700 F) → le Coca de **WORLD JUS**, donc deux livraisons | **Nouvelle limite L7 : la boutique du parcours en cours est oubliée.** *Fausse réussite au 1ᵉʳ passage : ma vérification ne regardait pas la boutique.* |

### Corrections, dans l'ordre proposé

1. **S4 (L3)** : la carte reprend départ **et** arrivée quand le cerveau a les deux (`argumentsDeCourse`, `preparer_course` en mode « récupérer »). Priorité : le texte et la carte se contredisent sur un engagement.
2. **S1, S7 (L1)** : l'écran lu est le dernier qui attend quelque chose (choix, carte ouverte, liste), jusqu'à 3 messages en arrière (`etat.ts`).
3. **S8 (L5)** : un écran de plus de 6 heures n'est plus lu (E2, `etat.ts`).
4. **S10 (L7)** : la boutique du parcours en cours (liste ou panier d'une seule boutique) est dite au cerveau, et la recherche cherche d'abord chez elle.

Après chaque correction : passage ciblé, relecture, puis passage complet (67 scénarios) à la fin.

---

## 6 ter. Version 1 : le dossier du parcours (09/10, REMPLACÉE par la section 6 quater)

> Relue par un autre agent le 09/10. Ses critiques ont été vérifiées dans le code et sont justes. La version 2 est en 6 quater ; celle-ci est gardée pour l'historique.

Le fondateur a refusé les quatre correctifs : « cherche une meilleure logique ». Il avait raison, car les cinq échecs ont **une seule cause**.

### La cause commune

Aujourd'hui, Tovo **n'a pas de mémoire propre**. À chaque message, il reconstruit la situation à partir de deux morceaux qui ne se parlent pas :

- **Ce que lit l'IA** : le texte et les cartes du *dernier* message de Tovo, décrits en phrases. Une question au milieu efface tout (S1, S7) ; une liste de la veille vaut encore (S8) ; la boutique d'une commande en cours n'y figure pas (S10).
- **Ce que construit le serveur** : les cartes, faites à partir de ce que le cerveau a extrait du *seul message courant*. L'IA et la carte peuvent donc dire deux choses différentes (S4 : « Yantala → Gamkalley » dans la phrase, « Chez vous » sur la carte).

Quatre correctifs boucheraient quatre trous ; le prochain parcours en ouvrirait d'autres.

### La logique proposée

**Un dossier par conversation, tenu par le serveur, qui est la seule vérité.**

```
dossier = {
  parcours : "course" | "repas" | "recherche" | aucun,
  mis_a_jour : 09/10 16:40,
  course    : { depart, arrivee, contact_depart, destinataire, quoi },
  repas     : { boutique, panier, note },
  recherche : { requete, lieu, montres : [ {rang 1, id, nom}, {rang 2, …} ] }
}
```

Quatre règles, valables pour tous les parcours :

1. **Le cerveau ne décrit plus la situation, il dit ce qui CHANGE.** Il reçoit le dossier et répond comme aujourd'hui (intention, produit, lieu, départ, arrivée, téléphone, précision), plus un seul champ nouveau : `suite` = *continuer* / *nouveau* / *aparté* / *abandonner*.
2. **Le serveur fusionne, sans IA.** Champ par champ, la dernière chose dite remplace la précédente (E3) ; le reste est gardé. Une **aparté** (« c'est combien ? », « merci ») ne touche pas le dossier. Le dossier se ferme sur une commande passée, un « laisse tomber », un nouveau parcours, ou **6 heures** d'inactivité (E2).
3. **Les cartes ET les phrases sortent du dossier.** La carte de course est dessinée à partir du dossier, et le rédacteur reçoit le même dossier comme faits. Le vérificateur (article 2) refuse une phrase qui nomme un lieu absent du dossier : le texte ne peut plus contredire la carte.
4. **« Le premier », « la moins chère », « celui de Yantala » se résolvent dans `montres`**, par le serveur, avec l'ordre exact de l'écran. Le cerveau dit seulement le rang ou le critère.

### Ce que ça règle

| Échec | Avec le dossier |
|---|---|
| S1 | La question est une aparté : la course reste ouverte, « Gamkalley » remplit l'arrivée, la carte revient. |
| S4 | Départ et arrivée vont dans le dossier ; la carte et la phrase en sortent toutes les deux. |
| S7 | « merci » est une aparté : la liste reste dans `montres`, « le premier » la retrouve. |
| S8 | Au-delà de 6 h, le dossier est fermé : « le premier » ne désigne plus rien, Tovo redemande. |
| S10 | Le dossier « repas » a sa boutique : la recherche cherche d'abord chez O'Takoss. |

Et ce qui marche aujourd'hui (S2, S3, S5, S6, S9) passe par le même chemin, au lieu de dépendre de ce que l'IA a relu.

### Ce que ça change

| Où | Quoi |
|---|---|
| Base | Migration 0079 : colonne `conversations.dossier` (jsonb). Une seule lecture par message, au lieu des deux actuelles (`dernierMessageTovo`, `etatDuParcours`). |
| `ai/dossier.ts` (nouveau) | La fusion, la fermeture et la résolution des références. **Code pur, testé sans IA** (tests unitaires). Remplace `etat.ts`. |
| `ai/decideur.ts` | Reçoit le dossier en JSON ; un champ `suite` de plus. |
| `chat.ts`, `tools.ts`, `catalogue.ts` | Les cartes de course, les listes et les recherches lisent et écrivent le dossier. |
| `verificateur.ts` | Un lieu nommé doit être dans le dossier. |

### Comment on le fait sans casser

1. **Le banc d'abord** : le nouveau champ `suite` est mesuré sur les 203 phrases de référence (≈ 200 appels du cerveau, quelques centimes). Si le score baisse, on n'avance pas.
2. **Un parcours à la fois** : B (course) d'abord, car S1 et S4 y sont ; puis les listes (S7, S8) ; puis le repas (S10).
3. Après chacun : les scénarios S, relus, puis les 67 scénarios.
4. Tant qu'un parcours n'est pas passé au dossier, il garde le fonctionnement actuel.

### Les décisions qui vous reviennent

- **F1** : adopter le dossier à la place des quatre correctifs. *Ma recommandation : oui.*
- **F2** : une question ou un remerciement au milieu (aparté) ne ferme jamais un parcours. *Ma recommandation : oui.*
- **F3** : commencer par la course (B). *Ma recommandation : oui.*

---

## 6 quater. Version 2 : une mémoire de conversation limitée (09/10)

### Ce que la relecture a corrigé

| Critique | Vérifié | Conséquence |
|---|---|---|
| Les échecs n'ont pas une seule cause : S4 vient aussi d'une **transformation** fausse | Oui : `argumentsDeCourse` (`chat.ts:982`) rend le départ **ou** l'arrivée, et `preparer_course` en mode « récupérer » force l'arrivée à « Chez vous » (`tools.ts`) | S4 se corrige **d'abord, à part** (étape 0), avec une protection |
| Le dossier ne peut pas être « la seule vérité » | Oui : le panier a sa route (`cart.ts`, `cart_add_item`), l'application y écrit sans passer par le chat ; les commandes, prix et statuts ont leurs tables | La mémoire ne garde **aucune donnée métier** : seulement des identifiants, relus au moment d'agir |
| Le nom `suite` est déjà pris | Oui : `suite` = « d'autres résultats » (`decideur.ts`, article 7) | Le nouveau champ s'appelle `tache` |
| Quatre valeurs exclusives représentent mal « et un coca » | Oui : c'est une nouvelle recherche **dans** le même repas | `tache` ne dit que le lien avec la tâche ; la nature du message reste dans `intention` |
| 6 h ne définit pas ce qui est à l'écran | Oui | Trois durées de vie distinctes (ci-dessous) |
| Un `jsonb` unique expose à des écritures perdues | Oui | Un seul écrivain et un numéro de version |

Et l'autre agent a raison sur l'examen : passer de 57/57 à 5/10 montre que **l'ancien examen ne couvrait pas ces situations**, pas que Tovo était fiable.

### La mémoire

```
memoire = {
  version : 12,
  tache : {                         // ce que le client est en train de faire
    genre : "course" | "repas" | "recherche",
    ouverte_le, touchee_le,
    course : { depart, arrivee, contact_depart, destinataire, quoi },  // champs PROVISOIRES, avant commande
    repas  : { boutique_id }                                          // une référence, rien d'autre
  } | null,
  ecran : {                         // la dernière liste réellement présentée
    message_id, montre_le,
    references : [ { rang: 1, genre: "produit" | "boutique" | "commerce", id, nom }, … ]
  } | null
}
```

**Ce qu'elle ne contient jamais** : le panier, les prix, les commandes, leurs statuts, la note « sans oignons » (déjà dans `notes_commande`). Tout cela est **relu dans ses tables** au moment de répondre ou d'agir.

### Les règles

1. **Le cerveau dit le lien avec la tâche**, dans un champ nouveau `tache` = `meme` / `nouvelle` / `abandon`. Le reste ne change pas : `intention` dit la nature du message, `suite` garde son sens.
   - « c'est combien la livraison ? » → intention *question*, tache *meme* : une aparté, la mémoire n'est pas touchée.
   - « et un coca » → intention *recherche*, tache *meme* : une recherche **dans** le repas en cours.
2. **La fusion est du code pur** (`ai/memoire.ts`, testé sans IA) : champ par champ, la dernière chose dite remplace la précédente (E3), le reste est gardé.
3. **Trois durées de vie** :

| Quoi | Vit jusqu'à | Protection |
|---|---|---|
| La tâche active | une commande passée (lue dans `orders`), un « laisse tomber », une nouvelle tâche | 6 h sans message (E2) |
| Les références d'écran | la **prochaine liste présentée**, quelle qu'elle soit, ou un changement de tâche | 6 h. Option G3 : l'application dit quel message est visible. |
| Le panier, les commandes, les prix | toujours valides : **jamais copiés**, relus à chaque fois | — |

4. **Un seul écrivain** : seule la route `/chat` écrit la mémoire, avec une version (`update … where version = lue`). En cas de conflit (deux messages très rapprochés), elle relit et refusionne une fois. Les actions directes de l'application (panier, commande) **n'écrivent jamais** la mémoire : leurs effets sont relus (une course commandée ferme la tâche « course » parce qu'une commande existe après `ouverte_le`).
5. **La carte et la phrase partent des mêmes faits** : la tâche (provisoire) et les données métier relues. Le vérificateur refuse une phrase qui nomme un lieu absent de la carte.

### S4, précisément

« Va chercher un sac chez ma tante à Yantala et apporte-le à Gamkalley »

1. Cerveau : intention *livreur*, tache *nouvelle*, départ « Yantala », arrivée « Gamkalley ».
2. Fusion : tâche course { départ : Yantala, arrivée : Gamkalley }.
3. La carte est construite **depuis la tâche** : départ Yantala, arrivée Gamkalley. Cela suppose la correction de la transformation (étape 0), sans quoi rien ne change.
4. **Protection** : si la carte à afficher n'a pas le départ et l'arrivée compris, elle ne s'affiche pas en état « Commander » ; elle s'affiche « à compléter », avec le champ manquant à remplir. Une contradiction entre ce qui est compris et ce qui serait commandé ne peut plus partir.

### « Et un coca », précisément

Tacos chez O'Takoss Centre Aéré → « sans oignons » → « et un coca »

1. Après le premier message : tâche repas { boutique : O'Takoss Centre Aéré }, écran = les 8 tacos.
2. « sans oignons » : rangée dans `notes_commande` (métier), la mémoire n'est pas touchée.
3. « et un coca » : intention *recherche*, produit « coca », tache *meme*.
4. **La boutique de référence** : celle du **panier** s'il n'est pas vide (relu dans `carts`, c'est lui qui fait foi), sinon celle de la tâche.
5. Recherche **d'abord chez cette boutique** : Coca, 700 F. Si elle n'en a pas, recherche générale, et la phrase le dit (« O'Takoss n'en a pas ; en voici ailleurs, livraison à part »).
6. L'écran devient la liste des cocas : « le premier » désigne désormais un coca.

### L'ordre de travail

0. **S4, tout de suite et à part** : `argumentsDeCourse` transmet départ **et** arrivée ; `preparer_course` accepte une arrivée en mode « récupérer » ; protection « à compléter ». Mesure : S4, S2, S3, M6, B6, B7, N1.
1. `ai/memoire.ts` en code pur, avec ses tests (fusion, durées de vie, conflit de version).
2. Le champ `tache` dans le cerveau, mesuré sur les 203 phrases de référence (≈ 200 appels, quelques centimes) avant d'être gardé.
3. Puis un parcours à la fois : course (S1), références d'écran (S7, S8), repas (S10). Après chacun : scénarios S relus, puis les 67.

### Les questions du fondateur, mesurées (09/10, scénarios R1–R6)

Fichier : `resultats/partiel-parcours-2026-10-09-11-54.json`. **2 réussites sur 6**, réponses relues.

| # | Question | Résultat |
|---|---|---|
| R1 | Pizzas de Maison Grill, puis « je prends la pizza margherita » | ✓ Ajoutée au panier (la Margerita de Maison Grill) |
| R2 | « la pizza margherita de chez Maison Grill, livrée à Yantala », en une phrase | ✗ « Je ne trouve pas de pizza margherita chez Maison Grill » : elle existe, écrite « Margerita ». Et « Yantala » n'est gardé nulle part pour la livraison. |
| R3 | Chercher un colis à Harobanda, l'amener chez moi | ✓ Carte « Aller chercher », départ Harobanda, arrivée chez le client |
| R4 | Chercher à Harobanda, amener à Banifandou | ✗ Phrase « de Harobanda à Banifandou », carte livrée chez le client (comme S4) |
| R5 | Course + « dites-lui de sonner au portail bleu » | ✗ La phrase dit « avec votre consigne pour le portail bleu » : **inventé**, la carte de course n'a aucun champ de consigne |
| R6 | Tacos, puis « dites au livreur de m'appeler en arrivant » | ✗ « C'est noté, votre instruction sera transmise au livreur » : **inventé**, rien en base |

**Ce que montre la lecture du code :**
- Une commande ne part jamais sur une phrase : seulement sur le bouton d'une carte qui affiche le prix (D1, article 5). C'est voulu.
- Une course a **deux sortes seulement** : « Venir chez moi » (départ = le client) et « Aller chercher » (arrivée = le client). Le trajet d'un endroit à un autre, sans passer par le client (Harobanda → Banifandou), **n'existe pas** : ni dans la carte (`courier_form.dart`), ni dans la commande (`orders.ts`, `mode`).
- **Aucune consigne n'arrive au livreur d'une course** : la note gardée n'est jointe qu'aux commandes de boutique (`orders.ts:216`, `type === 'delivery'`), et la carte n'a pas de champ de consigne. Le champ `parcel_note` existe en base mais rien ne le remplit, et l'application du livreur ne l'affiche pas.
- Pour un repas, la note (« sans oignons », « appelez en arrivant ») part dans **un seul champ**, lu à la fois par la boutique et par le livreur.
- Il existe déjà **trois mémoires partielles** : `etat.ts` (l'écran, pour le cerveau), `memoire.ts` (l'écran, pour l'assistant) et les « déjà vus » du résumé (`orchestrator.ts`). La version 2 doit les **remplacer**, pas en ajouter une quatrième. Le nouveau module ne s'appellera donc pas `memoire.ts`.

**Une règle générale manquante (article 4)** : une phrase qui affirme une action (« c'est noté », « transmis », « avec votre consigne », « la carte qui s'affiche ») doit correspondre à une action **réellement faite pendant ce tour**. Sinon, le vérificateur la retire. Elle couvre S1, R5 et R6 d'un coup.

### Étape 1 faite : la protection immédiate (09/10)

Ordre révisé après la seconde relecture de l'autre agent : (1) protection, (2) trajet et consignes de bout en bout (maquette d'abord), (3) réponses fondées sur des preuves, (4) mémoire limitée.

- **Aucune carte qui contredit le trajet** (`tools.ts`, `preparerCourse`) : un départ ET une arrivée qui ne sont pas le client → pas de carte « Commander », deux choix (« Chercher à X, livrer chez moi » / « Venir chez moi, livrer à Y »). Valable pour les anciennes applications, puisque c'est le serveur qui n'envoie pas la carte. « Venir chez moi » avec un départ ailleurs devient « Aller chercher ». `argumentsDeCourse` transmet désormais départ **et** arrivée.
- **Aucune consigne de course dite transmise** : la précision dite pendant une course n'est plus rangée dans la note des repas (`orchestrator.ts`) ; elle va à la carte, qui la déclare `consigne_transmise: false` ; le vérificateur retire toute phrase qui en parle sans dire franchement qu'elle n'est pas transmise, **quelle que soit la tournure** (fait structuré, plus une liste de formules). Filet en plus : « sera transmise », « avec votre consigne ».
- **Mesures** : tests unitaires `carteDeCourse.test.ts` (8) ; 355/355. Examen : S4 et R4 réussis (choix proposés, aucune course annoncée) ; R5 : la phrase « prendra en compte votre consigne » est retirée, il ne lui reste que l'objectif de l'étape 2 (la consigne sur la carte) ; S3, R3, M4, M6, M7, M8, B1, B6, B7, N1, N3, R6 sans régression.
- **Relevé en passant, pour la mémoire (étape 4)** : S2 perd Yantala une fois sur deux en ajoutant le numéro (L2) ; S10 a une fois rangé « et un coca » comme une précision (« j'ajoute un Coca à votre commande », rien d'ajouté). R6 est instable : un échec au 1ᵉʳ passage, réussi ensuite (note « appelez en arrivant » en base) ; il n'était pas une invention, contrairement à ce que j'avais écrit.

### Étape 2 faite : le trajet et la consigne de bout en bout (09/10)

Maquette validée : « Carte de course Tovo », version 6 (https://claude.ai/artifact/KqwQDCtxz4iWUVPBM1csbL).

- **Application** (`courier_form.dart`, réécrite) : Récupérer à → Livrer à, chaque bout « Chez moi », un lieu écrit ou un point sur la carte, avec « Modifier » ; « Pour le livreur » ; Espèces | Nita en pilule ; le prix sur sa ligne ; « Commander un livreur ». Commandée, la carte s'efface (plus de ligne « Livreur commandé »). Les anciennes cartes restent lues.
- **Suivi d'une course** (`order_tracking.dart`, dans le fil) : titre d'état (« Livreur demandé », « [Prénom] part le chercher »…), trois étapes avec icônes au trait ET lieux (« Récupération à Harobanda », « En route vers Banifandou », « Livré »), la consigne rattachée au trajet, Espèces/Nita et le total, « Appeler » et « Suivre sur la carte » (icônes actuelles) l'un sous l'autre, « Annuler la commande » tant qu'aucun livreur n'est parti. Le délai n'est dit qu'une fois, dans la phrase de Tovo : « C'est noté. Un livreur vous appelle dans les **7 minutes**. » Le suivi des repas ne change pas.
- **Livreur** (`driver_home.dart`) : la consigne s'affiche (« Consigne du client : … ») ; l'offre montre le vrai départ d'un trajet A → B.
- **Serveur** : l'application annonce le contrat 2 (`x-tovo-contract`) ; le serveur lui envoie la carte de trajet (`carteDeTrajet`, lieux situés par `reperer`, prix à la distance quand les deux bouts sont situés, forfait sinon — comme la base). Les anciennes applications gardent la protection de l'étape 1. Aucune migration : la base savait déjà tout enregistrer (`parcel_note`, départ et arrivée distincts).
- **Ton** : « Avec plaisir, voici votre course. » ; le vérificateur retire désormais « je m'occupe », « c'est lancé », « je lance » tant qu'aucune commande n'existe.
- **Mesures** : application 200 tests (2 échecs anciens connus, accueil du 01/10), analyse propre ; serveur 359/359. Examen : scénarios **de bout en bout** E1–E3 (contrat 2 : la carte, le toucher, la course **en base**, et le suivi que lit le livreur) réussis ; passage complet 70/76, **aucune régression** sur la référence. Échecs restants : S1, S8, S10, R2 (mémoire, étape 4 ; recherche « Margherita »), S5 (instable, réussi 2 fois ce matin, raté 2 fois l'après-midi, chemin non touché), E2 une fois HTTP 500 passager (réussi aux 5 autres passages, cause non trouvée).

### Les décisions qui vous reviennent

- **G1** : adopter cette version 2 (mémoire limitée, sans données métier) à la place de la version 1. *Recommandation : oui.*
- **G2** : faire l'étape 0 (S4) tout de suite, avant le reste. *Recommandation : oui.*
- **G3** : plus tard, l'application envoie l'identifiant du message visible, pour qu'une liste quittée ne soit plus désignée. *Recommandation : pas maintenant ; d'abord mesurer si la règle « prochaine liste présentée » suffit.*

---

## 7. L'ordre de travail

1. Validation de ce document (E1 à E4).
2. Écriture des scénarios S1–S10 dans l'examen.
3. Un passage, relecture des réponses, tableau des échecs dans ce document.
4. Corrections des seuls échecs mesurés, une à la fois, avec un passage ciblé après chacune.
5. Passage complet de non-régression.
