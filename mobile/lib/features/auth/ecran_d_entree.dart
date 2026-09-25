import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// La mise en page des écrans d'entrée, à la Glovo : une image en pleine
/// largeur jusque sous la barre d'état, une feuille aux coins arrondis qui
/// monte dessus, le formulaire dans la feuille et le bouton tout en bas.
///
/// Clavier ouvert, l'image s'efface et la feuille remonte : le champ et le
/// bouton restent visibles au-dessus du clavier, même sur un petit écran.
class EcranDEntree extends StatelessWidget {
  const EcranDEntree({
    super.key,
    required this.heros,
    required this.contenu,
    required this.bouton,
    this.onRetour,
  });

  /// Le contenu de l'image, selon la place disponible (sous la barre d'état).
  final Widget Function(double hauteur) heros;
  final List<Widget> contenu;
  final Widget bouton;
  final VoidCallback? onRetour;

  static const _arrondi = 28.0;

  @override
  Widget build(BuildContext context) {
    final haut = MediaQuery.paddingOf(context).top;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Le clavier se lit sur l'écran lui-même : le Scaffold retire sa
        // hauteur du MediaQuery qu'il transmet à son contenu. Lu ICI, relu à
        // chaque redimensionnement (l'ouverture du clavier en est un).
        final clavier = View.of(context).viewInsets.bottom > 0;
        final hauteurHeros = clavier
            ? 0.0
            : (constraints.maxHeight * 0.42).clamp(200.0, 380.0).toDouble();
        final placeHeros = hauteurHeros - haut;
        return Stack(
          children: [
            AnimatedPositioned(
              duration: TovoTheme.normal,
              curve: TovoTheme.courbe,
              top: 0,
              left: 0,
              right: 0,
              height: hauteurHeros + _arrondi,
              child: ColoredBox(
                color: TovoTheme.tealSoft,
                child: Padding(
                  padding: EdgeInsets.only(top: haut, bottom: _arrondi),
                  child: placeHeros >= 120
                      ? Center(child: heros(placeHeros))
                      : const SizedBox.shrink(),
                ),
              ),
            ),
            AnimatedPositioned(
              duration: TovoTheme.normal,
              curve: TovoTheme.courbe,
              top: hauteurHeros,
              left: 0,
              right: 0,
              bottom: 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: TovoTheme.canvas,
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(clavier ? 0 : _arrondi),
                  ),
                ),
                // Le bouton reste en bas quand il y a la place ; sinon (petit
                // écran, feuille qui remonte) tout défile, sans déborder.
                child: SafeArea(
                  top: clavier,
                  child: CustomScrollView(
                    slivers: [
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                24,
                                28,
                                24,
                                16,
                              ),
                              child: Center(
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 420,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: contenu,
                                  ),
                                ),
                              ),
                            ),
                            const Spacer(),
                            EnBasDEcran(child: bouton),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (onRetour != null)
              Positioned(
                top: haut + 4,
                left: 8,
                child: IconButton(
                  tooltip: 'Retour',
                  onPressed: onRetour,
                  icon: const Icon(
                    Icons.arrow_back_rounded,
                    color: TovoTheme.ink,
                  ),
                ),
              ),
          ],
        );
      },
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
