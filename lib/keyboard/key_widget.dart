import 'package:flutter/material.dart';
import '../platform/keyboard_channel.dart';

/// A single key on the Smart Keyboard.
///
/// Design goals:
/// • Renders in < 1 ms (no layout calculation, pre-baked [BoxDecoration]).
/// • Plays a short scale animation on tap to give tactile-like feedback.
/// • Notifies the parent via [onTap] so that all [InputConnection] writes
///   happen in one place ([KeyboardWidget]).
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

  Future<void> _handleTap() async {
    await _controller.forward();
    await _controller.reverse();
    widget.onTap(widget.character);
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
              borderRadius: BorderRadius.circular(6),
              color: bg,
              child: SizedBox(
                height: 46,
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
  });

  final String label;
  final String character;
  final void Function(String) onTap;
  final int flex;
  final Color? backgroundColor;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    return KeyWidget(
      label: label,
      character: character,
      onTap: onTap,
      flex: flex,
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
    );
  }
}

/// The Backspace key — shows a delete icon instead of text.
class BackspaceKeyWidget extends StatefulWidget {
  const BackspaceKeyWidget({
    super.key,
    required this.onDelete,
  });

  final VoidCallback onDelete;

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

  Future<void> _handleTap() async {
    await _controller.forward();
    await _controller.reverse();
    widget.onDelete();
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
            borderRadius: BorderRadius.circular(6),
            color: theme.colorScheme.surfaceContainerHigh,
            child: const SizedBox(
              height: 46,
              child: Center(
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
  });

  final bool isActive;
  final VoidCallback onTap;

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
            borderRadius: BorderRadius.circular(6),
            color: isActive
                ? theme.colorScheme.primary
                : theme.colorScheme.surfaceContainerHigh,
            child: SizedBox(
              height: 46,
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
