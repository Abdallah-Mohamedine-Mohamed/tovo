import 'dart:math';

import 'package:flutter/material.dart';

import '../../components/registry.dart';
import '../../core/api.dart';
import '../../core/location.dart';
import '../../core/theme.dart';

/// Le fil conversationnel.
///
/// En Phase 2 les composants viennent des routes REST du catalogue et du
/// panier. En Phase 4 ils viendront de l'orchestrateur IA, par `POST /chat`.
/// Cet écran ne changera pas : il affiche une enveloppe `content` +
/// `components`, sans savoir qui l'a produite.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.api});

  final TovoApi api;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _TourDeConversation {
  _TourDeConversation({
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
  final List<_TourDeConversation> _tours = [];
  final ScrollController _scroll = ScrollController();
  final TextEditingController _saisie = TextEditingController();
  bool _charge = false;

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

  /// Point unique par lequel passe toute réponse du backend : un seul
  /// endroit à modifier pour ajouter un indicateur de chargement, un
  /// journal, ou le passage à `POST /chat` en Phase 4.
  Future<void> _appeler(Future<TovoResponse> Function() requete) async {
    setState(() => _charge = true);
    final reponse = await requete();
    if (!mounted) return;

    setState(() {
      _charge = false;
      _tours.add(_TourDeConversation(
        deLAssistant: true,
        contenu: reponse.content,
        composants: reponse.components,
        enErreur: !reponse.ok,
      ));
    });
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

  void _ajouterTourUtilisateur(String texte) {
    setState(() {
      _tours.add(_TourDeConversation(deLAssistant: false, contenu: texte));
    });
    _versLeBas();
  }

  /// Routage des interactions.
  ///
  /// Les actions déterministes partent vers les routes REST, sans tour LLM.
  /// C'est la règle du contrat : un tap sur « ajouter » ne doit pas coûter un
  /// aller-retour au modèle.
  void _interaction(TovoInteraction interaction) {
    final payload = interaction.payload;

    switch (interaction.action) {
      case 'select_category':
        _ajouterTourUtilisateur('Voir cette catégorie');
        _appeler(() =>
            widget.api.get('/categories/${payload['category_id']}/products'));

      case 'select_product':
        _appeler(() => widget.api.get('/products/${payload['product_id']}'));

      case 'add_to_cart':
        _appeler(() => widget.api.post('/cart/items', {
              'product_id': payload['product_id'],
              'quantity': payload['quantity'] ?? 1,
              'selections': payload['selections'] ?? const [],
            }));

      case 'update_qty':
        _appeler(() => widget.api.patch(
              '/cart/items/${payload['item_id']}',
              {'quantity': payload['quantity']},
            ));

      case 'remove_from_cart':
        _appeler(() => widget.api.delete('/cart/items/${payload['item_id']}'));

      case 'place_order':
        _commander();

      case 'quick_reply':
        _ajouterTourUtilisateur('${payload['label'] ?? payload['value']}');
        // Les réponses rapides seront interprétées par l'orchestrateur en
        // Phase 4. En attendant, on retombe sur l'accueil.
        _accueil();

      default:
        // Une action inconnue ne doit pas casser le fil : on l'ignore, en la
        // signalant en debug via le registre.
        debugPrint('[chat] interaction non gérée : ${interaction.action}');
    }
  }

  /// Passage de commande.
  ///
  /// Le `client_order_id` est généré ICI, avant l'envoi, et pas côté serveur.
  /// C'est ce qui rend l'opération idempotente : si le réseau coupe après
  /// l'envoi mais avant la réponse — le cas courant à Niamey — un second
  /// essai retombe sur la même commande au lieu d'en créer une deuxième.
  Future<void> _commander() async {
    final position = await TovoLocation.current();
    if (!mounted) return;

    if (position == null) {
      setState(() {
        _tours.add(_TourDeConversation(
          deLAssistant: true,
          contenu: "Je ne peux pas vous livrer sans savoir où vous êtes. "
              "Activez la localisation, puis réessayez.",
          enErreur: true,
        ));
      });
      _versLeBas();
      return;
    }

    final repere = await _demanderLeRepere();
    if (!mounted || repere == null) return;

    _idCommandeEnCours ??= _nouvelIdentifiant();

    await _appeler(() => widget.api.post('/orders', {
          'type': 'delivery',
          'client_order_id': _idCommandeEnCours,
          'dropoff_hint': repere,
          'dropoff': {'lat': position.latitude, 'lng': position.longitude},
          'payment_method': 'cash',
        }));

    // Commande acceptée : l'identifiant a joué son rôle, la prochaine
    // commande en aura un nouveau.
    _idCommandeEnCours = null;
  }

  /// Le repère textuel accompagne l'épingle GPS : « immeuble bleu, face à la
  /// pharmacie ». Sans lui, le livreur a un point sur une carte et rien
  /// d'autre.
  Future<String?> _demanderLeRepere() async {
    final controleur = TextEditingController();

    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Où livrer ?', style: TextStyle(fontSize: 16)),
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
            child: const Text('Commander'),
          ),
        ],
      ),
    );
  }

  static String _nouvelIdentifiant() {
    // UUID v4 sans dépendance supplémentaire.
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

  void _envoyer() {
    final texte = _saisie.text.trim();
    if (texte.isEmpty) return;
    _saisie.clear();
    _ajouterTourUtilisateur(texte);

    // Phase 4 : POST /chat. D'ici là, la saisie libre n'a pas d'interlocuteur.
    setState(() {
      _tours.add(_TourDeConversation(
        deLAssistant: true,
        contenu: "La recherche en langage naturel arrive bientôt. "
            "En attendant, choisissez une catégorie.",
      ));
    });
    _accueil();
  }

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
            Text(
              'Niamey · livraison',
              style: const TextStyle(fontSize: 11, color: TovoTheme.muted),
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
              itemBuilder: (context, i) => _Tour(
                tour: _tours[i],
                onInteraction: _interaction,
              ),
            ),
          ),
          if (_charge)
            const LinearProgressIndicator(
              minHeight: 2,
              color: TovoTheme.teal,
              backgroundColor: TovoTheme.line,
            ),
          _BarreDeSaisie(controller: _saisie, onSend: _envoyer),
        ],
      ),
    );
  }
}

class _Tour extends StatelessWidget {
  const _Tour({required this.tour, required this.onInteraction});

  final _TourDeConversation tour;
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
            borderRadius: BorderRadius.circular(16).copyWith(
              bottomRight: const Radius.circular(4),
            ),
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
              borderRadius: BorderRadius.circular(16).copyWith(
                bottomLeft: const Radius.circular(4),
              ),
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
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: widget,
          ),
      ],
    );
  }
}

class _BarreDeSaisie extends StatelessWidget {
  const _BarreDeSaisie({required this.controller, required this.onSend});

  final TextEditingController controller;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: TovoTheme.line)),
        ),
        child: Row(
          children: [
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
