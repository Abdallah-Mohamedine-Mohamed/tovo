import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../components/registry.dart';
import '../../core/api.dart';
import '../../core/location.dart';
import '../../core/theme.dart';
import '../../core/voix.dart';

/// Le fil conversationnel.
///
/// Deux chemins vers le backend, et le partage n'est pas arbitraire :
///
///   `/chat`  — tout ce qui demande de comprendre une intention. Le texte
///              libre, les photos, les réponses rapides.
///
///   REST     — tout ce qui est déterministe. Ajouter au panier, changer une
///              quantité, passer commande. Ces actions ne coûtent pas un
///              aller-retour au modèle, et surtout : passer commande engage
///              de l'argent et ne doit dépendre d'aucune interprétation.
///
/// L'enveloppe renvoyée est identique dans les deux cas — `content` +
/// `components` — donc cet écran ne fait pas la différence.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.api});

  final TovoApi api;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

/// Où livrer, une fois le choix fait.
///
/// Le repère écrit compte autant que les coordonnées : c'est lui que le
/// livreur lit quand le GPS le pose au milieu du quartier.
class _Destination {
  const _Destination({required this.repere, required this.lat, required this.lng});

  final String repere;
  final double lat;
  final double lng;
}

class _Tour {
  _Tour({
    required this.deLAssistant,
    required this.contenu,
    this.composants = const [],
    this.enErreur = false,
  });

  final bool deLAssistant;
  final String contenu;
  final List<TovoComponent> composants;
  final bool enErreur;
}

class _ChatScreenState extends State<ChatScreen> {
  final List<_Tour> _tours = [];
  final ScrollController _scroll = ScrollController();
  final TextEditingController _saisie = TextEditingController();

  bool _charge = false;
  String? _conversationId;

  /// Conservé entre deux tentatives : un rejeu après coupure doit présenter
  /// le MÊME identifiant, sinon l'idempotence ne sert à rien.
  String? _idCommandeEnCours;

  bool _enregistreLaVoix = false;
  DateTime? _debutParole;
  Timer? _minuterieParole;

  @override
  void initState() {
    super.initState();
    _accueil();
  }

  @override
  void dispose() {
    _minuterieParole?.cancel();
    unawaited(VoixTovo.annuler());
    unawaited(VoixTovo.liberer());
    _scroll.dispose();
    _saisie.dispose();
    super.dispose();
  }

  /// Ce qu'on montre à l'ouverture.
  ///
  /// Une commande en cours passe AVANT tout le reste : c'est la seule chose
  /// que le client a en tête en rouvrant l'app. Jusqu'ici il retombait sur
  /// la grille des catégories et devait demander où en était sa livraison.
  Future<void> _accueil() async {
    final commandes = await widget.api.get('/orders', query: {'limit': 5});

    if (commandes.ok) {
      final liste = (commandes.raw['orders'] as List?) ?? const [];
      final enCours = liste.cast<Map<String, dynamic>>().where((o) {
        final s = '${o['status']}';
        return s != 'delivered' && s != 'cancelled';
      }).toList();

      if (enCours.isNotEmpty && mounted) {
        await _appeler(() => widget.api.get('/orders/${enCours.first['id']}'));
        return;
      }
    }

    if (!mounted) return;
    if (await _reprendreLaConversation()) return;
    if (mounted) await _appeler(() => widget.api.get('/categories'));
  }

