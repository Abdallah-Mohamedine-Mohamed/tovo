import 'dart:math';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../components/registry.dart';
import '../../core/api.dart';
import '../../core/location.dart';
import '../../core/theme.dart';

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

  @override
  void initState() {
    super.initState();
    _accueil();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _saisie.dispose();
    super.dispose();
  }

  Future<void> _accueil() => _appeler(() => widget.api.get('/categories'));

  // ------------------------------------------------------------------
  // Échanges
  // ------------------------------------------------------------------

  Future<void> _appeler(Future<TovoResponse> Function() requete) async {
    setState(() => _charge = true);
    final reponse = await requete();
    if (!mounted) return;

    setState(() {
      _charge = false;
      _tours.add(_Tour(
        deLAssistant: true,
        contenu: reponse.content,
        composants: reponse.components,
        enErreur: !reponse.ok,
      ));
      final id = reponse.raw['conversation_id'];
      if (id is String) _conversationId = id;
    });
    _versLeBas();
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
      case 'select_category':
        _ajouterTourUtilisateur('Voir cette catégorie');
        _appeler(() => widget.api.get('/categories/${p['category_id']}/products'));

      case 'select_product':
        _appeler(() => widget.api.get('/products/${p['product_id']}'));

      case 'add_to_cart':
        _appeler(() => widget.api.post('/cart/items', {
              'product_id': p['product_id'],
              'quantity': p['quantity'] ?? 1,
              'selections': p['selections'] ?? const [],
            }));

      case 'update_qty':
        _appeler(() => widget.api.patch(
              '/cart/items/${p['item_id']}',
              {'quantity': p['quantity']},
            ));

      case 'remove_from_cart':
        _appeler(() => widget.api.delete('/cart/items/${p['item_id']}'));

      case 'place_order':
        _commander();

      case 'submit_courier':
        _envoyerColis(p);

      // --- interprétation nécessaire : l'assistant -------------------
      case 'select_merchant':
        _parler(interaction: {'action': 'select_merchant', 'payload': p});

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

  Future<void> _commander() async {
    final position = await TovoLocation.current();
    if (!mounted) return;

    if (position == null) {
      _erreurLocalisation();
      return;
    }

    final repere = await _demanderLeRepere('Où livrer ?');
    if (!mounted || repere == null) return;

    _idCommandeEnCours ??= _nouvelIdentifiant();

    await _appeler(() => widget.api.post('/orders', {
          'type': 'delivery',
          'client_order_id': _idCommandeEnCours,
          'dropoff_hint': repere,
          'dropoff': {'lat': position.latitude, 'lng': position.longitude},
          'payment_method': 'cash',
        }));

    _idCommandeEnCours = null;
  }

  Future<void> _envoyerColis(Map<String, dynamic> p) async {
    final depart = (p['pickup'] as Map?)?.cast<String, dynamic>();
    final arrivee = (p['dropoff'] as Map?)?.cast<String, dynamic>();

    if (depart?['lat'] == null || arrivee?['lat'] == null) {
      _erreurLocalisation();
      return;
    }

    _idCommandeEnCours ??= _nouvelIdentifiant();

    await _appeler(() => widget.api.post('/orders', {
          'type': 'courier',
          'client_order_id': _idCommandeEnCours,
          'pickup_hint': depart!['hint'],
          'pickup': {'lat': depart['lat'], 'lng': depart['lng']},
          'dropoff_hint': arrivee!['hint'],
          'dropoff': {'lat': arrivee['lat'], 'lng': arrivee['lng']},
          'parcel': p['parcel'] ?? 'small',
          'payment_method': 'cash',
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
    final numero = '${telephone ?? ''}'.replaceAll(' ', '');
    if (numero.isEmpty) return;
    await launchUrl(Uri.parse('tel:$numero'));
  }

  void _envoyer() {
    final texte = _saisie.text.trim();
    if (texte.isEmpty) return;
    _saisie.clear();
    _ajouterTourUtilisateur(texte);
    _rafraichirPosition();
    _parler(texte: texte);
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
              itemBuilder: (context, i) =>
                  _TourVue(tour: _tours[i], onInteraction: _interaction),
            ),
          ),
          if (_charge)
            const LinearProgressIndicator(
              minHeight: 2,
              color: TovoTheme.teal,
              backgroundColor: TovoTheme.line,
            ),
          _BarreDeSaisie(
            controller: _saisie,
            onSend: _envoyer,
            onCamera: () => _chercherParPhoto(ImageSource.camera),
          ),
        ],
      ),
    );
  }
}

class _TourVue extends StatelessWidget {
  const _TourVue({required this.tour, required this.onInteraction});

  final _Tour tour;
  final InteractionCallback onInteraction;

  @override
  Widget build(BuildContext context) {
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
  });

  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onCamera;

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
        child: Row(
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
            InkWell(
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
            ),
          ],
        ),
      ),
    );
  }
}
