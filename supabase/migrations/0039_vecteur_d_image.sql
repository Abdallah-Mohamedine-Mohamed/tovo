-- =====================================================================
-- 0039 — Vectoriser les produits depuis leurs PHOTOS
-- =====================================================================
-- La recherche par photo passe aujourd'hui par des mots-clés : le modèle
-- regarde l'image, écrit « souris sans fil », et on cherche ces mots. Ça
-- marche, et ça restera le chemin par défaut tant que la bascule n'est pas
-- faite.
--
-- Sa limite est le NOM. Un plat appelé « Menu 3 » ne se trouvera jamais par
-- photo, parce qu'aucun mot ne relie l'image au nom. C'est précisément le
-- cas où un client photographie : quand il ne sait pas comment ça s'appelle.
--
-- POURQUOI LA COMPARAISON VISUELLE ÉCHOUAIT. Les produits n'étaient
-- vectorisés que depuis leur texte — nom, description, étiquettes. Comparer
-- une image à des vecteurs de texte ne sépare rien. Mesuré, photo d'une
-- souris contre les vecteurs de TEXTE du catalogue :
--
--     la souris elle-même         0,469
--     une AUTRE souris       0,31 à 0,40
--     un produit au hasard   0,33 à 0,36
--
-- Une autre souris notait comme un produit sans rapport.
--
-- LA MÊME MESURE, IMAGE CONTRE IMAGE. Photo de « SOURIS SANS FIL HP W10 »
-- comparée aux photos du catalogue :
--
--     Logitech clavier + souris MK290     0,725
--     Ensemble clavier + souris GKM520    0,690
--     Casque P9                           0,661
--     Coca Cola                           0,608
--     Riz au Gras                         0,591
--     Box Poulet Pané                     0,581
--
-- Les accessoires informatiques se détachent des produits sans rapport, et
-- le casque — accessoire tech lui aussi — se place logiquement entre les
-- deux. La séparation existe. C'est ce qui rend le chantier utile.
--
-- PAS D'INDEX VECTORIEL, et c'est délibéré. Aucune colonne de ce projet n'en
-- a, pas même `embedding`. Sur 2 060 lignes, un parcours séquentiel se
-- mesure en millisecondes ; un index HNSW n'apporterait rien de mesurable et
-- ferait dépendre la migration de la version de pgvector installée. Le jour
-- où le catalogue atteindra des dizaines de milliers de produits, les deux
-- colonnes prendront un index ensemble.

alter table products
  add column if not exists image_embedding vector(1536);

comment on column products.image_embedding is
  'Vecteur calculé depuis la PHOTO du produit, distinct de `embedding` qui vient de son texte. Sert la recherche par photo : comparer une image à des vecteurs de texte ne sépare pas un produit semblable d''un produit sans rapport (mesuré : 0,31–0,40 contre 0,33–0,36).';

-- Trace de ce qui a été vectorisé : sans elle, impossible de savoir si un
-- produit sans vecteur a échoué ou n'a jamais été tenté, ni de reprendre
-- un rattrapage interrompu.
alter table products
  add column if not exists image_embedded_at timestamptz;

comment on column products.image_embedded_at is
  'Date du dernier calcul de `image_embedding`. Null = jamais tenté. Permet de reprendre un rattrapage interrompu et de repérer les images devenues inaccessibles.';

notify pgrst, 'reload schema';
