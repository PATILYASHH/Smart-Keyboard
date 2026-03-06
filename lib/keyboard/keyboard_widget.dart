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

  /// Whether the emoji panel placeholder is currently shown.
  bool _isEmojiMode = false;

  // ---------------------------------------------------------------------------
  // Key layout definitions – delegated to the active KeyboardLayout
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // Adaptive sizing
  // ---------------------------------------------------------------------------

  /// Computes the key height based on current screen dimensions.
  ///
  /// Uses ~6.5 % of screen height in portrait and ~11 % in landscape,
  /// clamped so keys never get unusably small or excessively large.
  double _keyHeight(BuildContext context) {
    final mq = MediaQuery.of(context);
    final factor =
        mq.orientation == Orientation.landscape ? 0.11 : 0.065;
    return (mq.size.height * factor).clamp(38.0, 54.0);
  }

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

  void _handleDeleteWord() {
    widget.channel.deleteWord();
  }

  void _handleSymbolToggle() {
    setState(() => _isSymbolMode = !_isSymbolMode);
    widget.channel.toggleModifier(KeyboardModifier.symbol);
  }

  void _handleEmojiToggle() {
    setState(() {
      _isEmojiMode = !_isEmojiMode;
      // Reset symbol mode when leaving emoji mode so that the regular
      // keyboard is always shown in its default (letter) state.
      if (!_isEmojiMode) _isSymbolMode = false;
    });
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Compute adaptive height once per frame; passed down to all key widgets.
    final keyHeight = _keyHeight(context);
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

            if (_isEmojiMode)
              // Emoji panel placeholder – shows common emoji categories.
              // Replace with a real emoji picker in a future iteration.
              _buildEmojiPanel(theme, keyHeight)
            else ...[
              // Row 1
              _buildRow(row1, keyHeight: keyHeight),

              // Row 2
              _buildRow(row2, padded: true, keyHeight: keyHeight),

              // Row 3 – Shift + letters + Backspace
              _buildRow3(row3, keyHeight: keyHeight),
            ],

            // Row 4 – Symbol toggle / emoji / space / period / return
            // Always visible so the user can exit emoji mode.
            _buildBottomRow(theme, keyHeight: keyHeight),

            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(List<String> keys,
      {bool padded = false, double keyHeight = 46.0}) {
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
                height: keyHeight,
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _buildRow3(List<String> keys, {double keyHeight = 46.0}) {
    return Row(
      children: [
        // Shift / Caps key
        ShiftKeyWidget(
          isActive: _isShiftActive || _isCapsLockActive,
          onTap: _handleShiftTap,
          height: keyHeight,
        ),

        // Letters or symbols
        ...keys.map(
          (k) => KeyWidget(
            key: ValueKey(k),
            label: _isSymbolMode ? k : (_isUpperCase ? k : k.toLowerCase()),
            character: k,
            onTap: _handleKeyTap,
            height: keyHeight,
          ),
        ),

        // Backspace
        BackspaceKeyWidget(onDelete: _handleDelete, height: keyHeight),
      ],
    );
  }

  Widget _buildBottomRow(ThemeData theme, {double keyHeight = 46.0}) {
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
          height: keyHeight,
        ),

        // Emoji toggle placeholder
        EmojiKeyWidget(
          isActive: _isEmojiMode,
          onTap: _handleEmojiToggle,
          height: keyHeight,
        ),

        // Space bar — swipe left triggers delete-word via SpacebarKeyWidget.
        SpacebarKeyWidget(
          onTap: _handleKeyTap,
          onSwipeLeft: _handleDeleteWord,
          flex: 4,
          backgroundColor: theme.colorScheme.surface,
          height: keyHeight,
        ),

        // Period
        KeyWidget(
          label: '.',
          character: '.',
          onTap: _handleKeyTap,
          flex: 1,
          isModifier: true,
          height: keyHeight,
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
          height: keyHeight,
        ),
      ],
    );
  }

  /// Emoji panel placeholder.
  ///
  /// Shows a 4-row grid of common emoji to demonstrate that emoji mode is
  /// active.  Replace the [_kEmojiRows] data with a full picker widget in a
  /// future iteration; the surrounding scaffold does not need to change.
  Widget _buildEmojiPanel(ThemeData theme, double keyHeight) {
    const emojiRows = [
      ['😀', '😂', '😍', '🥰', '😎', '🤔', '😢', '😡', '🥳', '🤩'],
      ['👍', '👎', '❤️', '🔥', '✨', '🎉', '💯', '👏', '🙏', '💪'],
      ['🌟', '🌈', '🍕', '🎮', '📱', '💻', '🎵', '🏆', '⚽', '🐶'],
      ['😴', '🤗', '😏', '🤑', '😇', '🤯', '🥶', '😬', '🫡', '🫶'],
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: emojiRows
          .map(
            (row) => Row(
              children: row
                  .map(
                    (emoji) => Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(3.0),
                        child: GestureDetector(
                          onTap: () => _handleKeyTap(emoji),
                          child: Material(
                            color: theme.colorScheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(6),
                            child: SizedBox(
                              height: keyHeight,
                              child: Center(
                                child: Text(
                                  emoji,
                                  style: const TextStyle(fontSize: 20),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          )
          .toList(),
    );
  }
}