  /// Recharge la dernière conversation. Vrai s'il y avait quelque chose.
  ///
  /// Les échanges étaient enregistrés depuis toujours et jamais relus :
  /// chaque lancement ouvrait un fil neuf, et ce que le client avait dit la
  /// veille disparaissait. Il repartait de zéro sans comprendre pourquoi
  /// l'assistant ne se souvenait de rien.
  Future<bool> _reprendreLaConversation() async {
    final reponse = await widget.api.get('/conversations/last');
    if (!reponse.ok || !mounted) return false;

    final id = reponse.raw['conversation_id'];
    final messages = (reponse.raw['messages'] as List?) ?? const [];
    if (id is! String || messages.isEmpty) return false;

    setState(() {
      _conversationId = id;
      for (final m in messages.cast<Map<String, dynamic>>()) {
        _tours.add(_Tour(
          deLAssistant: m['role'] != 'user',
          contenu: '${m['content'] ?? ''}',
          composants: ((m['components'] as List?) ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(TovoComponent.fromJson)
              .where((c) => c.type.isNotEmpty)
              .toList(),
        ));
      }
    });
    _versLeBas();
    return true;
  }

  // ------------------------------------------------------------------
  // Échanges
  // ------------------------------------------------------------------

  /// @param remplaceLeDernier met à jour le dernier tour au lieu d'en
  ///        ajouter un. Sans ça, changer une quantité empilait un panier de
  ///        plus à chaque appui : on croyait avoir ajouté un produit, et on
  ///        perdait de vue celui qu'on venait de modifier.
  Future<void> _appeler(
    Future<TovoResponse> Function() requete, {
    bool remplaceLeDernier = false,
  }) async {
    setState(() => _charge = true);
    final reponse = await requete();
    if (!mounted) return;

    final tour = _Tour(
      deLAssistant: true,
      contenu: reponse.content,
      composants: reponse.components,
      enErreur: !reponse.ok,
    );

    setState(() {
      _charge = false;
      // On ne remplace que si le dernier tour montre bien la même chose :
      // écraser un message d'erreur ou une réponse de l'assistant ferait
      // disparaître une information que l'utilisateur n'a pas encore lue.
      final peutRemplacer = remplaceLeDernier &&
          _tours.isNotEmpty &&
          reponse.ok &&
          _memeNature(_tours.last, tour);

      if (peutRemplacer) {
        _tours[_tours.length - 1] = tour;
      } else {
        _tours.add(tour);
      }

      final id = reponse.raw['conversation_id'];
      if (id is String) _conversationId = id;
    });

    if (!remplaceLeDernier) _versLeBas();
  }

  /// Deux tours montrent-ils le même composant ?
  static bool _memeNature(_Tour a, _Tour b) {
    if (a.composants.isEmpty || b.composants.isEmpty) return false;
    return a.composants.first.type == b.composants.first.type;
  }

  /// Parle à l'assistant. Texte libre ou interaction à interpréter.
  Future<void> _parler({String? texte, Map<String, dynamic>? interaction}) {
    return _appeler(() => widget.api.post('/chat', {
          'client_message_id': _nouvelIdentifiant(),
          if (_conversationId != null) 'conversation_id': _conversationId,
          if (texte != null) 'text': texte,
          if (interaction != null) 'interaction': interaction,
          if (_position != null)
            'context': {'lat': _position!.$1, 'lng': _position!.$2},
        }));
  }

  // ------------------------------------------------------------------
  // Message vocal
  // ------------------------------------------------------------------

  /// Appui court sur le micro.
  ///
  /// Sans lui, toucher le bouton ne produisait rien du tout : ni son, ni
  /// message, ni vibration. On en concluait que la fonction était cassée —
  /// alors qu'elle attendait simplement un appui maintenu.
  ///
  /// C'est aussi ici qu'on demande l'accès au micro, jamais pendant l'appui
  /// long : la boîte de dialogue Android interromprait le geste, et
  /// l'enregistrement démarrerait après coup, sans personne pour l'arrêter.
  Future<void> _toucherLeMicro() async {
    if (await VoixTovo.autorisation()) {
      if (!mounted) return;
      _messageAssistant('Maintenez le bouton pour parler, relâchez pour envoyer.');
      return;
    }

    if (!mounted) return;
    _messageAssistant(
      "Je n'ai pas accès au micro. Autorisez-le dans les réglages du "
      'téléphone, ou écrivez votre demande.',
      enErreur: true,
    );
  }

  void _messageAssistant(String texte, {bool enErreur = false}) {
    setState(() {
      _tours.add(_Tour(deLAssistant: true, contenu: texte, enErreur: enErreur));
    });
    _versLeBas();
  }

  Future<void> _demarrerLaParole() async {
    // L'autorisation est réglée par l'appui court : si elle manque encore,
    // on ne l'ouvre pas ici, on explique. Ouvrir la boîte de dialogue
    // pendant l'appui long laisserait un enregistrement orphelin.
    if (!await VoixTovo.autorisation()) {
      if (!mounted) return;
      _messageAssistant(
        "Je n'ai pas accès au micro. Autorisez-le dans les réglages du "
        'téléphone, ou écrivez votre demande.',
        enErreur: true,
      );
      return;
    }

    final autorise = await VoixTovo.demarrer();
    if (!mounted) return;

    if (!autorise) {
      _messageAssistant(
        "Je n'arrive pas à démarrer l'enregistrement. Écrivez votre demande.",
        enErreur: true,
      );
      return;
    }

    // Le doigt couvre le bouton pendant l'appui long : sans vibration, on
    // ne sait pas si le micro a démarré, et on parle dans le vide.
    unawaited(HapticFeedback.mediumImpact());

    setState(() {
      _enregistreLaVoix = true;
      _debutParole = DateTime.now();
    });

    // Un doigt qui reste posé — poche, distraction — enverrait des minutes
    // de silence à facturer. On coupe et on envoie ce qui a été dit.
    _minuterieParole = Timer(VoixTovo.dureeMax, () {
      if (mounted && _enregistreLaVoix) unawaited(_envoyerLaParole());
    });
  }

  Future<void> _envoyerLaParole() async {
    if (!_enregistreLaVoix) return;
    _minuterieParole?.cancel();

    final duree = DateTime.now().difference(_debutParole ?? DateTime.now());
    setState(() => _enregistreLaVoix = false);

    // Appui trop bref : c'est un geste manqué, pas une demande. Envoyer
    // coûterait un appel au modèle pour du silence.
    if (duree < VoixTovo.dureeMin) {
      await VoixTovo.annuler();
      return;
    }

    final audio = await VoixTovo.arreter();
    if (!mounted || audio == null) return;

    unawaited(HapticFeedback.lightImpact());
    _ajouterTourUtilisateur('🎤 Message vocal');
    await _appeler(() => widget.api.post('/chat', {
          'client_message_id': _nouvelIdentifiant(),
          if (_conversationId != null) 'conversation_id': _conversationId,
          'audio': {'mime': audio.mime, 'data': audio.data},
          if (_position != null)
            'context': {'lat': _position!.$1, 'lng': _position!.$2},
        }));
  }

  Future<void> _annulerLaParole() async {
    _minuterieParole?.cancel();
    if (mounted) setState(() => _enregistreLaVoix = false);
    await VoixTovo.annuler();
  }

  /// Dernière position connue, envoyée à l'assistant pour les recherches de
  /// proximité. On ne la redemande pas à chaque message : le GPS coûte de la
  /// batterie et l'utilisateur ne se téléporte pas entre deux phrases.
  (double, double)? _position;

  Future<void> _rafraichirPosition() async {
    final p = await TovoLocation.current();
    if (p != null && mounted) setState(() => _position = (p.latitude, p.longitude));
  }

  void _ajouterTourUtilisateur(String texte) {
    setState(() => _tours.add(_Tour(deLAssistant: false, contenu: texte)));
    _versLeBas();
  }

  void _versLeBas() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  // ------------------------------------------------------------------
  // Interactions
  // ------------------------------------------------------------------

  void _interaction(TovoInteraction interaction) {
    final p = interaction.payload;

    switch (interaction.action) {
      // --- déterministe : REST, sans modèle -------------------------
      // Une catégorie mène aux BOUTIQUES, pas à un tas de produits.
      // « Restaurants » regroupe 31 enseignes : en déverser les plats
      // mélangés ne correspond ni à la structure des données ni à la façon
      // dont on choisit — on décide d'abord où, puis quoi.
      case 'select_category':
        // Un rayon de boutique porte son `merchant_id` : il mène aux
        // produits de CETTE boutique, pas à toutes les boutiques de la
        // catégorie.
        final boutique = p['merchant_id'] as String?;
        if (boutique != null) {
          _appeler(() => widget.api.get(
                '/merchants/$boutique/products',
                query: {'category': p['category_id']},
              ));
        } else {
          _ajouterTourUtilisateur('Voir cette catégorie');
          _appeler(() => widget.api.get(
                '/categories/${p['category_id']}/merchants',
                query: _position == null
                    ? null
                    : {'lat': _position!.$1, 'lng': _position!.$2},
              ));
        }

      case 'select_product':
        _appeler(() => widget.api.get('/products/${p['product_id']}'));

      case 'add_to_cart':
        _appeler(() => widget.api.post('/cart/items', {
              'product_id': p['product_id'],
              'quantity': p['quantity'] ?? 1,
              'selections': p['selections'] ?? const [],
            }));

      // Ces trois gestes changent un panier déjà à l'écran : ils le
      // mettent à jour sur place au lieu d'en empiler une copie plus bas.
      case 'update_qty':
        _appeler(
          () => widget.api.patch(
            '/cart/items/${p['item_id']}',
            {'quantity': p['quantity']},
          ),
          remplaceLeDernier: true,
        );

      case 'remove_from_cart':
        _appeler(
          () => widget.api.delete('/cart/items/${p['item_id']}'),
          remplaceLeDernier: true,
        );

      case 'place_order':
        _commander();

      case 'submit_courier':
        _envoyerColis(p);

      // Envoi silencieux : la carte affiche déjà le remerciement, et faire
      // répondre l'assistant après une note serait du bavardage.
      case 'rate_order':
        _noter('${p['order_id'] ?? ''}', (p['rating'] as num?)?.toInt() ?? 0);

      // Ouvrir une boutique est déterministe : on sait exactement quoi
      // afficher. Ça passait par l'assistant, qui n'avait aucun outil pour
      // le faire et répondait « je n'ai rien trouvé » — un aller-retour au
      // modèle, facturé, pour une réponse fausse.
      case 'select_merchant':
        _appeler(() => widget.api.get('/merchants/${p['merchant_id']}/products'));

      // --- interprétation nécessaire : l'assistant -------------------

      case 'compare_price':
        _ajouterTourUtilisateur('Comparer les prix pour ${p['query']}');
        _parler(interaction: {'action': 'compare_price', 'payload': p});

      case 'quick_reply':
        final valeur = '${p['value'] ?? ''}';
        _ajouterTourUtilisateur('${p['label'] ?? valeur}');
        // Deux réponses rapides sont des ordres, pas des intentions : les
        // faire interpréter serait payer un aller-retour pour rien.
        if (valeur == 'vider_panier') {
          _appeler(() => widget.api.delete('/cart'));
        } else if (valeur == 'garder_panier') {
          _appeler(() => widget.api.get('/cart'));
        } else if (valeur.startsWith('adresse:')) {
          // L'assistant a proposé « je livre chez vous, à … ? » et le client
          // a répondu. Redemander la destination juste après serait lui
          // reposer la question à laquelle il vient de répondre.
          _commander(adresseChoisie: valeur.substring('adresse:'.length));
        } else {
          _parler(interaction: {'action': 'quick_reply', 'payload': p});
        }

      // --- cas particuliers ------------------------------------------
      case 'pick_image':
        _chercherParPhoto(
          '${p['source']}' == 'camera' ? ImageSource.camera : ImageSource.gallery,
        );

      case 'open_external':
        _ouvrirLien('${p['url'] ?? ''}');

      case 'call_driver':
        _appeler_(p['phone']);

      default:
        debugPrint('[chat] interaction non gérée : ${interaction.action}');
    }
  }

  // ------------------------------------------------------------------
  // Recherche par photo
  // ------------------------------------------------------------------

  Future<void> _chercherParPhoto(ImageSource source) async {
    final fichier = await ImagePicker().pickImage(
      source: source,
      // Compression avant l'envoi : une photo brute de 4 Mo depuis Niamey
      // prend une minute et consomme le forfait de l'utilisateur. 1024 px
      // suffisent largement à reconnaître un produit.
      maxWidth: 1024,
      imageQuality: 75,
    );
    if (fichier == null || !mounted) return;

    _ajouterTourUtilisateur('📷 Photo envoyée');
    setState(() => _charge = true);

    try {
      final utilisateur = Supabase.instance.client.auth.currentUser;
      if (utilisateur == null) throw Exception('session absente');

      // Convention imposée par les policies Storage : le premier segment est
      // l'identifiant de l'utilisateur. Chacun n'écrit que chez soi.
      final chemin = '${utilisateur.id}/${_nouvelIdentifiant()}.jpg';

      await Supabase.instance.client.storage.from('search-images').uploadBinary(
            chemin,
            await fichier.readAsBytes(),
            fileOptions: const FileOptions(contentType: 'image/jpeg'),
          );

      if (!mounted) return;
      setState(() => _charge = false);

      // Seul le CHEMIN part vers l'assistant. Les octets de l'image
      // n'entrent jamais dans le contexte du modèle : ils y resteraient à
      // chaque tour, pour toujours.
      await _parler(interaction: {
        'action': 'search_by_image',
        'payload': {'image_path': chemin},
      });
    } on Exception catch (cause) {
      if (!mounted) return;
      setState(() {
        _charge = false;
        _tours.add(_Tour(
          deLAssistant: true,
          contenu: "L'envoi de la photo a échoué. Vérifiez votre réseau.",
          enErreur: true,
        ));
      });
      debugPrint('[chat] photo non envoyée : $cause');
    }
  }

  // ------------------------------------------------------------------
  // Commande
  // ------------------------------------------------------------------

  /// Passe la commande du panier courant.
  ///
  /// [adresseChoisie] vient de la réponse rapide de l'assistant : le client
  /// a déjà dit où livrer, on ne le lui redemande pas. La valeur
  /// `nouvelle` signifie « ailleurs » et retombe sur la position actuelle.
  Future<void> _commander({String? adresseChoisie}) async {
    // Les adresses d'abord : à Niamey il n'y a pas d'adresse postale, et
    // retaper « Yantala, derrière la pharmacie Al Nour » à chaque commande
    // est la friction la plus évitable de l'application.
    final destination = await _choisirDestination(adresseChoisie: adresseChoisie);
    if (!mounted || destination == null) return;

    final paiement = await _choisirPaiement();
    if (!mounted || paiement == null) return;

    // Le geste qui engage de l'argent mérite un retour franc.
    unawaited(HapticFeedback.mediumImpact());
    _idCommandeEnCours ??= _nouvelIdentifiant();

    await _appeler(() => widget.api.post('/orders', {
          'type': 'delivery',
          'client_order_id': _idCommandeEnCours,
          'dropoff_hint': destination.repere,
          'dropoff': {'lat': destination.lat, 'lng': destination.lng},
          'payment_method': paiement,
        }));

    _idCommandeEnCours = null;
  }

  /// Où livrer : une adresse déjà connue, ou la position actuelle.
  ///
  /// Renvoie `null` si le client renonce — annuler à cette étape ne doit
  /// jamais passer commande.
  Future<_Destination?> _choisirDestination({String? adresseChoisie}) async {
    List<Map<String, dynamic>> connues = const [];
    try {
      final reponse = await widget.api.get('/addresses');
      connues = ((reponse.raw['addresses'] as List?) ?? const [])
          .map((a) => (a as Map).cast<String, dynamic>())
          .toList();
    } catch (_) {
      // Hors ligne ou route indisponible : on retombe sur la saisie
      // manuelle plutôt que d'empêcher de commander.
    }

    if (!mounted) return null;

    // Choix déjà exprimé auprès de l'assistant : on l'honore tel quel.
    // Une adresse entre-temps supprimée retombe sur la feuille de choix
    // plutôt que de faire échouer la commande.
    if (adresseChoisie != null && adresseChoisie != 'nouvelle') {
      final connue = connues.where((a) => a['id'] == adresseChoisie).firstOrNull;
      if (connue != null) {
        return _Destination(
          repere: connue['text_hint'] as String,
          lat: (connue['lat'] as num).toDouble(),
          lng: (connue['lng'] as num).toDouble(),
        );
      }
    }

    if (connues.isNotEmpty && adresseChoisie != 'nouvelle') {
      final choix = await _feuilleAdresses(connues);
      if (!mounted || choix == null) return null;
      if (choix != _nouvelleAdresse) {
        final a = connues.firstWhere((x) => x['id'] == choix);
        return _Destination(
          repere: a['text_hint'] as String,
          lat: (a['lat'] as num).toDouble(),
          lng: (a['lng'] as num).toDouble(),
        );
      }
    }

    final position = await TovoLocation.current();
    if (!mounted) return null;
    if (position == null) {
      _erreurLocalisation();
      return null;
    }

    final repere = await _demanderLeRepere('Où livrer ?');
    if (!mounted || repere == null) return null;

    // Enregistrer se fait en tâche de fond : un échec ne doit pas empêcher
    // la commande, qui est ce que le client est venu faire.
    unawaited(widget.api.post('/addresses', {
      'label': 'Adresse',
      'text_hint': repere,
      'lat': position.latitude,
      'lng': position.longitude,
    }));

    return _Destination(
      repere: repere,
      lat: position.latitude,
      lng: position.longitude,
    );
  }

  static const String _nouvelleAdresse = '__nouvelle__';

  Future<String?> _feuilleAdresses(List<Map<String, dynamic>> adresses) {
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Où livrer ?',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
            for (final a in adresses)
              ListTile(
                leading: Icon(
                  a['is_default'] == true ? Icons.home_rounded : Icons.place_outlined,
                  color: TovoTheme.teal,
                ),
                title: Text(a['label'] as String? ?? 'Adresse'),
                subtitle: Text(
                  a['text_hint'] as String? ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.pop(context, a['id'] as String),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.add_location_alt_outlined),
              title: const Text('Livrer ailleurs'),
              subtitle: const Text('Utiliser ma position actuelle'),
              onTap: () => Navigator.pop(context, _nouvelleAdresse),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Espèces ou Nita.
  ///
  /// Choisir Nita ne retient rien : la commande part chez le boutiquier et
  /// le client règle quand il veut, avant ou à la livraison. On le dit ici,
  /// sinon il croit devoir payer d'abord.
  Future<String?> _choisirPaiement() {
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Comment souhaitez-vous payer ?',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.payments_outlined, color: TovoTheme.teal),
              title: const Text('Espèces'),
              subtitle: const Text('Vous payez le livreur à l’arrivée'),
              onTap: () => Navigator.pop(context, 'cash'),
            ),
            ListTile(
              leading: const Icon(Icons.phone_iphone_rounded, color: TovoTheme.teal),
              title: const Text('Nita'),
              subtitle: const Text('Un code à régler depuis MYNITA, ou payez au livreur'),
              onTap: () => Navigator.pop(context, 'mobile_money'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Enregistre la note d'une commande livrée.
  ///
  /// Sans passer par `_appeler` : celui-ci ajoute la réponse du serveur au
  /// fil de conversation, ce qui ferait apparaître un message pour un geste
  /// qui se suffit à lui-même. Un échec reste silencieux — la carte a déjà
  /// remercié, revenir dessus pour dire que ça n'a pas marché n'apporterait
  /// rien au client, qui ne peut rien y faire.
  Future<void> _noter(String orderId, int note) async {
    if (orderId.isEmpty || note < 1 || note > 5) return;
    unawaited(HapticFeedback.selectionClick());
    try {
      await widget.api.post('/orders/$orderId/review', {'rating': note});
    } catch (cause) {
      debugPrint('[chat] note non enregistrée : $cause');
    }
  }

  Future<void> _envoyerColis(Map<String, dynamic> p) async {
    final depart = (p['pickup'] as Map?)?.cast<String, dynamic>();
    final arrivee = (p['dropoff'] as Map?)?.cast<String, dynamic>();

    if (depart?['lat'] == null || arrivee?['lat'] == null) {
      _erreurLocalisation();
      return;
    }

    final paiement = await _choisirPaiement();
    if (!mounted || paiement == null) return;

    _idCommandeEnCours ??= _nouvelIdentifiant();

    await _appeler(() => widget.api.post('/orders', {
          'type': 'courier',
          'client_order_id': _idCommandeEnCours,
          'pickup_hint': depart!['hint'],
          'pickup': {'lat': depart['lat'], 'lng': depart['lng']},
          'dropoff_hint': arrivee!['hint'],
          'dropoff': {'lat': arrivee['lat'], 'lng': arrivee['lng']},
          'parcel': p['parcel'] ?? 'small',
          'payment_method': paiement,
        }));

    _idCommandeEnCours = null;
  }

  void _erreurLocalisation() {
    setState(() {
      _tours.add(_Tour(
        deLAssistant: true,
        contenu: "Je ne peux pas livrer sans savoir où vous êtes. "
            "Activez la localisation, puis réessayez.",
        enErreur: true,
      ));
    });
    _versLeBas();
  }

  Future<String?> _demanderLeRepere(String titre) {
    final controleur = TextEditingController();

    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(titre, style: const TextStyle(fontSize: 16)),
        content: TextField(
          controller: controleur,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Ex. : Yantala, derrière la pharmacie Al Nour',
            helperText: 'Un repère que le livreur reconnaîtra',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () {
              final texte = controleur.text.trim();
              if (texte.isEmpty) return;
              Navigator.pop(context, texte);
            },
            child: const Text('Confirmer'),
          ),
        ],
      ),
    );
  }

  Future<void> _ouvrirLien(String url) async {
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _appeler_(Object? telephone) async {
    var numero = '${telephone ?? ''}'.replaceAll(RegExp(r'[^\d+]'), '');
    if (numero.isEmpty) return;

    // Supabase Auth retire le « + » en enregistrant le numéro : la base
    // contient « 22790626927 ». Composé tel quel, le téléphone y voit un
    // numéro local de 11 chiffres — au Niger ils en font 8 — et l'appel
    // n'aboutit pas. Le livreur ne peut alors pas joindre son client.
    if (!numero.startsWith('+') && numero.length > 8) numero = '+$numero';

    await launchUrl(Uri.parse('tel:$numero'));
  }

  void _envoyer() {
    unawaited(HapticFeedback.selectionClick());
    final texte = _saisie.text.trim();
    if (texte.isEmpty) return;
    _saisie.clear();
    _ajouterTourUtilisateur(texte);
    _rafraichirPosition();
    unawaited(_chercherPuisDemander(texte));
  }

  /// La recherche d'abord, l'assistant seulement s'il le faut.
  ///
  /// « tacos » est un mot-clé sans ambiguïté : le faire interpréter coûtait
  /// 3,5 secondes et un appel au modèle facturé, là où la base répond en
  /// 200 ms. On tente donc la recherche directe, et on ne réveille
  /// l'assistant que si elle ne trouve rien — c'est précisément là que
  /// l'interprétation sert, pour « quelque chose de léger pour ce soir ».
  ///
  /// Ce que ça coûte : l'assistant ne voit pas passer les recherches
  /// abouties, donc un « le deuxième » qui suit ne trouvera pas de contexte.
  /// Le compromis vaut la peine tant que la lenteur reste le premier reproche.
  Future<void> _chercherPuisDemander(String texte) async {
    setState(() => _charge = true);

    final recherche = await widget.api.get('/search', query: {
      'q': texte,
      if (_position != null) 'lat': _position!.$1,
      if (_position != null) 'lng': _position!.$2,
    });

    if (!mounted) return;

    // Des résultats : on s'arrête là, sans appel au modèle.
    if (recherche.ok && recherche.components.isNotEmpty) {
      setState(() {
        _charge = false;
        _tours.add(_Tour(
          deLAssistant: true,
          contenu: recherche.content,
          composants: recherche.components,
        ));
      });
      _versLeBas();
      return;
    }

    // Rien trouvé, ou route indisponible : l'assistant prend le relais.
    setState(() => _charge = false);
    await _parler(texte: texte);
  }

  static String _nouvelIdentifiant() {
    const chiffres = '0123456789abcdef';
    final aleatoire = Random.secure();
    final tampon = StringBuffer();
    for (var i = 0; i < 36; i++) {
      if (i == 8 || i == 13 || i == 18 || i == 23) {
        tampon.write('-');
      } else if (i == 14) {
        tampon.write('4');
      } else if (i == 19) {
        tampon.write(chiffres[8 + aleatoire.nextInt(4)]);
      } else {
        tampon.write(chiffres[aleatoire.nextInt(16)]);
      }
    }
    return tampon.toString();
  }

  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'tovo',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: TovoTheme.teal,
                letterSpacing: -1,
              ),
            ),
            const Text(
              'Niamey · livraison',
              style: TextStyle(fontSize: 11, color: TovoTheme.muted),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Mon panier',
            icon: const Icon(Icons.shopping_bag_outlined),
            onPressed: () => _appeler(() => widget.api.get('/cart')),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              itemCount: _tours.length,
              itemBuilder: (context, i) => _TourVue(
                key: ValueKey(_tours[i]),
                tour: _tours[i],
                onInteraction: _interaction,
                // Seul le dernier message s'anime. Animer toute la liste la
                // ferait frémir à chaque défilement, et le client croirait
                // que quelque chose se recharge.
                anime: i == _tours.length - 1,
              ),
            ),
          ),
          // Un trait de progression ne dit rien de ce qui se passe. Trois
          // points qui respirent disent « je réfléchis », ce qui est la
          // vérité et ce que le client comprend sans y penser.
          AnimatedSize(
            duration: TovoTheme.normal,
            curve: TovoTheme.courbe,
            child: _charge ? const _EnReflexion() : const SizedBox.shrink(),
          ),
          _BarreDeSaisie(
            controller: _saisie,
            onSend: _envoyer,
            onCamera: () => _chercherParPhoto(ImageSource.camera),
            enregistre: _enregistreLaVoix,
            onParoleTouche: _toucherLeMicro,
            onParoleDebut: _demarrerLaParole,
            onParoleFin: _envoyerLaParole,
            onParoleAnnulee: _annulerLaParole,
          ),
        ],
      ),
    );
  }
}

