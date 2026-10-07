-- La position des boutiques Tovo, pour la carte des commerces (07/10) :
-- l'appli place chaque boutique partenaire sur la carte, à côté des
-- commerces hors Tovo. nearby_merchants ne renvoie que la distance.

create or replace function public.merchants_positions(ids uuid[])
returns table (id uuid, lat double precision, lng double precision)
language sql stable security invoker set search_path = public as $$
  select m.id, st_y(m.location::geometry), st_x(m.location::geometry)
  from merchants m
  where m.id = any(ids) and m.is_approved = true and m.location is not null
$$;

grant execute on function public.merchants_positions(uuid[]) to  anon, authenticated, service_role;
