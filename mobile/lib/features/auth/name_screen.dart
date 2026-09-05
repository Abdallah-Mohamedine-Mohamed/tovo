import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/marque.dart';
import '../../core/theme.dart';

/// Le nom, demandé une fois et une seule.
///
/// L'inscription de Tovo ne réclame que deux choses : un numéro et un nom.
/// Pas d'email — à Niamey, beaucoup de clients n'en ont pas, et en faire une
/// condition écarterait une part du marché pour une donnée dont Tovo n'a
/// aucun usage.
///
/// Cet écran est présenté par `AuthGate` et non par l'écran de connexion,
/// parce que la porte est le seul passage obligé : la session naît dès le
/// code validé, et quelqu'un qui fermerait l'app à cet instant entrerait
/// ensuite sans nom si le contrôle vivait ailleurs.
class DemandeDeNom extends StatefulWidget {
  const DemandeDeNom({super.key, required this.onEnregistre});

  final VoidCallback onEnregistre;

  @override
  State<DemandeDeNom> createState() => _DemandeDeNomState();
}

class _DemandeDeNomState extends State<DemandeDeNom> {
  final TextEditingController _nom = TextEditingController();
  bool _occupe = false;
  String? _erreur;

  @override
  void dispose() {
    _nom.dispose();
    super.dispose();
  }

  Future<void> _enregistrer() async {
    final nom = _nom.text.trim();
    if (nom.length < 2) {
      setState(() => _erreur = 'Indiquez votre nom.');
      return;
    }

    setState(() {
      _occupe = true;
      _erreur = null;
    });

    final client = Supabase.instance.client;
    final id = client.auth.currentUser?.id;

    try {
      if (id != null) {
        await client.from('profiles').update({'full_name': nom}).eq('id', id);
      }
      unawaited(HapticFeedback.selectionClick());
      if (mounted) widget.onEnregistre();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _occupe = false;
        // Le compte existe, la session est ouverte : le seul obstacle est le
        // réseau. On le dit et on laisse réessayer, plutôt que de renvoyer
        // vers la connexion et de tout recommencer.
        _erreur = 'Enregistrement impossible. Vérifiez votre réseau.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TovoTheme.canvas,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: TovoTheme.teal,
                    shape: BoxShape.circle,
                    boxShadow: TovoTheme.ombreFlottante,
                  ),
                  child: const MarqueTovo(taille: 42, couleur: Colors.white),
                ),
                const SizedBox(height: 28),
                const Text(
                  'Encore une chose',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1.2,
                    color: TovoTheme.tealDeep,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Comment vous appelez-vous ?',
                  style: TextStyle(fontSize: 13, color: TovoTheme.muted),
                ),
                const SizedBox(height: 40),
                TextField(
                  controller: _nom,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _enregistrer(),
                  decoration: InputDecoration(
                    hintText: 'Prénom et nom',
                    // Dire à quoi sert l'information fait qu'on la donne.
                    helperText: 'Votre livreur le verra pour vous trouver.',
                    filled: true,
                    fillColor: TovoTheme.tealMist,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 16,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(TovoTheme.radiusChip),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    backgroundColor: TovoTheme.teal,
                  ),
                  onPressed: _occupe ? null : _enregistrer,
                  child: Text(
                    _occupe ? 'Un instant…' : 'Continuer',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (_erreur != null) ...[
                  const SizedBox(height: 14),
                  Text(
                    _erreur!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: TovoTheme.danger,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Évite d'importer dart:async pour un seul usage.
void unawaited(Future<void> future) {
  future.catchError((_) {});
}
