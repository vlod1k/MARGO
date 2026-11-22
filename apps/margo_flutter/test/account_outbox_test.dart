import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:margo/data/local_database.dart';
import 'package:margo/data/repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest.dart' as tzdata;

class AccountServer implements HttpClientAdapter {
  String user = 'a';
  bool expired = false;
  bool offline = false;
  bool loseResponse = false;
  bool rejectProfile = false;
  int applications = 0;
  final received = <String, List<dynamic>>{};
  final applied = <String>{};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelled,
  ) async {
    Object body;
    var status = 200;
    if (options.path == '/api/auth/login') {
      body = {'access_token': 'token-$user'};
    } else if (options.path == '/api/auth/me' && rejectProfile) {
      body = {'detail': 'Invalid token'};
      status = 401;
    } else if (options.path == '/api/auth/me') {
      body = {'id': user};
    } else if (expired) {
      body = {'detail': 'Session expired'};
      status = 401;
    } else if (offline) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
      );
    } else if (options.path == '/api/auth/logout') {
      body = {};
      status = 204;
    } else if (options.path == '/api/sync/operations') {
      final operations = (options.data as Map)['operations'] as List;
      received[user] = [...?received[user], ...operations];
      for (final op in operations) {
        if (applied.add('$user:${op['operation_id']}')) applications++;
      }
      if (loseResponse && operations.isNotEmpty) {
        loseResponse = false;
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.receiveTimeout,
        );
      }
      body = {
        'profile': {'id': user},
        'articles': [],
        'interactions': [],
        'history': [],
        'results': operations
            .map(
              (op) => {'operation_id': op['operation_id'], 'status': 'applied'},
            )
            .toList(),
      };
    } else {
      body = {'detail': 'Not ready'};
      status = 409;
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
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
  setUpAll(() {
    sqfliteFfiInit();
    tzdata.initializeTimeZones();
  });
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  Future<LocalDatabase> createDatabase(String path) async {
    final db = await databaseFactoryFfi.openDatabase(path);
    await db.execute(
      'CREATE TABLE cache (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE operations (seq INTEGER PRIMARY KEY AUTOINCREMENT, operation_id TEXT UNIQUE NOT NULL, payload TEXT NOT NULL)',
    );
    return LocalDatabase(db);
  }

  test('401 survives restart, failed login, demo and another account; restores original FIFO', () async {
    final dir = await Directory.systemTemp.createTemp('margo-outbox-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/test.sqlite';
    var local = await createDatabase(path);
    var repo = MargoRepository(local);
    final server = AccountServer()..offline = true;
    repo.dio.httpClientAdapter = server;
    await repo.authenticate('a@example.com', 'password');
    await repo.act('article', 'saved', true);
    await repo.act('article', 'feedback', 'liked');
    await repo.act('article', 'read', true);
    final original = await local.pending();
    server.expired = true;
    expect((await repo.synchronize()).signedIn, false);
    expect(await repo.secure.read(key: 'thoth_token'), isNull);
    expect(await local.read('snapshot'), isNull);
    expect(await local.pending(), isEmpty);
    await expectLater(repo.act('article', 'saved', false), throwsStateError);
    await local.db.close();

    local = LocalDatabase(await databaseFactoryFfi.openDatabase(path));
    addTearDown(local.db.close);
    repo = MargoRepository(local)..dio.httpClientAdapter = server;
    expect((await repo.initialize()).signedIn, false);
    // Login succeeds but /me rejects the token: no outbox may be consumed.
    server.rejectProfile = true;
    await expectLater(
      repo.authenticate('a@example.com', 'password'),
      throwsA(isA<DioException>()),
    );
    expect(await local.pending(), isEmpty);
    server.rejectProfile = false;
    server.user = 'b';
    server.expired = false;
    await repo.enterDemo();
    await repo.logout();
    await repo.authenticate('b@example.com', 'password');
    expect(await local.pending(), isEmpty);
    await repo.act('other', 'saved', true);
    server.expired = true;
    await repo.preferences({'version': 0});
    server.expired = false;
    server.user = 'a';
    final restored = await repo.authenticate('a@example.com', 'password');
    expect(await local.pending(), original);
    expect(restored.pending, 3);
    expect(restored.interaction('article')['saved'], true);
    expect(restored.interaction('article')['feedback'], 'liked');
    expect(restored.interaction('article')['read_at'], original[2]['read_at']);
    server.offline = false;
    expect((await repo.synchronize()).online, true);
    expect(server.received['a'], original);
    expect(await local.pending(), isEmpty);
    await repo.logout();
    server.user = 'b';
    await repo.authenticate('b@example.com', 'password');
    expect(server.received['b']!.single['article_id'], 'other');
  });

  test(
    'committed operation keeps its UUID across expiry and retries only once',
    () async {
      final local = await createDatabase(inMemoryDatabasePath);
      addTearDown(local.db.close);
      final repo = MargoRepository(local);
      final server = AccountServer()..offline = true;
      repo.dio.httpClientAdapter = server;
      await repo.authenticate('a@example.com', 'password');
      await repo.act('article', 'saved', true);
      final original = await local.pending();
      server.offline = false;
      server.loseResponse = true;
      await repo.synchronize();
      expect(server.applications, 1);
      server.expired = true;
      await repo.synchronize();
      server.expired = false;
      await repo.authenticate('a@example.com', 'password');
      expect(server.received['a'], [...original, ...original]);
      expect(server.applications, 1);
      expect(await local.pending(), isEmpty);
    },
  );

  test(
    'missing token at startup and 401 during deletion preserve pending actions',
    () async {
      final local = await createDatabase(inMemoryDatabasePath);
      addTearDown(local.db.close);
      final server = AccountServer()..offline = true;
      var repo = MargoRepository(local)..dio.httpClientAdapter = server;
      await repo.authenticate('a@example.com', 'password');
      await repo.act('article', 'saved', true);
      final original = await local.pending();
      await repo.secure.delete(key: 'thoth_token');
      repo = MargoRepository(local)..dio.httpClientAdapter = server;
      expect((await repo.initialize()).signedIn, false);
      await repo.authenticate('a@example.com', 'password');
      expect(await local.pending(), original);
      server.expired = true;
      await repo.deleteAccount();
      server.expired = false;
      await repo.authenticate('a@example.com', 'password');
      expect(await local.pending(), original);
    },
  );

  test(
    'failed restoration rolls back without losing the account outbox',
    () async {
      final local = await createDatabase(inMemoryDatabasePath);
      addTearDown(local.db.close);
      final repo = MargoRepository(local);
      final server = AccountServer()..offline = true;
      repo.dio.httpClientAdapter = server;
      await repo.authenticate('a@example.com', 'password');
      await repo.act('article', 'saved', true);
      final original = await local.pending();
      await repo.clearLocal();
      await expectLater(
        local.restoreAccount(repo.endpoint, {
          'profile': {'id': 'a'},
        }, (_, _) => throw StateError('interrupted')),
        throwsStateError,
      );
      expect(await local.pending(), isEmpty);
      expect(await local.read('snapshot'), isNull);
      await repo.authenticate('a@example.com', 'password');
      expect(await local.pending(), original);
    },
  );

  test('server namespace is isolated and successful deletion discards active actions', () async {
    final local = await createDatabase(inMemoryDatabasePath);
    addTearDown(local.db.close);
    final repo = MargoRepository(local);
    final server = AccountServer()..offline = true;
    repo.dio.httpClientAdapter = server;
    await repo.authenticate('a@example.com', 'password');
    await repo.act('old-server', 'saved', true);
    await local.write('account_server', {
      'endpoint': 'https://old.example.com',
    });
    await repo.clearLocal();
    await repo.authenticate('a@example.com', 'password');
    expect(await local.pending(), isEmpty);
    await repo.act('deleted', 'read', true);
    server.offline = false;
    // The transport returns 409 for unrelated endpoints; provide a successful DELETE.
    repo.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'DELETE') {
            handler.resolve(Response(requestOptions: options, statusCode: 204));
          } else {
            handler.next(options);
          }
        },
      ),
    );
    await repo.deleteAccount();
    server.offline = true;
    await repo.authenticate('a@example.com', 'password');
    expect(await local.pending(), isEmpty);
    await repo.clearLocal();
    await local.restoreAccount('https://old.example.com', {
      'profile': {'id': 'a'},
    }, MargoRepository.overlay);
    expect((await local.pending()).single['article_id'], 'old-server');
  });
}
