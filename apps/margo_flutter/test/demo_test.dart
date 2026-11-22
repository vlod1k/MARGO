import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:margo/app/app.dart';
import 'package:margo/data/local_database.dart';
import 'package:margo/data/models.dart';
import 'package:margo/data/demo_catalog.dart';
import 'package:margo/data/repository.dart';
import 'package:margo/sync/controller.dart';

class NoNetwork implements HttpClientAdapter {
  int calls = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelled,
  ) async {
    calls++;
    throw StateError('Demo must never call API');
  }

  @override
  void close({bool force = false}) {}
}

Future<LocalDatabase> memoryDatabase() async {
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  await db.execute(
    'CREATE TABLE cache (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
  );
  await db.execute(
    'CREATE TABLE operations (seq INTEGER PRIMARY KEY AUTOINCREMENT, operation_id TEXT UNIQUE NOT NULL, payload TEXT NOT NULL)',
  );
  return LocalDatabase(db);
}

class ReadyController extends SessionController {
  final MargoRepository prepared;
  ReadyController(this.prepared);
  @override
  Future<AppData> build() async {
    repository = prepared;
    return const AppData();
  }

  @override
  Future<void> enterDemo() async {
    state = AsyncData(AppData(snapshot: createDemoSnapshot()));
  }

  @override
  Future<void> refresh() async {}
}

class WidgetDatabase implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #query) {
      return Future.value(<Map<String, Object?>>[]);
    }
    return super.noSuchMethod(invocation);
  }
}

class DesktopDemoController extends ReadyController {
  DesktopDemoController(super.prepared);
  @override
  Future<AppData> build() async {
    repository = prepared;
    return AppData(snapshot: createDemoSnapshot());
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    tz.initializeTimeZones();
  });
  testWidgets('desktop navigation remains usable in a low window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = MargoRepository(LocalDatabase(WidgetDatabase()));
    appRouter.go('/');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          repositoryProvider.overrideWith((ref) async => repository),
          sessionProvider.overrideWith(() => DesktopDemoController(repository)),
        ],
        child: const MargoApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  for (final signedIn in [false, true]) {
    testWidgets(
      'narrow mobile shell and login support enlarged text: $signedIn',
      (tester) async {
        tester.view.physicalSize = const Size(320, 600);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 1.6;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final repository = MargoRepository(LocalDatabase(WidgetDatabase()));
        appRouter.go('/');
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              repositoryProvider.overrideWith((ref) async => repository),
              sessionProvider.overrideWith(
                () => signedIn
                    ? DesktopDemoController(repository)
                    : ReadyController(repository),
              ),
            ],
            child: const MargoApp(),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  test('demo persists locally, never queues or sends actions, and preserves account cache', () async {
    final local = await memoryDatabase();
    await local.write('snapshot', {
      'profile': {'id': 'real-user'},
    });
    final repository = MargoRepository(local);
    final network = NoNetwork();
    repository.dio.httpClientAdapter = network;
    final demo = await repository.enterDemo();
    expect(demo.isDemo, true);
    expect(demo.articles.length, 4);
    await repository.act('antikythera', 'saved', true);
    final liked = await repository.act('antikythera', 'feedback', 'liked');
    final repeated = await repository.act('antikythera', 'feedback', 'liked');
    expect(liked.profile!['weights'], repeated.profile!['weights']);
    await repository.act('antikythera', 'read', true);
    await repository.preferences({
      ...demo.profile!,
      'name': 'Гость',
      'interests': ['physics'],
      'timezone': 'Europe/Moscow',
    });
    final restored = MargoRepository(local);
    final snapshot = await restored
        .initialize(); // Also verifies no secure-storage plugin is needed.
    expect(snapshot.isDemo, true);
    expect(snapshot.profile!['name'], 'Гость');
    expect(snapshot.interaction('antikythera')['saved'], true);
    expect(snapshot.interaction('antikythera')['read_at'], isNotNull);
    expect(snapshot.today!['date'], demo.today!['date']);
    final unread = await repository.act('antikythera', 'read', false);
    expect(unread.interaction('antikythera')['read_at'], isNull);
    expect(unread.interaction('antikythera')['saved'], true);
    final restoredUnread = await restored.initialize();
    expect(restoredUnread.interaction('antikythera')['read_at'], isNull);
    await repository.synchronize();
    expect(network.calls, 0);
    expect(await local.pending(), isEmpty);
    expect((await local.read('snapshot'))!['profile']['id'], 'real-user');
    expect((await repository.exportAccount())['demo'], true);
    await repository.logout();
    expect(repository.demoMode, false);
    expect((await local.read('demo_session'))!['active'], false);
    await repository.enterDemo();
    expect(
      (await repository.cached()).interaction('antikythera')['saved'],
      true,
    );
    await repository.deleteAccount();
    expect(await local.read('demo_snapshot'), isNull);
    expect((await local.read('snapshot'))!['profile']['id'], 'real-user');
    expect(network.calls, 0);
    await local.db.close();
  });
  testWidgets(
    'mobile login can open demo without credentials and reach the library',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = MargoRepository(LocalDatabase(WidgetDatabase()));
      appRouter.go('/');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            repositoryProvider.overrideWith((ref) async => repository),
            sessionProvider.overrideWith(() => ReadyController(repository)),
          ],
          child: const MargoApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Попробовать без аккаунта'));
      await tester.tap(find.text('Попробовать без аккаунта'));
      await tester.pumpAndSettle();
      expect(find.text('Антикитерский механизм'), findsOneWidget);
      expect(find.textContaining('Деморежим · Без аккаунта'), findsOneWidget);
      await tester.tap(find.text('Библиотека'));
      await tester.pumpAndSettle();
      expect(find.text('Моя библиотека.'), findsOneWidget);
      expect(find.text('Полярное сияние'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
