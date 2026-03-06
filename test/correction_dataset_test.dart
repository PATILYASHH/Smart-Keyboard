import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:smart_keyboard/dataset/correction_dataset.dart';

/// Opens an in-memory [CorrectionDataset] backed by sqflite_common_ffi.
Future<CorrectionDataset> _openInMemory() async {
  final dataset = CorrectionDataset();
  await dataset.open(
    dbFactory: databaseFactoryFfi,
    dbPath: inMemoryDatabasePath,
  );
  return dataset;
}

void main() {
  // Initialise the FFI implementation of sqflite so tests run without a
  // real Android/iOS environment.
  setUpAll(() {
    sqfliteFfiInit();
  });

  // ---------------------------------------------------------------------------
  // CorrectionEntry
  // ---------------------------------------------------------------------------

  group('CorrectionEntry', () {
    test('toJson contains input, output and timestamp keys', () {
      final entry = CorrectionEntry(
        input: 'helo bro wat doing',
        output: 'Hello bro, what are you doing?',
        timestamp: DateTime.utc(2024, 1, 15, 12, 30),
      );

      final map = entry.toJson();
      expect(map['input'], equals('helo bro wat doing'));
      expect(map['output'], equals('Hello bro, what are you doing?'));
      expect(map['timestamp'], equals('2024-01-15T12:30:00.000Z'));
    });

    test('fromMap round-trips through toJson', () {
      final original = CorrectionEntry(
        input: 'thx',
        output: 'Thanks',
        timestamp: DateTime.utc(2024, 6, 1),
      );

      final restored = CorrectionEntry.fromMap(original.toJson());
      expect(restored.input, equals(original.input));
      expect(restored.output, equals(original.output));
      expect(restored.timestamp, equals(original.timestamp));
    });

    test('default timestamp is close to now (UTC)', () {
      final before = DateTime.now().toUtc();
      final entry = CorrectionEntry(input: 'hi', output: 'Hi');
      final after = DateTime.now().toUtc();

      expect(
        entry.timestamp.isAfter(before.subtract(const Duration(seconds: 1))),
        isTrue,
      );
      expect(entry.timestamp.isBefore(after.add(const Duration(seconds: 1))),
          isTrue);
    });

    test('toJson is directly serialisable by jsonEncode', () {
      final entry = CorrectionEntry(
        input: 'helo',
        output: 'Hello',
        timestamp: DateTime.utc(2024),
      );
      expect(() => jsonEncode(entry.toJson()), returnsNormally);
    });
  });

  // ---------------------------------------------------------------------------
  // CorrectionDataset.open / close
  // ---------------------------------------------------------------------------

  group('CorrectionDataset.open', () {
    test('open creates database without throwing', () async {
      final dataset = await _openInMemory();
      addTearDown(dataset.close);
    });

    test('calling open twice is a no-op and does not throw', () async {
      final dataset = await _openInMemory();
      addTearDown(dataset.close);
      await dataset.open(
        dbFactory: databaseFactoryFfi,
        dbPath: inMemoryDatabasePath,
      );
    });

    test('calling a method before open throws StateError', () {
      final dataset = CorrectionDataset();
      expect(
        () => dataset.count(),
        throwsA(isA<StateError>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // CorrectionDataset.addEntry
  // ---------------------------------------------------------------------------

  group('CorrectionDataset.addEntry', () {
    late CorrectionDataset dataset;

    setUp(() async {
      dataset = await _openInMemory();
    });

    tearDown(() => dataset.close());

    test('adding a valid entry increases count', () async {
      await dataset.addEntry(
        input: 'helo bro wat doing',
        output: 'Hello bro, what are you doing?',
      );
      expect(await dataset.count(), equals(1));
    });

    test('input is trimmed before storage', () async {
      await dataset.addEntry(
        input: '  hello  ',
        output: 'Hello',
      );
      final entries = await dataset.getEntries();
      expect(entries.first.input, equals('hello'));
    });

    test('output is trimmed before storage', () async {
      await dataset.addEntry(
        input: 'hello',
        output: '  Hello  ',
      );
      final entries = await dataset.getEntries();
      expect(entries.first.output, equals('Hello'));
    });

    test('blank input throws ArgumentError', () async {
      expect(
        () => dataset.addEntry(input: '   ', output: 'Hello'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('blank output throws ArgumentError', () async {
      expect(
        () => dataset.addEntry(input: 'helo', output: ''),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('multiple distinct entries are all stored', () async {
      await dataset.addEntry(input: 'helo', output: 'Hello');
      await dataset.addEntry(input: 'thx', output: 'Thanks');
      await dataset.addEntry(input: 'u', output: 'you');
      expect(await dataset.count(), equals(3));
    });

    test('duplicate input/output pairs are each stored as separate rows',
        () async {
      await dataset.addEntry(input: 'helo', output: 'Hello');
      await dataset.addEntry(input: 'helo', output: 'Hello');
      expect(await dataset.count(), equals(2));
    });

    test('custom timestamp is stored and retrieved correctly', () async {
      final ts = DateTime.utc(2024, 1, 15, 12, 30);
      await dataset.addEntry(
        input: 'helo',
        output: 'Hello',
        timestamp: ts,
      );
      final entries = await dataset.getEntries();
      expect(entries.first.timestamp, equals(ts));
    });
  });

  // ---------------------------------------------------------------------------
  // CorrectionDataset.getEntries
  // ---------------------------------------------------------------------------

  group('CorrectionDataset.getEntries', () {
    late CorrectionDataset dataset;

    setUp(() async {
      dataset = await _openInMemory();
      await dataset.addEntry(
        input: 'a',
        output: 'A',
        timestamp: DateTime.utc(2024, 1, 1),
      );
      await dataset.addEntry(
        input: 'b',
        output: 'B',
        timestamp: DateTime.utc(2024, 1, 2),
      );
      await dataset.addEntry(
        input: 'c',
        output: 'C',
        timestamp: DateTime.utc(2024, 1, 3),
      );
    });

    tearDown(() => dataset.close());

    test('returns all entries when no limit is given', () async {
      final entries = await dataset.getEntries();
      expect(entries.length, equals(3));
    });

    test('entries are ordered by ascending timestamp', () async {
      final entries = await dataset.getEntries();
      expect(entries[0].input, equals('a'));
      expect(entries[1].input, equals('b'));
      expect(entries[2].input, equals('c'));
    });

    test('limit restricts the number of rows returned', () async {
      final entries = await dataset.getEntries(limit: 2);
      expect(entries.length, equals(2));
    });

    test('offset skips the specified number of rows', () async {
      final entries = await dataset.getEntries(offset: 1);
      expect(entries.length, equals(2));
      expect(entries.first.input, equals('b'));
    });

    test('returns empty list when dataset is empty', () async {
      await dataset.clearEntries();
      expect(await dataset.getEntries(), isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // CorrectionDataset.exportJson
  // ---------------------------------------------------------------------------

  group('CorrectionDataset.exportJson', () {
    late CorrectionDataset dataset;

    setUp(() async {
      dataset = await _openInMemory();
    });

    tearDown(() => dataset.close());

    test('returns empty list when no entries exist', () async {
      expect(await dataset.exportJson(), isEmpty);
    });

    test('exported list contains correct keys', () async {
      await dataset.addEntry(
        input: 'helo bro wat doing',
        output: 'Hello bro, what are you doing?',
        timestamp: DateTime.utc(2024, 1, 15, 12, 30),
      );

      final json = await dataset.exportJson();
      expect(json.length, equals(1));

      final row = json.first;
      expect(row['input'], equals('helo bro wat doing'));
      expect(row['output'], equals('Hello bro, what are you doing?'));
      expect(row['timestamp'], equals('2024-01-15T12:30:00.000Z'));
    });

    test('exported list matches the example entry from the spec', () async {
      await dataset.addEntry(
        input: 'helo bro wat doing',
        output: 'Hello bro, what are you doing?',
      );

      final json = await dataset.exportJson();
      final row = json.first;
      expect(row.containsKey('input'), isTrue);
      expect(row.containsKey('output'), isTrue);
      expect(row.containsKey('timestamp'), isTrue);
    });

    test('exportJson result is directly serialisable by jsonEncode', () async {
      await dataset.addEntry(input: 'helo', output: 'Hello');
      final json = await dataset.exportJson();
      expect(() => jsonEncode(json), returnsNormally);
    });

    test('exported list is ordered by ascending timestamp', () async {
      await dataset.addEntry(
        input: 'second',
        output: 'Second',
        timestamp: DateTime.utc(2024, 1, 2),
      );
      await dataset.addEntry(
        input: 'first',
        output: 'First',
        timestamp: DateTime.utc(2024, 1, 1),
      );

      final json = await dataset.exportJson();
      expect(json[0]['input'], equals('first'));
      expect(json[1]['input'], equals('second'));
    });

    test('multiple entries all appear in the exported list', () async {
      await dataset.addEntry(input: 'helo', output: 'Hello');
      await dataset.addEntry(input: 'thx', output: 'Thanks');
      await dataset.addEntry(input: 'u r gr8', output: 'You are great');

      final json = await dataset.exportJson();
      expect(json.length, equals(3));
    });
  });

  // ---------------------------------------------------------------------------
  // CorrectionDataset.clearEntries
  // ---------------------------------------------------------------------------

  group('CorrectionDataset.clearEntries', () {
    late CorrectionDataset dataset;

    setUp(() async {
      dataset = await _openInMemory();
      await dataset.addEntry(input: 'helo', output: 'Hello');
      await dataset.addEntry(input: 'thx', output: 'Thanks');
    });

    tearDown(() => dataset.close());

    test('clearEntries removes all rows', () async {
      await dataset.clearEntries();
      expect(await dataset.count(), equals(0));
    });

    test('clearEntries on an empty dataset does not throw', () async {
      await dataset.clearEntries();
      await dataset.clearEntries(); // second call should be a no-op
    });

    test('new entries can be added after clearing', () async {
      await dataset.clearEntries();
      await dataset.addEntry(input: 'new', output: 'New');
      expect(await dataset.count(), equals(1));
    });
  });

  // ---------------------------------------------------------------------------
  // CorrectionDataset.count
  // ---------------------------------------------------------------------------

  group('CorrectionDataset.count', () {
    late CorrectionDataset dataset;

    setUp(() async {
      dataset = await _openInMemory();
    });

    tearDown(() => dataset.close());

    test('count is 0 for an empty dataset', () async {
      expect(await dataset.count(), equals(0));
    });

    test('count reflects the number of added entries', () async {
      await dataset.addEntry(input: 'a', output: 'A');
      expect(await dataset.count(), equals(1));
      await dataset.addEntry(input: 'b', output: 'B');
      expect(await dataset.count(), equals(2));
    });
  });
}
