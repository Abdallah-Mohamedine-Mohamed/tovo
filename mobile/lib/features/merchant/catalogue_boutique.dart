import 'package:flutter/material.dart';

import '../../components/registry.dart';
import '../../core/catalog_image.dart';
import '../../core/theme.dart';
import 'merchant_controller.dart';

/// Le catalogue du boutiquier (18/10).
///
/// Avant : une seule liste alphabétique, sans photo ni rayon. Supportable à
/// 30 plats ; inutilisable à 1 000 parfums — Niger Beauté. Un boutiquier
/// cherche un produit précis (« le Lattafa noir ») ou parcourt un rayon ;
/// il reconnaît un flacon à sa photo bien avant de lire son nom.
///
/// D'où : une recherche, les rayons en puces avec leur nombre, deux filtres
/// qui servent vraiment (ce qui est en rupture, ce qui n'a pas de photo), et
/// une vignette sur chaque ligne.
class CatalogueBoutique extends StatefulWidget {
  const CatalogueBoutique({
    super.key,
    required this.controller,
    required this.onEditer,
  });

  final MerchantController controller;
  final void Function(Map<String, dynamic>) onEditer;

  @override
  State<CatalogueBoutique> createState() => _CatalogueBoutiqueState();
}

enum _Filtre { tout, rupture, sansPhoto }

/// Le rayon choisi : « tous », ou un rayon précis (dont « sans rayon », d'id nul).
class _Choix {
  const _Choix.tous() : tous = true, id = null;
  const _Choix.rayon(this.id) : tous = false;
  final bool tous;
  final String? id;
}

class _CatalogueBoutiqueState extends State<CatalogueBoutique> {
  final _recherche = TextEditingController();
  String _texte = '';
  _Choix _rayon = const _Choix.tous();
  _Filtre _filtre = _Filtre.tout;

  @override
  void dispose() {
    _recherche.dispose();
    super.dispose();
  }

  /// Minuscules sans accents : « creme » doit trouver « Crème ».
  static String _plat(String s) {
    const avec = 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ';
    const sans = 'aaaaaaceeeeiiiinooooouuuuyyoa';
    final bas = s.toLowerCase();
    final sortie = StringBuffer();
    for (final c in bas.split('')) {
      final i = avec.indexOf(c);
      sortie.write(i < 0 ? c : sans[i]);
    }
    return sortie.toString();
  }

