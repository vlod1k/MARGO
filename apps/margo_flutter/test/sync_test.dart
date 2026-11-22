import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:margo/data/local_database.dart';
import 'package:margo/data/repository.dart';

// An API transport that commits a write, loses its response, then accepts a retry.
class LostResponseServer implements HttpClientAdapter {
  bool offline = true, lostResponse = true;
  int applications = 0;
  final results = <String, Map<String, dynamic>>{};
  final interaction = <String, dynamic>{
    'article_id': 'a',
    'saved': false,
    'feedback': null,
    'field_versions': <String, dynamic>{},
  };
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (offline) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
      );
    }
    Map<String, dynamic> body;
    if (options.path.endsWith('/today')) {
      body = {
        'date': '2026-11-05',
        'mode': 'personal',
        'explanation': 'test',
        'article': {
          'id': 'a',
          'title': 'Test',
          'summary': 'Cached description',
          'topics': {'history': 1},
        },
      };
    } else {
      final operations = (options.data as Map)['operations'] as List;
      for (final op in operations) {
        final id = op['operation_id'] as String;
        if (!results.containsKey(id)) {
          applications++;
          if (op['field'] == 'read') {
            interaction['read_at'] = op['value'] == true ? op['read_at'] : null;
          } else {
            interaction[op['field'] as String] = op['value'];
          }
          interaction['field_versions'] = {(op['field'] as String): 1};
          results[id] = {
            'operation_id': id,
            'status': 'applied',
            'interaction': interaction,
          };
        }
      }
      if (lostResponse && operations.isNotEmpty) {
        lostResponse = false;
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.receiveTimeout,
        );
      }
      body = {
        'results': operations.map((op) => results[op['operation_id']]).toList(),
        'profile': {'id': 'user', 'onboarded': true},
        'articles': [
          {'id': 'a', 'summary': 'Cached description'},
        ],
        'history': [],
        'interactions': [interaction],
      };
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  setUpAll(sqfliteFfiInit);
  test(
    'offline action survives lost ACK and retries with the same UUID',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute(
        'CREATE TABLE cache (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
      );
      await db.execute(
        'CREATE TABLE operations (seq INTEGER PRIMARY KEY AUTOINCREMENT, operation_id TEXT UNIQUE NOT NULL, payload TEXT NOT NULL)',
      );
      final local = LocalDatabase(db);
      await local.write('snapshot', {
        'profile': {'id': 'user'},
        'articles': [
          {'id': 'a'},
        ],
        'interactions': [],
      });
      final repository = MargoRepository(local)..token = 'test';
      final backend = LostResponseServer();
      repository.dio.httpClientAdapter = backend;
      final before = DateTime.now().toUtc();
      final optimistic = await repository.act('a', 'read', true);
      final original = (await local.pending()).single;
      final readAt = original['read_at'] as String;
      expect(DateTime.parse(readAt).isBefore(before), false);
      expect(DateTime.parse(readAt).isAfter(DateTime.now().toUtc()), false);
      expect(optimistic.interaction('a')['read_at'], readAt);
      final queued = (await local.pending()).single['operation_id'];
      expect((await repository.synchronize()).online, false);
      expect((await local.pending()).single['operation_id'], queued);
      expect((await local.pending()).single, original);
      backend.offline = false;
      await repository.synchronize(); // Server commits, response is lost.
      expect(backend.applications, 1);
      expect((await local.pending()).single['operation_id'], queued);
      final restored = MargoRepository(local)..token = 'test';
      restored.dio.httpClientAdapter = backend;
      final synced = await restored.synchronize();
      expect(synced.online, true);
      expect(await local.pending(), isEmpty);
      expect(backend.applications, 1);
      expect(synced.interaction('a')['read_at'], readAt);
      expect(synced.today!['article']['summary'], 'Cached description');
      expect(synced.articles.single['summary'], 'Cached description');
      expect(synced.history.single['date'], '2026-11-05');
      await db.close();
    },
  );

  test(
    'replaying offline reads preserves original days and read transitions',
    () {
      var snapshot = <String, dynamic>{};
      Map<String, dynamic> read(
        String article,
        bool value,
        int version,
        String? time,
      ) => {
        'article_id': article,
        'field': 'read',
        'value': value,
        'base_version': version,
        'read_at': ?time,
      };
      const first = '2026-01-02T00:30:00.000Z';
      const second = '2026-01-04T12:00:00.000Z';
      snapshot = MargoRepository.overlay(snapshot, read('a', true, 0, first));
      snapshot = MargoRepository.overlay(snapshot, read('b', true, 0, second));
      expect((snapshot['interactions'] as List).map((i) => i['read_at']), [
        first,
        second,
      ]);
      snapshot = MargoRepository.overlay(snapshot, read('a', true, 1, second));
      expect((snapshot['interactions'] as List).first['read_at'], first);
      snapshot = MargoRepository.overlay(snapshot, read('a', false, 2, null));
      expect((snapshot['interactions'] as List).first['read_at'], isNull);
      snapshot = MargoRepository.overlay(snapshot, read('a', true, 3, second));
      expect((snapshot['interactions'] as List).first['read_at'], second);
    },
  );
}
