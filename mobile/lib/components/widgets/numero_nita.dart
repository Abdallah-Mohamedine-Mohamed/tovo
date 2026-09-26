import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme.dart';

/// Le numéro qui paiera par Nita.
///
/// Nita ne connaît que les numéros du Niger. Or le compte Tovo peut être un
/// numéro étranger, ou un numéro nigérien sans Nita : l'achat était alors
/// créé sur un numéro qui ne pouvait pas payer, et échouait en silence
/// (retour du client, 26/09).
///
/// Sans friction :
///   - un numéro déjà utilisé pour payer est repris d'office ;
///   - sinon, le numéro du compte s'il est nigérien — proposé, modifiable
///     d'un geste ;
///   - un compte étranger voit directement le champ, avec la raison.
class NumeroNita extends StatefulWidget {
  const NumeroNita({super.key, required this.onChanged, this.actif = true});

  /// Le numéro local à 8 chiffres, ou null tant qu'il n'est pas complet.
  final ValueChanged<String?> onChanged;
  final bool actif;

  static const _cle = 'numero_nita';

  /// Retient le numéro qui a servi : la prochaine fois, rien à retaper.
  static Future<void> retenir(String numero) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cle, numero);
    } catch (_) {
      // Pas de mémoire : il faudra simplement le confirmer la prochaine fois.
    }
  }

  /// Un numéro nigérien local (8 chiffres), depuis un numéro complet.
  static String? nigerien(String? telephone) {
    final chiffres = (telephone ?? '').replaceAll(RegExp(r'\D'), '');
    if (chiffres.length == 11 && chiffres.startsWith('227')) {
      return chiffres.substring(3);
    }
    if (chiffres.length == 13 && chiffres.startsWith('00227')) {
      return chiffres.substring(5);
    }
    return null;
  }

  /// « 90 12 34 56 ».
  static String lisible(String numero) => [
    for (var i = 0; i < numero.length; i += 2)
      numero.substring(i, i + 2 > numero.length ? numero.length : i + 2),
  ].join(' ');

  @override
  State<NumeroNita> createState() => _NumeroNitaState();
}

/// Le logo MyNita, petit et arrondi, pour la puce « Nita ».
class LogoNita extends StatelessWidget {
  const LogoNita({super.key, this.taille = 20});

  final double taille;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(taille * 0.25),
    child: Image.asset(
      'assets/branding/mynita.png',
      width: taille,
      height: taille,
      fit: BoxFit.cover,
      semanticLabel: 'MyNita',
    ),
  );
}

class _NumeroNitaState extends State<NumeroNita> {
  final _champ = TextEditingController();
  String? _numero;
  bool _saisie = false;
  bool _etranger = false;
  bool _pret = false;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  @override
  void dispose() {
    _champ.dispose();
    super.dispose();
  }

  Future<void> _charger() async {
    String? retenu;
    try {
      // Une seconde au plus : sans mémoire, on propose le numéro du compte.
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 1),
      );
      retenu = prefs.getString(NumeroNita._cle);
    } catch (_) {}
    String? duCompte;
    try {
      duCompte = Supabase.instance.client.auth.currentUser?.phone;
    } catch (_) {}
    final compte = NumeroNita.nigerien(duCompte);
    final numero = (retenu != null && retenu.length == 8) ? retenu : compte;
    if (!mounted) return;
    setState(() {
      _pret = true;
      _numero = numero;
      _etranger = numero == null && (duCompte ?? '').isNotEmpty;
      // Pas de numéro utilisable : le champ, tout de suite.
      _saisie = numero == null;
    });
    widget.onChanged(numero);
  }

  void _modifier() {
    _champ.text = _numero ?? '';
    setState(() => _saisie = true);
  }

  void _saisi(String valeur) {
    final chiffres = valeur.replaceAll(RegExp(r'\D'), '');
    final complet = chiffres.length == 8 ? chiffres : null;
    setState(() => _numero = complet);
    widget.onChanged(complet);
  }

  @override
  Widget build(BuildContext context) {
    if (!_pret) return const SizedBox(height: 44);
    if (!_saisie && _numero != null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(
                  text: 'Payé par Nita avec le ',
                  style: const TextStyle(
                    fontSize: 13,
                    color: TovoTheme.inkDoux,
                  ),
                  children: [
                    TextSpan(
                      text: '+227 ${NumeroNita.lisible(_numero!)}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: TovoTheme.ink,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            TextButton(
              onPressed: widget.actif ? _modifier : null,
              style: TextButton.styleFrom(
                foregroundColor: TovoTheme.ink,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 36),
              ),
              child: const Text(
                'Modifier',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _etranger
                ? 'Votre numéro n’est pas nigérien : indiquez le numéro Nita qui paiera.'
                : 'Le numéro Nita qui paiera',
            style: const TextStyle(fontSize: 13, color: TovoTheme.inkDoux),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('numero-nita'),
            controller: _champ,
            enabled: widget.actif,
            // Affiché parce qu'il faut le remplir (compte étranger, ou
            // « Modifier ») : le curseur y est déjà.
            autofocus: true,
            keyboardType: TextInputType.phone,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(8),
            ],
            onChanged: _saisi,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            decoration: InputDecoration(
              prefixText: '+227  ',
              hintText: '90 00 00 00',
              isDense: true,
              filled: true,
              fillColor: TovoTheme.bloc,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(TovoTheme.radiusChip),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
