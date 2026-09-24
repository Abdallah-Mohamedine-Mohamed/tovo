import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../components/registry.dart';
import '../../components/widgets/read_placeholder.dart';
import '../../core/api.dart';
import '../../core/location.dart';
import '../../core/panier.dart';
import '../../core/push.dart';
import '../../core/theme.dart';
import '../../core/catalog_image.dart';

class _DeliveryPoint {
  const _DeliveryPoint(this.hint, this.lat, this.lng);
  final String hint;
  final double lat;
  final double lng;

  String get cle => '$lat,$lng';
}

/// La commande, sur un seul écran, avec un seul bouton.
///
/// Avant : « Voir le total avec livraison », attendre, faire défiler,
/// « Confirmer la commande » — deux gestes et deux attentes, un bouton qu'il
/// fallait aller chercher en bas, des listes de boutons radio pour l'adresse
/// et le paiement. Le client avait l'impression de remplir un formulaire.
///
/// Maintenant, comme une caisse bien tenue :
///  - ce qu'on achète, en haut ;
///  - où on livre et comment on paie, sur deux lignes qu'on change d'un geste ;
///  - le total, déjà calculé ;
///  - un bouton, toujours visible : « Commander · 7 500 F ». Le prix est
///    SUR le bouton : le client sait ce qu'il valide, pas besoin d'une étape
///    de confirmation de plus.
///
/// Aucune attente visible dans le cas courant : le panier déjà affiché dans
/// la discussion s'ouvre tel quel, l'adresse habituelle vient du cache, et le
/// total avec livraison est demandé au serveur dès l'ouverture — il est là
/// avant que le client ait fini de relire. Le serveur reste seul juge des
/// prix (on ne fait jamais confiance à un total calculé sur le téléphone) ;
/// on ne fait simplement plus ATTENDRE le client pour ça.
class CartScreen extends StatefulWidget {
  const CartScreen({
    super.key,
    required this.api,
    this.initialAddressId,
    this.initialCart,
    this.conversationId,
  });
  final TovoApi api;
  final String? initialAddressId;
  final TovoComponent? initialCart;

  /// La conversation d'où vient le client : la commande y est inscrite,
  /// et son suivi y sera encore quand il la rouvrira.
  final String? conversationId;

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  /// Le dernier panier connu. Il porte les frais de livraison quand
  /// [_devisPour] désigne la destination actuelle.
  TovoComponent? _cart;
  bool _chargement = true;

  /// La destination pour laquelle [_cart] contient un devis (frais compris).
  String? _devisPour;
  bool _devisEnCours = false;

  /// Une quantité en cours d'envoi : l'affichage est déjà à jour.
  bool _miseAJour = false;
  bool _commandeEnCours = false;

  /// Chaque erreur s'affiche là où le client vient d'agir.
  String? _erreurArticles;
  String? _erreurCommande;

  List<Map<String, dynamic>> _adresses = const [];
  String? _adresseId;
  _DeliveryPoint? _position;
  final _repere = TextEditingController();
  String _paiement = 'cash';
  String? _orderId;

