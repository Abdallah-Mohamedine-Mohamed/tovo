# Catalogue : recherche, enseignes et navigation

## Comportement attendu

- « Poulet » recherche des produits, même si une boutique porte aussi ce nom. « Chez Poulet » désigne explicitement la boutique.
- « Otakoss » propose uniquement les établissements correspondants. La sélection d'une adresse ouvre sa carte complète, pas une recherche de tacos héritée du tour précédent.
- « Tacos poulet chez Otakoss » conserve la demande de produit pendant le choix de l'établissement. Les résultats restent dans cette enseigne.
- Une enseigne inconnue ne déclenche pas une liste générale d'autres commerces.
- Le chat conserve un aperçu de huit produits avec le total réel et un accès au catalogue. Une recherche exacte n'est pas plafonnée à huit, quarante ou soixante résultats.
- Cliquer une enseigne ou une catégorie ouvre un écran séparé : recherche, catégories, produits paginés, détail et personnalisation. Le retour restaure la discussion sans y ajouter chaque étape de navigation.
- Les produits trouvés grâce à une option sont signalés comme à personnaliser. Leur prix affiché reste le prix de base ; les options déterminent le montant final dans le détail.

## Données et limites

`catalog_products_page` applique les restrictions de boutique et catégorie avant la recherche. La pagination utilise un ordre déterministe, avec l'identifiant pour départager les égalités. Les commerces fermés restent consultables ; les produits indisponibles et commerces non approuvés sont exclus.

La recherche exacte compare les mots normalisés du nom et des options. Plusieurs mots doivent tous correspondre, avec au moins un mot dans le nom. En l'absence de correspondance exacte, la recherche sémantique existante fournit des suggestions : ce lot est explicitement présenté comme tel, pas comme un inventaire exhaustif de tous les synonymes. Le catalogue vide de requête liste tous les produits disponibles de son périmètre.

`GET /catalog/products` accepte `q`, `merchant_id` ou `merchant_ids`, `category_id`, `offset` et `limit`. La réponse contient `items`, `total`, `next_offset` et `match_type`. Une boutique unique ajoute ses informations et toutes ses catégories. Le mobile charge 24 produits par page et rejette les réponses d'une recherche devenue obsolète.

Champs optionnels des composants : `product_carousel.data.browse` transporte les filtres et le total ; `merchant_card.data.pending_query` préserve la recherche pendant le choix d'une adresse ; `total_products` indique la taille de la carte ; `category_grid.data.collapse_in_chat` garde les catégories pour les anciens clients sans les afficher dans le fil sur le nouveau client.

## Déploiement

1. Appliquer les migrations jusqu'à `supabase/migrations/0054_options_obligatoires_produits_configurables.sql` avant de déployer le backend. La migration 0052 rend les commandes en préparation visibles au livreur ; la 0054 bloque les Tacos Bowl sans options obligatoires configurées.
2. Renseigner les véritables groupes et valeurs d'options obligatoires des Tacos Bowl dans le catalogue. Tovo ne les invente pas : ces produits restent non commandables jusque-là.
3. Déployer le backend avec le nouveau code.
4. Installer les APK client et livreur recompilés avec `SUPABASE_URL`, `SUPABASE_ANON_KEY` et `API_BASE_URL`. Ne jamais embarquer la clé service Supabase ni les clés des fournisseurs IA.

Ne pas installer uniquement le nouveau mobile contre un ancien backend : la route du catalogue n'y existe pas encore.

## Vérifications

- Tests backend : PostgreSQL embarqué avec la vraie migration, pagination de plus de 60 produits, catégories, options, enseigne/produit homonymes, variantes de noms, choix de branche, requêtes vocales interprétées et contrat HTTP.
- Tests Flutter : recherche limitée à la boutique, changement de catégorie, pagination et reprise après erreur, réponse réseau obsolète, détail, ajout au panier, retour à la discussion et transmission des filtres.
- `backend/scripts/verifyCatalogueReadOnly.ts` lit uniquement le catalogue public, le copie dans une base en mémoire et vérifie les résultats de la nouvelle fonction. Ce contrôle ne déploie rien et ne remplace pas les tests RLS de Supabase.

Après déploiement, vérifier sur Android : « Poulet » et toutes ses pages ; « Otakoss » puis chaque adresse ; carte complète, boissons puis retour ; « tacos poulet chez Otakoss » ; enseigne absente ; perte/reprise du réseau ; ajout avec options ; abandon puis retour au chat. Réaliser séparément un essai réel audio, les tests locaux simulant son interprétation.
