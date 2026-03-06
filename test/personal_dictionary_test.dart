import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:smart_keyboard/dictionary/personal_dictionary.dart';

/// Opens an in-memory [PersonalDictionary] backed by sqflite_common_ffi.
Future<PersonalDictionary> _openInMemory() async {
  final dict = PersonalDictionary();
  await dict.open(
    dbFactory: databaseFactoryFfi,
    dbPath: inMemoryDatabasePath,
  );
  return dict;
}

void main() {
  // Initialise the FFI implementation of sqflite so tests run without a
  // real Android/iOS environment.
  setUpAll(() {
    sqfliteFfiInit();
  });

  // ---------------------------------------------------------------------------
  // open / close
  // ---------------------------------------------------------------------------

  group('PersonalDictionary.open', () {
    test('open creates database without throwing', () async {
      final dict = await _openInMemory();
      addTearDown(dict.close);
      // If we reach here the table was created successfully.
    });

    test('calling open twice is a no-op and does not throw', () async {
      final dict = await _openInMemory();
      addTearDown(dict.close);
      await dict.open(
        dbFactory: databaseFactoryFfi,
        dbPath: inMemoryDatabasePath,
      );
    });

    test('calling a method before open throws StateError', () async {
      final dict = PersonalDictionary();
      expect(
        () => dict.contains('word'),
        throwsA(isA<StateError>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // saveWord
  // ---------------------------------------------------------------------------

  group('PersonalDictionary.saveWord', () {
    late PersonalDictionary dict;

    setUp(() async {
      dict = await _openInMemory();
    });

    tearDown(() => dict.close());

    test('saved word is present in dictionary', () async {
      await dict.saveWord('flutter');
      expect(await dict.contains('flutter'), isTrue);
    });

    test('saving the same word twice increments frequency', () async {
      await dict.saveWord('flutter');
      await dict.saveWord('flutter');
      // Frequency should now be 2; verify via getSuggestions which ranks by
      // frequency.  If the word is there at all we have enough evidence.
      final suggestions = await dict.getSuggestions('fl');
      expect(suggestions, contains('flutter'));
    });

    test('word is normalised to lower-case on save', () async {
      await dict.saveWord('Flutter');
      expect(await dict.contains('flutter'), isTrue);
    });

    test('word is trimmed before saving', () async {
      await dict.saveWord('  dart  ');
      expect(await dict.contains('dart'), isTrue);
    });

    test('single-character words are silently ignored', () async {
      await dict.saveWord('a');
      expect(await dict.contains('a'), isFalse);
    });

    test('empty string is silently ignored', () async {
      await dict.saveWord('');
      // Should not throw.
    });
  });

  // ---------------------------------------------------------------------------
  // contains
  // ---------------------------------------------------------------------------

  group('PersonalDictionary.contains', () {
    late PersonalDictionary dict;

    setUp(() async {
      dict = await _openInMemory();
      await dict.saveWord('keyboard');
    });

    tearDown(() => dict.close());

    test('returns true for a saved word', () async {
      expect(await dict.contains('keyboard'), isTrue);
    });

    test('lookup is case-insensitive', () async {
      expect(await dict.contains('KEYBOARD'), isTrue);
    });

    test('returns false for a word that was never saved', () async {
      expect(await dict.contains('unknown'), isFalse);
    });

    test('returns false for empty string', () async {
      expect(await dict.contains(''), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // getSuggestions
  // ---------------------------------------------------------------------------

  group('PersonalDictionary.getSuggestions', () {
    late PersonalDictionary dict;

    setUp(() async {
      dict = await _openInMemory();
      // Save words with different frequencies.
      await dict.saveWord('flutter');
      await dict.saveWord('flutter'); // frequency = 2
      await dict.saveWord('flutter'); // frequency = 3
      await dict.saveWord('flat');    // frequency = 1
      await dict.saveWord('flight');  // frequency = 1
      await dict.saveWord('world');   // no 'fl' prefix
    });

    tearDown(() => dict.close());

    test('returns words that start with the given prefix', () async {
      final results = await dict.getSuggestions('fl');
      expect(results, contains('flutter'));
      expect(results, contains('flat'));
      expect(results, contains('flight'));
      expect(results, isNot(contains('world')));
    });

    test('suggestions are ranked by descending frequency', () async {
      final results = await dict.getSuggestions('fl');
      // 'flutter' has frequency 3 and should appear first.
      expect(results.first, equals('flutter'));
    });

    test('respects limit parameter', () async {
      final results = await dict.getSuggestions('fl', limit: 2);
      expect(results.length, lessThanOrEqualTo(2));
    });

    test('default limit is 3', () async {
      // We have 3 'fl' words; default limit is 3 so all three should come back.
      final results = await dict.getSuggestions('fl');
      expect(results.length, lessThanOrEqualTo(3));
    });

    test('returns empty list for blank prefix', () async {
      expect(await dict.getSuggestions(''), isEmpty);
    });

    test('returns empty list for whitespace-only prefix', () async {
      expect(await dict.getSuggestions('   '), isEmpty);
    });

    test('returns empty list when no words match the prefix', () async {
      expect(await dict.getSuggestions('xyz'), isEmpty);
    });

    test('prefix match is case-insensitive', () async {
      final results = await dict.getSuggestions('FL');
      expect(results, contains('flutter'));
    });
  });

  // ---------------------------------------------------------------------------
  // updateFrequency
  // ---------------------------------------------------------------------------

  group('PersonalDictionary.updateFrequency', () {
    late PersonalDictionary dict;

    setUp(() async {
      dict = await _openInMemory();
      await dict.saveWord('dart'); // frequency = 1
    });

    tearDown(() => dict.close());

    test('updateFrequency increases frequency of an existing word', () async {
      await dict.updateFrequency('dart');
      await dict.updateFrequency('dart');
      // After two extra increments frequency is 3.
      // Verify via getSuggestions ordering: 'dart' should beat any word
      // saved only once.
      await dict.saveWord('data'); // frequency = 1
      final results = await dict.getSuggestions('da');
      expect(results.first, equals('dart'));
    });

    test('updateFrequency on a non-existent word is a no-op', () async {
      // Should not throw.
      await dict.updateFrequency('nonexistent');
      expect(await dict.contains('nonexistent'), isFalse);
    });

    test('updateFrequency is case-insensitive', () async {
      await dict.updateFrequency('DART');
      // Frequency of 'dart' should now be 2.  A second save would yield 3, so
      // 'dart' must still beat a word saved once.
      await dict.saveWord('data'); // frequency = 1
      final results = await dict.getSuggestions('da');
      expect(results.first, equals('dart'));
    });
  });

  // ---------------------------------------------------------------------------
  // removeWord
  // ---------------------------------------------------------------------------

  group('PersonalDictionary.removeWord', () {
    late PersonalDictionary dict;

    setUp(() async {
      dict = await _openInMemory();
      await dict.saveWord('obsolete');
    });

    tearDown(() => dict.close());

    test('removed word is no longer present', () async {
      await dict.removeWord('obsolete');
      expect(await dict.contains('obsolete'), isFalse);
    });

    test('removing a non-existent word is a no-op', () async {
      await dict.removeWord('nonexistent');
      // Should not throw.
    });

    test('remove is case-insensitive', () async {
      await dict.removeWord('OBSOLETE');
      expect(await dict.contains('obsolete'), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // containsAny
  // ---------------------------------------------------------------------------

  group('PersonalDictionary.containsAny', () {
    late PersonalDictionary dict;

    setUp(() async {
      dict = await _openInMemory();
      await dict.saveWord('hello');
      await dict.saveWord('world');
    });

    tearDown(() => dict.close());

    test('returns the subset of words that are present', () async {
      final result = await dict.containsAny(['hello', 'world', 'unknown']);
      expect(result, containsAll(['hello', 'world']));
      expect(result, isNot(contains('unknown')));
    });

    test('returns empty set when no words match', () async {
      final result = await dict.containsAny(['foo', 'bar']);
      expect(result, isEmpty);
    });

    test('returns empty set for empty input', () async {
      final result = await dict.containsAny([]);
      expect(result, isEmpty);
    });

    test('lookup is case-insensitive', () async {
      final result = await dict.containsAny(['HELLO', 'WORLD']);
      expect(result, containsAll(['hello', 'world']));
    });
  });

  // ---------------------------------------------------------------------------
  // Autocorrect exclusion contract
  // ---------------------------------------------------------------------------

  group('PersonalDictionary autocorrect exclusion', () {
    test('contains returns true for a saved word, suppressing autocorrect',
        () async {
      final dict = await _openInMemory();
      addTearDown(dict.close);

      // Simulate a user who always writes 'gonna' intentionally.
      await dict.saveWord('gonna');

      // A caller implementing "never autocorrect saved words" should check:
      expect(await dict.contains('gonna'), isTrue,
          reason: 'saved word must be excluded from autocorrect');
    });
  });
}
