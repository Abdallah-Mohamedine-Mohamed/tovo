import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../components/widgets/pastille_panier.dart';
import '../../components/widgets/product_carousel.dart';
import '../../components/widgets/read_placeholder.dart';
import '../../core/api.dart';
import '../../core/noms.dart';
import '../../core/catalog_image.dart';
import '../../core/panier.dart';
import '../../core/theme.dart';
import 'cart_screen.dart';
import 'catalog_screen.dart';
import 'product_sheet.dart';
import 'rayons_screen.dart';

/// La page d'une boutique, inspirée de Glovo : sa photo, son logo, ce qu'il
/// faut savoir en une ligne, puis TOUTE la carte, rayon après rayon.
///
/// L'ancienne page ne montrait qu'un rayon à la fois, filtré, dans une
/// grille sans titres : pour voir les boissons d'un restaurant, il fallait
/// deviner qu'un onglet existait. Ici on fait défiler la carte comme un
/// menu ; les onglets du haut y sautent, et suivent le défilement.
///
/// En monochrome, comme le reste de Tovo : pas de pastilles promo rouges.
class BoutiqueScreen extends StatefulWidget {
  const BoutiqueScreen({
    super.key,
    required this.api,
    required this.merchantId,
    this.apercu = const {},
    this.conversationId,
  });

  final TovoApi api;
  final String merchantId;

  /// Ce qu'on sait déjà de la boutique (nom, logo) : l'en-tête s'affiche
  /// tout de suite, sans attendre la carte.
  final Map<String, dynamic> apercu;
  final String? conversationId;

  @override
  State<BoutiqueScreen> createState() => _BoutiqueScreenState();
}

class _BoutiqueScreenState extends State<BoutiqueScreen> {
  static const _hauteurOnglets = 52.0;

  final _scroll = ScrollController();
  final _defileOnglets = ScrollController();
  final _cles = <int, GlobalKey>{};
  final _clesOnglets = <int, GlobalKey>{};
  Map<String, dynamic> _boutique = {};
  List<Map<String, dynamic>> _rayons = [];
  bool _charge = true;
  String? _erreur;
  int _actif = 0;
  bool _saute = false;

  String get _chemin => '/merchants/${widget.merchantId}/carte';

  @override
  void initState() {
    super.initState();
    _boutique = {...widget.apercu};
    _scroll.addListener(_suivreLeDefilement);
    unawaited(_charger());
  }

  @override
  void dispose() {
    _scroll.dispose();
    _defileOnglets.dispose();
    super.dispose();
  }

  Future<void> _charger() async {
    final requete = widget.api.get(_chemin);
    final cache = await widget.api.cachedGet(_chemin);
    if (!mounted) return;
    if (cache != null) _appliquer(cache);
    final reponse = await requete;
    if (!mounted) return;
    if (reponse.ok) {
      _appliquer(reponse);
    } else if (_rayons.isEmpty) {
      setState(() {
        _charge = false;
        _erreur = reponse.content;
      });
    }
  }

  void _appliquer(TovoResponse reponse) {
    setState(() {
      _charge = false;
      _erreur = null;
      final fiche = reponse.raw['merchant'];
      if (fiche is Map<String, dynamic>) _boutique = fiche;
      _rayons = reponse.list('sections');
    });
  }

  GlobalKey _cle(int i) => _cles.putIfAbsent(i, GlobalKey.new);
  GlobalKey _cleOnglet(int i) => _clesOnglets.putIfAbsent(i, GlobalKey.new);

  /// L'onglet actif suit le rayon qui passe sous la barre d'onglets.
  void _suivreLeDefilement() {
    if (_saute || _rayons.length < 2) return;
    var actif = 0;
    for (var i = 0; i < _rayons.length; i++) {
      final boite = _cles[i]?.currentContext?.findRenderObject();
      if (boite is! RenderBox || !boite.attached) continue;
      final haut = boite.localToGlobal(Offset.zero).dy;
      if (haut <= MediaQuery.paddingOf(context).top + _hauteurOnglets + 24) {
        actif = i;
      }
    }
    if (actif != _actif) {
      setState(() => _actif = actif);
      _montrerOnglet(actif);
    }
  }

  /// Amène l'onglet actif en vue dans la barre. Seulement la barre :
  /// Scrollable.ensureVisible ferait aussi défiler la page entière.
  void _montrerOnglet(int i) {
    final objet = _clesOnglets[i]?.currentContext?.findRenderObject();
    if (objet == null || !objet.attached || !_defileOnglets.hasClients) return;
    final cible = RenderAbstractViewport.of(objet)
        .getOffsetToReveal(objet, 0.3)
        .offset
        .clamp(0.0, _defileOnglets.position.maxScrollExtent);
    unawaited(
      _defileOnglets.animateTo(
        cible,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      ),
    );
  }

