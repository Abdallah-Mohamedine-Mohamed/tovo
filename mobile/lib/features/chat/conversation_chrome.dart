import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:image_picker/image_picker.dart';

import '../../components/registry.dart' show Money;
import '../../core/theme.dart';
import '../../core/noms.dart';
import '../../core/viewport_reveal.dart';

enum ConversationSymbol {
  menu,
  plus,
  microphone,
  keyboard,
  bookmark,
  calendar,
  back,
  forward,
  share,
  close,
  cart,
  // Même trait que les autres, dans l'esprit des symboles d'Apple.
  bag,
  bubble,
  compose,
  store,
  logout,
}

class ConversationIcon extends StatelessWidget {
  const ConversationIcon(
    this.symbol, {
    super.key,
    this.color = const Color(0xFF202020),
    this.size = 24,
  });
  final ConversationSymbol symbol;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _ConversationIconPainter(symbol, color),
  );
}

class _ConversationIconPainter extends CustomPainter {
  const _ConversationIconPainter(this.symbol, this.color);
  final ConversationSymbol symbol;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    void line(double startX, double startY, double endX, double endY) =>
        canvas.drawLine(Offset(startX, startY), Offset(endX, endY), stroke);
    switch (symbol) {
      case ConversationSymbol.menu:
        line(4, 5, 17, 5);
        line(4, 12, 21, 12);
        line(4, 19, 13, 19);
      case ConversationSymbol.plus:
        line(12, 3, 12, 21);
        line(3, 12, 21, 12);
      case ConversationSymbol.microphone:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(9, 2, 6, 12),
            const Radius.circular(3),
          ),
          stroke,
        );
        canvas.drawPath(
          Path()
            ..moveTo(5.5, 10)
            ..lineTo(5.5, 12)
            ..cubicTo(5.5, 20, 18.5, 20, 18.5, 12)
            ..lineTo(18.5, 10),
          stroke,
        );
        line(12, 18, 12, 22);
        line(8, 22, 16, 22);
      case ConversationSymbol.keyboard:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(1, 4, 22, 16),
            const Radius.circular(4),
          ),
          stroke,
        );
        for (final row in [8.0, 12.0]) {
          for (final column in [5.0, 9.5, 14.0, 18.5]) {
            line(column, row, column + 0.5, row);
          }
        }
        line(7, 16, 17, 16);
      case ConversationSymbol.bookmark:
        canvas.drawPath(
          Path()
            ..moveTo(5, 21)
            ..lineTo(5, 5)
            ..quadraticBezierTo(5, 2, 8, 2)
            ..lineTo(16, 2)
            ..quadraticBezierTo(19, 2, 19, 5)
            ..lineTo(19, 21)
            ..quadraticBezierTo(19, 22, 18, 21.4)
            ..lineTo(12, 17)
            ..lineTo(6, 21.4)
            ..quadraticBezierTo(5, 22, 5, 21),
          stroke,
        );
      case ConversationSymbol.calendar:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(3, 4, 18, 18),
            const Radius.circular(4),
          ),
          stroke,
        );
        line(3, 10, 21, 10);
        line(7, 1, 7, 6);
        line(17, 1, 17, 6);
      case ConversationSymbol.back:
        canvas.drawPath(
          Path()
            ..moveTo(15, 5)
            ..lineTo(8, 12)
            ..lineTo(15, 19),
          stroke,
        );
      case ConversationSymbol.forward:
        canvas.drawPath(
          Path()
            ..moveTo(9, 5)
            ..lineTo(16, 12)
            ..lineTo(9, 19),
          stroke,
        );
      case ConversationSymbol.share:
        canvas.drawPath(
          Path()
            ..moveTo(7, 9)
            ..lineTo(5, 9)
            ..quadraticBezierTo(3, 9, 3, 12)
            ..lineTo(3, 19)
            ..quadraticBezierTo(3, 22, 6, 22)
            ..lineTo(18, 22)
            ..quadraticBezierTo(21, 22, 21, 19)
            ..lineTo(21, 12)
            ..quadraticBezierTo(21, 9, 18, 9)
            ..lineTo(17, 9),
          stroke,
        );
        line(12, 15, 12, 1);
        canvas.drawPath(
          Path()
            ..moveTo(7, 6)
            ..lineTo(12, 1)
            ..lineTo(17, 6),
          stroke,
        );
      case ConversationSymbol.close:
        line(5, 5, 19, 19);
        line(19, 5, 5, 19);
      case ConversationSymbol.cart:
        canvas.drawPath(
          Path()
            ..moveTo(2, 3)
            ..lineTo(5, 3)
            ..lineTo(8, 16)
            ..lineTo(19, 16)
            ..lineTo(22, 7)
            ..lineTo(6, 7),
          stroke,
        );
        canvas.drawCircle(const Offset(9, 21), 1, stroke);
        canvas.drawCircle(const Offset(18, 21), 1, stroke);
      case ConversationSymbol.bag:
        // Un sac de courses : « mes commandes ».
        canvas.drawPath(
          Path()
            ..moveTo(5.2, 8)
            ..lineTo(18.8, 8)
            ..lineTo(19.8, 19)
            ..quadraticBezierTo(20, 21.5, 17.5, 21.5)
            ..lineTo(6.5, 21.5)
            ..quadraticBezierTo(4, 21.5, 4.2, 19)
            ..close(),
          stroke,
        );
        canvas.drawPath(
          Path()
            ..moveTo(8.5, 10.5)
            ..lineTo(8.5, 6.5)
            ..cubicTo(8.5, 1.8, 15.5, 1.8, 15.5, 6.5)
            ..lineTo(15.5, 10.5),
          stroke,
        );
      case ConversationSymbol.bubble:
        // Une bulle de discussion, la queue en bas à gauche.
        canvas.drawPath(
          Path()
            ..moveTo(8, 4)
            ..lineTo(16, 4)
            ..quadraticBezierTo(21, 4, 21, 9)
            ..lineTo(21, 12)
            ..quadraticBezierTo(21, 17, 16, 17)
            ..lineTo(10.5, 17)
            ..lineTo(6.6, 20.4)
            ..quadraticBezierTo(5.6, 21.2, 5.7, 19.9)
            ..lineTo(5.9, 16.8)
            ..quadraticBezierTo(3, 15.8, 3, 12)
            ..lineTo(3, 9)
            ..quadraticBezierTo(3, 4, 8, 4)
            ..close(),
          stroke,
        );
      case ConversationSymbol.compose:
        // Carré ouvert et crayon : « nouvelle conversation ».
        canvas.drawPath(
          Path()
            ..moveTo(11, 4)
            ..lineTo(7, 4)
            ..quadraticBezierTo(4, 4, 4, 7)
            ..lineTo(4, 17)
            ..quadraticBezierTo(4, 20, 7, 20)
            ..lineTo(17, 20)
            ..quadraticBezierTo(20, 20, 20, 17)
            ..lineTo(20, 13),
          stroke,
        );
        canvas.drawPath(
          Path()
            ..moveTo(17.6, 3.4)
            ..quadraticBezierTo(18.6, 2.4, 19.6, 3.4)
            ..lineTo(20.6, 4.4)
            ..quadraticBezierTo(21.6, 5.4, 20.6, 6.4)
            ..lineTo(12.5, 14.5)
            ..lineTo(9.2, 15.3)
            ..lineTo(10, 12)
            ..close(),
          stroke,
        );
      case ConversationSymbol.store:
        // Une devanture : store, vitrine, porte.
        canvas.drawPath(
          Path()
            ..moveTo(4.5, 3.5)
            ..lineTo(19.5, 3.5)
            ..lineTo(21, 8.5)
            ..quadraticBezierTo(21, 11, 18.4, 11)
            ..quadraticBezierTo(15.7, 11, 15.7, 8.5)
            ..quadraticBezierTo(15.7, 11, 12, 11)
            ..quadraticBezierTo(8.3, 11, 8.3, 8.5)
            ..quadraticBezierTo(8.3, 11, 5.6, 11)
            ..quadraticBezierTo(3, 11, 3, 8.5)
            ..close(),
          stroke,
        );
        canvas.drawPath(
          Path()
            ..moveTo(4.5, 11)
            ..lineTo(4.5, 20.5)
            ..lineTo(19.5, 20.5)
            ..lineTo(19.5, 11),
          stroke,
        );
        canvas.drawPath(
          Path()
            ..moveTo(10, 20.5)
            ..lineTo(10, 15.5)
            ..quadraticBezierTo(10, 14.5, 11, 14.5)
            ..lineTo(13, 14.5)
            ..quadraticBezierTo(14, 14.5, 14, 15.5)
            ..lineTo(14, 20.5),
          stroke,
        );
      case ConversationSymbol.logout:
        // Une porte et une flèche qui en sort.
        canvas.drawPath(
          Path()
            ..moveTo(10, 4)
            ..lineTo(7, 4)
            ..quadraticBezierTo(4, 4, 4, 7)
            ..lineTo(4, 17)
            ..quadraticBezierTo(4, 20, 7, 20)
            ..lineTo(10, 20),
          stroke,
        );
        line(10, 12, 20.5, 12);
        canvas.drawPath(
          Path()
            ..moveTo(16.5, 8)
            ..lineTo(20.5, 12)
            ..lineTo(16.5, 16),
          stroke,
        );
    }
  }

  @override
  bool shouldRepaint(_ConversationIconPainter oldDelegate) =>
      oldDelegate.symbol != symbol || oldDelegate.color != color;
}

