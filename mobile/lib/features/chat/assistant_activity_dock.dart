import 'dart:math';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../core/theme.dart';

enum AssistantActivity { listening, transcribing, searching, answering }

class AssistantActivityAtmosphere extends StatefulWidget {
  const AssistantActivityAtmosphere({super.key, required this.active});

  final bool active;

  @override
  State<AssistantActivityAtmosphere> createState() =>
      _AssistantActivityAtmosphereState();
}

class _AssistantActivityAtmosphereState
    extends State<AssistantActivityAtmosphere>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2300),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updatePulse();
  }

  @override
  void didUpdateWidget(AssistantActivityAtmosphere oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updatePulse();
  }

  void _updatePulse() {
    if (widget.active && !MediaQuery.disableAnimationsOf(context)) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _pulse.stop();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: AnimatedOpacity(
      opacity: widget.active ? 1 : 0,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 260),
      child: RepaintBoundary(
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Color(0x30434A54)),
            AnimatedBuilder(
              animation: _pulse,
              builder: (_, __) => ClipPath(
                clipper: _LiquidClipper(_pulse.value),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                  child: const ColoredBox(color: Color(0x2094AFB5)),
                ),
              ),
            ),
            AnimatedBuilder(
              animation: _pulse,
              builder: (_, __) =>
                  CustomPaint(painter: _AtmospherePainter(_pulse.value)),
            ),
          ],
        ),
      ),
    ),
  );
}

class _AtmospherePainter extends CustomPainter {
  const _AtmospherePainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(
      size.width * (0.5 + 0.035 * sin(progress * 2 * pi)),
      size.height * 0.9,
    );
    final radius = size.width * (0.72 + 0.05 * sin(progress * 2 * pi));
    final glow = Paint()
      ..shader = RadialGradient(
        colors: const [Color(0x299DC5C5), Color(0x1699A0C3), Color(0x0099A0C3)],
        stops: const [0, 0.55, 1],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, glow);

    canvas.drawPath(
      _liquidPath(size, progress),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const [Color(0x00FFFFFF), Color(0x2793B5B4)],
        ).createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(covariant _AtmospherePainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class _LiquidClipper extends CustomClipper<Path> {
  const _LiquidClipper(this.progress);

  final double progress;

  @override
  Path getClip(Size size) => _liquidPath(size, progress);

  @override
  bool shouldReclip(covariant _LiquidClipper oldClipper) =>
      oldClipper.progress != progress;
}

Path _liquidPath(Size size, double progress) {
  if (size.width <= 0 || size.height <= 0) return Path();
  final waveTop = size.height * 0.78;
  final amplitude = min(15.0, size.height * 0.025);
  final wave = Path()..moveTo(0, size.height);
  for (var position = 0.0; position <= size.width + 8; position += 8) {
    final phase = position / size.width * 2 * pi;
    final height =
        waveTop +
        amplitude * sin(phase + progress * 2 * pi) +
        amplitude * 0.4 * sin(phase * 2 - progress * 2 * pi);
    wave.lineTo(position, height);
  }
  return wave
    ..lineTo(size.width, size.height)
    ..close();
}

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
        height: 68,
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: [
            if (listening)
              const Positioned(bottom: 0, child: _ListeningPulse()),
            Align(
              alignment: Alignment.bottomCenter,
              child: Tooltip(
                message: listening
                    ? 'Arrêter et transcrire'
                    : label ?? _defaultLabel,
                child: Material(
                  color: TovoTheme.ink,
                  elevation: 9,
                  shadowColor: const Color(0x550E2525),
                  borderRadius: BorderRadius.circular(32),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(32),
                    onTap: onPrimary,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 15,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (listening)
                            const Icon(
                              Icons.mic_rounded,
                              color: Colors.white,
                              size: 19,
                            )
                          else
                            const _ActivityWave(),
                          const SizedBox(width: 10),
                          Text(
                            label ?? _defaultLabel,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (onCancel != null)
              Positioned(
                left: 0,
                bottom: 7,
                child: IconButton.filledTonal(
                  tooltip: listening
                      ? 'Annuler le vocal'
                      : 'Annuler la transcription',
                  onPressed: onCancel,
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ListeningPulse extends StatefulWidget {
  const _ListeningPulse();

  @override
  State<_ListeningPulse> createState() => _ListeningPulseState();
}

class _ListeningPulseState extends State<_ListeningPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
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
  Widget build(BuildContext context) => IgnorePointer(
    child: AnimatedBuilder(
      animation: _animation,
      builder: (_, __) => CustomPaint(
        size: const Size(220, 68),
        painter: _PulsePainter(_animation.value),
      ),
    ),
  );
}

class _PulsePainter extends CustomPainter {
  const _PulsePainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    for (var index = 0; index < 3; index++) {
      final phase = (progress + index / 3) % 1;
      final spread = 3 + phase * 16;
      final rect = Rect.fromCenter(
        center: size.center(Offset.zero),
        width: 137 + spread * 2,
        height: 43 + spread,
      );
      final path = Path();
      for (var step = 0; step <= 48; step++) {
        final angle = step / 48 * 2 * pi;
        final ripple = 1 + 0.035 * sin(angle * 3 + progress * 2 * pi);
        final point = Offset(
          rect.center.dx + rect.width / 2 * cos(angle) * ripple,
          rect.center.dy + rect.height / 2 * sin(angle) * ripple,
        );
        if (step == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      path.close();
      canvas.drawPath(
        path,
        Paint()
          ..color = TovoTheme.teal.withValues(alpha: (1 - phase) * 0.16)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PulsePainter oldDelegate) =>
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