  /// Toucher un onglet fait défiler jusqu'au rayon, juste sous la barre.
  Future<void> _allerAuRayon(int i) async {
    setState(() => _actif = i);
    _montrerOnglet(i);
    _saute = true;
    try {
      // Un rayon loin en bas n'est peut-être pas encore construit : on s'en
      // approche d'abord, un écran à la fois, puis on se cale exactement.
      // Les rayons étant désormais complets, il peut y avoir beaucoup
      // d'écrans à franchir : on va jusqu'au bout de la page s'il le faut.
      for (var essai = 0; essai < 200; essai++) {
        final cible = _positionDuRayon(i);
        if (cible != null) {
          await _scroll.animateTo(
            cible,
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
          );
          // Les rayons au-dessus, construits pendant l'animation, ont
          // remplacé leur hauteur estimée par la vraie : on se recale,
          // jusqu'à ce que la position ne bouge plus (les rayons complets
          // sont hauts : l'estimation se corrige en plusieurs fois).
          for (var recalage = 0; recalage < 12; recalage++) {
            await WidgetsBinding.instance.endOfFrame;
            if (!mounted) return;
            final juste = _positionDuRayon(i);
            if (juste == null || (juste - _scroll.offset).abs() < 1) break;
            _scroll.jumpTo(juste);
          }
          return;
        }
        final vers = i > _premierConstruit() ? 1 : -1;
        final bout = vers > 0
            ? _scroll.offset >= _scroll.position.maxScrollExtent
            : _scroll.offset <= 0;
        if (bout) return;
        _scroll.jumpTo(
          (_scroll.offset + vers * MediaQuery.sizeOf(context).height).clamp(
            0.0,
            _scroll.position.maxScrollExtent,
          ),
        );
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
      }
    } finally {
      _saute = false;
    }
  }

  /// Le défilement qui place le rayon [i] juste sous la barre d'onglets, ou
  /// null s'il n'est pas encore construit.
  double? _positionDuRayon(int i) {
    final objet = _cles[i]?.currentContext?.findRenderObject();
    if (objet == null || !objet.attached) return null;
    // getOffsetToReveal tient déjà compte de la barre d'onglets épinglée.
    final revele = RenderAbstractViewport.of(objet).getOffsetToReveal(objet, 0);
    return revele.offset.clamp(0.0, _scroll.position.maxScrollExtent);
  }

  int _premierConstruit() {
    for (var i = 0; i < _rayons.length; i++) {
      if (_cles[i]?.currentContext != null) return i;
    }
    return 0;
  }

  Future<void> _ouvrirProduit(Map<String, dynamic> produit) async {
    final issue = await showProductSheet(
      context,
      api: widget.api,
      productId: produit['id'] as String,
      initialProduct: produit,
    );
    if (mounted && issue == IssueFiche.commander) await _ouvrirPanier();
  }

  Future<void> _ouvrirPanier() async {
    final commande = await Navigator.of(context).push<TovoResponse>(
      MaterialPageRoute(
        builder: (_) => CartScreen(
          api: widget.api,
          initialCart: PanierEnDirect.instance.value?.composant,
          conversationId: widget.conversationId,
        ),
      ),
    );
    if (mounted && commande != null) Navigator.of(context).pop(commande);
  }

  Future<void> _ouvrirCatalogue({String? rayon}) async {
    final commande = await Navigator.of(context).push<TovoResponse>(
      MaterialPageRoute(
        builder: (_) => CatalogScreen(
          api: widget.api,
          merchantId: widget.merchantId,
          categoryId: rayon,
          conversationId: widget.conversationId,
        ),
      ),
    );
    if (mounted && commande != null) Navigator.of(context).pop(commande);
  }

