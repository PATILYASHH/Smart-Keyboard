import 'dart:convert';

import 'package:http/http.dart' as http;

/// Exception thrown when the translation API returns a non-successful HTTP
/// status.
class TranslationApiException implements Exception {
  const TranslationApiException(this.statusCode, this.body);

  /// The HTTP status code returned by the API.
  final int statusCode;

  /// The raw response body from the API.
  final String body;

  @override
  String toString() =>
      'TranslationApiException(statusCode: $statusCode, body: $body)';
}

/// A Dart client that detects Hinglish text (mixed Hindi–English) and
/// translates it into natural English via an online LLM API.
///
/// Language detection
/// ------------------
/// [isHinglish] returns `true` when [text] contains either:
/// * Devanagari Unicode characters (U+0900–U+097F), or
/// * one or more words from a curated set of romanised Hindi markers
///   that are characteristic of Hinglish typing.
///
/// Translation
/// -----------
/// [translate] first calls [isHinglish]; if the text is not Hinglish the
/// original string is returned unchanged (no API round-trip).  Otherwise the
/// text is sent to the configured chat-completions endpoint with a prompt
/// that requests a natural English rewrite.
///
/// Features
/// --------
/// * **Async**: uses [Future]-based HTTP via `package:http`.
/// * **Timeout protection**: each request is wrapped with [Future.timeout];
///   the default is [defaultTimeout] but can be overridden per-call.
/// * **Retry on failure**: transient errors (network errors and 5xx responses)
///   are retried up to [maxRetries] times with exponential back-off.
///
/// Prompt format
/// -------------
/// ```
/// Translate the following Hinglish text to natural English.
/// Return only the translated sentence, nothing else:
/// {text}
/// ```
///
/// Usage
/// -----
/// ```dart
/// final translator = HinglishTranslator(
///   apiUrl: Uri.parse('https://api.openai.com/v1/chat/completions'),
///   apiKey: 'sk-...',
/// );
///
/// // Hinglish → English
/// final result = await translator.translate('bhai tu kidhar hai');
/// // → 'Bro, where are you?'
///
/// // Pure English is returned as-is (no API call made)
/// final passThrough = await translator.translate('hello world');
/// // → 'hello world'
///
/// translator.close();
/// ```
class HinglishTranslator {
  /// Default per-request timeout.
  static const Duration defaultTimeout = Duration(seconds: 15);

  /// Default maximum number of retry attempts on transient failures.
  static const int defaultMaxRetries = 3;

  /// Delay before the first retry.  Subsequent retries double this value.
  static const Duration _initialRetryDelay = Duration(milliseconds: 500);

  // Matches any character in the Devanagari Unicode block (U+0900–U+097F).
  static final RegExp _devanagariPattern = RegExp(r'[\u0900-\u097F]');

  /// Romanised Hindi words that are strong indicators of Hinglish content.
  ///
  /// The list covers common pronouns, verb forms, conjunctions, postpositions,
  /// and everyday vocabulary that native Hinglish typists routinely mix in.
  static const Set<String> _hinglishMarkers = {
    // Pronouns
    'main', 'mein', 'tu', 'tum', 'aap', 'hum', 'woh', 'yeh',
    // Common verb stems / forms
    'hai', 'hain', 'tha', 'thi', 'the', 'hoga', 'hogi', 'honge',
    'raha', 'rahi', 'rahe', 'aana', 'jana', 'karna', 'lena', 'dena',
    'aunga', 'aaunga', 'jaunga', 'karunga',
    'karo', 'karna', 'bol', 'bolo', 'sun', 'suno', 'dekh', 'dekho',
    // Question words
    'kya', 'kaise', 'kab', 'kahan', 'kidhar', 'kyun', 'kaun',
    // Quantifiers / adjectives
    'koi', 'kuch', 'thoda', 'bahut', 'zyada', 'kam', 'bilkul',
    'achha', 'theek', 'sahi', 'galat', 'jaldi', 'dhire',
    // Conjunctions / particles
    'aur', 'bhi', 'nahi', 'nahin', 'haan', 'naa', 'na', 'toh', 'to',
    'lekin', 'par', 'magar', 'kyunki', 'isliye',
    // Postpositions
    'ko', 'ka', 'ki', 'ke', 'se', 'pe', 'tak', 'liye', 'saath',
    'bin', 'bina', 'mein',
    // Time words
    'kal', 'aaj', 'abhi', 'parso', 'subah', 'shaam', 'raat',
    // Address / kinship terms
    'bhai', 'yaar', 'dost', 'bro',
    // Possessive pronouns
    'mera', 'meri', 'mere', 'tera', 'teri', 'tere',
    'apna', 'apni', 'apne', 'humara', 'tumhara',
    // Object pronouns
    'mujhe', 'tumhe', 'humko', 'unko', 'inko', 'usse', 'isko',
    // Common nouns often used in Hinglish
    'ghar', 'kaam', 'paisa', 'khana', 'pani', 'matlab',
    // Wala / wali suffix forms (standalone)
    'wala', 'wali', 'wale',
  };

