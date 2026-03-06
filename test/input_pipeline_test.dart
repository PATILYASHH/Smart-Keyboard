import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smart_keyboard/grammar/grammar_client.dart';
import 'package:smart_keyboard/pipeline/input_pipeline.dart';
import 'package:smart_keyboard/prediction/ngram_predictor.dart';
import 'package:smart_keyboard/spell/spell_corrector.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Builds a minimal OpenAI-compatible chat-completions response.
String _aiBody(String content) => jsonEncode({
      'choices': [
        {
          'message': {'role': 'assistant', 'content': content},
        }
      ],
    });

/// Creates a [GrammarClient] whose HTTP client always returns [body] with
/// HTTP [statusCode].
GrammarClient _grammarClient({
  required String body,
  int statusCode = 200,
  Duration responseDelay = Duration.zero,
}) =>
    GrammarClient(
      apiUrl: Uri.parse('https://api.example.com/v1/chat/completions'),
      apiKey: 'test-key',
      maxRetries: 0,
      timeout: const Duration(seconds: 5),
      httpClient: MockClient((_) async {
        if (responseDelay > Duration.zero) await Future<void>.delayed(responseDelay);
        return http.Response(body, statusCode);
      }),
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Duration of the slow first AI response in the stale-response test.
const _slowResponseDelay = Duration(milliseconds: 200);

/// How long to wait for both AI responses to settle in the stale-response test.
const _settleDelay = Duration(milliseconds: 500);

void main() {
  // -------------------------------------------------------------------------
  // Stage 1 – Input buffer
  // -------------------------------------------------------------------------

  group('Stage 1 – input buffer', () {
    test('accumulates word characters into currentWord', () {
      final pipeline = InputPipeline(onSuggestions: (_) {});
      pipeline.process('h');
      pipeline.process('e');
      pipeline.process('l');
      expect(pipeline.currentWord, 'hel');
    });

    test('rotates previousWord on word boundary (space)', () {
      final pipeline = InputPipeline(onSuggestions: (_) {});
      for (final c in 'hello'.split('')) {
        pipeline.process(c);
      }
      pipeline.process(' '); // word boundary

      expect(pipeline.currentWord, '');
      expect(pipeline.previousWord, 'hello');
    });

    test('rotates previousPreviousWord after two completed words', () {
      final pipeline = InputPipeline(onSuggestions: (_) {});
      for (final c in 'i'.split('')) {
        pipeline.process(c);
      }
      pipeline.process(' ');
      for (final c in 'will'.split('')) {
        pipeline.process(c);
      }
      pipeline.process(' ');

      expect(pipeline.previousPreviousWord, 'i');
      expect(pipeline.previousWord, 'will');
      expect(pipeline.currentWord, '');
    });

    test('lower-cases accumulated characters', () {
      final pipeline = InputPipeline(onSuggestions: (_) {});
      pipeline.process('H');
      pipeline.process('i');
      expect(pipeline.currentWord, 'hi');
    });

    test('non-letter characters do not accumulate in word buffer', () {
      final pipeline = InputPipeline(onSuggestions: (_) {});
      pipeline.process('1');
      pipeline.process('2');
      expect(pipeline.currentWord, '');
    });
  });

  // -------------------------------------------------------------------------
  // Stage 2 – Spell correction
  // -------------------------------------------------------------------------

  group('Stage 2 – spell correction', () {
    test('suggests corrections when mid-word (>= 2 chars)', () {
      final corrector = SpellCorrector.fromList(['hello', 'help', 'helm']);
      final List<List<String>> captured = [];

      final pipeline = InputPipeline(
        spellCorrector: corrector,
        onSuggestions: captured.add,
      );

      pipeline.process('h');
      pipeline.process('e');
      pipeline.process('l');

      // Last update should contain spell suggestions for 'hel'
      expect(captured.last, isNotEmpty);
    });

    test('returns no spell suggestions for single character', () {
      final corrector = SpellCorrector.fromList(['hello']);
      final List<List<String>> captured = [];

      final pipeline = InputPipeline(
        spellCorrector: corrector,
        onSuggestions: captured.add,
      );

      pipeline.process('h');

      // 'h' has length 1 → spell correction stage is skipped
      expect(captured.last, isEmpty);
    });

    test('returns empty list when no corrector is set', () {
      final List<List<String>> captured = [];

      final pipeline = InputPipeline(onSuggestions: captured.add);
      pipeline.process('h');
      pipeline.process('e');

      expect(captured.last, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // Stage 3 – Word prediction
  // -------------------------------------------------------------------------

  group('Stage 3 – word prediction', () {
    test('provides n-gram predictions between words', () {
      final predictor = NgramPredictor.fromMap({
        'bigrams': {
          'i': {'will': 10, 'am': 5},
        },
        'trigrams': {},
      });
      final List<List<String>> captured = [];

      final pipeline = InputPipeline(
        ngramPredictor: predictor,
        onSuggestions: captured.add,
      );

      // Type 'i' then space to trigger prediction
      pipeline.process('i');
      pipeline.process(' ');

      expect(captured.last, contains('will'));
    });

    test('uses trigram context when two previous words are available', () {
      final predictor = NgramPredictor.fromMap({
        'bigrams': {
          'will': {'go': 5},
        },
        'trigrams': {
          'i will': {'go': 7, 'come': 4},
        },
      });
      final List<List<String>> captured = [];

      final pipeline = InputPipeline(
        ngramPredictor: predictor,
        onSuggestions: captured.add,
      );

      // Type 'i will ' to build two-word context
      for (final c in 'i will '.split('')) {
        pipeline.process(c);
      }

      expect(captured.last.first, 'go'); // highest frequency trigram hit
    });

    test('returns empty predictions when no predictor is set', () {
      final List<List<String>> captured = [];

      final pipeline = InputPipeline(onSuggestions: captured.add);
      pipeline.process('i');
      pipeline.process(' ');

      expect(captured.last, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // Stage 4 – Suggestion bar update (instant, synchronous)
  // -------------------------------------------------------------------------

  group('Stage 4 – suggestion bar update', () {
    test('onSuggestions is called synchronously within process()', () {
      bool called = false;

      final pipeline = InputPipeline(
        spellCorrector: SpellCorrector.fromList(['hello']),
        onSuggestions: (_) => called = true,
      );

      pipeline.process('h');
      pipeline.process('e');

      // Must be true synchronously — no await needed.
      expect(called, isTrue);
    });

    test('onSuggestions receives new list on every keystroke', () {
      final corrector = SpellCorrector.fromList(['he', 'her', 'hello']);
      final List<List<String>> updates = [];

      final pipeline = InputPipeline(
        spellCorrector: corrector,
        onSuggestions: updates.add,
      );

      pipeline.process('h');
      pipeline.process('e');
      pipeline.process('l');

      // One update per character
      expect(updates, hasLength(3));
    });
  });

  // -------------------------------------------------------------------------
  // Stage 5 – AI grammar improvement (async)
  // -------------------------------------------------------------------------

  group('Stage 5 – AI grammar improvement', () {
    test('onGrammarCorrection is called asynchronously with corrected text',
        () async {
      final completer = Completer<String>();
      final client = _grammarClient(body: _aiBody('I will go.'));

      final pipeline = InputPipeline(
        grammarClient: client,
        onSuggestions: (_) {},
        onGrammarCorrection: completer.complete,
      );

      pipeline.process('i');
      pipeline.process(' ');

      final result = await completer.future.timeout(const Duration(seconds: 5));
      expect(result, 'I will go.');

      client.close();
    });

    test('stale AI responses are discarded when new input arrives', () async {
      // The first AI response takes 300 ms; a second request is fired
      // immediately after.  Only the result for the second request should be
      // delivered.
      int callCount = 0;
      final results = <String>[];

      int requestCount = 0;
      final client = GrammarClient(
        apiUrl: Uri.parse('https://api.example.com/v1/chat/completions'),
        apiKey: 'test-key',
        maxRetries: 0,
        timeout: const Duration(seconds: 5),
        httpClient: MockClient((_) async {
          final n = ++requestCount;
          if (n == 1) {
            // Slow first response – will be superseded.
            await Future<void>.delayed(_slowResponseDelay);
          }
          return http.Response(_aiBody('response-$n'), 200);
        }),
      );

      final pipeline = InputPipeline(
        grammarClient: client,
        onSuggestions: (_) {},
        onGrammarCorrection: (corrected) {
          callCount++;
          results.add(corrected);
        },
      );

      // Fire first request
      pipeline.process('a');
      // Immediately fire second request (bumps token, invalidating first)
      pipeline.process('b');

      // Wait long enough for both requests to complete.
      await Future<void>.delayed(_settleDelay);

      // Only the second (non-stale) response should have been delivered.
      expect(callCount, 1);
      expect(results.single, 'response-2');

      client.close();
    });

    test('AI errors are swallowed and do not propagate to the pipeline',
        () async {
      final client = _grammarClient(body: 'error', statusCode: 500);
      bool grammarCallbackFired = false;

      final pipeline = InputPipeline(
        grammarClient: client,
        onSuggestions: (_) {},
        onGrammarCorrection: (_) => grammarCallbackFired = true,
      );

      // Should not throw even though the AI call will fail.
      expect(
        () {
          pipeline.process('a');
        },
        returnsNormally,
      );

      // Give the async error a chance to propagate (it shouldn't).
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Grammar callback must not have been called on error.
      expect(grammarCallbackFired, isFalse);

      client.close();
    });

    test('no AI request is fired when grammarClient is null', () async {
      bool called = false;

      final pipeline = InputPipeline(
        onSuggestions: (_) {},
        onGrammarCorrection: (_) => called = true,
      );

      pipeline.process('a');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(called, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // deleteLastChar
  // -------------------------------------------------------------------------

  group('deleteLastChar', () {
    test('removes last character from word buffer', () {
      final pipeline = InputPipeline(onSuggestions: (_) {});
      pipeline.process('h');
      pipeline.process('i');
      pipeline.deleteLastChar();

      expect(pipeline.currentWord, 'h');
    });

    test('does nothing when word buffer is empty', () {
      final pipeline = InputPipeline(onSuggestions: (_) {});
      expect(() => pipeline.deleteLastChar(), returnsNormally);
      expect(pipeline.currentWord, '');
    });

    test('calls onSuggestions after deletion', () {
      final List<List<String>> updates = [];
      final pipeline = InputPipeline(onSuggestions: updates.add);
      pipeline.process('h');
      final countBefore = updates.length;
      pipeline.deleteLastChar();
      expect(updates.length, greaterThan(countBefore));
    });
  });

  // -------------------------------------------------------------------------
  // reset
  // -------------------------------------------------------------------------

  group('reset', () {
    test('clears currentWord, previousWord, and previousPreviousWord', () {
      final pipeline = InputPipeline(onSuggestions: (_) {});
      for (final c in 'hello world '.split('')) {
        pipeline.process(c);
      }
      pipeline.process('a');

      pipeline.reset();

      expect(pipeline.currentWord, '');
      expect(pipeline.previousWord, '');
      expect(pipeline.previousPreviousWord, '');
    });

    test('calls onSuggestions with empty list', () {
      List<String>? lastSuggestions;
      final pipeline = InputPipeline(
        spellCorrector: SpellCorrector.fromList(['hello']),
        onSuggestions: (s) => lastSuggestions = s,
      );

      // Build up some state
      for (final c in 'hel'.split('')) {
        pipeline.process(c);
      }

      pipeline.reset();
      expect(lastSuggestions, isEmpty);
    });

    test('discards in-flight AI requests after reset', () async {
      final results = <String>[];
      final client = GrammarClient(
        apiUrl: Uri.parse('https://api.example.com/v1/chat/completions'),
        apiKey: 'test-key',
        maxRetries: 0,
        timeout: const Duration(seconds: 5),
        httpClient: MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return http.Response(_aiBody('Should be discarded'), 200);
        }),
      );

      final pipeline = InputPipeline(
        grammarClient: client,
        onSuggestions: (_) {},
        onGrammarCorrection: results.add,
      );

      pipeline.process('a');
      // Reset before the AI response arrives → token is bumped
      pipeline.reset();

      await Future<void>.delayed(const Duration(milliseconds: 400));

      // The stale AI response must not have been delivered.
      expect(results, isEmpty);

      client.close();
    });
  });
}
