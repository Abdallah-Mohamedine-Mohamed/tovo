import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/api.dart';
import '../../core/theme.dart';
import 'options_editor.dart';

/// Création et modification d'un produit.
///
/// Conçu pour être rempli d'une main, debout derrière un comptoir, sur un
/// téléphone d'entrée de gamme. Trois champs obligatoires — nom, prix,
/// catégorie — et tout le reste facultatif.
///
/// La photo compte plus que la description : un boutiquier pressé écrira
/// « Menu 3 », mais il prendra la photo. Le backend fait décrire l'image par
/// Gemini et enrichit le texte indexé — la fiche devient cherchable sans que
/// personne n'ait rédigé quoi que ce soit.
class ProductEditor extends StatefulWidget {
  const ProductEditor({
    super.key,
    required this.api,
    required this.merchantId,
    this.produit,
  });

  final TovoApi api;
  final String merchantId;

  /// Nul pour une création.
  final Map<String, dynamic>? produit;

  @override
  State<ProductEditor> createState() => _ProductEditorState();
}

class _ProductEditorState extends State<ProductEditor> {
  final _nom = TextEditingController();
  final _description = TextEditingController();
  final _prix = TextEditingController();

  final _db = Supabase.instance.client;

  List<Map<String, dynamic>> _categories = const [];
  String? _categorieId;
  String? _imageUrl;
  File? _nouvelleImage;

  bool _disponible = true;
  bool _enCours = false;
  String? _erreur;

  bool get _creation => widget.produit == null;

  @override
  void initState() {
    super.initState();
    final p = widget.produit;
    if (p != null) {
      _nom.text = (p['name'] as String?) ?? '';
      _description.text = (p['description'] as String?) ?? '';
      _prix.text = '${(p['price'] as num?)?.toInt() ?? ''}';
      _categorieId = p['category_id'] as String?;
      _imageUrl = p['image_url'] as String?;
      _disponible = p['is_available'] as bool? ?? true;
    }
    _chargerCategories();
  }

  @override
  void dispose() {
    _nom.dispose();
    _description.dispose();
    _prix.dispose();
    super.dispose();
  }

  Future<void> _chargerCategories() async {
    try {
      final data = await _db
          .from('categories')
          .select('id, name, parent_id')
          .eq('is_active', true)
          .order('sort_order');
      if (!mounted) return;
      setState(() => _categories = List<Map<String, dynamic>>.from(data));
    } on Exception {
      // Sans catégories, on peut toujours enregistrer : le champ devient
      // simplement vide, et l'admin pourra ranger le produit plus tard.
    }
  }

