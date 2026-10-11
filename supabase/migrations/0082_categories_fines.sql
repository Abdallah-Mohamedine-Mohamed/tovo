-- 0082 — Les catégories fines des commerces (11/10).
--
-- Demande du fondateur : « un atelier de couture, c'est différent d'un
-- prêt-à-porter ». L'annuaire public (data/commerces-niamey.json) range
-- désormais chaque commerce dans une catégorie fine, rattachée à l'un des
-- 12 types (son icône, son rayon). Les mêmes catégories rejoignent la liste
-- du terrain (0078) : un livreur peut les choisir, l'admin les voit.
-- Rien n'est modifié pour les catégories existantes ; « Téléphones » existe
-- déjà (clé electronique) et n'est pas ajoutée une seconde fois.

insert into public.categories_commerce (slug, libelle, type) values
  ('pret-a-porter', 'Prêt-à-porter', 'vetements'),
  ('couture', 'Atelier de couture', 'vetements'),
  ('chaussures', 'Chaussures', 'vetements'),
  ('tissus', 'Tissus et pagnes', 'vetements'),
  ('bijouterie', 'Bijouterie', 'vetements'),
  ('friperie', 'Friperie', 'vetements'),
  ('informatique', 'Informatique', 'electronique'),
  ('electromenager', 'Électroménager', 'electronique'),
  ('solaire', 'Énergie solaire', 'electronique'),
  ('alimentation', 'Alimentation', 'supermarche'),
  ('grossiste', 'Grossiste', 'supermarche'),
  ('patisserie', 'Pâtisserie', 'boulangerie'),
  ('poissonnerie', 'Poissonnerie', 'boucherie'),
  ('parfumerie', 'Parfumerie', 'beaute'),
  ('materiaux', 'Matériaux de construction', 'quincaillerie'),
  ('librairie', 'Librairie', 'boutique'),
  ('meubles', 'Meubles et décoration', 'boutique'),
  ('gaz', 'Gaz', 'boutique'),
  ('pieces-auto', 'Pièces auto et moto', 'boutique'),
  ('optique', 'Optique', 'boutique'),
  ('centre-commercial', 'Centre commercial', 'boutique'),
  ('fleuriste', 'Fleuriste', 'boutique')
on conflict (slug) do nothing;
