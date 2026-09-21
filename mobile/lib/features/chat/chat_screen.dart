import 'dart:async';
import 'dart:io' show File;
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../components/registry.dart';
import '../../components/widgets/read_placeholder.dart';
import '../../core/api.dart';
import '../../core/location.dart';
import '../../core/theme.dart';
import '../../core/voix.dart';
import 'conversations_drawer.dart';
import '../catalog/catalog_screen.dart';
import '../catalog/product_screen.dart';
import '../catalog/cart_screen.dart';

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
  const _Destination({
    required this.repere,
    required this.lat,
    required this.lng,
  });

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
    this.photoLocale,
  });

  final bool deLAssistant;
  final String contenu;
  final List<TovoComponent> composants;
  final bool enErreur;

  /// La photo que le client vient d'envoyer, telle qu'elle est sur son
  /// téléphone.
  ///
  /// « 📷 Photo envoyée » ne dit pas LAQUELLE. Quand l'assistant répond qu'il
  /// n'a rien trouvé, impossible de savoir si la photo était floue, mal
  /// cadrée, ou si c'est la recherche qui a échoué. La revoir tranche la
  /// question tout de suite.
  ///
  /// Le fichier local, et non l'URL du Storage : il est déjà là, et l'afficher
  /// ne coûte pas un aller-retour réseau. La vignette disparaît donc quand la
  /// conversation est rechargée depuis le serveur, ce qui est acceptable —
  /// elle sert sur le moment.
  final String? photoLocale;
}

class _ChatScreenState extends State<ChatScreen> {
  final List<_Tour> _tours = [];
  final ScrollController _scroll = ScrollController();
  final TextEditingController _saisie = TextEditingController();
  bool _scrollScheduled = false;

  bool _charge = false;
  bool _reponseCommencee = false;
  String? _conversationId;
  int _navigation = 0;
  int _voiceGeneration = 0;
  bool _voiceAction = false;
  bool _loadingHistory = false;
  bool _transcribing = false;
  bool _voiceDraft = false;
  String? _voiceError;
  Map<String, dynamic>? _pendingAudio;

  /// Conservé entre deux tentatives : un rejeu après coupure doit présenter
  /// le MÊME identifiant, sinon l'idempotence ne sert à rien.
  String? _idCommandeEnCours;

  bool _enregistreLaVoix = false;
  DateTime? _debutParole;
  Timer? _minuterieParole;

  /// Prénom du client, pour le salut d'accueil. Nul tant qu'on ne l'a pas.
  String? _prenom;

  @override
  void initState() {
    super.initState();
    unawaited(_lirePrenom());
    unawaited(_demarrer());
  }

