# Réactivité client — septembre 2026

## Ce qui change

- Accueil : catégories, historique et commandes demandés en parallèle. Un
  historique ou des catégories déjà consultés s'affichent depuis le téléphone,
  puis sont actualisés. Une réponse lente ne réouvre pas un fil abandonné.
- Le renouvellement du jeton ne recrée plus l'écran de conversation.
- Historique et catalogue : cache local limité à 24 heures, 50 entrées et
  2 Mo de JSON par compte. Effacement à la déconnexion ; une réponse tardive
  ne repeuple pas un cache fermé. Les lectures identiques en cours sont groupées.
- Produits : la fiche montre immédiatement les informations connues. Les
  actions d'achat attendent la vérification du prix, des options et de la
  disponibilité. Ni panier, ni devis, ni commande ne sont servis depuis ce cache.
- Photos publiques du catalogue : cache disque et décodage dimensionné, avec
  préparation des éléments proches de la zone visible. Les photos personnelles
  de conversation ne passent pas dans ce cache d'images publiques.
- Catalogue serveur : produits, enseigne, ouverture et catégories chargés
  en parallèle, sans attendre quatre lectures successives.
- Chat : résultats vérifiés et texte affichés progressivement ; le calcul et
  la persistance continuent côté serveur. Le modèle garde ses outils pour les
  étapes dépendantes, sans sacrifier la logique pour gagner un appel.
- Le cache de prompt Gemini ne bloque pas la génération s'il tarde à se créer.
- Vocal : après arrêt, transcription dans le champ de saisie, modifiable et
  envoyée uniquement après validation. Une erreur permet réessai ou annulation.
- Les mutations ne sont pas rejouées automatiquement après une coupure ambiguë.

## Déploiement

1. Déployer le backend avec `/transcriptions` et la réponse progressive `/chat`.
   Les anciens clients JSON restent compatibles.
2. Installer le nouvel APK client, compilé avec les trois paramètres publics
   habituels : `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `API_BASE_URL`.
3. Aucune migration SQL ni revectorisation n'est introduite par ce lot.
   Les migrations de navigation/catalogue antérieures restent nécessaires.
4. Avec l'ancien backend, les messages texte restent compatibles ; le vocal
   indique explicitement que la mise à jour du serveur est nécessaire.

Le modèle et le fournisseur d'IA ne changent pas. La voix passe par le modèle
Gemini déjà configuré, sans nouvelle clé ni nouveau service de reconnaissance.
Le traitement vocal après arrêt ajoute une étape de transcription : il rend
la demande vérifiable, mais ne garantit pas une réduction de la latence totale
par rapport à l'ancien envoi audio direct.

## Vérification avant généralisation

Tests locaux avec données simulées : affichage anticipé, compte séparé,
expiration/purge du cache, erreur réseau, flux fragmenté, reprise JSON, appels
d'outils dépendants, dictée modifiée avant envoi et navigation pendant un flux.
Les tests de commande conservent la confirmation explicite du devis serveur.

Mesurer sur le téléphone Android réel, à froid puis à chaud, en Wi-Fi et en
réseau mobile : délai au premier contenu, premières images, premières cartes,
premier texte, réponse complète et transcription. Comparer les médianes et
les p95, pas uniquement le meilleur essai. Les journaux de chat fournissent
`duration_ms`, `first_result_ms`, `first_text_ms` et l'usage du modèle ; ces
temps sont côté serveur, pas le délai total perçu sur le téléphone.

La première connexion, la vérification du profil, un contenu jamais visité,
la transcription et les opérations financières demandent encore le réseau.
Le cache n'est ni une preuve de disponibilité, ni une commande hors connexion.
Une réponse IA instantanée et sans erreur n'est pas une garantie réaliste.
Les gains Android de bout en bout restent à mesurer après déploiement.

## Validation locale du 13 septembre 2026

- 54 tests mobiles réussis, dont le vocal modifié avant envoi, le cache
  affiché pendant une panne et les réponses tardives après changement de fil.
- 59 tests serveur réussis : catalogue, intentions, transcription, cache du
  prompt, flux fragmentés et maintien des appels d'outils dépendants.
- Analyse des fichiers Flutter concernés et vérification TypeScript réussies.
- APK de test : `mobile/build/releases/Tovo-client-reactivite-2026-09-13.apk`,
  58 013 247 octets, application `com.unique.tovo.user`, version `2.1.0+5`.
  Signature identique au précédent APK de test et trois paramètres publics
  de connexion vérifiés dans le binaire. Ce n'est pas une publication store.
- Si une recherche affinée ne donne plus aucun résultat, les cartes de la
  première recherche disparaissent aussi du flux, sans attendre sa fin.

Ces vérifications utilisent des données simulées ou une base locale en mémoire,
pas la production. Elles ne mesurent ni le temps réel de Gemini, ni la qualité
de transcription sur le microphone Android, ni le débit du réseau mobile.

Parcours à vérifier après mise à jour du serveur et installation de l'APK :

1. Ouvrir une enseigne puis un produit, revenir et les rouvrir : le contenu
   déjà connu doit être visible pendant l'actualisation.
2. Envoyer « poulet », voir les cartes puis le texte arriver progressivement.
   Créer un nouveau fil pendant la réponse : elle ne doit pas y apparaître.
3. Toucher le micro, parler, toucher de nouveau pour arrêter : relire et
   corriger la transcription, puis envoyer. Rien ne part avant cet envoi.
4. Couper le réseau après consultation d'une carte : elle reste lisible, sans
   permettre de commander à partir d'un devis ou d'un prix non vérifié.
5. Se déconnecter et changer de compte : aucun historique du premier compte
   ne doit être visible dans le second.
