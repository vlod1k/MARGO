import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';

import 'local_database.dart';
import 'models.dart';
import 'demo_catalog.dart';

import 'package:timezone/timezone.dart' as tz;

class MargoRepository {
  static const _configuredEndpoint = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://margo.invalid',
  );

  final LocalDatabase local;
  final FlutterSecureStorage secure;
  final Lock _lock = Lock();
  String? token;
  bool demoMode = false;
  final String endpoint;
  final Dio dio = Dio();
  MargoRepository(this.local, {this.secure = const FlutterSecureStorage()})
    : endpoint = validateEndpoint(_configuredEndpoint) {
    _configure();
  }
  void _configure() {
    dio.options = BaseOptions(
      baseUrl: endpoint,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      followRedirects: false,
      headers: {if (token != null) 'Authorization': 'Bearer $token'},
    );
  }

  Future<AppData> initialize() async {
    if ((await local.read('demo_session'))?['active'] == true) {
      demoMode = true;
      return cached();
    }
    token = await secure.read(key: 'thoth_token');
    if (token == null) {
      await clearLocal();
      return const AppData();
    }
    final accountServer = await local.read('account_server');
    final previousEndpoint =
        accountServer?['endpoint'] ??
        (await local.read('settings'))?['endpoint'];
    // Session tokens and queued changes belong to the server that issued them.
    if (previousEndpoint != endpoint) {
      await clearLocal();
      return const AppData(message: 'Адрес сервера изменился. Войдите снова.');
    }
    if (accountServer == null) {
      await local.write('account_server', {'endpoint': endpoint});
    }
    _configure();
    final accountSnapshot = await local.read('snapshot') ?? {};
    if (accountSnapshot['profile'] == null) return synchronize();
    return AppData(
      snapshot: accountSnapshot,
      pending: (await local.pending()).length,
    );
  }

  static String validateEndpoint(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !['https', 'http'].contains(uri.scheme)) {
      throw const FormatException(
        'Укажите адрес сервера, например https://margo.example.com',
      );
    }
    if (uri.scheme != 'https' &&
        !['127.0.0.1', 'localhost', '10.0.2.2', '::1'].contains(uri.host)) {
      throw const FormatException(
        'Для удалённого сервера требуется HTTPS. HTTP разрешён только для локальной разработки.',
      );
    }
    if (uri.path.isNotEmpty && uri.path != '/') {
      throw const FormatException('Укажите адрес без пути /api.');
    }
    return input.trim().replaceFirst(RegExp(r'/+$'), '');
  }

  Future<AppData> authenticate(String email, String password, {String? name}) =>
      _lock.synchronized(() async {
        if (demoMode) throw StateError('Сначала выйдите из деморежима.');
        final response = await dio.post(
          name == null ? '/api/auth/login' : '/api/auth/register',
          data: {'email': email.trim(), 'password': password, 'name': ?name},
        );
        final nextToken = (response.data as Map)['access_token'] as String;
        final profile = Map<String, dynamic>.from(
          (await dio.get(
                '/api/auth/me',
                options: Options(
                  headers: {'Authorization': 'Bearer $nextToken'},
                ),
              )).data
              as Map,
        );
        await clearLocal();
        await local.restoreAccount(endpoint, {
          'profile': profile,
          'articles': [],
          'interactions': [],
          'history': [],
        }, overlay);
        await secure.write(key: 'thoth_token', value: nextToken);
        token = nextToken;
        _configure();
        return _synchronize();
      });

  Future<AppData> cached({String? message}) async => AppData(
    snapshot: await local.read(demoMode ? 'demo_snapshot' : 'snapshot') ?? {},
    pending: demoMode ? 0 : (await local.pending()).length,
    message: message,
  );

  Future<void> requestPasswordReset(String email) async {
    await dio.post(
      '/api/auth/password/reset/request',
      data: {'email': email.trim()},
    );
  }

  Future<void> confirmPasswordReset(
    String email,
    String code,
    String password,
  ) async {
    await dio.post(
      '/api/auth/password/reset/confirm',
      data: {
        'email': email.trim().toLowerCase(),
        'token': code.trim(),
        'new_password': password,
      },
    );
  }

  Future<void> changePassword(String current, String next) =>
      _lock.synchronized(() async {
        if (demoMode || token == null) {
          throw StateError('Сначала войдите в аккаунт.');
        }
        await dio.post(
          '/api/auth/password/change',
          data: {'current_password': current, 'new_password': next},
        );
      });

  Future<void> logoutOthers() => _lock.synchronized(() async {
    if (demoMode || token == null) {
      throw StateError('Сначала войдите в аккаунт.');
    }
    await dio.post('/api/auth/logout-others');
  });
  Future<AppData> enterDemo() => _lock.synchronized(() async {
    final snapshot = await local.read('demo_snapshot') ?? createDemoSnapshot();
    await local.write('demo_snapshot', snapshot);
    await local.write('demo_session', {'active': true});
    demoMode = true;
    return cached();
  });
  static Json clone(Json map) => jsonDecode(jsonEncode(map)) as Json;
  static Json overlay(Json snapshot, Json op) {
    final next = clone(snapshot);
    final list = (next['interactions'] as List?) ?? <dynamic>[];
    next['interactions'] = list;
    final item = list.cast<Json>().firstWhere(
      (i) => i['article_id'] == op['article_id'],
      orElse: () {
        final i = <String, dynamic>{
          'article_id': op['article_id'],
          'saved': false,
          'feedback': null,
          'field_versions': <String, dynamic>{},
        };
        list.add(i);
        return i;
      },
    );
    if (op['field'] == 'read') {
      item['read_at'] = op['value'] == true
          ? item['read_at'] ??
                op['read_at'] ??
                DateTime.now().toUtc().toIso8601String()
          : null;
    } else {
      item[op['field'] as String] = op['value'];
    }
    final versions = Map<String, dynamic>.from(
      item['field_versions'] as Map? ?? {},
    );
    versions[op['field'] as String] = (op['base_version'] as int) + 1;
    item['field_versions'] = versions;
    return next;
  }

  Future<AppData> act(String article, String field, dynamic value) =>
      _lock.synchronized(() async {
        final snapshot =
            await local.read(demoMode ? 'demo_snapshot' : 'snapshot') ?? {};
        final current = AppData(snapshot: snapshot).interaction(article);
        final versions = current['field_versions'] as Map? ?? {};
        final op = <String, dynamic>{
          'operation_id': const Uuid().v4(),
          'article_id': article,
          'field': field,
          'value': value,
          'base_version': versions[field] ?? 0,
          if (field == 'read' && value == true)
            'read_at': DateTime.now().toUtc().toIso8601String(),
        };
        final next = overlay(snapshot, op);
        if (demoMode) {
          await local.write('demo_snapshot', updateDemoWeights(next));
          return cached(message: 'Изменение сохранено локально');
        }
        if (token == null || snapshot['profile'] == null) {
          throw StateError('Сначала войдите в аккаунт.');
        }
        await local.enqueue(op, next);
        return AppData(
          snapshot: next,
          pending: (await local.pending()).length,
          message: 'Действие сохранено на устройстве',
        );
      });
  Future<AppData> synchronize() => _lock.synchronized(_synchronize);
  Future<AppData> _synchronize() async {
    if (demoMode) return cached();
    if (token == null) return const AppData();
    try {
      var conflicts = 0;
      do {
        final queue = await local.pending();
        final sent = queue.take(100).toList();
        final response = await dio.post(
          '/api/sync/operations',
          data: {'operations': sent},
        );
        final server = Map<String, dynamic>.from(response.data as Map);
        final old = await local.read('snapshot') ?? {};
        var next = <String, dynamic>{
          ...server,
          'today': old['today'],
          'catalog_empty': old['catalog_empty'],
        };
        next.remove('results');
        final results = (server['results'] as List).cast<Json>();
        conflicts += results.where((r) => r['status'] == 'conflict').length;
        final accepted = results
            .map((r) => r['operation_id'] as String)
            .toList();
        final expected = sent.map((op) => op['operation_id']).toSet();
        if (accepted.length != expected.length ||
            accepted.toSet().length != expected.length ||
            !accepted.every(expected.contains) ||
            results.any(
              (r) => !['applied', 'conflict'].contains(r['status']),
            )) {
          throw const FormatException(
            'Сервер не подтвердил все действия. Очередь сохранена; повторите синхронизацию позже.',
          );
        }
        final remaining = queue.where(
          (op) => !accepted.contains(op['operation_id']),
        );
        for (final op in remaining) {
          next = overlay(next, op);
        }
        await local.accept(accepted, next);
      } while ((await local.pending()).isNotEmpty);
      var snapshot = await local.read('snapshot') ?? {};
      try {
        final response = await dio.get('/api/recommendations/today');
        final recommendation = Map<String, dynamic>.from(response.data as Map);
        final catalog = recommendation.remove('catalog');
        final article = Map<String, dynamic>.from(
          recommendation['article'] as Map,
        );
        snapshot = {
          ...snapshot,
          'today': recommendation,
          'catalog_empty': null,
          if (catalog is Map) 'catalog': catalog,
          'articles': [
            ...(snapshot['articles'] as List? ?? []).where(
              (a) => a['id'] != article['id'],
            ),
            article,
          ],
          'history': [
            recommendation,
            ...(snapshot['history'] as List? ?? []).where(
              (h) => h['date'] != recommendation['date'],
            ),
          ],
        };
        await local.write('snapshot', snapshot);
      } on DioException catch (e) {
        final detail = e.response?.data is Map
            ? (e.response!.data as Map)['detail']
            : null;
        final exhausted =
            e.response?.statusCode == 404 &&
            detail is Map &&
            ['catalog_exhausted', 'catalog_empty'].contains(detail['code']);
        if (!exhausted && e.response?.statusCode != 409) {
          rethrow;
        }
        snapshot = {
          ...snapshot,
          'today': null,
          'catalog_empty': exhausted ? detail : null,
          if (exhausted) 'catalog': detail['inventory'],
        };
        await local.write('snapshot', snapshot);
      }
      return AppData(
        snapshot: snapshot,
        online: true,
        message: conflicts > 0
            ? '$conflicts изменений конфликтовали с другим устройством. Принята серверная версия.'
            : null,
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        await clearLocal();
        return const AppData(
          message: 'Сессия отозвана или истекла. Войдите снова. Неотправленные действия сохранены для вашего аккаунта.',
        );
      }
      if (e.response != null) {
        return cached(message: apiError(e));
      }
      return cached(
        message: 'Нет связи с сервером. Показаны загруженные данные.',
      );
    }
  }

  Future<AppData> preferences(Json profile) => _lock.synchronized(() async {
    if (demoMode) {
      try {
        tz.getLocation(profile['timezone'] as String);
      } catch (_) {
        throw const FormatException('Неизвестный часовой пояс IANA');
      }
      final snapshot = clone(
        await local.read('demo_snapshot') ?? createDemoSnapshot(),
      );
      snapshot['profile'] = {
        ...snapshot['profile'] as Json,
        ...profile,
        'language': 'ru',
        'notifications': false,
        'version': (profile['version'] as int) + 1,
      };
      await local.write('demo_snapshot', updateDemoWeights(snapshot));
      return cached();
    }
    late Json confirmed;
    try {
      confirmed = Map<String, dynamic>.from(
        (await dio.patch('/api/preferences', data: profile)).data as Map,
      );
    } on DioException catch (e) {
      if (e.response?.statusCode != 401) rethrow;
      await clearLocal();
      return const AppData(
        message: 'Сессия истекла или отозвана. Войдите снова. Неотправленные действия сохранены для вашего аккаунта.',
      );
    }
    final snapshot = await local.read('snapshot') ?? {};
    await local.write('snapshot', {...snapshot, 'profile': confirmed});
    return _synchronize();
  });

  Future<void> clearLocal({bool preservePending = true}) async {
    final accountEndpoint =
        (await local.read('account_server'))?['endpoint'] ??
        (await local.read('settings'))?['endpoint'] ??
        endpoint;
    // Archive before deleting the token: a crash must not orphan pending writes.
    await local.clearAccount(
      preserveForEndpoint: preservePending ? accountEndpoint as String : null,
    );
    token = null;
    await secure.delete(key: 'thoth_token');
    _configure();
  }

  Future<void> logout() => _lock.synchronized(() async {
    if (demoMode) {
      await local.write('demo_session', {'active': false});
      demoMode = false;
      return;
    }
    // Never silently lose pending actions on an explicit logout.
    if ((await local.pending()).isNotEmpty) {
      await _synchronize();
      if ((await local.pending()).isNotEmpty) {
        throw StateError('Сначала синхронизируйте ожидающие действия.');
      }
    }
    if (token == null) return;
    try {
      await dio.post('/api/auth/logout');
    } on DioException catch (e) {
      if (e.response?.statusCode != 401) rethrow;
    }
    await clearLocal();
  });

  Future<void> deleteAccount() => _lock.synchronized(() async {
    if (demoMode) {
      await local.db.transaction((txn) async {
        await txn.delete(
          'cache',
          where: 'key IN (?, ?)',
          whereArgs: ['demo_snapshot', 'demo_session'],
        );
      });
      demoMode = false;
      return;
    }
    try {
      await dio.delete('/api/account');
    } on DioException catch (e) {
      if (e.response?.statusCode != 401) rethrow;
      await clearLocal();
      return;
    }
    await clearLocal(preservePending: false);
  });

  Future<Json> exportAccount() => _lock.synchronized(
    () async => demoMode
        ? clone((await cached()).snapshot)
        : Map<String, dynamic>.from(
            (await dio.get('/api/account/export')).data as Map,
          ),
  );
}

String apiError(Object error) {
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map && data['detail'] is String) {
      return data['detail'] as String;
    }
    if (error.response?.statusCode == 422) {
      return 'Проверьте заполненные поля: email, пароль (от 8 символов), часовой пояс.';
    }
    return 'Сервер недоступен. Проверьте подключение к интернету.';
  }
  if (error is FormatException) return error.message;
  if (error is StateError) return error.message;
  return 'Не удалось завершить действие. Попробуйте ещё раз.';
}
