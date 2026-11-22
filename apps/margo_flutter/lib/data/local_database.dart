import 'dart:io';
import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as native;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'models.dart';

class LocalDatabase {
  final Database db;
  LocalDatabase(this.db);
  static Future<LocalDatabase> open() async {
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    } else {
      databaseFactory = native.databaseFactorySqflitePlugin;
    }
    final dir = await getApplicationSupportDirectory();
    final db = await openDatabase(
      p.join(dir.path, 'thoth.sqlite'),
      version: 1,
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE cache (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE operations (seq INTEGER PRIMARY KEY AUTOINCREMENT, operation_id TEXT UNIQUE NOT NULL, payload TEXT NOT NULL)',
        );
      },
    );
    return LocalDatabase(db);
  }

  Future<Json?> read(String key) async {
    final rows = await db.query('cache', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty
        ? null
        : jsonDecode(rows.first['value'] as String) as Json;
  }

  Future<void> write(String key, Json data) async => db
      .insert('cache', {
        'key': key,
        'value': jsonEncode(data),
      }, conflictAlgorithm: ConflictAlgorithm.replace)
      .then((_) {});
  Future<List<Json>> pending() async => (await db.query(
    'operations',
    orderBy: 'seq',
  )).map((r) => jsonDecode(r['payload'] as String) as Json).toList();
  Future<void> enqueue(Json operation, Json snapshot) async {
    await db.transaction((txn) async {
      await txn.insert('operations', {
        'operation_id': operation['operation_id'],
        'payload': jsonEncode(operation),
      });
      await txn.insert('cache', {
        'key': 'snapshot',
        'value': jsonEncode(snapshot),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<void> accept(List<String> ids, Json snapshot) async {
    await db.transaction((txn) async {
      for (final id in ids) {
        await txn.delete(
          'operations',
          where: 'operation_id = ?',
          whereArgs: [id],
        );
      }
      await txn.insert('cache', {
        'key': 'snapshot',
        'value': jsonEncode(snapshot),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  static String _outboxKey(String endpoint, Object accountId) =>
      'account_outbox:${jsonEncode([endpoint, accountId])}';

  // Outboxes are independent of the active session and never contain tokens.
  // Moving between an active queue and an outbox is atomic, including on v1 DBs.
  Future<void> clearAccount({String? preserveForEndpoint}) async {
    await db.transaction((txn) async {
      if (preserveForEndpoint != null) {
        final rows = await txn.query(
          'cache',
          where: 'key = ?',
          whereArgs: ['snapshot'],
        );
        final snapshot = rows.isEmpty
            ? null
            : jsonDecode(rows.single['value'] as String) as Json;
        final accountId = (snapshot?['profile'] as Map?)?['id'];
        final operations = await txn.query('operations', orderBy: 'seq');
        if (accountId != null && operations.isNotEmpty) {
          final key = _outboxKey(preserveForEndpoint, accountId);
          await txn.insert('cache', {
            'key': key,
            'value': jsonEncode({
              'operations': operations
                  .map((row) => jsonDecode(row['payload'] as String))
                  .toList(),
            }),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      await txn.delete('operations');
      await txn.delete(
        'cache',
        where: "key NOT IN (?, ?) AND substr(key, 1, 15) != 'account_outbox:'",
        whereArgs: ['settings', 'demo_snapshot'],
      );
    });
  }

  Future<void> restoreAccount(
    String endpoint,
    Json snapshot,
    Json Function(Json, Json) overlay,
  ) async {
    final key = _outboxKey(
      endpoint,
      (snapshot['profile'] as Map)['id'] as Object,
    );
    await db.transaction((txn) async {
      final rows = await txn.query('cache', where: 'key = ?', whereArgs: [key]);
      if (rows.isNotEmpty) {
        final outbox = jsonDecode(rows.single['value'] as String) as Json;
        for (final operation in (outbox['operations'] as List).cast<Json>()) {
          await txn.insert('operations', {
            'operation_id': operation['operation_id'],
            'payload': jsonEncode(operation),
          });
          snapshot = overlay(snapshot, operation);
        }
        await txn.delete('cache', where: 'key = ?', whereArgs: [key]);
      }
      for (final entry in {
        'snapshot': snapshot,
        'account_server': {'endpoint': endpoint},
      }.entries) {
        await txn.insert('cache', {
          'key': entry.key,
          'value': jsonEncode(entry.value),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }
}
