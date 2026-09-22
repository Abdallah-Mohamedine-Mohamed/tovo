import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/theme.dart';

enum AssistantActivity { listening, transcribing, searching, answering }

const Color kAssistantListeningSurface = Color(0xFFEFF0F0);

class AssistantActivityDock extends StatelessWidget {
  const AssistantActivityDock({
    super.key,
    required this.activity,
    this.label,
    this.onPrimary,
    this.onCancel,
  });

  final AssistantActivity activity;
  final String? label;
  final VoidCallback? onPrimary;
  final VoidCallback? onCancel;

  String get _defaultLabel => switch (activity) {
    AssistantActivity.listening => 'Je vous écoute',
    AssistantActivity.transcribing => 'Transcription…',
    AssistantActivity.searching => 'Je cherche…',
    AssistantActivity.answering => 'La réponse arrive…',
  };

  @override
  Widget build(BuildContext context) {
    final listening = activity == AssistantActivity.listening;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: SizedBox(
        height: listening ? 108 : 64,
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: [
            if (listening) ...[
              const Positioned(top: 3, child: _ListeningLabel()),
              Positioned(bottom: 0, child: _ListeningControl(onTap: onPrimary)),
            ],
            if (!listening)
              Align(
                alignment: Alignment.bottomCenter,
                child: Material(
                  color: TovoTheme.teal,
                  elevation: 5,
                  shadowColor: const Color(0x33006666),
                  borderRadius: BorderRadius.circular(32),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(32),
                    onTap: onPrimary,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 18,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const _ActivityWave(),
                          const SizedBox(width: 10),
                          Text(
                            label ?? _defaultLabel,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (onCancel != null)
              Positioned(
                left: 0,
                bottom: listening ? 17 : 7,
                child: IconButton.filled(
                  tooltip: listening
                      ? 'Annuler le vocal'
                      : 'Annuler la transcription',
                  onPressed: onCancel,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.white.withValues(alpha: 0.78),
                    foregroundColor: TovoTheme.inkDoux,
                  ),
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ListeningLabel extends StatefulWidget {
  const _ListeningLabel();

  @override
  State<_ListeningLabel> createState() => _ListeningLabelState();
}

class _ListeningLabelState extends State<_ListeningLabel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _animation.stop();
    } else if (!_animation.isAnimating) {
      _animation.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      FadeTransition(
        opacity: Tween<double>(
          begin: 0.35,
          end: 1,
        ).animate(CurvedAnimation(parent: _animation, curve: Curves.easeInOut)),
        child: const DecoratedBox(
          decoration: BoxDecoration(
            color: TovoTheme.tealBright,
            shape: BoxShape.circle,
          ),
          child: SizedBox.square(dimension: 7),
        ),
      ),
      const SizedBox(width: 8),
      const Text(
        'Je vous écoute',
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: TovoTheme.tealDeep,
          letterSpacing: -0.1,
        ),
      ),
    ],
  );
}

class _ListeningControl extends StatefulWidget {
  const _ListeningControl({required this.onTap});

  final VoidCallback? onTap;

  @override
  State<_ListeningControl> createState() => _ListeningControlState();
}

class _ListeningControlState extends State<_ListeningControl>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1180),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _animation.value = 0.32;
      _animation.stop();
    } else if (!_animation.isAnimating) {
      _animation.repeat();
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Arrêter et transcrire',
    child: SizedBox.square(
      dimension: 84,
      child: AnimatedBuilder(
        animation: _animation,
        builder: (context, _) {
          final breath = 1 + 0.025 * sin(_animation.value * 2 * pi);
          return Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(
                size: const Size.square(84),
                painter: _VoiceAuraPainter(_animation.value),
              ),
              Transform.scale(
                scale: breath,
                child: Material(
                  color: TovoTheme.teal,
                  elevation: 7,
                  shadowColor: const Color(0x33003F40),
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: widget.onTap,
                    child: const SizedBox.square(
                      dimension: 58,
                      child: Icon(
                        Icons.mic_rounded,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

class _VoiceAuraPainter extends CustomPainter {
  const _VoiceAuraPainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final glow = Paint()
      ..color = TovoTheme.tealBright.withValues(
        alpha: 0.08 + 0.04 * sin(progress * 2 * pi).abs(),
      );
    canvas.drawCircle(center, 37, glow);

    final paint = Paint()
      ..color = TovoTheme.teal.withValues(alpha: 0.52)
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    const bars = 24;
    for (var index = 0; index < bars; index++) {
      final angle = index / bars * 2 * pi - pi / 2;
      final energy =
          (sin(progress * 2 * pi + index * 0.83) +
              0.55 * sin(progress * 4 * pi - index * 0.47) +
              1.55) /
          3.1;
      final innerRadius = 35.5;
      final outerRadius = innerRadius + 2.5 + energy * 5.5;
      canvas.drawLine(
        center + Offset(cos(angle), sin(angle)) * innerRadius,
        center + Offset(cos(angle), sin(angle)) * outerRadius,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _VoiceAuraPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class _ActivityWave extends StatefulWidget {
  const _ActivityWave();

  @override
  State<_ActivityWave> createState() => _ActivityWaveState();
}

class _ActivityWaveState extends State<_ActivityWave>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 950),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _animation.stop();
    } else if (!_animation.isAnimating) {
      _animation.repeat();
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _animation,
    builder: (_, __) => CustomPaint(
      size: const Size(20, 18),
      painter: _WavePainter(_animation.value),
    ),
  );
}

class _WavePainter extends CustomPainter {
  const _WavePainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    for (var index = 0; index < 3; index++) {
      final height = 5 + 8 * (sin(2 * pi * (progress + index / 3)) + 1) / 2;
      final centerX = 3 + index * 7.0;
      canvas.drawLine(
        Offset(centerX, (size.height - height) / 2),
        Offset(centerX, (size.height + height) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter oldDelegate) =>
      oldDelegate.progress != progress;
}