  @override
  Widget build(BuildContext context) {
    final couverture = _boutique['cover_url'] as String? ?? '';
    return Scaffold(
      backgroundColor: Colors.white,
      floatingActionButton: PastillePanier(onTap: _ouvrirPanier),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      // La photo monte jusqu'en haut de l'écran, derrière la barre d'état,
      // comme chez Glovo : plus de bande blanche au-dessus de la boutique.
      body: MediaQuery.removePadding(
        context: context,
        removeTop: true,
        child: RefreshIndicator(
          onRefresh: _charger,
          child: CustomScrollView(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: couverture.isEmpty
                    ? _enTeteSimple()
                    : _enTete(couverture),
              ),
              SliverToBoxAdapter(child: _fiche()),
              if (_rayons.length > 1)
                SliverPersistentHeader(
                  pinned: true,
                  // Épinglée, la barre passe sous la barre d'état : elle
                  // réserve cette hauteur au-dessus des onglets.
                  delegate: _Barre(
                    hauteur: _hauteurOnglets + _haut,
                    marge: _haut,
                    child: _onglets(),
                  ),
                ),
              if (_charge && _rayons.isEmpty)
                const SliverToBoxAdapter(child: ReadPlaceholder())
              else if (_erreur != null && _rayons.isEmpty)
                SliverToBoxAdapter(child: _echec())
              else if (_rayons.isEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'Cette boutique n’a pas encore de produits en ligne.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: TovoTheme.inkDoux),
                    ),
                  ),
                )
              else
                SliverList.builder(
                  itemCount: _rayons.length,
                  itemBuilder: (_, i) => _rayon(i),
                ),
              // La pastille panier ne cache pas le dernier produit.
              const SliverToBoxAdapter(child: SizedBox(height: 110)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _boutonRond({
    required IconData icone,
    required String aide,
    required VoidCallback onTap,
  }) => Material(
    color: Colors.white,
    shape: const CircleBorder(),
    elevation: 1,
    child: IconButton(
      tooltip: aide,
      onPressed: onTap,
      icon: Icon(icone, size: 21, color: TovoTheme.ink),
    ),
  );

  Widget _boutons() => Row(
    children: [
      _boutonRond(
        icone: Icons.arrow_back_rounded,
        aide: 'Retour',
        onTap: () => Navigator.of(context).pop(),
      ),
      const Spacer(),
      _boutonRond(
        icone: Icons.search_rounded,
        aide: 'Rechercher dans la boutique',
        onTap: _ouvrirCatalogue,
      ),
    ],
  );

  /// Photo de couverture, le logo logé dans son coin bas gauche.
  /// La hauteur de la barre d'état (le contexte de l'état est au-dessus de
  /// removePadding : il la connaît encore).
  double get _haut => MediaQuery.paddingOf(context).top;

  /// La photo, bord bas droit et net, et le logo à cheval sur la ligne, à
  /// gauche. Plate : l'arrondi (sur la photo, puis sur la page) n'a pas
  /// convaincu, et un bord franc laisse le logo seul marquer la jonction —
  /// comme chez Uber Eats (25/09).
  Widget _enTete(String couverture) {
    final basPhoto = 200 + _haut;
    return SizedBox(
      height: basPhoto + 36,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: basPhoto,
            // Calée à GAUCHE : l'en-tête est plus haut que la couverture (2:1),
            // l'image est donc rognée sur les côtés. Les couvertures portent
            // le logo en haut à droite ; rogné au milieu, il finissait coupé
            // en deux sous le bouton de recherche. Calé à gauche, il sort
            // entier du cadre — le vrai logo est juste en dessous.
            child: CatalogImage(
              couverture,
              fit: BoxFit.cover,
              alignment: Alignment.centerLeft,
              decodeWidth: 900,
              errorBuilder: (_, __, ___) =>
                  const ColoredBox(color: Color(0xFFF4F5F5)),
            ),
          ),
          Positioned(left: 16, right: 16, top: _haut + 8, child: _boutons()),
          Positioned(left: 20, bottom: 0, child: _logo(72)),
        ],
      ),
    );
  }

