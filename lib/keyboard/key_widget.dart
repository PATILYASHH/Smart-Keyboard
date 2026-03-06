import 'package:flutter/material.dart';
import '../platform/keyboard_channel.dart';
import 'gesture_handler.dart';

/// A single key on the Smart Keyboard.
///
/// Design goals:
/// • Renders in < 1 ms (no layout calculation, pre-baked [BoxDecoration]).
/// • Plays a short scale animation on tap to give tactile-like feedback.
/// • Fires [onTap] **immediately** at the start of the press animation so the
///   input pipeline sees the keystroke with minimal latency (no waiting for the
///   animation to complete).
class KeyWidget extends StatefulWidget {
  const KeyWidget({
    super.key,
    required this.label,
    required this.character,
    required this.onTap,
    this.flex = 1,
    this.isModifier = false,
    this.isActive = false,
    this.backgroundColor,
    this.foregroundColor,
    this.height = 46.0,
  });

  /// The text displayed on the key face.
  final String label;

  /// The character (or control string) sent to the channel on tap.
  final String character;

  /// Called when the key is tapped.
  final void Function(String character) onTap;

  /// Flex factor in the [Row] that contains this key.
  final int flex;

  /// Whether this is a modifier key (Shift, Caps, Alt, …).
  final bool isModifier;

  /// Whether this modifier key is currently active.
  final bool isActive;

  final Color? backgroundColor;
  final Color? foregroundColor;

  /// Key face height in logical pixels.  Defaults to 46; override for
  /// adaptive sizing based on screen dimensions.
  final double height;

  @override
  State<KeyWidget> createState() => _KeyWidgetState();
}