  /// Le fil d'abord, la photo rescapée ensuite.
  ///
  /// L'ordre compte : la récupération ajoute un tour à la conversation, et
  /// la reprise du fil, elle, la remplit depuis le serveur. Dans l'autre
  /// sens, la photo récupérée serait écrasée avant même d'être vue.
  Future<void> _demarrer() async {
    final navigation = _navigation;
    await _accueil();
    if (mounted && navigation == _navigation) await _recupererPhotoPerdue();
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
  /// Le fil d'abord, la commande en cours par-dessus.
  ///
  /// L'ordre inverse était en place, et il effaçait tout : dès qu'une
  /// commande était en route, l'app s'ouvrait sur la seule carte de suivi et
  /// `return` sautait la reprise du fil. La conversation qui avait SERVI à
  /// passer cette commande disparaissait pendant toute la livraison — et le
  /// client, lui, en concluait que ses échanges n'étaient pas gardés.
  ///
  /// Les deux ne s'excluent pas : on remet le fil, puis on pose le suivi à la
  /// fin, là où le regard tombe.
  Future<void> _accueil() async {
    final navigation = _navigation;
    final ordersRequest = widget.api.get('/orders', query: {'limit': 5});
    final historyRequest = widget.api.get('/conversations/last');
    final categoriesRequest = widget.api.get('/categories');
    final saved = await widget.api.cachedGet('/conversations/last');
    if (!mounted || navigation != _navigation) return;
    if (saved != null && saved.list('messages').isNotEmpty) {
      _showHistory(saved);
    } else {
      final categories = await widget.api.cachedGet('/categories');
      if (!mounted || navigation != _navigation) return;
      if (categories != null) _showCategories(categories);
    }
    unawaited(
      categoriesRequest.then((categories) {
        if (mounted &&
            navigation == _navigation &&
            _conversationId == null &&
            categories.ok) {
          _showCategories(categories);
        }
      }),
    );
    final history = await historyRequest;
    if (!mounted || navigation != _navigation) return;
    if (history.ok && history.list('messages').isNotEmpty) {
      _showHistory(history);
    } else if (history.ok || _conversationId == null) {
      final categories = await categoriesRequest;
      if (!mounted || navigation != _navigation) return;
      if (categories.ok) _showCategories(categories);
    }
    final commandes = await ordersRequest;
    if (!mounted || navigation != _navigation) return;

    Map<String, dynamic>? enCours;
    if (commandes.ok) {
      final liste = (commandes.raw['orders'] as List?) ?? const [];
      enCours = liste.cast<Map<String, dynamic>>().where((o) {
        final s = '${o['status']}';
        return s != 'delivered' && s != 'cancelled';
      }).firstOrNull;
    }

    if (enCours != null && mounted) {
      await _appeler(() => widget.api.get('/orders/${enCours!['id']}'));
    }
  }

  /// Le prénom, pour le salut d'accueil.
  ///
  /// Le premier mot seulement : « Bonjour Abdallah » se dit, « Bonjour
  /// Abdallah Mohamed Ibrahim » se lit — et déborde sur deux lignes.
  Future<void> _lirePrenom() async {
    try {
      final moi = Supabase.instance.client.auth.currentUser?.id;
      if (moi == null) return;

      final data = await Supabase.instance.client
          .from('profiles')
          .select('full_name')
          .eq('id', moi)
          .maybeSingle();

      final complet = ((data?['full_name'] as String?) ?? '').trim();
      if (complet.isEmpty || !mounted) return;
      setState(() => _prenom = complet.split(RegExp(r'\s+')).first);
    } on Exception {
      // Sans nom, le salut reste impersonnel. Ce n'est pas une raison pour
      // afficher une erreur : personne n'est venu pour lire son prénom.
    }
  }

  /// Recharge la dernière conversation. Vrai s'il y avait quelque chose.
  ///
  /// Les échanges étaient enregistrés depuis toujours et jamais relus :
  /// chaque lancement ouvrait un fil neuf, et ce que le client avait dit la
  /// veille disparaissait. Il repartait de zéro sans comprendre pourquoi
  /// l'assistant ne se souvenait de rien.
  void _showHistory(TovoResponse reponse) {
    final id = reponse.raw['conversation_id'];
    final messages = (reponse.raw['messages'] as List?) ?? const [];
    if (id is! String) return;

    setState(() {
      _conversationId = id;
      _tours.clear();
      for (final m in messages.cast<Map<String, dynamic>>()) {
        _tours.add(
          _Tour(
            deLAssistant: m['role'] != 'user',
            contenu: '${m['content'] ?? ''}',
            composants: ((m['components'] as List?) ?? const [])
                .whereType<Map<String, dynamic>>()
                .map(TovoComponent.fromJson)
                .where((c) => c.type.isNotEmpty)
                .toList(),
          ),
        );
      }
    });
    _versLeBas();
  }

  void _showCategories(TovoResponse response) {
    setState(() {
      _conversationId = null;
      _tours.clear();
      _tours.add(
        _Tour(
          deLAssistant: true,
          contenu: response.content,
          composants: response.components,
        ),
      );
    });
  }

  void _rememberConversation() {
    final id = _conversationId;
    if (id == null) return;
    final body = <String, dynamic>{
      'conversation_id': id,
      'messages': _tours
          .where((tour) => !tour.enErreur)
          .map(
            (tour) => {
              'role': tour.deLAssistant ? 'assistant' : 'user',
              'content': tour.contenu,
              'components': tour.composants
                  .map(
                    (component) => {
                      'type': component.type,
                      'data': component.data,
                    },
                  )
                  .toList(),
            },
          )
          .toList(),
    };
    unawaited(widget.api.remember('/conversations/$id', body));
    unawaited(widget.api.remember('/conversations/last', body));
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
    final navigation = _navigation;
    setState(() {
      _charge = true;
      _reponseCommencee = false;
    });
    final reponse = await requete();
    if (!mounted || navigation != _navigation) return;

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
      final peutRemplacer =
          remplaceLeDernier &&
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

    if (!remplaceLeDernier &&
        !(_tours.length == 1 &&
            _tours.first.composants.any(
              (component) => component.type == 'category_grid',
            ))) {
      _versLeBas();
    }
  }

  /// Deux tours montrent-ils le même composant ?
  static bool _memeNature(_Tour a, _Tour b) {
    if (a.composants.isEmpty || b.composants.isEmpty) return false;
    return a.composants.first.type == b.composants.first.type;
  }

  /// Parle à l'assistant. Texte libre ou interaction à interpréter.
  Future<void> _parler({
    String? texte,
    Map<String, dynamic>? interaction,
  }) async {
    final navigation = _navigation;
    setState(() => _charge = true);
    final index = _tours.length;
    var partialText = '';
    List<TovoComponent> partialComponents = [];
    final response = await widget.api.chat(
      {
        'client_message_id': _nouvelIdentifiant(),
        if (_conversationId != null) 'conversation_id': _conversationId,
        if (texte != null) 'text': texte,
        if (interaction != null) 'interaction': interaction,
        if (_position != null)
          'context': {'lat': _position!.$1, 'lng': _position!.$2},
      },
      onEvent: (event) {
        if (!mounted || navigation != _navigation) return;
        final follow =
            !_scroll.hasClients || _scroll.position.extentAfter < 160;
        setState(() {
          if (event['conversation_id'] is String) {
            _conversationId = event['conversation_id'] as String;
          }
          if (event['type'] == 'text_start') partialText = '';
          if (event['type'] == 'text') {
            partialText += event['text'] as String? ?? '';
          }
          if (event['type'] == 'results') {
            partialComponents = (event['components'] as List? ?? [])
                .whereType<Map<String, dynamic>>()
                .map(TovoComponent.fromJson)
                .toList();
          }
          if (partialText.isNotEmpty || partialComponents.isNotEmpty) {
            _reponseCommencee = true;
          }
          if (partialText.isNotEmpty || partialComponents.isNotEmpty) {
            final tour = _Tour(
              deLAssistant: true,
              contenu: partialText,
              composants: partialComponents,
            );
            if (_tours.length == index) {
              _tours.add(tour);
            } else {
              _tours[index] = tour;
            }
          }
        });
        if (follow) _versLeBas(animate: false);
      },
    );
    if (!mounted || navigation != _navigation) return;
    setState(() {
      _charge = false;
      _reponseCommencee = false;
      final tour = _Tour(
        deLAssistant: true,
        contenu: response.content,
        composants: response.components,
        enErreur: !response.ok,
      );
      if (_tours.length == index) {
        _tours.add(tour);
      } else {
        _tours[index] = tour;
      }
      if (response.raw['conversation_id'] is String) {
        _conversationId = response.raw['conversation_id'] as String;
      }
    });
    if (response.ok) _rememberConversation();
    _versLeBas();
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
  ///
  /// Le maintien enfoncé a été retiré, pour deux raisons.
  ///
  /// La première est un défaut : dès que l'enregistrement commençait, la
  /// barre de saisie était remplacée par l'affichage d'écoute — et le
  /// détecteur de geste disparaissait de l'arbre avec elle. Le relâchement
  /// n'atteignait donc plus personne : l'enregistrement continuait jusqu'à
  /// la limite de durée, et l'application semblait figée.
  ///
  /// La seconde tient à l'usage : parler longtemps le doigt collé à l'écran
  /// est pénible, et impossible si l'on veut faire autre chose en même
  /// temps. Deux appuis coûtent un geste de plus et rendent la main.
  Future<void> _toucherLeMicro() async {
    if (_charge || _transcribing || _voiceAction) return;
    _voiceAction = true;
    final generation = _voiceGeneration;
    try {
      if (_enregistreLaVoix) {
        await _envoyerLaParole();
      } else {
        _navigation++;
        await _demarrerLaParole(generation);
      }
    } on Exception {
      await _annulerLaParole();
      if (!mounted) return;
      _messageAssistant(
        "L'enregistrement n'a pas abouti. Réessayez ou écrivez votre demande.",
        enErreur: true,
      );
    } finally {
      _voiceAction = false;
    }
  }

  void _messageAssistant(String texte, {bool enErreur = false}) {
    setState(() {
      _tours.add(_Tour(deLAssistant: true, contenu: texte, enErreur: enErreur));
    });
    _versLeBas();
  }

  Future<void> _demarrerLaParole(int generation) async {
    // L'autorisation est réglée par l'appui court : si elle manque encore,
    // on ne l'ouvre pas ici, on explique. Ouvrir la boîte de dialogue
    // pendant l'appui long laisserait un enregistrement orphelin.
    if (!await VoixTovo.autorisation()) {
      if (!mounted || generation != _voiceGeneration) return;
      _messageAssistant(
        "Je n'ai pas accès au micro. Autorisez-le dans les réglages du "
        'téléphone, ou écrivez votre demande.',
        enErreur: true,
      );
      return;
    }

    if (!mounted || generation != _voiceGeneration) return;
    final autorise = await VoixTovo.demarrer();
    if (!mounted || generation != _voiceGeneration) {
      await VoixTovo.annuler();
      return;
    }

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

    _minuterieParole = Timer(VoixTovo.dureeMax, () {
      if (mounted && _enregistreLaVoix) unawaited(_toucherLeMicro());
    });
  }

  Future<void> _envoyerLaParole() async {
    if (!_enregistreLaVoix) return;
    final generation = _voiceGeneration;
    _minuterieParole?.cancel();

    final duree = DateTime.now().difference(_debutParole ?? DateTime.now());
    setState(() => _enregistreLaVoix = false);

    // Trop court pour contenir une phrase. Avec le maintien enfoncé, c'était
    // un geste manqué qu'on ignorait en silence ; avec deux appuis, c'est
    // quelqu'un qui a appuyé deux fois de suite — et qui doit savoir
    // pourquoi rien n'est parti, sinon il recommence à l'identique.
    if (duree < VoixTovo.dureeMin) {
      await VoixTovo.annuler();
      if (!mounted || generation != _voiceGeneration) return;
      _messageAssistant(
        "C'était trop court. Appuyez, parlez, puis appuyez à nouveau.",
      );
      return;
    }

    final audio = await VoixTovo.arreter();
    if (!mounted || generation != _voiceGeneration) return;
    if (audio == null) {
      _messageAssistant(
        "Je n'ai pas reçu de son. Réessayez ou écrivez votre demande.",
      );
      return;
    }

    unawaited(HapticFeedback.lightImpact());
    _pendingAudio = {'mime': audio.mime, 'data': audio.data};
    unawaited(_transcribeVoice());
  }

  Future<void> _transcribeVoice() async {
    if (_transcribing || _pendingAudio == null) return;
    final navigation = _navigation;
    setState(() {
      _transcribing = true;
      _voiceError = null;
    });
    final response = await widget.api.post('/transcriptions', {
      'audio': _pendingAudio,
    });
    if (!mounted || navigation != _navigation) return;
    final transcript = response.raw['transcript'];
    setState(() {
      _transcribing = false;
      if (response.ok && transcript is String && transcript.trim().isNotEmpty) {
        _saisie.text = [
          _saisie.text.trim(),
          transcript.trim(),
        ].where((part) => part.isNotEmpty).join(' ');
        _saisie.selection = TextSelection.collapsed(
          offset: _saisie.text.length,
        );
        _voiceDraft = true;
        _pendingAudio = null;
      } else {
        _voiceError = response.statusCode == 404
            ? 'La transcription nécessite la mise à jour du serveur.'
            : response.content;
      }
    });
  }

  Future<void> _annulerLaParole() async {
    _voiceGeneration++;
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
    if (p != null && mounted) {
      setState(() => _position = (p.latitude, p.longitude));
    }
  }

  void _ajouterTourUtilisateur(String texte, {String? photoLocale}) {
    setState(
      () => _tours.add(
        _Tour(deLAssistant: false, contenu: texte, photoLocale: photoLocale),
      ),
    );
    _versLeBas();
  }

  void _versLeBas({bool animate = true}) {
    if (_scrollScheduled) return;
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (!_scroll.hasClients) return;
      if (animate) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      } else {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  // ------------------------------------------------------------------
  // Interactions
  // ------------------------------------------------------------------

  void _interaction(TovoInteraction interaction) {
    if (_charge || _transcribing || _enregistreLaVoix || _voiceAction) return;
    _navigation++;
    final p = interaction.payload;

    switch (interaction.action) {
      // --- déterministe : REST, sans modèle -------------------------
      // Une catégorie mène aux BOUTIQUES, pas à un tas de produits.
      // « Restaurants » regroupe 31 enseignes : en déverser les plats
      // mélangés ne correspond ni à la structure des données ni à la façon
      // dont on choisit — on décide d'abord où, puis quoi.
      case 'select_category':
        _ouvrirCatalogue(
          merchantId: p['merchant_id'] as String?,
          categoryId: p['category_id'] as String?,
          directory: p['merchant_id'] == null,
        );

      case 'browse_catalog':
        _ouvrirCatalogue(
          merchantId: p['merchant_id'] as String?,
          merchantIds:
              (p['merchant_ids'] as List?)?.whereType<String>().toList() ??
              const [],
          categoryId: p['category_id'] as String?,
          query: p['query'] as String? ?? '',
        );

      case 'select_product':
        _ouvrirProduit(
          '${p['product_id']}',
          p['product'] as Map<String, dynamic>?,
        );

      case 'add_to_cart':
        _appeler(
          () => widget.api.post('/cart/items', {
            'product_id': p['product_id'],
            'quantity': p['quantity'] ?? 1,
            'selections': p['selections'] ?? const [],
          }),
        );

      // Ces trois gestes changent un panier déjà à l'écran : ils le
      // mettent à jour sur place au lieu d'en empiler une copie plus bas.
      case 'update_qty':
        _appeler(
          () => widget.api.patch('/cart/items/${p['item_id']}', {
            'quantity': p['quantity'],
          }),
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
        _ouvrirCatalogue(
          merchantId: p['merchant_id'] as String?,
          query: p['query'] as String? ?? '',
        );

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
          '${p['source']}' == 'camera'
              ? ImageSource.camera
              : ImageSource.gallery,
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

  /// Rattrape une photo prise juste avant qu'Android ne tue l'application.
  ///
  /// L'appareil photo est une activité séparée, et quand la mémoire manque —
  /// le cas courant sur un téléphone d'entrée de gamme — le système détruit
  /// Tovo pendant qu'elle est au premier plan. Au retour, l'application
  /// redémarre : elle rouvre une conversation et la photo qu'on venait de
  /// confirmer n'arrive nulle part. C'est très exactement ce qu'on observait
  /// — « ça recharge sur une autre conversation et ne fait rien d'autre ».
  ///
  /// Android garde le fichier de côté ; encore faut-il le réclamer.
  Future<void> _recupererPhotoPerdue() async {
    try {
      final perdue = await ImagePicker().retrieveLostData();
      final fichier = perdue.file;
      if (fichier == null || !mounted) return;
      await _envoyerLaPhoto(fichier);
    } on Exception catch (cause) {
      debugPrint('[chat] photo perdue non récupérée : $cause');
    }
  }

  /// Laisse choisir entre l'appareil photo et la galerie.
  ///
  /// Le bouton menait droit à l'appareil photo. Or cadrer un produit d'une
  /// main, dans une boutique, est souvent raté — alors que la photo existe
  /// déjà dans la galerie, ou peut être prise tranquillement avec
  /// l'application appareil photo habituelle, qui a la mise au point et la
  /// stabilisation du constructeur.
  Future<void> _choisirLaSource() async {
    if (_charge || _transcribing || _enregistreLaVoix || _voiceAction) return;
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (contexte) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Chercher par photo',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
            ListTile(
              leading: const Icon(
                Icons.photo_camera_outlined,
                color: TovoTheme.teal,
              ),
              title: const Text('Prendre une photo'),
              onTap: () => Navigator.of(contexte).pop(ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(
                Icons.photo_library_outlined,
                color: TovoTheme.teal,
              ),
              title: const Text('Choisir dans la galerie'),
              onTap: () => Navigator.of(contexte).pop(ImageSource.gallery),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (source == null || !mounted) return;
    await _chercherParPhoto(source);
  }

  Future<void> _chercherParPhoto(ImageSource source) async {
    final navigation = ++_navigation;
    final fichier = await ImagePicker().pickImage(
      source: source,
      // Compression avant l'envoi : une photo brute de 4 Mo depuis Niamey
      // prend une minute et consomme le forfait de l'utilisateur. 1024 px
      // suffisent largement à reconnaître un produit.
      maxWidth: 1024,
      imageQuality: 75,
    );
    if (fichier == null || !mounted || navigation != _navigation) return;
    await _envoyerLaPhoto(fichier);
  }

  /// Téléverse la photo et la soumet à l'assistant.
  ///
  /// Séparé du choix de l'image pour que la récupération après redémarrage
  /// emprunte exactement le même chemin : deux chemins d'envoi divergeraient
  /// au premier correctif.
  Future<void> _envoyerLaPhoto(XFile fichier) async {
    final navigation = ++_navigation;
    _ajouterTourUtilisateur('📷 Photo envoyée', photoLocale: fichier.path);
    setState(() => _charge = true);

    try {
      final utilisateur = Supabase.instance.client.auth.currentUser;
      if (utilisateur == null) throw Exception('session absente');

      // Convention imposée par les policies Storage : le premier segment est
      // l'identifiant de l'utilisateur. Chacun n'écrit que chez soi.
      final chemin = '${utilisateur.id}/${_nouvelIdentifiant()}.jpg';

      await Supabase.instance.client.storage
          .from('search-images')
          .uploadBinary(
            chemin,
            await fichier.readAsBytes(),
            fileOptions: const FileOptions(contentType: 'image/jpeg'),
          );

      if (!mounted || navigation != _navigation) return;
      setState(() => _charge = false);

      // Seul le CHEMIN part vers l'assistant. Les octets de l'image
      // n'entrent jamais dans le contexte du modèle : ils y resteraient à
      // chaque tour, pour toujours.
      await _parler(
        interaction: {
          'action': 'search_by_image',
          'payload': {'image_path': chemin},
        },
      );
    } on Exception catch (cause) {
      if (!mounted || navigation != _navigation) return;
      setState(() {
        _charge = false;
        _tours.add(
          _Tour(
            deLAssistant: true,
            contenu: "L'envoi de la photo a échoué. Vérifiez votre réseau.",
            enErreur: true,
          ),
        );
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
    final destination = await _choisirDestination(
      adresseChoisie: adresseChoisie,
    );
    if (!mounted || destination == null) return;

    final paiement = await _choisirPaiement();
    if (!mounted || paiement == null) return;
    if (!await _confirmerCommande(destination, paiement) || !mounted) return;

    // Le geste qui engage de l'argent mérite un retour franc.
    unawaited(HapticFeedback.mediumImpact());
    _idCommandeEnCours ??= _nouvelIdentifiant();

    await _appeler(
      () => widget.api.post('/orders', {
        'type': 'delivery',
        'client_order_id': _idCommandeEnCours,
        'dropoff_hint': destination.repere,
        'dropoff': {'lat': destination.lat, 'lng': destination.lng},
        'payment_method': paiement,
      }),
    );

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
      final connue = connues
          .where((a) => a['id'] == adresseChoisie)
          .firstOrNull;
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
    unawaited(
      widget.api.post('/addresses', {
        'label': _libelleDepuisRepere(repere),
        'text_hint': repere,
        'lat': position.latitude,
        'lng': position.longitude,
      }),
    );

    return _Destination(
      repere: repere,
      lat: position.latitude,
      lng: position.longitude,
    );
  }

  /// Un nom d'adresse tiré de ce que le client a écrit.
  ///
  /// Toute nouvelle adresse était enregistrée sous le libellé littéral
  /// « Adresse ». Trois adresses donnaient donc trois boutons « Livrer à
  /// Adresse » rigoureusement identiques, et le choix se faisait au hasard —
  /// avec une commande livrée au mauvais endroit à la clé.
  ///
  /// Le premier segment du repère suffit à distinguer : « Yantala, derrière
  /// la pharmacie Al Nour » devient « Yantala ».
  static String _libelleDepuisRepere(String repere) {
    final premier = repere.split(RegExp(r'[,;·]')).first.trim();
    final court = premier.isEmpty ? repere.trim() : premier;
    if (court.isEmpty) return 'Adresse';
    return court.length > 24 ? '${court.substring(0, 23).trimRight()}…' : court;
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
                  a['is_default'] == true
                      ? Icons.home_rounded
                      : Icons.place_outlined,
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
  Future<bool> _confirmerCommande(
    _Destination destination,
    String paiement,
  ) async {
    final response = await widget.api.get(
      '/cart',
      query: {'lat': destination.lat, 'lng': destination.lng},
    );
    if (!mounted) return false;
    final cart = response.components
        .where((component) => component.type == 'cart_summary')
        .firstOrNull;
    if (!response.ok || cart == null || !cart.flag('can_checkout')) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            !response.ok
                ? response.content
                : cart?.str(
                        'blocked_reason',
                        'Votre panier ne peut pas être commandé.',
                      ) ??
                      'Votre panier est vide.',
          ),
        ),
      );
      return false;
    }
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.68,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ListView(
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Tout est prêt.',
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.8,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Annuler la confirmation',
                            onPressed: () => Navigator.pop(sheetContext, false),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Text(
                        cart.str('merchant_name'),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        'Livrer à',
                        style: TextStyle(
                          fontSize: 12,
                          color: TovoTheme.inkDoux,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        destination.repere,
                        style: const TextStyle(fontSize: 15),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'Paiement',
                        style: TextStyle(
                          fontSize: 12,
                          color: TovoTheme.inkDoux,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        paiement == 'cash' ? 'Espèces à la livraison' : 'Nita',
                        style: const TextStyle(fontSize: 15),
                      ),
                      const SizedBox(height: 24),
                      for (final amount in [
                        ('Articles', cart.money('items_total')),
                        ('Livraison', cart.money('delivery_fee')),
                        if (cart.money('discount') > 0)
                          ('Réduction', -cart.money('discount')),
                      ])
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 7),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  amount.$1,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    color: TovoTheme.inkDoux,
                                  ),
                                ),
                              ),
                              Text(
                                Money.format(amount.$2),
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Total',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Text(
                        Money.format(cart.money('total')),
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(sheetContext, true),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Text('Confirmer la commande'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return confirmed == true;
  }

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
              leading: const Icon(
                Icons.payments_outlined,
                color: TovoTheme.teal,
              ),
              title: const Text('Espèces'),
              subtitle: const Text('Vous payez le livreur à l’arrivée'),
              onTap: () => Navigator.pop(context, 'cash'),
            ),
            ListTile(
              leading: const Icon(
                Icons.phone_iphone_rounded,
                color: TovoTheme.teal,
              ),
              title: const Text('Nita'),
              subtitle: const Text(
                'Un code à régler depuis MYNITA, ou payez au livreur',
              ),
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

    await _appeler(
      () => widget.api.post('/orders', {
        'type': 'courier',
        'client_order_id': _idCommandeEnCours,
        'pickup_hint': depart!['hint'],
        'pickup': {'lat': depart['lat'], 'lng': depart['lng']},
        'dropoff_hint': arrivee!['hint'],
        'dropoff': {'lat': arrivee['lat'], 'lng': arrivee['lng']},
        // Sans lui le serveur refuse : c'est par ce numéro que le livreur
        // joint le destinataire une fois sur place.
        'dropoff_contact': p['dropoff_contact'] ?? '',
        'parcel': p['parcel'] ?? 'small',
        'payment_method': paiement,
      }),
    );

    _idCommandeEnCours = null;
  }

  void _erreurLocalisation() {
    setState(() {
      _tours.add(
        _Tour(
          deLAssistant: true,
          contenu:
              "Je ne peux pas livrer sans savoir où vous êtes. "
              "Activez la localisation, puis réessayez.",
          enErreur: true,
        ),
      );
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
            // Dire lequel des deux fait foi.
            //
            // Le point GPS enregistré est celui où se trouve le téléphone
            // MAINTENANT — c'est lui qui guide le livreur, le texte n'étant
            // qu'un appoint. Quelqu'un qui commande depuis son bureau pour
            // une livraison chez lui envoyait donc le livreur au bureau, sans
            // que rien ne le prévienne. Tant qu'il n'y a pas de carte pour
            // désigner un autre point, il faut au moins le dire.
            helperText:
                'Repère pour le livreur. Le point GPS enregistré est '
                'celui où vous êtes en ce moment.',
            helperMaxLines: 3,
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
    if (_charge ||
        _transcribing ||
        _enregistreLaVoix ||
        _voiceAction ||
        _loadingHistory) {
      return;
    }
    unawaited(HapticFeedback.selectionClick());
    final texte = _saisie.text.trim();
    if (texte.isEmpty) return;
    _navigation++;
    _voiceDraft = false;
    _voiceError = null;
    _pendingAudio = null;
    _saisie.clear();
    _ajouterTourUtilisateur(texte);
    _rafraichirPosition();
    unawaited(_chercherPuisDemander(texte));
  }

  void _envoyerSuggestion(String texte) {
    _saisie.text = texte;
    _envoyer();
  }

  Future<void> _ouvrirProduit(String id, Map<String, dynamic>? product) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ProductScreen(
          api: widget.api,
          productId: id,
          initialProduct: product ?? const {},
        ),
      ),
    );
  }

  Future<void> _ouvrirPanier() async {
    if (_charge || _transcribing || _enregistreLaVoix || _voiceAction) return;
    _navigation++;
    final checkout = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => CartScreen(api: widget.api)),
    );
    if (mounted && checkout == true) await _commander();
  }

  Future<void> _ouvrirCatalogue({
    String? merchantId,
    List<String> merchantIds = const [],
    String? categoryId,
    String query = '',
    bool directory = false,
  }) async {
    final checkout = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CatalogScreen(
          api: widget.api,
          merchantId: merchantId,
          merchantIds: merchantIds,
          categoryId: categoryId,
          query: query,
          directory: directory,
        ),
      ),
    );
    if (mounted && checkout == true) {
      await _commander();
    }
  }

  Future<void> _chercherPuisDemander(String texte) => _parler(texte: texte);

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

  /// Ouvre une conversation enregistrée.
  Future<void> _ouvrirConversation(String id) async {
    final navigation = ++_navigation;
    unawaited(_annulerLaParole());
    setState(() {
      _tours.clear();
      _saisie.clear();
      _loadingHistory = true;
      _charge = false;
      _conversationId = id;
      _transcribing = false;
      _voiceDraft = false;
      _voiceError = null;
      _pendingAudio = null;
    });
    final request = widget.api.get('/conversations/$id');
    final cached = await widget.api.cachedGet('/conversations/$id');
    if (!mounted || navigation != _navigation) return;
    if (cached != null) {
      _showHistory(cached);
      setState(() => _loadingHistory = false);
    }
    final response = await request;
    if (!mounted || navigation != _navigation) return;
    setState(() => _loadingHistory = false);
    if (response.ok) {
      _showHistory(response);
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(response.content)));
    }
  }

  /// Repart de zéro.
  ///
  /// On oublie simplement l'identifiant : la conversation précédente reste
  /// en base et dans le tiroir. Le prochain message en ouvrira une nouvelle
  /// côté serveur.
  Future<void> _nouvelleConversation() async {
    final navigation = ++_navigation;
    setState(() {
      _tours.clear();
      _loadingHistory = false;
      _conversationId = null;
      _charge = false;
      _saisie.clear();
      _transcribing = false;
      _voiceDraft = false;
      _voiceError = null;
      _pendingAudio = null;
    });
    unawaited(_annulerLaParole());
    final cached = await widget.api.cachedGet('/categories');
    if (!mounted || navigation != _navigation) return;
    if (cached != null) _showCategories(cached);
    final response = await widget.api.get('/categories');
    if (!mounted || navigation != _navigation) return;
    if (response.ok) _showCategories(response);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      drawer: TiroirConversations(
        api: widget.api,
        conversationCourante: _conversationId,
        onOuvrir: (id) => unawaited(_ouvrirConversation(id)),
        onNouvelle: _nouvelleConversation,
      ),
      appBar: AppBar(
        // Les trois traits, et rien d'autre.
        //
        // J'avais mis une icône de conversation, en me disant qu'elle
        // annoncerait mieux ce qu'il y a derrière. C'était une erreur : le
        // menu à trois traits est le seul symbole que tout le monde
        // reconnaît sans y penser, et ce qu'on gagne à être explicite ne
        // vaut pas ce qu'on perd en habitude.
        leading: Builder(
          builder: (context) => IconButton(
            tooltip: 'Mes conversations',
            icon: const Icon(Icons.menu_rounded, size: 25),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        leadingWidth: 52,
        centerTitle: true,
        title: SvgPicture.asset(
          'assets/branding/tovo-logo.svg',
          width: 88,
          height: 28,
        ),
        actions: [
          IconButton(
            tooltip: 'Mon panier',
            icon: const Icon(Icons.shopping_bag_outlined, size: 23),
            onPressed: _ouvrirPanier,
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Builder(
              builder: (context) {
                if (_loadingHistory && _tours.isEmpty) {
                  return const ReadPlaceholder();
                }
                final afficheAccueil =
                    _tours.isEmpty ||
                    (_tours.length == 1 &&
                        _tours.first.deLAssistant &&
                        _tours.first.composants.any(
                          (component) => component.type == 'category_grid',
                        ));
                final decalage = afficheAccueil ? 1 : 0;

                return ListView.builder(
                  controller: _scroll,
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.only(bottom: 18),
                  itemCount: _tours.length + decalage,
                  itemBuilder: (context, i) {
                    if (afficheAccueil && i == 0) {
                      return _AccueilNouveau(
                        prenom: _prenom,
                        onSuggestion: _envoyerSuggestion,
                        onCamera: () => unawaited(_choisirLaSource()),
                      );
                    }

                    final tourIndex = i - decalage;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: IgnorePointer(
                        ignoring: _charge && tourIndex == _tours.length - 1,
                        child: _TourVue(
                          key: ValueKey('$_navigation:$tourIndex'),
                          tour: _tours[tourIndex],
                          onInteraction: _interaction,
                          anime: !_charge && tourIndex == _tours.length - 1,
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          // Un trait de progression ne dit rien de ce qui se passe. Trois
          // points qui respirent disent « je réfléchis », ce qui est la
          // vérité et ce que le client comprend sans y penser.
          AnimatedSize(
            duration: TovoTheme.normal,
            curve: TovoTheme.courbe,
            child: _charge && !_reponseCommencee
                ? const _EnReflexion()
                : const SizedBox.shrink(),
          ),
          if (_transcribing || _voiceError != null || _voiceDraft)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _transcribing
                          ? 'Transcription en cours…'
                          : _voiceError ??
                                'Vocal transcrit · modifiez puis envoyez',
                      style: TextStyle(
                        fontSize: 12,
                        color: _voiceError == null
                            ? TovoTheme.muted
                            : TovoTheme.danger,
                      ),
                    ),
                  ),
                  if (_voiceError != null && _pendingAudio != null)
                    TextButton(
                      onPressed: _transcribeVoice,
                      child: const Text('Réessayer'),
                    ),
                  if (_transcribing || _voiceError != null)
                    IconButton(
                      tooltip: 'Annuler la transcription',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        _navigation++;
                        setState(() {
                          _transcribing = false;
                          _voiceError = null;
                          _pendingAudio = null;
                        });
                      },
                    ),
                ],
              ),
            ),
          _BarreDeSaisieNouveau(
            controller: _saisie,
            onSend: _envoyer,
            onCamera: () => unawaited(_choisirLaSource()),
            enregistre: _enregistreLaVoix,
            onParoleTouche: _toucherLeMicro,
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
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
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
                  width: 5,
                  height: 5,
                  margin: const EdgeInsets.only(right: 4),
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
      if (mounted) {
        setState(() {
          _opacite = 1;
          _decalage = 0;
        });
      }
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
      final photo = tour.photoLocale;

      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 18, left: 54),
          padding: photo == null
              ? const EdgeInsets.symmetric(horizontal: 16, vertical: 12)
              : const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: const Color(0xFFF0F2F2),
            borderRadius: BorderRadius.circular(
              22,
            ).copyWith(bottomRight: const Radius.circular(7)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (photo != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(17),
                  child: Image.file(
                    File(photo),
                    width: 168,
                    fit: BoxFit.cover,
                    // Le fichier peut avoir disparu — Android nettoie ses
                    // caches. On retombe alors sur le texte seul plutôt que
                    // sur une icône d'image cassée.
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              Padding(
                padding: photo == null
                    ? EdgeInsets.zero
                    : const EdgeInsets.fromLTRB(8, 6, 8, 2),
                child: Text(
                  tour.contenu,
                  style: const TextStyle(
                    fontSize: 15,
                    color: TovoTheme.ink,
                    height: 1.45,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final widgets = ComponentRegistry.buildAll(tour.composants, onInteraction);

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (tour.contenu.isNotEmpty)
            Container(
              margin: EdgeInsets.only(bottom: widgets.isEmpty ? 0 : 14, top: 2),
              padding: tour.enErreur
                  ? const EdgeInsets.all(12)
                  : EdgeInsets.zero,
              decoration: tour.enErreur
                  ? BoxDecoration(
                      color: TovoTheme.coralSoft,
                      borderRadius: BorderRadius.circular(
                        TovoTheme.radiusSmall,
                      ),
                    )
                  : null,
              child: _TexteAssistant(
                tour.contenu,
                couleur: tour.enErreur ? TovoTheme.danger : TovoTheme.ink,
              ),
            ),
          for (final widget in widgets)
            Padding(padding: const EdgeInsets.only(bottom: 14), child: widget),
        ],
      ),
    );
  }
}

class _TexteAssistant extends StatelessWidget {
  const _TexteAssistant(this.texte, {required this.couleur});

  final String texte;
  final Color couleur;

  @override
  Widget build(BuildContext context) {
    final morceaux = <InlineSpan>[];
    final expression = RegExp(r'\*\*(.+?)\*\*', dotAll: true);
    var debut = 0;

    for (final correspondance in expression.allMatches(texte)) {
      if (correspondance.start > debut) {
        morceaux.add(
          TextSpan(text: texte.substring(debut, correspondance.start)),
        );
      }
      morceaux.add(
        TextSpan(
          text: correspondance.group(1),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      );
      debut = correspondance.end;
    }
    if (debut < texte.length) {
      morceaux.add(TextSpan(text: texte.substring(debut)));
    }

    return SelectableText.rich(
      TextSpan(children: morceaux),
      style: TextStyle(
        fontSize: 16,
        height: 1.55,
        fontWeight: FontWeight.w400,
        color: couleur,
      ),
    );
  }
}

/// Le point rouge de l'enregistrement, qui bat.
///
/// Un point fixe pourrait être un élément de décor. Un point qui pulse dit
/// que quelque chose tourne en ce moment — c'est la seule preuve que le micro
/// écoute, maintenant que le doigt ne reste plus posé dessus.
class _PointQuiBat extends StatefulWidget {
  const _PointQuiBat();

  @override
  State<_PointQuiBat> createState() => _PointQuiBatState();
}

class _PointQuiBatState extends State<_PointQuiBat>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(
        begin: 1,
        end: 0.25,
      ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut)),
      child: Container(
        width: 10,
        height: 10,
        decoration: const BoxDecoration(
          color: TovoTheme.danger,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// Le salut d'accueil.
///
/// Deux lignes, beaucoup d'air, et une hiérarchie franche : le nom en grand,
/// la question en gris. L'écran s'ouvrait jusqu'ici directement sur une
/// grille de tuiles — utile, mais qui ne s'adresse à personne.
class _AccueilNouveau extends StatelessWidget {
  const _AccueilNouveau({
    required this.prenom,
    required this.onSuggestion,
    required this.onCamera,
  });
  final String? prenom;
  final ValueChanged<String> onSuggestion;
  final VoidCallback onCamera;

  @override
  Widget build(BuildContext context) {
    final heure = DateTime.now().hour;
    final salut = heure >= 5 && heure < 17 ? 'Bonjour' : 'Bonsoir';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$salut${prenom == null ? '' : ', $prenom'}',
            style: const TextStyle(fontSize: 14, color: TovoTheme.inkDoux),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Expanded(
                child: Text(
                  'Votre envie,\nlivrée.',
                  style: TextStyle(
                    fontSize: 31,
                    height: 1.08,
                    letterSpacing: -1.1,
                    fontWeight: FontWeight.w700,
                    color: TovoTheme.ink,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ExcludeSemantics(
                child: Image.asset(
                  MediaQuery.disableAnimationsOf(context)
                      ? 'assets/branding/accueil-burger-statique.webp'
                      : 'assets/branding/accueil-burger-anime.webp',
                  width: 100,
                  height: 114,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: _SuggestionAccueil(
                  icon: Icons.local_shipping_outlined,
                  label: 'Envoyer un colis',
                  onTap: () => onSuggestion('Je veux envoyer un colis'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _SuggestionAccueil(
                  icon: Icons.center_focus_strong_rounded,
                  label: 'Trouver en photo',
                  onTap: onCamera,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SuggestionAccueil extends StatelessWidget {
  const _SuggestionAccueil({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xFFF5F6F6),
    borderRadius: BorderRadius.circular(14),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 15),
        child: Row(
          children: [
            Icon(icon, size: 20, color: TovoTheme.ink),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: TovoTheme.ink,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

// ignore: unused_element
class _Accueil extends StatelessWidget {
  const _Accueil({required this.prenom});

  final String? prenom;

  /// Le moment de la journée, à l'heure de Niamey.
  ///
  /// `DateTime.now()` suit le fuseau du téléphone, qui est le bon ici. Rien à
  /// convertir : c'est le client qui regarde, pas le serveur.
  String get _salut {
    final h = DateTime.now().hour;
    if (h < 5) return 'Bonsoir';
    if (h < 17) return 'Bonjour';
    return 'Bonsoir';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            prenom == null ? _salut : '$_salut $prenom',
            style: const TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w700,
              color: TovoTheme.teal,
              height: 1.15,
              // Les grandes tailles paraissent lâches au crénage par défaut ;
              // le resserrer très légèrement les rend nettes.
              letterSpacing: -0.8,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Que voulez-vous commander ?',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w500,
              color: TovoTheme.inkDoux,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _BarreDeSaisieNouveau extends StatelessWidget {
  const _BarreDeSaisieNouveau({
    required this.controller,
    required this.onSend,
    required this.onCamera,
    required this.enregistre,
    required this.onParoleTouche,
    required this.onParoleAnnulee,
  });

  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onCamera;
  final bool enregistre;
  final VoidCallback onParoleTouche;
  final VoidCallback onParoleAnnulee;

  Widget _action({
    Key? key,
    required IconData icon,
    required VoidCallback onTap,
    required String tooltip,
    bool principal = false,
  }) {
    return Tooltip(
      key: key,
      message: tooltip,
      child: Material(
        color: principal ? TovoTheme.ink : Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox.square(
            dimension: 44,
            child: Icon(
              icon,
              size: principal ? 20 : 19,
              color: principal ? Colors.white : TovoTheme.teal,
            ),
          ),
        ),
      ),
    );
  }

  Widget _enEcoute() {
    return Row(
      children: [
        _action(
          icon: Icons.close_rounded,
          onTap: onParoleAnnulee,
          tooltip: 'Annuler',
        ),
        const SizedBox(width: 12),
        const _PointQuiBat(),
        const SizedBox(width: 10),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Je vous écoute',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              Text(
                'Arrêtez pour relire votre message',
                style: TextStyle(fontSize: 10.5, color: TovoTheme.muted),
              ),
            ],
          ),
        ),
        _action(
          icon: Icons.stop_rounded,
          onTap: onParoleTouche,
          tooltip: 'Arrêter et transcrire',
          principal: true,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Container(
        constraints: const BoxConstraints(minHeight: 64),
        padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: TovoTheme.line),
        ),
        child: enregistre
            ? _enEcoute()
            : Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _action(
                    icon: Icons.add_rounded,
                    onTap: onCamera,
                    tooltip: 'Chercher avec une photo',
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      minLines: 1,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
                      textInputAction: TextInputAction.newline,
                      onSubmitted: (_) {
                        if (controller.text.trim().isNotEmpty) onSend();
                      },
                      decoration: const InputDecoration(
                        hintText: 'Demandez à Tovo…',
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 11,
                        ),
                      ),
                      style: const TextStyle(fontSize: 14.5, height: 1.35),
                    ),
                  ),
                  const SizedBox(width: 6),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: controller,
                    builder: (context, valeur, _) {
                      final aDuTexte = valeur.text.trim().isNotEmpty;
                      return _action(
                        icon: aDuTexte
                            ? Icons.arrow_upward_rounded
                            : Icons.mic_none_rounded,
                        onTap: aDuTexte ? onSend : onParoleTouche,
                        tooltip: aDuTexte ? 'Envoyer' : 'Parler à Tovo',
                        principal: true,
                      );
                    },
                  ),
                ],
              ),
      ),
    );
  }
}

// ignore: unused_element
class _BarreDeSaisie extends StatelessWidget {
  const _BarreDeSaisie({
    required this.controller,
    required this.onSend,
    required this.onCamera,
    required this.enregistre,
    required this.onParoleTouche,
    required this.onParoleAnnulee,
  });

  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onCamera;

  /// Vrai pendant l'enregistrement : la barre change entièrement d'aspect,
  /// sinon l'utilisateur ne sait pas que le micro l'écoute.
  final bool enregistre;

  /// Appuyer démarre l'enregistrement ; appuyer de nouveau l'envoie.
  final VoidCallback onParoleTouche;

  /// Renoncer à ce qui vient d'être dit.
  final VoidCallback onParoleAnnulee;

  /// Ce que voit l'utilisateur pendant qu'il parle.
  ///
  /// La barre change entièrement : sans signal clair, on ne sait pas si le
  /// micro écoute, et on relâche trop tôt ou on parle dans le vide.
  Widget _enEcoute() {
    return Row(
      children: [
        // Renoncer doit rester possible. Sans cette croix, la seule issue
        // était d'envoyer ce qu'on venait de dire, même en cas d'erreur.
        IconButton(
          tooltip: 'Annuler',
          onPressed: onParoleAnnulee,
          icon: const Icon(Icons.close_rounded, color: TovoTheme.muted),
        ),
        const _PointQuiBat(),
        const SizedBox(width: 10),
        const Expanded(
          child: Text(
            'Je vous écoute…',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
        // Le MÊME bouton qu'au repos, à la même place, qui a simplement
        // changé de sens : appuyer une fois démarre, appuyer une fois envoie.
        // Le déplacer ferait chercher le geste au moment de conclure.
        GestureDetector(
          onTap: onParoleTouche,
          child: Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(
              color: TovoTheme.teal,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.arrow_upward,
              size: 20,
              color: Colors.white,
            ),
          ),
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
        // Plus de trait de séparation : la barre se détache du fil par une
        // ombre très pâle, qui la fait flotter au-dessus au lieu de couper
        // l'écran en deux.
        decoration: const BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Color(0x0A000000),
              blurRadius: 16,
              offset: Offset(0, -4),
            ),
          ],
        ),
        child: enregistre
            ? _enEcoute()
            : Row(
                children: [
                  // La recherche par photo est ce que Tovo fait de mieux et que
                  // personne ne fait ici. Elle mérite un bouton permanent, pas
                  // d'être enfouie derrière une question de l'assistant.
                  IconButton(
                    onPressed: onCamera,
                    tooltip: 'Chercher par photo',
                    icon: const Icon(
                      Icons.photo_camera_outlined,
                      color: TovoTheme.teal,
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => onSend(),
                      decoration: InputDecoration(
                        // Le salut d'accueil pose déjà la question ; la répéter mot
                        // pour mot juste en dessous sonnait comme un bégaiement.
                        hintText: 'Demandez ce que vous cherchez…',
                        hintStyle: const TextStyle(
                          fontSize: 14,
                          color: TovoTheme.muted,
                        ),
                        filled: true,
                        fillColor: TovoTheme.bloc,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 14,
                        ),
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
                            child: const Icon(
                              Icons.arrow_upward,
                              size: 18,
                              color: Colors.white,
                            ),
                          ),
                        );
                      }

                      // Un appui démarre, un appui envoie. Le maintien enfoncé a
                      // été retiré : la barre changeant d'aspect au démarrage, le
                      // détecteur de geste disparaissait avec elle et le
                      // relâchement n'atteignait plus rien.
                      return GestureDetector(
                        onTap: onParoleTouche,
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: const BoxDecoration(
                            color: TovoTheme.teal,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.mic_none_rounded,
                            size: 20,
                            color: Colors.white,
                          ),
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