/// Trois points qui respirent pendant que l'assistant travaille.
///
/// Remplace le trait de progression : celui-ci indiquait qu'il se passait
/// quelque chose, sans dire quoi. Ici la forme dit d'elle-même « je
/// réfléchis », et l'attente devient lisible plutôt que vide.
class _EnReflexion extends StatefulWidget {
  const _EnReflexion();

  @override
  State<_EnReflexion> createState() => _EnReflexionState();
}

class _EnReflexionState extends State<_EnReflexion>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
      child: Row(
        children: [
          for (var i = 0; i < 3; i++)
            AnimatedBuilder(
              animation: _c,
              builder: (context, _) {
                // Chaque point est décalé d'un tiers de cycle : l'onde va de
                // gauche à droite au lieu de les faire clignoter ensemble.
                final phase = (_c.value + i / 3) % 1.0;
                final montee = (sin(phase * 2 * pi) + 1) / 2;
                return Container(
                  width: 6,
                  height: 6,
                  margin: const EdgeInsets.only(right: 5),
                  decoration: BoxDecoration(
                    color: Color.lerp(TovoTheme.line, TovoTheme.teal, montee),
                    shape: BoxShape.circle,
                  ),
                );
              },
            ),
          const SizedBox(width: 4),
          const Text(
            'Je réfléchis…',
            style: TextStyle(fontSize: 12, color: TovoTheme.muted),
          ),
        ],
      ),
    );
  }
}

