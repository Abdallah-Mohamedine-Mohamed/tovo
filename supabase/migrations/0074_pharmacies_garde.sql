-- Les pharmacies de garde (01/10). Pas d'API publique : l'équipe saisit
-- chaque semaine la liste officielle (Ministère de la Santé, diffusée par
-- Lahiyata) depuis l'admin, à partir de l'image de la semaine. La garde court
-- du samedi 8 h au samedi suivant 8 h. Le serveur montre au client les plus
-- proches de sa position (services/pharmaciesGarde.ts).

create table if not exists public.pharmacies_garde (
  id            uuid primary key default gen_random_uuid(),
  debut         timestamptz not null,
  fin           timestamptz not null check (fin > debut),
  commune       text not null check (length(commune) between 1 and 10),
  nom           text not null check (length(nom) between 1 and 120),
  localisation  text not null default '' check (length(localisation) <= 200),
  -- 8 chiffres, sans indicatif.
  telephone     text not null check (telephone ~ '^\d{8}$'),
  lat           double precision,
  lng           double precision,
  -- Comment la position a été trouvée : Google (le plus sûr), la pharmacie dans
  -- nos données, un repère, le quartier, ou collée à la main.
  precision     text check (precision in ('google', 'pharmacie', 'repere', 'quartier', 'manuelle')),
  cree_le       timestamptz not null default now()
);

create index if not exists pharmacies_garde_periode on public.pharmacies_garde (debut, fin);

alter table public.pharmacies_garde enable row level security;

