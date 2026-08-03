-- =====================================================================
-- 0014 — Jetons de notification, pour tout le monde
-- =====================================================================
-- `driver_profiles` avait un `fcm_token`, pas `profiles`. Autrement dit :
-- on savait notifier un livreur qu'une course l'attendait, mais pas un
-- client que sa commande était prête, ni un boutiquier qu'une commande
-- venait d'arriver.
--
-- Un jeton par APPAREIL et non par personne : quelqu'un peut avoir un
-- téléphone et une tablette, et un livreur peut être client le soir. Une
-- colonne unique aurait écrasé le jeton précédent à chaque connexion sur un
-- autre appareil.
-- =====================================================================

create table if not exists push_tokens (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references profiles(id) on delete cascade,
  token       text not null unique,
  platform    text not null check (platform in ('android', 'ios', 'web')),
  app         text not null check (app in ('client', 'driver', 'merchant')),
  last_seen_at timestamptz not null default now(),
  created_at  timestamptz not null default now()
);

create index if not exists idx_push_tokens_user on push_tokens(user_id, app);

alter table push_tokens enable row level security;

drop policy if exists push_tokens_owner on push_tokens;
create policy push_tokens_owner on push_tokens for all
  using (user_id = auth.uid() or is_admin())
  with check (user_id = auth.uid());

-- Enregistre ou rafraîchit le jeton de l'appareil courant.
--
-- Un jeton FCM peut migrer d'un compte à un autre : deux personnes qui se
-- passent un téléphone, ou une réinstallation. On le réattribue à
-- l'utilisateur courant plutôt que d'échouer sur la contrainte d'unicité —
-- sinon le nouveau propriétaire ne recevrait jamais rien.
create or replace function public.register_push_token(
  p_token    text,
  p_platform text,
  p_app      text
)
returns void language plpgsql security invoker set search_path = public as $$
begin
  insert into push_tokens (user_id, token, platform, app)
  values (auth.uid(), p_token, p_platform, p_app)
  on conflict (token) do update
    set user_id = auth.uid(),
        platform = excluded.platform,
        app = excluded.app,
        last_seen_at = now();
end; $$;

-- Jetons d'un utilisateur pour une app donnée. SECURITY DEFINER : appelée
-- par le backend avec la service_role au moment de notifier.
create or replace function public.tokens_for(p_user_id uuid, p_app text)
returns table (token text)
language sql stable security definer set search_path = public as $$
  select t.token from push_tokens t
  where t.user_id = p_user_id
    and t.app = p_app
    -- Un jeton inutilisé depuis deux mois est presque sûrement mort ;
    -- l'envoi échouerait et polluerait les journaux.
    and t.last_seen_at > now() - interval '60 days'
$$;

-- Purge des jetons morts. FCM signale les jetons invalides à l'envoi, le
-- backend les supprime ; ceci rattrape ceux qu'on n'a jamais tenté.
create or replace function public.purge_push_tokens()
returns void language sql security definer set search_path = public as $$
  delete from push_tokens where last_seen_at < now() - interval '90 days';
$$;

notify pgrst, 'reload schema';
