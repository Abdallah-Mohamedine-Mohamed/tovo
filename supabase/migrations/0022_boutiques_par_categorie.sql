-- =====================================================================
-- 0022 — Une catégorie mène à des boutiques, pas à un tas de plats
-- =====================================================================
-- Chez 6ammart, un « module » regroupe des BOUTIQUES : Restaurants en
-- compte 31, Kasuwa, Épicerie et Street-food ont les leurs. La migration a
-- fait de ces modules les catégories racines, et `merchants.category_id`
-- porte déjà ce rattachement.
--
-- Mais l'application traitait une catégorie comme un rayon de produits :
-- toucher « Restaurants » déversait des plats de trente enseignes mélangées.
-- Ce n'est pas ainsi qu'on choisit à manger — on choisit d'abord où, puis
-- quoi. Et surtout, un plat sorti de son restaurant ne veut rien dire :
-- « 1/2 poulet » n'aide personne s'il ne sait pas de quelle cuisine il sort.
--
-- Le parcours devient donc : catégorie → boutiques → produits.

/*
 * Les boutiques d'une catégorie, les plus proches d'abord.
 *
 * L'ouverture est calculée, jamais lue telle quelle : une boutique dont
 * l'interrupteur est levé mais qui n'ouvre qu'à 19 h ne doit pas passer
 * devant celles qui servent maintenant.
 *
 * @param p_lat, p_lng position du client. Sans elle, on classe par note —
 *        toujours mieux que par ordre d'insertion.
 */
create or replace function public.category_merchants(
  p_category_id uuid,
  p_lat         double precision default null,
  p_lng         double precision default null,
  p_limite      integer default 20
)
returns table (
  id            uuid,
  name          text,
  description   text,
  logo_url      text,
  address_hint  text,
  is_open       boolean,
  rating        numeric,
  prep_time_min integer,
  distance_m    integer
)
language sql stable security definer set search_path = public as $$
  with origine as (
    select case
      when p_lat is null or p_lng is null then null
      else st_setsrid(st_point(p_lng, p_lat), 4326)::geography
    end as point
  )
  select
    m.id, m.name, m.description, m.logo_url, m.address_hint,
    public.merchant_open_now(m.id),
    m.rating, m.prep_time_min,
    case when o.point is null then null
         else st_distance(m.location, o.point)::integer end
  from merchants m
  cross join origine o
  where m.is_approved
    and m.category_id = p_category_id
  -- Ouvertes d'abord, puis les plus proches. Montrer une boutique fermée
  -- avant une ouverte fait perdre le client à l'étape suivante, quand il
  -- découvre qu'il ne peut pas commander.
  order by
    public.merchant_open_now(m.id) desc,
    case when o.point is null then m.rating * -1
         else st_distance(m.location, o.point) end,
    m.name
  limit p_limite
$$;

notify pgrst, 'reload schema';