class _TourVue extends StatefulWidget {
  const _TourVue({
    super.key,
    required this.tour,
    required this.onInteraction,
    this.anime = false,
  });

  final _Tour tour;
  final InteractionCallback onInteraction;

  /// Le message vient d'arriver : il glisse et se révèle. Les précédents
  /// s'affichent directement, sinon la liste frémirait à chaque défilement.
  final bool anime;

  @override
  State<_TourVue> createState() => _TourVueState();
}

class _TourVueState extends State<_TourVue> {
  double _opacite = 1;
  double _decalage = 0;

  @override
  void initState() {
    super.initState();
    if (!widget.anime) return;

    _opacite = 0;
    _decalage = 12;
    // Une image plus tard : poser l'état initial puis le changer dans la
    // même image ne déclencherait aucune transition.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() { _opacite = 1; _decalage = 0; });
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      offset: Offset(0, _decalage / 100),
      duration: TovoTheme.normal,
      curve: TovoTheme.courbe,
      child: AnimatedOpacity(
        opacity: _opacite,
        duration: TovoTheme.normal,
        curve: TovoTheme.courbe,
        child: _contenu(context),
      ),
    );
  }

  Widget _contenu(BuildContext context) {
    final tour = widget.tour;
    final onInteraction = widget.onInteraction;

    if (!tour.deLAssistant) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12, left: 48),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: TovoTheme.teal,
            borderRadius: BorderRadius.circular(16)
                .copyWith(bottomRight: const Radius.circular(4)),
          ),
          child: Text(
            tour.contenu,
            style: const TextStyle(fontSize: 13, color: Colors.white, height: 1.5),
          ),
        ),
      );
    }

    final widgets = ComponentRegistry.buildAll(tour.composants, onInteraction);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (tour.contenu.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 12, right: 48),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: tour.enErreur ? const Color(0xFFFDECEA) : TovoTheme.tealSoft,
              borderRadius: BorderRadius.circular(16)
                  .copyWith(bottomLeft: const Radius.circular(4)),
            ),
            child: Text(
              tour.contenu,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: tour.enErreur ? TovoTheme.danger : TovoTheme.ink,
              ),
            ),
          ),
        for (final widget in widgets)
          Padding(padding: const EdgeInsets.only(bottom: 16), child: widget),
      ],
    );
  }
}

