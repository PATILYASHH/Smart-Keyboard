import 'dart:convert';

import 'package:flutter/services.dart';

/// An n-gram word-prediction engine for a mobile keyboard.
///
/// Supports **bigram** (one-word context) and **trigram** (two-word context)
/// predictions loaded from a local JSON asset.  When predicting, trigrams are
/// tried first; the engine falls back to bigrams when no trigram entry exists
/// for the given context.
///
/// Data format
/// -----------
/// The JSON model file has two top-level keys, `"bigrams"` and `"trigrams"`.
/// Each entry maps a context string to a frequency table:
///
/// ```json
/// {
///   "bigrams": {
///     "i":    { "am": 15, "will": 10, "can": 8 },
///     "will": { "go": 12, "come":  8, "send": 5 }
///   },
///   "trigrams": {
///     "i will": { "go": 7, "come": 5, "send": 3 },
///     "you can": { "do": 4, "go": 3, "see": 2 }
///   }
/// }
/// ```
///
/// Context keys are lower-cased.  For bigrams the context is the single
/// preceding word; for trigrams it is the two preceding words separated by a
/// single space.
///
/// Usage
/// -----
/// ```dart
/// // Production – load from bundled asset once on startup.
/// final predictor = await NgramPredictor.fromAsset();
///
/// // Testing – supply data directly.
/// final predictor = NgramPredictor.fromMap({
///   'bigrams':  {'will': {'go': 3, 'come': 2}},
///   'trigrams': {'i will': {'go': 5}},
/// });
///
/// final words = predictor.predict('I will');
/// // → ['go', 'come', ...]
/// ```
class NgramPredictor {
  /// Number of predictions returned by [predict].
  static const int maxPredictions = 3;

  NgramPredictor._(this._bigrams, this._trigrams);

  /// Bigram table: `context_word → {next_word: count}`.
  final Map<String, Map<String, int>> _bigrams;

  /// Trigram table: `"word1 word2" → {next_word: count}`.
  final Map<String, Map<String, int>> _trigrams;

  // ---------------------------------------------------------------------------
  // Factories
  // ---------------------------------------------------------------------------

  /// Creates an [NgramPredictor] by loading the model from a Flutter asset.
  ///
  /// [assetPath] defaults to `'assets/ngrams.json'`.  The file must follow the
  /// JSON schema described in the class documentation.
  static Future<NgramPredictor> fromAsset([
    String assetPath = 'assets/ngrams.json',
  ]) async {
    final content = await rootBundle.loadString(assetPath);
    final decoded = json.decode(content) as Map<String, dynamic>;
    return NgramPredictor.fromMap(decoded);
  }

  /// Creates an [NgramPredictor] from an in-memory map.
  ///
  /// Useful for unit tests or when the JSON has already been decoded.
  factory NgramPredictor.fromMap(Map<String, dynamic> data) {
    final bigrams = _parseTable(data['bigrams']);
    final trigrams = _parseTable(data['trigrams']);
    return NgramPredictor._(bigrams, trigrams);
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Returns up to [maxPredictions] predicted next words for [context].
  ///
  /// [context] is a string of one or more words (e.g. `"I will"`).
  /// The engine lower-cases the context before lookup.
  ///
  /// Strategy:
  /// 1. If the context has ≥ 2 words, look up the last two words in the
  ///    trigram table.
  /// 2. Fall back to looking up the last word in the bigram table.
  /// 3. If neither table has an entry, return an empty list.
  ///
  /// Candidates are ranked by **descending frequency** within the matching
  /// table; ties are broken lexicographically for deterministic output.
  List<String> predict(String context) {
    final words = _tokenise(context);
    if (words.isEmpty) return const [];

    // Try trigram first (requires ≥ 2 context words).
    if (words.length >= 2) {
      final key = '${words[words.length - 2]} ${words[words.length - 1]}';
      final result = _lookup(_trigrams, key);
      if (result.isNotEmpty) return result;
    }

    // Fall back to bigram.
    final result = _lookup(_bigrams, words.last);
    return result;
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Looks up [key] in [table] and returns the top-[maxPredictions] words
  /// sorted by descending count (ties broken lexicographically).
  List<String> _lookup(Map<String, Map<String, int>> table, String key) {
    final freq = table[key];
    if (freq == null || freq.isEmpty) return const [];

    final entries = freq.entries.toList()
      ..sort((a, b) {
        final cmp = b.value.compareTo(a.value); // descending count
        return cmp != 0 ? cmp : a.key.compareTo(b.key); // alphabetical tiebreak
      });

    return entries.take(maxPredictions).map((e) => e.key).toList();
  }

  /// Splits [text] into lower-cased word tokens, stripping punctuation.
  static List<String> _tokenise(String text) => text
      .toLowerCase()
      .split(RegExp(r'[^a-z]+'))
      .where((w) => w.isNotEmpty)
      .toList();

  /// Parses the raw JSON frequency table into typed Dart maps.
  ///
  /// Input shape (after JSON decode):
  /// ```
  /// { "context": { "word": count, ... }, ... }
  /// ```
  static Map<String, Map<String, int>> _parseTable(dynamic raw) {
    if (raw == null) return const {};
    final outer = raw as Map<String, dynamic>;
    return {
      for (final entry in outer.entries)
        entry.key.trim().toLowerCase(): {
          for (final inner in (entry.value as Map<String, dynamic>).entries)
            inner.key.trim().toLowerCase(): (inner.value as num).toInt(),
        },
    };
  }
}
