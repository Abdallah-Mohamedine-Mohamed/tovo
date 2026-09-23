import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

class PhotoCaptureSheet extends StatefulWidget {
  const PhotoCaptureSheet({super.key});

  @override
  State<PhotoCaptureSheet> createState() => _PhotoCaptureSheetState();
}

class _PhotoCaptureSheetState extends State<PhotoCaptureSheet>
    with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = const [];
  int _generation = 0;
  bool _capturing = false;
  bool _openingGallery = false;
  CameraLensDirection _lens = CameraLensDirection.back;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_ouvrirCamera());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      _generation++;
      final controller = _controller;
      _controller = null;
      if (controller != null) unawaited(controller.dispose());
    } else if (state == AppLifecycleState.resumed && _controller == null) {
      unawaited(_ouvrirCamera(_lens));
    }
  }

  Future<void> _ouvrirCamera([
    CameraLensDirection lens = CameraLensDirection.back,
  ]) async {
    final generation = ++_generation;
    final previous = _controller;
    _controller = null;
    if (mounted) setState(() => _error = null);
    if (previous != null) await previous.dispose();

    CameraController? next;
    try {
      final cameras = _cameras.isEmpty ? await availableCameras() : _cameras;
      if (cameras.isEmpty) throw CameraException('noCamera', 'Aucune caméra');
      final camera = cameras.firstWhere(
        (item) => item.lensDirection == lens,
        orElse: () => cameras.first,
      );
      next = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await next.initialize();
      if (!mounted || generation != _generation) {
        await next.dispose();
        return;
      }
      setState(() {
        _cameras = cameras;
        _controller = next;
        _lens = camera.lensDirection;
      });
    } on CameraException catch (error) {
      if (next != null) await next.dispose();
      if (mounted && generation == _generation) {
        setState(() => _error = error.description ?? 'Caméra indisponible');
      }
    } on Exception {
      if (next != null) await next.dispose();
      if (mounted && generation == _generation) {
        setState(
          () => _error =
              'Impossible d’ouvrir la caméra. Vérifiez son autorisation.',
        );
      }
    }
  }

  Future<void> _prendrePhoto() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _capturing) {
      return;
    }
    unawaited(HapticFeedback.mediumImpact());
    setState(() => _capturing = true);
    try {
      final photo = await controller.takePicture();
      if (mounted) Navigator.of(context).pop(photo);
    } on CameraException {
      if (mounted) {
        setState(() {
          _capturing = false;
          _error = 'La photo n’a pas été prise. Réessayez.';
        });
      }
    }
  }

  Future<void> _ouvrirGalerie() async {
    if (_openingGallery) return;
    setState(() => _openingGallery = true);
    try {
      final photo = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        imageQuality: 75,
      );
      if (mounted && photo != null) Navigator.of(context).pop(photo);
    } on Exception {
      if (mounted) setState(() => _error = 'Impossible d’ouvrir les photos.');
    } finally {
      if (mounted) setState(() => _openingGallery = false);
    }
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    final controller = _controller;
    if (controller != null) unawaited(controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final controller = _controller;
    final ready = controller != null && controller.value.isInitialized;
    final hasFront = _cameras.any(
      (camera) => camera.lensDirection == CameraLensDirection.front,
    );
    final hasBack = _cameras.any(
      (camera) => camera.lensDirection == CameraLensDirection.back,
    );

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Container(
          height: size.height * 0.78,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 28,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(
                  color: const Color(0xFF191919),
                  child: ready
                      ? CameraPreview(controller)
                      : const SizedBox.expand(),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x66000000),
                        Colors.transparent,
                        Colors.transparent,
                        Color(0xB3000000),
                      ],
                      stops: [0, 0.22, 0.55, 1],
                    ),
                  ),
                ),
                if (!ready)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _error ?? 'Ouverture de la caméra…',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white),
                          ),
                          if (_error != null)
                            TextButton(
                              onPressed: () => unawaited(_ouvrirCamera(_lens)),
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.white,
                              ),
                              child: const Text('Réessayer'),
                            ),
                        ],
                      ),
                    ),
                  ),
                if (_capturing) const ColoredBox(color: Color(0x44FFFFFF)),
                Positioned(
                  top: 12,
                  left: 12,
                  child: IconButton(
                    tooltip: 'Fermer',
                    onPressed: () => Navigator.of(context).pop(),
                    style: IconButton.styleFrom(
                      backgroundColor: const Color(0x55000000),
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ),
                if (_error != null && ready)
                  Positioned(
                    top: 66,
                    left: 24,
                    right: 24,
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 104,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _mode(
                        'Objet',
                        selected: _lens == CameraLensDirection.back,
                        enabled: ready && hasBack && !_capturing,
                        onPressed: () {
                          if (_lens != CameraLensDirection.back) {
                            unawaited(_ouvrirCamera(CameraLensDirection.back));
                          }
                        },
                      ),
                      _mode(
                        'Selfie',
                        selected: _lens == CameraLensDirection.front,
                        enabled: ready && hasFront && !_capturing,
                        onPressed: () {
                          if (_lens != CameraLensDirection.front) {
                            unawaited(_ouvrirCamera(CameraLensDirection.front));
                          }
                        },
                      ),
                      _mode(
                        'Images',
                        enabled: !_capturing && !_openingGallery,
                        onPressed: _ouvrirGalerie,
                      ),
                    ],
                  ),
                ),
                Positioned(
                  bottom: 20,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Semantics(
                      label: 'Prendre une photo',
                      button: true,
                      enabled: ready && !_capturing,
                      child: GestureDetector(
                        onTap: ready && !_capturing ? _prendrePhoto : null,
                        child: Container(
                          width: 70,
                          height: 70,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: ready ? Colors.white : Colors.white54,
                              width: 3,
                            ),
                          ),
                          child: Container(
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: ready ? Colors.white : Colors.white54,
                            ),
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
      ),
    );
  }

  Widget _mode(
    String label, {
    bool selected = false,
    required bool enabled,
    required VoidCallback onPressed,
  }) => Expanded(
    child: TextButton(
      onPressed: enabled ? onPressed : null,
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white54,
        minimumSize: Size.zero,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 14,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          decoration: selected ? TextDecoration.underline : null,
          decorationColor: Colors.white,
        ),
      ),
    ),
  );
}

