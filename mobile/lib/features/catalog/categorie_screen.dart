import 'dart:async';

import 'package:flutter/material.dart';

import '../../components/widgets/pastille_panier.dart';
import '../../components/widgets/read_placeholder.dart';
import '../../core/api.dart';
import '../../core/noms.dart';
import '../../core/catalog_image.dart';
import '../../core/icones_3d.dart';
import '../../core/panier.dart';
import '../../core/theme.dart';
import 'boutique_screen.dart';
import 'cart_screen.dart';
import 'catalog_screen.dart';

/// Une catégorie (Restaurants, Supermarché…), à la Glovo : un grand titre,
/// une recherche qui ne cherche que là, des sous-catégories pour filtrer,
/// puis les boutiques en grandes cartes avec leur photo.
///
/// L'ancienne page était une liste de logos intitulée « Les bonnes
/// adresses. » : rien pour choisir entre trente-quatre restaurants, sinon
/// leur nom. Ici, « Burgers » ne garde que les treize qui en font.
///
/// Monochrome : pas de bandeaux promo rouges ni de cœurs.
class CategorieScreen extends StatefulWidget {
  const CategorieScreen({
    super.key,
    required this.api,
    this.categoryId,
    this.nom = '',
    this.conversationId,
  });

  final TovoApi api;

  /// Sans catégorie : TOUTES les boutiques (« Explorer les boutiques »).
  final String? categoryId;

  /// Le nom déjà connu (tuile touchée) : le titre s'affiche tout de suite.
  final String nom;
  final String? conversationId;

  @override
  State<CategorieScreen> createState() => _CategorieScreenState();
}

class _CategorieScreenState extends State<CategorieScreen> {
  final _recherche = TextEditingController();
  late String _nom = widget.nom;
  List<Map<String, dynamic>> _boutiques = [];
  List<Map<String, dynamic>> _rayons = [];
  String? _rayon;
  bool _ouvertesSeulement = false;
  bool _charge = true;
  bool _redirige = false;
  String? _erreur;

  String get _chemin => widget.categoryId == null
      ? '/boutiques'
      : '/categories/${widget.categoryId}/boutiques';

  @override
  void initState() {
    super.initState();
    unawaited(_charger());
  }

