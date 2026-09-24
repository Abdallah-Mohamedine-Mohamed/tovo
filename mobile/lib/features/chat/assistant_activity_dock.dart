import 'dart:math';

import 'package:flutter/material.dart';

import 'conversation_chrome.dart';

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
      minimum: const EdgeInsets.fromLTRB(18, 12, 18, 18),
      child: _barre(listening),
    );
  }

  Widget _barre(bool listening) {
    return Row(
      children: [
        if (onCancel != null)
          ConversationControl(
            symbol: ConversationSymbol.close,
            label: listening ? 'Annuler le vocal' : 'Annuler la transcription',
            onPressed: onCancel,
          )
        else
          const SizedBox(width: 44),
        const SizedBox(width: 12),
        Expanded(
          child: Center(
            child: ConversationSurface(
              child: Padding(
                padding: const EdgeInsets.all(3.5),
                child: Material(
                  color: const Color(0xFF1B1921),
                  borderRadius: BorderRadius.circular(30),
                  child: Semantics(
                    button: onPrimary != null,
                    liveRegion: true,
                    child: Tooltip(
                      message: listening
                          ? 'Arrêter et transcrire'
                          : (label ?? _defaultLabel),
                      child: InkWell(
                        onTap: onPrimary,
                        borderRadius: BorderRadius.circular(30),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (listening)
                                const Icon(
                                  Icons.stop_circle_outlined,
                                  color: Colors.white,
                                  size: 22,
                                )
                              else
                                const _ActivityWave(),
                              const SizedBox(width: 10),
                              Flexible(
                                child: Text(
                                  label ?? _defaultLabel,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 56),
      ],
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
