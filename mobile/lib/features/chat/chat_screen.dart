import 'dart:async';
import 'dart:io' show File;
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as image_lib;
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../components/registry.dart';
import '../../components/widgets/read_placeholder.dart';
import '../../core/api.dart';
import '../../core/location.dart';
import '../../core/theme.dart';
import '../../core/viewport_reveal.dart';
import '../../core/voix.dart';
import 'assistant_activity_dock.dart';
import 'conversations_drawer.dart';
import 'conversation_chrome.dart';
import 'photo_capture_sheet.dart';
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
  bool _homeVisible = true;
  final List<Map<String, dynamic>> _recentConversations = [];
  final List<_Tour> _tours = [];
  final ScrollController _scroll = ScrollController();
  final TextEditingController _saisie = TextEditingController();
  bool _scrollScheduled = false;

  bool _charge = false;
  bool _reponseCommencee = false;
  String? _busyLabel;
  int? _focusedTourIndex;
  int? _selectedProductTourIndex;
  String? _selectedProductId;
  Map<String, dynamic>? _selectedProduct;
  bool _productAdded = false;
  final _productAnchorKey = GlobalKey();
  final _latestResponseKey = GlobalKey();
  String? _conversationId;
  int _navigation = 0;
  int _voiceGeneration = 0;
  bool _voiceAction = false;
  bool _loadingHistory = false;
  bool _transcribing = false;
  bool _voiceDraft = false;
  String? _voiceError;
  Map<String, dynamic>? _pendingAudio;
  XFile? _photoDraft;

  /// Conservé entre deux tentatives : un rejeu après coupure doit présenter
  /// le MÊME identifiant, sinon l'idempotence ne sert à rien.
  String? _idCommandeEnCours;

  bool _enregistreLaVoix = false;
  DateTime? _debutParole;
  Timer? _minuterieParole;

  /// Prénom du client, pour le salut d'accueil. Nul tant qu'on ne l'a pas.
  String? _prenom;

  /// Dernière commande livrée, pour la carte « Recommander » de l'accueil.
  /// Nulle s'il n'y en a pas : un nouveau client ne voit rien de vide.
  Map<String, dynamic>? _derniereCommande;

  /// Le client a choisi d'écrire : la box reste ouverte d'un message à
  /// l'autre (voir ConversationComposer.ecrit).
  bool _modeEcrit = false;

  AssistantActivity? get _activity {
    if (_enregistreLaVoix) return AssistantActivity.listening;
    if (_transcribing) return AssistantActivity.transcribing;
    if (_charge) {
      return _reponseCommencee
          ? AssistantActivity.answering
          : AssistantActivity.searching;
    }
    return null;
  }

  static bool _hasDiscoveryResults(List<TovoComponent> components) =>
      components.any(
        (component) => const {
          'product_carousel',
          'product_list',
          'product_card',
          'merchant_card',
          'price_comparison',
        }.contains(component.type),
      );

  void _closeFocusedResults() {
    if (_focusedTourIndex != null) {
      setState(() => _focusedTourIndex = null);
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_lirePrenom());
    unawaited(_demarrer());
  }

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
      final liste = ((commandes.raw['orders'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();
      enCours = liste.where((o) {
        final s = '${o['status']}';
        return s != 'delivered' && s != 'cancelled';
      }).firstOrNull;
      // Un colis ne se « recommande » pas : l'adresse et le destinataire
      // changent à chaque fois. Sans articles (serveur plus ancien), il n'y
      // aurait rien à montrer.
      final derniere = liste.where((o) {
        return '${o['status']}' == 'delivered' &&
            '${o['type']}' != 'courier' &&
            ((o['articles'] as List?)?.isNotEmpty ?? false);
      }).firstOrNull;
      if (derniere != null) setState(() => _derniereCommande = derniere);
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
      _trackRecent(id, messages.cast<Map<String, dynamic>>());
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
    _trackRecent(id, (body['messages'] as List).cast<Map<String, dynamic>>());
  }

  void _trackRecent(String id, List<Map<String, dynamic>> messages) {
    final first =
        messages.where((message) => message['role'] == 'user').firstOrNull ??
        messages.firstOrNull;
    final title = '${first?['content'] ?? ''}'.trim();
    _recentConversations.removeWhere(
      (conversation) => conversation['id'] == id,
    );
    _recentConversations.insert(0, {
      'id': id,
      'title': title.isEmpty ? 'Votre dernière discussion' : title,
    });
    if (_recentConversations.length > 8) _recentConversations.removeLast();
  }

  void _retourAccueil() {
    FocusScope.of(context).unfocus();
    setState(() {
      _homeVisible = true;
      _focusedTourIndex = null;
    });
  }

  Future<void> _ouvrirCommandes() async {
    final request = widget.api.get('/orders', query: {'limit': 20});
    final id = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.65,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text(
                  'Mes commandes',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                ),
              ),
              Expanded(
                child: FutureBuilder<TovoResponse>(
                  future: request,
                  builder: (context, snapshot) {
                    if (!snapshot.hasData && !snapshot.hasError) {
                      return const ReadPlaceholder();
                    }
                    final response = snapshot.data;
                    if (response == null || !response.ok) {
                      return const Center(
                        child: Text('Impossible de charger les commandes.'),
                      );
                    }
                    final orders = response.list('orders');
                    if (orders.isEmpty) {
                      return const Center(
                        child: Text('Vos commandes apparaîtront ici.'),
                      );
                    }
                    return ListView.builder(
                      itemCount: orders.length,
                      itemBuilder: (context, index) {
                        final order = orders[index];
                        final status = switch (order['status']) {
                          'delivered' => 'Livrée',
                          'cancelled' => 'Annulée',
                          'pending' => 'En attente',
                          'confirmed' => 'Confirmée',
                          'preparing' => 'En préparation',
                          'delivering' => 'En livraison',
                          _ => 'En cours',
                        };
                        return ListTile(
                          leading: const ConversationIcon(
                            ConversationSymbol.cart,
                          ),
                          title: Text('Commande ${index + 1}'),
                          subtitle: Text(status),
                          trailing: const ConversationIcon(
                            ConversationSymbol.forward,
                          ),
                          onTap: () => Navigator.pop(context, '${order['id']}'),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (id != null && mounted) {
      await _appeler(() => widget.api.get('/orders/$id'));
    }
  }

  Future<void> _copierConversation() async {
    await Clipboard.setData(
      ClipboardData(
        text: _tours
            .map((tour) => tour.contenu)
            .where((text) => text.isNotEmpty)
            .join('\n\n'),
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Conversation copiée')));
    }
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
      _homeVisible = false;
      _charge = true;
      _reponseCommencee = false;
      _busyLabel = 'Mise à jour…';
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
      _busyLabel = null;
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
    String? statusLabel,
  }) async {
    final navigation = _navigation;
    setState(() {
      _charge = true;
      _reponseCommencee = false;
      _busyLabel = statusLabel ?? 'Je cherche…';
    });
    final index = _tours.length;
    var responseAnchored = false;
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
        if (_hasDiscoveryResults(partialComponents)) {
          if (!responseAnchored) {
            responseAnchored = true;
            _montrerLeDebutDeLaReponse();
          }
        } else if (follow) {
          _versLeBas(animate: false);
        }
      },
    );
    if (!mounted || navigation != _navigation) return;
    setState(() {
      _charge = false;
      _reponseCommencee = false;
      _busyLabel = null;
      final components = response.ok && response.components.isEmpty
          ? partialComponents
          : response.components;
      final tour = _Tour(
        deLAssistant: true,
        contenu: response.content.isEmpty && response.ok
            ? partialText
            : response.content,
        composants: components,
        enErreur: !response.ok,
      );
      if (_tours.length == index) {
        _tours.add(tour);
      } else {
        _tours[index] = tour;
      }
      if (_focusedTourIndex == index) {
        _focusedTourIndex = null;
      }
      if (response.raw['conversation_id'] is String) {
        _conversationId = response.raw['conversation_id'] as String;
      }
    });
    if (response.ok) _rememberConversation();
    if (response.ok && _hasDiscoveryResults(_tours[index].composants)) {
      if (!responseAnchored) _montrerLeDebutDeLaReponse();
    } else {
      _versLeBas();
    }
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
        _closeFocusedResults();
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
      _homeVisible = false;
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
    final autoSend =
        response.ok &&
        transcript is String &&
        transcript.trim().isNotEmpty &&
        _saisie.text.trim().isEmpty &&
        _photoDraft == null &&
        !_loadingHistory;
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
        _voiceDraft = !autoSend;
        _pendingAudio = null;
      } else {
        _voiceError = response.statusCode == 404
            ? 'La transcription nécessite la mise à jour du serveur.'
            : response.content;
      }
    });
    if (autoSend) _envoyer();
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
  DateTime? _dernierRelevePosition;

  Future<void> _rafraichirPosition() async {
    final maintenant = DateTime.now();
    if (_dernierRelevePosition != null &&
        maintenant.difference(_dernierRelevePosition!) <
            const Duration(minutes: 5)) {
      return;
    }
    _dernierRelevePosition = maintenant;
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

  void _montrerLeDebutDeLaReponse() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final responseContext = _latestResponseKey.currentContext;
      if (responseContext == null) return;
      unawaited(
        Scrollable.ensureVisible(
          responseContext,
          duration: const Duration(milliseconds: 260),
          curve: TovoTheme.courbe,
          alignment: 0.06,
        ),
      );
    });
  }

  void _montrerLaFiche() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final productContext = _productAnchorKey.currentContext;
      if (productContext == null) return;
      unawaited(
        Scrollable.ensureVisible(
          productContext,
          duration: const Duration(milliseconds: 420),
          curve: TovoTheme.courbe,
          alignment: 0.08,
        ),
      );
    });
  }

  // ------------------------------------------------------------------
  // Interactions
  // ------------------------------------------------------------------

  void _interaction(TovoInteraction interaction, {int? sourceTourIndex}) {
    if (_transcribing || _enregistreLaVoix || _voiceAction) return;
    if (_charge) {
      final canOpenResult =
          _tours.isNotEmpty &&
          _hasDiscoveryResults(_tours.last.composants) &&
          const {
            'browse_catalog',
            'select_product',
            'select_category',
          }.contains(interaction.action);
      if (!canOpenResult) return;
      setState(() {
        _charge = false;
        _reponseCommencee = false;
        _busyLabel = null;
      });
    }
    _closeFocusedResults();
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
        if (sourceTourIndex == null) {
          _ouvrirProduit(
            '${p['product_id']}',
            p['product'] as Map<String, dynamic>?,
          );
        } else {
          setState(() {
            _selectedProductTourIndex = sourceTourIndex;
            _selectedProductId = '${p['product_id']}';
            _selectedProduct = p['product'] as Map<String, dynamic>?;
            _productAdded = false;
          });
        }

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
        _ouvrirPanier();

      case 'submit_courier':
        _envoyerColis(p);

      // La base décide (aucun livreur parti, rien d'encaissé) et renvoie un
      // motif lisible si elle refuse.
      case 'cancel_order':
        _appeler(
          () => widget.api.post('/orders/${p['order_id']}/cancel', const {}),
        );

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
        } else if (valeur.startsWith('vider_et_recommander:')) {
          _recommander(
            valeur.substring('vider_et_recommander:'.length),
            vider: true,
          );
        } else if (valeur == 'garder_panier') {
          _appeler(() => widget.api.get('/cart'));
        } else if (valeur.startsWith('adresse:')) {
          // L'assistant a proposé « je livre chez vous, à … ? » et le client
          // a répondu. Redemander la destination juste après serait lui
          // reposer la question à laquelle il vient de répondre.
          _ouvrirPanier(initialAddressId: valeur.substring('adresse:'.length));
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

  Future<void> _recupererPhotoPerdue() async {
    try {
      final perdue = await ImagePicker().retrieveLostData();
      final fichier = perdue.file;
      if (fichier == null || !mounted) return;
      setState(() => _photoDraft = fichier);
    } on Exception catch (cause) {
      debugPrint('[chat] photo perdue non récupérée : $cause');
    }
  }

  Future<void> _choisirLaSource() async {
    if (_charge || _transcribing || _enregistreLaVoix || _voiceAction) return;
    _closeFocusedResults();
    FocusScope.of(context).unfocus();
    await _chercherParPhoto(ImageSource.camera);
  }

  Future<void> _choisirDansLesPhotos() async {
    if (_charge || _transcribing || _enregistreLaVoix || _voiceAction) return;
    _closeFocusedResults();
    FocusScope.of(context).unfocus();
    await _chercherParPhoto(ImageSource.gallery);
  }

  Future<void> _chercherParPhoto(ImageSource source) async {
    final navigation = _navigation;
    XFile? fichier;
    try {
      fichier = source == ImageSource.camera
          ? await showModalBottomSheet<XFile>(
              context: context,
              isScrollControlled: true,
              backgroundColor: Colors.transparent,
              builder: (_) => const PhotoCaptureSheet(),
            )
          : await ImagePicker().pickImage(
              source: ImageSource.gallery,
              maxWidth: 1024,
              imageQuality: 75,
            );
    } on Exception {
      if (mounted && navigation == _navigation) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Impossible d’ouvrir vos photos. Vérifiez les autorisations de l’application.',
            ),
          ),
        );
      }
      return;
    }
    if (fichier == null || !mounted || navigation != _navigation) return;
    setState(() => _photoDraft = fichier);
  }

  Future<Uint8List> _octetsPhoto(XFile fichier) async {
    final octets = await fichier.readAsBytes();
    return Isolate.run(() {
      final decoded = image_lib.decodeImage(octets);
      if (decoded == null) return octets;
      final oriented = image_lib.bakeOrientation(decoded);
      final resized = oriented.width > 1024
          ? image_lib.copyResize(oriented, width: 1024)
          : oriented;
      return Uint8List.fromList(image_lib.encodeJpg(resized, quality: 75));
    });
  }

  Future<void> _envoyerLaPhoto(XFile fichier, String caption) async {
    final navigation = ++_navigation;
    final index = _tours.length;
    _ajouterTourUtilisateur(
      caption.isEmpty ? '📷 Photo envoyée' : '📷 $caption',
      photoLocale: fichier.path,
    );
    setState(() {
      _charge = true;
      _busyLabel = 'Analyse de la photo…';
    });

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
            await _octetsPhoto(fichier),
            fileOptions: const FileOptions(contentType: 'image/jpeg'),
          );

      if (!mounted || navigation != _navigation) return;

      // Seul le CHEMIN part vers l'assistant. Les octets de l'image
      // n'entrent jamais dans le contexte du modèle : ils y resteraient à
      // chaque tour, pour toujours.
      await _parler(
        statusLabel: 'Analyse de la photo…',
        interaction: {
          'action': 'search_by_image',
          'payload': {
            'image_path': chemin,
            if (caption.isNotEmpty) 'caption': caption,
          },
        },
      );
    } on Exception catch (cause) {
      if (!mounted || navigation != _navigation) return;
      setState(() {
        _charge = false;
        _busyLabel = null;
        _photoDraft = fichier;
        _saisie.text = caption;
        if (_tours.length > index &&
            _tours[index].photoLocale == fichier.path) {
          _tours.removeAt(index);
        }
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

    // Seule la position de départ est requise : c'est là que vient le
    // livreur, et il appelle le client pour le reste.
    if (depart?['lat'] == null) {
      _erreurLocalisation();
      return;
    }

    _idCommandeEnCours ??= _nouvelIdentifiant();

    // Le paiement est choisi sur la carte (espèces par défaut) : plus de
    // fenêtre à part entre le geste et la commande.
    await _appeler(
      () => widget.api.post('/orders', {
        'type': 'courier',
        'client_order_id': _idCommandeEnCours,
        'pickup_hint': depart!['hint'],
        'pickup': {'lat': depart['lat'], 'lng': depart['lng']},
        'dropoff_hint': p['dropoff_hint'] ?? arrivee?['hint'],
        if (arrivee?['lat'] != null)
          'dropoff': {'lat': arrivee!['lat'], 'lng': arrivee['lng']},
        'dropoff_contact': p['dropoff_contact'],
        'parcel': p['parcel'] ?? 'small',
        'payment_method': p['payment_method'] ?? 'cash',
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
    final photo = _photoDraft;
    if (texte.isEmpty && photo == null) return;
    if (_homeVisible) {
      _tours.clear();
      _conversationId = null;
      _homeVisible = false;
    }
    _closeFocusedResults();
    _selectedProductTourIndex = null;
    _selectedProductId = null;
    _selectedProduct = null;
    _productAdded = false;
    FocusScope.of(context).unfocus();
    _navigation++;
    _voiceDraft = false;
    _voiceError = null;
    _pendingAudio = null;
    _saisie.clear();
    if (photo != null) {
      setState(() => _photoDraft = null);
      unawaited(_envoyerLaPhoto(photo, texte));
      return;
    }
    _ajouterTourUtilisateur(texte);
    _rafraichirPosition();
    unawaited(_chercherPuisDemander(texte));
  }

  void _envoyerSuggestion(String texte) {
    _saisie.text = texte;
    _envoyer();
  }

  /// Remet une commande livrée au panier, sans passer par l'assistant : le
  /// geste dit déjà tout. En cas de panier d'une autre boutique, le serveur
  /// propose « Vider et recommander », qui revient ici avec [vider].
  void _recommander(String orderId, {bool vider = false}) {
    _appeler(
      () => widget.api.post('/cart/reorder', {
        'order_id': orderId,
        if (vider) 'vider': true,
      }),
    );
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

  Future<void> _ouvrirPanier({String? initialAddressId}) async {
    if (_charge || _transcribing || _enregistreLaVoix || _voiceAction) return;
    _navigation++;
    final cartPreview = _tours.lastOrNull?.composants
        .where((component) => component.type == 'cart_summary')
        .firstOrNull;
    final order = await Navigator.of(context).push<TovoResponse>(
      MaterialPageRoute(
        builder: (_) => CartScreen(
          api: widget.api,
          initialAddressId: initialAddressId,
          initialCart: cartPreview,
        ),
      ),
    );
    if (mounted && order != null) await _appeler(() async => order);
  }

  Future<void> _ouvrirCatalogue({
    String? merchantId,
    List<String> merchantIds = const [],
    String? categoryId,
    String query = '',
    bool directory = false,
  }) async {
    final order = await Navigator.of(context).push<TovoResponse>(
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
    if (mounted && order != null) await _appeler(() async => order);
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
      _homeVisible = false;
      _tours.clear();
      _saisie.clear();
      _loadingHistory = true;
      _charge = false;
      _busyLabel = null;
      _focusedTourIndex = null;
      _selectedProductTourIndex = null;
      _selectedProductId = null;
      _selectedProduct = null;
      _productAdded = false;
      _conversationId = id;
      _transcribing = false;
      _voiceDraft = false;
      _voiceError = null;
      _pendingAudio = null;
      _photoDraft = null;
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
      _homeVisible = true;
      _tours.clear();
      _loadingHistory = false;
      _conversationId = null;
      _charge = false;
      _busyLabel = null;
      _focusedTourIndex = null;
      _selectedProductTourIndex = null;
      _selectedProductId = null;
      _selectedProduct = null;
      _productAdded = false;
      _saisie.clear();
      _transcribing = false;
      _voiceDraft = false;
      _voiceError = null;
      _pendingAudio = null;
      _photoDraft = null;
    });
    unawaited(_annulerLaParole());
    final cached = await widget.api.cachedGet('/categories');
    if (!mounted || navigation != _navigation) return;
    if (cached != null) _showCategories(cached);
    final response = await widget.api.get('/categories');
    if (!mounted || navigation != _navigation) return;
    if (response.ok) _showCategories(response);
  }

  void _annulerTranscription() {
    _navigation++;
    setState(() {
      _transcribing = false;
      _voiceError = null;
      _pendingAudio = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final activity = _activity;
    final focusedIndex = _focusedTourIndex;
    final focusedTour = focusedIndex != null && focusedIndex < _tours.length
        ? _tours[focusedIndex]
        : null;
    final motionDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : TovoTheme.normal;
    final listening = activity == AssistantActivity.listening;
    return PopScope<void>(
      canPop: focusedTour == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closeFocusedResults();
      },
      child: ConversationBackdrop(
        home: _homeVisible,
        listening: listening,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          drawer: TiroirConversations(
            api: widget.api,
            conversationCourante: _conversationId,
            onOuvrir: (id) => unawaited(_ouvrirConversation(id)),
            onNouvelle: _nouvelleConversation,
            onPanier: _ouvrirPanier,
            onCatalogue: () => _ouvrirCatalogue(),
          ),
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            automaticallyImplyLeading: false,
            toolbarHeight: 72,
            titleSpacing: 18,
            title: Builder(
              builder: (context) => Row(
                children: [
                  ConversationControl(
                    symbol: ConversationSymbol.menu,
                    label: 'Mes conversations',
                    onPressed: () => Scaffold.of(context).openDrawer(),
                  ),
                  if (!_homeVisible) ...[
                    const SizedBox(width: 10),
                    ConversationSurface(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ConversationControl(
                            symbol: ConversationSymbol.back,
                            label: 'Accueil',
                            surface: false,
                            onPressed: _charge ? null : _retourAccueil,
                          ),
                          const ConversationControl(
                            symbol: ConversationSymbol.forward,
                            label: 'Suivant',
                            surface: false,
                          ),
                        ],
                      ),
                    ),
                  ],
                  const Spacer(),
                  ConversationSurface(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!_homeVisible)
                          ConversationControl(
                            symbol: ConversationSymbol.share,
                            label: 'Copier la conversation',
                            surface: false,
                            onPressed: _copierConversation,
                          ),
                        ConversationControl(
                          symbol: ConversationSymbol.bookmark,
                          label: 'Conversations enregistrées',
                          surface: false,
                          onPressed: () => Scaffold.of(context).openDrawer(),
                        ),
                        if (_homeVisible)
                          ConversationControl(
                            symbol: ConversationSymbol.calendar,
                            label: 'Mes commandes',
                            surface: false,
                            onPressed: _ouvrirCommandes,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          body: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    AnimatedOpacity(
                      duration: motionDuration,
                      opacity: focusedTour != null
                          ? 0.28
                          : listening ||
                                activity == AssistantActivity.transcribing
                          ? 0.8
                          : 1,
                      child: IgnorePointer(
                        ignoring: focusedTour != null,
                        child: ExcludeSemantics(
                          excluding: focusedTour != null,
                          child: Builder(
                            builder: (context) {
                              if (_homeVisible) {
                                return ConversationHome(
                                  firstName: _prenom,
                                  recent: _recentConversations,
                                  onResume: (id) {
                                    if (id == _conversationId &&
                                        _tours.isNotEmpty) {
                                      setState(() => _homeVisible = false);
                                      _versLeBas(animate: false);
                                    } else {
                                      unawaited(_ouvrirConversation(id));
                                    }
                                  },
                                  onSuggestion: _envoyerSuggestion,
                                  lastOrder: _derniereCommande,
                                  onReorder: (commande) {
                                    _ajouterTourUtilisateur(
                                      'Recommander ma commande'
                                      '${commande['merchant_name'] == null ? '' : ' chez ${commande['merchant_name']}'}',
                                    );
                                    _recommander('${commande['id']}');
                                  },
                                );
                              }
                              if (_loadingHistory && _tours.isEmpty) {
                                return const ReadPlaceholder();
                              }
                              return ListView.builder(
                                controller: _scroll,
                                keyboardDismissBehavior:
                                    ScrollViewKeyboardDismissBehavior.onDrag,
                                padding: EdgeInsets.only(
                                  bottom: _selectedProductId != null
                                      ? MediaQuery.sizeOf(context).height * 0.20
                                      : _productAdded
                                      ? 80
                                      : 18,
                                ),
                                itemCount: _tours.length,
                                itemBuilder: (context, i) {
                                  final tourIndex = i;
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 26,
                                    ),
                                    child: IgnorePointer(
                                      ignoring:
                                          _charge &&
                                          tourIndex == _tours.length - 1 &&
                                          !_hasDiscoveryResults(
                                            _tours[tourIndex].composants,
                                          ),
                                      child: _TourVue(
                                        key:
                                            tourIndex == _tours.length - 1 &&
                                                _tours[tourIndex].deLAssistant
                                            ? _latestResponseKey
                                            : ValueKey(tourIndex),
                                        tour: _tours[tourIndex],
                                        onInteraction: (interaction) =>
                                            _interaction(
                                              interaction,
                                              sourceTourIndex: tourIndex,
                                            ),
                                        anime: tourIndex == _tours.length - 1,
                                        shoppingStep:
                                            _hasDiscoveryResults(
                                              _tours[tourIndex].composants,
                                            )
                                            ? _selectedProductTourIndex ==
                                                      tourIndex
                                                  ? _productAdded
                                                        ? 2
                                                        : 1
                                                  : 0
                                            : null,
                                        productDetail:
                                            _selectedProductTourIndex ==
                                                    tourIndex &&
                                                _selectedProductId != null
                                            ? Container(
                                                key: _productAnchorKey,
                                                child: ProductScreen(
                                                  key: ValueKey(
                                                    _selectedProductId,
                                                  ),
                                                  api: widget.api,
                                                  productId:
                                                      _selectedProductId!,
                                                  initialProduct:
                                                      _selectedProduct ??
                                                      const {},
                                                  embedded: true,
                                                  onClose: () => setState(() {
                                                    _selectedProductTourIndex =
                                                        null;
                                                    _selectedProductId = null;
                                                    _selectedProduct = null;
                                                    _productAdded = false;
                                                  }),
                                                  onAdded: () => setState(
                                                    () => _productAdded = true,
                                                  ),
                                                ),
                                              )
                                            : null,
                                        selectedProductId: _selectedProductId,
                                        onProductExpanded: _montrerLaFiche,
                                        scanne:
                                            _charge &&
                                            tourIndex == _tours.length - 1 &&
                                            _tours[tourIndex].photoLocale !=
                                                null,
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: IgnorePointer(
                        ignoring: focusedTour == null,
                        child: AnimatedSwitcher(
                          duration: motionDuration,
                          switchInCurve: TovoTheme.courbe,
                          transitionBuilder: (child, animation) =>
                              FadeTransition(
                                opacity: animation,
                                child: SlideTransition(
                                  position: Tween<Offset>(
                                    begin: const Offset(0, 0.035),
                                    end: Offset.zero,
                                  ).animate(animation),
                                  child: child,
                                ),
                              ),
                          child: focusedTour == null
                              ? const SizedBox.shrink(
                                  key: ValueKey('discussion'),
                                )
                              : _FocusedResultView(
                                  key: ValueKey('resultats-$focusedIndex'),
                                  tour: focusedTour,
                                  onClose: _closeFocusedResults,
                                  onInteraction: _interaction,
                                ),
                        ),
                      ),
                    ),
                    if (_productAdded)
                      Positioned(
                        bottom: 12,
                        left: 16,
                        right: 16,
                        child: Center(
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: TovoTheme.teal,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: _ouvrirPanier,
                            icon: const Icon(Icons.shopping_bag_outlined),
                            label: const Text('Voir mon panier'),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (_voiceError != null || _voiceDraft)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _voiceError ??
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
                      if (_voiceError != null)
                        IconButton(
                          tooltip: 'Annuler la transcription',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: _annulerTranscription,
                        ),
                    ],
                  ),
                ),
              AnimatedContainer(
                duration: motionDuration,
                curve: TovoTheme.courbe,
                color: Colors.transparent,
                child: AnimatedSwitcher(
                  duration: motionDuration,
                  switchInCurve: TovoTheme.courbe,
                  child: activity == null
                      ? ConversationComposer(
                          key: const ValueKey('composer'),
                          controller: _saisie,
                          onSend: _envoyer,
                          onCamera: () => unawaited(_choisirLaSource()),
                          onGallery: () => unawaited(_choisirDansLesPhotos()),
                          photoPath: _photoDraft?.path,
                          onRemovePhoto: () =>
                              setState(() => _photoDraft = null),
                          onVoice: _toucherLeMicro,
                          ecrit: _modeEcrit,
                          onEcrit: (ecrit) => _modeEcrit = ecrit,
                        )
                      : AssistantActivityDock(
                          key: const ValueKey('activity'),
                          activity: activity,
                          label: activity == AssistantActivity.searching
                              ? _busyLabel
                              : null,
                          onPrimary: activity == AssistantActivity.listening
                              ? () => unawaited(_toucherLeMicro())
                              : null,
                          onCancel: activity == AssistantActivity.listening
                              ? () => unawaited(_annulerLaParole())
                              : activity == AssistantActivity.transcribing
                              ? _annulerTranscription
                              : null,
                        ),
                ),
              ),
            ],
          ),
        ),
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
    this.scanne = false,
    this.shoppingStep,
    this.productDetail,
    this.selectedProductId,
    this.onProductExpanded,
  });

  final _Tour tour;
  final InteractionCallback onInteraction;
  final int? shoppingStep;
  final Widget? productDetail;
  final String? selectedProductId;
  final VoidCallback? onProductExpanded;

  /// Le message vient d'arriver : il glisse et se révèle. Les précédents
  /// s'affichent directement, sinon la liste frémirait à chaque défilement.
  final bool anime;
  final bool scanne;

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
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 120);
    return AnimatedSlide(
      offset: Offset(0, _decalage / 100),
      duration: duration,
      curve: const Cubic(0.22, 1, 0.36, 1),
      child: AnimatedOpacity(
        opacity: _opacite,
        duration: duration,
        curve: const Cubic(0.22, 1, 0.36, 1),
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
                  child: Stack(
                    children: [
                      Image.file(
                        File(photo),
                        width: 168,
                        height: 168,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                      ),
                      if (widget.scanne)
                        const Positioned.fill(child: PhotoScanOverlay()),
                    ],
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
              if (widget.scanne)
                const Padding(
                  padding: EdgeInsets.fromLTRB(8, 0, 8, 3),
                  child: Text(
                    'Recherche visuelle…',
                    style: TextStyle(fontSize: 11, color: TovoTheme.inkDoux),
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
            ViewportReveal(
              enabled: widget.anime,
              child: Container(
                margin: EdgeInsets.only(
                  bottom: widgets.isEmpty ? 0 : 14,
                  top: 2,
                ),
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
            ),
          if (widget.shoppingStep != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: _ShoppingProgress(step: widget.shoppingStep!),
            ),
          for (var index = 0; index < widgets.length; index++)
            ViewportReveal(
              key: ValueKey('component-$index'),
              enabled: widget.anime,
              delay: Duration(milliseconds: min(350 + index * 380, 1500)),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: widgets[index],
              ),
            ),
          TweenAnimationBuilder<double>(
            key: ValueKey(widget.selectedProductId),
            tween: Tween(begin: 0, end: widget.productDetail == null ? 0 : 1),
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 600),
            curve: TovoTheme.courbe,
            onEnd: widget.productDetail == null
                ? null
                : widget.onProductExpanded,
            builder: (context, progress, child) => ClipRect(
              child: Align(
                alignment: Alignment.topCenter,
                heightFactor: progress,
                child: child,
              ),
            ),
            child: widget.productDetail == null
                ? const SizedBox.shrink()
                : ViewportReveal(
                    key: ValueKey(widget.selectedProductId),
                    duration: const Duration(milliseconds: 600),
                    offset: 16,
                    child: widget.productDetail!,
                  ),
          ),
        ],
      ),
    );
  }
}

class _ShoppingProgress extends StatelessWidget {
  const _ShoppingProgress({required this.step});

  final int step;

  @override
  Widget build(BuildContext context) {
    const labels = ['Recherche', 'Choix', 'Commande'];
    return Semantics(
      label: 'Étape ${step + 1} sur 3 : ${labels[step]}',
      child: Row(
        children: [
          for (var index = 0; index < labels.length; index++) ...[
            if (index > 0)
              const Expanded(child: Divider(color: TovoTheme.line)),
            Text(
              labels[index],
              style: TextStyle(
                fontSize: 12,
                fontWeight: index == step ? FontWeight.w700 : FontWeight.w400,
                color: index == step ? TovoTheme.teal : TovoTheme.muted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FocusedResultView extends StatelessWidget {
  const _FocusedResultView({
    super.key,
    required this.tour,
    required this.onClose,
    required this.onInteraction,
  });

  final _Tour tour;
  final VoidCallback onClose;
  final InteractionCallback onInteraction;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      namesRoute: true,
      label: 'Résultats de recherche',
      child: Material(
        color: Colors.white,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 16, 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Retour à la discussion',
                    onPressed: onClose,
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Résultats',
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                        color: TovoTheme.ink,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: TovoTheme.line),
            Expanded(
              child: ListView(
                key: const PageStorageKey('focused-results'),
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 24),
                children: [
                  _TourVue(
                    tour: tour,
                    onInteraction: onInteraction,
                    anime: true,
                  ),
                ],
              ),
            ),
          ],
        ),
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
        fontSize: 17,
        height: 1.4,
        fontWeight: FontWeight.w400,
        color: couleur,
      ),
    );
  }
}
