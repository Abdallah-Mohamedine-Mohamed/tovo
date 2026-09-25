-- ============================================================================
-- 0064 — Un téléphone qui change de compte garde ses notifications
--
-- Le jeton FCM appartient au TÉLÉPHONE (unique en base). Quand un autre
-- compte se connecte sur le même téléphone, register_push_token doit
-- rattacher le jeton au nouveau compte (on conflict … do update).
--
-- Mais la fonction tournait avec les droits de l'appelant (security
-- invoker), et la RLS de push_tokens ne laisse modifier QUE ses propres
-- lignes : la ligne existante, au nom de l'ancien compte, était intouchable.
-- L'enregistrement échouait — en silence côté app — et le nouveau compte
-- ne recevait plus AUCUNE notification : ni classique, ni suivi Android.
-- Constaté le 25/09 sur un Motorola (Android 14) : deux comptes, zéro jeton.
--
-- La fonction passe en security definer : elle peut reprendre un jeton, mais
-- UNIQUEMENT pour le compte connecté (auth.uid()), jamais pour un autre.
-- ============================================================================

create or replace function public.register_push_token(
  p_token    text,
  p_platform text,
  p_app      text
)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    raise exception 'connexion requise' using errcode = '42501';
  end if;
  if coalesce(length(p_token), 0) = 0 then
    raise exception 'jeton vide' using errcode = '22023';
  end if;

  insert into push_tokens (user_id, token, platform, app)
  values (auth.uid(), p_token, p_platform, p_app)
  on conflict (token) do update
    set user_id      = auth.uid(),
        platform     = excluded.platform,
        app          = excluded.app,
        last_seen_at = now();
end; $$;

revoke all on function public.register_push_token(text, text, text) from public;
grant execute on function public.register_push_token(text, text, text) to authenticated;

notify pgrst, 'reload schema';
