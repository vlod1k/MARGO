import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:margo/data/local_database.dart';
import 'package:margo/data/repository.dart';

const profile = {
  'id': 'user',
  'name': 'Reader',
  'version': 0,
  'onboarded': true,
};
Future<LocalDatabase> database() async {
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  await db.execute(
    'CREATE TABLE cache (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
  );
  await db.execute(
    'CREATE TABLE operations (seq INTEGER PRIMARY KEY AUTOINCREMENT, operation_id TEXT UNIQUE NOT NULL, payload TEXT NOT NULL)',
  );
  return LocalDatabase(db);
}

class Server implements HttpClientAdapter {
  final bool missingAck;
  final bool expired;
  int syncCalls = 0;
  Server({this.missingAck = false, this.expired = false});
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelled,
  ) async {
    Object body;
    if (expired && options.path == '/api/preferences') {
      return ResponseBody.fromString(
        '{"detail":"Session expired"}',
        401,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    if (options.path == '/api/auth/login') {
      body = {'access_token': 'test-token', 'user_id': 'user'};
    } else if (options.path == '/api/auth/me') {
      body = profile;
    } else if (options.path == '/api/preferences') {
      body = {...profile, 'name': 'Updated', 'version': 1};
    } else {
      syncCalls++;
      if (!missingAck || syncCalls > 1) {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        );
      }
      body = {
        'results': [],
        'profile': profile,
        'articles': [],
        'interactions': [],
        'history': [],
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
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test(
    'expired session during preference save clears the account safely',
    () async {
      final local = await database();
      await local.write('snapshot', {'profile': profile});
      final repo = MargoRepository(local)..token = 'expired';
      repo.dio.httpClientAdapter = Server(expired: true);
      final result = await repo.preferences(profile);
      expect(result.signedIn, false);
      expect(repo.token, isNull);
      expect(await local.read('snapshot'), isNull);
      await local.db.close();
    },
  );
  test(
    'acknowledged preferences survive a disconnected follow-up sync',
    () async {
      final local = await database();
      await local.write('snapshot', {'profile': profile});
      final repo = MargoRepository(local)..token = 'test';
      repo.dio.httpClientAdapter = Server();
      final result = await repo.preferences({...profile, 'name': 'Updated'});
      expect(result.profile!['name'], 'Updated');
      expect(result.profile!['version'], 1);
      await local.db.close();
    },
  );
  test('successful login preserves profile if sync disconnects', () async {
    final local = await database();
    final repo = MargoRepository(local);
    repo.dio.httpClientAdapter = Server();
    final result = await repo.authenticate(
      'reader@example.com',
      'valid-password',
    );
    expect(result.signedIn, true);
    expect(result.profile!['id'], 'user');
    expect((await local.read('snapshot'))!['profile']['id'], 'user');
    expect((await MargoRepository(local).initialize()).signedIn, true);
    await local.db.close();
  });
  test('an old server cannot override the API or reuse its session', () async {
    FlutterSecureStorage.setMockInitialValues({'thoth_token': 'old-token'});
    final local = await database();
    await local.write('settings', {
      'endpoint': 'http://127.0.0.1:8000',
      'theme': 'dark',
    });
    await local.enqueue({'operation_id': 'old-op'}, {'profile': profile});
    final repo = MargoRepository(local);
    final server = Server();
    repo.dio.httpClientAdapter = server;
    expect((await repo.initialize()).signedIn, false);
    expect(repo.dio.options.baseUrl, 'https://margo.invalid');
    expect(repo.dio.options.headers.containsKey('Authorization'), false);
    expect(await repo.secure.read(key: 'thoth_token'), isNull);
    expect(await local.pending(), isEmpty);
    expect((await local.read('settings'))?['theme'], 'dark');
    expect(server.syncCalls, 0);
    await local.db.close();
  });
  test(
    'an existing account on the configured server keeps its session',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'thoth_token': 'current-token',
      });
      final local = await database();
      final repo = MargoRepository(local);
      await local.write('settings', {'endpoint': repo.endpoint});
      await local.enqueue({'operation_id': 'pending-op'}, {'profile': profile});
      final result = await repo.initialize();
      expect(result.signedIn, true);
      expect(result.pending, 1);
      expect(repo.dio.options.headers['Authorization'], 'Bearer current-token');
      await local.db.close();
    },
  );
  test(
    'missing acknowledgements stop sync instead of retrying forever',
    () async {
      final local = await database();
      await local.write('snapshot', {'profile': profile, 'interactions': []});
      final repo = MargoRepository(local)..token = 'test';
      final server = Server(missingAck: true);
      repo.dio.httpClientAdapter = server;
      await repo.act('article', 'saved', true);
      await expectLater(repo.synchronize(), throwsFormatException);
      expect(server.syncCalls, 1);
      expect((await local.pending()).length, 1);
      await local.db.close();
    },
  );
}
