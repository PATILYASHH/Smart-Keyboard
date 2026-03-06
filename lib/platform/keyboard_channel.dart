import 'package:flutter/services.dart';
import '../spell/spell_corrector.dart';

/// Modifier key flags tracked by the keyboard UI.
enum KeyboardModifier { shift, capsLock, alt, symbol }

/// Metadata about the currently focused input field, sent by Kotlin when
/// [SmartKeyboardService.onStartInput] is triggered.
class InputFieldInfo {
  const InputFieldInfo({
    required this.inputType,
    required this.fieldId,
    required this.packageName,
    required this.label,
    required this.hint,
  });

  final int inputType;
  final int fieldId;
  final String packageName;
  final String label;
  final String hint;

  factory InputFieldInfo.fromMap(Map<Object?, Object?> map) => InputFieldInfo(
        inputType: (map['inputType'] as int?) ?? 0,
        fieldId: (map['fieldId'] as int?) ?? 0,
        packageName: (map['packageName'] as String?) ?? '',
        label: (map['label'] as String?) ?? '',
        hint: (map['hint'] as String?) ?? '',
      );
}

/// Manages the three [MethodChannel]s used by the Smart Keyboard.
///
/// Channel layout
/// --------------
/// ```
/// com.smartkeyboard/keyInput    Flutter → Kotlin  (key presses)
/// com.smartkeyboard/suggestions Kotlin → Flutter  (word predictions)
/// com.smartkeyboard/inputState  Kotlin → Flutter  (field metadata)
/// ```
///
/// Listeners registered via [addSuggestionListener] / [addInputStateListener]
/// are notified synchronously when the Kotlin side invokes the corresponding
/// channel method.  Widgets should use [StatefulWidget] or [ValueListenableBuilder]
/// to rebuild efficiently.
class KeyboardChannel {
  // ---------------------------------------------------------------------------
  // Channels
  // ---------------------------------------------------------------------------

  static const _keyInputChannel =
      MethodChannel('com.smartkeyboard/keyInput');
  static const _suggestionsChannel =
      MethodChannel('com.smartkeyboard/suggestions');
  static const _inputStateChannel =
      MethodChannel('com.smartkeyboard/inputState');

  // ---------------------------------------------------------------------------
  // Observable state
  // ---------------------------------------------------------------------------

  List<String> _suggestions = const [];
  InputFieldInfo? _currentField;
  final Set<KeyboardModifier> _activeModifiers = {};

  /// The spell corrector used to generate offline suggestions.
  ///
  /// Set via [setSpellCorrector] after loading the dictionary from assets.
  /// When `null` the channel relies entirely on Kotlin-side suggestions.
  SpellCorrector? _spellCorrector;

  /// The word currently being composed (updated on every [commitKey] call).
  String _currentWord = '';

  List<String> get suggestions => List.unmodifiable(_suggestions);
  InputFieldInfo? get currentField => _currentField;
  Set<KeyboardModifier> get activeModifiers =>
      Set.unmodifiable(_activeModifiers);

  // ---------------------------------------------------------------------------
  // Spell corrector
  // ---------------------------------------------------------------------------

  /// Attaches an offline [SpellCorrector] to this channel.
  ///
  /// Once set, [commitKey] will update an internal word buffer and push local
  /// spell-correction suggestions whenever the user is mid-word.  Suggestions
  /// pushed by the Kotlin side (via [_handleSuggestionsCall]) always override
  /// local ones so that server-side prediction takes precedence when online.
  void setSpellCorrector(SpellCorrector corrector) {
    _spellCorrector = corrector;
  }

  /// Returns the word currently being typed (empty between words).
  ///
  /// Exposed primarily for testing.
  String get currentWord => _currentWord;

  // ---------------------------------------------------------------------------
  // Listeners
  // ---------------------------------------------------------------------------

  final List<void Function(List<String>)> _suggestionListeners = [];
  final List<void Function(InputFieldInfo?)> _inputStateListeners = [];
  final List<void Function(Set<KeyboardModifier>)> _modifierListeners = [];

  void addSuggestionListener(void Function(List<String>) listener) =>
      _suggestionListeners.add(listener);

  void removeSuggestionListener(void Function(List<String>) listener) =>
      _suggestionListeners.remove(listener);

  void addInputStateListener(void Function(InputFieldInfo?) listener) =>
      _inputStateListeners.add(listener);

  void removeInputStateListener(void Function(InputFieldInfo?) listener) =>
      _inputStateListeners.remove(listener);

  void addModifierListener(void Function(Set<KeyboardModifier>) listener) =>
      _modifierListeners.add(listener);

  void removeModifierListener(void Function(Set<KeyboardModifier>) listener) =>
      _modifierListeners.remove(listener);

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Register handlers for Kotlin → Flutter method calls.
  void initialize() {
    _suggestionsChannel.setMethodCallHandler(_handleSuggestionsCall);
    _inputStateChannel.setMethodCallHandler(_handleInputStateCall);
  }

  /// Unregister all handlers.
  void dispose() {
    _suggestionsChannel.setMethodCallHandler(null);
    _inputStateChannel.setMethodCallHandler(null);
  }

  // ---------------------------------------------------------------------------
  // Flutter → Kotlin API
  // ---------------------------------------------------------------------------

