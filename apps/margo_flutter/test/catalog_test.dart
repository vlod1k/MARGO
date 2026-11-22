import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:margo/data/local_database.dart';
import 'package:margo/data/models.dart';
import 'package:margo/data/repository.dart';
import 'package:margo/features/daily_article/article_screen.dart';
import 'package:margo/sync/controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const exhaustion = <String, dynamic>{
  'code': 'catalog_exhausted',
  'language': 'ru',
  'inventory': {
    'ru': {'available': 116, 'remaining': 0},
    'en': {'available': 100, 'remaining': 100},
  },
};

class CatalogServer implements HttpClientAdapter {
  bool refilled = false;
  bool offline = false;
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
    final today = options.path.endsWith('/today');
    final body = today
        ? refilled
              ? {
                  'date': '2026-11-16',
                  'mode': 'personal',
                  'explanation': 'test',
                  'article': {'id': 'new', 'title': 'New'},
                }
              : {'detail': exhaustion}
        : {
            'profile': {'id': 'reader'},
            'results': [],
            'articles': [],
            'history': [],
            'interactions': [],
          };
    return ResponseBody.fromString(
      jsonEncode(body),
      today && !refilled ? 404 : 200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class ExhaustedSession extends SessionController {
  @override
  Future<AppData> build() async => const AppData(
    online: true,
    snapshot: {
      'profile': {'language': 'ru'},
      'catalog_empty': exhaustion,
    },
  );
}

void main() {
  setUpAll(sqfliteFfiInit);
  test(
    'exhaustion survives offline restart and clears after replenishment',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await db.execute(
        'CREATE TABLE cache (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
      );
      await db.execute(
        'CREATE TABLE operations (seq INTEGER PRIMARY KEY AUTOINCREMENT, operation_id TEXT UNIQUE NOT NULL, payload TEXT NOT NULL)',
      );
      final local = LocalDatabase(db);
      final repository = MargoRepository(local)..token = 'test';
      final server = CatalogServer();
      repository.dio.httpClientAdapter = server;
      final empty = await repository.synchronize();
      expect(empty.online, true);
      expect(empty.today, isNull);
      expect(empty.snapshot['catalog_empty'], exhaustion);
      server.offline = true;
      expect(
        (await repository.synchronize()).snapshot['catalog_empty'],
        exhaustion,
      );
      server.offline = false;
      server.refilled = true;
      final next = await repository.synchronize();
      expect(next.today!['article']['id'], 'new');
      expect(next.snapshot['catalog_empty'], isNull);
    },
  );

  for (final width in [390.0, 1280.0]) {
    testWidgets('exhaustion explains stock at width $width', (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sessionProvider.overrideWith(ExhaustedSession.new)],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                return ref
                    .watch(sessionProvider)
                    .when(
                      loading: () => const SizedBox(),
                      error: (e, _) => Text('$e'),
                      data: (_) => const Scaffold(
                        body: SingleChildScrollView(child: TodayScreen()),
                      ),
                    );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Вы просмотрели все доступные статьи'), findsOneWidget);
      expect(find.text('Английский: новых 100, всего 100'), findsOneWidget);
      expect(find.text('Открыть библиотеку'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
