import 'dart:async';

import '../grammar/grammar_client.dart';
import '../prediction/ngram_predictor.dart';
import '../spell/spell_corrector.dart';

/// Called synchronously within [InputPipeline.process] whenever the local
/// suggestion list changes (stages 2–4 of the pipeline).
typedef SuggestionCallback = void Function(List<String> suggestions);

/// Called asynchronously after the AI grammar stage completes (stage 5).
typedef GrammarCorrectionCallback = void Function(String corrected);

/// Processes every user keystroke through a five-stage pipeline:
///
/// ```
/// User typing
///     ↓
/// Stage 1 – Input buffer        (sync)  track current word + sentence context
///     ↓
/// Stage 2 – Spell correction    (sync)  Levenshtein candidates for current word
///     ↓
/// Stage 3 – Word prediction     (sync)  n-gram next-word predictions
///     ↓
/// Stage 4 – Suggestion bar update (sync) merge & push via [onSuggestions]
///     ↓
/// Stage 5 – AI grammar improvement (async, optional)
///            fire-and-forget via [onGrammarCorrection]; stale results discarded
/// ```
///
/// Design goals
/// ------------
/// * **Non-blocking**: stages 1–4 are synchronous and complete in < 5 ms on
///   device, keeping suggestions in sync with every keystroke.
/// * **Instant suggestions**: [onSuggestions] is invoked synchronously inside
///   [process], so the [SuggestionBar] updates within the same UI frame.
/// * **Async AI**: grammar correction is launched as a fire-and-forget
///   [Future]; a monotonically-increasing token discards responses that were
///   superseded by newer keystrokes before the API replied.
///
/// Pseudocode
/// ----------
/// ```
/// process(character):
///   // Stage 1
///   buffer.update(character)
///
///   // Stage 2 – spell correction (sync, < 5 ms)
///   if currentWord.length >= 2 and spellCorrector != null:
///     spellSuggestions = spellCorrector.suggest(currentWord)
///   else:
///     spellSuggestions = []
///
///   // Stage 3 – word prediction (sync, < 2 ms)
///   if currentWord.isEmpty and ngramPredictor != null:
///     predictions = ngramPredictor.predict(context)
///   else:
///     predictions = []
///
///   // Stage 4 – merge and push instantly
///   suggestions = merge(spellSuggestions, predictions)
///   onSuggestions(suggestions)                  // synchronous callback
///
///   // Stage 5 – optional AI grammar (async, fire-and-forget)
///   if grammarClient != null and onGrammarCorrection != null:
///     token = nextToken()
///     grammarClient.correct(sentenceBuffer)
///       .then((result) { if currentToken == token: onGrammarCorrection(result) })
///       .catchError((_) {})                     // non-fatal
/// ```
///
/// Usage
/// -----
/// ```dart
/// final pipeline = InputPipeline(
///   spellCorrector: SpellCorrector.fromList(['hello', 'world']),
///   ngramPredictor: NgramPredictor.fromMap({
///     'bigrams': {'i': {'am': 5, 'will': 3}},
///     'trigrams': {},
///   }),
///   grammarClient: GrammarClient(apiUrl: ..., apiKey: '...'),
///   onSuggestions: (suggestions) => setState(() => _suggestions = suggestions),
///   onGrammarCorrection: (corrected) => setState(() => _corrected = corrected),
/// );
///
/// // On every key press:
/// pipeline.process(character);
///
/// // On backspace:
/// pipeline.deleteLastChar();
///
/// // On input field close:
/// pipeline.reset();
/// ```
class InputPipeline {
  /// Creates an [InputPipeline].
  ///
  /// Parameters
  /// ----------
  /// * [spellCorrector] – optional offline spell-correction engine (stage 2).
  /// * [ngramPredictor] – optional n-gram word predictor (stage 3).
  /// * [grammarClient]  – optional AI grammar client (stage 5).
  /// * [onSuggestions]  – **required** callback invoked synchronously in
  ///   [process] whenever local suggestions change (stages 2–4).
  /// * [onGrammarCorrection] – optional callback invoked asynchronously when
  ///   the AI grammar stage returns a result (stage 5).
  InputPipeline({
    SpellCorrector? spellCorrector,
    NgramPredictor? ngramPredictor,
    GrammarClient? grammarClient,
    required this.onSuggestions,
    this.onGrammarCorrection,
  })  : _spellCorrector = spellCorrector,
        _ngramPredictor = ngramPredictor,
        _grammarClient = grammarClient;

  final SpellCorrector? _spellCorrector;
  final NgramPredictor? _ngramPredictor;
  final GrammarClient? _grammarClient;

  // ---------------------------------------------------------------------------
  // Output callbacks
  // ---------------------------------------------------------------------------

  /// Called synchronously within [process] (and [deleteLastChar] / [reset])
  /// whenever the local suggestion list is updated (stages 2–4).
  final SuggestionCallback onSuggestions;

  /// Called asynchronously when the AI grammar correction stage returns a
  /// result (stage 5).  May be `null` if AI grammar is disabled.
  final GrammarCorrectionCallback? onGrammarCorrection;

  // ---------------------------------------------------------------------------
  // Internal buffer state
  // ---------------------------------------------------------------------------

