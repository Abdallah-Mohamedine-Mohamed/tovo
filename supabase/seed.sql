-- =====================================================================
-- Seed — catégories et zones de Niamey
-- =====================================================================
-- À exécuter après schema.sql et les migrations. Idempotent.
--
-- ATTENTION : les zones sont des cercles de 1,5 km autour d'un point
-- approximatif du quartier. C'est suffisant pour router le dispatch en
-- développement, PAS pour la production. À remplacer par de vrais
-- polygones tracés avec les livreurs avant le lancement.
-- =====================================================================

insert into categories (name, slug, icon, sort_order) values
  ('Repas',            'repas',            '🍛', 10),
  ('Épicerie',         'epicerie',         '🛒', 20),
  ('Fruits & légumes', 'fruits-legumes',   '🥬', 30),
  ('Boissons',         'boissons',         '🥤', 40),
  ('Boulangerie',      'boulangerie',      '🥖', 50),
  ('Pharmacie',        'pharmacie',        '💊', 60),
  ('Viande & poisson', 'viande-poisson',   '🍖', 70),
  ('Électronique',     'electronique',     '🔌', 80),
  ('Maison',           'maison',           '🏠', 90)
on conflict (slug) do update
  set name = excluded.name,
      icon = excluded.icon,
      sort_order = excluded.sort_order;

-- Sous-catégories de Repas, avec les plats locaux qui font la différence
-- pour la recherche.
insert into categories (parent_id, name, slug, icon, sort_order)
select c.id, v.name, v.slug, v.icon, v.sort_order
from categories c,
  (values
    ('Plats locaux',   'plats-locaux',   '🍲', 11),
    ('Grillades',      'grillades',      '🔥', 12),
    ('Riz & pâtes',    'riz-pates',      '🍚', 13),
    ('Petit-déjeuner', 'petit-dejeuner', '☕', 14),
    ('Fast-food',      'fast-food',      '🍔', 15)
  ) as v(name, slug, icon, sort_order)
where c.slug = 'repas'
on conflict (slug) do nothing;

-- ---------------------------------------------------------------------
-- Zones de livraison — Niamey
-- ---------------------------------------------------------------------

insert into delivery_zones (name, area, base_fee)
select
  v.name,
  st_buffer(st_setsrid(st_point(v.lng, v.lat), 4326)::geography, 1500)::geography(polygon, 4326),
  v.fee
from (values
  ('Plateau',      13.5137, 2.1098, 500),
  ('Yantala',      13.5290, 2.0870, 500),
  ('Koira Kano',   13.5230, 2.1240, 500),
  ('Niamey 2000',  13.4880, 2.1350, 700),
  ('Talladjé',     13.4830, 2.0980, 700),
  ('Aéroport',     13.4796, 2.1836, 1000),
  ('Saga',         13.4700, 2.1600, 1000),
  ('Lazaret',      13.5060, 2.1300, 500)
) as v(name, lat, lng, fee)
where not exists (select 1 from delivery_zones z where z.name = v.name);
