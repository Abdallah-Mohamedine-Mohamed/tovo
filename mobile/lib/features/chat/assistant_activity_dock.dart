import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/theme.dart';

enum AssistantActivity { listening, transcribing, searching, answering }

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
        height: listening ? 98 : 64,
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: [
            if (listening) ...[
              const Positioned(
                top: 0,
                child: Text(
                  'Je vous écoute',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: TovoTheme.tealDeep,
                  ),
                ),
              ),
              const Positioned(bottom: 0, child: _ListeningPulse()),
            ],
            Align(
              alignment: Alignment.bottomCenter,
              child: Tooltip(
                message: listening
                    ? 'Arrêter et transcrire'
                    : label ?? _defaultLabel,
                child: Material(
                  color: TovoTheme.teal,
                  elevation: 5,
                  shadowColor: const Color(0x33006666),
                  borderRadius: BorderRadius.circular(32),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(32),
                    onTap: onPrimary,
                    child: listening
                        ? const SizedBox.square(
                            dimension: 58,
                            child: Icon(
                              Icons.mic_rounded,
                              color: Colors.white,
                              size: 24,
                            ),
                          )
                        : Padding(
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
        size: const Size.square(74),
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
    for (var index = 0; index < 2; index++) {
      final phase = (progress + index / 2) % 1;
      final paint = Paint()
        ..color = TovoTheme.teal.withValues(alpha: (1 - phase) * 0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawCircle(size.center(Offset.zero), 30 + phase * 7, paint);
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
