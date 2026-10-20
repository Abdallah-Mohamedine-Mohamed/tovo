/**
 * Le jeu d'essai tiré de l'ANCIENNE application Tovo : de vrais messages de
 * clients au support, aux boutiques et aux livreurs (export de la base
 * `tovodb`, novembre 2024 – octobre 2026, 1 020 messages de clients ; lus et
 * choisis le 20/10/2026).
 *
 * Ces clients écrivaient à des HUMAINS, souvent au milieu d'une commande :
 * c'est exactement ce que le cerveau recevra. Le texte est gardé tel quel —
 * fautes, abréviations, mélange de langues — sauf l'ANONYMISATION :
 * numéros de téléphone remplacés par des numéros fictifs (90 11 22 33),
 * noms de personnes retirés, liens supprimés. Les exports bruts ne sont
 * jamais versés au dépôt.
 *
 * Étiquetés à la main avec les intentions de jev.ts. `aussi` : une autre
 * lecture juste. `contexte` : la phrase suppose une commande en cours
 * (`avant` = ce que le client venait de voir).
 *
 *   npm run banc:ia -- actuel --ancienne
 */
import type { Cas } from './jeu.js';
import type { Intention } from '../jev.js';

const a = (texte: string, attendu: Intention, extra: Partial<Cas> = {}): Cas =>
  ({ texte, attendu, source: 'reel', ...extra });
const enCours = { contexte: true, avant: 'Votre commande est en préparation.' };