  Future<void> _choisirPhoto() async {
    final fichier = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      // Compression à la prise : une photo de 4 Mo téléversée depuis Niamey
      // prend une minute et coûte le forfait du boutiquier.
      maxWidth: 1280,
      imageQuality: 80,
    );
    if (fichier == null) return;
    setState(() => _nouvelleImage = File(fichier.path));
  }

  Future<String?> _televerserPhoto(String productId) async {
    final image = _nouvelleImage;
    if (image == null) return _imageUrl;

    // Convention imposée par les policies Storage : le premier segment est
    // l'identifiant de la boutique. Sans elle, l'écriture est refusée.
    final chemin = '${widget.merchantId}/$productId.jpg';

    await _db.storage.from('products').upload(
          chemin,
          image,
          fileOptions: const FileOptions(upsert: true, contentType: 'image/jpeg'),
        );

    return _db.storage.from('products').getPublicUrl(chemin);
  }

  Future<void> _enregistrer() async {
    final prix = int.tryParse(_prix.text.trim());

    if (_nom.text.trim().isEmpty) {
      setState(() => _erreur = 'Le nom est obligatoire.');
      return;
    }
    if (prix == null || prix < 0) {
      setState(() => _erreur = 'Prix invalide.');
      return;
    }

    setState(() {
      _enCours = true;
      _erreur = null;
    });

    try {
      final valeurs = {
        'merchant_id': widget.merchantId,
        'name': _nom.text.trim(),
        'description': _description.text.trim().isEmpty ? null : _description.text.trim(),
        'price': prix,
        'category_id': _categorieId,
        'is_available': _disponible,
      };

      final String productId;
      if (_creation) {
        final res = await _db.from('products').insert(valeurs).select('id').single();
        productId = res['id'] as String;
      } else {
        productId = widget.produit!['id'] as String;
        await _db.from('products').update(valeurs).eq('id', productId);
      }

      final url = await _televerserPhoto(productId);
      if (url != null && url != _imageUrl) {
        // On efface `image_description` : elle décrivait l'ANCIENNE photo, et
        // la garder ferait indexer le produit sur une image qui n'existe plus.
        await _db
            .from('products')
            .update({'image_url': url, 'image_description': null})
            .eq('id', productId);
      }

      // Indexation immédiate. En cas d'échec, le balayage périodique reprend
      // le produit dans les cinq minutes — on ne bloque donc pas dessus.
      await widget.api.post('/merchant/products/$productId/index', const {});

      if (!mounted) return;
      Navigator.pop(context, true);
    } on PostgrestException catch (cause) {
      if (!mounted) return;
      setState(() => _erreur = cause.message);
    } on Exception catch (cause) {
      if (!mounted) return;
      setState(() => _erreur = 'Enregistrement impossible : $cause');
    } finally {
      if (mounted) setState(() => _enCours = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TovoTheme.surface,
      appBar: AppBar(
        title: Text(
          _creation ? 'Nouveau produit' : 'Modifier',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Photo(
            url: _imageUrl,
            fichier: _nouvelleImage,
            onTap: _choisirPhoto,
          ),
          const SizedBox(height: 8),
          const Text(
            'Une photo suffit souvent : Tovo la décrit automatiquement pour que vos clients vous trouvent.',
            style: TextStyle(fontSize: 11, color: TovoTheme.muted),
          ),
          const SizedBox(height: 20),

          _Champ(
            libelle: 'Nom du produit',
            controller: _nom,
            hint: 'Tuo zaafi sauce arachide',
          ),
          const SizedBox(height: 16),

          _Champ(
            libelle: 'Prix en francs CFA',
            controller: _prix,
            hint: '1500',
            clavier: TextInputType.number,
            formateurs: [FilteringTextInputFormatter.digitsOnly],
          ),
          const SizedBox(height: 16),

          _Champ(
            libelle: 'Description (facultatif)',
            controller: _description,
            hint: 'Pâte de mil, sauce arachide maison',
            lignes: 3,
          ),
          const SizedBox(height: 16),

          const Text('Catégorie', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            initialValue: _categorieId,
            isExpanded: true,
            decoration: _decoration('Choisir'),
            items: [
              for (final c in _categories)
                DropdownMenuItem(
                  value: c['id'] as String,
                  child: Text(
                    // Une sous-catégorie est décalée : « Repas » puis
                    // « — Plats locaux », pour qu'on voie la hiérarchie sans
                    // avoir à naviguer.
                    c['parent_id'] == null ? '${c['name']}' : '   — ${c['name']}',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
            ],
            onChanged: (v) => setState(() => _categorieId = v),
          ),
          const SizedBox(height: 16),

          SwitchListTile(
            value: _disponible,
            onChanged: (v) => setState(() => _disponible = v),
            title: const Text('Disponible', style: TextStyle(fontSize: 13)),
            subtitle: const Text(
              'Décochez en cas de rupture — le produit reste dans votre catalogue.',
              style: TextStyle(fontSize: 11, color: TovoTheme.muted),
            ),
            activeThumbColor: TovoTheme.success,
            contentPadding: EdgeInsets.zero,
          ),


          // Les options exigent un identifiant de produit : on ne peut donc
          // les gérer qu'après la création. Le dire explicitement évite au
          // boutiquier de chercher un bouton absent.
          if (_creation)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Vous pourrez ajouter des options (portion, sauce…) après avoir créé le produit.',
                style: TextStyle(fontSize: 11, color: TovoTheme.muted),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => OptionsEditor(
                      productId: widget.produit!['id'] as String,
                      productName: _nom.text.trim(),
                    ),
                  ),
                ),
                icon: const Icon(Icons.tune, size: 18),
                label: const Text('Gérer les options'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                  foregroundColor: TovoTheme.teal,
                ),
              ),
            ),

          if (_erreur != null) ...[
            const SizedBox(height: 12),
            Text(_erreur!, style: const TextStyle(fontSize: 12, color: TovoTheme.danger)),
          ],

          const SizedBox(height: 24),
          FilledButton(
            onPressed: _enCours ? null : _enregistrer,
            child: _enCours
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : Text(_creation ? 'Créer le produit' : 'Enregistrer'),
          ),
        ],
      ),
    );
  }

  InputDecoration _decoration(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 13, color: Color(0xFFAAAAAA)),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TovoTheme.radiusChip),
          borderSide: const BorderSide(color: Color(0x14000000)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TovoTheme.radiusChip),
          borderSide: const BorderSide(color: Color(0x14000000)),
        ),
      );
}

class _Champ extends StatelessWidget {
  const _Champ({
    required this.libelle,
    required this.controller,
    required this.hint,
    this.clavier,
    this.formateurs,
    this.lignes = 1,
  });

  final String libelle;
  final TextEditingController controller;
  final String hint;
  final TextInputType? clavier;
  final List<TextInputFormatter>? formateurs;
  final int lignes;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(libelle, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          keyboardType: clavier,
          inputFormatters: formateurs,
          maxLines: lignes,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(fontSize: 13, color: Color(0xFFAAAAAA)),
            filled: true,
            fillColor: Colors.white,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(TovoTheme.radiusChip),
              borderSide: const BorderSide(color: Color(0x14000000)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(TovoTheme.radiusChip),
              borderSide: const BorderSide(color: Color(0x14000000)),
            ),
          ),
        ),
      ],
    );
  }
}

class _Photo extends StatelessWidget {
  const _Photo({required this.url, required this.fichier, required this.onTap});

  final String? url;
  final File? fichier;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(TovoTheme.radiusCard),
      child: Container(
        height: 170,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(TovoTheme.radiusCard),
          border: Border.all(color: const Color(0x14000000)),
        ),
        clipBehavior: Clip.antiAlias,
        child: fichier != null
            ? Image.file(fichier!, fit: BoxFit.cover, width: double.infinity)
            : url != null && url!.isNotEmpty
                ? Image.network(
                    url!,
                    fit: BoxFit.cover,
                    width: double.infinity,
                    errorBuilder: (_, __, ___) => const _Invite(),
                  )
                : const _Invite(),
      ),
    );
  }
}

class _Invite extends StatelessWidget {
  const _Invite();

  @override
  Widget build(BuildContext context) => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add_a_photo_outlined, size: 30, color: TovoTheme.muted),
            SizedBox(height: 8),
            Text(
              'Ajouter une photo',
              style: TextStyle(fontSize: 13, color: TovoTheme.muted),
            ),
          ],
        ),
      );
}
