import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme.dart';

/// Connexion par téléphone.
///
/// Deux étapes, un seul écran : le numéro, puis le code reçu sur WhatsApp.
/// Supabase Auth génère et vérifie le code ; notre backend ne fait que le
/// livrer. Rien de la sécurité de l'authentification n'est réimplémenté ici.
///
/// Au Niger, le numéro de téléphone EST l'identité. Pas d'e-mail, pas de mot
/// de passe : les deux seraient des obstacles pour une part importante des
/// utilisateurs.
class AuthScreen extends StatefulWidget {
  const AuthScreen({
    super.key,
    required this.titre,
    required this.sousTitre,
    this.onConnecte,
  });

  final String titre;
  final String sousTitre;
  final VoidCallback? onConnecte;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

enum _Etape { numero, code }

class _AuthScreenState extends State<AuthScreen> {
  final _numero = TextEditingController();
  final _code = TextEditingController();

  _Etape _etape = _Etape.numero;

  bool _occupe = false;
  String? _erreur;
  int _secondesAvantRenvoi = 0;
  Timer? _resendTimer;

  /// Le Niger est en +227. On le préremplit plutôt que d'obliger chacun à le
  /// taper, tout en le laissant modifiable pour les numéros étrangers.
  static const String _indicatifParDefaut = '+227';

  @override
  void initState() {
    super.initState();
    _numero.text = _indicatifParDefaut;
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    _numero.dispose();
    _code.dispose();
    super.dispose();
  }

  String get _numeroComplet {
    final brut = _numero.text.replaceAll(RegExp(r'[^\d+]'), '');
    return brut.startsWith('+') ? brut : '$_indicatifParDefaut$brut';
  }

  bool get _numeroValide {
    final numero = _numeroComplet;
    if (numero.startsWith('+227')) {
      return RegExp(r'^\+227\d{8}$').hasMatch(numero);
    }
    return RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(numero);
  }

  Future<void> _envoyerCode() async {
    if (!_numeroValide) {
      setState(() => _erreur = 'Numéro incomplet.');
      return;
    }

    setState(() {
      _occupe = true;
      _erreur = null;
    });

    try {
      await Supabase.instance.client.auth.signInWithOtp(phone: _numeroComplet);
      if (!mounted) return;
      setState(() {
        _etape = _Etape.code;
        _secondesAvantRenvoi = 60;
      });
      _decompte();
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => _erreur = _messageLisible(e));
    } on Exception {
      if (!mounted) return;
      setState(() => _erreur = 'Connexion impossible. Vérifiez votre réseau.');
    } finally {
      if (mounted) setState(() => _occupe = false);
    }
  }

