import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme.dart';
import 'anneau_tovo.dart';

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

  /// Le prénom seul : c'est lui qu'on salue.
  String get _prenom {
    final mots = _nom.text.trim().split(RegExp(r'\s+'));
    final premier = mots.isEmpty ? '' : mots.first;
    if (premier.isEmpty) return '';
    return premier[0].toUpperCase() + premier.substring(1);
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: TovoTheme.canvas,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final clavier = MediaQuery.viewInsetsOf(context).bottom > 0;
              final place = constraints.maxHeight - 330;
              final taille = clavier
                  ? place.clamp(0.0, 200.0)
                  : (constraints.maxWidth - 32)
                        .clamp(0.0, place)
                        .clamp(0.0, 300.0);
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight - 24,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          AnimatedSize(
                            duration: TovoTheme.normal,
                            curve: TovoTheme.courbe,
                            child: taille >= 120
                                ? Center(
                                    child: AnneauTovo(
                                      taille: taille,
                                      centre: _Salut(
                                        prenom: _prenom,
                                        taille: taille,
                                      ),
                                    ),
                                  )
                                : const SizedBox(
                                    width: double.infinity,
                                    height: 16,
                                  ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            // Coupé à la main : « appelez-vous » ne doit pas
                            // se casser sur le trait d'union (Geist n'a pas
                            // de trait d'union insécable).
                            'Comment vous\nappelez-vous ?',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontFamily: TovoTheme.policeClient,
                              fontSize: 28,
                              height: 1.15,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.8,
                              color: TovoTheme.ink,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Votre livreur saura qui il cherche.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 16,
                              height: 1.45,
                              color: TovoTheme.inkDoux,
                            ),
                          ),
                          const SizedBox(height: 28),
                          TextField(
                            controller: _nom,
                            autofillHints: const [AutofillHints.name],
                            textCapitalization: TextCapitalization.words,
                            textInputAction: TextInputAction.done,
                            onSubmitted: (_) => _enregistrer(),
                            onChanged: (_) => setState(() => _erreur = null),
                            cursorColor: TovoTheme.teal,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w500,
                              color: TovoTheme.ink,
                            ),
                            decoration: InputDecoration(
                              hintText: 'Prénom et nom',
                              hintStyle: const TextStyle(
                                color: TovoTheme.muted,
                              ),
                              filled: true,
                              fillColor: const Color(0xFFF2F3F1),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 17,
                              ),
                              border: _bord,
                              enabledBorder: _bord,
                              focusedBorder: _bord,
                            ),
                          ),
                          if (_erreur != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(
                                _erreur!,
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: TovoTheme.danger,
                                ),
                              ),
                            ),
                          const SizedBox(height: 16),
                          FilledButton(
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(56),
                              backgroundColor: TovoTheme.teal,
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: TovoTheme.teal,
                              disabledForegroundColor: Colors.white,
                              shape: const StadiumBorder(),
                            ),
                            onPressed: _occupe ? null : _enregistrer,
                            child: Text(
                              _occupe ? 'Un instant…' : 'Continuer',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  static final _bord = OutlineInputBorder(
    borderRadius: BorderRadius.circular(16),
    borderSide: BorderSide.none,
  );
}

/// Le centre de l'anneau : « Bonjour », puis « Bonjour, Amina » à mesure
/// que le client tape. L'app le reconnaît avant même qu'il ait validé.
class _Salut extends StatelessWidget {
  const _Salut({required this.prenom, required this.taille});

  final String prenom;
  final double taille;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontFamily: TovoTheme.policeClient,
      fontSize: (taille * 0.075).clamp(16.0, 28.0),
      height: 1.2,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.5,
      color: TovoTheme.teal,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(prenom.isEmpty ? 'Bonjour' : 'Bonjour,', style: style),
        AnimatedSize(
          duration: TovoTheme.normal,
          curve: TovoTheme.courbe,
          child: prenom.isEmpty
              ? const SizedBox(width: 0)
              : FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    prenom,
                    key: const ValueKey('salut-prenom'),
                    maxLines: 1,
                    style: style.copyWith(color: TovoTheme.ink),
                  ),
                ),
        ),
      ],
    );
  }
}

/// Évite d'importer dart:async pour un seul usage.
void unawaited(Future<void> future) {
  future.catchError((_) {});
}
