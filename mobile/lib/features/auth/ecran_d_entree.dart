import 'package:flutter/material.dart';

import '../../core/theme.dart';
import 'anneau_tovo.dart';

/// La mise en page des écrans d'entrée, à la Glovo : une image en pleine
/// largeur jusque sous la barre d'état, une feuille aux coins arrondis qui
/// monte dessus, le formulaire dans la feuille et le bouton tout en bas.
///
/// Clavier ouvert, RIEN ne disparaît : l'image garde sa taille, la page
/// défile d'elle-même jusqu'au champ touché, et « Continuer » remonte juste
/// au-dessus du clavier. La version précédente effaçait l'image et faisait
/// sauter toute la page (retour du client, 25/09).
class EcranDEntree extends StatelessWidget {
  const EcranDEntree({
    super.key,
    required this.heros,
    required this.contenu,
    required this.bouton,
    this.onRetour,
  });

  /// L'image, qui reçoit la hauteur de la barre d'état qu'elle recouvre.
  final Widget Function(double margeHaut) heros;
  final List<Widget> contenu;
  final Widget bouton;
  final VoidCallback? onRetour;

  static const _arrondi = 28.0;

  @override
  Widget build(BuildContext context) {
    final haut = MediaQuery.paddingOf(context).top;
    // La hauteur de l'ÉCRAN, que le clavier ne change pas : l'image ne
    // bouge pas quand il s'ouvre.
    final hauteurHeros = (MediaQuery.sizeOf(context).height * 0.40)
        .clamp(220.0, 360.0)
        .toDouble();
    return Stack(
      children: [
        Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: hauteurHeros + _arrondi,
                      child: ColoredBox(
                        color: AnneauTovo.fond,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: _arrondi),
                          child: heros(haut),
                        ),
                      ),
                    ),
                    // La feuille monte sur l'image de la hauteur de son
                    // arrondi.
                    Transform.translate(
                      offset: const Offset(0, -_arrondi),
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          color: TovoTheme.canvas,
                          borderRadius: BorderRadius.vertical(
                            top: Radius.circular(_arrondi),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 28, 24, 0),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 420),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: contenu,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Hors du défilement : toujours visible, au-dessus du clavier.
            SafeArea(top: false, child: EnBasDEcran(child: bouton)),
          ],
        ),
        if (onRetour != null)
          Positioned(
            top: haut + 4,
            left: 8,
            child: IconButton(
              tooltip: 'Retour',
              onPressed: onRetour,
              icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
            ),
          ),
      ],
    );
  }
}

/// Le bas de l'écran : le bouton principal, seul, sous le pouce.
class EnBasDEcran extends StatelessWidget {
  const EnBasDEcran({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: child,
      ),
    ),
  );
}

/// Les champs cernés d'un trait, comme chez Glovo : plus lisibles qu'un
/// champ gris sur fond clair, et le focus se voit.
class BordsDeChamp {
  const BordsDeChamp._();

  static final repos = OutlineInputBorder(
    borderRadius: BorderRadius.circular(14),
    borderSide: const BorderSide(color: TovoTheme.ink, width: 1.4),
  );

  static final focus = OutlineInputBorder(
    borderRadius: BorderRadius.circular(14),
    borderSide: const BorderSide(color: TovoTheme.ink, width: 2),
  );

  static final erreur = OutlineInputBorder(
    borderRadius: BorderRadius.circular(14),
    borderSide: const BorderSide(color: TovoTheme.danger, width: 1.6),
  );
}

/// Les titres des écrans d'entrée : « Bienvenue », en gras, centré.
const styleTitreEntree = TextStyle(
  fontFamily: TovoTheme.policeClient,
  fontSize: 30,
  height: 1.15,
  fontWeight: FontWeight.w700,
  letterSpacing: -0.8,
  color: TovoTheme.ink,
);

const styleSousTitreEntree = TextStyle(
  fontSize: 16,
  height: 1.4,
  color: TovoTheme.inkDoux,
);
