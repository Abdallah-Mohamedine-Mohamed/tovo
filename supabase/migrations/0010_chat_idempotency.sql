-- =====================================================================
-- 0010 — Idempotence des tours de conversation
-- =====================================================================
-- Même problème que pour les commandes, mêmes conséquences.
--
-- Le réseau coupe après l'envoi mais avant la réponse. L'app réessaie. Sans
-- garde, le modèle est rappelé : deuxième facturation, deuxième réponse,
-- et un fil qui contient deux fois la même question.
--
-- L'identifiant est généré par Flutter AVANT l'envoi. Un rejeu porte le
-- même, et retombe donc sur la réponse déjà calculée.
-- =====================================================================

alter table messages
  add column if not exists client_message_id uuid;

-- Unique par conversation, et seulement quand l'identifiant est présent :
-- les messages produits par les routes REST n'en ont pas.
create unique index if not exists idx_messages_idempotence
  on messages(conversation_id, client_message_id)
  where client_message_id is not null;

notify pgrst, 'reload schema';
