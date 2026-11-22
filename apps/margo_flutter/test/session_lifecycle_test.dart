import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:margo/data/models.dart';
import 'package:margo/data/local_database.dart';
import 'package:margo/data/repository.dart';
import 'package:margo/sync/controller.dart';

class UnusedDatabase implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class DeferredRepository extends MargoRepository {
  DeferredRepository() : super(LocalDatabase(UnusedDatabase()));
  final initialized = Completer<AppData>();
  final response = Completer<AppData>();
  bool slowInit = false;
  int syncCalls = 0;
  AppData latest = const AppData(
    snapshot: {
      'profile': {'id': 'user'},
    },
  );
  @override
  Future<AppData> initialize() async => slowInit ? initialized.future : latest;
  @override
  Future<AppData> synchronize() {
    syncCalls++;
    return syncCalls == 1 ? response.future : Future.value(latest);
  }

  @override
  Future<void> logout() async {}
  @override
  Future<AppData> act(String id, String field, dynamic value) async {
    latest = AppData(
      snapshot: MargoRepository.overlay(latest.snapshot, {
        'article_id': id,
        'field': field,
        'value': value,
        'base_version': 0,
      }),
    );
    return latest;
  }
}

ProviderContainer createContainer(DeferredRepository repository) {
  final container = ProviderContainer(
    overrides: [repositoryProvider.overrideWith((ref) async => repository)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('late refresh cannot sign a user back in after logout', () async {
    final repo = DeferredRepository();
    final container = createContainer(repo);
    await container.read(sessionProvider.future);
    final controller = container.read(sessionProvider.notifier);
    final refresh = controller.refresh();
    await controller.logout();
    repo.response.complete(repo.latest);
    await refresh;
    expect(container.read(sessionProvider).asData!.value.signedIn, false);
  });
  test('app resume during initialization does not touch an uninitialized repository', () async {
    final repo = DeferredRepository()..slowInit = true;
    final container = createContainer(repo);
    final pending = container.read(sessionProvider.future);
    await container.read(sessionProvider.notifier).refresh();
    expect(repo.syncCalls, 0);
    repo.initialized.complete(repo.latest);
    await pending;
  });
  test('an action during refresh schedules a follow-up sync instead of losing freshness', () async {
    final repo = DeferredRepository();
    final container = createContainer(repo);
    await container.read(sessionProvider.future);
    final controller = container.read(sessionProvider.notifier);
    final refresh = controller.refresh();
    final old = repo.latest;
    await controller.act('a', 'saved', true);
    repo.response.complete(old);
    await refresh;
    await Future<void>.delayed(Duration.zero);
    expect(repo.syncCalls, 2);
    expect(
      container.read(sessionProvider).asData!.value.interaction('a')['saved'],
      true,
    );
  });
}
