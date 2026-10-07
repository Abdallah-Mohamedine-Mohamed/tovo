import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import 'avatar.dart';

/// Le choix du personnage qui représente le client sur la carte (étape 5,
/// 07/10). Les quatre, animés en train de marcher, vus de trois quarts ; un
/// toucher suffit. Le choix est gardé sur le téléphone, et la carte le
/// reprend à sa prochaine ouverture.
class ChoixAvatar extends StatefulWidget {
  const ChoixAvatar({super.key});

  @override
  State<ChoixAvatar> createState() => _ChoixAvatarState();
}

class _ChoixAvatarState extends State<ChoixAvatar> {
  String? _choisi;

  @override
  void initState() {
    super.initState();
    unawaited(
      ImagesAvatar.choisi().then((c) {
        if (mounted) setState(() => _choisi = c);
      }),
    );
  }

  Future<void> _choisir(String cle) async {
    setState(() => _choisi = cle);
    await ImagesAvatar.choisir(cle);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: const Text(
          'Mon avatar',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: TovoTheme.ink,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          const Text(
            'Il vous représente sur la carte : il attend, marche ou court selon '
            'votre vitesse, de jour comme de nuit.',
            style: TextStyle(
              fontSize: 14,
              height: 1.4,
              color: TovoTheme.inkDoux,
            ),
          ),
          const SizedBox(height: 16),
          GridView.count(
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.82,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (final e in ImagesAvatar.personnages.entries)
                _Carte(
                  cle: e.key,
                  nom: e.value,
                  choisi: _choisi == e.key,
                  onTap: () => _choisir(e.key),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Carte extends StatelessWidget {
  const _Carte({
    required this.cle,
    required this.nom,
    required this.choisi,
    required this.onTap,
  });

  final String cle;
  final String nom;
  final bool choisi;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: choisi,
    label: nom,
    child: Material(
      color: const Color(0xFFF4F5F3),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        // Le choisi : un trait foncé, sobre ; jamais de couleur vive.
        side: BorderSide(
          color: choisi ? TovoTheme.ink : Colors.transparent,
          width: 2,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            children: [
              Expanded(child: ApercuAvatar(cle: cle)),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (choisi) ...[
                    const Icon(
                      Icons.check_circle_rounded,
                      size: 16,
                      color: TovoTheme.ink,
                    ),
                    const SizedBox(width: 5),
                  ],
                  Text(
                    nom,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: TovoTheme.ink,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Un personnage animé (marche, vu de trois quarts), d'après les images de
/// la carte : téléchargées une fois, gardées sur le téléphone.
class ApercuAvatar extends StatefulWidget {
  const ApercuAvatar({
    super.key,
    required this.cle,
    this.animation = 'walk',
    this.images = 12,
    this.dureeS = 1.67,
  });

  final String cle;
  final String animation;
  final int images;
  final double dureeS;

  @override
  State<ApercuAvatar> createState() => _ApercuAvatarState();
}

class _ApercuAvatarState extends State<ApercuAvatar>
    with SingleTickerProviderStateMixin {
  ui.Image? _bande;
  late final AnimationController _temps = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: (widget.dureeS * 1000).round()),
  )..repeat();

  @override
  void initState() {
    super.initState();
    unawaited(_charger());
  }

  Future<void> _charger() async {
    // Inclinaison 30°, direction 135° : de trois quarts, vers la droite.
    final octets = await ImagesAvatar.octetsBande(
      widget.cle,
      '${widget.animation}_t30_135.webp',
    ).catchError((_) => null);
    if (octets == null || !mounted) return;
    final codec = await ui.instantiateImageCodec(octets);
    final image = (await codec.getNextFrame()).image;
    if (mounted) setState(() => _bande = image);
  }

  @override
  void dispose() {
    _temps.dispose();
    _bande?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bande = _bande;
    if (bande == null) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: TovoTheme.muted,
          ),
        ),
      );
    }
    return AnimatedBuilder(
      animation: _temps,
      builder: (context, _) => CustomPaint(
        painter: _Image(
          bande,
          (_temps.value * widget.images).floor() % widget.images,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _Image extends CustomPainter {
  _Image(this.bande, this.image);
  final ui.Image bande;
  final int image;

  @override
  void paint(Canvas canvas, Size size) {
    final cote = bande.height.toDouble();
    final n = (bande.width / cote).round();
    final source = Rect.fromLTWH((image % n) * cote, 0, cote, cote);
    final c = size.shortestSide;
    final dest = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: c,
      height: c,
    );
    canvas.drawImageRect(
      bande,
      source,
      dest,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_Image ancien) =>
      ancien.image != image || ancien.bande != bande;
}
