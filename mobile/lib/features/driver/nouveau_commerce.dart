import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api.dart';
import '../../core/location.dart';
import '../../core/theme.dart';

/// Relever un commerce sur le terrain (07/10).
///
/// Le livreur est devant la devanture : une photo, le point GPS (pris tout
/// seul), le nom, le type, et le téléphone s'il est écrit sur l'enseigne.
/// La fiche part « proposée » ; l'équipe la valide en regardant la photo, et
/// le commerce apparaît alors aux clients. Tovo connaît ainsi les commerces
/// de Niamey que Google ne connaît pas.
class NouveauCommerce extends StatefulWidget {
  const NouveauCommerce({super.key, required this.api});

  final TovoApi api;

  @override
  State<NouveauCommerce> createState() => _NouveauCommerceState();
}

/// Les catégories de base, si le serveur ne répond pas (migration 0078 :
/// les mêmes clés). Le serveur ajoute celles que les livreurs ont créées.
const Map<String, String> _categoriesDeBase = {
  'boutique': 'Boutique',
  'supermarche': 'Supermarché',
  'restaurant': 'Restaurant',
  'grillades': 'Grillades',
  'vetements': 'Vêtements',
  'beaute': 'Beauté',
  'electronique': 'Téléphones',
  'pharmacie': 'Pharmacie',
  'boulangerie': 'Boulangerie',
  'boucherie': 'Boucherie',
  'quincaillerie': 'Quincaillerie',
  'marche': 'Marché',
};

class _NouveauCommerceState extends State<NouveauCommerce> {
  final _nom = TextEditingController();
  final _telephone = TextEditingController();
  final _repere = TextEditingController();
  // Les catégories (08/10) : plusieurs par commerce, et le livreur peut en
  // créer une quand elle manque.
  Map<String, String> _categories = Map.of(_categoriesDeBase);
  final _choisies = <String>[];
  static const _maxCategories = 5;
  File? _photo;
  Position? _position;
  bool _gpsEnCours = true;
  bool _envoi = false;
  String? _erreur;

  @override
  void initState() {
    super.initState();
    unawaited(_relever());
    unawaited(_chargerCategories());
  }

  Future<void> _chargerCategories() async {
    final r = await widget.api.get('/livreur/categories');
    if (!mounted || !r.ok) return;
    final liste = r.list('categories');
    if (liste.isEmpty) return;
    setState(() {
      _categories = {for (final c in liste) '${c['slug']}': '${c['libelle']}'};
    });
  }

  void _basculer(String slug) {
    setState(() {
      if (_choisies.remove(slug)) return;
      if (_choisies.length < _maxCategories) _choisies.add(slug);
    });
  }