  /// Sans photo : pas de fausse image, juste les boutons et le logo.
  Widget _enTeteSimple() => Padding(
    padding: EdgeInsets.fromLTRB(16, _haut + 8, 16, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _boutons(),
        if ((_boutique['logo_url'] as String? ?? '').isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 12),
            child: _logo(64),
          ),
      ],
    ),
  );

  Widget _logo(double taille) {
    final logo = _boutique['logo_url'] as String? ?? '';
    return Container(
      width: taille,
      height: taille,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 10)],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: logo.isEmpty
            ? const ColoredBox(color: Color(0xFFF4F5F5))
            : CatalogImage(
                logo,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) =>
                    const ColoredBox(color: Color(0xFFF4F5F5)),
              ),
      ),
    );
  }

  /// Nom, puis l'essentiel : ouverte ou non, et l'adresse.
  ///
  /// Pas de note : 96 boutiques sur 97 ont 5/5 par défaut (base de dev,
  /// 24/09, 7 avis en tout). Afficher « 5,0 » partout serait trompeur.
  Widget _fiche() {
    final ouverte = _boutique['is_open'];
    final adresse = _boutique['address_hint'] as String? ?? '';
    final infos = <String>[
      if (ouverte == true) 'Ouverte',
      if (ouverte == false) 'Fermée pour le moment',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            enPhrase(_boutique['name'] as String?),
            style: const TextStyle(
              fontFamily: TovoTheme.policeNoms,
              fontSize: 28,
              height: 1.15,
              letterSpacing: -0.6,
              fontWeight: FontWeight.w600,
              color: TovoTheme.ink,
            ),
          ),
          if (infos.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                if (ouverte is bool)
                  Container(
                    width: 7,
                    height: 7,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: ouverte ? TovoTheme.success : TovoTheme.inkDoux,
                    ),
                  ),
                Expanded(
                  child: Text(
                    infos.join('  ·  '),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: TovoTheme.ink,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (adresse.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              adresse,
              style: const TextStyle(fontSize: 13, color: TovoTheme.inkDoux),
            ),
          ],
        ],
      ),
    );
  }

  Widget _onglets() => ListView.builder(
    controller: _defileOnglets,
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    itemCount: _rayons.length,
    itemBuilder: (_, i) {
      final choisi = i == _actif;
      return Semantics(
        selected: choisi,
        button: true,
        child: InkWell(
          key: _cleOnglet(i),
          onTap: () => unawaited(_allerAuRayon(i)),
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: choisi ? TovoTheme.ink : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Text(
              _nomRayon(i),
              style: TextStyle(
                fontSize: 14,
                fontWeight: choisi ? FontWeight.w700 : FontWeight.w500,
                color: choisi ? TovoTheme.ink : TovoTheme.inkDoux,
              ),
            ),
          ),
        ),
      );
    },
  );

  String _nomRayon(int i) => enPhrase('${_rayons[i]['name'] ?? ''}');

  /// Au-delà, la flèche mène à tout le rayon.
  static const _apercu = 4;

  /// Un rayon : son nom, puis ses 4 premiers produits EN LIGNE, qu'on fait
  /// défiler du doigt ; au-delà de 4, une flèche ouvre tout le rayon — sur
  /// un écran où l'on passe d'un rayon à l'autre en glissant (demande du
  /// client, 25/09). La carte laisse deviner la suivante au bord droit :
  /// on comprend qu'il y a de quoi faire défiler.
  Widget _rayon(int i) {
    final rayon = _rayons[i];
    final items = (rayon['items'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final montres = items.take(_apercu).toList();
    final plus = items.length > _apercu;
    final largeur = (MediaQuery.sizeOf(context).width - 40 - 14) / 2 * 0.92;
    return Padding(
      key: _cle(i),
      padding: const EdgeInsets.only(top: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _rayons.length == 1 ? 'La carte' : _nomRayon(i),
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.4,
                      color: TovoTheme.ink,
                    ),
                  ),
                ),
                if (plus)
                  Semantics(
                    button: true,
                    label: 'Tout voir, ${_nomRayon(i)}',
                    excludeSemantics: true,
                    child: Material(
                      color: const Color(0xFFF4F5F5),
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => _toutVoir(i),
                        child: const SizedBox(
                          width: 40,
                          height: 40,
                          child: Icon(
                            Icons.arrow_forward_rounded,
                            size: 20,
                            color: TovoTheme.ink,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var k = 0; k < montres.length; k++) ...[
                    if (k > 0) const SizedBox(width: 14),
                    SizedBox(
                      width: largeur,
                      child: ProductTile(
                        data: montres[k],
                        afficherBoutique: false,
                        onOpen: () => _ouvrirProduit(montres[k]),
                        onAdd: () => _ouvrirProduit(montres[k]),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Tout le rayon [i], et les autres à portée de glissement.
  Future<void> _toutVoir(int i) async {
    final commande = await Navigator.of(context).push<TovoResponse>(
      MaterialPageRoute(
        builder: (_) => RayonsScreen(
          api: widget.api,
          rayons: _rayons,
          depart: i,
          conversationId: widget.conversationId,
        ),
      ),
    );
    if (mounted && commande != null) Navigator.of(context).pop(commande);
  }

  Widget _echec() => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      children: [
        Text(_erreur ?? '', textAlign: TextAlign.center),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: () {
            setState(() {
              _charge = true;
              _erreur = null;
            });
            unawaited(_charger());
          },
          child: const Text('Réessayer'),
        ),
      ],
    ),
  );
}

class _Barre extends SliverPersistentHeaderDelegate {
  _Barre({required this.child, required this.hauteur, this.marge = 0});
  final Widget child;
  final double hauteur;

  /// La place de la barre d'état, au-dessus des onglets.
  final double marge;

  @override
  double get minExtent => hauteur;
  @override
  double get maxExtent => hauteur;

  @override
  Widget build(BuildContext context, double shrink, bool overlaps) =>
      DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(
            bottom: BorderSide(
              color: overlaps || shrink > 0
                  ? const Color(0xFFEEF0F0)
                  : Colors.transparent,
            ),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.only(top: marge),
          child: child,
        ),
      );

  @override
  bool shouldRebuild(covariant _Barre old) =>
      old.child != child || old.hauteur != hauteur || old.marge != marge;
}
