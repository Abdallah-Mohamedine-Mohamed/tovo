import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme.dart';
import 'anneau_tovo.dart';
import 'ecran_d_entree.dart';
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
    this.codeDejaEnvoyeA,
  });

  final String titre;
  final String sousTitre;
  final VoidCallback? onConnecte;

  /// Tests et captures : ouvre directement l'étape du code, comme si un
  /// code venait d'être envoyé à ce numéro local.
  @visibleForTesting
  final String? codeDejaEnvoyeA;

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
  void initState() {
    super.initState();
    final numero = widget.codeDejaEnvoyeA;
    if (numero != null) {
      _numero.text = numero;
      _etape = _Etape.code;
      _secondesAvantRenvoi = 42;
    }
  }

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
      // Code faux : les cases se vident, on retape — pas six chiffres à
      // effacer un à un.
      _code.clear();
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
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: PopScope(
        // Le retour système, sur le code, ramène au numéro — il ne ferme pas
        // l'app au milieu de la connexion.
        canPop: _etape == _Etape.numero,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && !_occupe) _changerDeNumero();
        },
        child: Scaffold(
          backgroundColor: TovoTheme.canvas,
          body: AnimatedSwitcher(
            duration: TovoTheme.normal,
            switchInCurve: TovoTheme.courbe,
            switchOutCurve: TovoTheme.courbe,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween(
                  begin: const Offset(0.04, 0),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
            child: _etape == _Etape.numero
                ? KeyedSubtree(
                    key: const ValueKey('etape-numero'),
                    child: _ecranNumero(),
                  )
                : KeyedSubtree(
                    key: const ValueKey('etape-code'),
                    child: SafeArea(child: _ecranCode()),
                  ),
          ),
        ),
      ),
    );
  }

  /// Le premier écran, à la Glovo : l'anneau en pleine largeur sur un fond
  /// clair, une feuille arrondie qui monte dessus, « Bienvenue », les deux
  /// champs, et « Continuer » tout en bas. Rien d'autre : pas de canal à
  /// choisir, pas de mot de passe (demande du client, 25/09).
  Widget _ecranNumero() {
    final isClient = widget.titre == 'Tovo';
    return EcranDEntree(
      onRetour: Navigator.of(context).canPop()
          ? () => Navigator.of(context).pop()
          : null,
      heros: (hauteur) => LayoutBuilder(
        builder: (context, c) =>
            AnneauTovo(taille: math.min(c.maxWidth * 0.8, hauteur * 0.94)),
      ),
      contenu: [
        const Text(
          'Bienvenue',
          textAlign: TextAlign.center,
          style: styleTitreEntree,
        ),
        const SizedBox(height: 8),
        Text(
          isClient
              ? 'Commençons par votre numéro de téléphone'
              : 'Connectez-vous à ${widget.titre} avec votre numéro',
          textAlign: TextAlign.center,
          style: styleSousTitreEntree,
        ),
        const SizedBox(height: 24),
        _champNumero(),
        if (_erreur != null) _Erreur(_erreur!),
      ],
      bouton: _BoutonPrincipal(
        libelle: 'Continuer',
        occupe: _occupe,
        onPressed: _envoyerCode,
      ),
    );
  }

  /// « Préfixe » et le numéro, deux champs cernés d'un trait, comme chez
  /// Glovo.
  Widget _champNumero() => Row(
    children: [
      Semantics(
        button: true,
        label: 'Pays : ${_pays.name}, indicatif ${_pays.dialCode}',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: const ValueKey('auth-country'),
            onTap: _occupe ? null : _choisirPays,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              height: 64,
              padding: const EdgeInsets.fromLTRB(14, 0, 8, 0),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: _erreur == null ? TovoTheme.ink : TovoTheme.danger,
                  width: 1.4,
                ),
              ),
              child: Row(
                children: [
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Préfixe',
                        style: TextStyle(
                          fontSize: 12,
                          color: TovoTheme.inkDoux,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text(
                            _pays.flag,
                            style: const TextStyle(fontSize: 18),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _pays.dialCode,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              color: TovoTheme.ink,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(width: 10),
                  const Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 20,
                    color: TovoTheme.inkDoux,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: TextField(
          key: const ValueKey('auth-phone'),
          controller: _numero,
          keyboardType: TextInputType.phone,
          autofillHints: const [AutofillHints.telephoneNumberNational],
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _envoyerCode(),
          onChanged: (_) {
            if (_erreur != null) setState(() => _erreur = null);
          },
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          cursorColor: TovoTheme.ink,
          decoration: InputDecoration(
            hintText: 'Numéro de téléphone',
            // Un cran plus petit que la saisie : le texte tient en entier.
            hintStyle: const TextStyle(
              fontSize: 15.5,
              letterSpacing: 0,
              color: TovoTheme.muted,
            ),
            filled: false,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 21,
            ),
            border: BordsDeChamp.repos,
            enabledBorder: _erreur == null
                ? BordsDeChamp.repos
                : BordsDeChamp.erreur,
            focusedBorder: _erreur == null
                ? BordsDeChamp.focus
                : BordsDeChamp.erreur,
          ),
          style: const TextStyle(
            fontSize: 17,
            letterSpacing: 0.3,
            fontWeight: FontWeight.w500,
            color: TovoTheme.ink,
          ),
        ),
      ),
    ],
  );

  /// Le code : un titre, six cases, et c'est tout. Il se valide seul au
  /// sixième chiffre — il n'y a pas de bouton à chercher.
  Widget _ecranCode() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 444),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Retour(onPressed: _occupe ? null : _changerDeNumero),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 20, 12, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Entrez le code', style: _titre),
                    const SizedBox(height: 8),
                    Text.rich(
                      TextSpan(
                        text: 'Envoyé sur WhatsApp au ',
                        children: [
                          TextSpan(
                            text: _numeroLisible,
                            style: const TextStyle(
                              color: TovoTheme.ink,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                      style: _sousTitre,
                    ),
                    const SizedBox(height: 32),
                    _CasesCode(
                      controller: _code,
                      actif: !_occupe,
                      onComplet: _verifierCode,
                      onChanged: () {
                        if (_erreur != null) setState(() => _erreur = null);
                      },
                    ),
                    if (_erreur != null) _Erreur(_erreur!),
                    const SizedBox(height: 24),
                    SizedBox(
                      height: 40,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: _occupe
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: TovoTheme.teal,
                                ),
                              )
                            : _secondesAvantRenvoi > 0
                            ? Text(
                                'Renvoyer le code dans $_secondesAvantRenvoi s',
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: TovoTheme.muted,
                                ),
                              )
                            : TextButton(
                                onPressed: _envoyerCode,
                                style: TextButton.styleFrom(
                                  foregroundColor: TovoTheme.teal,
                                  padding: EdgeInsets.zero,
                                  minimumSize: const Size(0, 40),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                child: const Text(
                                  'Renvoyer le code',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// « +227 90 12 34 56 » : le numéro tel qu'on le lit, par paires.
  String get _numeroLisible {
    final chiffres = _numero.text.replaceAll(RegExp(r'\D'), '');
    final local = _pays.removeTrunkZero && chiffres.startsWith('0')
        ? chiffres.substring(1)
        : chiffres;
    final paires = <String>[];
    for (var i = 0; i < local.length; i += 2) {
      paires.add(
        local.substring(i, i + 2 > local.length ? local.length : i + 2),
      );
    }
    return '${_pays.dialCode} ${paires.join(' ')}';
  }

  void _changerDeNumero() => setState(() {
    _etape = _Etape.numero;
    _code.clear();
    _erreur = null;
  });

  static const _titre = TextStyle(
    fontFamily: TovoTheme.policeClient,
    fontSize: 26,
    height: 1.15,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.8,
    color: TovoTheme.ink,
  );

  static const _sousTitre = TextStyle(
    fontSize: 15,
    height: 1.45,
    color: TovoTheme.inkDoux,
  );
}

class _Retour extends StatelessWidget {
  const _Retour({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Retour',
    onPressed: onPressed,
    icon: const Icon(Icons.arrow_back_rounded, color: TovoTheme.ink),
  );
}

class _Erreur extends StatelessWidget {
  const _Erreur(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Text(
      message,
      style: const TextStyle(fontSize: 14, color: TovoTheme.danger),
    ),
  );
}

class _BoutonPrincipal extends StatelessWidget {
  const _BoutonPrincipal({
    required this.libelle,
    required this.occupe,
    required this.onPressed,
  });

  final String libelle;
  final bool occupe;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => FilledButton(
    style: FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(50),
      backgroundColor: TovoTheme.teal,
      foregroundColor: Colors.white,
      disabledBackgroundColor: TovoTheme.teal,
      shape: const StadiumBorder(),
    ),
    onPressed: occupe ? null : onPressed,
    child: occupe
        ? const _Attente()
        : Text(
            libelle,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
  );
}

/// Six cases, un seul champ. Le vrai champ est invisible sous les cases :
/// il garde le collage, le remplissage automatique du code (iOS, Android) et
/// l'effacement ; les cases ne font que montrer ce qu'il contient.
class _CasesCode extends StatefulWidget {
  const _CasesCode({
    required this.controller,
    required this.actif,
    required this.onComplet,
    required this.onChanged,
  });

  final TextEditingController controller;
  final bool actif;
  final VoidCallback onComplet;
  final VoidCallback onChanged;

  @override
  State<_CasesCode> createState() => _CasesCodeState();
}

class _CasesCodeState extends State<_CasesCode> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_redessiner);
    widget.controller.addListener(_redessiner);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_redessiner);
    _focus.dispose();
    super.dispose();
  }

  void _redessiner() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final code = widget.controller.text;
    return SizedBox(
      height: 60,
      child: Stack(
        children: [
          Positioned.fill(
            child: TextField(
              key: const ValueKey('auth-code'),
              controller: widget.controller,
              focusNode: _focus,
              enabled: widget.actif,
              autofocus: true,
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              maxLength: 6,
              showCursor: false,
              enableInteractiveSelection: false,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(color: Colors.transparent, fontSize: 1),
              decoration: const InputDecoration(
                counterText: '',
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                filled: false,
              ),
              onChanged: (v) {
                widget.onChanged();
                // Validation automatique à six chiffres : un code se saisit
                // et se valide d'un geste, pas de deux.
                if (v.length == 6) widget.onComplet();
              },
            ),
          ),
          IgnorePointer(
            child: Row(
              children: [
                for (var i = 0; i < 6; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(
                    child: _Case(
                      chiffre: i < code.length ? code[i] : null,
                      courante:
                          _focus.hasFocus &&
                          (i == code.length || (i == 5 && code.length == 6)),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Case extends StatelessWidget {
  const _Case({required this.chiffre, required this.courante});

  final String? chiffre;
  final bool courante;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: TovoTheme.vif,
    height: 60,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: const Color(0xFFF2F3F1),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(
        color: courante ? TovoTheme.ink : Colors.transparent,
        width: 1.5,
      ),
    ),
    child: Text(
      chiffre ?? '',
      style: const TextStyle(
        fontFamily: TovoTheme.policeClient,
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: TovoTheme.ink,
      ),
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