  /// Seule la réponse à la DERNIÈRE demande de devis compte : un client qui
  /// change deux fois d'adresse ne doit pas voir revenir le premier total.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _cart = widget.initialCart;
    _chargement = widget.initialCart == null;
    unawaited(_demarrer());
  }

  @override
  void dispose() {
    _repere.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ données ---

  _DeliveryPoint? get _destination {
    if (_adresseId != null) {
      for (final adresse in _adresses) {
        if (adresse['id'] == _adresseId &&
            adresse['lat'] is num &&
            adresse['lng'] is num) {
          return _DeliveryPoint(
            '${adresse['text_hint'] ?? ''}',
            (adresse['lat'] as num).toDouble(),
            (adresse['lng'] as num).toDouble(),
          );
        }
      }
    }
    // Position GPS prise : elle suffit. Le repère aide le livreur mais ne
    // bloque rien — il appelle le client si besoin.
    if (_position != null) {
      final repere = _repere.text.trim();
      return _DeliveryPoint(
        repere.isEmpty ? 'Position du client (le livreur appellera)' : repere,
        _position!.lat,
        _position!.lng,
      );
    }
    return null;
  }

  bool get _devisPret {
    final destination = _destination;
    return _cart != null &&
        destination != null &&
        _devisPour == destination.cle &&
        !_devisEnCours;
  }

  Future<void> _demarrer() async {
    // L'adresse habituelle, depuis le cache : le devis part tout de suite,
    // sans attendre la liste à jour.
    final enCache = await widget.api.cachedGet('/addresses');
    if (!mounted) return;
    if (enCache != null) _appliquerAdresses(enCache.list('addresses'));
    if (_destination != null) {
      unawaited(_chargerDevis());
    } else {
      unawaited(_chargerPanier());
    }

    final reponse = await widget.api.get('/addresses');
    if (!mounted || !reponse.ok) return;
    final avant = _destination?.cle;
    _appliquerAdresses(reponse.list('addresses'));
    // L'adresse est arrivée après coup, ou a changé : le devis suit.
    if (_destination != null && _destination!.cle != avant) {
      unawaited(_chargerDevis());
    }
  }

  void _appliquerAdresses(List<Map<String, dynamic>> brutes) {
    setState(() {
      _adresses = brutes
          .where((a) => a['lat'] is num && a['lng'] is num)
          .toList();
      final existe = _adresses.any((a) => a['id'] == _adresseId);
      if (_position == null && !existe) {
        _adresseId =
            _adresses
                    .where((a) => a['id'] == widget.initialAddressId)
                    .firstOrNull?['id']
                as String? ??
            _adresses.where((a) => a['is_default'] == true).firstOrNull?['id']
                as String? ??
            _adresses.firstOrNull?['id'] as String?;
      }
    });
  }

  TovoComponent? _panierDans(TovoResponse reponse) =>
      reponse.components.where((c) => c.type == 'cart_summary').firstOrNull;

  Future<void> _chargerPanier() async {
    final reponse = await widget.api.get('/cart');
    if (!mounted) return;
    setState(() {
      _chargement = false;
      if (!reponse.ok) {
        _erreurArticles = reponse.content;
        return;
      }
      _erreurArticles = null;
      _cart = _panierDans(reponse);
      _devisPour = null;
    });
  }

  /// Le panier ET les frais de livraison, en une seule requête.
  Future<void> _chargerDevis() async {
    final destination = _destination;
    if (destination == null) return;
    final generation = ++_generation;
    setState(() {
      _devisEnCours = true;
      _erreurCommande = null;
    });
    final reponse = await widget.api.get(
      '/cart',
      query: {'lat': destination.lat, 'lng': destination.lng},
    );
    if (!mounted || generation != _generation) return;
    setState(() {
      _devisEnCours = false;
      _chargement = false;
      if (!reponse.ok) {
        // Sans panier déjà affiché, c'est le panier qui manque, pas le devis.
        if (_cart == null) {
          _erreurArticles = reponse.content;
        } else {
          _erreurCommande = reponse.content;
        }
        return;
      }
      _erreurArticles = null;
      _cart = _panierDans(reponse);
      _devisPour = destination.cle;
    });
  }

  /// La quantité change TOUT DE SUITE à l'écran ; le serveur confirme
  /// derrière, et recalcule la livraison dans la même requête.
  Future<void> _quantite(String id, int quantite) async {
    final cart = _cart;
    if (cart == null || _miseAJour || quantite < 0 || quantite > 50) return;
    final avant = cart;
    final destination = _destination;
    final generation = ++_generation;

    setState(() {
      _miseAJour = true;
      _erreurArticles = null;
      _cart = _avecQuantite(cart, id, quantite);
    });

    final reponse = quantite == 0
        ? await widget.api.delete('/cart/items/$id')
        : await widget.api.patch('/cart/items/$id', {
            'quantity': quantite,
            if (destination != null) 'lat': destination.lat,
            if (destination != null) 'lng': destination.lng,
          });
    if (!mounted) return;
    setState(() {
      _miseAJour = false;
      if (!reponse.ok) {
        // Refusé : on revient à ce que le serveur connaît, et on dit pourquoi.
        _cart = avant;
        _erreurArticles = reponse.content;
        return;
      }
      if (generation != _generation) return;
      _cart = _panierDans(reponse);
      if (_cart == null) PanierEnDirect.instance.vider();
      _devisPour = quantite > 0 && destination != null ? destination.cle : null;
    });
    // Un article retiré : la réponse ne porte pas la livraison, on la redemande.
    if (reponse.ok && _cart != null && _devisPour == null) {
      unawaited(_chargerDevis());
    }
  }

  /// Le panier tel qu'il sera, pour l'afficher sans attendre : même prix
  /// unitaire, nouvelle quantité. Le serveur tranche ensuite.
  static TovoComponent _avecQuantite(
    TovoComponent cart,
    String id,
    int quantite,
  ) {
    final articles = <Map<String, dynamic>>[];
    for (final article in cart.list('items')) {
      if (article['item_id'] != id) {
        articles.add(article);
        continue;
      }
      if (quantite == 0) continue;
      final ancienne = (article['quantity'] as num?)?.toInt() ?? 1;
      final ligne = (article['line_total'] as num?)?.toInt() ?? 0;
      final unitaire = ancienne > 0 ? ligne ~/ ancienne : 0;
      articles.add({
        ...article,
        'quantity': quantite,
        'line_total': unitaire * quantite,
      });
    }
    final sousTotal = articles.fold<int>(
      0,
      (t, a) => t + ((a['line_total'] as num?)?.toInt() ?? 0),
    );
    final total =
        sousTotal - cart.money('discount') + cart.money('delivery_fee');
    return TovoComponent(
      type: cart.type,
      data: {
        ...cart.data,
        'items': articles,
        'items_total': sousTotal,
        'total': total,
      },
    );
  }

  Future<void> _commander() async {
    final destination = _destination;
    if (_commandeEnCours || destination == null || !_devisPret) return;
    _orderId ??= _nouvelIdentifiant();
    setState(() {
      _commandeEnCours = true;
      _erreurCommande = null;
    });
    final reponse = await widget.api.post('/orders', {
      'type': 'delivery',
      'client_order_id': _orderId,
      'dropoff_hint': destination.hint,
      'dropoff': {'lat': destination.lat, 'lng': destination.lng},
      'payment_method': _paiement,
      if (widget.conversationId != null)
        'conversation_id': widget.conversationId,
    });
    if (!mounted) return;
    if (reponse.ok) {
      unawaited(HapticFeedback.mediumImpact());
      unawaited(TovoPush.enregistrer('client'));
      // Commande partie : plus de panier, plus de pastille.
      PanierEnDirect.instance.vider();
      Navigator.of(context).pop(reponse);
      return;
    }
    setState(() {
      _commandeEnCours = false;
      _erreurCommande = reponse.content;
    });
  }

  static String _nouvelIdentifiant() {
    const chiffres = '0123456789abcdef';
    final hasard = Random.secure();
    final tampon = StringBuffer();
    for (var i = 0; i < 36; i++) {
      if ([8, 13, 18, 23].contains(i)) {
        tampon.write('-');
      } else if (i == 14) {
        tampon.write('4');
      } else if (i == 19) {
        tampon.write(chiffres[8 + hasard.nextInt(4)]);
      } else {
        tampon.write(chiffres[hasard.nextInt(16)]);
      }
    }
    return tampon.toString();
  }

  /// Une étiquette qui dit quelque chose (« Maison », « Bureau »), pas
  /// l'étiquette par défaut.
  static bool _etiquetteParlante(Object? label) {
    final texte = '${label ?? ''}'.trim().toLowerCase();
    return texte.isNotEmpty && texte != 'adresse';
  }

  // -------------------------------------------------------------- gestes ---

  /// Où livrer : une feuille qui monte, un geste, elle se referme.
  Future<void> _choisirAdresse() async {
    final choix = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (feuille) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Où livrer ?',
                style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              for (final adresse in _adresses)
                _LigneChoix(
                  icone: Icons.place_outlined,
                  titre: '${adresse['text_hint'] ?? ''}'.trim().isNotEmpty
                      ? '${adresse['text_hint']}'
                      : '${adresse['label'] ?? 'Adresse'}',
                  sousTitre: _etiquetteParlante(adresse['label'])
                      ? '${adresse['label']}'
                      : null,
                  choisi: _position == null && adresse['id'] == _adresseId,
                  onTap: () => Navigator.pop(feuille, adresse['id'] as String),
                ),
              _LigneChoix(
                icone: Icons.my_location_rounded,
                titre: 'Ma position actuelle',
                sousTitre: 'Le livreur vous appelle si besoin',
                choisi: _position != null,
                onTap: () => Navigator.pop(feuille, _ici),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || choix == null) return;
    if (choix == _ici) {
      await _prendreMaPosition();
    } else {
      setState(() {
        _adresseId = choix;
        _position = null;
        _erreurCommande = null;
      });
      unawaited(_chargerDevis());
    }
  }

  static const _ici = '__position__';

  Future<void> _prendreMaPosition() async {
    setState(() => _erreurCommande = null);
    // Déjà connue depuis l'ouverture de l'app : aucune attente GPS.
    final position =
        TovoLocation.recente ??
        await TovoLocation.current(requestPermission: true);
    if (!mounted) return;
    if (position == null) {
      setState(
        () => _erreurCommande =
            'Activez la localisation, ou choisissez une adresse enregistrée.',
      );
      return;
    }
    setState(() {
      _adresseId = null;
      _position = _DeliveryPoint('', position.latitude, position.longitude);
    });
    unawaited(_chargerDevis());
  }

  // ---------------------------------------------------------------- vue ---

  @override
  Widget build(BuildContext context) {
    final articles = _cart?.list('items') ?? [];
    return PopScope(
      canPop: !_commandeEnCours,
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          // Pas de titre ici : le nom de la boutique, en grand, en tient
          // lieu. Deux titres l'un sous l'autre disaient deux fois la même chose.
          leading: IconButton(
            tooltip: 'Retour aux produits',
            onPressed: _commandeEnCours ? null : () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back_rounded, color: TovoTheme.ink),
          ),
        ),
        bottomNavigationBar: articles.isEmpty ? null : _barreCommande(),
        body: _chargement && _cart == null
            ? const ReadPlaceholder()
            : articles.isEmpty
            ? _vide()
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                children: [
                  Text(
                    _cart!.str('merchant_name'),
                    style: const TextStyle(
                      fontSize: 26,
                      height: 1.15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.7,
                    ),
                  ),
                  if (_erreurArticles != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _erreurArticles!,
                      style: const TextStyle(color: TovoTheme.danger),
                    ),
                  ],
                  const SizedBox(height: 8),
                  for (final article in articles) _article(article),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: _commandeEnCours
                          ? null
                          : () => Navigator.pop(context),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        foregroundColor: TovoTheme.inkDoux,
                      ),
                      child: const Text('Ajouter des articles'),
                    ),
                  ),
                  const SizedBox(height: 20),
                  _ligneLivraison(),
                  if (_position != null) _champRepere(),
                  const _Separation(),
                  _lignePaiement(),
                  const _Separation(),
                  const SizedBox(height: 8),
                  _totaux(),
                ],
              ),
      ),
    );
  }

  Widget _vide() => ListView(
    padding: const EdgeInsets.fromLTRB(20, 88, 20, 32),
    children: [
      if (_erreurArticles != null) ...[
        Text(
          _erreurArticles!,
          textAlign: TextAlign.center,
          style: const TextStyle(color: TovoTheme.danger),
        ),
        Center(
          child: TextButton(
            onPressed: _destination != null ? _chargerDevis : _chargerPanier,
            child: const Text('Réessayer'),
          ),
        ),
      ] else ...[
        const Icon(
          Icons.shopping_bag_outlined,
          size: 52,
          color: TovoTheme.teal,
        ),
        const SizedBox(height: 24),
        const Text(
          'Une envie à ajouter ?',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.8,
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'Votre panier est encore vide.',
          textAlign: TextAlign.center,
          style: TextStyle(color: TovoTheme.inkDoux),
        ),
        const SizedBox(height: 24),
        Center(
          child: TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Revenir aux produits'),
          ),
        ),
      ],
    ],
  );

  Widget _ligneLivraison() {
    final destination = _destination;
    String titre;
    String? sousTitre;
    if (_position != null) {
      titre = 'Ma position actuelle';
      sousTitre = _repere.text.trim().isEmpty ? null : _repere.text.trim();
    } else if (destination != null) {
      final adresse = _adresses.firstWhere((a) => a['id'] == _adresseId);
      titre = destination.hint.isNotEmpty
          ? destination.hint
          : '${adresse['label'] ?? 'Adresse'}';
      sousTitre = _etiquetteParlante(adresse['label'])
          ? '${adresse['label']}'
          : null;
    } else {
      titre = 'Choisir où livrer';
    }
    return _LigneReglage(
      libelle: 'Livraison',
      titre: titre,
      sousTitre: sousTitre,
      action: destination == null ? null : 'Changer',
      onTap: _commandeEnCours ? null : _choisirAdresse,
    );
  }

  Widget _champRepere() => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: _repere,
      onChanged: (_) => setState(() {}),
      textCapitalization: TextCapitalization.sentences,
      style: const TextStyle(fontSize: 14),
      decoration: InputDecoration(
        hintText: 'Un repère pour le livreur (facultatif)',
        isDense: true,
        filled: true,
        fillColor: TovoTheme.bloc,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TovoTheme.radiusChip),
          borderSide: BorderSide.none,
        ),
      ),
    ),
  );

  Widget _lignePaiement() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 14),
    child: Row(
      children: [
        const Expanded(
          child: Text(
            'Paiement',
            style: TextStyle(fontSize: 13, color: TovoTheme.inkDoux),
          ),
        ),
        for (final (valeur, libelle) in const [
          ('cash', 'Espèces'),
          ('mobile_money', 'Nita'),
        ]) ...[
          const SizedBox(width: 8),
          ChoiceChip(
            label: Text(libelle),
            selected: _paiement == valeur,
            showCheckmark: false,
            onSelected: _commandeEnCours
                ? null
                : (_) => setState(() => _paiement = valeur),
          ),
        ],
      ],
    ),
  );

  Widget _totaux() {
    final cart = _cart!;
    final pret = _devisPret;
    return Column(
      children: [
        _montant('Articles', Money.format(cart.money('items_total'))),
        if (cart.money('discount') > 0)
          _montant('Réduction', '−${Money.format(cart.money('discount'))}'),
        // Jamais « 0 F » tant que le serveur n'a pas calculé : la livraison
        // n'est pas gratuite, elle est en cours de calcul.
        _montant(
          'Livraison',
          pret
              ? Money.format(cart.money('delivery_fee'))
              : _devisEnCours
              ? 'Calcul…'
              : 'À calculer',
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            const Expanded(
              child: Text(
                'Total',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            AnimatedSwitcher(
              duration: TovoTheme.normal,
              child: Text(
                pret ? Money.format(cart.money('total')) : '—',
                key: ValueKey(pret ? cart.money('total') : -1),
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.4,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Le seul bouton de l'écran, toujours à portée de pouce.
  Widget _barreCommande() {
    final cart = _cart!;
    final bloque = cart.str('blocked_reason');
    final destination = _destination;
    final pret = _devisPret && cart.flag('can_checkout');

    final String libelle;
    VoidCallback? action;
    if (_commandeEnCours) {
      libelle = 'Commande en cours…';
    } else if (destination == null) {
      libelle = 'Choisir où livrer';
      action = _choisirAdresse;
    } else if (_erreurCommande != null && !_devisPret) {
      libelle = 'Réessayer';
      action = _chargerDevis;
    } else if (!_devisPret) {
      libelle = 'Calcul du total…';
    } else if (!cart.flag('can_checkout')) {
      libelle = 'Commander';
    } else {
      libelle = 'Commander · ${Money.format(cart.money('total'))}';
      action = _commander;
    }

    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFEEF0F0))),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Juste au-dessus du bouton, là où le client regarde.
            for (final message in [
              if (bloque.isNotEmpty) bloque,
              if (_erreurCommande != null) _erreurCommande!,
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: TovoTheme.danger),
                ),
              ),
            SizedBox(
              height: 56,
              child: FilledButton(
                onPressed: action,
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: AnimatedSwitcher(
                  duration: TovoTheme.normal,
                  child: Text(
                    libelle,
                    key: ValueKey(libelle),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: pret ? FontWeight.w700 : FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _montant(String libelle, String valeur) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        Expanded(
          child: Text(
            libelle,
            style: const TextStyle(fontSize: 14, color: TovoTheme.inkDoux),
          ),
        ),
        Text(
          valeur,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ],
    ),
  );

  Widget _article(Map<String, dynamic> article) {
    final id = article['item_id'] as String?;
    final quantite = (article['quantity'] as num?)?.toInt() ?? 1;
    final photo = article['image_url'] as String? ?? '';
    final nom = '${article['product_name'] ?? ''}';
    final options = article['selections_label'] as String? ?? '';
    final disponible = article['is_available'] != false;
    final actif = !_miseAJour && !_commandeEnCours && id != null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (photo.isNotEmpty) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: CatalogImage(
                photo,
                width: 56,
                height: 56,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
            const SizedBox(width: 14),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  nom,
                  style: const TextStyle(
                    fontSize: 15,
                    height: 1.25,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (options.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      options,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: TovoTheme.inkDoux,
                      ),
                    ),
                  ),
                if (!disponible)
                  const Padding(
                    padding: EdgeInsets.only(top: 3),
                    child: Text(
                      'Indisponible',
                      style: TextStyle(fontSize: 12, color: TovoTheme.danger),
                    ),
                  ),
                const SizedBox(height: 4),
                Text(
                  Money.format((article['line_total'] as num?)?.toInt() ?? 0),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // − 2 + : une pilule discrète, pas trois gros boutons.
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: TovoTheme.line),
              borderRadius: BorderRadius.circular(22),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: quantite > 1 ? 'Réduire $nom' : 'Retirer $nom',
                  visualDensity: VisualDensity.compact,
                  onPressed: actif ? () => _quantite(id, quantite - 1) : null,
                  icon: Icon(
                    quantite > 1
                        ? Icons.remove_rounded
                        : Icons.delete_outline_rounded,
                    size: 18,
                  ),
                ),
                Text(
                  '$quantite',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                IconButton(
                  tooltip: 'Ajouter un $nom',
                  visualDensity: VisualDensity.compact,
                  onPressed: actif && quantite < 50 && disponible
                      ? () => _quantite(id, quantite + 1)
                      : null,
                  icon: const Icon(Icons.add_rounded, size: 18),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Une ligne de réglage : ce qui est choisi, et un geste pour le changer.
class _LigneReglage extends StatelessWidget {
  const _LigneReglage({
    required this.libelle,
    required this.titre,
    this.sousTitre,
    this.action,
    this.onTap,
  });

  final String libelle;
  final String titre;
  final String? sousTitre;
  final String? action;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  libelle,
                  style: const TextStyle(
                    fontSize: 13,
                    color: TovoTheme.inkDoux,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  titre,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (sousTitre != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      sousTitre!,
                      style: const TextStyle(
                        fontSize: 13,
                        color: TovoTheme.inkDoux,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (action != null)
            Text(
              action!,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: TovoTheme.teal,
              ),
            )
          else
            const Icon(Icons.chevron_right_rounded, color: TovoTheme.inkDoux),
        ],
      ),
    ),
  );
}

/// Un choix dans la feuille « Où livrer ? ».
class _LigneChoix extends StatelessWidget {
  const _LigneChoix({
    required this.icone,
    required this.titre,
    required this.choisi,
    required this.onTap,
    this.sousTitre,
  });

  final IconData icone;
  final String titre;
  final String? sousTitre;
  final bool choisi;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icone, color: TovoTheme.ink),
    title: Text(titre, style: const TextStyle(fontWeight: FontWeight.w600)),
    subtitle: sousTitre == null ? null : Text(sousTitre!),
    trailing: choisi
        ? const Icon(Icons.check_rounded, color: TovoTheme.teal)
        : null,
    onTap: onTap,
  );
}

class _Separation extends StatelessWidget {
  const _Separation();

  @override
  Widget build(BuildContext context) =>
      const Divider(height: 1, color: Color(0xFFEEF0F0));
}