class _BarreDeSaisie extends StatelessWidget {
  const _BarreDeSaisie({
    required this.controller,
    required this.onSend,
    required this.onCamera,
    required this.enregistre,
    required this.onParoleTouche,
    required this.onParoleDebut,
    required this.onParoleFin,
    required this.onParoleAnnulee,
  });

  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onCamera;

  /// Vrai pendant l'enregistrement : la barre change entièrement d'aspect,
  /// sinon l'utilisateur ne sait pas que le micro l'écoute.
  final bool enregistre;
  /// Appui court : explique le geste, ou demande l'accès au micro.
  final VoidCallback onParoleTouche;
  final VoidCallback onParoleDebut;
  final VoidCallback onParoleFin;
  final VoidCallback onParoleAnnulee;

  /// Ce que voit l'utilisateur pendant qu'il parle.
  ///
  /// La barre change entièrement : sans signal clair, on ne sait pas si le
  /// micro écoute, et on relâche trop tôt ou on parle dans le vide.
  Widget _enEcoute() {
    return Row(
      children: [
        const SizedBox(width: 8),
        Container(
          width: 10,
          height: 10,
          decoration: const BoxDecoration(color: TovoTheme.danger, shape: BoxShape.circle),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Text(
            'Je vous écoute… relâchez pour envoyer',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        Container(
          width: 40,
          height: 40,
          decoration: const BoxDecoration(color: TovoTheme.teal, shape: BoxShape.circle),
          child: const Icon(Icons.mic, size: 20, color: Colors.white),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 8, 12, 10),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: TovoTheme.line)),
        ),
        child: enregistre ? _enEcoute() : Row(
          children: [
            // La recherche par photo est ce que Tovo fait de mieux et que
            // personne ne fait ici. Elle mérite un bouton permanent, pas
            // d'être enfouie derrière une question de l'assistant.
            IconButton(
              onPressed: onCamera,
              tooltip: 'Chercher par photo',
              icon: const Icon(Icons.photo_camera_outlined, color: TovoTheme.teal),
            ),
            Expanded(
              child: TextField(
                controller: controller,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: InputDecoration(
                  hintText: 'Que voulez-vous commander ?',
                  hintStyle: const TextStyle(fontSize: 13, color: Color(0xFFAAAAAA)),
                  filled: true,
                  fillColor: const Color(0xFFF2F2F2),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Micro tant que rien n'est écrit, envoi dès qu'il y a du texte :
            // deux boutons côte à côte encombreraient une barre déjà chargée,
            // et l'un des deux serait toujours inutile.
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, valeur, _) {
                final vide = valeur.text.trim().isEmpty;
                if (!vide) {
                  return InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: onSend,
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: const BoxDecoration(
                        color: TovoTheme.teal,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.arrow_upward, size: 18, color: Colors.white),
                    ),
                  );
                }

                // Maintenir pour parler, relâcher pour envoyer. Le geste est
                // celui de WhatsApp, que tout le monde connaît ici — un
                // appui-relâche à apprendre ferait échouer le premier essai.
                return GestureDetector(
                  // Un appui court doit répondre quelque chose. Sans `onTap`,
                  // toucher le micro ne produisait rien — ni son, ni message,
                  // ni vibration — et on en concluait que c'était cassé.
                  onTap: onParoleTouche,
                  onLongPressStart: (_) => onParoleDebut(),
                  onLongPressEnd: (_) => onParoleFin(),
                  onLongPressCancel: onParoleAnnulee,
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: const BoxDecoration(
                      color: TovoTheme.teal,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.mic_none_rounded, size: 20, color: Colors.white),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
