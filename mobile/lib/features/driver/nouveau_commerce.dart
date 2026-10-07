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

const Map<String, String> _types = {
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
  String? _type;
  File? _photo;
  Position? _position;
  bool _gpsEnCours = true;
  bool _envoi = false;
  String? _erreur;

  @override
  void initState() {
    super.initState();
    unawaited(_relever());
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
      _type != null &&
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
      'type': _type,
      'telephone': _telephone.text.trim().isEmpty ? null : _telephone.text.trim(),
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
                  ? Image.file(_photo!, fit: BoxFit.cover, width: double.infinity)
                  : const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.photo_camera_outlined, size: 34, color: TovoTheme.ink),
                        SizedBox(height: 8),
                        Text(
                          'Photographier la devanture',
                          style: TextStyle(fontWeight: FontWeight.w600, color: TovoTheme.ink),
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
          const Text('Type', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entree in _types.entries)
                ChoiceChip(
                  label: Text(entree.value),
                  selected: _type == entree.key,
                  selectedColor: TovoTheme.ink,
                  labelStyle: TextStyle(
                    color: _type == entree.key ? Colors.white : TovoTheme.ink,
                    fontWeight: FontWeight.w600,
                  ),
                  showCheckmark: false,
                  onSelected: _envoi ? null : (_) => setState(() => _type = entree.key),
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
                position == null ? Icons.location_searching : Icons.location_on_outlined,
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
                      : _type == null
                          ? 'Choisissez le type.'
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
