import 'package:flutter/material.dart';

/// A transparent gesture-detection overlay for keyboard regions.
///
/// Wraps [child] without affecting its layout and fires callbacks when the
/// user performs a recognisable horizontal swipe:
///
/// | Gesture      | Callback       | Default use            |
/// |--------------|----------------|------------------------|
/// | Swipe left   | [onSwipeLeft]  | Delete previous word   |
/// | Swipe right  | [onSwipeRight] | Reserved / future use  |
///
/// The [swipeThreshold] is the minimum fling velocity in logical pixels per
/// second required to trigger a callback.  The default (300 px/s) works well
/// for most users; lower it for higher sensitivity, raise it to reduce
/// accidental triggers.
///
/// Typical usage – add delete-word on the space bar:
/// ```dart
/// GestureHandler(
///   onSwipeLeft: () => channel.deleteWord(),
///   child: SpacebarKeyWidget(onTap: _handleKeyTap, onSwipeLeft: () {}),
/// )
/// ```
class GestureHandler extends StatelessWidget {
  const GestureHandler({
    super.key,
    required this.child,
    this.onSwipeLeft,
    this.onSwipeRight,
    this.swipeThreshold = 300.0,
  });

  /// The widget to decorate with swipe detection.
  final Widget child;

  /// Called when the user swipes left with velocity ≥ [swipeThreshold].
  final VoidCallback? onSwipeLeft;

  /// Called when the user swipes right with velocity ≥ [swipeThreshold].
  final VoidCallback? onSwipeRight;

  /// Minimum fling velocity (px/s) needed to fire a swipe callback.
  final double swipeThreshold;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // translucent so the child's own GestureDetector still receives taps
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: _onHorizontalDragEnd,
      child: child,
    );
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0.0;
    if (velocity < -swipeThreshold) {
      onSwipeLeft?.call();
    } else if (velocity > swipeThreshold) {
      onSwipeRight?.call();
    }
  }
}
