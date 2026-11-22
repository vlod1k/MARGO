import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:margo/data/local_database.dart';
import 'package:margo/data/repository.dart';
import 'package:margo/data/models.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  test('queue and optimistic cache survive reopening SQLite', () async {
    final dir = await Directory.systemTemp.createTemp('margo-test-');
    final path = '${dir.path}/test.sqlite';
    final db = await databaseFactoryFfi.openDatabase(path);
    await db.execute(
      'CREATE TABLE cache (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE operations (seq INTEGER PRIMARY KEY AUTOINCREMENT, operation_id TEXT UNIQUE NOT NULL, payload TEXT NOT NULL)',
    );
    final local = LocalDatabase(db);
    final op = <String, dynamic>{
      'operation_id': 'op-1',
      'article_id': 'a',
      'field': 'saved',
      'value': true,
      'base_version': 0,
    };
    final snapshot = MargoRepository.overlay({'interactions': []}, op);
    await local.enqueue(op, snapshot);
    await db.close();
    final nextDb = await databaseFactoryFfi.openDatabase(path);
    final reopened = LocalDatabase(nextDb);
    expect((await reopened.pending()).single, op);
    expect(
      AppData(snapshot: (await reopened.read('snapshot'))!)
          .interaction('a')['saved'],
      true,
    );
    final server = {
      'interactions': [
        {
          'article_id': 'a',
          'saved': true,
          'field_versions': {'saved': 1},
        },
      ],
    };
    await reopened.accept(['op-1'], server);
    expect(await reopened.pending(), isEmpty);
    expect(
      (await reopened.read('snapshot'))!['interactions'],
      server['interactions'],
    );
    await nextDb.close();
    await dir.delete(recursive: true);
  });
  test('successive offline actions retain unique field versions', () {
    final snapshot = MargoRepository.overlay(
      {'interactions': []},
      {
        'article_id': 'a',
        'field': 'feedback',
        'value': 'liked',
        'base_version': 0,
      },
    );
    final next = MargoRepository.overlay(snapshot, {
      'article_id': 'a',
      'field': 'feedback',
      'value': 'known',
      'base_version': 1,
    });
    expect(
      AppData(snapshot: next).interaction('a')['field_versions']['feedback'],
      2,
    );
    expect(AppData(snapshot: next).interaction('a')['feedback'], 'known');
    expect(AppData(snapshot: snapshot).interaction('a')['feedback'], 'liked');
  });
  test('remote HTTP and credentials in endpoint are rejected', () {
    expect(
      () => MargoRepository.validateEndpoint('http://example.com'),
      throwsFormatException,
    );
    expect(
      () => MargoRepository.validateEndpoint('https://user:pass@example.com'),
      throwsFormatException,
    );
    expect(
      MargoRepository.validateEndpoint('https://example.com/'),
      'https://example.com',
    );
    expect(
      MargoRepository.validateEndpoint('http://10.0.2.2:8000'),
      'http://10.0.2.2:8000',
    );
  });
}
