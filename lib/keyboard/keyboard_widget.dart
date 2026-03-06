import 'package:flutter/material.dart';
import 'key_widget.dart';
import 'keyboard_layouts.dart';
import 'suggestion_bar.dart';
import '../platform/keyboard_channel.dart';

/// The root keyboard widget.
///
/// Renders the full QWERTY keyboard layout together with the suggestion bar.
/// All key taps are forwarded to [KeyboardChannel] which serialises them over
/// the platform channel to the Kotlin [SmartKeyboardService].
///
/// Layout layers (bottom → top):
/// ```
/// ┌──────────────────────────────────────────────────────┐
/// │  SuggestionBar  (44 dp)                              │
/// ├──────────────────────────────────────────────────────┤
/// │  Row 1 – Q W E R T Y U I O P                        │
/// │  Row 2 –  A S D F G H J K L                         │
/// │  Row 3 – ⇧  Z X C V B N M  ⌫                        │
/// │  Row 4 – ?123 · [    space    ] · . ↵               │
/// └──────────────────────────────────────────────────────┘
/// ```
///
/// Performance notes
/// -----------------
/// • Each [KeyWidget] uses `const` constructors where possible to avoid
///   unnecessary rebuilds.
/// • The only widgets that rebuild on state changes are [SuggestionBar]
///   (reacts to suggestion list) and the Shift key row (reacts to modifier
///   state).  All other keys are stateless.
class KeyboardWidget extends StatefulWidget {
  const KeyboardWidget({
    super.key,
    required this.channel,
    this.layout = KeyboardLayouts.qwerty,
  });

  final KeyboardChannel channel;

  /// The keyboard layout to use.  Defaults to [KeyboardLayouts.qwerty].
  final KeyboardLayout layout;

  @override
  State<KeyboardWidget> createState() => _KeyboardWidgetState();
}

class _KeyboardWidgetState extends State<KeyboardWidget> {
  bool _isShiftActive = false;
  bool _isCapsLockActive = false;
  bool _isSymbolMode = false;

  // ---------------------------------------------------------------------------
  // Key layout definitions – delegated to the active KeyboardLayout
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  bool get _isUpperCase => _isShiftActive || _isCapsLockActive;

  String _transform(String key) =>
      _isUpperCase ? key.toUpperCase() : key.toLowerCase();

  Set<KeyboardModifier> get _modifiers => {
        if (_isShiftActive) KeyboardModifier.shift,
        if (_isCapsLockActive) KeyboardModifier.capsLock,
        if (_isSymbolMode) KeyboardModifier.symbol,
      };

  // ---------------------------------------------------------------------------
  // Action handlers
  // ---------------------------------------------------------------------------

  void _handleKeyTap(String character) {
    widget.channel.commitKey(
      _isSymbolMode ? character : _transform(character),
      modifiers: _modifiers,
    );

    // Auto-deactivate one-shot shift after a letter key
    if (_isShiftActive && !_isCapsLockActive) {
      setState(() => _isShiftActive = false);
    }
  }

  void _handleShiftTap() {
    setState(() {
      if (_isCapsLockActive) {
        // Double-tap on caps → turn everything off
        _isCapsLockActive = false;
        _isShiftActive = false;
      } else if (_isShiftActive) {
        // Second tap → activate caps lock
        _isCapsLockActive = true;
      } else {
        // First tap → one-shot shift
        _isShiftActive = true;
      }
    });
    widget.channel.toggleModifier(
      _isCapsLockActive ? KeyboardModifier.capsLock : KeyboardModifier.shift,
    );
  }

  void _handleDelete() {
    widget.channel.deleteBackward();
  }

  void _handleSymbolToggle() {
    setState(() => _isSymbolMode = !_isSymbolMode);
    widget.channel.toggleModifier(KeyboardModifier.symbol);
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final row1 = _isSymbolMode ? widget.layout.row1Symbol : widget.layout.row1;
    final row2 = _isSymbolMode ? widget.layout.row2Symbol : widget.layout.row2;
    final row3 = _isSymbolMode ? widget.layout.row3Symbol : widget.layout.row3;

    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Suggestion bar
            SuggestionBar(channel: widget.channel),

            const SizedBox(height: 4),

            // Row 1
            _buildRow(row1),

            // Row 2
            _buildRow(row2, padded: true),

            // Row 3 – Shift + letters + Backspace
            _buildRow3(row3),

            // Row 4 – Symbol toggle / space / return
            _buildBottomRow(theme),

            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(List<String> keys, {bool padded = false}) {
    return Padding(
      padding: padded
          ? const EdgeInsets.symmetric(horizontal: 16.0)
          : EdgeInsets.zero,
      child: Row(
        children: keys
            .map(
              (k) => KeyWidget(
                key: ValueKey(k),
                label: _isSymbolMode ? k : (_isUpperCase ? k : k.toLowerCase()),
                character: k,
                onTap: _handleKeyTap,
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _buildRow3(List<String> keys) {
    return Row(
      children: [
        // Shift / Caps key
        ShiftKeyWidget(
          isActive: _isShiftActive || _isCapsLockActive,
          onTap: _handleShiftTap,
        ),

        // Letters or symbols
        ...keys.map(
          (k) => KeyWidget(
            key: ValueKey(k),
            label: _isSymbolMode ? k : (_isUpperCase ? k : k.toLowerCase()),
            character: k,
            onTap: _handleKeyTap,
          ),
        ),

        // Backspace
        BackspaceKeyWidget(onDelete: _handleDelete),
      ],
    );
  }

  Widget _buildBottomRow(ThemeData theme) {
    return Row(
      children: [
        // Symbol / ABC toggle
        KeyWidget(
          label: _isSymbolMode ? 'ABC' : '?123',
          character: '', // handled by onTap override
          onTap: (_) => _handleSymbolToggle(),
          flex: 2,
          isModifier: true,
          isActive: _isSymbolMode,
        ),

        // Comma / period
        KeyWidget(
          label: ',',
          character: ',',
          onTap: _handleKeyTap,
          flex: 1,
          isModifier: true,
        ),

        // Space bar
        WideKeyWidget(
          label: 'space',
          character: ' ',
          onTap: _handleKeyTap,
          flex: 5,
          backgroundColor: theme.colorScheme.surface,
        ),

        // Period
        KeyWidget(
          label: '.',
          character: '.',
          onTap: _handleKeyTap,
          flex: 1,
          isModifier: true,
        ),

        // Return / Enter
        KeyWidget(
          label: '↵',
          character: '\n',
          onTap: _handleKeyTap,
          flex: 2,
          isModifier: true,
          backgroundColor: theme.colorScheme.primaryContainer,
          foregroundColor: theme.colorScheme.onPrimaryContainer,
        ),
      ],
    );
  }
}