  /// Characters accumulated since the last word boundary.
  final StringBuffer _wordBuffer = StringBuffer();

  /// The word before [_wordBuffer] (one-word context for bigrams).
  String _previousWord = '';

  /// The word before [_previousWord] (two-word context for trigrams).
  String _previousPreviousWord = '';

  /// Running sentence fragment fed to the AI grammar stage.
  final StringBuffer _sentenceBuffer = StringBuffer();

  /// Monotonically-increasing token for stale-response detection.
  ///
  /// Incremented every time a new AI request is dispatched (and on [reset]).
  /// When the AI [Future] resolves, its captured token is compared against
  /// [_aiToken]; if they differ the response is silently discarded.
  int _aiToken = 0;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Feeds [character] into the pipeline.
  ///
  /// Stages 1–4 run synchronously: [onSuggestions] is called before this
  /// method returns.  Stage 5 (AI grammar) is launched asynchronously if a
  /// [grammarClient] and [onGrammarCorrection] callback were provided.
  void process(String character) {
    // Stage 1: update input buffer.
    _updateBuffer(character);

    // Stages 2 & 3: spell correction + word prediction.
    // Stage 4: push suggestions instantly.
    onSuggestions(_computeLocalSuggestions());

    // Stage 5: fire optional AI grammar correction asynchronously.
    _triggerAiGrammar();
  }

  /// Handles a backspace: removes the last character from the word buffer and
  /// re-runs stages 2–4.
  ///
  /// The sentence buffer is also trimmed by one character if non-empty.
  void deleteLastChar() {
    final word = _wordBuffer.toString();
    if (word.isNotEmpty) {
      _wordBuffer.clear();
      _wordBuffer.write(word.substring(0, word.length - 1));
    }

    final sentence = _sentenceBuffer.toString();
    if (sentence.isNotEmpty) {
      _sentenceBuffer.clear();
      _sentenceBuffer.write(sentence.substring(0, sentence.length - 1));
    }

    onSuggestions(_computeLocalSuggestions());
  }

  /// Resets all internal state (e.g. when an input field is closed).
  ///
  /// Increments the AI token so any in-flight grammar request is discarded
  /// when it eventually resolves.  Calls [onSuggestions] with an empty list.
  void reset() {
    _wordBuffer.clear();
    _sentenceBuffer.clear();
    _previousWord = '';
    _previousPreviousWord = '';
    _aiToken++; // invalidate any in-flight AI request
    onSuggestions(const []);
  }

  // ---------------------------------------------------------------------------
  // Test-accessible state
  // ---------------------------------------------------------------------------

  /// The word fragment currently being typed (empty at word boundaries).
  String get currentWord => _wordBuffer.toString();

  /// The last fully-committed word (empty at session start).
  String get previousWord => _previousWord;

  /// The word before [previousWord] (empty at session start or after one word).
  String get previousPreviousWord => _previousPreviousWord;

  // ---------------------------------------------------------------------------
  // Stage 1: Input buffer
  // ---------------------------------------------------------------------------

  void _updateBuffer(String character) {
    _sentenceBuffer.write(character);

    final isWordChar = RegExp(r"[a-zA-Z']").hasMatch(character);
    if (!isWordChar) {
      // Word boundary: rotate context buffers and clear the word accumulator.
      final completed = _wordBuffer.toString();
      if (completed.isNotEmpty) {
        _previousPreviousWord = _previousWord;
        _previousWord = completed;
      }
      _wordBuffer.clear();
    } else {
      _wordBuffer.write(character.toLowerCase());
    }
  }

  // ---------------------------------------------------------------------------
  // Stages 2 & 3: Spell correction + word prediction
  // ---------------------------------------------------------------------------

  List<String> _computeLocalSuggestions() {
    final word = _wordBuffer.toString();

    // Stage 2: mid-word spell correction.
    if (word.length >= 2 && _spellCorrector != null) {
      return _spellCorrector!.suggest(word);
    }

    // Stage 3: between-word n-gram prediction.
    if (word.isEmpty && _ngramPredictor != null) {
      if (_previousPreviousWord.isNotEmpty && _previousWord.isNotEmpty) {
        final preds = _ngramPredictor!
            .predict('$_previousPreviousWord $_previousWord');
        if (preds.isNotEmpty) return preds;
      }
      if (_previousWord.isNotEmpty) {
        return _ngramPredictor!.predict(_previousWord);
      }
    }

    return const [];
  }

  // ---------------------------------------------------------------------------
  // Stage 5: Optional AI grammar improvement
  // ---------------------------------------------------------------------------

  void _triggerAiGrammar() {
    final client = _grammarClient;
    final callback = onGrammarCorrection;
    if (client == null || callback == null) return;

    final sentence = _sentenceBuffer.toString().trim();
    if (sentence.isEmpty) return;

    // Bump the token so any previous in-flight response is invalidated.
    final token = ++_aiToken;

    unawaited(
      client.correct(sentence).then((corrected) {
        // Only deliver the result if it has not been superseded.
        if (_aiToken == token) {
          callback(corrected);
        }
      }).catchError((_) {
        // AI errors are non-fatal; the suggestion bar retains its last value.
      }),
    );
  }
}
