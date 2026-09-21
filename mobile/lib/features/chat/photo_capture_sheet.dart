import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme.dart';

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
      unawaited(_ouvrirCamera());
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
    try {
      final photo = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        imageQuality: 75,
      );
      if (mounted && photo != null) Navigator.of(context).pop(photo);
    } on Exception {
      if (mounted) setState(() => _error = 'Impossible d’ouvrir les photos.');
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
    final hasFront = _cameras.any(
      (camera) => camera.lensDirection == CameraLensDirection.front,
    );
    final hasBack = _cameras.any(
      (camera) => camera.lensDirection == CameraLensDirection.back,
    );

    return Container(
      height: size.height * 0.62,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(
            children: [
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: TovoTheme.line,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Rechercher par photo',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Fermer',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(
                        color: TovoTheme.ink,
                        child:
                            controller == null ||
                                !controller.value.isInitialized
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(28),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        _error ?? 'Ouverture de la caméra…',
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ),
                                      ),
                                      if (_error != null)
                                        TextButton(
                                          onPressed: () =>
                                              unawaited(_ouvrirCamera()),
                                          child: const Text('Réessayer'),
                                        ),
                                    ],
                                  ),
                                ),
                              )
                            : CameraPreview(controller),
                      ),
                      if (controller != null && controller.value.isInitialized)
                        const PhotoScanOverlay(),
                      if (_capturing)
                        const ColoredBox(color: Color(0x66FFFFFF)),
                    ],
                  ),
                ),
              ),
              if (_error != null && controller != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: TovoTheme.danger),
                  ),
                ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  IconButton.filledTonal(
                    tooltip: 'Choisir une photo',
                    onPressed: _capturing ? null : _ouvrirGalerie,
                    icon: const Icon(Icons.photo_library_outlined),
                  ),
                  Semantics(
                    label: 'Prendre une photo',
                    button: true,
                    child: GestureDetector(
                      onTap: controller == null || _capturing
                          ? null
                          : _prendrePhoto,
                      child: Container(
                        width: 68,
                        height: 68,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: controller == null
                              ? TovoTheme.line
                              : TovoTheme.teal,
                          border: Border.all(color: Colors.white, width: 4),
                          boxShadow: TovoTheme.ombreFlottante,
                        ),
                        child: const Icon(
                          Icons.camera_alt_rounded,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Changer de caméra',
                    onPressed:
                        _capturing ||
                            !hasFront ||
                            !hasBack ||
                            controller == null
                        ? null
                        : () => unawaited(
                            _ouvrirCamera(
                              controller.description.lensDirection ==
                                      CameraLensDirection.back
                                  ? CameraLensDirection.front
                                  : CameraLensDirection.back,
                            ),
                          ),
                    icon: const Icon(Icons.cameraswitch_outlined),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'Cadrez l’objet. La photo rejoindra votre message.',
                style: TextStyle(fontSize: 12, color: TovoTheme.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