class ConversationSurface extends StatelessWidget {
  const ConversationSurface({
    super.key,
    required this.child,
    this.radius = 28,
    this.color = const Color(0xF5FFFFFF),
  });
  final Widget child;
  final double radius;
  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(radius),
      boxShadow: const [
        BoxShadow(
          color: Color(0x11000000),
          blurRadius: 24,
          offset: Offset(0, 7),
        ),
      ],
    ),
    child: Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(radius),
      child: child,
    ),
  );
}

class ConversationControl extends StatelessWidget {
  const ConversationControl({
    super.key,
    required this.symbol,
    required this.label,
    this.onPressed,
    this.surface = true,
  });
  final ConversationSymbol symbol;
  final String label;
  final VoidCallback? onPressed;
  final bool surface;

  @override
  Widget build(BuildContext context) {
    final button = Tooltip(
      message: label,
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: SizedBox.square(
            dimension: 44,
            child: Center(
              child: ConversationIcon(
                symbol,
                size: 22,
                color: onPressed == null
                    ? const Color(0xFFB8B8B8)
                    : const Color(0xFF202020),
              ),
            ),
          ),
        ),
      ),
    );
    return surface ? ConversationSurface(child: button) : button;
  }
}

class ConversationBackdrop extends StatelessWidget {
  const ConversationBackdrop({
    super.key,
    required this.home,
    required this.child,
    this.listening = false,
  });
  final bool home;
  final bool listening;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child: ColoredBox(
          color: listening ? const Color(0xFFE3E6E6) : Colors.white,
        ),
      ),
      if (home || listening)
        Positioned.fill(
          child: IgnorePointer(
            child: Stack(
              children: [
                for (final glow in const [
                  (Alignment(-1.5, 0.1), Color(0xB3E6F8F1)),
                  (Alignment(1.4, 0.0), Color(0xA6FCEAF3)),
                  (Alignment(0.7, 1.2), Color(0xC4DDDFF6)),
                  (Alignment(-1.1, 1.3), Color(0xB3FAE7D9)),
                ])
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: glow.$1,
                          radius: 1.1,
                          colors: [glow.$2, glow.$2.withValues(alpha: 0)],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      child,
    ],
  );
}

/// « Commande en cours » : l'étape en une ligne, touchée pour suivre.
class _ActiveOrderCard extends StatelessWidget {
  const _ActiveOrderCard({required this.order, required this.onTap});

  final Map<String, dynamic> order;
  final VoidCallback onTap;

  static String etape(String statut, {required bool colis}) {
    if (colis) {
      return switch (statut) {
        'assigned' => 'Votre livreur arrive',
        'picked_up' => 'Colis récupéré',
        'delivering' => 'Colis en route',
        _ => 'On cherche un livreur',
      };
    }
    return switch (statut) {
      'pending' => 'La boutique confirme',
      'confirmed' => 'Commande acceptée',
      'preparing' => 'En cuisine',
      'ready' => 'Prête, un livreur arrive',
      'assigned' => 'Un livreur va la chercher',
      'picked_up' || 'delivering' => 'En route vers vous',
      _ => 'Commande en cours',
    };
  }

  @override
  Widget build(BuildContext context) {
    final colis = order['type'] == 'courier';
    final boutique = enPhrase(order['merchant_name'] as String?);
    return Semantics(
      button: true,
      label: 'Suivre ma commande',
      child: Material(
        color: const Color(0xFFF4F5F5),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  padding: const EdgeInsets.all(8),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  child: Image.asset(
                    colis
                        ? 'assets/icons/3d/colis.png'
                        : 'assets/icons/3d/repas.png',
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        colis ? 'Votre livreur' : 'Commande en cours',
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: TovoTheme.inkDoux,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        etape('${order['status']}', colis: colis),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: TovoTheme.ink,
                        ),
                      ),
                      if (!colis && boutique.isNotEmpty)
                        Text(
                          boutique,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            color: TovoTheme.inkDoux,
                          ),
                        ),
                    ],
                  ),
                ),
                const Text(
                  'Suivre',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: TovoTheme.ink,
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: TovoTheme.ink),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ConversationHome extends StatelessWidget {
  const ConversationHome({
    super.key,
    this.firstName,
    required this.recent,
    required this.onResume,
    required this.onSuggestion,
    required this.onBrowseShops,
    this.lastOrder,
    this.onReorder,
    this.activeOrder,
    this.onTrack,
  });
  final String? firstName;
  final List<Map<String, dynamic>> recent;
  final ValueChanged<String> onResume;
  final ValueChanged<String> onSuggestion;
  final VoidCallback onBrowseShops;

  /// Dernière commande livrée (GET /orders), ou nulle.
  final Map<String, dynamic>? lastOrder;
  final ValueChanged<Map<String, dynamic>>? onReorder;

  /// Commande pas encore livrée, proposée au suivi (sans y sauter d'office).
  final Map<String, dynamic>? activeOrder;
  final ValueChanged<Map<String, dynamic>>? onTrack;

  @override
  Widget build(BuildContext context) {
    final hour = DateTime.now().hour;
    final greeting = hour >= 5 && hour < 17 ? 'Bonjour' : 'Bonsoir';
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    // Entrée en cascade : le salut, puis chaque section, puis chaque carte.
    // Sans elle, l'accueil apparaissait d'un bloc, figé. Même courbe que le
    // reste de l'app ; « réduire les animations » est respecté par
    // ViewportReveal.
    Widget entre(int rang, Widget child) => ViewportReveal(
      delay: Duration(milliseconds: 70 * rang),
      duration: const Duration(milliseconds: 420),
      offset: 16,
      child: child,
    );
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        key: const PageStorageKey('conversation-home'),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Padding(
            padding: const EdgeInsets.only(top: 28, bottom: 68),
            child: Column(
              mainAxisAlignment:
                  recent.isEmpty && lastOrder == null && activeOrder == null
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                entre(
                  0,
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 26),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text:
                                '$greeting${firstName == null ? '.\n' : ', '}',
                          ),
                          if (firstName != null)
                            TextSpan(
                              text: '$firstName.\n',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          const TextSpan(text: 'Comment puis-je vous aider '),
                          const TextSpan(
                            text: 'aujourd’hui',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const TextSpan(
                            text: ' ? Demandez-moi n’importe quoi.',
                          ),
                        ],
                      ),
                      style: const TextStyle(
                        fontSize: 21,
                        height: 1.3,
                        letterSpacing: -0.45,
                        color: Color(0xFF232323),
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                ),
                if (activeOrder != null && onTrack != null)
                  entre(
                    1,
                    Padding(
                      padding: const EdgeInsets.fromLTRB(26, 28, 26, 0),
                      child: _ActiveOrderCard(
                        order: activeOrder!,
                        onTap: () => onTrack!(activeOrder!),
                      ),
                    ),
                  ),
                if (lastOrder != null && onReorder != null)
                  entre(
                    1,
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 32),
                        const _HomeSectionTitle('Votre dernière commande'),
                        const SizedBox(height: 15),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 26),
                          child: _LastOrderCard(
                            order: lastOrder!,
                            onReorder: () => onReorder!(lastOrder!),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (recent.isNotEmpty)
                  entre(
                    2,
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 32),
                        const _HomeSectionTitle('Reprendre où vous en étiez'),
                        const SizedBox(height: 15),
                        SizedBox(
                          height: 82 * scale,
                          child: ListView.separated(
                            clipBehavior: Clip.none,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 26,
                              vertical: 4,
                            ),
                            scrollDirection: Axis.horizontal,
                            itemCount: recent.length,
                            separatorBuilder: (_, index) =>
                                const SizedBox(width: 10),
                            itemBuilder: (context, index) => _HomePromptCard(
                              title:
                                  '${recent[index]['title'] ?? 'Votre dernière discussion'}',
                              asset: 'assets/branding/suggestion-meal.svg',
                              compact: true,
                              onTap: () => onResume('${recent[index]['id']}'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 32),
                entre(
                  3,
                  const _HomeSectionTitle('Essayez quelque chose de nouveau'),
                ),
                const SizedBox(height: 15),
                SizedBox(
                  height: 112 * scale,
                  child: ListView(
                    clipBehavior: Clip.none,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 26,
                      vertical: 4,
                    ),
                    scrollDirection: Axis.horizontal,
                    // L'ordre voulu par le client (25/09) : le colis
                    // d'abord, puis les courses, puis les boutiques.
                    children: [
                      entre(
                        4,
                        _HomePromptCard(
                          title: 'Je voudrais envoyer un colis',
                          asset: 'assets/branding/suggestion-parcel.svg',
                          onTap: () => onSuggestion('Je veux envoyer un colis'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      entre(
                        5,
                        _HomePromptCard(
                          title: 'Aide-moi à préparer mes courses',
                          asset: 'assets/branding/suggestion-grocery.svg',
                          onTap: () =>
                              onSuggestion('Je veux faire mes courses'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      entre(
                        6,
                        _HomePromptCard(
                          title: 'Explorer les boutiques',
                          asset: 'assets/branding/suggestion-shops.svg',
                          onTap: onBrowseShops,
                        ),
                      ),
                      const SizedBox(width: 10),
                      entre(
                        7,
                        _HomePromptCard(
                          title: 'Trouve-moi un bon repas à Niamey',
                          asset: 'assets/branding/suggestion-meal.svg',
                          onTap: () => onSuggestion(
                            'Je cherche un bon restaurant à Niamey',
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
      ),
    );
  }
}

class _HomeSectionTitle extends StatelessWidget {
  const _HomeSectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 26),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.6,
        color: Color(0xFF202020),
      ),
    ),
  );
}

/// « Otakoss · 2 × Tacos poulet, 1 × Bissap · 4 500 F » et un seul bouton.
///
/// Le contenu plutôt que la date : « commande du 20 septembre » ne rappelle
/// à personne ce qu'il a mangé. Le total affiché est celui d'alors ; le
/// panier, lui, reprend les prix du jour, et le serveur le dit.
class _LastOrderCard extends StatelessWidget {
  const _LastOrderCard({required this.order, required this.onReorder});
  final Map<String, dynamic> order;
  final VoidCallback onReorder;

  @override
  Widget build(BuildContext context) {
    final articles = ((order['articles'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((a) => '${a['quantite'] ?? 1} × ${a['nom'] ?? ''}')
        .join(', ');
    final boutique = order['merchant_name'] as String?;
    final total = (order['total'] as num?)?.toInt();
    return ConversationSurface(
      radius: 16,
      color: const Color(0xF0F8F8F9),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (boutique != null)
                    Text(
                      boutique,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                        color: Color(0xFF202020),
                      ),
                    ),
                  const SizedBox(height: 3),
                  Text(
                    articles,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      height: 1.25,
                      color: Color(0xFF6B6B6B),
                    ),
                  ),
                  if (total != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      Money.format(total),
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF202020),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: onReorder,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF202020),
                foregroundColor: Colors.white,
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                shape: const StadiumBorder(),
                textStyle: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: const Text('Recommander'),
            ),
          ],
        ),
      ),
    );
  }
}

class _HomePromptCard extends StatelessWidget {
  const _HomePromptCard({
    required this.title,
    required this.asset,
    required this.onTap,
    this.compact = false,
  });
  final String title;
  final String asset;
  final VoidCallback onTap;
  final bool compact;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: (MediaQuery.sizeOf(context).width * (compact ? 0.58 : 0.64)).clamp(
      218.0,
      300.0,
    ),
    child: ConversationSurface(
      radius: 16,
      color: const Color(0xF0F8F8F9),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(9),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: SvgPicture.asset(
                  asset,
                  width: compact ? 54 : 80,
                  height: compact ? 54 : 80,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  maxLines: compact ? 2 : 4,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF202020),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class ConversationComposer extends StatefulWidget {
  const ConversationComposer({
    super.key,
    required this.controller,
    required this.onSend,
    required this.onCamera,
    required this.onGallery,
    required this.onVoice,
    this.photoPath,
    required this.onRemovePhoto,
    this.ecrit = false,
    this.onEcrit,
  });
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onCamera;
  final VoidCallback onGallery;
  final VoidCallback onVoice;
  final String? photoPath;
  final VoidCallback onRemovePhoto;

  /// Le client converse par écrit : la box s'ouvre directement.
  ///
  /// Retenu par l'écran parent, parce que la box est détruite pendant chaque
  /// réponse (l'indicateur d'activité prend sa place) : sans cela, chaque
  /// message renvoyait au gros bouton micro, et il fallait rouvrir le clavier
  /// à chaque échange.
  final bool ecrit;
  final ValueChanged<bool>? onEcrit;

  @override
  State<ConversationComposer> createState() => _ConversationComposerState();
}

class _ConversationComposerState extends State<ConversationComposer> {
  final _focus = FocusNode();
  bool _typing = false;
  @override
  void initState() {
    super.initState();
    _typing =
        widget.ecrit ||
        widget.controller.text.isNotEmpty ||
        widget.photoPath != null;
  }

  void _changerMode(bool ecrit) {
    if (!ecrit) _focus.unfocus();
    if (mounted) setState(() => _typing = ecrit);
    widget.onEcrit?.call(ecrit);
  }

  @override
  void didUpdateWidget(ConversationComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.photoPath != null) _typing = true;
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Widget _resize(Widget child) => MediaQuery.disableAnimationsOf(context)
      ? child
      : AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.bottomCenter,
          child: child,
        );

  Widget _attachments() => PopupMenuButton<ImageSource>(
    tooltip: 'Ajouter une photo',
    color: Colors.white,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    onSelected: (source) =>
        source == ImageSource.camera ? widget.onCamera() : widget.onGallery(),
    itemBuilder: (_) => const [
      PopupMenuItem(
        value: ImageSource.gallery,
        child: ListTile(
          leading: Icon(Icons.photo_outlined),
          title: Text('Photos'),
        ),
      ),
      PopupMenuItem(
        value: ImageSource.camera,
        child: ListTile(
          leading: Icon(Icons.camera_alt_outlined),
          title: Text('Appareil photo'),
        ),
      ),
    ],
    child: const SizedBox.square(
      dimension: 44,
      child: Center(child: ConversationIcon(ConversationSymbol.plus)),
    ),
  );

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    minimum: const EdgeInsets.fromLTRB(18, 12, 18, 18),
    child: _resize(
      _typing
          ? TapRegion(
              // Toucher une carte ou faire défiler range le clavier, mais
              // garde la box : le client lit la réponse, puis continue
              // d'écrire sans rien rouvrir. On ne revient au micro que par
              // le bouton micro.
              onTapOutside: (_) => _focus.unfocus(),
              child: ConversationSurface(
                radius: 28,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.photoPath != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 6, 6, 8),
                          child: Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Image.file(
                                  File(widget.photoPath!),
                                  width: 52,
                                  height: 52,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, error, stack) =>
                                      const Icon(Icons.image_outlined),
                                ),
                              ),
                              const SizedBox(width: 12),
                              const Expanded(
                                child: Text(
                                  'Photo prête à envoyer',
                                  style: TextStyle(fontSize: 13),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Retirer la photo',
                                onPressed: widget.onRemovePhoto,
                                icon: const Icon(Icons.close_rounded),
                              ),
                            ],
                          ),
                        ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          _attachments(),
                          Expanded(
                            child: TextField(
                              controller: widget.controller,
                              focusNode: _focus,
                              minLines: 1,
                              maxLines: 5,
                              textCapitalization: TextCapitalization.sentences,
                              textInputAction: TextInputAction.newline,
                              // Le « tap à l'extérieur » est géré par la
                              // TapRegion qui entoure toute la box : attaché
                              // au seul champ, il repliait la box dès que le
                              // doigt touchait le bouton Envoyer — qui
                              // disparaissait avant d'avoir reçu le tap.
                              onTapOutside: (_) {},
                              decoration: const InputDecoration(
                                hintText: 'Demandez à Tovo…',
                                filled: false,
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 12,
                                ),
                              ),
                              style: const TextStyle(fontSize: 16, height: 1.3),
                            ),
                          ),
                          ValueListenableBuilder<TextEditingValue>(
                            valueListenable: widget.controller,
                            builder: (context, value, child) {
                              final hasDraft =
                                  value.text.trim().isNotEmpty ||
                                  widget.photoPath != null;
                              return IconButton(
                                tooltip: hasDraft ? 'Envoyer' : 'Parler à Tovo',
                                onPressed: hasDraft
                                    ? () {
                                        // La box reste ouverte ; le clavier
                                        // se range pour laisser lire la
                                        // réponse.
                                        _focus.unfocus();
                                        widget.onSend();
                                      }
                                    : () {
                                        _changerMode(false);
                                        widget.onVoice();
                                      },
                                style: IconButton.styleFrom(
                                  backgroundColor: hasDraft
                                      ? TovoTheme.teal
                                      : Colors.transparent,
                                  foregroundColor: hasDraft
                                      ? Colors.white
                                      : const Color(0xFF202020),
                                ),
                                icon: Icon(
                                  hasDraft
                                      ? Icons.arrow_upward_rounded
                                      : Icons.mic_none_rounded,
                                  size: 22,
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                ConversationSurface(child: _attachments()),
                ConversationSurface(
                  child: Padding(
                    padding: const EdgeInsets.all(3.5),
                    child: Material(
                      color: const Color(0xFF1B1921),
                      borderRadius: BorderRadius.circular(30),
                      child: InkWell(
                        onTap: widget.onVoice,
                        borderRadius: BorderRadius.circular(30),
                        child: const Tooltip(
                          message: 'Parler à Tovo',
                          child: SizedBox(
                            width: 86,
                            height: 43,
                            child: Center(
                              child: ConversationIcon(
                                ConversationSymbol.microphone,
                                color: Colors.white,
                                size: 23,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                ConversationControl(
                  symbol: ConversationSymbol.keyboard,
                  label: 'Écrire un message',
                  onPressed: () {
                    _changerMode(true);
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _focus.requestFocus();
                    });
                  },
                ),
              ],
            ),
    ),
  );
}
