import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme.dart';
import 'phone_country.dart';

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
  PhoneCountry _pays = phoneCountries.first;

  _Etape _etape = _Etape.numero;

  bool _occupe = false;
  String? _erreur;
  int _secondesAvantRenvoi = 0;
  Timer? _resendTimer;

  @override
  void dispose() {
    _resendTimer?.cancel();
    _numero.dispose();
    _code.dispose();
    super.dispose();
  }

  String get _numeroComplet => _pays.fullNumber(_numero.text);

  bool get _numeroValide => _pays.accepts(_numero.text);

  Future<void> _choisirPays() async {
    FocusScope.of(context).unfocus();
    final country = await showModalBottomSheet<PhoneCountry>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PhoneCountrySheet(selected: _pays),
    );
    if (!mounted || country == null) return;
    setState(() {
      _pays = country;
      _erreur = null;
    });
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
    final isClient = widget.titre == 'Tovo';
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Scaffold(
      backgroundColor: TovoTheme.canvas,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final showArtwork =
                isClient &&
                _etape == _Etape.numero &&
                !keyboardOpen &&
                constraints.maxHeight >= 700;
            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(28, keyboardOpen ? 24 : 44, 28, 40),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (Navigator.of(context).canPop()) ...[
                        Align(
                          alignment: Alignment.centerLeft,
                          child: IconButton(
                            tooltip: 'Retour',
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.arrow_back_rounded),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (showArtwork) ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(22),
                          child: Image.asset(
                            'assets/branding/accueil-niamey.webp',
                            height: (constraints.maxHeight * 0.25).clamp(
                              140.0,
                              220.0,
                            ),
                            fit: BoxFit.cover,
                            alignment: Alignment.center,
                          ),
                        ),
                        const SizedBox(height: 30),
                      ],
                      Text(
                        isClient && _etape == _Etape.numero
                            ? 'Tout commence par une envie.'
                            : _etape == _Etape.numero
                            ? 'Bienvenue sur ${widget.titre}'
                            : 'Vérifiez votre numéro',
                        style: const TextStyle(
                          fontSize: 29,
                          height: 1.15,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.9,
                          color: TovoTheme.ink,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        isClient && _etape == _Etape.numero
                            ? 'Un repas, des courses, un colis : dites-nous ce qu’il vous faut. Tovo s’en occupe.'
                            : _etape == _Etape.numero
                            ? widget.sousTitre
                            : 'Saisissez le code reçu pour continuer.',
                        style: const TextStyle(
                          fontSize: 16,
                          height: 1.45,
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
                      if (isClient && _etape == _Etape.numero) ...[
                        const SizedBox(height: 18),
                        const Text(
                          'Votre numéro protège vos commandes et vous permet de suivre votre livreur. Aucun mot de passe à retenir.',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.45,
                            color: TovoTheme.inkDoux,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  List<Widget> _etapeNumero() => [
    const Text('Votre numéro'),
    const SizedBox(height: 10),
    Row(
      children: [
        Semantics(
          button: true,
          label: 'Pays : ${_pays.name}, indicatif ${_pays.dialCode}',
          child: Material(
            color: const Color(0xFFF2F3F1),
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              key: const ValueKey('auth-country'),
              onTap: _occupe ? null : _choisirPays,
              borderRadius: BorderRadius.circular(18),
              child: SizedBox(
                height: 56,
                width: 132,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(_pays.flag, style: const TextStyle(fontSize: 21)),
                    const SizedBox(width: 6),
                    Text(
                      _pays.dialCode,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            key: const ValueKey('auth-phone'),
            controller: _numero,
            keyboardType: TextInputType.phone,
            autofillHints: const [AutofillHints.telephoneNumberNational],
            autofocus: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _envoyerCode(),
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: _decoration(
              _pays.isoCode == 'NE' ? '90 00 00 00' : 'Numéro',
            ),
            style: const TextStyle(
              fontSize: 18,
              letterSpacing: 0.3,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    ),
    const SizedBox(height: 16),
    FilledButton(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(54),
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
    fillColor: const Color(0xFFF2F3F1),
    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: BorderSide.none,
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: BorderSide.none,
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
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
