import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/api.dart';
import '../../core/push.dart';
import '../../core/read_cache.dart';
import '../../core/theme.dart';

/// Supprimer son compte (maquette du 27/10), exigé par Apple et Google.
///
/// En deux temps, volontairement : le client lit ce qui disparaît, reçoit un
/// code par WhatsApp et le saisit. Cette connexion toute fraîche est la seule
/// qui autorise le serveur à supprimer (routes/compte.ts) : un téléphone
/// prêté ou laissé déverrouillé ne suffit pas.
class SupprimerCompteScreen extends StatefulWidget {
  const SupprimerCompteScreen({
    super.key,
    required this.api,
    required this.telephone,
  });

  final TovoApi api;

  /// Le numéro du compte, tel que Supabase le garde (« 22796123456 »).
  final String telephone;

  @override
  State<SupprimerCompteScreen> createState() => _SupprimerCompteScreenState();
}

class _SupprimerCompteScreenState extends State<SupprimerCompteScreen> {
  final _code = TextEditingController();
  bool _codeEnvoye = false;
  bool _occupe = false;
  String? _erreur;

  String get _numero {
    final chiffres = widget.telephone.replaceAll(RegExp(r'\D'), '');
    return '+$chiffres';
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _envoyerLeCode() async {
    setState(() {
      _occupe = true;
      _erreur = null;
    });
    try {
      await Supabase.instance.client.auth.signInWithOtp(phone: _numero);
      if (!mounted) return;
      setState(() => _codeEnvoye = true);
    } on Exception {
      if (!mounted) return;
      setState(() => _erreur = 'Le code n’a pas pu être envoyé. Réessayez.');
    } finally {
      if (mounted) setState(() => _occupe = false);
    }
  }

  Future<void> _supprimer() async {
    final code = _code.text.trim();
    if (code.length != 6) {
      setState(() => _erreur = 'Le code a 6 chiffres.');
      return;
    }
    setState(() {
      _occupe = true;
      _erreur = null;
    });
    try {
      await Supabase.instance.client.auth.verifyOTP(
        phone: _numero,
        token: code,
        type: OtpType.sms,
      );
    } on Exception {
      if (!mounted) return;
      _code.clear();
      setState(() {
        _occupe = false;
        _erreur = 'Code incorrect ou expiré.';
      });
      return;
    }
    // Le jeton push pendant que la session existe encore (la RLS ne laisse
    // supprimer que ses propres jetons).
    await TovoPush.oublier();
    final reponse = await widget.api.delete('/me');
    if (!mounted) return;
    if (!reponse.ok) {
      setState(() {
        _occupe = false;
        _erreur = reponse.content;
      });
      return;
    }
    await TovoReadCache.clearPrivateCaches();
    await Supabase.instance.client.auth.signOut();
    // AuthGate écoute la session et revient de lui-même à la connexion.
    if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Material(
                color: TovoTheme.bloc,
                shape: const CircleBorder(),
                child: IconButton(
                  tooltip: 'Retour',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(
                    Icons.arrow_back_rounded,
                    color: TovoTheme.ink,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Supprimer votre compte ?',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'C’est définitif. Voici ce qui disparaît :',
              style: TextStyle(fontSize: 15, color: TovoTheme.inkDoux),
            ),
            const SizedBox(height: 12),
            for (final ligne in const [
              'votre nom, votre numéro et vos adresses ;',
              'vos conversations avec Tovo ;',
              'votre panier et vos préférences.',
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      margin: const EdgeInsets.only(top: 8, right: 12),
                      decoration: const BoxDecoration(
                        color: TovoTheme.ink,
                        shape: BoxShape.circle,
                      ),
                    ),
                    Expanded(
                      child: Text(ligne, style: const TextStyle(fontSize: 15)),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            const Text(
              'Vos commandes passées restent pour la comptabilité des boutiques '
              'et des livreurs, sans votre nom, votre numéro ni votre adresse.',
              style: TextStyle(
                fontSize: 14,
                color: TovoTheme.inkDoux,
                height: 1.45,
              ),
            ),
            if (_codeEnvoye) ...[
              const SizedBox(height: 24),
              const Text(
                'Saisissez le code reçu par WhatsApp',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('code-suppression'),
                controller: _code,
                autofocus: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                style: const TextStyle(fontSize: 22, letterSpacing: 6),
                decoration: InputDecoration(
                  counterText: '',
                  filled: true,
                  fillColor: TovoTheme.bloc,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ],
            if (_erreur != null) ...[
              const SizedBox(height: 14),
              Text(_erreur!, style: const TextStyle(color: TovoTheme.danger)),
            ],
            const SizedBox(height: 28),
            FilledButton(
              key: const ValueKey('confirmer-suppression'),
              onPressed: _occupe
                  ? null
                  : (_codeEnvoye ? _supprimer : _envoyerLeCode),
              style: FilledButton.styleFrom(
                backgroundColor: TovoTheme.danger,
                minimumSize: const Size.fromHeight(54),
              ),
              child: Text(
                _codeEnvoye
                    ? 'Supprimer définitivement'
                    : 'Recevoir le code de confirmation',
              ),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: _occupe ? null : () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                foregroundColor: TovoTheme.ink,
              ),
              child: const Text('Garder mon compte'),
            ),
          ],
        ),
      ),
    );
  }
}
