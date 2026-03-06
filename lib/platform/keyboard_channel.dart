import 'dart:async';

import 'package:flutter/services.dart';
import '../dictionary/personal_dictionary.dart';
import '../grammar/grammar_client.dart';
import '../pipeline/input_pipeline.dart';
import '../prediction/ngram_predictor.dart';
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

  /// The n-gram predictor used to generate context-aware word predictions.
  ///
  /// Set via [setNgramPredictor] after loading the model from assets.
  /// When set, predictions are derived from the recent word context instead of
  /// (or in addition to) spell-correction suggestions.  Kotlin-side suggestions
  /// received via [_handleSuggestionsCall] always override local ones.
  NgramPredictor? _ngramPredictor;

  /// The personal dictionary used to:
  /// * suppress autocorrect for words the user has previously typed, and
  /// * surface those words as suggestions ranked by frequency.
  ///
  /// Set via [setPersonalDictionary].
  PersonalDictionary? _personalDictionary;

  /// The word currently being composed (updated on every [commitKey] call).
  String _currentWord = '';

  /// The last committed word (updated when a word boundary is reached).
  String _previousWord = '';

  /// The word committed before [_previousWord] (used for trigram context).
  String _previousPreviousWord = '';

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
    _rebuildPipeline();
  }

  // ---------------------------------------------------------------------------
  // N-gram predictor
  // ---------------------------------------------------------------------------

  /// Attaches an [NgramPredictor] to this channel.
  ///
  /// Once set, [commitKey] will provide context-aware word predictions based
  /// on the preceding word(s) whenever the user is between words (i.e. just
  /// after typing a space or completing a word).  When [_currentWord] is
  /// non-empty the spell corrector (if set) takes over.  Kotlin-side
  /// suggestions received via [_handleSuggestionsCall] always override local
  /// ones.
  void setNgramPredictor(NgramPredictor predictor) {
    _ngramPredictor = predictor;
    _rebuildPipeline();
  }

  // ---------------------------------------------------------------------------
  // Personal dictionary
  // ---------------------------------------------------------------------------

  /// Attaches a [PersonalDictionary] to this channel.
  ///
  /// Once set:
  /// * Every completed word (at a word boundary) is recorded via
  ///   [PersonalDictionary.saveWord] so that it is remembered for future
  ///   sessions.
  /// * [_pushLocalSuggestions] checks the dictionary first and suppresses
  ///   spell-correction candidates that are already known words (so the user's
  ///   intentional vocabulary is never "corrected away").
  /// * When mid-word, personal-dictionary suggestions that start with the
  ///   current prefix are prepended to any spell-correction suggestions.
  void setPersonalDictionary(PersonalDictionary dictionary) {
    _personalDictionary = dictionary;
  }

  // ---------------------------------------------------------------------------
  // Grammar client (AI stage)
  // ---------------------------------------------------------------------------

  /// The [GrammarClient] used for optional AI grammar improvement (stage 5 of
  /// the input pipeline).
  ///
  /// Set via [setGrammarClient] after the keyboard is initialised.
  /// When set, every [commitKey] call fires an asynchronous grammar-correction
  /// request via [InputPipeline].  Stale responses (superseded by newer input)
  /// are automatically discarded.  Registered [_grammarCorrectionListeners] are
  /// notified when a fresh correction arrives.
  GrammarClient? _grammarClient;

  /// [InputPipeline] instance rebuilt whenever a spell-corrector, n-gram
  /// predictor, or grammar client is attached.  `null` until at least one
  /// component is set.
  InputPipeline? _inputPipeline;

  final List<void Function(String)> _grammarCorrectionListeners = [];

  /// Attaches a [GrammarClient] for asynchronous AI grammar improvement.
  ///
  /// Each completed key press fires a fire-and-forget HTTP request to the
  /// configured LLM API.  Results are delivered via [addGrammarCorrectionListener]
  /// callbacks.  Stale responses (from earlier keystrokes) are discarded
  /// automatically.
  void setGrammarClient(GrammarClient client) {
    _grammarClient = client;
    _rebuildPipeline();
  }

  /// Registers a callback that is called asynchronously whenever the AI
  /// grammar stage returns a corrected sentence.
  void addGrammarCorrectionListener(void Function(String) listener) =>
      _grammarCorrectionListeners.add(listener);

  /// Removes a previously registered grammar correction listener.
  void removeGrammarCorrectionListener(void Function(String) listener) =>
      _grammarCorrectionListeners.remove(listener);

  /// Rebuilds [_inputPipeline] with the currently-attached components.
  ///
  /// Called whenever a new component is attached so the pipeline always
  /// reflects the latest configuration.
  ///
  /// Note: within [KeyboardChannel] the pipeline's [onSuggestions] callback is
  /// intentionally a no-op because local suggestions (including personal-
  /// dictionary hits) are already managed by [_computeAndApplySuggestions].
  /// The pipeline is used exclusively for its AI grammar stage (stage 5).
  void _rebuildPipeline() {
    _inputPipeline = InputPipeline(
      spellCorrector: _spellCorrector,
      ngramPredictor: _ngramPredictor,
      grammarClient: _grammarClient,
      // Local suggestions are handled by _computeAndApplySuggestions which
      // also integrates the personal dictionary.  The pipeline's onSuggestions
      // callback is unused here to avoid double-notification.
      onSuggestions: (_) {},
      onGrammarCorrection: (corrected) {
        for (final l in _grammarCorrectionListeners) {
          l(corrected);
        }
      },
    );
  }

  /// Returns the word currently being typed (empty between words).
  ///
  /// Exposed primarily for testing.
  String get currentWord => _currentWord;

  /// Returns the last fully committed word (empty at the start of a session).
  ///
  /// Exposed primarily for testing.
  String get previousWord => _previousWord;

  /// Returns the word committed before [previousWord] (empty at session start).
  ///
  /// Together with [previousWord] this forms the two-word context used for
  /// trigram lookups.  Exposed primarily for testing.
  String get previousPreviousWord => _previousPreviousWord;

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
    _inputPipeline?.deleteLastChar();
    return _keyInputChannel.invokeMethod<void>('deleteBackward');
  }

  /// Tells Kotlin to delete the entire word immediately before the cursor.
  ///
  /// The Kotlin side reads the text before the cursor, computes the previous
  /// word boundary, and calls [InputConnection.deleteSurroundingText] with the
  /// appropriate character count.
  Future<void> deleteWord() {
    _currentWord = '';
    _previousWord = '';
    _previousPreviousWord = '';
    _pushLocalSuggestions();
    return _keyInputChannel.invokeMethod<void>('deleteWord');
  }

  /// Commits the selected [word] suggestion (Kotlin will append a space).
  Future<void> commitSuggestion(String word) {
    _previousPreviousWord = _previousWord;
    _previousWord = word.toLowerCase();
    _currentWord = '';
    // Record the chosen word so it is remembered for future sessions.
    // Fire-and-forget: saving to disk must not block the UI thread.
    unawaited(_personalDictionary?.saveWord(word) ?? Future.value());
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
        _previousWord = '';
        _previousPreviousWord = '';
        _suggestions = const [];
        _inputPipeline?.reset();
        for (final l in _inputStateListeners) {
          l(null);
        }
        for (final l in _suggestionListeners) {
          l(const []);
        }
    }
  }

  // ---------------------------------------------------------------------------
  // Word buffer + local spell correction + n-gram prediction
  // ---------------------------------------------------------------------------

  /// Updates [_currentWord] and [_previousWord] based on [character], then
  /// pushes the best available offline suggestions.
  ///
  /// Called only when at least one of [_spellCorrector], [_ngramPredictor], or
  /// [_personalDictionary] is attached.
  void _updateWordBuffer(String character) {
    if (_spellCorrector == null &&
        _ngramPredictor == null &&
        _personalDictionary == null &&
        _grammarClient == null) return;

    if (character.isEmpty) return;

    // Space, newline, or punctuation → word boundary: rotate buffers.
    final isWordChar = RegExp(r"[a-zA-Z']").hasMatch(character);
    if (!isWordChar) {
      if (_currentWord.isNotEmpty) {
        _previousPreviousWord = _previousWord;
        _previousWord = _currentWord;
        // Persist the completed word to the personal dictionary.
        // Fire-and-forget: saving to disk must not block the UI thread.
        unawaited(_personalDictionary?.saveWord(_currentWord) ?? Future.value());
      }
      _currentWord = '';
    } else {
      _currentWord += character.toLowerCase();
    }
    _pushLocalSuggestions();

    // Delegate AI grammar improvement (stage 5) to the InputPipeline.
    // The pipeline runs asynchronously and notifies _grammarCorrectionListeners
    // when a fresh correction arrives; stale responses are discarded by the
    // pipeline's token mechanism.
    _inputPipeline?.process(character);
  }

  /// Computes offline suggestions and notifies [_suggestionListeners].
  ///
  /// Priority (mid-word, i.e. [_currentWord] has ≥ 2 characters):
  /// 1. **Personal-dictionary prefix matches** – words the user has previously
  ///    typed that start with the current prefix, ranked by frequency.
  /// 2. **Spell corrections** – candidates from [SpellCorrector] that are *not*
  ///    already in the personal dictionary (saved words are never autocorrected).
  ///
  /// Priority (between words, i.e. [_currentWord] is empty):
  /// 1. **N-gram prediction** – context-aware word predictions from
  ///    [NgramPredictor] based on the preceding word(s).
  ///
  /// Kotlin-side suggestions received via [_handleSuggestionsCall] always
  /// overwrite whatever is set here.
  void _pushLocalSuggestions() {
    // Personal-dictionary calls are async; schedule and return to avoid
    // blocking the UI.  When the future completes it will call
    // _applySuggestions which notifies listeners.
    _computeAndApplySuggestions();
  }

  Future<void> _computeAndApplySuggestions() async {
    List<String> newSuggestions = const [];

    final corrector = _spellCorrector;
    final predictor = _ngramPredictor;
    final dict = _personalDictionary;

    if (_currentWord.length >= 2) {
      // Mid-word: personal-dictionary prefix hits first, then spell correction
      // (excluding words already in the personal dictionary).
      final personalHits = dict != null
          ? await dict.getSuggestions(_currentWord)
          : <String>[];

      if (corrector != null) {
        final spellHits = corrector.suggest(_currentWord);
        // Batch-check which spell candidates are in the personal dictionary so
        // that a single SQL round-trip replaces N individual queries.
        final knownWords =
            dict != null ? await dict.containsAny(spellHits) : const <String>{};
        // Filter out candidates the user typed intentionally.
        final filtered =
            spellHits.where((w) => !knownWords.contains(w)).toList();

        // Merge using a Set for O(1) duplicate detection.
        final merged = <String>{...personalHits};
        merged.addAll(filtered);
        newSuggestions = merged.toList();
      } else {
        newSuggestions = personalHits;
      }
    } else if (_currentWord.isEmpty && predictor != null) {
      // Between words: offer n-gram predictions.
      // Pass the two most recent words so the predictor can try a trigram
      // lookup first and fall back to a bigram when no trigram entry exists.
      if (_previousPreviousWord.isNotEmpty && _previousWord.isNotEmpty) {
        newSuggestions =
            predictor.predict('$_previousPreviousWord $_previousWord');
      } else if (_previousWord.isNotEmpty) {
        newSuggestions = predictor.predict(_previousWord);
      }
    }

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
