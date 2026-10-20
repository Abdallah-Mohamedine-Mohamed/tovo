-- =====================================================================
-- 0086 — Le TYPE de chaque produit : ce qu'il EST
-- =====================================================================
-- La recherche par mots sait quels mots porte un produit, pas ce qu'il est :
-- pour « chocolat noir », des « Biscuits… Chocolat Noir » valaient le Lindt ;
-- pour « crème pour les mains », un savon « Crème Seife » valait le lait
-- corps & mains (banc-clients, 19/10).
--
-- 1 à 3 types par produit (« biscuit », « chocolat », « savon »), écrits par
-- l'IA (backend/src/services/typeProduit.ts, scripts/recherche/types.ts ;
-- l'indexeur type les produits nouveaux ou renommés). Le serveur fait passer
-- devant les produits dont la phrase du client NOMME le type ; il ne retire
-- rien. Sans cette colonne, l'ordre reste celui d'avant.

alter table public.products add column if not exists type_produit text[];
