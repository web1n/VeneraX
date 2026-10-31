import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/sqlite_connection.dart';

/// Device-local state, deliberately outside the synced local.db manifest.
/// Keep reads in memory so grid filtering never touches storage.
class LocalAvailabilityStore {
  Database? _db;
  String? _path;
  final _entries = <(String, int), (String, bool)>{};

  void init(String dataPath) {
    final path = '$dataPath/local_availability.db';
    if (_path == path && _db != null) return;
    close();
    _path = path;
    final db = DatabaseGateway.instance.openManaged(path);
    _db = db;
    db.execute('''
      CREATE TABLE IF NOT EXISTS availability (
        comic_id TEXT NOT NULL,
        comic_type INTEGER NOT NULL,
        base_dir TEXT NOT NULL,
        available INTEGER NOT NULL,
        PRIMARY KEY (comic_id, comic_type)
      );
      CREATE TABLE IF NOT EXISTS task_history (
        id TEXT PRIMARY KEY,
        data TEXT NOT NULL
      );
    ''');
    for (final row in db.select('SELECT * FROM availability;')) {
      _entries[(row['comic_id'] as String, row['comic_type'] as int)] =
          (row['base_dir'] as String, row['available'] == 1);
    }
  }

  bool? lookup(String id, int type, String baseDir) {
    final value = _entries[(id, type)];
    return value?.$1 == baseDir ? value?.$2 : null;
  }

  void set(String id, int type, String baseDir, bool available) {
    final value = (baseDir, available);
    if (_entries[(id, type)] == value) return;
    _db?.execute(
      'INSERT OR REPLACE INTO availability VALUES (?, ?, ?, ?);',
      [id, type, baseDir, available ? 1 : 0],
    );
    _entries[(id, type)] = value;
  }

  void remove(String id, int type) {
    _entries.remove((id, type));
    _db?.execute(
      'DELETE FROM availability WHERE comic_id = ? AND comic_type = ?;',
      [id, type],
    );
  }

  /// A transaction bounds write overhead for progress batches and deletions.
  void batch(void Function() apply) {
    final db = _db;
    if (db == null) {
      apply();
      return;
    }
    final previous = Map.of(_entries);
    db.execute('BEGIN TRANSACTION;');
    try {
      apply();
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      _entries
        ..clear()
        ..addAll(previous);
      rethrow;
    }
  }

  List<Map<String, dynamic>> loadHistory() {
    return _db?.select('SELECT data FROM task_history ORDER BY id DESC LIMIT 50;')
        .map((row) => Map<String, dynamic>.from(jsonDecode(row['data'] as String)))
        .toList() ?? [];
  }

  void saveHistory(Iterable<Map<String, dynamic>> tasks) {
    batch(() {
      _db?.execute('DELETE FROM task_history;');
      for (final task in tasks.take(50)) {
        _db?.execute('INSERT INTO task_history VALUES (?, ?);',
            [task['id'], jsonEncode(task)]);
      }
    });
  }

  void close() {
    if (_path != null && _db != null) {
      DatabaseGateway.instance.closeManaged(_path!);
    }
    _db = null;
    _path = null;
    _entries.clear();
  }
}
