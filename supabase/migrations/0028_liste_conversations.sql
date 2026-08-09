-- =====================================================================
-- 0028 — Retrouver ses conversations
-- =====================================================================
-- La table existait depuis le début, la colonne `title` aussi, et rien ne
-- l'a jamais remplie ni relue. Chaque lancement ouvrait un fil neuf et le
-- précédent disparaissait — non pas effacé, simplement introuvable.

/*
 * Titre d'une conversation, tiré de son premier message.
 *
 * Aucun appel au modèle : le titrer par une IA coûterait un appel par
 * conversation pour un gain de confort, et les premiers mots du client
 * disent déjà de quoi il s'agit — « je veux un tacos poulet » se reconnaît
 * mieux que « Commande de restauration rapide ».
 */
create or replace function public.titrer_conversation()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_titre text;
begin
  if new.role <> 'user' then
    return new;
  end if;

  -- Seulement si elle n'en a pas encore : le titre vient du PREMIER message
  -- et ne bouge plus, sinon il changerait sous les yeux du client à chaque
  -- phrase qu'il écrit.
  select title into v_titre from conversations where id = new.conversation_id;
  if v_titre is not null then
    return new;
  end if;

  v_titre := trim(regexp_replace(coalesce(new.content, ''), '\s+', ' ', 'g'));

  -- Les interactions produisent des phrases techniques — « Montre-moi le
  -- produit 3f2a… ». Un titre pareil n'apprend rien ; on laisse la
  -- conversation sans nom jusqu'à ce que le client écrive vraiment.
  if v_titre = '' or v_titre ~ '[0-9a-f]{8}-[0-9a-f]{4}' then
    return new;
  end if;

  if length(v_titre) > 60 then
    v_titre := left(v_titre, 57) || '…';
  end if;

  update conversations set title = v_titre where id = new.conversation_id;
  return new;
end $$;

drop trigger if exists trg_titrer_conversation on messages;
create trigger trg_titrer_conversation
  after insert on messages
  for each row execute function titrer_conversation();

/*
 * La date du dernier message fait foi pour l'ordre d'affichage.
 *
 * `created_at` classerait par date d'ouverture : une conversation entamée
 * lundi et poursuivie aujourd'hui se retrouverait tout en bas.
 */
create or replace function public.toucher_conversation()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update conversations set updated_at = now() where id = new.conversation_id;
  return new;
end $$;

drop trigger if exists trg_toucher_conversation on messages;
create trigger trg_toucher_conversation
  after insert on messages
  for each row execute function toucher_conversation();

/*
 * Les conversations du client, la plus récente d'abord.
 *
 * Celles restées vides — ouvertes puis abandonnées — ne sont pas listées :
 * une barre latérale pleine de fils sans contenu ne sert personne.
 */
create or replace function public.my_conversations(p_limite integer default 30)
returns table (
  id         uuid,
  title      text,
  updated_at timestamptz,
  messages   integer
)
language sql stable security definer set search_path = public as $$
  select c.id,
         coalesce(c.title, 'Conversation'),
         c.updated_at,
         count(m.id)::integer
  from conversations c
  join messages m on m.conversation_id = c.id
  where c.user_id = auth.uid()
  group by c.id, c.title, c.updated_at
  order by c.updated_at desc
  limit p_limite
$$;

-- Rattrapage : les conversations déjà en base n'ont ni titre ni date à jour.
update conversations c
   set title = coalesce(c.title, sous.premier),
       updated_at = greatest(c.updated_at, sous.dernier)
  from (
    select m.conversation_id,
           left((array_agg(m.content order by m.created_at)
                 filter (where m.role = 'user'))[1], 60) as premier,
           max(m.created_at) as dernier
    from messages m
    group by m.conversation_id
  ) sous
 where sous.conversation_id = c.id;

notify pgrst, 'reload schema';
