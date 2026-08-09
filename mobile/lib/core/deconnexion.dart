import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'push.dart';
import 'theme.dart';

/// Se déconnecter, depuis n'importe laquelle des trois apps.
///
/// Il n'existait aucun moyen de sortir d'un compte, sauf à tomber sur l'écran
/// « ce compte n'est pas un compte livreur ». Un boutiquier qui change de
/// téléphone, un livreur qui prête le sien, un compte de test ouvert par
/// erreur : tous restaient enfermés, la réinstallation pour seule issue.
///
/// La confirmation n'est pas une politesse. Se reconnecter demande un code
/// WhatsApp, qui n'arrive pas toujours dans la seconde ; un appui malheureux
/// pendant un service coûte plusieurs minutes de commandes non traitées.
Future<void> confirmerDeconnexion(BuildContext context) async {
  final confirme = await showDialog<bool>(
    context: context,
    builder: (contexte) => AlertDialog(
      title: const Text('Se déconnecter ?'),
      content: const Text(
        'Il faudra un nouveau code de connexion par WhatsApp pour revenir.',
        style: TextStyle(fontSize: 13, height: 1.5),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(contexte).pop(false),
          child: const Text('Rester'),
        ),
        TextButton(
          onPressed: () => Navigator.of(contexte).pop(true),
          style: TextButton.styleFrom(foregroundColor: TovoTheme.danger),
          child: const Text('Se déconnecter'),
        ),
      ],
    ),
  );

  if (confirme != true) return;

  // Le jeton push d'abord, session encore ouverte : la RLS n'autorise à
  // supprimer que ses propres jetons, et après `signOut` il n'y a plus de
  // « soi » pour le faire.
  await TovoPush.oublier();
  await Supabase.instance.client.auth.signOut();

  // Aucune navigation ici : `AuthGate` écoute l'état de session et bascule de
  // lui-même vers l'écran de connexion. Pousser une route en plus laisserait
  // l'ancienne pile d'écrans dessous, avec les données du compte quitté.
}
