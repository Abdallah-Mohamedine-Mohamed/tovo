-- Banc IA : ce que l'humain peut dire d'une phrase, au-delà d'« un seul sens ».
--
-- Une phrase vraiment ambiguë (« Je vais à livrer ») n'a pas de bonne réponse
-- unique : la bonne réaction de l'assistant est de PROPOSER DES TUILES, pas
-- de deviner. Une phrase incompréhensible (transcription ratée) : demander de
-- reformuler, jamais agir. L'examen le vérifie désormais.
--
--   reponse = 'intention' : un sens unique (attendu) ;
--   reponse = 'tuiles'    : l'assistant doit proposer ces choix (tuiles) ;
--   reponse = 'erronee'   : phrase erronée, l'assistant ne doit pas agir.
--
-- `commentaire` : ce que la phrase veut dire, avec les mots de l'humain. Le
-- même mot qui revient (« réclamation ») signale une intention qui manque.

alter table public.banc_cas
  add column if not exists reponse text not null default 'intention'
    check (reponse in ('intention', 'tuiles', 'erronee')),
  add column if not exists tuiles text[],
  add column if not exists commentaire text check (length(commentaire) <= 500);

-- Le rythme de croisière : 20 phrases toutes les 10 minutes, et l'examen
-- complet une fois par heure seulement (il interroge l'assistant avec la même
-- clé Gemini que les clients : trop souvent, il risquerait de les ralentir).
alter table public.platform_settings
  add column if not exists banc_ia_examen_min integer not null default 60
    check (banc_ia_examen_min between 10 and 1440);

update public.platform_settings
  set banc_ia_intervalle_min = 10, banc_ia_phrases = 20;

-- Un passage a-t-il fait passer l'examen ? (le suivant sait quand refaire)
alter table public.banc_passages
  add column if not exists examine boolean not null default true;