  bool _garde(Map<String, dynamic> p) {
    if (!_rayon.tous && p['category_id'] != _rayon.id) return false;
    final disponible = p['is_available'] as bool? ?? true;
    final photo = ((p['image_url'] as String?) ?? '').isNotEmpty;
    if (_filtre == _Filtre.rupture && disponible) return false;
    if (_filtre == _Filtre.sansPhoto && photo) return false;
    if (_texte.isEmpty) return true;
    final nom = _plat((p['name'] as String?) ?? '');
    // Chaque mot tapé doit se trouver dans le nom, dans n'importe quel ordre :
    // « noir lattafa » trouve « Lattafa Maahir Black… Noir ».
    return _plat(
      _texte,
    ).split(RegExp(r'\s+')).where((m) => m.isNotEmpty).every(nom.contains);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final produits = c.produits;

    if (produits.isEmpty) {
      return ListView(
        children: const [
          _Vide(
            titre: 'Catalogue vide',
            detail:
                'Touchez « Produit » en bas à droite pour ajouter votre premier article.',
          ),
        ],
      );
    }

    final rayons = c.rayons;
    final ruptures = produits
        .where((p) => !(p['is_available'] as bool? ?? true))
        .length;
    final sansPhoto = produits
        .where((p) => ((p['image_url'] as String?) ?? '').isEmpty)
        .length;
    final visibles = produits.where(_garde).toList(growable: false);

    // Regroupé par rayon seulement quand on parcourt tout, sans recherche ni
    // filtre : dès qu'on cherche, des titres de rayon ne feraient que gêner.
    final grouper =
        _rayon.tous &&
        _texte.isEmpty &&
        _filtre == _Filtre.tout &&
        rayons.length > 1;
    final lignes = <Object>[];
    if (grouper) {
      for (final r in rayons) {
        final dedans = visibles.where((p) => p['category_id'] == r.id).toList();
        if (dedans.isEmpty) continue;
        lignes.add(r);
        lignes.addAll(dedans);
      }
    } else {
      lignes.addAll(visibles);
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            controller: _recherche,
            onChanged: (v) => setState(() => _texte = v.trim()),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Rechercher parmi ${produits.length} produits',
              hintStyle: const TextStyle(
                fontSize: 14,
                color: TovoTheme.inkDoux,
              ),
              prefixIcon: const Icon(
                Icons.search,
                size: 20,
                color: TovoTheme.inkDoux,
              ),
              suffixIcon: _texte.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Effacer',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => setState(() {
                        _recherche.clear();
                        _texte = '';
                      }),
                    ),
              filled: true,
              fillColor: Colors.white,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(TovoTheme.radiusSmall),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        SizedBox(
          height: 38,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              _Puce(
                libelle: 'Tout',
                nombre: produits.length,
                choisie: _rayon.tous,
                onTap: () => setState(() => _rayon = const _Choix.tous()),
              ),
              for (final r in rayons)
                _Puce(
                  libelle: r.nom,
                  nombre: r.nombre,
                  choisie: !_rayon.tous && _rayon.id == r.id,
                  onTap: () => setState(() => _rayon = _Choix.rayon(r.id)),
                ),
            ],
          ),
        ),
        if (ruptures > 0 || sansPhoto > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                if (ruptures > 0)
                  _Filtrage(
                    libelle: 'En rupture',
                    nombre: ruptures,
                    actif: _filtre == _Filtre.rupture,
                    onTap: () => setState(
                      () => _filtre = _filtre == _Filtre.rupture
                          ? _Filtre.tout
                          : _Filtre.rupture,
                    ),
                  ),
                if (sansPhoto > 0)
                  _Filtrage(
                    libelle: 'Sans photo',
                    nombre: sansPhoto,
                    actif: _filtre == _Filtre.sansPhoto,
                    onTap: () => setState(
                      () => _filtre = _filtre == _Filtre.sansPhoto
                          ? _Filtre.tout
                          : _Filtre.sansPhoto,
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 6),
        Expanded(
          child: lignes.isEmpty
              ? ListView(
                  children: const [
                    _Vide(
                      titre: 'Aucun produit',
                      detail: 'Rien ne correspond à cette recherche.',
                    ),
                  ],
                )
              : ListView.builder(
                  // De la place sous la dernière ligne pour le bouton « Produit ».
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                  itemCount: lignes.length,
                  itemBuilder: (context, i) {
                    final l = lignes[i];
                    if (l is Map<String, dynamic>) {
                      return _LigneProduit(
                        produit: l,
                        onTap: () => widget.onEditer(l),
                        onDisponible: () =>
                            widget.controller.basculerDisponibilite(l),
                      );
                    }
                    final r = l as ({String? id, String nom, int nombre});
                    return Padding(
                      padding: EdgeInsets.fromLTRB(4, i == 0 ? 6 : 18, 4, 8),
                      child: Text(
                        '${r.nom}  ·  ${r.nombre}',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: TovoTheme.inkDoux,
                          letterSpacing: 0.2,
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _LigneProduit extends StatelessWidget {
  const _LigneProduit({
    required this.produit,
    required this.onTap,
    required this.onDisponible,
  });

  final Map<String, dynamic> produit;
  final VoidCallback onTap;
  final VoidCallback onDisponible;

  @override
  Widget build(BuildContext context) {
    final disponible = produit['is_available'] as bool? ?? true;
    final image = (produit['image_url'] as String?) ?? '';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
            child: Row(
              children: [
                // Les images du catalogue sont sur fond blanc : `contain`,
                // pour voir le flacon entier plutôt qu'un bouchon rogné.
                Opacity(
                  opacity: disponible ? 1 : 0.45,
                  child: Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      color: image.isEmpty ? TovoTheme.bloc : Colors.white,
                      borderRadius: BorderRadius.circular(
                        TovoTheme.radiusSmall,
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: image.isEmpty
                        ? const Icon(
                            Icons.photo_camera_outlined,
                            size: 20,
                            color: TovoTheme.inkDoux,
                          )
                        : CatalogImage(
                            image,
                            fit: BoxFit.contain,
                            decodeWidth: 180,
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (produit['name'] as String?) ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          height: 1.25,
                          fontWeight: FontWeight.w600,
                          color: disponible ? TovoTheme.ink : TovoTheme.inkDoux,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        disponible
                            ? Money.format(
                                (produit['price'] as num?)?.toInt() ?? 0,
                              )
                            : '${Money.format((produit['price'] as num?)?.toInt() ?? 0)}  ·  en rupture',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: disponible ? TovoTheme.ink : TovoTheme.inkDoux,
                        ),
                      ),
                    ],
                  ),
                ),
                // Rupture de stock en un geste : l'action la plus fréquente,
                // elle ne doit pas demander d'ouvrir la fiche.
                Switch(
                  value: disponible,
                  activeThumbColor: TovoTheme.success,
                  onChanged: (_) => onDisponible(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Une puce de rayon. Choisie : pleine et sombre ; sinon : blanche.
class _Puce extends StatelessWidget {
  const _Puce({
    required this.libelle,
    required this.nombre,
    required this.choisie,
    required this.onTap,
  });

  final String libelle;
  final int nombre;
  final bool choisie;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: choisie ? TovoTheme.ink : Colors.white,
        borderRadius: BorderRadius.circular(TovoTheme.radiusChip),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(TovoTheme.radiusChip),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Center(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: libelle,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    TextSpan(
                      text: '  $nombre',
                      style: TextStyle(
                        color: choisie ? Colors.white70 : TovoTheme.inkDoux,
                      ),
                    ),
                  ],
                ),
                style: TextStyle(
                  fontSize: 13,
                  color: choisie ? Colors.white : TovoTheme.ink,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Un filtre rapide, plus discret qu'un rayon : texte souligné d'un fond quand actif.
class _Filtrage extends StatelessWidget {
  const _Filtrage({
    required this.libelle,
    required this.nombre,
    required this.actif,
    required this.onTap,
  });

  final String libelle;
  final int nombre;
  final bool actif;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: actif ? TovoTheme.blocPresse : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                actif ? Icons.check_box : Icons.check_box_outline_blank,
                size: 16,
                color: TovoTheme.inkDoux,
              ),
              const SizedBox(width: 6),
              Text(
                '$libelle  $nombre',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: TovoTheme.inkDoux,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Vide extends StatelessWidget {
  const _Vide({required this.titre, required this.detail});

  final String titre;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 32),
      child: Column(
        children: [
          const Icon(
            Icons.inventory_2_outlined,
            size: 40,
            color: TovoTheme.muted,
          ),
          const SizedBox(height: 12),
          Text(
            titre,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: TovoTheme.inkDoux),
          ),
        ],
      ),
    );
  }
}
