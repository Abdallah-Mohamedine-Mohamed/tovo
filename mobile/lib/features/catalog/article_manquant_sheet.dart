import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/catalog_image.dart';
import '../../core/theme.dart';

/// « Un article manque » (maquette validée le 02/11).
///
/// La boutique a coché un article qu'elle n'a plus. Le client choisit :
/// le remplacer (au plus deux propositions de la même boutique, au même
/// prix), le retirer (le nouveau total est affiché), ou annuler. Sans
/// réponse en 10 minutes, l'article est retiré et la commande continue —
/// c'est le serveur qui le fait.
///
/// Renvoie le message à afficher une fois le choix fait, ou null.
Future<String?> choisirPourArticleManquant(
  BuildContext context, {
  required TovoApi api,
  required Map<String, dynamic> commande,
  required Map<String, dynamic> manquant,
}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.white,
  showDragHandle: true,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
  ),
  builder: (_) =>
      _FeuilleManquant(api: api, commande: commande, manquant: manquant),
);

String _francs(num n) =>
    '${n.round().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ' ')} F';

class _FeuilleManquant extends StatefulWidget {
  const _FeuilleManquant({
    required this.api,
    required this.commande,
    required this.manquant,
  });

  final TovoApi api;
  final Map<String, dynamic> commande;
  final Map<String, dynamic> manquant;

  @override
  State<_FeuilleManquant> createState() => _FeuilleManquantState();
}

class _FeuilleManquantState extends State<_FeuilleManquant> {
  bool _envoi = false;
  String? _erreur;

  String get _nom => '${widget.manquant['nom'] ?? 'Un article'}';
  int get _prix => (widget.manquant['prix_unitaire'] as num?)?.toInt() ?? 0;
  int get _quantite => (widget.manquant['quantite'] as num?)?.toInt() ?? 1;

  List<Map<String, dynamic>> get _suggestions =>
      ((widget.manquant['suggestions'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();

  Future<void> _decider(
    String decision, {
    String? produit,
    required String message,
  }) async {
    setState(() {
      _envoi = true;
      _erreur = null;
    });
    final reponse = await widget.api.post(
      '/orders/${widget.commande['id']}/manquants/${widget.manquant['id']}',
      {'decision': decision, if (produit != null) 'product_id': produit},
    );
    if (!mounted) return;
    if (reponse.ok) {
      Navigator.of(context).pop(message);
    } else {
      setState(() {
        _envoi = false;
        _erreur = reponse.content;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final boutique = '${widget.commande['merchant_name'] ?? 'La boutique'}';
    final total = (widget.commande['total'] as num?)?.toInt() ?? 0;
    final nouveauTotal = total - _prix * _quantite;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Un article manque',
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '$boutique n’a plus de '),
                  TextSpan(
                    text: _nom,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const TextSpan(
                    text: '. Le reste de votre commande est en préparation.',
                  ),
                ],
              ),
              style: const TextStyle(fontSize: 15.5, height: 1.4),
            ),
            if (_suggestions.isNotEmpty) ...[
              const SizedBox(height: 18),
              const Text(
                'La remplacer par',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: TovoTheme.inkDoux,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < _suggestions.length; i++) ...[
                    if (i > 0) const SizedBox(width: 10),
                    Expanded(child: _tuile(_suggestions[i])),
                  ],
                  if (_suggestions.length == 1)
                    const Expanded(child: SizedBox()),
                ],
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey('retirer-article'),
              onPressed: _envoi
                  ? null
                  : () => _decider(
                      'retirer',
                      message:
                          '$_nom est retiré. Nouveau total : ${_francs(nouveauTotal)}.',
                    ),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFE6E9E3),
                foregroundColor: TovoTheme.ink,
                minimumSize: const Size.fromHeight(50),
              ),
              child: Text(
                'Retirer l’article · nouveau total ${_francs(nouveauTotal)}',
              ),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: _envoi
                  ? null
                  : () => _decider(
                      'annuler',
                      message: 'Votre commande est annulée.',
                    ),
              style: TextButton.styleFrom(
                foregroundColor: TovoTheme.danger,
                minimumSize: const Size.fromHeight(46),
              ),
              child: const Text('Annuler la commande'),
            ),
            if (_erreur != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _erreur!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: TovoTheme.danger),
                ),
              ),
            const SizedBox(height: 6),
            const Text(
              'Sans réponse dans 10 minutes, l’article est retiré et la commande continue.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: TovoTheme.muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tuile(Map<String, dynamic> s) {
    final prix = (s['prix'] as num?)?.toInt() ?? 0;
    final image = '${s['image_url'] ?? ''}';
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F8F9),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: image.isEmpty
                  ? const ColoredBox(color: TovoTheme.bloc)
                  : CatalogImage(image, fit: BoxFit.cover, decodeWidth: 300),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 36,
            child: Text(
              '${s['nom'] ?? ''}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                height: 1.25,
              ),
            ),
          ),
          Text(
            prix == _prix ? '${_francs(prix)} · même prix' : _francs(prix),
            style: const TextStyle(fontSize: 13, color: TovoTheme.inkDoux),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _envoi
                ? null
                : () => _decider(
                    'remplacer',
                    produit: '${s['product_id']}',
                    message: 'C’est noté : ${s['nom']} à la place de $_nom.',
                  ),
            style: FilledButton.styleFrom(
              backgroundColor: TovoTheme.ink,
              minimumSize: const Size.fromHeight(40),
            ),
            child: const Text('Choisir'),
          ),
        ],
      ),
    );
  }
}
