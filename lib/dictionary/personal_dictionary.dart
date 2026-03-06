import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// A personal dictionary that persists words the user has typed.
///
/// Words stored here are:
/// * **never** autocorrected – callers should check [contains] before
///   offering spell-correction suggestions and skip any word that is present.
/// * surfaced as suggestions ranked by [frequency] so that the user's own
///   vocabulary is preferred.
///
/// Storage
/// -------
/// An SQLite database (via `sqflite`) with a single `words` table:
///
/// ```
/// ┌──────────────┬───────────┬──────────────────────────┐
/// │  word TEXT   │ frequency │ last_used TEXT            │
/// │  PRIMARY KEY │  INTEGER  │  ISO-8601 timestamp       │
/// └──────────────┴───────────┴──────────────────────────┘
/// ```
///
/// Thread safety
/// -------------
/// All public methods are `async` and route through `sqflite`'s serialised
/// transaction queue, making them safe to call from the UI isolate.
///
/// Usage
/// -----
/// ```dart
/// // Initialise once at app startup.
/// final dict = PersonalDictionary();
/// await dict.open();
///
/// // Record a word the user typed.
/// await dict.saveWord('flutter');
///
/// // Check before autocorrecting.
/// if (!await dict.contains('flutter')) {
///   final spellSuggestions = corrector.suggest('flutter');
/// }
///
/// // Surface frequently used words in the suggestion bar.
/// final suggestions = await dict.getSuggestions('fl', limit: 3);
///
/// // Dispose when done.
/// await dict.close();
/// ```
class PersonalDictionary {
  static const String _tableName = 'words';
  static const String _colWord = 'word';
  static const String _colFrequency = 'frequency';
  static const String _colLastUsed = 'last_used';

  static const String _createTableSql = '''
    CREATE TABLE IF NOT EXISTS $_tableName (
      $_colWord      TEXT    PRIMARY KEY,
      $_colFrequency INTEGER NOT NULL DEFAULT 1,
      $_colLastUsed  TEXT    NOT NULL
    )
  ''';

  Database? _db;

  /// Opens (or creates) the SQLite database at the default location.
  ///
  /// Must be called before any other method.  Safe to call multiple times –
  /// subsequent calls are no-ops when the database is already open.
  ///
  /// [dbFactory] and [dbPath] are exposed for testing: inject a
  /// [sqflite_common_ffi] factory and an in-memory path to avoid touching the
  /// file system.
  Future<void> open({
    DatabaseFactory? dbFactory,
    String? dbPath,
  }) async {
    if (_db != null) return;

    final factory = dbFactory ?? databaseFactory;
    final path = dbPath ?? p.join(await getDatabasesPath(), 'personal_dictionary.db');

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

  /// Saves [word] to the dictionary, or increments its frequency if it already
  /// exists.
  ///
  /// [word] is trimmed and lower-cased before storage.  Words shorter than two
  /// characters are silently ignored.
  Future<void> saveWord(String word) async {
    final normalised = word.trim().toLowerCase();
    if (normalised.length < 2) return;

    final db = _requireDb();
    final now = DateTime.now().toUtc().toIso8601String();

    // Use UPSERT so a single statement handles both insert and update.
    await db.rawInsert(
      '''
      INSERT INTO $_tableName ($_colWord, $_colFrequency, $_colLastUsed)
      VALUES (?, 1, ?)
      ON CONFLICT($_colWord) DO UPDATE SET
        $_colFrequency = $_colFrequency + 1,
        $_colLastUsed  = excluded.$_colLastUsed
      ''',
      [normalised, now],
    );
  }

  /// Returns `true` if [word] (case-insensitive) is stored in the dictionary.
  Future<bool> contains(String word) async {
    final normalised = word.trim().toLowerCase();
    if (normalised.isEmpty) return false;

    final db = _requireDb();
    final rows = await db.query(
      _tableName,
      columns: [_colWord],
      where: '$_colWord = ?',
      whereArgs: [normalised],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Returns the subset of [words] that are present in the dictionary.
  ///
  /// Uses a single SQL query (one round-trip) regardless of how many words are
  /// checked, avoiding the N+1 query problem.
  Future<Set<String>> containsAny(Iterable<String> words) async {
    final normalised = words
        .map((w) => w.trim().toLowerCase())
        .where((w) => w.isNotEmpty)
        .toSet();
    if (normalised.isEmpty) return const {};

    final db = _requireDb();
    final placeholders = List.filled(normalised.length, '?').join(', ');
    final rows = await db.query(
      _tableName,
      columns: [_colWord],
      where: '$_colWord IN ($placeholders)',
      whereArgs: normalised.toList(),
    );
    return rows.map((r) => r[_colWord] as String).toSet();
  }

  /// Returns up to [limit] suggestions whose word starts with [prefix],
  /// ranked by descending [frequency] then by most-recently used.
  ///
  /// Returns an empty list when [prefix] is blank or no matches exist.
  Future<List<String>> getSuggestions(String prefix, {int limit = 3}) async {
    final normalised = prefix.trim().toLowerCase();
    if (normalised.isEmpty) return const [];

    final db = _requireDb();
    final rows = await db.query(
      _tableName,
      columns: [_colWord],
      where: '$_colWord LIKE ?',
      whereArgs: ['$normalised%'],
      orderBy: '$_colFrequency DESC, $_colLastUsed DESC',
      limit: limit,
    );
    return rows.map((r) => r[_colWord] as String).toList();
  }

  /// Explicitly increments the [frequency] counter for [word].
  ///
  /// Has no effect if [word] is not already in the dictionary.  Callers that
  /// always call [saveWord] first do not need to call this separately.
  Future<void> updateFrequency(String word) async {
    final normalised = word.trim().toLowerCase();
    if (normalised.isEmpty) return;

    final db = _requireDb();
    final now = DateTime.now().toUtc().toIso8601String();
    await db.rawUpdate(
      '''
      UPDATE $_tableName
         SET $_colFrequency = $_colFrequency + 1,
             $_colLastUsed  = ?
       WHERE $_colWord = ?
      ''',
      [now, normalised],
    );
  }

  /// Removes [word] from the dictionary.  No-op if the word is not present.
  Future<void> removeWord(String word) async {
    final normalised = word.trim().toLowerCase();
    if (normalised.isEmpty) return;

    final db = _requireDb();
    await db.delete(
      _tableName,
      where: '$_colWord = ?',
      whereArgs: [normalised],
    );
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  Database _requireDb() {
    final db = _db;
    if (db == null) {
      throw StateError(
        'PersonalDictionary has not been opened. Call open() first.',
      );
    }
    return db;
  }
}
