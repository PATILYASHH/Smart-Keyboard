import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smart_keyboard/pipeline/input_pipeline.dart';
import 'package:smart_keyboard/translation/hinglish_translator.dart';

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

/// Creates a [HinglishTranslator] backed by a [MockClient] that always returns
/// [statusCode] with [body].
HinglishTranslator _translatorWith({
  required int statusCode,
  required String body,
  int maxRetries = 0,
  Duration timeout = const Duration(seconds: 5),
  Duration responseDelay = Duration.zero,
}) =>
    HinglishTranslator(
      apiUrl: Uri.parse('https://api.example.com/v1/chat/completions'),
      apiKey: 'test-key',
      maxRetries: maxRetries,
      timeout: timeout,
      httpClient: MockClient((_) async {
        if (responseDelay > Duration.zero) {
          await Future<void>.delayed(responseDelay);
        }
        return http.Response(body, statusCode);
      }),
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  // isHinglish – language detection
  // -------------------------------------------------------------------------

  group('HinglishTranslator.isHinglish – detection', () {
    late HinglishTranslator translator;

    setUp(() {
      translator = HinglishTranslator(
        apiUrl: Uri.parse('https://api.example.com/v1/chat/completions'),
        apiKey: 'key',
      );
    });

    tearDown(translator.close);

    test('detects romanised Hinglish phrase with "hai"', () {
      expect(translator.isHinglish('bhai tu kidhar hai'), isTrue);
    });

    test('detects romanised Hinglish phrase with "kal"', () {
      expect(translator.isHinglish('kal office late aunga'), isTrue);
    });

    test('detects Devanagari script as Hinglish', () {
      expect(translator.isHinglish('मैं ठीक हूँ'), isTrue);
    });

    test('detects mixed Devanagari and Latin text', () {
      expect(translator.isHinglish('main ठीक हूँ'), isTrue);
    });

    test('returns false for a plain English sentence', () {
      expect(translator.isHinglish('I will come to the office late tomorrow'),
          isFalse);
    });

    test('returns false for an empty string', () {
      expect(translator.isHinglish(''), isFalse);
    });

    test('detection is case-insensitive for marker words', () {
      // "HAI" should still be detected as a Hinglish marker.
      expect(translator.isHinglish('woh theek HAI'), isTrue);
    });

    test('detects sentence containing "nahi"', () {
      expect(translator.isHinglish('main nahi jaaunga'), isTrue);
    });

    test('detects sentence containing "kya"', () {
      expect(translator.isHinglish('kya hua'), isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // translate – pass-through for non-Hinglish
  // -------------------------------------------------------------------------

  group('HinglishTranslator.translate – non-Hinglish pass-through', () {
    test('returns original text unchanged when not Hinglish (no API call)',
        () async {
      int callCount = 0;
      final sut = HinglishTranslator(
        apiUrl: Uri.parse('https://api.example.com/v1/chat/completions'),
        apiKey: 'key',
        httpClient: MockClient((_) async {
          callCount++;
          return http.Response(_successBody('should not be called'), 200);
        }),
      );

      final result = await sut.translate('hello world');

      expect(result, equals('hello world'));
      expect(callCount, isZero);
      sut.close();
    });
  });

  // -------------------------------------------------------------------------
  // translate – successful translation
  // -------------------------------------------------------------------------

  group('HinglishTranslator.translate – success', () {
    test('translates "bhai tu kidhar hai" to English', () async {
      const translated = 'Bro, where are you?';
      final sut = _translatorWith(
        statusCode: 200,
        body: _successBody(translated),
      );

      final result = await sut.translate('bhai tu kidhar hai');

      expect(result, equals(translated));
      sut.close();
    });

    test('translates "kal office late aunga" to English', () async {
      const translated = 'I will come to the office late tomorrow.';
      final sut = _translatorWith(
        statusCode: 200,
        body: _successBody(translated),
      );

      final result = await sut.translate('kal office late aunga');

      expect(result, equals(translated));
      sut.close();
    });

    test('strips surrounding whitespace from the translated text', () async {
      final sut = _translatorWith(
        statusCode: 200,
        body: _successBody('  Bro, where are you?  '),
      );

      final result = await sut.translate('bhai tu kidhar hai');

      expect(result, equals('Bro, where are you?'));
      sut.close();
    });

    test('sends the correct prompt to the API', () async {
      late http.Request capturedRequest;

      final sut = HinglishTranslator(
        apiUrl: Uri.parse('https://api.example.com/v1/chat/completions'),
        apiKey: 'test-key',
        maxRetries: 0,
        httpClient: MockClient((request) async {
          capturedRequest = request;
          return http.Response(_successBody('OK'), 200);
        }),
      );

      await sut.translate('bhai tu kidhar hai');

      final requestBody =
          jsonDecode(capturedRequest.body) as Map<String, dynamic>;
      final messages = requestBody['messages'] as List<dynamic>;
      final userMessage = messages.first as Map<String, dynamic>;

      expect(
        userMessage['content'],
        contains('Hinglish'),
      );
      expect(
        userMessage['content'],
        contains('bhai tu kidhar hai'),
      );
      sut.close();
    });

    test('sends the Authorization header with the API key', () async {
      late http.Request capturedRequest;

      final sut = HinglishTranslator(
        apiUrl: Uri.parse('https://api.example.com/v1/chat/completions'),
        apiKey: 'my-secret-key',
        maxRetries: 0,
        httpClient: MockClient((request) async {
          capturedRequest = request;
          return http.Response(_successBody('OK'), 200);
        }),
      );

      await sut.translate('bhai tu kidhar hai');

      expect(
        capturedRequest.headers['Authorization'],
        equals('Bearer my-secret-key'),
      );
      sut.close();
    });
  });

  // -------------------------------------------------------------------------
  // translate – non-retryable (4xx) errors
  // -------------------------------------------------------------------------

  group('HinglishTranslator.translate – non-retryable errors', () {
    test('throws TranslationApiException on 401 without retrying', () async {
      int callCount = 0;

      final sut = HinglishTranslator(
        apiUrl: Uri.parse('https://api.example.com/v1/chat/completions'),
        apiKey: 'bad-key',
        maxRetries: 3,
        httpClient: MockClient((_) async {
          callCount++;
          return http.Response('Unauthorized', 401);
        }),
      );

      await expectLater(
        sut.translate('bhai tu kidhar hai'),
        throwsA(
          isA<TranslationApiException>()
              .having((e) => e.statusCode, 'statusCode', 401),
        ),
      );

      // Should not have retried after a 4xx response.
      expect(callCount, equals(1));
      sut.close();
    });

    test('throws TranslationApiException on 429 without retrying', () async {
      int callCount = 0;

      final sut = HinglishTranslator(
        apiUrl: Uri.parse('https://api.example.com/v1/chat/completions'),
        apiKey: 'key',
        maxRetries: 2,
        httpClient: MockClient((_) async {
          callCount++;
          return http.Response('Too Many Requests', 429);
        }),
      );

      await expectLater(
        sut.translate('bhai tu kidhar hai'),
        throwsA(isA<TranslationApiException>()),
      );
      expect(callCount, equals(1));
      sut.close();
    });
  });

  // -------------------------------------------------------------------------
  // translate – retry on 5xx errors
  // -------------------------------------------------------------------------

  group('HinglishTranslator.translate – retry on 5xx', () {
    test('retries on 500 and succeeds on the second attempt', () async {
      int callCount = 0;
      const translated = 'Bro, where are you?';

      final sut = HinglishTranslator(
        apiUrl: Uri.parse('https://api.example.com/v1/chat/completions'),
        apiKey: 'key',
        maxRetries: 2,
        httpClient: MockClient((_) async {
          callCount++;
          if (callCount == 1) {
            return http.Response('Internal Server Error', 500);
          }
          return http.Response(_successBody(translated), 200);
        }),
      );

      final result = await sut.translate('bhai tu kidhar hai');

      expect(result, equals(translated));
      expect(callCount, equals(2));
      sut.close();
    });

    test(
        'exhausts all retries and throws TranslationApiException on persistent 503',
        () async {
      int callCount = 0;
      const maxRetries = 3;

      final sut = HinglishTranslator(
        apiUrl: Uri.parse('https://api.example.com/v1/chat/completions'),
        apiKey: 'key',
        maxRetries: maxRetries,
        httpClient: MockClient((_) async {
          callCount++;
          return http.Response('Service Unavailable', 503);
        }),
      );

      await expectLater(
        sut.translate('bhai tu kidhar hai'),
        throwsA(
          isA<TranslationApiException>()
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
      const translated = 'Everything is fine.';

      final sut = HinglishTranslator(
        apiUrl: Uri.parse('https://api.example.com/v1/chat/completions'),
        apiKey: 'key',
        maxRetries: 3,
        httpClient: MockClient((_) async {
          callCount++;
          if (callCount < 3) throw Exception('Network error');
          return http.Response(_successBody(translated), 200);
        }),
      );

      final result = await sut.translate('sab theek hai');

      expect(result, equals(translated));
      expect(callCount, equals(3));
      sut.close();
    });
  });

  // -------------------------------------------------------------------------
  // translate – timeout protection
  // -------------------------------------------------------------------------

  group('HinglishTranslator.translate – timeout', () {
    test('throws TimeoutException when the request exceeds the timeout',
        () async {
      final sut = HinglishTranslator(
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
        sut.translate('bhai tu kidhar hai'),
        throwsA(isA<TimeoutException>()),
      );
      sut.close();
    });
  });

  // -------------------------------------------------------------------------
  // TranslationApiException
  // -------------------------------------------------------------------------

  group('TranslationApiException', () {
    test('toString includes statusCode and body', () {
      const e = TranslationApiException(404, 'Not Found');
      expect(e.toString(), contains('404'));
      expect(e.toString(), contains('Not Found'));
    });
  });

  // -------------------------------------------------------------------------
  // Stage 6 – Hinglish translation inside InputPipeline
  // -------------------------------------------------------------------------

  group('InputPipeline – Stage 6 Hinglish translation', () {
    test('onTranslation is called asynchronously with translated text',
        () async {
      final completer = Completer<String>();
      final translator = _translatorWith(
        statusCode: 200,
        body: _successBody('Bro, where are you?'),
      );

      final pipeline = InputPipeline(
        hinglishTranslator: translator,
        onSuggestions: (_) {},
        onTranslation: completer.complete,
      );

      // 'bhai' is a Hinglish marker → translation triggered
      for (final c in 'bhai '.split('')) {
        pipeline.process(c);
      }

      final result = await completer.future.timeout(const Duration(seconds: 5));
      expect(result, equals('Bro, where are you?'));

      translator.close();
    });

    test('stale translation responses are discarded when new input arrives',
        () async {
      int callCount = 0;
      final results = <String>[];

      int requestCount = 0;
      final translator = HinglishTranslator(
        apiUrl: Uri.parse('https://api.example.com/v1/chat/completions'),
        apiKey: 'test-key',
        maxRetries: 0,
        timeout: const Duration(seconds: 5),
        httpClient: MockClient((_) async {
          final n = ++requestCount;
          if (n == 1) {
            // Slow first response – will be superseded.
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          return http.Response(_successBody('response-$n'), 200);
        }),
      );

      final pipeline = InputPipeline(
        hinglishTranslator: translator,
        onSuggestions: (_) {},
        onTranslation: (translated) {
          callCount++;
          results.add(translated);
        },
      );

      // Type 'hai' one character at a time.  When 'i' is processed the sentence
      // buffer reads "hai" which is a Hinglish marker, so the first (slow)
      // translation request is dispatched with token 1.  The subsequent space
      // triggers a second request with token 2, invalidating the first.
      pipeline.process('h'); // sentence = "h"   – no Hinglish marker yet
      pipeline.process('a'); // sentence = "ha"  – no Hinglish marker yet
      pipeline.process('i'); // sentence = "hai" – Hinglish detected → request #1 (slow, token 1)
      pipeline.process(' '); // sentence = "hai " – Hinglish detected → request #2 (fast, token 2)

      // Wait long enough for both responses to settle.
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // Only the second (non-stale) response should have been delivered.
      expect(callCount, equals(1));
      expect(results.single, equals('response-2'));

      translator.close();
    });

    test('translation errors are swallowed and do not propagate to the pipeline',
        () async {
      final translator =
          _translatorWith(statusCode: 500, body: 'Internal Server Error');
      bool translationCallbackFired = false;

      final pipeline = InputPipeline(
        hinglishTranslator: translator,
        onSuggestions: (_) {},
        onTranslation: (_) => translationCallbackFired = true,
      );

      expect(
        () {
          // 'bhai' is a Hinglish marker → translation is attempted.
          for (final c in 'bhai '.split('')) {
            pipeline.process(c);
          }
        },
        returnsNormally,
      );

      // Give the async error a chance to propagate (it shouldn't).
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Translation callback must not have been called on error.
      expect(translationCallbackFired, isFalse);

      translator.close();
    });

    test('no translation request is fired when hinglishTranslator is null',
        () async {
      bool called = false;

      final pipeline = InputPipeline(
        onSuggestions: (_) {},
        onTranslation: (_) => called = true,
      );

      for (final c in 'bhai '.split('')) {
        pipeline.process(c);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(called, isFalse);
    });

    test('reset discards in-flight translation requests', () async {
      final results = <String>[];
      final translator = HinglishTranslator(
        apiUrl: Uri.parse('https://api.example.com/v1/chat/completions'),
        apiKey: 'test-key',
        maxRetries: 0,
        timeout: const Duration(seconds: 5),
        httpClient: MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return http.Response(_successBody('Should be discarded'), 200);
        }),
      );

      final pipeline = InputPipeline(
        hinglishTranslator: translator,
        onSuggestions: (_) {},
        onTranslation: results.add,
      );

      for (final c in 'bhai '.split('')) {
        pipeline.process(c);
      }
      // Reset before the translation response arrives → token is bumped.
      pipeline.reset();

      await Future<void>.delayed(const Duration(milliseconds: 400));

      // The stale translation must not have been delivered.
      expect(results, isEmpty);

      translator.close();
    });
  });
}
