import 'dart:async';

import 'package:flutter/material.dart';

class ViewportReveal extends StatefulWidget {
  const ViewportReveal({
    super.key,
    required this.child,
    this.enabled = true,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 120),
    this.offset = 12,
  });

  final Widget child;
  final bool enabled;
  final Duration delay;
  final Duration duration;
  final double offset;

  @override
  State<ViewportReveal> createState() => _ViewportRevealState();
}

class _ViewportRevealState extends State<ViewportReveal>
    with SingleTickerProviderStateMixin {
  static const _curve = Cubic(0.22, 1, 0.36, 1);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  ScrollPosition? _scrollPosition;
  ScrollableState? _scrollable;
  Timer? _delayTimer;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scrollable = Scrollable.maybeOf(context);
    final position = _scrollable?.position;
    if (position != _scrollPosition) {
      _scrollPosition?.removeListener(_checkVisibility);
      _scrollPosition = position;
      _scrollPosition?.addListener(_checkVisibility);
    }
    if (!widget.enabled || MediaQuery.disableAnimationsOf(context)) {
      _started = true;
      _delayTimer?.cancel();
      _controller.value = 1;
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkVisibility());
    }
  }

  @override
  void didUpdateWidget(ViewportReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && oldWidget.enabled) {
      _started = true;
      _delayTimer?.cancel();
      _controller.value = 1;
    }
  }

  void _checkVisibility() {
    if (!mounted || _started) return;
    final childBox = context.findRenderObject();
    final viewportBox = _scrollable?.context.findRenderObject();
    if (childBox is! RenderBox || !childBox.hasSize) return;
    if (viewportBox is RenderBox && viewportBox.hasSize) {
      final childTop = childBox.localToGlobal(Offset.zero);
      final viewportTop = viewportBox.localToGlobal(Offset.zero);
      final childRect = childTop & childBox.size;
      final viewportRect = viewportTop & viewportBox.size;
      if (!childRect.overlaps(viewportRect.inflate(24))) return;
    }
    _started = true;
    if (widget.delay == Duration.zero) {
      _controller.forward();
    } else {
      _delayTimer = Timer(widget.delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _scrollPosition?.removeListener(_checkVisibility);
    _delayTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, child) {
      final progress = _curve.transform(_controller.value);
      return Opacity(
        opacity: progress,
        child: Transform.translate(
          offset: Offset(0, widget.offset * (1 - progress)),
          child: child,
        ),
      );
    },
    child: widget.child,
  );
}