export const JEU_ANCIENNE: Cas[] = [
  // ── Où en est ma commande (121 conversations) ───────────────────────
  a('Hello what is the delay of order', 'suivi'),
  a("J'attends toujours", 'suivi', enCours),
  a('Bonsoir J’aimerai connaître le statut de ma commande svp', 'suivi'),
  a('Ma commande est en route', 'suivi'),
  a('Il reste combien de temps pour la commande s’il vous plaît', 'suivi'),
  a('Votre livreur est super lent !!! Ça fait Deux heures que j’attends', 'suivi', { aussi: ['aide'] }),
  a('Bonsoir, j ai lancer une comande ca fais plus de 15 min que c est en attente povez vous me dire c est quoi le problem?', 'suivi'),
  a('Bonjour, ma course semble bloquée et le livreur ne décroche pas mes appels', 'suivi', { aussi: ['aide'] }),
  a('Bonsoir pourquoi ma commande est en attente s\'il vous plaît ?', 'suivi'),
  a('Bsr,j’ai passé une livraison depuis 30mn mais jusque là je n’ai reçu aucun appel,merci .', 'suivi'),
  a('Vous êtes en route ?', 'suivi', enCours),
  a('Ça en ai où pour la livraison ?', 'suivi'),
  a('Bonjour... J\'ai lancé une commande et jusqu\'à présent aucun livré n\'a été assigné', 'suivi'),
  a('Je peut savoir l etat de ma comande?', 'suivi'),
  a('C est comment pour ma comande', 'suivi'),
  a('Tu es ou', 'suivi', enCours),
  a('Salut c comment pour ma commande ??', 'suivi'),
  a('J aurais ma commande dans combien de temps ?', 'suivi'),
  a('Ça prend du temps, c\'est toujours pas livré', 'suivi'),
  a('Ça fait déjà 1h et j\'attends toujours le livreur', 'suivi'),
  a('Bonsoir la commande est deja prêt ou il faut patienter ? Ici je vois que c’est en traitement', 'suivi'),
  a('Bonsoir Tovo, ma commande est en statut préparation depuis plus d’une heure et le livreur assignée n’est pas joignable. Pouvez vous confirmer que la commande progresse merci.', 'suivi'),
  a('Le service deviens lent', 'suivi', { aussi: ['aide'] }),
  a('Ce n’est toujours pas prêt ?', 'suivi', enCours),
  a('Bonsoir vous êtes encore loin ?', 'suivi', enCours),
  a('Toujours pas prêt ?', 'suivi', enCours),
  a('Ça fais presque 1h30 qu’on attend pour deux shawarmas, bon…', 'suivi'),
  a('Ma commande tarde, es ce qu\'il y\'a un problème ? Bonsoir', 'suivi'),
  a('Salut ça arrive quand ?', 'suivi'),
  a('Pourquoi c’est long ?', 'suivi'),
  a('Svp que sa dépasse pas 30mnts maximum je pas loin de o tacos', 'suivi', { aussi: ['aide'] }),
  a('Salut pouvez-vous accélérer s’il vous plaît j’ai un match à jouer', 'suivi', { aussi: ['aide'] }),
  a('J’ai l’impression qu’il n’y a pas de livreur disponible et je voulais me renseigner sachant que j’ai une heure de pause a ne pas dépasser', 'suivi'),
  a('Bonjour la commande prend combien de temps ?', 'suivi'),
  a('Bonsoir .j’ai lancé la commande depuis 12h .. et jusque la je suis en attente.', 'suivi'),
  a('Ya un problème ça fait plus d\'une heure que j\'ai lancé une commande', 'suivi', { aussi: ['aide'] }),
  a('Bonsoir comment allez-vous ?? La livraison va t’elle durer', 'suivi'),

  // ── Ma commande est-elle confirmée ? (50) ───────────────────────────
  a('Je viens de commander j sais as si c lancer ou pas ça marche comment svp', 'suivi'),
  a('Helllo c ma première fois dites moi la commande a été prise en compte ?', 'suivi'),
  a('Bonsoir J\'ai passé une commande depuis plus d\'une heure , est ce qu\'elle a été prise en compte ??', 'suivi'),
  a('Bonsoir est ce que ma commande a été pris en charge', 'suivi'),
  a('C\'est comment, ma commande n\'est toujours pas attribué', 'suivi'),
  a('Ma commande n\'a pas été comfirmer jusqu\'à présent', 'suivi'),
  a('C\'est cmt j\'ai pas reçu d\'appel pour confirmer', 'suivi'),
  a('Bonsoir ma commande n’est toujours pas confirmé', 'suivi'),
  a('Bonjour, je viens de faire une commande. Est-elle prise en charge ?', 'suivi'),
  a('Bonjour c\'est ma première fois d’utiliser. Le livreur m’appelèrent t-il ?', 'suivi', { aussi: ['question'] }),
  a('Coucou , prenez ma commande sivouplaitmerci.', 'suivi', { aussi: ['panier'] }),
  a('Je confirme la commande', 'panier', { aussi: ['suivi'], note: 'ancienne app : le client confirmait au support ce qu’il venait de commander' }),

  // ── Annuler (46) ────────────────────────────────────────────────────
  a('Comment annuler un commande ?', 'annuler', { aussi: ['question'] }),
  a('Salut, je voudrais annuler la commande Car l’article n’est pas encore prêt Merci', 'annuler'),
  a('Je voudrais annuler ma commande', 'annuler'),
  a('Annuler la commande', 'annuler'),
  a('J\'annule la commande svp C\'est mo fils qui à commander', 'annuler'),
  a('Bonsoir j\'aimerais annuler ma commande J\'ai fais une erreur j\'aimerais l\'annuler', 'annuler'),
  a('Bon bah...annulé cette commande', 'annuler'),
  a('Je veux plus ce que j’ai commandé,trop de retard', 'annuler'),
  a('Janul', 'annuler'),
  a('C’est bon j’annule la commande', 'annuler'),
  a('J\'annule C\'est trop lent', 'annuler'),
  a('Annuler la commande elle prend trop de temps', 'annuler'),
  a('Je veux plus du tacos c déjà bon je vais me rendre sur place', 'annuler'),
  a('Je voudrais anneler la commande. Merci', 'annuler'),
  a('Bonjour, je n’arrive pas à annuler la commande, les nems ne sont pas encore disponibles', 'annuler', { aussi: ['aide'] }),
  a('C\'est possible d\'annuler la commande si le livreur ne l\'a pas encore pris ? J\'ai un conte temps', 'annuler', { aussi: ['question'] }),
  a('Salam, Puis je annuler pour commander au centre aéré qui plus proche de chez moi? Javais pas remarqué que c\'est koubia .', 'annuler', { aussi: ['aide'] }),
  a('I would cancel the commande please', 'annuler'),

  // ── Numéro injoignable, rappelez-moi (50) ───────────────────────────
  a('Contacter moi sur le 90 11 22 33', 'aide', { aussi: ['suivi'], note: 'numéro de secours' }),
  a('Mon numéro affiché sur mon compte Tovo n’est pas disponible. Merci de dire au livreur de m’appeler au 90 11 22 33.', 'aide', { aussi: ['suivi'] }),
  a('Bonsoir j ai commandé deux pizza de royal grill entre temps mon phone s est déchargé svp me contacter au 90 11 22 33', 'aide', { aussi: ['suivi'] }),
  a('Vous pouvez m\'appeler s\'il vous plaît je n\'ai plus de crédit', 'aide', { aussi: ['suivi'] }),
  a('J op credit appelez moi', 'aide', { aussi: ['suivi'] }),
  a('Bonsoir , votre numéro ne passe pas', 'aide', { aussi: ['suivi'], ...enCours }),
  a('Bonsoir vous avez annulé ma commande ma commande pourquoi', 'aide', { aussi: ['suivi'] }),
  a('Bonsoir, je viens de voir que ma commande a été annulée. Puis-je en connaître la raison svp?', 'aide', { aussi: ['suivi'] }),

  // ── Paiement (40) ───────────────────────────────────────────────────
  a('Avec quel numéro puis-je vous faire parvenir les sous via MyNITA ?', 'question'),
  a('Puis-je payé par my Nita mes commandes de nourriture', 'question'),
  a('Est ce possible de payer par MyNita ?', 'question'),
  a('Est-ce qu’on peut payer par Amana ta', 'question'),
  a('Vous pouvez mettre une rubrique pour qu\'on puisse payer avec carte Visa ou MasterCard ?', 'question'),
  a('Pourquoi on peut pas payé par MyNITA ?', 'question', { aussi: ['aide'] }),
  a('On peut payer avec wave s’il vous plaît ?', 'question'),
  a('Quel sont les mode de paiements disponibles ?', 'question'),
  a('J’aimerais payer par mynita mais j’y arrive pas', 'aide', { aussi: ['question'] }),
  a('Comment se passe les commandes c forcément par NITA ?', 'question'),
  a('Est ce que le livreur accepte les paiements par m’y nita ?', 'question'),
  a('Bonsoir, J’ai 10.000 pour régler la commande.', 'aide', { note: 'monnaie à prévoir', ...enCours }),
  a('Ne serait ce pas mieux après la prière ? Et aussi merci de venir avec de la monnaie. J\'ai un billet de 10.000', 'aide', enCours),

  // ── Frais, prix, promo (34) ─────────────────────────────────────────
  a('Bonjour, pouvez vous s\'il vous plaît m\'expliquer ce qu\'est les frais de service appliqués de 250 CFa ?', 'question'),
  a('Je voudrais savoir si c’est à la livraison ont paye ?', 'question'),
  a('Au faite je voudrai savoir si pour prendre un coursier c\'est gratuit ???', 'question'),
  a('Cc l frais d l livraison c est payant ? Si oui l prix svp', 'question'),
  a('La première livraison est gratuite ?c\'est ça?', 'question'),
  a('Bonjour, J’aimerai connaître votre tarif pour une livraison de cité Fayçal à ElNasser. Merci.', 'question'),
  a('Bonjour combien coûte une course de livraison', 'question'),
  a('Bonsoir! Où est-ce qu’on inscrit le code promo?', 'question'),
  a('Pour le mardi TACOS est ce que c\'est pour chaque commande que j\'ai une réduction de 1000f', 'question'),
  a('Bonsoir, pouvoir votre code promo ne marche plus?', 'aide', { aussi: ['question'] }),
  a('Comment avoir des coupons', 'question'),
  a('Bonjour j\'ai une question pour vous. Quand je regarde certains plats, je vois déjà un prix affiché et après il y a des options requises. Je voudrais savoir le prix affiché concerne le plat uniquement et après il faut payer pour les options requises ? Merci beaucoup', 'question'),
  a('Quand t’on commande de la nourriture il faut encore payer le livreur à par le prix du produit', 'question'),
  a('C vrai que le cheese burger est à 10f', 'question', { aussi: ['recherche'] }),

  // ── Commande fausse, incomplète, « livrée » sans l'être (35) ────────
  a('Bonsoir je suis désolée mais le service de livraison est vraiment lent et pas du tout efficace, ça fait plus d’une heure de temps que j’ai passé commande et je ne l’ai toujours pas reçu , pourtant je vois marqué commande livrée', 'aide', { aussi: ['suivi'] }),
  a('Bonsoir, le livreur a pris 1000 franc comme frais de livraison alors que c\'est sensé être gratuit non ???', 'aide'),
  a('On dit commande livrée pourtant je n\'ai rien reçu, vous pouvez m\'expliquer ??', 'aide', { aussi: ['suivi'] }),
  a('Bonsoir, j’ai commandé 2 plat de queue de bœuf mais j’ai reçu 2 plats de viande de bœuf.', 'aide'),
  a('Je ne suis pas fiers pcq le gars a casser la Commande et je ne l’ai pas eu', 'aide'),
  a('Je viens de commander 2 tacos viande L avec supplément poulet. Mais malheureusement vous n\'avez pas ajouter le supplément poulet dedans', 'aide'),
  a('Je suis toujours en attente de la livraison mais vous affirmez avoir livré', 'aide', { aussi: ['suivi'] }),
  a('Le livreur m\'a soutiré 3,5k au lieu de 3', 'aide'),
  a('Merci de bien vouloir rectifier vos prix avec vos prestataires. Ma commande vient d’arriver et le livreur me tend un reçu de 6500 au lieu de 4250', 'aide'),
  a('I’m being charged more than what I purchased', 'aide'),
  a('Bonsoir moi je suis pas satisfait de vous c\'est la première fois que je fais une commande et on la livre incomplète.', 'aide'),
  a('Bonsoir j’ai passé commande au près de vous mais ce qu’on m’a livré est très différent de ce que j’ai reçu', 'aide'),
  a('Commande livrée mais pas satisfait. D\'abord l\'emballage n\'était pas à la hauteur et le yaourt est versé', 'aide'),
  a('Ma commande a été livrée et moi j’ai pas reçu la commande, j’ai même pas vu le livreur venir', 'aide', { aussi: ['suivi'] }),
  a('Bonjour. La commande est effectivement arrivée mais ce n’était absolument pas ce que j’avais commandé.', 'aide'),
  a('J\'ai reçu une notification qui dit que j\'ai été livrée alors que le livreur ne m\'a même pas encore contacté. J\'ai pas compris', 'aide', { aussi: ['suivi'] }),
  a('Bonjour, j’ai passé une commande à Otakoss mais je suis tombée sur un livreur malpoli. Merci de le changer si possible.', 'aide'),
  a('Bonjour, trouvez moi un autre livreur', 'aide', { aussi: ['suivi'] }),

  // ── Modifier, ajouter, préciser une commande passée (35) ────────────
  a('Bonsoir pour mon toukoudi je veux le frais svp, je ne savais pas comment préciser ça via l’application en passant la commande', 'aide'),
  a('Svp j aimerait rajouter un tacos à la commande comment faire ?', 'aide'),
  a('Merci de dire au restaurant d’ajouter un supplément de sauce Dja.', 'aide'),
  a('Pour le boba je veux les perles noires', 'aide'),
  a('Svp informer les à propos de milkshake de ne pas mettre trop de glaçon', 'aide'),
  a('Bonsoir, je voudrais modifier ma comande. Un plat de frite a la plase des crepes', 'aide'),
  a('Par rapport à la commande que je viens de passer je voulais savoir si c’était possible de me rajouter un milkshake Fraise taille M sans supplément de chez boba dans la commande svp', 'aide'),
  a('Y’a erreur je veux un seul tacos L', 'aide'),
  a('Svp que sa prend pas du temps que le tacos soit pimentée', 'aide'),
  a('Ajoutez une bouteille d’eau avec svp', 'aide'),
  a('Je voulais ajouter un milk-shake chocolat oreo petite taille et ça refusé mais je le veux quand même faut ajouter ça à la commande', 'aide'),
  a('Bonjour ,svp il faut ajouter un peu de piment vert dans la commande et ça va prendre combien de minutes ??', 'aide', { aussi: ['suivi'] }),
  a('Bonsoir concernant la commande de riz cantonnais, j\'aimerais la modifier, pour prendre un plat de riz cantonnais simple plus un plat de poulet panné', 'aide'),
  a('Bonsoir peut ont rajoute un tacos Sur la commande', 'aide'),
  a('Svp je veux aussi un boba oreo xl avec boule', 'aide', { aussi: ['recherche'], ...enCours }),
  a('Si il n’ont pas fini ketchups on met pas pardonne moi', 'aide', enCours),

  // ── Adresse et repères pendant la livraison (53) ────────────────────
  a('Bonsoir dite au livreur de s’arrêter au niveau du pharmacie de camps', 'aide', { aussi: ['suivi'], ...enCours }),
  a('Dites au livreur de venir à côté de la mosquée de Rhodésie qu’il m’attend là-bas sur le goudron et il m’appelle', 'aide', { aussi: ['suivi'], ...enCours }),
  a('Il s’emblerai y avoir une erreur sur la localisation, il s’agit de la où je me trouvais la dernière fois, veuillez téléphoner afin d’obtenir ma localisation actuelle', 'aide', enCours),
  a('Coucou erreur sur le lieu de livraison Je suis à Ryad', 'aide', enCours),
  a('Bonsoir je crois je me suis trompée sur la localisation Je suis à recasement 3e laterite', 'aide', enCours),
  a('Bonsoir, svp informez le livreur que j’ai quitté darsalam, je rentre à Aeroport donc la livraison ça sera à Aeroport derrière l’hôtel Fazao au lieu de darsalam', 'aide', enCours),
  a('Bonsoir ,merci de dire au livreur de me livrer au niveau du pavé Mamar , le réseau est mauvais', 'aide', enCours),
  a('Hello Je suis à harobanda,non loin de la pharmacie kirkissoye', 'aide', { aussi: ['suivi'], ...enCours }),

  // ── Livreur à la demande, colis (27) ────────────────────────────────
  a('Bonjour j’aimerais commander un livreur', 'livreur'),
  a('Bonsoir j’ai besoin d’un livreur', 'livreur'),
  a('Bonjour Tovo Comment faire pour profiter de la livraison gratuite j’ai un colis à récupérer 😅?', 'colis', { aussi: ['question'] }),
  a('Comment être livrer dans une boutique qui n’est pas sur l’application svp', 'question', { aussi: ['livreur'] }),
  a('J\'ai colis à prendre avec moi à livrer vers hôpital référence', 'colis'),
  a('J ai des cadeaux que j aimerai qu on livre à une personne si possible j aimerai avoir un livreur maina tout de suite', 'colis', { aussi: ['livreur'] }),
  a('J\'ai besoin de livreur c\'est urgent', 'livreur'),
  a('J\'ai un colis un carton à récupérer Niamey école Niger Nigeria pour livré à cité airtel école mayaki', 'colis'),
  a('Bonjour je voudrais utiliser les services de livraison avec les tricycles, mais je n’arrive pas à lancer la commande', 'colis', { aussi: ['question', 'livreur'] }),
  a('Bonjour, livraison de la commande vers 13h45.grand marche à côté de Adoua', 'colis', { aussi: ['aide'] }),
  a('Bonsoir j’ai besoin d’une livraison de cité Fayçal a Francophonie', 'colis', { aussi: ['livreur'] }),
  a('Bonjour Tovo Faite vous les livraisons de canapés', 'question', { aussi: ['colis'] }),
  a('Comment appelée un taxi?', 'question'),
  a('Vous ne faites plus les livraisons de bouteilles de gaz ?', 'recherche', { aussi: ['question'] }),

  // ── Produits et boutiques (hors catalogue souvent) ──────────────────
  a('Avez-vous de la charcuterie comme la viande hachée?', 'recherche'),
  a('Hello est-ce que vous livrez du Doukounou?', 'recherche'),
  a('Bonjour je voulais commander du papier cuisson mais je le trouve pas dans les listes ?', 'recherche'),
  a('Est-ce que sonda sonda est parmi vos partenaires ?', 'boutique'),
  a('Je n\'arrive plus à retrouver goût unique, lahia ?', 'boutique'),
  a('Bonjour comment allez-vous pourrais-je avoir le menu du jour du restaurant Gondwana svp', 'boutique'),
  a('Je voudrai faire livrer du kakan dadi a deux personnes', 'recherche'),
  a('Est ce que je peut avoir un plat disponible à peu pres 20 minutes de escadrille ? Souroundou ou bien doukounou', 'recherche'),
  a('Vous livrez des articles du parck Assalam de koira kano??', 'boutique', { aussi: ['question'] }),
  a('Votre attiéké ya alloco dedans ?', 'question', { aussi: ['recherche'], note: 'question sur un plat de la boutique' }),
  a('Salut, vous avez des boissons?', 'recherche'),
  a('Bien, combien coûte la chaise VIP en rouge?', 'recherche'),
  a('J’aimerai qu’on me paie des frites et merguez', 'recherche'),
  a('Bonjour j’aimerais un plat de sauce graine avec poisson fumé accompagné de placali , et un plat de mafe accompagné de riz svp', 'recherche'),
  a('Bonsoir comment allez-vous ? Je veux commander 1 sandwich merguez.1 plat de frites 1 plat d Aloco. Et 1 boisson citron gingembre', 'recherche'),
  a('Coucou j’espère que vous allez bien? Vous pouvez envoyer un livreur au niveau de O’tacoss nouveau marché pleaseee j’ai trop la dalle wallah', 'livreur', { aussi: ['boutique'] }),

  // ── Questions sur Tovo ──────────────────────────────────────────────
  a('Comment puis-je procéder pour prendre un ticket de voyage stm?', 'question', { aussi: ['colis'] }),
  a('Oui j\'aimerais bien connaître les attributs de cette belle initiative. Moi j\'ai mon petit business à Niamey, est-ce que je peux exposer mes marchandise et les vendre ici. Et comment ça se passe?', 'question'),
  a('Comment mettre mon article en vente sur Tovo', 'question'),
  a('Bonsoir,quelles sont les procédures à suivre pour créer un compte vendeur? Merci.', 'question'),
  a('Comment puis-je créer ma boutique dans l\'application ?', 'question'),
  a('Bonjour, je voudrais savoir si on peut valider deux produits de deux resto différents dans un même panier merci', 'question'),
  a('Bonsoir, j\'aimerai passer deux commande dans deux restaurants collés l\'un à l\'autre. Est-ce possible d\'avoir le même livreur pour les 2 ?', 'question'),
  a('Bonjour est ce que vous travaillez aujourd’hui ?', 'question'),
  a('Bonjour vous faites pas livraison à cette heure-ci', 'question'),
  a('Hello tovo! J’aimerais savoir si possible d’effectuer une commande à livrer à quelqu\'un ?', 'question'),
  a('Comment commander ?? bonsoir', 'question'),
  a('How can command food for tovo application', 'question'),
  a('Bonjour ! J\'aimerais savoir plus sur cette app', 'question'),
  a('Je parle à une ia ou avec une personne réelle', 'question', { aussi: ['social'] }),
  a('Vous pour commander chez vous faut le faire une journée à l’avance pour que ça valide ou c’est comment', 'question'),
  a('Bonsoir J\'aimerais vous suggérer d\'avoir des livreurs qui ont un GPS et pourront localiser les clients puisque les commandes se font en ligne.', 'social', { aussi: ['question'], note: 'suggestion' }),

  // ── Salutations et compliments ──────────────────────────────────────
  a('Bonjour vous allez bien ??', 'social'),
  a('Bonjour chers développeur', 'social'),
  a('Servie impeccable et rapide mention spéciale au livreur', 'social'),
  a('Excellent service, je recommande vivement. 👍🏾', 'social'),
  a('1ere commande magnifique…5 etoiles au livreur qui m’a livrer', 'social'),
  a('La qualité de vos services est inpecable et vos agents sont très polis! Bravo pour cette initiative', 'social'),
  a('Colis reçu, très rapide Masha Allah très bon service 👍🏽👍🏽👍🏽', 'social'),
  a('As salam', 'social'),
  a('مرحبا', 'social', { note: 'arabe : bonjour' }),
  a('Bonsoir désolé du dérangement c’était une erreur le téléphone était dans les mains des enfants', 'social', { aussi: ['annuler'] }),
];
