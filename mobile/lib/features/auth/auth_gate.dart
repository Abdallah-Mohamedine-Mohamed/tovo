import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/api.dart';
import '../../core/deconnexion.dart';
import '../../core/push.dart';
import '../../core/theme.dart';
import 'auth_screen.dart';
import 'name_screen.dart';

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

  /// Un compte sans nom n'entre pas.
  ///
  /// La session naît dès le code validé. Fermer l'app à cet instant précis
  /// laissait donc entrer, à la relance, un client dont le livreur ne
  /// connaîtrait jamais le nom. Le contrôle se fait ici et non dans l'écran
  /// de connexion, parce que c'est ici que passe TOUTE entrée dans l'app.
  bool _nomManquant = false;

  /// Le rôle n'a pas pu être lu — distinct d'un rôle lu et insuffisant.
  bool _echecRole = false;

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
      // Le jeton d'abord. Au réveil de l'appareil il est périmé — le minuteur
      // de Supabase ne tourne pas pendant le sommeil — et cette lecture
      // échouait, faisant retomber le boutiquier sur « ce compte n'est pas un
      // compte boutiquier » alors que rien ne clochait chez lui.
      await TovoApi.jetonFrais();

      // Le nom voyage avec le rôle : une seule requête au démarrage.
      final data = await Supabase.instance.client
          .from('profiles')
          .select('role, full_name')
          .eq('id', Supabase.instance.client.auth.currentUser!.id)
          .maybeSingle();

      if (!mounted) return;
      setState(() {
        _role = data?['role'] as String? ?? 'client';
        _nomManquant = ((data?['full_name'] as String?) ?? '').trim().isEmpty;
        _verificationEnCours = false;
      });

      // Après la connexion, jamais avant : un jeton sans utilisateur n'a
      // personne à qui être rattaché.
      unawaited(TovoPush.enregistrer(widget.appPush));
    } on Exception {
      if (!mounted) return;
      setState(() {
        // Un rôle qu'on n'a PAS pu lire n'est pas un rôle « client ».
        //
        // Le supposer envoyait le boutiquier sur « ce compte n'est pas un
        // compte boutiquier » — un message qui accuse le compte alors que
        // seul le réseau a manqué, et qui pousse à chercher le problème là
        // où il n'est pas. Les apps à rôle proposent donc de réessayer.
        //
        // L'app client, elle, ne bloque pas : tout compte y est client, et la
        // RLS refusera de toute façon ce qui n'est pas permis.
        _role = widget.roleRequis == null ? 'client' : null;
        _echecRole = widget.roleRequis != null;
        // Réseau muet : on ne réclame pas un nom qu'on n'a pas pu lire. Le
        // contrôle repassera au prochain démarrage.
        _nomManquant = false;
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

    if (_echecRole) {
      return _RoleIllisible(
        onReessayer: () {
          setState(() {
            _echecRole = false;
            _verificationEnCours = true;
          });
          _chargerRole();
        },
      );
    }

    final requis = widget.roleRequis;
    if (requis != null && _role != requis && _role != 'admin') {
      return _MauvaisRole(role: _role ?? 'client', requis: requis);
    }

    // Avant l'app, jamais après : un client sans nom passe commande et le
    // livreur cherche une porte sans savoir qui demander.
    if (_nomManquant) {
      return DemandeDeNom(
        onEnregistre: () => setState(() => _nomManquant = false),
      );
    }

    return widget.child();
  }
}

/// Le réseau a manqué au moment de lire le rôle.
///
/// Écran distinct de « mauvais rôle » à dessein : l'un dit « votre compte
/// n'est pas le bon », l'autre « je n'ai pas pu vérifier ». Les confondre
/// envoie le boutiquier appeler Tovo pour un problème de réseau.
class _RoleIllisible extends StatelessWidget {
  const _RoleIllisible({required this.onReessayer});

  final VoidCallback onReessayer;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off, size: 40, color: TovoTheme.muted),
              const SizedBox(height: 16),
              const Text(
                'Connexion impossible',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              const Text(
                'Votre compte est bien connecté, mais le réseau n’a pas '
                'répondu. Réessayez dans un instant.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: TovoTheme.muted, height: 1.5),
              ),
              const SizedBox(height: 24),
              FilledButton(onPressed: onReessayer, child: const Text('Réessayer')),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => confirmerDeconnexion(context),
                child: const Text('Se déconnecter'),
              ),
            ],
          ),
        ),
      ),
    );
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
                // Passe par le chemin commun : le jeton push doit être oublié
                // avant la déconnexion, sinon l'appareil continue de recevoir
                // les commandes du compte quitté.
                onPressed: () => confirmerDeconnexion(context),
                child: const Text('Se déconnecter'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