class PhotoScanOverlay extends StatefulWidget {
  const PhotoScanOverlay({super.key});

  @override
  State<PhotoScanOverlay> createState() => _PhotoScanOverlayState();
}

class _PhotoScanOverlayState extends State<PhotoScanOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _animation,
        builder: (context, _) => CustomPaint(
          painter: _PhotoScanPainter(_animation.value),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _PhotoScanPainter extends CustomPainter {
  const _PhotoScanPainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final horizontalInset = size.width * 0.12;
    final verticalInset = size.height * 0.12;
    final lineY = verticalInset + progress * (size.height - 2 * verticalInset);
    final line = Paint()
      ..color = const Color(0xCC91F1DC)
      ..strokeWidth = 2
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawLine(
      Offset(horizontalInset, lineY),
      Offset(size.width - horizontalInset, lineY),
      line,
    );

    final corners = Paint()
      ..color = const Color(0xD9FFFFFF)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const length = 20.0;
    for (final x in [horizontalInset, size.width - horizontalInset]) {
      for (final y in [verticalInset, size.height - verticalInset]) {
        final xDirection = x < size.width / 2 ? 1.0 : -1.0;
        final yDirection = y < size.height / 2 ? 1.0 : -1.0;
        final path = Path()
          ..moveTo(x, y + yDirection * length)
          ..lineTo(x, y)
          ..lineTo(x + xDirection * length, y);
        canvas.drawPath(path, corners);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PhotoScanPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
