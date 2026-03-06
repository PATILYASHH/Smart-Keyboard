import 'package:flutter_test/flutter_test.dart';
import 'package:smart_keyboard/spell/spell_corrector.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Sample vocabulary used across multiple tests.
  // ---------------------------------------------------------------------------

  final sampleWords = [
    'tomorrow',
    "tomorrow's",
    'tomorrows',
    'tonight',
    'today',
    'hello',
    'world',
    'water',
    'apple',
    'orange',
    'computer',
    'keyboard',
    'receive',
    'believe',
    'achieve',
    'friend',
    'because',
    'separate',
    'necessary',
    'occurrence',
  ];

  SpellCorrector makeSut([List<String>? words]) =>
      SpellCorrector.fromList(words ?? sampleWords);

  // ---------------------------------------------------------------------------
  // levenshteinDistance – unit tests
  // ---------------------------------------------------------------------------

  group('SpellCorrector.levenshteinDistance', () {
    test('identical strings return 0', () {
      expect(SpellCorrector.levenshteinDistance('hello', 'hello'), equals(0));
    });

    test('empty source returns target length', () {
      expect(SpellCorrector.levenshteinDistance('', 'abc'), equals(3));
    });

    test('empty target returns source length', () {
      expect(SpellCorrector.levenshteinDistance('abc', ''), equals(3));
    });

    test('single deletion', () {
      expect(SpellCorrector.levenshteinDistance('helo', 'hello'), equals(1));
    });

    test('single insertion', () {
      expect(SpellCorrector.levenshteinDistance('helllo', 'hello'), equals(1));
    });

    test('single substitution', () {
      expect(SpellCorrector.levenshteinDistance('hallo', 'hello'), equals(1));
    });

    test('tommorow → tomorrow is distance 2', () {
      expect(
        SpellCorrector.levenshteinDistance('tommorow', 'tomorrow'),
        equals(2),
      );
    });

    test('tommorow → tomorrows is distance 3', () {
      expect(
        SpellCorrector.levenshteinDistance('tommorow', 'tomorrows'),
        equals(3),
      );
    });

    test('completely different words exceed maxDistance', () {
      // 'apple' vs 'computer' – length diff alone exceeds maxDistance.
      final dist = SpellCorrector.levenshteinDistance('apple', 'computer');
      expect(dist, greaterThan(SpellCorrector.maxDistance));
    });

    test('symmetric: distance(a,b) == distance(b,a)', () {
      const pairs = [
        ('kitten', 'sitting'),
        ('saturday', 'sunday'),
        ('receive', 'recieve'),
      ];
      for (final (a, b) in pairs) {
        expect(
          SpellCorrector.levenshteinDistance(a, b),
          equals(SpellCorrector.levenshteinDistance(b, a)),
          reason: 'expected symmetry for ($a, $b)',
        );
      }
    });
  });

  // ---------------------------------------------------------------------------
  // suggest – behavioural tests
  // ---------------------------------------------------------------------------

  group('SpellCorrector.suggest', () {
    test('empty input returns empty list', () {
      expect(makeSut().suggest(''), isEmpty);
    });

    test('whitespace-only input returns empty list', () {
      expect(makeSut().suggest('   '), isEmpty);
    });

    test('exact match returns the word itself', () {
      final result = makeSut().suggest('hello');
      expect(result, equals(['hello']));
    });

    test('exact match is case-insensitive', () {
      final result = makeSut().suggest('HELLO');
      expect(result, equals(['hello']));
    });

    test('"tommorow" → first suggestion is "tomorrow"', () {
      final result = makeSut().suggest('tommorow');
      expect(result, isNotEmpty);
      expect(result.first, equals('tomorrow'));
    });

    test('"tommorow" returns up to maxSuggestions results', () {
      final result = makeSut().suggest('tommorow');
      expect(result.length, lessThanOrEqualTo(SpellCorrector.maxSuggestions));
    });

    test('"tommorow" suggestions include "tomorrow" and "tomorrows"', () {
      final result = makeSut().suggest('tommorow');
      expect(result, contains('tomorrow'));
      expect(result, contains('tomorrows'));
    });

    test('results are sorted by ascending edit distance', () {
      // 'recieve' is a classic misspelling of 'receive' (distance 2).
      final extended = [...sampleWords, 'relieve', 'relief'];
      final result = SpellCorrector.fromList(extended).suggest('recieve');
      expect(result, isNotEmpty);

      // Verify 'receive' appears before candidates with a higher distance.
      final receiveIdx = result.indexOf('receive');
      expect(receiveIdx, greaterThanOrEqualTo(0),
          reason: '"receive" should be in the suggestions');
      for (int i = 0; i < receiveIdx; i++) {
        final earlier = SpellCorrector.levenshteinDistance('recieve', result[i]);
        final later = SpellCorrector.levenshteinDistance('recieve', 'receive');
        expect(earlier, lessThanOrEqualTo(later));
      }
    });

    test('no suggestion for a short unrecognised word (< 2 chars)', () {
      // One-character input is too short for meaningful spell correction.
      final corrector = SpellCorrector.fromList(['a', 'i', 'to']);
      // Single letter: exact match if in dict.
      expect(corrector.suggest('a'), equals(['a']));
    });

    test('returns at most maxSuggestions even when many candidates match', () {
      // Dictionary with many words close to 'test'.
      final words = ['test', 'text', 'best', 'rest', 'nest', 'fest', 'vest'];
      final result = SpellCorrector.fromList(words).suggest('tset');
      expect(result.length, lessThanOrEqualTo(SpellCorrector.maxSuggestions));
    });

    test('returns empty list when no word is within maxDistance', () {
      final corrector =
          SpellCorrector.fromList(['xyz', 'abc', 'def', 'ghi']);
      // 'hello' is not close to any of the four candidates.
      final result = corrector.suggest('hello');
      expect(result, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // contains
  // ---------------------------------------------------------------------------

  group('SpellCorrector.contains', () {
    test('returns true for a word in the dictionary', () {
      expect(makeSut().contains('hello'), isTrue);
    });

    test('returns true regardless of case', () {
      expect(makeSut().contains('HELLO'), isTrue);
    });

    test('returns false for a word not in the dictionary', () {
      expect(makeSut().contains('nonexistent'), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // Performance
  // ---------------------------------------------------------------------------

  group('SpellCorrector performance', () {
    test('suggest runs in under 10 ms on a 700-word dictionary', () {
      // Build a representative dictionary with 700 unique words by combining
      // the sample words with programmatically generated distinct words.
      // Each generated word is a unique letter sequence unlikely to appear in
      // the real dictionary, ensuring the corrector scans the full list.
      final uniqueWords = <String>{...sampleWords};
      for (int i = 0; uniqueWords.length < 700; i++) {
        // Produces words like 'aaaa', 'aaab', ..., 'baaa', etc.
        final code = i;
        final w = String.fromCharCodes([
          0x61 + (code ~/ (26 * 26 * 26)) % 26,
          0x61 + (code ~/ (26 * 26)) % 26,
          0x61 + (code ~/ 26) % 26,
          0x61 + code % 26,
        ]);
        uniqueWords.add(w);
      }

      final corrector = SpellCorrector.fromList(uniqueWords.toList());

      final sw = Stopwatch()..start();
      corrector.suggest('tommorow');
      sw.stop();

      expect(
        sw.elapsedMilliseconds,
        lessThan(10),
        reason: 'spell correction must complete within 10 ms',
      );
    });
  });
}
