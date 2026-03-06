import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smart_keyboard/grammar/grammar_client.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Builds a well-formed OpenAI-compatible chat-completions response body.
String _successBody(String content) => jsonEncode({
      'choices': [
        {
          'message': {'role': 'assistant', 'content': content},
        }
      ],
    });

/// Creates a [GrammarClient] backed by a [MockClient] that always returns
/// [statusCode] with [body].
GrammarClient _clientWith({
  required int statusCode,
  required String body,
  int maxRetries = 0,
  Duration timeout = const Duration(seconds: 5),
}) =>
    GrammarClient(
      apiUrl: Uri.parse('https://api.example.com/v1/chat/completions'),
      apiKey: 'test-key',
      maxRetries: maxRetries,
      timeout: timeout,
      httpClient: MockClient(
        (_) async => http.Response(body, statusCode),
      ),
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  // Successful correction
  // -------------------------------------------------------------------------

  group('GrammarClient.correct – success', () {
    test('returns corrected sentence from API response', () async {
      const corrected = 'I want to take leave tomorrow.';
      final client = _clientWith(
        statusCode: 200,
        body: _successBody(corrected),
      );

      final result = await client.correct('i want leave tommorow');

      expect(result, equals(corrected));
      client.close();
    });

    test('strips surrounding whitespace from the corrected text', () async {
      final client = _clientWith(
        statusCode: 200,
        body: _successBody('  Hello, world!  '),
      );

      final result = await client.correct('hello world');

      expect(result, equals('Hello, world!'));
      client.close();
    });

    test('sends the correct prompt format to the API', () async {
      late http.Request capturedRequest;

      final sut = GrammarClient(
        apiUrl: Uri.parse('https://api.example.com/v1/chat/completions'),
        apiKey: 'test-key',
        maxRetries: 0,
        httpClient: MockClient((request) async {
          capturedRequest = request;
          return http.Response(_successBody('OK'), 200);
        }),
      );

      await sut.correct('she go to school');

      final requestBody =
          jsonDecode(capturedRequest.body) as Map<String, dynamic>;
      final messages = requestBody['messages'] as List<dynamic>;
      final userMessage = messages.first as Map<String, dynamic>;

      expect(
        userMessage['content'],
        equals('Fix grammar and rewrite naturally:\nshe go to school'),
      );
      sut.close();
    });

    test('sends the Authorization header with the API key', () async {
      late http.Request capturedRequest;

      final sut = GrammarClient(
        apiUrl: Uri.parse('https://api.example.com/v1/chat/completions'),
        apiKey: 'my-secret-key',
        maxRetries: 0,
        httpClient: MockClient((request) async {
          capturedRequest = request;
          return http.Response(_successBody('OK'), 200);
        }),
      );

      await sut.correct('test sentence');

      expect(
        capturedRequest.headers['Authorization'],
        equals('Bearer my-secret-key'),
      );
      sut.close();
    });
  });

  // -------------------------------------------------------------------------
  // Non-retryable (4xx) errors
  // -------------------------------------------------------------------------

  group('GrammarClient.correct – non-retryable errors', () {
    test('throws GrammarApiException on 401 without retrying', () async {
      int callCount = 0;

      final sut = GrammarClient(
        apiUrl: Uri.parse('https://api.example.com/v1/chat/completions'),
        apiKey: 'bad-key',
        maxRetries: 3,
        httpClient: MockClient((_) async {
          callCount++;
          return http.Response('Unauthorized', 401);
        }),
      );

      await expectLater(
        sut.correct('test'),
        throwsA(
          isA<GrammarApiException>()
              .having((e) => e.statusCode, 'statusCode', 401),
        ),
      );

      // Should not have retried after a 4xx response.
      expect(callCount, equals(1));
      sut.close();
    });

    test('throws GrammarApiException on 429 without retrying', () async {
      int callCount = 0;

      final sut = GrammarClient(
        apiUrl: Uri.parse('https://api.example.com/v1/chat/completions'),
        apiKey: 'key',
        maxRetries: 2,
        httpClient: MockClient((_) async {
          callCount++;
          return http.Response('Too Many Requests', 429);
        }),
      );

      await expectLater(
        sut.correct('test'),
        throwsA(isA<GrammarApiException>()),
      );
      expect(callCount, equals(1));
      sut.close();
    });
  });

  // -------------------------------------------------------------------------
  // Retry behaviour on 5xx errors
  // -------------------------------------------------------------------------

  group('GrammarClient.correct – retry on 5xx', () {
    test('retries on 500 and succeeds on the second attempt', () async {
      int callCount = 0;
      const corrected = 'I want to take leave tomorrow.';

      final sut = GrammarClient(
        apiUrl: Uri.parse('https://api.example.com/v1/chat/completions'),
        apiKey: 'key',
        maxRetries: 2,
        httpClient: MockClient((_) async {
          callCount++;
          if (callCount == 1) {
            return http.Response('Internal Server Error', 500);
          }
          return http.Response(_successBody(corrected), 200);
        }),
      );

      final result = await sut.correct('i want leave tommorow');

      expect(result, equals(corrected));
      expect(callCount, equals(2));
      sut.close();
    });

    test('exhausts all retries and throws GrammarApiException on persistent 503',
        () async {
      int callCount = 0;
      const maxRetries = 3;

      final sut = GrammarClient(
        apiUrl: Uri.parse('https://api.example.com/v1/chat/completions'),
        apiKey: 'key',
        maxRetries: maxRetries,
        httpClient: MockClient((_) async {
          callCount++;
          return http.Response('Service Unavailable', 503);
        }),
      );

      await expectLater(
        sut.correct('test'),
        throwsA(
          isA<GrammarApiException>()
              .having((e) => e.statusCode, 'statusCode', 503),
        ),
      );

      // 1 initial attempt + maxRetries retries.
      expect(callCount, equals(maxRetries + 1));
      sut.close();
    });

    test('retries on network error and succeeds on the third attempt',
        () async {
      int callCount = 0;
      const corrected = 'He is going to the market.';

      final sut = GrammarClient(
        apiUrl: Uri.parse('https://api.example.com/v1/chat/completions'),
        apiKey: 'key',
        maxRetries: 3,
        httpClient: MockClient((_) async {
          callCount++;
          if (callCount < 3) throw Exception('Network error');
          return http.Response(_successBody(corrected), 200);
        }),
      );

      final result = await sut.correct('he going to the market');

      expect(result, equals(corrected));
      expect(callCount, equals(3));
      sut.close();
    });
  });

  // -------------------------------------------------------------------------
  // Timeout protection
  // -------------------------------------------------------------------------

  group('GrammarClient.correct – timeout', () {
    test('throws TimeoutException when the request exceeds the timeout',
        () async {
      final sut = GrammarClient(
        apiUrl: Uri.parse('https://api.example.com/v1/chat/completions'),
        apiKey: 'key',
        maxRetries: 0,
        timeout: const Duration(milliseconds: 50),
        httpClient: MockClient((_) async {
          // Simulate a slow server.
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return http.Response(_successBody('Late reply'), 200);
        }),
      );

      await expectLater(
        sut.correct('test'),
        throwsA(isA<TimeoutException>()),
      );
      sut.close();
    });
  });

  // -------------------------------------------------------------------------
  // GrammarApiException
  // -------------------------------------------------------------------------

  group('GrammarApiException', () {
    test('toString includes statusCode and body', () {
      const e = GrammarApiException(404, 'Not Found');
      expect(e.toString(), contains('404'));
      expect(e.toString(), contains('Not Found'));
    });
  });
}
