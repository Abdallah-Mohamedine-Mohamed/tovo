# La constitution de Tovo

**Depuis le 2 octobre 2026.** Le texte de référence est `src/ai/constitution.ts`. Il est lu par **les trois IA** :

- le cerveau qui comprend (`decideur.ts`) ;
- le rédacteur qui écrit (`redacteur.ts`) ;
- l'assistant qui agit (`systemPrompt.ts`).

## Pourquoi une constitution

> « Tuer un chien n'est pas bien » ne dit rien de la vache. « Tuer n'est pas bien » couvre le chien, la vache et la fourmi. — le fondateur, 02/10

Les clients diront des milliers de phrases qu'on n'aura jamais vues. On n'écrit donc pas une règle par phrase signalée : on écrit **les principes dont toutes découlent**.

Deux règles d'écriture :

1. **Un article énonce un principe général.** Il ne cite jamais une boutique, un produit ou une phrase de client.
2. **Un principe que l'on peut vérifier sans IA est garanti par le serveur.** Le demander au modèle ne suffit pas : un modèle peut désobéir. La colonne « Garanti par » ci-dessous dit où.

## Les articles et leur garantie

| # | Article | Garanti par (code) |
|---|---|---|
| 1 | **Le sens, pas les mots.** Un mot seul ne décide jamais de rien. | Le cerveau est le seul interprète. Plus de court-circuit « recherche exacte » avant lui (`chat.ts`), et le filtre à mots ne refuse plus une recherche comprise (`orchestrator.ts`, `rapide`). L'assistant ne reçoit que les outils d'action que le cerveau a choisis (`outilsPermis`). La boutique cherchée est celle que le cerveau a nommée. |
| 2 | **Ce qui est à l'écran donne le sens.** Une réponse courte complète ce qui attend. | `ai/etat.ts`, `etatDuParcours` : le cerveau reçoit l'écran (choix en attente, carte ouverte, liste, produit en cours de choix) et dit s'il y a une commande en cours. Un choix d'agence en attente l'emporte sur les autres boutiques au nom proche (`resolveCatalogueIntent`, `agenceNommee`). |
| 3 | **On n'agit que sur ce qui existe.** | `aiguillage.ts`, `routeDuCerveau` : sans commande en cours, « annuler » et « suivre » deviennent une conversation, jamais la tuile « Annuler ma commande ». |
| 4 | **Rien ne se fait dans le dos du client, et on ne le dit pas.** | Aucune course sans toucher (D1, `chat.ts`). Le vérificateur (`verificateur.ts`, `DIT_GARDE` et `DIT_EN_ROUTE`) retire toute phrase qui dit « noté / gardé / transmis » ou « en route / se rend » si les données ne le confirment pas. |
| 5 | **Rien d'inventé.** | Le vérificateur : montants, durées et noms en gras doivent venir des données. Les mots du client ne confirment aucun chiffre (`ajouterParole`). |
| 6 | **Montrer ce que le client veut, rien d'autre.** Un produit par ce qu'il EST, pas par une option. | La base (migration 0075) : le nom d'abord ; les options seulement s'il n'existe aucun produit de ce nom. Un juge de pertinence séparé (`redacteur.ts`, `jugerPertinence`, température 0) contrôle **tous** les chemins, y compris celui de l'assistant ; un résultat approchant sans rapport est remplacé par les commerces hors Tovo. |
| 7 | **« D'autres », « encore », « plus loin » : ce qu'il n'a pas encore vu.** | Le cerveau signale une demande de `suite`. `orchestrator.ts`, `laSuite`, montre alors la suite du catalogue après ce qui a été affiché, puis les commerces hors Tovo pas encore montrés (tous types, jusqu'à 20 km). |
| 8 | **Ce qui existe ailleurs fait partie de la réponse** (réécrit le 05/10, à la demande du fondateur : « quelqu'un qui cherche merguez s'arrêtera aux résultats de Tovo »). D'abord Tovo, puis, en dessous et sans que le client ait à le demander, les commerces hors Tovo utiles. Le livreur appelle le client, et aucune avance d'argent n'est jamais promise. | `catalogue.ts`, `ailleursEnPlus`, appliqué sous chaque liste de produits, sur la voie rapide comme sur le chemin de l'assistant :<br>• les **spécialistes**, toujours (`specialistesDe` : leur nom porte le produit, comme « Nouhou Merguez » ou « Pizza Kana » ; personne n'a à cartographier les vendeurs réputés) ;<br>• les commerces du bon type, si Tovo a **3 résultats ou moins** ;<br>• rien d'autre si Tovo en a beaucoup, pour ne pas noyer les partenaires.<br>Quand Tovo n'a rien : `horsTovo` et `alternativesHorsTovo`. *Limite : l'écran Explorer de l'application ne montre pas encore ces commerces (maquette à valider).* |
| 9 | **Ce que le client a dit est gardé.** | Le cerveau extrait les `details` : départ, arrivée, téléphone, précision. La carte de course est remplie avec eux (`argumentsDeCourse`). Une précision est rangée dans la note de commande (`notes_commande`, migration 0075, `noteCommande.ts`), visible et modifiable au panier, et part avec la commande. |
| 10 | **Une seule chose à la fois, clairement.** | Le rédacteur : une ou deux phrases ; `sansPromesseVide`. Dans l'application, un seul accès à « la suite » des produits. |
| 11 | **Dans le doute, demander plutôt que deviner.** | `aiguillage.ts`, `routeDuCerveau` : une action coûteuse dont le cerveau n'est pas sûr donne des tuiles de choix. Une décision sans « sûr » est incertaine (`lireDecision`). *Limite : pour une recherche, on devine encore, ce qui ne coûte rien à corriger.* |
| 12 | **La santé n'est pas notre métier.** | Le vérificateur (`CONSEIL_MEDICAL`) retire toute dose, toute posologie et tout médicament conseillé. Un médicament mène vers les pharmacies (de garde la nuit). |
| 13 | **Les données d'un client ne regardent que lui.** | La RLS de la base : chaque client ne lit que ses propres données. Le vérificateur retire tout numéro de téléphone qui ne vient ni des données de Tovo ni du client lui-même (`telephonesDans`, `connaitTelephone`). |
| 14 | **Le respect, dans la langue du client.** | Le vérificateur retire toute phrase qui tutoie (`TUTOIEMENT`). L'examen le vérifie sur **chaque** réponse. *Limite : la qualité de la compréhension du haoussa et du zarma reste celle du modèle.* |
| 15 | **Savoir passer la main.** | Le cerveau classe « parler à une personne » et les échecs répétés en `aide`. La route `aide` transmet réellement à l'équipe (table `signalements`) ; le vérificateur ne laisse dire « transmis » que si c'est fait (article 4). *Limite : « la même demande échoue deux fois » n'est pas encore détecté par le serveur.* |

## Solidité de chaque article (bilan du 02/10)

- **Garantis par le code**, l'IA ne peut pas les violer : 3, 4, 5, 12, 13, 14.
- **En partie garantis** : 2 et 11 (le serveur décrit l'état et propose des tuiles, mais c'est le cerveau qui lit), 6 (un juge IA trie les produits), 9 (le cerveau doit extraire la précision), 15.
- **Seulement demandés** : 1, 7, 8, 10. Ils reposent sur la compréhension du cerveau, mesurée à environ 96 %.

**Test de complétude** : chaque nouvelle erreur doit se rattacher à un article. Si c'est le cas, on renforce sa garantie. Sinon, il manque un principe, et on l'ajoute. Jamais une règle pour la seule phrase fautive.

## Comment on le vérifie

- **`scripts/banc-ia/examen-parcours.ts`** : de vraies conversations envoyées à la route `/chat`. Les vérifications sont objectives : lues en base, ou dans les cartes affichées.
- **Après chaque passage, on relit les réponses une par une.** Le 02/10, un 44/44 cachait six fausses réussites.
- **`npm run banc:ia -- cerveau`** après toute modification de la consigne du cerveau.
- **Ajouter un article** : seulement pour un principe qu'aucun article ne couvre déjà, jamais pour un cas. Et dire dans cette page où le code le garantit.

## Ajouts du 05/10 (soir) : garanties générales, pas des cas

- **Un type de commerce** (« un supermarché pas loin », « tous les supermarchés de Niamey ») : `commercesDuTypeDemande`. D'abord les boutiques Tovo de ce type (les ouvertes en premier), puis l'annuaire. La liste garde en mémoire tout ce qui a déjà été montré : « plus loin » et « tous » montrent la suite (articles 7 et 8).
- **Un champ du cerveau n'est gardé que si le client l'a dit** (article 5) :
  - un numéro doit figurer chiffre pour chiffre dans le message ;
  - un lieu ou une précision doit y figurer par l'un de ses mots ;
  - un type de commerce doit y être nommé (« pizza » n'est pas « restaurant »).
- **Un choix en attente passe avant tout le reste** (article 2) : avant la suite, la précision ou toute recherche.
- **Une boutique nommée est cherchée comme boutique, jamais comme produit au nom proche** (article 1) : « Otakoss » ne doit pas donner des tacos d'autres enseignes.
- **Un produit dont le nom COMMENCE par ce qui est cherché y répond**, et le juge ne peut pas l'écarter (article 6) : « Riz basmati » est du riz, « Savon au lait » est un savon.
- **Le vocabulaire local est construit à partir du catalogue** (`data/vocabulaire-local.json`, `scripts/voix/vocabulaire-local.ts`). Ces plats, et leurs déformations par la transcription (placali, entendu « plat cali »), sont donnés à la transcription et au cerveau. Le produit est toujours écrit en français.

## Consolidation du 05/10 (soir) : 57/57 sur quatre passages, banc à 96 %

- **Les détecteurs lisent les mots du client, jamais la note d'aiguillage** ajoutée pour l'assistant. La note de « designe » cite « le deuxième, celui-là » : elle faisait passer « sans oignons » et « centre aéré » pour des désignations.
- **Tout champ utile du cerveau est obligatoire, vide s'il n'y a rien** (précision, départ, arrivée, téléphone, type de commerce). Facultatifs, ces champs étaient omis une fois sur deux, et même 4 fois sur 4 pour « clés à mon frère à Yantala ».
- **Deux noms désignent le même commerce seulement si leurs mots distinctifs correspondent dans les deux sens** (`memeCommerce`). Les métiers et les quartiers ne comptent pas, et la tolérance est d'une faute pour quatre lettres. « French Tacos », « Nouhou Merguez » et « Pharmacie du Ténéré » ne sont plus cachés au client.
- **Les types de l'annuaire sont vérifiés d'après le nom** (`data/commerces-types.json`, 33 corrections), en respectant les usages de Niamey : « Alimentation » = épicerie, « Dépôt » = pharmacie.
- **Le vérificateur garantit en plus :**
  - « près de vous » seulement sous 2 km ;
  - « plus loin » montre seulement des commerces plus éloignés que ceux déjà vus ;
  - aucun renvoi vers un type de commerce (« les librairies de Niamey ») si aucun commerce n'est montré.
- **Après le tri des produits**, la phrase et les commerces hors Tovo sont recalculés sur ce qui reste.