  @override
  void dispose() {
    _recherche.dispose();
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
    } else if (_boutiques.isEmpty) {
      setState(() {
        _charge = false;
        _erreur = reponse.content;
      });
    }
  }

  void _appliquer(TovoResponse reponse) {
    final categorie = reponse.raw['category'];
    final boutiques = reponse.list('merchants');
    // Catégorie qui se parcourt par produits (Beauté…), ou une seule
    // boutique : la page intermédiaire n'apprendrait rien au client.
    if (!_redirige &&
        widget.categoryId != null &&
        (reponse.raw['mode'] == 'products' || boutiques.length == 1)) {
      _redirige = true;
      final vers = boutiques.length == 1
          ? BoutiqueScreen(
              api: widget.api,
              merchantId: boutiques.single['id'] as String,
              apercu: boutiques.single,
              conversationId: widget.conversationId,
            )
          : CatalogScreen(
              api: widget.api,
              categoryId: widget.categoryId,
              conversationId: widget.conversationId,
            );
      unawaited(
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<TovoResponse>(builder: (_) => vers),
        ),
      );
      return;
    }
    setState(() {
      _charge = false;
      _erreur = null;
      if (categorie is Map && categorie['name'] is String) {
        _nom = categorie['name'] as String;
      }
      _boutiques = boutiques;
      _rayons = reponse.list('rayons');
      if (_rayon != null && !_rayons.any((r) => r['name'] == _rayon)) {
        _rayon = null;
      }
    });
  }

  List<Map<String, dynamic>> get _visibles {
    final texte = _normaliser(_recherche.text);
    return _boutiques.where((b) {
      if (_ouvertesSeulement && b['is_open'] != true) return false;
      final rayons = (b['rayons'] as List? ?? const []).cast<String>();
      if (_rayon != null && !rayons.contains(_rayon)) return false;
      if (texte.isEmpty) return true;
      // Le nom de la boutique, ou ce qu'elle sert : « pizza » trouve les
      // boutiques qui ont un rayon Pizza.
      return _normaliser('${b['name']}').contains(texte) ||
          rayons.any((r) => _normaliser(r).contains(texte));
    }).toList();
  }

  bool get _filtre =>
      _rayon != null || _ouvertesSeulement || _recherche.text.isNotEmpty;

  void _reinitialiser() => setState(() {
    _rayon = null;
    _ouvertesSeulement = false;
    _recherche.clear();
  });

  Future<void> _ouvrirBoutique(Map<String, dynamic> boutique) async {
    final commande = await Navigator.of(context).push<TovoResponse>(
      MaterialPageRoute(
        builder: (_) => BoutiqueScreen(
          api: widget.api,
          merchantId: boutique['id'] as String,
          apercu: boutique,
          conversationId: widget.conversationId,
        ),
      ),
    );
    if (mounted && commande != null) Navigator.of(context).pop(commande);
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

  @override
  Widget build(BuildContext context) {
    final visibles = _visibles;
    final fermees = _boutiques.where((b) => b['is_open'] != true).length;
    return Scaffold(
      backgroundColor: Colors.white,
      floatingActionButton: PastillePanier(onTap: _ouvrirPanier),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _charger,
          child: CustomScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(child: _enTete()),
              if (_rayons.isNotEmpty || fermees > 0)
                SliverToBoxAdapter(child: _filtres(fermees)),
              if (_charge && _boutiques.isEmpty)
                const SliverToBoxAdapter(child: ReadPlaceholder())
              else if (_erreur != null && _boutiques.isEmpty)
                SliverToBoxAdapter(child: _echec())
              else ...[
                SliverToBoxAdapter(child: _compte(visibles.length)),
                if (visibles.isEmpty)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(20, 24, 20, 0),
                      child: Text(
                        'Aucune boutique ne correspond.',
                        style: TextStyle(color: TovoTheme.inkDoux),
                      ),
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  sliver: SliverList.builder(
                    itemCount: visibles.length,
                    itemBuilder: (_, i) => _carte(visibles[i]),
                  ),
                ),
              ],
              const SliverToBoxAdapter(child: SizedBox(height: 110)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _enTete() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Material(
          color: const Color(0xFFF4F5F5),
          shape: const CircleBorder(),
          child: IconButton(
            tooltip: 'Retour',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back_rounded, color: TovoTheme.ink),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 18, 4, 18),
          child: Text(
            _nom,
            style: const TextStyle(
              fontSize: 32,
              height: 1.1,
              letterSpacing: -1,
              fontWeight: FontWeight.w700,
              color: TovoTheme.ink,
            ),
          ),
        ),
        TextField(
          controller: _recherche,
          onChanged: (_) => setState(() {}),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search_rounded, size: 21),
            hintText: _nom.isEmpty ? 'Rechercher' : 'Rechercher dans $_nom',
            hintStyle: const TextStyle(fontSize: 14, color: TovoTheme.inkDoux),
            filled: true,
            fillColor: const Color(0xFFF4F5F5),
            contentPadding: const EdgeInsets.symmetric(vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(28),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(28),
              borderSide: BorderSide.none,
            ),
            suffixIcon: _recherche.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Effacer la recherche',
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () => setState(_recherche.clear),
                  ),
          ),
        ),
      ],
    ),
  );

  /// Les sous-catégories en icônes, comme chez Glovo, puis « Ouvertes ».
  /// Une sous-catégorie à la fois : on retouche la même pour la retirer.
  Widget _filtres(int fermees) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (_rayons.isNotEmpty)
        SizedBox(
          height: 128 + (MediaQuery.textScalerOf(context).scale(13) - 13) * 2.6,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 18, 12, 0),
            children: [
              for (final rayon in _rayons)
                _IconeRayon(
                  libelle: enPhrase('${rayon['name']}'),
                  icone:
                      Icones3d.categorie(rayon['slug'] as String?) ??
                      Icones3d.rayon('${rayon['name']}') ??
                      'assets/icons/3d/colis.png',
                  choisie: _rayon == rayon['name'],
                  onTap: () => setState(
                    () => _rayon = _rayon == rayon['name']
                        ? null
                        : rayon['name'] as String,
                  ),
                ),
            ],
          ),
        ),
      if (fermees > 0)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: SizedBox(
            height: 40,
            child: Row(
              children: [
                _Pastille(
                  libelle: 'Ouvertes',
                  choisie: _ouvertesSeulement,
                  onTap: () =>
                      setState(() => _ouvertesSeulement = !_ouvertesSeulement),
                ),
              ],
            ),
          ),
        ),
    ],
  );

  Widget _compte(int n) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 10, 12, 6),
    child: Row(
      children: [
        Expanded(
          child: Text(
            _filtre
                ? '$n résultat${n > 1 ? 's' : ''}'
                : '$n boutique${n > 1 ? 's' : ''}',
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: TovoTheme.inkDoux,
            ),
          ),
        ),
        if (_filtre)
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: TovoTheme.ink,
              backgroundColor: const Color(0xFFF4F5F5),
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
            ),
            onPressed: _reinitialiser,
            child: const Text(
              'Réinitialiser',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
      ],
    ),
  );

  /// Une boutique : sa photo en grand, son nom, et l'essentiel en une ligne.
  Widget _carte(Map<String, dynamic> b) {
    final ouverte = b['is_open'] == true;
    final couverture = b['cover_url'] as String? ?? '';
    final logo = b['logo_url'] as String? ?? '';
    final distance = (b['distance_m'] as num?)?.toInt();
    final infos = <String>[
      ouverte ? 'Ouverte' : 'Fermée pour le moment',
      if (distance != null) _distance(distance),
    ];
    const vide = ColoredBox(color: Color(0xFFF4F5F5));
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 6),
      child: Semantics(
        button: true,
        label: '${b['name']}, ${infos.join(', ')}',
        excludeSemantics: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _ouvrirBoutique(b),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Fermée : aussi belle qu'une autre. On parcourt souvent tard ;
              // la ligne « Fermée pour le moment » suffit à le dire.
              ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: AspectRatio(
                  aspectRatio: 16 / 8,
                  child: couverture.isNotEmpty
                      ? Stack(
                          fit: StackFit.expand,
                          children: [
                            CatalogImage(
                              couverture,
                              fit: BoxFit.cover,
                              decodeWidth: 900,
                              errorBuilder: (_, __, ___) => vide,
                            ),
                            // Le logo dans une encoche, coin bas droit :
                            // un liseré blanc, couleur de la page, le
                            // découpe dans la photo (croquis du client).
                            if (logo.isNotEmpty)
                              Positioned(
                                right: 0,
                                bottom: 0,
                                child: _Encoche(logo: logo),
                              ),
                          ],
                        )
                      : logo.isNotEmpty
                      ? ColoredBox(
                          color: const Color(0xFFF4F5F5),
                          child: Center(
                            child: SizedBox(
                              width: 84,
                              height: 84,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(16),
                                child: CatalogImage(
                                  logo,
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, __, ___) => vide,
                                ),
                              ),
                            ),
                          ),
                        )
                      : vide,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                enPhrase(b['name'] as String?),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: TovoTheme.policeNoms,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: TovoTheme.ink,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    margin: const EdgeInsets.only(right: 7),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: ouverte ? TovoTheme.success : TovoTheme.inkDoux,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      infos.join('  ·  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        color: TovoTheme.inkDoux,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
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

/// Le logo d'une boutique logé dans le coin bas droit de sa photo. Ses
/// bords droit et bas prolongent ceux de la carte (le coin arrondi de la
/// carte le découpe) ; son coin haut gauche est simplement arrondi — pas de
/// liseré blanc autour (demande du client, 25/09).
class _Encoche extends StatelessWidget {
  const _Encoche({required this.logo});

  final String logo;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: const BorderRadius.only(topLeft: Radius.circular(14)),
    child: SizedBox.square(
      dimension: 58,
      child: ColoredBox(
        color: Colors.white,
        child: CatalogImage(
          logo,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

/// Une sous-catégorie : l'icône 3D sur un disque clair, le nom dessous.
/// Choisie : un anneau et une coche, en noir — pas de couleur ajoutée.
class _IconeRayon extends StatelessWidget {
  const _IconeRayon({
    required this.libelle,
    required this.icone,
    required this.choisie,
    required this.onTap,
  });

  final String libelle;
  final String icone;
  final bool choisie;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: choisie,
    label: libelle,
    excludeSemantics: true,
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: SizedBox(
        width: 84,
        child: Column(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: 64,
                  height: 64,
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF4F5F5),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: choisie ? TovoTheme.ink : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: Image.asset(
                    icone,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
                if (choisie)
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: TovoTheme.ink,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: const Icon(
                        Icons.check_rounded,
                        size: 13,
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              libelle,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                height: 1.15,
                fontWeight: choisie ? FontWeight.w700 : FontWeight.w500,
                color: TovoTheme.ink,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Pastille extends StatelessWidget {
  const _Pastille({
    required this.libelle,
    required this.choisie,
    required this.onTap,
  });

  final String libelle;
  final bool choisie;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: Semantics(
      selected: choisie,
      button: true,
      child: Material(
        color: choisie ? TovoTheme.ink : const Color(0xFFF4F5F5),
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    libelle,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: choisie ? Colors.white : TovoTheme.ink,
                    ),
                  ),
                  if (choisie) ...[
                    const SizedBox(width: 6),
                    const Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: Colors.white,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

String _distance(int metres) => metres < 1000
    ? '$metres m'
    : '${(metres / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';

/// Minuscules, sans accents : « Crêpes » se trouve en tapant « crepes ».
String _normaliser(String texte) {
  const avec = 'àâäéèêëîïôöùûüç';
  const sans = 'aaaeeeeiioouuuc';
  final bas = texte.toLowerCase().trim();
  final tampon = StringBuffer();
  for (final c in bas.split('')) {
    final i = avec.indexOf(c);
    tampon.write(i < 0 ? c : sans[i]);
  }
  return tampon.toString();
}
