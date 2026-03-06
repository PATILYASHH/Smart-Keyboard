import 'dart:convert';

import 'package:http/http.dart' as http;

/// Exception thrown when the LLM API returns a non-successful HTTP status.
class GrammarApiException implements Exception {
  const GrammarApiException(this.statusCode, this.body);

  /// The HTTP status code returned by the API.
  final int statusCode;

  /// The raw response body from the API.
  final String body;

  @override
  String toString() =>
      'GrammarApiException(statusCode: $statusCode, body: $body)';
}

/// A Dart client that sends a sentence to an LLM API and receives a
/// grammar-corrected version of that sentence.
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
/// Fix grammar and rewrite naturally:
/// {sentence}
/// ```
///
/// Usage
/// -----
/// ```dart
/// final client = GrammarClient(
///   apiUrl: Uri.parse('https://api.openai.com/v1/chat/completions'),
///   apiKey: 'sk-...',
/// );
///
/// final corrected = await client.correct('i want leave tommorow');
/// // → 'I want to take leave tomorrow.'
///
/// client.close();
/// ```
class GrammarClient {
  /// Default per-request timeout.
  static const Duration defaultTimeout = Duration(seconds: 15);

  /// Default maximum number of retry attempts on transient failures.
  static const int defaultMaxRetries = 3;

  /// Delay before the first retry.  Subsequent retries double this value.
  static const Duration _initialRetryDelay = Duration(milliseconds: 500);

  /// Constructs a [GrammarClient].
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
  GrammarClient({
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

  /// Sends [sentence] to the LLM API and returns the grammar-corrected text.
  ///
  /// Retries up to [_maxRetries] times on network errors or 5xx responses
  /// before propagating the failure.  Throws [GrammarApiException] when the
  /// API returns a non-retryable HTTP error, and [TimeoutException] when a
  /// request exceeds [_timeout].
  Future<String> correct(String sentence) async {
    final prompt = 'Fix grammar and rewrite naturally:\n$sentence';
    Exception? lastError;
    Duration delay = _initialRetryDelay;

    for (int attempt = 0; attempt <= _maxRetries; attempt++) {
      try {
        return await _sendRequest(prompt).timeout(_timeout);
      } on GrammarApiException catch (e) {
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
  /// Call this when the [GrammarClient] is no longer needed to free sockets.
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
      throw GrammarApiException(response.statusCode, response.body);
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = decoded['choices'] as List<dynamic>;
    final message = choices.first['message'] as Map<String, dynamic>;
    return (message['content'] as String).trim();
  }
}
