import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../components/registry.dart';
import '../../core/theme.dart';

/// Options d'un produit — « Portion », « Sauce », « Accompagnement ».
///
/// C'est la partie du catalogue que les boutiquiers comprennent le moins.
/// L'écran évite donc le vocabulaire technique : pas de « min_select » ni de
/// « max_select », mais « le client doit choisir » et « il peut en prendre
/// plusieurs ».
///
/// Deux modèles suffisent à couvrir la quasi-totalité des cas d'un
/// restaurant : un choix unique obligatoire (la portion), et un choix
/// multiple facultatif (les accompagnements).
class OptionsEditor extends StatefulWidget {
  const OptionsEditor({
    super.key,
    required this.productId,
    required this.productName,
  });

  final String productId;
  final String productName;

  @override
  State<OptionsEditor> createState() => _OptionsEditorState();
}

class _OptionsEditorState extends State<OptionsEditor> {
  final _db = Supabase.instance.client;

  List<Map<String, dynamic>> _options = const [];
  bool _chargement = true;
  String? _erreur;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    try {
      final data = await _db
          .from('product_options')
          .select(
            'id, name, is_required, min_select, max_select, sort_order, '
            'product_option_values(id, name, price_delta, is_available, sort_order)',
          )
          .eq('product_id', widget.productId)
          .order('sort_order');

      if (!mounted) return;
      setState(() {
        _options = List<Map<String, dynamic>>.from(data);
        _chargement = false;
        _erreur = null;
      });
    } on Exception catch (cause) {
      if (!mounted) return;
      setState(() {
        _chargement = false;
        _erreur = 'Chargement impossible : $cause';
      });
    }
  }

  Future<void> _ajouterOption() async {
    final resultat = await showDialog<_NouvelleOption>(
      context: context,
      builder: (_) => const _DialogueOption(),
    );
    if (resultat == null) return;

    try {
      await _db.from('product_options').insert({
        'product_id': widget.productId,
        'name': resultat.nom,
        'is_required': resultat.obligatoire,
        'min_select': resultat.obligatoire ? 1 : 0,
        // Un choix unique se traduit par max_select = 1 ; multiple, on
        // autorise large plutôt que de demander un nombre au boutiquier.
        'max_select': resultat.multiple ? 10 : 1,
        'sort_order': _options.length + 1,
      });
      await _charger();
    } on Exception catch (cause) {
      if (mounted) setState(() => _erreur = '$cause');
    }
  }

  Future<void> _ajouterValeur(Map<String, dynamic> option) async {
    final resultat = await showDialog<_NouvelleValeur>(
      context: context,
      builder: (_) => _DialogueValeur(optionNom: option['name'] as String),
    );
    if (resultat == null) return;

    try {
      await _db.from('product_option_values').insert({
        'option_id': option['id'],
        'name': resultat.nom,
        'price_delta': resultat.supplement,
        'sort_order':
            ((option['product_option_values'] as List?)?.length ?? 0) + 1,
      });
      await _charger();
    } on Exception catch (cause) {
      if (mounted) setState(() => _erreur = '$cause');
    }
  }

  Future<void> _supprimer(String table, String id, String quoi) async {
    final confirme = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Supprimer $quoi ?', style: const TextStyle(fontSize: 16)),
        content: const Text(
          'Les commandes déjà passées ne sont pas modifiées : elles gardent ce qui a été choisi.',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: TovoTheme.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirme != true) return;

    try {
      await _db.from(table).delete().eq('id', id);
      await _charger();
    } on Exception catch (cause) {
      if (mounted) setState(() => _erreur = '$cause');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TovoTheme.surface,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Options', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            Text(
              widget.productName,
              style: const TextStyle(fontSize: 11, color: TovoTheme.muted),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _ajouterOption,
        backgroundColor: TovoTheme.teal,
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text('Option', style: TextStyle(color: Colors.white)),
      ),
      body: _chargement
          ? const Center(child: CircularProgressIndicator(color: TovoTheme.teal))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
              children: [
                if (_erreur != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _erreur!,
                      style: const TextStyle(fontSize: 12, color: TovoTheme.danger),
                    ),
                  ),
                if (_options.isEmpty) const _Vide(),
                for (final option in _options)
                  _CarteOption(
                    option: option,
                    onAjouterValeur: () => _ajouterValeur(option),
                    onSupprimerOption: () => _supprimer(
                      'product_options',
                      option['id'] as String,
                      'cette option',
                    ),
                    onSupprimerValeur: (id) => _supprimer(
                      'product_option_values',
                      id,
                      'ce choix',
                    ),
                  ),
              ],
            ),
    );
  }
}

class _CarteOption extends StatelessWidget {
  const _CarteOption({
    required this.option,
    required this.onAjouterValeur,
    required this.onSupprimerOption,
    required this.onSupprimerValeur,
  });

  final Map<String, dynamic> option;
  final VoidCallback onAjouterValeur;
  final VoidCallback onSupprimerOption;
  final void Function(String) onSupprimerValeur;