  /// Constructs a [HinglishTranslator].
  ///
  /// Parameters
  /// ----------
  /// * [apiUrl] — full URL of the chat-completions endpoint.
  /// * [apiKey] — bearer token sent in the `Authorization` header.
  /// * [model] — LLM model identifier (default: `'gpt-4o-mini'`).
  /// * [maxRetries] — maximum retry attempts on transient failure
  ///   (default: [defaultMaxRetries]).
  /// * [timeout] — per-attempt timeout (default: [defaultTimeout]).
  /// * [httpClient] — optional injected HTTP client; useful for testing.
  HinglishTranslator({
    required Uri apiUrl,
    required String apiKey,
    String model = 'gpt-4o-mini',
    int maxRetries = defaultMaxRetries,
    Duration timeout = defaultTimeout,
    http.Client? httpClient,
  })  : _apiUrl = apiUrl,
        _apiKey = apiKey,
        _model = model,
        _maxRetries = maxRetries,
        _timeout = timeout,
        _httpClient = httpClient ?? http.Client();

  final Uri _apiUrl;
  final String _apiKey;
  final String _model;
  final int _maxRetries;
  final Duration _timeout;
  final http.Client _httpClient;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Returns `true` when [text] appears to contain Hinglish content.
  ///
  /// Detection is based on two independent signals:
  /// 1. The presence of any Devanagari Unicode character (U+0900–U+097F).
  /// 2. One or more space-separated tokens that match [_hinglishMarkers]
  ///    (case-insensitive).
  bool isHinglish(String text) {
    if (_devanagariPattern.hasMatch(text)) return true;
    final words = text.toLowerCase().split(RegExp(r'\s+'));
    return words.any(_hinglishMarkers.contains);
  }

  /// Translates [text] from Hinglish to natural English.
  ///
  /// If [isHinglish] returns `false` for [text] the original string is
  /// returned immediately without making an API call.
  ///
  /// Retries up to [_maxRetries] times on network errors or 5xx responses
  /// before propagating the failure.  Throws [TranslationApiException] when
  /// the API returns a non-retryable HTTP error, and [TimeoutException] when a
  /// request exceeds [_timeout].
  Future<String> translate(String text) async {
    if (!isHinglish(text)) return text;

    const instruction = 'Translate the following Hinglish text to natural '
        'English. Return only the translated sentence, nothing else:';
    final prompt = '$instruction\n$text';

    Exception? lastError;
    Duration delay = _initialRetryDelay;

    for (int attempt = 0; attempt <= _maxRetries; attempt++) {
      try {
        return await _sendRequest(prompt).timeout(_timeout);
      } on TranslationApiException catch (e) {
        // Only retry on server-side (5xx) errors.
        if (e.statusCode < 500) rethrow;
        lastError = e;
      } catch (e) {
        // Covers network / socket / timeout errors.
        lastError = e is Exception ? e : Exception(e.toString());
      }

      if (attempt < _maxRetries) {
        await Future<void>.delayed(delay);
        delay *= 2;
      }
    }

    throw lastError!;
  }

  /// Releases the underlying HTTP client.
  ///
  /// Call this when the [HinglishTranslator] is no longer needed to free
  /// sockets.
  void close() => _httpClient.close();

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  Future<String> _sendRequest(String prompt) async {
    final body = jsonEncode({
      'model': _model,
      'messages': [
        {'role': 'user', 'content': prompt},
      ],
    });

    final response = await _httpClient.post(
      _apiUrl,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_apiKey',
      },
      body: body,
    );

    if (response.statusCode != 200) {
      throw TranslationApiException(response.statusCode, response.body);
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = decoded['choices'] as List<dynamic>;
    final message = choices.first['message'] as Map<String, dynamic>;
    return (message['content'] as String).trim();
  }
}
