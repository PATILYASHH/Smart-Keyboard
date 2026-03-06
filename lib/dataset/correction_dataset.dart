import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// A single keyboard-correction pair recorded for ML dataset collection.
///
/// Each entry captures the raw text the user originally typed ([input]), the
/// corrected version ([output]), and the [timestamp] at which the correction
/// was made.
///
/// JSON representation (as produced by [toJson]):
/// ```json
/// {
///   "input":     "helo bro wat doing",
///   "output":    "Hello bro, what are you doing?",
///   "timestamp": "2024-01-15T12:30:00.000Z"
/// }
/// ```
class CorrectionEntry {
  /// Creates a [CorrectionEntry].
  ///
  /// * [input]     – the raw, uncorrected sentence as typed by the user.
  /// * [output]    – the corrected sentence.
  /// * [timestamp] – when the correction was recorded (defaults to now, UTC).
  CorrectionEntry({
    required this.input,
    required this.output,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now().toUtc();

  /// The raw text as typed by the user.
  final String input;

  /// The corrected version of [input].
  final String output;

  /// When this correction was recorded (UTC).
  final DateTime timestamp;

  /// Serialises this entry to a [Map] suitable for [jsonEncode].
  Map<String, dynamic> toJson() => <String, dynamic>{
        'input': input,
        'output': output,
        'timestamp': timestamp.toUtc().toIso8601String(),
      };

  /// Deserialises a [CorrectionEntry] from a [Map] (e.g. a sqflite row).
  factory CorrectionEntry.fromMap(Map<String, dynamic> map) => CorrectionEntry(
        input: map['input'] as String,
        output: map['output'] as String,
        timestamp: DateTime.parse(map['timestamp'] as String).toUtc(),
      );
}

/// Persists keyboard-correction pairs for ML dataset collection.
///
/// Schema
/// ------
/// An SQLite database with a single `corrections` table:
///
/// ```
/// ┌────────────────────┬────────────────────┬───────────────────────────────┐
/// │  input  TEXT       │  output  TEXT       │  timestamp  TEXT              │
/// │  NOT NULL          │  NOT NULL           │  ISO-8601 UTC, NOT NULL       │
/// └────────────────────┴────────────────────┴───────────────────────────────┘
/// ```
///
/// Usage
/// -----
/// ```dart
/// final dataset = CorrectionDataset();
/// await dataset.open();
///
/// // Record a correction pair:
/// await dataset.addEntry(
///   input:  'helo bro wat doing',
///   output: 'Hello bro, what are you doing?',
/// );
///
/// // Export all entries as a JSON-serialisable list for model training:
/// final rows = await dataset.exportJson();
/// final jsonString = jsonEncode(rows);
///
/// // Inspect entries page by page:
/// final page = await dataset.getEntries(limit: 50, offset: 0);
///
/// // Remove all collected data:
/// await dataset.clearEntries();
///
/// await dataset.close();
/// ```
///
/// Thread safety
/// -------------
/// All public methods are `async` and route through sqflite's serialised
/// transaction queue.
class CorrectionDataset {
  static const String _tableName = 'corrections';
  static const String _colInput = 'input';
  static const String _colOutput = 'output';
  static const String _colTimestamp = 'timestamp';

  static const String _createTableSql = '''
    CREATE TABLE IF NOT EXISTS $_tableName (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      $_colInput  TEXT    NOT NULL,
      $_colOutput TEXT    NOT NULL,
      $_colTimestamp TEXT NOT NULL
    )
  ''';

  Database? _db;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Opens (or creates) the SQLite database.
  ///
  /// Must be called before any other method.  Subsequent calls are no-ops when
  /// the database is already open.
  ///
  /// [dbFactory] and [dbPath] are exposed for testing: inject a
  /// `sqflite_common_ffi` factory and an in-memory path to avoid touching the
  /// file system.
  Future<void> open({
    DatabaseFactory? dbFactory,
    String? dbPath,
  }) async {
    if (_db != null) return;

    final factory = dbFactory ?? databaseFactory;
    final path =
        dbPath ?? p.join(await getDatabasesPath(), 'correction_dataset.db');

    _db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async => db.execute(_createTableSql),
      ),
    );
  }

  /// Closes the underlying database connection.
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Records a correction pair.
  ///
  /// * [input]     – raw text as typed by the user (must be non-empty after
  ///   trimming).
  /// * [output]    – corrected version (must be non-empty after trimming).
  /// * [timestamp] – override the recorded time (defaults to `DateTime.now()`
  ///   in UTC).  Useful for importing historical data or in tests.
  ///
  /// Throws [ArgumentError] if either [input] or [output] is blank after
  /// trimming.
  Future<void> addEntry({
    required String input,
    required String output,
    DateTime? timestamp,
  }) async {
    final trimmedInput = input.trim();
    final trimmedOutput = output.trim();

    if (trimmedInput.isEmpty) {
      throw ArgumentError.value(input, 'input', 'must not be blank');
    }
    if (trimmedOutput.isEmpty) {
      throw ArgumentError.value(output, 'output', 'must not be blank');
    }

    final db = _requireDb();
    final ts = (timestamp ?? DateTime.now()).toUtc().toIso8601String();

    await db.insert(_tableName, <String, dynamic>{
      _colInput: trimmedInput,
      _colOutput: trimmedOutput,
      _colTimestamp: ts,
    });
  }

  /// Returns all stored entries as a list of [CorrectionEntry] objects,
  /// ordered by ascending timestamp (oldest first).
  ///
  /// Use [limit] and [offset] for pagination when the dataset is large.
  Future<List<CorrectionEntry>> getEntries({
    int? limit,
    int offset = 0,
  }) async {
    final db = _requireDb();
    final rows = await db.query(
      _tableName,
      columns: [_colInput, _colOutput, _colTimestamp],
      orderBy: '$_colTimestamp ASC',
      limit: limit,
      offset: offset > 0 ? offset : null,
    );
    return rows.map(CorrectionEntry.fromMap).toList();
  }

  /// Returns all stored entries as a JSON-serialisable list of maps, ordered
  /// by ascending timestamp.
  ///
  /// Pass the returned value directly to [jsonEncode] to obtain the training
  /// dataset file.
  ///
  /// Example output:
  /// ```json
  /// [
  ///   {
  ///     "input":     "helo bro wat doing",
  ///     "output":    "Hello bro, what are you doing?",
  ///     "timestamp": "2024-01-15T12:30:00.000Z"
  ///   }
  /// ]
  /// ```
  Future<List<Map<String, dynamic>>> exportJson() async {
    final entries = await getEntries();
    return entries.map((e) => e.toJson()).toList();
  }

  /// Returns the total number of entries stored in the dataset.
  Future<int> count() async {
    final db = _requireDb();
    final result =
        await db.rawQuery('SELECT COUNT(*) AS c FROM $_tableName');
    return (result.first['c'] as int?) ?? 0;
  }

  /// Deletes all entries from the dataset.
  ///
  /// The database file itself is retained; only the rows are removed.
  Future<void> clearEntries() async {
    final db = _requireDb();
    await db.delete(_tableName);
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  Database _requireDb() {
    final db = _db;
    if (db == null) {
      throw StateError(
        'CorrectionDataset has not been opened. Call open() first.',
      );
    }
    return db;
  }
}