  Future<void> _verifierCode() async {
    if (_code.text.trim().length != 6) {
      setState(() => _erreur = 'Code incomplet.');
      return;
    }

    setState(() {
      _occupe = true;
      _erreur = null;
    });

    try {
      await Supabase.instance.client.auth.verifyOTP(
        phone: _numeroComplet,
        token: _code.text.trim(),
        type: OtpType.sms,
      );
      if (!mounted) return;
      // Un habitué est chez lui : son nom est déjà en base. Un nouveau se
      // le verra demander par AuthGate, une seule fois, juste après.
      widget.onConnecte?.call();
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => _erreur = _messageLisible(e));
    } on Exception {
      if (!mounted) return;
      setState(() => _erreur = 'Connexion impossible. Vérifiez votre réseau.');
    } finally {
      if (mounted) setState(() => _occupe = false);
    }
  }

  /// Les messages de GoTrue sont en anglais et techniques. On les traduit
  /// pour les cas courants : quelqu'un qui se trompe de code ne doit pas lire
  /// « Token has expired or is invalid ».
  String _messageLisible(AuthException e) {
    final m = e.message.toLowerCase();
    if (m.contains('expired') || m.contains('invalid')) {
      return 'Code incorrect ou expiré. Demandez-en un nouveau.';
    }
    if (m.contains('rate') || m.contains('too many')) {
      return 'Trop de tentatives. Patientez quelques minutes.';
    }
    if (m.contains('sms') || m.contains('provider')) {
      return "L'envoi du code a échoué. Réessayez dans un instant.";
    }
    return e.message;
  }

  void _decompte() {
    _resendTimer?.cancel();
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _secondesAvantRenvoi == 0) {
        timer.cancel();
        return;
      }
      setState(() => _secondesAvantRenvoi--);
      if (_secondesAvantRenvoi == 0) timer.cancel();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TovoTheme.canvas,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(28, 72, 28, 40),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _etape == _Etape.numero
                            ? 'Bienvenue sur ${widget.titre}'
                            : 'Vérifiez votre numéro',
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.7,
                          color: TovoTheme.ink,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _etape == _Etape.numero
                            ? widget.sousTitre
                            : 'Saisissez le code reçu pour continuer.',
                        style: const TextStyle(
                          fontSize: 15,
                          height: 1.5,
                          color: TovoTheme.inkDoux,
                        ),
                      ),
                      const SizedBox(height: 32),
                      if (_etape == _Etape.numero)
                        ..._etapeNumero()
                      else
                        ..._etapeCode(),
                      if (_erreur != null) ...[
                        const SizedBox(height: 14),
                        Text(
                          _erreur!,
                          style: const TextStyle(color: TovoTheme.danger),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (Navigator.of(context).canPop())
              Positioned(
                left: 16,
                top: 8,
                child: IconButton(
                  tooltip: 'Retour',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _etapeNumero() => [
    const Text('Votre numéro de téléphone'),
    const SizedBox(height: 10),
    TextField(
      key: const ValueKey('auth-phone'),
      controller: _numero,
      keyboardType: TextInputType.phone,
      autofillHints: const [AutofillHints.telephoneNumber],
      autofocus: false,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _envoyerCode(),
      // Chiffres, « + » et espaces. Le « \d » compte : sans lui, la
      // classe n'autorise que la lettre d, le plus et l'espace — le champ
      // refuse alors tout chiffre, et personne ne peut se connecter.
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d+ ]'))],
      decoration: _decoration('+227 90 00 00 00').copyWith(
        prefixIcon: const Icon(Icons.phone_rounded, color: TovoTheme.teal),
      ),
      style: const TextStyle(
        fontSize: 19,
        letterSpacing: 1,
        fontWeight: FontWeight.w600,
      ),
    ),
    const SizedBox(height: 16),
    FilledButton(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(50),
        backgroundColor: TovoTheme.teal,
        shape: const StadiumBorder(),
      ),
      onPressed: _occupe ? null : _envoyerCode,
      child: _occupe
          ? const _Attente()
          : const Text(
              'Recevoir un code',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
    ),
  ];

  List<Widget> _etapeCode() => [
    Text(
      'Code envoyé au $_numeroComplet',
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    ),
    const SizedBox(height: 8),
    TextField(
      key: const ValueKey('auth-code'),
      controller: _code,
      keyboardType: TextInputType.number,
      autofillHints: const [AutofillHints.oneTimeCode],
      autofocus: true,
      maxLength: 6,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      textAlign: TextAlign.center,
      decoration: _decoration('••••••').copyWith(counterText: ''),
      style: const TextStyle(
        fontSize: 26,
        letterSpacing: 10,
        fontWeight: FontWeight.w700,
      ),
      onChanged: (v) {
        // Validation automatique à six chiffres : un code se saisit et se
        // valide d'un geste, pas de deux.
        if (v.length == 6 && !_occupe) _verifierCode();
      },
    ),
    const SizedBox(height: 20),
    FilledButton(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(50),
        backgroundColor: TovoTheme.teal,
        shape: const StadiumBorder(),
      ),
      onPressed: _occupe ? null : _verifierCode,
      child: _occupe ? const _Attente() : const Text('Valider'),
    ),
    const SizedBox(height: 10),
    TextButton(
      onPressed: _secondesAvantRenvoi > 0 || _occupe ? null : _envoyerCode,
      child: Text(
        _secondesAvantRenvoi > 0
            ? 'Renvoyer le code dans $_secondesAvantRenvoi s'
            : 'Renvoyer le code',
        style: const TextStyle(fontSize: 12),
      ),
    ),
    TextButton(
      onPressed: _occupe
          ? null
          : () => setState(() {
              _etape = _Etape.numero;
              _code.clear();
              _erreur = null;
            }),
      child: const Text('Changer de numéro', style: TextStyle(fontSize: 12)),
    ),
  ];

  InputDecoration _decoration(String hint) => InputDecoration(
    hintText: hint,
    filled: true,
    fillColor: TovoTheme.tealMist,
    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(TovoTheme.radiusChip),
      borderSide: BorderSide.none,
    ),
  );
}

class _Attente extends StatelessWidget {
  const _Attente();

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 18,
    width: 18,
    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
  );
}
