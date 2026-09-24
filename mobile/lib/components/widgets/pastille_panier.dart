import 'package:flutter/material.dart';

import '../../core/panier.dart';
import '../../core/theme.dart';
import '../registry.dart';

/// La pastille du panier : « 🛍 2 · 7 000 F ».
///
/// Petite et discrète — pas une barre en bas d'écran. Elle n'existe que si
/// le panier contient quelque chose, apparaît dès le premier ajout, et mène
/// en un geste à l'écran de commande. Le client sait toujours où est son
/// panier sans qu'on le lui annonce par un message.
class PastillePanier extends StatelessWidget {
  const PastillePanier({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ApercuPanier?>(
    valueListenable: PanierEnDirect.instance,
    builder: (context, panier, _) => AnimatedSwitcher(
      duration: TovoTheme.normal,
      switchInCurve: TovoTheme.courbe,
      transitionBuilder: (enfant, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween(begin: 0.85, end: 1.0).animate(animation),
          child: enfant,
        ),
      ),
      child: panier == null
          ? const SizedBox.shrink(key: ValueKey('vide'))
          : _Pastille(
              // La clé change avec le contenu : un ajout se voit.
              key: ValueKey('${panier.articles}-${panier.total}'),
              panier: panier,
              onTap: onTap,
            ),
    ),
  );
}

class _Pastille extends StatelessWidget {
  const _Pastille({super.key, required this.panier, required this.onTap});

  final ApercuPanier panier;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final articles = panier.articles;
    return Semantics(
      button: true,
      label:
          'Panier : $articles article${articles > 1 ? 's' : ''}, '
          '${Money.format(panier.total)}',
      excludeSemantics: true,
      child: Tooltip(
        message: 'Voir le panier',
        child: Material(
          color: TovoTheme.ink,
          shape: const StadiumBorder(),
          elevation: 2,
          shadowColor: Colors.black26,
          child: InkWell(
            onTap: onTap,
            customBorder: const StadiumBorder(),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 9, 16, 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.shopping_bag_outlined,
                    size: 17,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '$articles · ${Money.format(panier.total)}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
