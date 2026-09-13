import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

class CatalogImage extends StatelessWidget {
  const CatalogImage(
    this.url, {
    super.key,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.errorBuilder,
    this.decodeWidth = 600,
  });

  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final ImageErrorWidgetBuilder? errorBuilder;
  final int decodeWidth;

  @visibleForTesting
  static ImageProvider Function(String)? providerOverride;

  static ImageProvider provider(String url) =>
      providerOverride?.call(url) ?? CachedNetworkImageProvider(url);

  @override
  Widget build(BuildContext context) => Image(
    image: ResizeImage.resizeIfNeeded(decodeWidth, null, provider(url)),
    width: width,
    height: height,
    fit: fit,
    gaplessPlayback: true,
    errorBuilder: errorBuilder ?? (_, __, ___) => const SizedBox.shrink(),
    frameBuilder: (context, child, frame, synchronous) =>
        frame != null || synchronous
        ? child
        : SizedBox(
            width: width,
            height: height,
            child: const ColoredBox(color: Color(0xFFF3F3F1)),
          ),
  );
}