  @override
  Widget build(BuildContext context) {
    final valeurs = List<Map<String, dynamic>>.from(
      (option['product_option_values'] as List?) ?? const [],
    )..sort((a, b) => (a['sort_order'] ?? 0).compareTo(b['sort_order'] ?? 0));

    final obligatoire = option['is_required'] as bool? ?? false;
    final multiple = ((option['max_select'] as num?)?.toInt() ?? 1) > 1;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(TovoTheme.radiusCard),
        border: Border.all(color: const Color(0x12000000)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (option['name'] as String?) ?? '',
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        // Reformulé pour un boutiquier, pas pour un
                        // développeur : « obligatoire » et « min_select »
                        // ne disent rien de la même façon.
                        [
                          obligatoire ? 'Le client doit choisir' : 'Facultatif',
                          multiple ? 'plusieurs choix possibles' : 'un seul choix',
                        ].join(' · '),
                        style: const TextStyle(fontSize: 11, color: TovoTheme.muted),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: onSupprimerOption,
                  icon: const Icon(Icons.delete_outline, size: 20, color: TovoTheme.danger),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (valeurs.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Text(
                'Aucun choix. Ajoutez-en au moins un, sinon vos clients ne pourront pas commander ce produit.',
                style: TextStyle(fontSize: 11, color: TovoTheme.danger),
              ),
            ),
          for (final valeur in valeurs)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      (valeur['name'] as String?) ?? '',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  Text(
                    ((valeur['price_delta'] as num?)?.toInt() ?? 0) == 0
                        ? 'inclus'
                        : '+ ${Money.format((valeur['price_delta'] as num).toInt())}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: ((valeur['price_delta'] as num?)?.toInt() ?? 0) == 0
                          ? TovoTheme.muted
                          : TovoTheme.teal,
                    ),
                  ),
                  IconButton(
                    onPressed: () => onSupprimerValeur(valeur['id'] as String),
                    icon: const Icon(Icons.close, size: 16, color: TovoTheme.muted),
                  ),
                ],
              ),
            ),
          TextButton.icon(
            onPressed: onAjouterValeur,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Ajouter un choix', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

class _Vide extends StatelessWidget {
  const _Vide();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 48, horizontal: 16),
        child: Column(
          children: [
            Icon(Icons.tune, size: 36, color: TovoTheme.muted),
            SizedBox(height: 12),
            Text(
              'Aucune option',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            SizedBox(height: 6),
            Text(
              'Les options permettent au client de préciser sa commande : '
              'la taille de la portion, la sauce, l’accompagnement.\n\n'
              'Sans option, le produit se commande tel quel.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: TovoTheme.muted),
            ),
          ],
        ),
      );
}

// ---------------------------------------------------------------------
// Dialogues de saisie
// ---------------------------------------------------------------------

class _NouvelleOption {
  const _NouvelleOption(this.nom, this.obligatoire, this.multiple);
  final String nom;
  final bool obligatoire;
  final bool multiple;
}

class _DialogueOption extends StatefulWidget {
  const _DialogueOption();

  @override
  State<_DialogueOption> createState() => _DialogueOptionState();
}

class _DialogueOptionState extends State<_DialogueOption> {
  final _nom = TextEditingController();
  bool _obligatoire = true;
  bool _multiple = false;

  @override
  void dispose() {
    _nom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Nouvelle option', style: TextStyle(fontSize: 16)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nom,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Nom',
              hintText: 'Portion, Sauce, Boisson…',
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            value: _obligatoire,
            onChanged: (v) => setState(() => _obligatoire = v),
            title: const Text('Le client doit choisir', style: TextStyle(fontSize: 13)),
            contentPadding: EdgeInsets.zero,
            activeThumbColor: TovoTheme.teal,
          ),
          SwitchListTile(
            value: _multiple,
            onChanged: (v) => setState(() => _multiple = v),
            title: const Text('Plusieurs choix possibles', style: TextStyle(fontSize: 13)),
            contentPadding: EdgeInsets.zero,
            activeThumbColor: TovoTheme.teal,
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(
          onPressed: () {
            final nom = _nom.text.trim();
            if (nom.isEmpty) return;
            Navigator.pop(context, _NouvelleOption(nom, _obligatoire, _multiple));
          },
          child: const Text('Créer'),
        ),
      ],
    );
  }
}

class _NouvelleValeur {
  const _NouvelleValeur(this.nom, this.supplement);
  final String nom;
  final int supplement;
}

class _DialogueValeur extends StatefulWidget {
  const _DialogueValeur({required this.optionNom});
  final String optionNom;

  @override
  State<_DialogueValeur> createState() => _DialogueValeurState();
}

class _DialogueValeurState extends State<_DialogueValeur> {
  final _nom = TextEditingController();
  final _supplement = TextEditingController(text: '0');

  @override
  void dispose() {
    _nom.dispose();
    _supplement.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Choix pour « ${widget.optionNom} »', style: const TextStyle(fontSize: 16)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nom,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Nom du choix',
              hintText: 'Simple, Double, Arachide…',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _supplement,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Supplément en francs',
              helperText: '0 si ce choix ne coûte rien de plus',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(
          onPressed: () {
            final nom = _nom.text.trim();
            if (nom.isEmpty) return;
            Navigator.pop(
              context,
              _NouvelleValeur(nom, int.tryParse(_supplement.text.trim()) ?? 0),
            );
          },
          child: const Text('Ajouter'),
        ),
      ],
    );
  }
}
