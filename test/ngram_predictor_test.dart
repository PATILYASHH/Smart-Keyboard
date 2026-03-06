import 'package:flutter_test/flutter_test.dart';
import 'package:smart_keyboard/prediction/ngram_predictor.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Sample model used across tests.
  // ---------------------------------------------------------------------------

  /// Minimal in-memory n-gram model used across multiple tests.
  final sampleModel = {
    'bigrams': {
      'i': {'will': 10, 'am': 8, 'can': 6},
      'will': {'go': 12, 'come': 8, 'send': 5},
      'you': {'can': 14, 'are': 11, 'will': 9},
      'good': {'morning': 12, 'night': 10, 'luck': 8},
    },
    'trigrams': {
      'i will': {'go': 7, 'come': 5, 'send': 3},
      'i am': {'going': 8, 'not': 6, 'here': 4},
      'how are': {'you': 15, 'things': 5, 'we': 3},
    },
  };

  NgramPredictor makeSut() => NgramPredictor.fromMap(sampleModel);

  // ---------------------------------------------------------------------------
  // predict – bigram
  // ---------------------------------------------------------------------------

  group('NgramPredictor.predict – bigram', () {
    test('returns top-3 next words for a known unigram context', () {
      final result = makeSut().predict('will');
      expect(result, equals(['go', 'come', 'send']));
    });

    test('returns at most maxPredictions results', () {
      final result = makeSut().predict('i');
      expect(result.length, lessThanOrEqualTo(NgramPredictor.maxPredictions));
    });

    test('results are sorted by descending frequency', () {
      // 'will' → go(12) > come(8) > send(5)
      final result = makeSut().predict('will');
      expect(result[0], equals('go'));
      expect(result[1], equals('come'));
      expect(result[2], equals('send'));
    });

    test('returns empty list for unknown context', () {
      expect(makeSut().predict('xyzzy'), isEmpty);
    });

    test('context is normalised to lower-case', () {
      expect(makeSut().predict('WILL'), equals(makeSut().predict('will')));
    });

    test('handles context with leading/trailing whitespace', () {
      expect(makeSut().predict('  will  '), isNotEmpty);
    });

    test('returns empty list for empty context', () {
      expect(makeSut().predict(''), isEmpty);
    });

    test('returns empty list for whitespace-only context', () {
      expect(makeSut().predict('   '), isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // predict – trigram takes priority over bigram
  // ---------------------------------------------------------------------------

  group('NgramPredictor.predict – trigram priority', () {
    test('"i will" uses trigram and returns correct top-3', () {
      final result = makeSut().predict('i will');
      expect(result, equals(['go', 'come', 'send']));
    });

    test('"i am" uses trigram and returns correct top-3', () {
      final result = makeSut().predict('i am');
      expect(result, equals(['going', 'not', 'here']));
    });

    test('"how are" uses trigram prediction', () {
      final result = makeSut().predict('how are');
      expect(result.first, equals('you'));
    });

    test('falls back to bigram when trigram context has no entry', () {
      // "unknown good" has no trigram entry in sampleModel, but "good" does
      // have a bigram entry → predictor should fall back and return bigram hits.
      final result = makeSut().predict('unknown good');
      expect(result, equals(['morning', 'night', 'luck']));
    });

    test('three-word input uses only last two words as trigram context', () {
      // "please i will" → trigram key "i will"
      final result = makeSut().predict('please i will');
      expect(result, equals(['go', 'come', 'send']));
    });
  });

  // ---------------------------------------------------------------------------
  // predict – tie-breaking
  // ---------------------------------------------------------------------------

  group('NgramPredictor.predict – tie-breaking', () {
    test('ties in frequency are broken lexicographically', () {
      final tieModel = {
        'bigrams': {
          'test': {'banana': 5, 'apple': 5, 'cherry': 5},
        },
        'trigrams': <String, dynamic>{},
      };
      final predictor = NgramPredictor.fromMap(tieModel);
      final result = predictor.predict('test');
      // All three have equal counts; alphabetical order is the tiebreaker.
      expect(result, equals(['apple', 'banana', 'cherry']));
    });
  });

  // ---------------------------------------------------------------------------
  // fromMap – data parsing
  // ---------------------------------------------------------------------------

  group('NgramPredictor.fromMap', () {
    test('handles missing bigrams key gracefully', () {
      final predictor = NgramPredictor.fromMap({
        'trigrams': <String, dynamic>{},
      });
      expect(predictor.predict('i'), isEmpty);
    });

    test('handles missing trigrams key gracefully', () {
      final predictor = NgramPredictor.fromMap({
        'bigrams': {
          'i': {'will': 5},
        },
      });
      expect(predictor.predict('i'), equals(['will']));
    });

    test('normalises context keys to lower-case during parsing', () {
      final predictor = NgramPredictor.fromMap({
        'bigrams': {
          'Will': {'go': 5, 'come': 3},
        },
        'trigrams': <String, dynamic>{},
      });
      // Lookup should succeed regardless of input case.
      expect(predictor.predict('will'), isNotEmpty);
      expect(predictor.predict('WILL'), isNotEmpty);
    });

    test('normalises next-word keys to lower-case during parsing', () {
      final predictor = NgramPredictor.fromMap({
        'bigrams': {
          'i': {'Go': 5, 'COME': 3},
        },
        'trigrams': <String, dynamic>{},
      });
      final result = predictor.predict('i');
      expect(result, contains('go'));
      expect(result, contains('come'));
    });
  });

  // ---------------------------------------------------------------------------
  // maxPredictions constant
  // ---------------------------------------------------------------------------

  group('NgramPredictor constants', () {
    test('maxPredictions is 3', () {
      expect(NgramPredictor.maxPredictions, equals(3));
    });

    test('never returns more than maxPredictions results', () {
      // Model with 5 candidates for one context.
      final bigModel = {
        'bigrams': {
          'i': {
            'will': 10,
            'am': 9,
            'can': 8,
            'have': 7,
            'think': 6,
          },
        },
        'trigrams': <String, dynamic>{},
      };
      final result = NgramPredictor.fromMap(bigModel).predict('i');
      expect(result.length, lessThanOrEqualTo(NgramPredictor.maxPredictions));
    });
  });

  // ---------------------------------------------------------------------------
  // Performance
  // ---------------------------------------------------------------------------

  group('NgramPredictor performance', () {
    test('predict completes in under 5 ms for a 500-entry model', () {
      // Build a large model with 500 bigram contexts each having 10 next-words.
      final bigrams = <String, dynamic>{};
      for (int i = 0; i < 500; i++) {
        final context = 'word$i';
        bigrams[context] = {
          for (int j = 0; j < 10; j++) 'next${i}_$j': 10 - j,
        };
      }
      final predictor = NgramPredictor.fromMap({
        'bigrams': bigrams,
        'trigrams': <String, dynamic>{},
      });

      final sw = Stopwatch()..start();
      predictor.predict('word250');
      sw.stop();

      expect(
        sw.elapsedMilliseconds,
        lessThan(5),
        reason: 'n-gram lookup must complete within 5 ms',
      );
    });
  });
}
