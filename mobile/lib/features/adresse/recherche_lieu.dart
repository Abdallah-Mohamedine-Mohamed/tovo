import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/theme.dart';

/// Un quartier ou un repère de Niamey (nos lieux OpenStreetMap).
class LieuTrouve {
  const LieuTrouve({
    required this.nom,
    required this.genre,
    required this.lat,
    required this.lng,
    this.quartier,
  });

  factory LieuTrouve.depuis(Map<String, dynamic> j) => LieuTrouve(
    nom: '${j['nom']}',
    genre: '${j['genre']}',
    quartier: j['quartier'] as String?,
    lat: (j['lat'] as num).toDouble(),
    lng: (j['lng'] as num).toDouble(),
  );

  final String nom;
  final String genre;
  final String? quartier;
  final double lat;
  final double lng;

  bool get estUnQuartier => genre == 'quartier' || genre == 'village';

  /// « Marché · Talladjé ».
  String get precision {
    final type = switch (genre) {
      'quartier' => 'Quartier',
      'village' => 'Village',
      'mosquée' => 'Mosquée',
      'église' => 'Église',
      'école' => 'École',
      'santé' => 'Santé',
      'pharmacie' => 'Pharmacie',
      'marché' => 'Marché',
      'supermarché' => 'Supermarché',
      'banque' => 'Banque',
      'station-service' => 'Station-service',
      'hôtel' => 'Hôtel',
      'restaurant' => 'Restaurant',
      'rue' => 'Rue',
      _ => 'Repère',
    };
    if (estUnQuartier || quartier == null || quartier == nom) {
      return '$type · Niamey';
    }
    return '$type · $quartier';
  }

  /// L'icône 3D (Fluent, la famille de l'écran d'accueil) de son genre.
  String get icone =>
      'assets/icons/3d/${switch (genre) {
        'quartier' || 'village' => 'lieu-quartier',
        'mosquée' => 'lieu-mosquee',
        'église' => 'lieu-eglise',
        'école' => 'lieu-ecole',
        'santé' => 'lieu-sante',
        'pharmacie' => 'lieu-pharmacie',
        'marché' || 'supermarché' => 'marche',
        'banque' => 'lieu-banque',
        'station-service' => 'lieu-station',
        'hôtel' => 'lieu-hotel',
        'restaurant' => 'restaurants',
        'boutique' => 'boutiques',
        'bureau' || 'police' || 'gare' => 'lieu-administration',
        'loisir' || 'tourisme' => 'lieu-parc',
        'rue' => 'lieu-carte',
        _ => 'lieu-epingle',
      }}.png';
}

/// Chercher un quartier ou un repère pendant la frappe : « tallad » →
/// Talladjé, Talladjé Est, CSI de Talladjé… Les quartiers d'abord, puis les
/// repères. Un toucher : la carte y va.
class RechercheLieuScreen extends StatefulWidget {
  const RechercheLieuScreen({required this.api, super.key});

  final TovoApi api;

  @override
  State<RechercheLieuScreen> createState() => _RechercheLieuScreenState();
}

class _RechercheLieuScreenState extends State<RechercheLieuScreen> {
  final _saisie = TextEditingController();
  Timer? _attente;
  List<LieuTrouve> _lieux = const [];
  bool _cherche = false;
  int _generation = 0;

  @override
  void dispose() {
    _attente?.cancel();
    _saisie.dispose();
    super.dispose();
  }

  void _changer(String texte) {
    _attente?.cancel();
    // Une requête par pause de frappe, pas une par lettre.
    _attente = Timer(const Duration(milliseconds: 220), () => _chercher(texte));
  }

  Future<void> _chercher(String texte) async {
    final generation = ++_generation;
    if (texte.trim().length < 2) {
      setState(() {
        _lieux = const [];
        _cherche = false;
      });
      return;
    }
    setState(() => _cherche = true);
    final reponse = await widget.api.get(
      '/lieux/recherche',
      query: {'q': texte.trim()},
    );
    if (!mounted || generation != _generation) return;
    setState(() {
      _cherche = false;
      _lieux = ((reponse.raw['lieux'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(LieuTrouve.depuis)
          .toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final quartiers = _lieux.where((l) => l.estUnQuartier).toList();
    final reperes = _lieux.where((l) => !l.estUnQuartier).toList();
    final aucun =
        !_cherche && _saisie.text.trim().length >= 2 && _lieux.isEmpty;
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  IconButton.filledTonal(
                    tooltip: 'Retour à la carte',
                    style: IconButton.styleFrom(
                      backgroundColor: TovoTheme.bloc,
                      fixedSize: const Size(46, 46),
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(
                      Icons.arrow_back_rounded,
                      color: TovoTheme.ink,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _saisie,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      onChanged: _changer,
                      style: const TextStyle(fontSize: 16),
                      decoration: InputDecoration(
                        hintText: 'Quartier, repère…',
                        prefixIcon: const Icon(
                          Icons.search_rounded,
                          color: TovoTheme.ink,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 12,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(23),
                          borderSide: const BorderSide(color: TovoTheme.line),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(23),
                          borderSide: const BorderSide(
                            color: TovoTheme.ink,
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_cherche) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: ListView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  if (quartiers.isNotEmpty) ...[
                    const _Section('Quartiers'),
                    for (final l in quartiers) _Ligne(lieu: l),
                  ],
                  if (reperes.isNotEmpty) ...[
                    const _Section('Repères'),
                    for (final l in reperes) _Ligne(lieu: l),
                  ],
                  if (aucun)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 24, 20, 0),
                      child: Text(
                        'Aucun lieu de ce nom. Placez l’épingle sur la carte : '
                        'le livreur vous appellera si besoin.',
                        style: TextStyle(
                          fontSize: 14.5,
                          height: 1.4,
                          color: TovoTheme.inkDoux,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: FilledButton.tonalIcon(
                onPressed: () => Navigator.of(context).pop(),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  backgroundColor: TovoTheme.bloc,
                  foregroundColor: TovoTheme.ink,
                ),
                icon: const Icon(Icons.place_outlined, size: 20),
                label: const Text(
                  'Placer l’épingle sur la carte',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.texte);

  final String texte;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
    child: Text(
      texte.toUpperCase(),
      style: const TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.6,
        color: TovoTheme.inkDoux,
      ),
    ),
  );
}

class _Ligne extends StatelessWidget {
  const _Ligne({required this.lieu});

  final LieuTrouve lieu;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
    leading: Image.asset(lieu.icone, width: 38, height: 38),
    title: Text(
      lieu.nom,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    ),
    subtitle: Text(
      lieu.precision,
      style: const TextStyle(fontSize: 13.5, color: TovoTheme.inkDoux),
    ),
    onTap: () => Navigator.of(context).pop(lieu),
  );
}
