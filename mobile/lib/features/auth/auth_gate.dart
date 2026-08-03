import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/push.dart';
import '../../core/theme.dart';
import 'auth_screen.dart';

/// Porte d'entrée des trois apps.
///
/// Elle écoute l'état de session et bascule entre l'écran de connexion et
/// l'app. Un jeton expiré ou une déconnexion ramènent automatiquement à la
/// connexion, sans que chaque écran ait à s'en préoccuper.
///
/// Le contrôle de rôle est fait ici pour les apps livreur et boutiquier :
/// quelqu'un qui n'a pas le bon rôle voit un message clair plutôt qu'une
/// interface vide dont il ne comprendrait pas le silence.
class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    required this.titre,
    required this.sousTitre,
    required this.child,
    required this.appPush,
    this.roleRequis,
  });

  final String titre;
  final String sousTitre;

  /// Construit l'app une fois la session ouverte et le rôle validé.
  final Widget Function() child;

  /// `driver` ou `merchant`. Nul pour l'app client : tout compte est client.
  final String? roleRequis;

  /// Identifiant de l'app pour les notifications.
  ///
  /// Un jeton par app, et non par personne : un livreur qui est aussi client
  /// le soir doit recevoir ses courses d'un côté et ses commandes de
  /// l'autre, sans que l'un écrase l'autre.
  final String appPush;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  StreamSubscription<AuthState>? _abonnement;
  Session? _session;
  String? _role;
  bool _verificationEnCours = true;

  @override
  void initState() {
    super.initState();
    _session = Supabase.instance.client.auth.currentSession;

    _abonnement = Supabase.instance.client.auth.onAuthStateChange.listen((etat) {
      if (!mounted) return;
      setState(() {
        _session = etat.session;
        _role = null;
        _verificationEnCours = etat.session != null;
      });
      if (etat.session != null) _chargerRole();
    });

    if (_session != null) {
      _chargerRole();
    } else {
      _verificationEnCours = false;
    }
  }

  @override
  void dispose() {
    _abonnement?.cancel();
    super.dispose();
  }

  Future<void> _chargerRole() async {
    // Le rôle vit dans `profiles`, jamais dans le jeton : un utilisateur ne
    // doit pas pouvoir se promouvoir en modifiant ses métadonnées.
    try {
      final data = await Supabase.instance.client
          .from('profiles')
          .select('role')
          .eq('id', Supabase.instance.client.auth.currentUser!.id)
          .maybeSingle();

      if (!mounted) return;
      setState(() {
        _role = data?['role'] as String? ?? 'client';
        _verificationEnCours = false;
      });

      // Après la connexion, jamais avant : un jeton sans utilisateur n'a
      // personne à qui être rattaché.
      unawaited(TovoPush.enregistrer(widget.appPush));
    } on Exception {
      if (!mounted) return;
      // Sans réponse, on ne bloque pas : la RLS refusera de toute façon ce
      // qui ne lui est pas permis, et l'app affichera ses propres messages.
      setState(() {
        _role = 'client';
        _verificationEnCours = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_session == null) {
      return AuthScreen(titre: widget.titre, sousTitre: widget.sousTitre);
    }

    if (_verificationEnCours) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: TovoTheme.teal)),
      );
    }

    final requis = widget.roleRequis;
    if (requis != null && _role != requis && _role != 'admin') {
      return _MauvaisRole(role: _role ?? 'client', requis: requis);
    }

    return widget.child();
  }
}

class _MauvaisRole extends StatelessWidget {
  const _MauvaisRole({required this.role, required this.requis});

  final String role;
  final String requis;

  static const Map<String, String> _libelles = {
    'driver': 'livreur',
    'merchant': 'boutiquier',
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 40, color: TovoTheme.muted),
              const SizedBox(height: 16),
              Text(
                'Ce compte n’est pas un compte ${_libelles[requis] ?? requis}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              const Text(
                'Contactez Tovo pour faire activer votre compte, puis reconnectez-vous.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: TovoTheme.muted),
              ),
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: () => Supabase.instance.client.auth.signOut(),
                child: const Text('Se déconnecter'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