-- Écrite par le serveur (publication depuis l'admin) ; l'admin la lit aussi.
drop policy if exists pharmacies_garde_admin on public.pharmacies_garde;
create policy pharmacies_garde_admin on public.pharmacies_garde
  for all using (public.is_admin()) with check (public.is_admin());


-- La garde du samedi 26/09 8 h au samedi 03/10 8 h (liste Lahiyata / MS-HP).
-- Positions : Google d'abord (gardées moins de 30 jours, comme Google le
-- permet), sinon nos données (services/pharmaciesGarde.ts).
delete from public.pharmacies_garde where debut = '2026-09-26T08:00:00+01:00';
insert into public.pharmacies_garde (debut, fin, commune, nom, localisation, telephone, lat, lng, precision) values
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'I', 'Avenir', 'Plateau, Avenue Maurice de Lens', '20753869', 13.527688600000001, 2.0964991, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'I', 'Bobiel', 'Pas loin de la Boulangerie Bobiel', '80059789', 13.5517348, 2.0972407, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'I', 'CEG 25 Riyad', 'Face CEG 25, alignement Alimentation Riyad', '80686811', 13.5502843, 2.0758883, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'I', 'Centre Aéré BCEAO', 'Bobiel, près du Centre Aéré BCEAO', '80066158', 13.5647716, 2.0873188000000003, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'I', 'Choukr-Allah', 'Latérite Fenifoot face Station Tamesna', '90020480', 13.574247999999999, 2.0939532, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'I', 'Cité Chinoise', 'Non loin de l''OPVN', '80075377', 13.5580954, 2.1110139, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'I', 'Francophonie', 'À côté Grande Porte Village Francophonie', '20322030', 13.568353, 2.1102846, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'I', 'Issa-Beri', 'Plateau, en face de CEG5 Franco-Arabe', '20742898', 13.5218894, 2.0990307, 'quartier'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'I', 'Marhaba', 'Koubia, entre Commissariat et Station Morey', '77304270', 13.563849, 2.0372232, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'I', 'Moaga Losso', 'Lossou Goungou, près CEG Lossogoungou', '92198096', 13.537874266666668, 2.044465366666667, 'quartier'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'I', 'Recasement', '1ère latérite en face Station Oriba', '20350388', 13.5407418, 2.0869588, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'I', 'Ridwane', 'Yantala, Habou Tagui Yantala', '88538341', 13.536613099999999, 2.0810565999999997, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'I', 'Rond Point', 'Plateau, à côté de Nigelec Siège', '20734283', 13.5175374, 2.1036205, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'I', 'Route Oualam', 'Koira Tegui, face grande porte Gendarmerie', '88884888', 13.584603999999999, 2.1090092, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'I', 'Sabara Bangou', 'Cité SATU, non loin de GMA', '98021792', 13.572700399999999, 2.0629691, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'I', 'Salbaz', 'Tchangarey, près de Halirou Bakoye', '92703000', 13.5902152, 2.0846799, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'I', 'Saye', 'Goudel, Zone des Ambassades', '20352264', 13.5382117, 2.0989147999999997, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'I', 'Sira', 'Koira Kano Nord, en face Station Noma', '82183214', 13.5470768, 2.0645577, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'II', '3 Août', 'Plateau, près de l''Échangeur Mali Béro', '20351818', 13.534402799999999, 2.1030671, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'II', 'Arewa', 'Boukoki, pas loin de la Station Olibya', '20733505', 13.5316743, 2.1232109, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'II', 'Deyzeibon', 'À côté du CSI Deyzeibon', '20736790', 13.5227428, 2.1120305, 'pharmacie'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'II', 'Kalley 100m', 'Banizoumbou, Station Bazacor voie 100 m', '96242504', 13.5177885, 2.1189734, 'quartier'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'II', 'Lazaret', 'Non loin de Bab Salam', '90583776', 13.5510956, 2.1255527, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'II', 'Tourakou', 'À côté de Zeyna Transfert', '80085451', 13.539879599999999, 2.1103765, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'III', 'Arènes', 'Poudrière, près de la Maternité Poudrière', '93226464', 13.515582199999999, 2.1382688, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'III', 'Carrefour 6ème', 'Nouveau Marché, près Rond-Point 6ème', '20741818', 13.5030054, 2.1297381, 'pharmacie'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'III', 'Cité BCEAO', 'Banifandou, Marché Albarka', '21887968', 13.5333682, 2.1393925, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'III', 'Dom', 'À côté Station Total Kalley Nord', '80076691', 13.5158806, 2.1234211, 'repere'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'III', 'El Nasr', 'Kombo, dans Immeuble El Nasr', '89117400', 13.510391, 2.1109165, 'pharmacie'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'III', 'Lawanerame', 'Boukoki, Marie Garage près Nita Transfert', '98489220', 13.5353043, 2.1258662999999998, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'III', 'Temple', 'Kalley Sud, à côté de la TV Dounia', '20736182', 13.510842499999999, 2.1231926999999997, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'III', 'Zana', 'Banifandou, près Rond-Point Salou Djibo', '91145837', 13.537573499999999, 2.1460798999999997, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'IV', 'Aéroport', 'Aéroport, derrière CSI Aéroport', '90194535', 13.4678001, 2.181996, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'IV', 'Dendi', 'Bassora, Bassora Château Korey', '89148882', 13.5095054, 2.1730685, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'IV', 'Escadrille', 'Talladjé, face à la Nigelec Talladjé', '92807623', 13.4925745, 2.1536193, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'IV', 'Niamey 2000', 'À côté Boulangerie Pâtisserie Youssourra', '91249798', 13.5288375, 2.1815260999999997, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'IV', 'Poste', 'Niamey 2000, Rond-point Station Oil Lybia (ex Telwa)', '80067943', 13.524384, 2.1833296, 'quartier'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'IV', 'Tadjeje', 'Aéroport, à côté Alimentation Route Tchanga', '80075393', 13.463854099999999, 2.1936074, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'V', 'Galabi', 'Saguia, après le 2e cassis vers Say', '96484545', 13.4632031, 2.108994, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'V', 'Kirkissoye', 'Non loin du Rond-Point Gnalga', '20315140', 13.4805972, 2.1118235, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'V', 'Lamorde', 'Derrière l''ex CHU Lamordé', '92198095', 13.5031629, 2.0799414, 'google'),
  ('2026-09-26T08:00:00+01:00', '2026-10-03T08:00:00+01:00', 'V', 'Rive Droite', 'Route Say, face à la Station Bazagor', '95326404', 13.4884218, 2.0981499, 'google');