  /// Une catégorie qui manque : le livreur la nomme, elle est créée et
  /// choisie aussitôt (l'équipe la valide ensuite).
  Future<void> _nouvelleCategorie() async {
    final champ = TextEditingController();
    final libelle = await showDialog<String>(
      context: context,
      builder: (contexte) => AlertDialog(
        title: const Text('Nouvelle catégorie'),
        content: TextField(
          controller: champ,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          maxLength: 60,
          decoration: const InputDecoration(
            hintText: 'Ex. : Pièces auto, Friperie, Couture',
          ),
          onSubmitted: (v) => Navigator.of(contexte).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(contexte).pop(),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: TovoTheme.ink),
            onPressed: () => Navigator.of(contexte).pop(champ.text.trim()),
            child: const Text('Ajouter'),
          ),
        ],
      ),
    );
    champ.dispose();
    if (libelle == null || libelle.length < 2 || !mounted) return;
    final r = await widget.api.post('/livreur/categories', {
      'libelle': libelle,
    });
    if (!mounted) return;
    final c = r.raw['categorie'];
    if (!r.ok || c is! Map) {
      setState(
        () =>
            _erreur = r.content.isEmpty ? 'Catégorie non ajoutée.' : r.content,
      );
      return;
    }
    final slug = '${c['slug']}';
    setState(() {
      _categories = {..._categories, slug: '${c['libelle']}'};
      if (!_choisies.contains(slug) && _choisies.length < _maxCategories) {
        _choisies.add(slug);
      }
    });
  }

  @override
  void dispose() {
    _nom.dispose();
    _telephone.dispose();
    _repere.dispose();
    super.dispose();
  }

  /// Le point GPS, pris devant la devanture. Toujours un relevé frais : une
  /// position d'il y a dix minutes placerait le commerce ailleurs.
  Future<void> _relever() async {
    setState(() => _gpsEnCours = true);
    final p = await TovoLocation.current(requestPermission: true);
    if (!mounted) return;
    setState(() {
      _position = p;
      _gpsEnCours = false;
    });
  }

  Future<void> _photographier() async {
    final fichier = await ImagePicker().pickImage(
      source: ImageSource.camera,
      maxWidth: 1280,
      imageQuality: 70,
    );
    if (fichier == null || !mounted) return;
    setState(() => _photo = File(fichier.path));
  }

  bool get _pret =>
      _nom.text.trim().length >= 2 &&
      _choisies.isNotEmpty &&
      _position != null &&
      _photo != null &&
      !_envoi;

  Future<void> _envoyer() async {
    final position = _position;
    if (!_pret || position == null) return;
    setState(() {
      _envoi = true;
      _erreur = null;
    });
    final photo = _photo;
    final reponse = await widget.api.post('/livreur/commerces', {
      'nom': _nom.text.trim(),
      'categories': _choisies,
      'telephone': _telephone.text.trim().isEmpty
          ? null
          : _telephone.text.trim(),
      'repere': _repere.text.trim().isEmpty ? null : _repere.text.trim(),
      'lat': position.latitude,
      'lng': position.longitude,
      'precision_m': position.accuracy,
      if (photo != null)
        'photo': {
          'mime': 'image/jpeg',
          'data': base64Encode(await photo.readAsBytes()),
        },
    });
    if (!mounted) return;
    if (reponse.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Merci ! « ${_nom.text.trim()} » sera vérifié par l’équipe.',
          ),
        ),
      );
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _envoi = false;
      _erreur = reponse.content;
    });
  }

  @override
  Widget build(BuildContext context) {
    final position = _position;
    return Scaffold(
      backgroundColor: TovoTheme.surface,
      appBar: AppBar(
        title: const Text(
          'Ajouter un commerce',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Devant la devanture : photo, nom et type. La position est prise '
            'toute seule.',
            style: TextStyle(fontSize: 14, color: TovoTheme.inkDoux),
          ),
          const SizedBox(height: 16),
          // La photo : la preuve que l'équipe regarde pour valider.
          GestureDetector(
            onTap: _envoi ? null : _photographier,
            child: Container(
              height: 190,
              decoration: BoxDecoration(
                color: TovoTheme.bloc,
                borderRadius: BorderRadius.circular(TovoTheme.radiusCard),
                border: Border.all(color: TovoTheme.line),
              ),
              clipBehavior: Clip.antiAlias,
              child: _photo != null
                  ? Image.file(
                      _photo!,
                      fit: BoxFit.cover,
                      width: double.infinity,
                    )
                  : const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.photo_camera_outlined,
                          size: 34,
                          color: TovoTheme.ink,
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Photographier la devanture',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: TovoTheme.ink,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _nom,
            enabled: !_envoi,
            textCapitalization: TextCapitalization.words,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Nom écrit sur l’enseigne',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Catégories (une ou plusieurs)',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entree in _categories.entries)
                FilterChip(
                  label: Text(entree.value),
                  selected: _choisies.contains(entree.key),
                  selectedColor: TovoTheme.ink,
                  labelStyle: TextStyle(
                    color: _choisies.contains(entree.key)
                        ? Colors.white
                        : TovoTheme.ink,
                    fontWeight: FontWeight.w600,
                  ),
                  showCheckmark: false,
                  onSelected: _envoi ? null : (_) => _basculer(entree.key),
                ),
              // La catégorie qui manque : le livreur la crée.
              ActionChip(
                avatar: const Icon(
                  Icons.add_rounded,
                  size: 18,
                  color: TovoTheme.ink,
                ),
                label: const Text('Nouvelle catégorie'),
                labelStyle: const TextStyle(
                  color: TovoTheme.ink,
                  fontWeight: FontWeight.w600,
                ),
                onPressed: _envoi ? null : _nouvelleCategorie,
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _telephone,
            enabled: !_envoi,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Téléphone (s’il est sur l’enseigne)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _repere,
            enabled: !_envoi,
            decoration: const InputDecoration(
              labelText: 'Repère (facultatif) : face à la mosquée…',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          // La position : visible, et à reprendre si le GPS est imprécis.
          Row(
            children: [
              Icon(
                position == null
                    ? Icons.location_searching
                    : Icons.location_on_outlined,
                size: 20,
                color: TovoTheme.inkDoux,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _gpsEnCours
                      ? 'Recherche de la position…'
                      : position == null
                      ? 'Position introuvable : activez la localisation.'
                      : 'Position prise (à ${position.accuracy.round()} m près)',
                  style: const TextStyle(color: TovoTheme.inkDoux),
                ),
              ),
              if (!_gpsEnCours)
                TextButton(
                  onPressed: _envoi ? null : _relever,
                  child: const Text('Reprendre'),
                ),
            ],
          ),
          if (_erreur != null) ...[
            const SizedBox(height: 12),
            Text(_erreur!, style: const TextStyle(color: TovoTheme.danger)),
          ],
          const SizedBox(height: 20),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: TovoTheme.ink,
              minimumSize: const Size.fromHeight(54),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(TovoTheme.radiusChip),
              ),
            ),
            onPressed: _pret ? _envoyer : null,
            child: Text(
              _envoi ? 'Envoi…' : 'Envoyer',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
          if (!_pret && !_envoi) ...[
            const SizedBox(height: 8),
            Text(
              _photo == null
                  ? 'Il manque la photo de la devanture.'
                  : _nom.text.trim().length < 2
                  ? 'Il manque le nom.'
                  : _choisies.isEmpty
                  ? 'Choisissez au moins une catégorie.'
                  : 'Il manque la position.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: TovoTheme.muted, fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }
}
