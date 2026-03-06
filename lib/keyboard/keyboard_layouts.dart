/// Keyboard layout definitions.
///
/// Each layout is a [KeyboardLayout] consisting of three letter rows and one
/// bottom row.  Adding a new layout (e.g. AZERTY, Dvorak) requires only adding
/// an entry here; [KeyboardWidget] consumes the active layout from
/// [KeyboardLayouts.current] without any per-layout widget changes.
library keyboard_layouts;

/// A single keyboard layout: three letter rows and one symbol row.
class KeyboardLayout {
  const KeyboardLayout({
    required this.name,
    required this.row1,
    required this.row2,
    required this.row3,
    required this.row1Symbol,
    required this.row2Symbol,
    required this.row3Symbol,
  });

  /// Human-readable name shown in layout picker.
  final String name;

  // Letter rows
  final List<String> row1;
  final List<String> row2;
  final List<String> row3;

  // Symbol rows (shown when ?123 is active)
  final List<String> row1Symbol;
  final List<String> row2Symbol;
  final List<String> row3Symbol;
}

/// Static catalogue of built-in keyboard layouts.
abstract final class KeyboardLayouts {
  /// Standard QWERTY layout.
  static const KeyboardLayout qwerty = KeyboardLayout(
    name: 'QWERTY',
    row1: ['Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P'],
    row2: ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L'],
    row3: ['Z', 'X', 'C', 'V', 'B', 'N', 'M'],
    row1Symbol: ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'],
    row2Symbol: ['-', '/', ':', ';', '(', ')', r'$', '&', '@'],
    row3Symbol: ['.', ',', '?', '!', "'", '"', '_'],
  );

  /// French AZERTY layout.
  static const KeyboardLayout azerty = KeyboardLayout(
    name: 'AZERTY',
    row1: ['A', 'Z', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P'],
    row2: ['Q', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', 'M'],
    row3: ['W', 'X', 'C', 'V', 'B', 'N'],
    row1Symbol: ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'],
    row2Symbol: ['-', '/', ':', ';', '(', ')', r'$', '&', '@', '#'],
    row3Symbol: ['.', ',', '?', '!', "'", '"'],
  );

  /// Dvorak simplified layout.
  static const KeyboardLayout dvorak = KeyboardLayout(
    name: 'Dvorak',
    row1: ["'", ',', '.', 'P', 'Y', 'F', 'G', 'C', 'R', 'L'],
    row2: ['A', 'O', 'E', 'U', 'I', 'D', 'H', 'T', 'N', 'S'],
    row3: [';', 'Q', 'J', 'K', 'X', 'B', 'M', 'W', 'V', 'Z'],
    row1Symbol: ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'],
    row2Symbol: ['-', '/', ':', ';', '(', ')', r'$', '&', '@'],
    row3Symbol: ['.', ',', '?', '!', "'", '"', '_'],
  );

  /// All available layouts in display order.
  static const List<KeyboardLayout> all = [qwerty, azerty, dvorak];
}
