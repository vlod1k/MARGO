import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/repository.dart';
import '../data/local_database.dart';

final repositoryProvider = FutureProvider<MargoRepository>(
  (ref) async => MargoRepository(await LocalDatabase.open()),
);
final sessionProvider = AsyncNotifierProvider<SessionController, AppData>(
  SessionController.new,
);

class SessionController extends AsyncNotifier<AppData> {
  late MargoRepository repository;
  int _epoch = 0;
  bool _refreshing = false;
  bool _refreshAgain = false;
  @override
  Future<AppData> build() async {
    repository = await ref.watch(repositoryProvider.future);
    final data = await repository.initialize();
    final timer = Timer.periodic(const Duration(seconds: 45), (_) => refresh());
    ref.onDispose(timer.cancel);
    return data;
  }

  void _publish(AppData data, int ticket) {
    if (ref.mounted && ticket == _epoch) state = AsyncData(data);
  }

  Future<void> refresh() async {
    if (!ref.mounted || state.asData == null) return;
    if (_refreshing) {
      _refreshAgain = true;
      return;
    }
    _refreshing = true;
    final ticket = _epoch;
    try {
      _publish(await repository.synchronize(), ticket);
    } catch (e) {
      if (ref.mounted && ticket == _epoch) {
        _publish(await repository.cached(message: apiError(e)), ticket);
      }
    } finally {
      _refreshing = false;
      if (_refreshAgain && ref.mounted) {
        _refreshAgain = false;
        unawaited(refresh());
      }
    }
  }

  Future<void> authenticate(
    String email,
    String password, {
    String? name,
  }) async {
    final ticket = ++_epoch;
    _publish(
      await repository.authenticate(email, password, name: name),
      ticket,
    );
  }

  Future<void> act(String id, String field, dynamic value) async {
    final ticket = ++_epoch;
    _publish(await repository.act(id, field, value), ticket);
    if (ref.mounted && ticket == _epoch) unawaited(refresh());
  }

  Future<void> enterDemo() async {
    final ticket = ++_epoch;
    _publish(await repository.enterDemo(), ticket);
  }

  Future<void> preferences(Json profile) async {
    final ticket = ++_epoch;
    _publish(await repository.preferences(profile), ticket);
  }

  Future<void> logout() async {
    final ticket = ++_epoch;
    await repository.logout();
    _publish(const AppData(), ticket);
  }

  Future<void> deleteAccount() async {
    final ticket = ++_epoch;
    await repository.deleteAccount();
    _publish(const AppData(), ticket);
  }
}
