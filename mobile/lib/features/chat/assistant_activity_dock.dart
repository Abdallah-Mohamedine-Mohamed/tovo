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
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : TovoTheme.normal;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: SizedBox(
        height: 64,
        child: Stack(
          alignment: Alignment.center,
          children: [
            UnconstrainedBox(
              child: Tooltip(
                message: activity == AssistantActivity.listening
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
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 15,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (activity == AssistantActivity.listening)
                            const Icon(
                              Icons.mic_rounded,
                              color: Colors.white,
                              size: 18,
                            )
                          else
                            const _ActivityWave(),
                          const SizedBox(width: 10),
                          AnimatedSwitcher(
                            duration: duration,
                            switchInCurve: TovoTheme.courbe,
                            child: Text(
                              label ?? _defaultLabel,
                              key: ValueKey('${activity.name}:${label ?? ''}'),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (activity == AssistantActivity.listening) ...[
                            const SizedBox(width: 10),
                            const Icon(
                              Icons.stop_circle_outlined,
                              color: Colors.white,
                              size: 20,
                            ),
                          ],
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
                child: IconButton.filledTonal(
                  tooltip: activity == AssistantActivity.listening
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