  /// Sends a key press to Kotlin and returns the acknowledgement payload.
  ///
  /// Returns a [Map] containing `character`, `isShift`, `isCaps`, `isAlt`, and
  /// `timestampMs` — matching the Kotlin [KeyboardEngine.buildKeyPressPayload].
  ///
  /// Side-effect: updates the internal word buffer and fires offline
  /// spell-correction suggestions via [_pushLocalSuggestions] when a
  /// [SpellCorrector] is attached.
  Future<Map<Object?, Object?>> commitKey(
    String character, {
    Set<KeyboardModifier> modifiers = const {},
  }) async {
    _updateWordBuffer(character);

    final result = await _keyInputChannel.invokeMethod<Map<Object?, Object?>>(
      'commitKey',
      {
        'character': character,
        'modifiers': modifiers.map(_modifierName).toList(),
      },
    );
    return result ?? const {};
  }

  /// Tells Kotlin to delete the character before the cursor and removes the
  /// last character from the internal word buffer.
  Future<void> deleteBackward() {
    if (_currentWord.isNotEmpty) {
      _currentWord = _currentWord.substring(0, _currentWord.length - 1);
      _pushLocalSuggestions();
    }
    return _keyInputChannel.invokeMethod<void>('deleteBackward');
  }

  /// Tells Kotlin to delete the entire word immediately before the cursor.
  ///
  /// The Kotlin side reads the text before the cursor, computes the previous
  /// word boundary, and calls [InputConnection.deleteSurroundingText] with the
  /// appropriate character count.
  Future<void> deleteWord() {
    _currentWord = '';
    _pushLocalSuggestions();
    return _keyInputChannel.invokeMethod<void>('deleteWord');
  }

  /// Commits the selected [word] suggestion (Kotlin will append a space).
  Future<void> commitSuggestion(String word) {
    _currentWord = '';
    _pushLocalSuggestions();
    return _keyInputChannel.invokeMethod<void>('commitSuggestion', {'word': word});
  }

  /// Sends a raw Android key code to Kotlin.
  Future<void> sendKeyCode(int keyCode) =>
      _keyInputChannel.invokeMethod<void>('sendKeyCode', {'keyCode': keyCode});

  // ---------------------------------------------------------------------------
  // Modifier helper
  // ---------------------------------------------------------------------------

  /// Toggles [modifier] and notifies modifier listeners.
  void toggleModifier(KeyboardModifier modifier) {
    if (_activeModifiers.contains(modifier)) {
      _activeModifiers.remove(modifier);
    } else {
      _activeModifiers.add(modifier);
    }
    for (final l in _modifierListeners) {
      l(activeModifiers);
    }
  }

  // ---------------------------------------------------------------------------
  // Kotlin → Flutter handlers
  // ---------------------------------------------------------------------------

  Future<void> _handleSuggestionsCall(MethodCall call) async {
    if (call.method == 'updateSuggestions') {
      final args = call.arguments as Map<Object?, Object?>?;
      final rawList = args?['suggestions'] as List<Object?>?;
      _suggestions = rawList?.map((e) => e.toString()).toList() ?? const [];
      for (final l in _suggestionListeners) {
        l(_suggestions);
      }
    }
  }

  Future<void> _handleInputStateCall(MethodCall call) async {
    switch (call.method) {
      case 'inputStarted':
        final args = call.arguments as Map<Object?, Object?>?;
        if (args != null) {
          _currentField = InputFieldInfo.fromMap(args);
          for (final l in _inputStateListeners) {
            l(_currentField);
          }
        }
      case 'inputFinished':
        _currentField = null;
        _currentWord = '';
        _suggestions = const [];
        for (final l in _inputStateListeners) {
          l(null);
        }
        for (final l in _suggestionListeners) {
          l(const []);
        }
    }
  }

  // ---------------------------------------------------------------------------
  // Word buffer + local spell correction
  // ---------------------------------------------------------------------------

  /// Updates [_currentWord] based on [character] and pushes offline
  /// suggestions when a [SpellCorrector] is attached.
  void _updateWordBuffer(String character) {
    if (_spellCorrector == null) return;

    if (character.isEmpty) return;

    // Space, newline, or punctuation → word boundary: reset buffer.
    final isWordChar = RegExp(r"[a-zA-Z']").hasMatch(character);
    if (!isWordChar) {
      _currentWord = '';
    } else {
      _currentWord += character.toLowerCase();
    }
    _pushLocalSuggestions();
  }

  /// Computes offline spell-correction suggestions for [_currentWord] and
  /// notifies [_suggestionListeners].
  ///
  /// Called only when [_spellCorrector] is set.  Kotlin-side suggestions
  /// received via [_handleSuggestionsCall] will overwrite these.
  void _pushLocalSuggestions() {
    final corrector = _spellCorrector;
    if (corrector == null) return;

    final word = _currentWord;
    final newSuggestions =
        word.length >= 2 ? corrector.suggest(word) : const <String>[];

    _suggestions = newSuggestions;
    for (final l in _suggestionListeners) {
      l(_suggestions);
    }
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  static String _modifierName(KeyboardModifier m) => switch (m) {
        KeyboardModifier.shift => 'shift',
        KeyboardModifier.capsLock => 'caps',
        KeyboardModifier.alt => 'alt',
        KeyboardModifier.symbol => 'symbol',
      };
}
