-- Les commerces relevés SUR LE TERRAIN par les livreurs (07/10) : Tovo doit
-- connaître tous les commerces de Niamey, et Google Maps les connaît mal. Le
-- livreur est déjà devant la devanture : photo, point GPS, nom, type,
-- téléphone. La fiche est « proposée » ; l'admin la valide (ou la refuse)
-- en regardant la photo. Validée, elle rejoint l'annuaire hors Tovo
-- (services/commerces.ts) sans redéploiement.

create table if not exists public.commerces_terrain (
  id           uuid primary key default gen_random_uuid(),
  nom          text not null check (length(nom) between 2 and 120),
  -- Les types de l'annuaire (services/commerces.ts, TypeCommerce).
  type         text not null check (type in ('supermarche', 'marche', 'boucherie', 'boulangerie', 'beaute',
                 'electronique', 'vetements', 'quincaillerie', 'restaurant', 'grillades', 'pharmacie', 'boutique')),
  telephone    text check (telephone ~ '^\d{8}$'),
  -- Le point GPS pris devant la devanture (Niamey et ses abords).
  lat          double precision not null check (lat between 13.2 and 13.8),
  lng          double precision not null check (lng between 1.8 and 2.4),
  -- La précision du GPS au moment du relevé, en mètres.
  precision_m  integer check (precision_m >= 0),
  -- Un repère libre (« face à la mosquée »), si le livreur en donne un.
  repere       text check (length(repere) <= 200),
  -- La photo de la devanture, dans le stockage privé « terrain ».
  photo        text,
  propose_par  uuid not null references public.profiles(id),
  statut       text not null default 'propose' check (statut in ('propose', 'valide', 'refuse')),
  motif_refus  text check (length(motif_refus) <= 200),
  cree_le      timestamptz not null default now(),
  verifie_le   timestamptz,
  verifie_par  uuid references public.profiles(id)
);

create index if not exists commerces_terrain_statut on public.commerces_terrain (statut, cree_le desc);
create index if not exists commerces_terrain_livreur on public.commerces_terrain (propose_par, cree_le desc);

alter table public.commerces_terrain enable row level security;

-- Écrite et lue par le serveur (clé de service) ; l'admin voit tout, le
-- livreur ses propres fiches.
drop policy if exists commerces_terrain_admin on public.commerces_terrain;
create policy commerces_terrain_admin on public.commerces_terrain
  for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists commerces_terrain_livreur on public.commerces_terrain;
create policy commerces_terrain_livreur on public.commerces_terrain
  for select using (propose_par = auth.uid());

-- Les photos des devantures : privées (lues par l'admin via des liens signés).
insert into storage.buckets (id, name, public)
values ('terrain', 'terrain', false)
on conflict (id) do nothing;

-- Le serveur y écrit (clé de service) ; l'admin les regarde pour valider.
drop policy if exists terrain_admin_lit on storage.objects;
create policy terrain_admin_lit on storage.objects
  for select using (bucket_id = 'terrain' and public.is_admin());