class _KeyWidgetState extends State<KeyWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 80),
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.88).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Fires [onTap] immediately for minimal latency, then runs the press
  /// animation in the background so the UI still shows tactile feedback.
  void _handleTap() {
    widget.onTap(widget.character);
    _controller.forward().then((_) => _controller.reverse());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final bg = widget.isActive
        ? theme.colorScheme.primary
        : (widget.isModifier
            ? theme.colorScheme.surfaceContainerHigh
            : widget.backgroundColor ?? theme.colorScheme.surface);

    final fg = widget.isActive
        ? theme.colorScheme.onPrimary
        : (widget.foregroundColor ?? theme.colorScheme.onSurface);

    return Expanded(
      flex: widget.flex,
      child: Padding(
        padding: const EdgeInsets.all(3.0),
        child: GestureDetector(
          onTap: _handleTap,
          child: ScaleTransition(
            scale: _scaleAnimation,
            child: Material(
              elevation: widget.isModifier ? 0 : 1,
              borderRadius: BorderRadius.circular(8),
              color: bg,
              shadowColor: theme.colorScheme.shadow.withAlpha(80),
              child: SizedBox(
                height: widget.height,
                child: Center(
                  child: Text(
                    widget.label,
                    style: TextStyle(
                      color: fg,
                      fontSize: widget.isModifier ? 13 : 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A special wide key (e.g. Space, Return) with a [flex] > 1.
class WideKeyWidget extends StatelessWidget {
  const WideKeyWidget({
    super.key,
    required this.label,
    required this.character,
    required this.onTap,
    this.flex = 4,
    this.backgroundColor,
    this.foregroundColor,
    this.height = 46.0,
  });

  final String label;
  final String character;
  final void Function(String) onTap;
  final int flex;
  final Color? backgroundColor;
  final Color? foregroundColor;

  /// Key face height in logical pixels.
  final double height;

  @override
  Widget build(BuildContext context) {
    return KeyWidget(
      label: label,
      character: character,
      onTap: onTap,
      flex: flex,
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      height: height,
    );
  }
}

/// The Backspace key — shows a delete icon instead of text.
class BackspaceKeyWidget extends StatefulWidget {
  const BackspaceKeyWidget({
    super.key,
    required this.onDelete,
    this.height = 46.0,
  });

  final VoidCallback onDelete;

  /// Key face height in logical pixels.
  final double height;

  @override
  State<BackspaceKeyWidget> createState() => _BackspaceKeyWidgetState();
}

class _BackspaceKeyWidgetState extends State<BackspaceKeyWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 80),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Fires the delete callback immediately and animates in the background.
  void _handleTap() {
    widget.onDelete();
    _controller.forward().then((_) => _controller.reverse());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      flex: 2,
      child: Padding(
        padding: const EdgeInsets.all(3.0),
        child: GestureDetector(
          onTap: _handleTap,
          child: Material(
            elevation: 0,
            borderRadius: BorderRadius.circular(8),
            color: theme.colorScheme.surfaceContainerHigh,
            child: SizedBox(
              height: widget.height,
              child: const Center(
                child: Icon(Icons.backspace_outlined, size: 20),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A Shift key that reflects [isActive] and reports taps.
class ShiftKeyWidget extends StatelessWidget {
  const ShiftKeyWidget({
    super.key,
    required this.isActive,
    required this.onTap,
    this.height = 46.0,
  });

  final bool isActive;
  final VoidCallback onTap;

  /// Key face height in logical pixels.
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      flex: 2,
      child: Padding(
        padding: const EdgeInsets.all(3.0),
        child: GestureDetector(
          onTap: onTap,
          child: Material(
            elevation: 0,
            borderRadius: BorderRadius.circular(8),
            color: isActive
                ? theme.colorScheme.primary
                : theme.colorScheme.surfaceContainerHigh,
            child: SizedBox(
              height: height,
              child: Center(
                child: Icon(
                  isActive ? Icons.arrow_upward : Icons.arrow_upward_outlined,
                  size: 20,
                  color: isActive
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.onSurface,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Emoji toggle key — shows 😊 when inactive and 🎨 when active.
///
/// This is a **placeholder**: tapping it toggles [isActive].  A full emoji
/// picker panel can be wired up behind the [onTap] callback in a future
/// iteration without changing this widget's API.
class EmojiKeyWidget extends StatelessWidget {
  const EmojiKeyWidget({
    super.key,
    required this.isActive,
    required this.onTap,
    this.height = 46.0,
  });

  /// Whether emoji mode is currently active.
  final bool isActive;

  /// Called when the key is tapped to toggle emoji mode.
  final VoidCallback onTap;

  /// Key face height in logical pixels.
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(3.0),
        child: GestureDetector(
          onTap: onTap,
          child: Material(
            elevation: 0,
            borderRadius: BorderRadius.circular(8),
            color: isActive
                ? theme.colorScheme.primary
                : theme.colorScheme.surfaceContainerHigh,
            child: SizedBox(
              height: height,
              child: Center(
                child: Text(
                  isActive ? '🎨' : '😊',
                  style: const TextStyle(fontSize: 20),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Spacebar key that commits a space character on tap **and** triggers
/// [onSwipeLeft] when the user swipes left across it (delete previous word).
///
/// The swipe gesture is handled by an embedded [GestureHandler] so the logic
/// remains encapsulated here and [keyboard_widget.dart] only calls
/// [_handleDeleteWord].
class SpacebarKeyWidget extends StatefulWidget {
  const SpacebarKeyWidget({
    super.key,
    required this.onTap,
    required this.onSwipeLeft,
    this.flex = 5,
    this.backgroundColor,
    this.height = 46.0,
  });

  /// Called with `' '` when the user taps the spacebar.
  final void Function(String) onTap;

  /// Called when the user swipes left (≥ 300 px/s) across the spacebar.
  /// Typically wired to [KeyboardChannel.deleteWord].
  final VoidCallback onSwipeLeft;

  /// Flex factor in the enclosing [Row].
  final int flex;

  /// Background colour override (defaults to [ColorScheme.surface]).
  final Color? backgroundColor;

  /// Key face height in logical pixels.
  final double height;

  @override
  State<SpacebarKeyWidget> createState() => _SpacebarKeyWidgetState();
}

class _SpacebarKeyWidgetState extends State<SpacebarKeyWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 80),
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.88).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Fires [onTap] immediately for minimal latency, then animates in the
  /// background.
  void _handleTap() {
    widget.onTap(' ');
    _controller.forward().then((_) => _controller.reverse());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = widget.backgroundColor ?? theme.colorScheme.surface;

    return Expanded(
      flex: widget.flex,
      child: Padding(
        padding: const EdgeInsets.all(3.0),
        // GestureHandler intercepts horizontal swipes; taps pass through to
        // the inner GestureDetector thanks to HitTestBehavior.translucent.
        child: GestureHandler(
          onSwipeLeft: widget.onSwipeLeft,
          child: GestureDetector(
            onTap: _handleTap,
            child: ScaleTransition(
              scale: _scaleAnimation,
              child: Material(
                elevation: 1,
                borderRadius: BorderRadius.circular(8),
                color: bg,
                shadowColor: theme.colorScheme.shadow.withAlpha(80),
                child: SizedBox(
                  height: widget.height,
                  child: Center(
                    child: Text(
                      'space',
                      style: TextStyle(
                        color: theme.colorScheme.onSurface,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
