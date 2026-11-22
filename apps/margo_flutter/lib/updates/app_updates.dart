import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final appUpdatesProvider = Provider<AppUpdates>((ref) {
  final updates = AppUpdates();
  ref.onDispose(updates.dispose);
  return updates;
});

class AppVersion implements Comparable<AppVersion> {
  final List<int> parts;
  final int build;
  AppVersion(String version, this.build)
    : parts = version.split('.').map(int.parse).toList() {
    if (parts.length != 3 || parts.any((part) => part < 0) || build < 1) {
      throw const FormatException('Invalid version');
    }
  }

  @override
  int compareTo(AppVersion other) {
    for (var i = 0; i < 3; i++) {
      final result = parts[i].compareTo(other.parts[i]);
      if (result != 0) return result;
    }
    return build.compareTo(other.build);
  }
}

class AppRelease {
  final String version;
  final int build;
  final Uri url;
  final String checksum;
  final int size;
  final String notes;

  AppRelease.fromJson(Map<String, dynamic> json, Uri manifest, String platform)
    : version = json['version'] as String,
      build = json['build'] as int,
      url = manifest.resolve(json['url'] as String),
      checksum = json['sha256'] as String,
      size = json['size'] as int,
      notes = json['notes'] as String? ?? '' {
    AppVersion(version, build);
    // Updates can execute code: only HTTPS files on the configured origin.
    if (url.scheme != 'https' ||
        url.origin != manifest.origin ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment ||
        !url.path.startsWith('/updates/') ||
        !url.path.endsWith(platform == 'windows' ? '.exe' : '.apk') ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(checksum) ||
        size <= 0 ||
        size > 512 * 1024 * 1024) {
      throw const FormatException('Invalid update manifest');
    }
  }
}

enum UpdatePhase { idle, checking, downloading, ready, installing, failed }

class AppUpdates extends ChangeNotifier {
  static const channel = MethodChannel('dev.thoth.app/updates');
  final Dio dio;
  final String platform;
  final Uri manifest;
  final Future<PackageInfo> Function() packageInfo;
  final Future<Directory> Function() cacheDirectory;
  final Future<void> Function(File)? installer;
  UpdatePhase phase = UpdatePhase.idle;
  AppRelease? release;
  File? _file;
  String? currentVersion;
  String? error;
  double progress = 0;
  DateTime? _lastCheck;
  bool _disposed = false;
  CancelToken? _cancel;

  AppUpdates({
    Dio? dio,
    String? platform,
    Uri? manifest,
    Future<PackageInfo> Function()? packageInfo,
    Future<Directory> Function()? cacheDirectory,
    this.installer,
  }) : dio = dio ?? Dio(),
       platform = platform ?? Platform.operatingSystem,
       manifest =
           manifest ??
           Uri.parse(
             const String.fromEnvironment(
               'UPDATE_MANIFEST_URL',
               defaultValue:
                   'https://margo.invalid/updates/latest.json',
             ),
           ),
       packageInfo = packageInfo ?? PackageInfo.fromPlatform,
       cacheDirectory = cacheDirectory ?? getTemporaryDirectory {
    this.dio.options.connectTimeout = const Duration(seconds: 15);
  }

  bool get busy =>
      phase == UpdatePhase.checking ||
      phase == UpdatePhase.downloading ||
      phase == UpdatePhase.installing;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<bool> _verified(File file, AppRelease update) async =>
      await file.exists() &&
      await file.length() == update.size &&
      (await sha256.bind(file.openRead()).first).toString() == update.checksum;

  Future<void> check({bool force = false}) async {
    if (_disposed || busy || !['windows', 'android'].contains(platform)) return;
    if (!force &&
        _lastCheck != null &&
        DateTime.now().difference(_lastCheck!) < const Duration(hours: 1)) {
      return;
    }
    _lastCheck = DateTime.now();
    error = null;
    phase = UpdatePhase.checking;
    _notify();
    _cancel = CancelToken();
    try {
      if (manifest.scheme != 'https' || manifest.userInfo.isNotEmpty) {
        throw const FormatException('HTTPS update source required');
      }
      final info = await packageInfo();
      currentVersion = '${info.version}+${info.buildNumber}';
      final current = AppVersion(info.version, int.parse(info.buildNumber));
      final response = await dio.get<String>(
        manifest.toString(),
        cancelToken: _cancel,
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: false,
          receiveTimeout: const Duration(seconds: 20),
          sendTimeout: const Duration(seconds: 20),
          headers: {'Cache-Control': 'no-cache'},
        ),
      );
      final body = response.data!;
      if (body.length > 65536) {
        throw const FormatException('Manifest too large');
      }
      final data = (jsonDecode(body) as Map<String, dynamic>)[platform];
      if (data == null) {
        release = null;
        phase = UpdatePhase.idle;
        return;
      }
      final update = AppRelease.fromJson(
        data as Map<String, dynamic>,
        manifest,
        platform,
      );
      final candidate = AppVersion(update.version, update.build);
      if (candidate.compareTo(current) <= 0 ||
          (platform == 'android' && candidate.build <= current.build)) {
        release = null;
        phase = UpdatePhase.idle;
        return;
      }
      release = update;
      phase = UpdatePhase.downloading;
      progress = 0;
      _notify();
      final directory = Directory(
        p.join((await cacheDirectory()).path, 'margo-updates'),
      );
      await directory.create(recursive: true);
      final file = File(
        p.join(
          directory.path,
          '${update.checksum}.${platform == 'windows' ? 'exe' : 'apk'}',
        ),
      );
      if (!await _verified(file, update)) {
        // Only updater-owned cache files, never user data.
        await for (final entry in directory.list()) {
          if (entry is File) await entry.delete();
        }
        final partial = File('${file.path}.part');
        try {
          await dio.download(
            update.url.toString(),
            partial.path,
            cancelToken: _cancel,
            options: Options(
              followRedirects: false,
              receiveTimeout: const Duration(minutes: 2),
            ),
            onReceiveProgress: (received, total) {
              if (received > update.size ||
                  (total > 0 && total != update.size)) {
                _cancel?.cancel('Unexpected update size');
              }
              progress = (received / update.size).clamp(0, 1);
              _notify();
            },
          );
          if (!await _verified(partial, update)) {
            throw const FormatException('Update checksum mismatch');
          }
          await partial.rename(file.path);
        } finally {
          if (await partial.exists()) await partial.delete();
        }
      }
      _file = file;
      progress = 1;
      phase = UpdatePhase.ready;
    } catch (_) {
      error = 'Не удалось проверить или загрузить обновление. Проверьте соединение и повторите.';
      phase = UpdatePhase.failed;
    } finally {
      _notify();
    }
  }

  Future<void> install() async {
    if (_disposed ||
        phase != UpdatePhase.ready ||
        _file == null ||
        release == null) {
      return;
    }
    phase = UpdatePhase.installing;
    error = null;
    _notify();
    try {
      if (!await _verified(_file!, release!)) {
        throw const FormatException('Update checksum mismatch');
      }
      if (installer != null) {
        await installer!(_file!);
      } else if (platform == 'android') {
        final result = await channel.invokeMethod<String>('install', {
          'path': _file!.path,
        });
        if (result == 'permission') {
          error = 'Разрешите установку обновлений MARGO в открывшихся настройках, вернитесь и нажмите «Установить обновление» ещё раз.';
        }
      } else if (platform == 'windows') {
        await Process.start(_file!.path, [
          '/SP-',
          '/NORESTART',
          '/CLOSEAPPLICATIONS',
          '/DIR=${p.dirname(Platform.resolvedExecutable)}',
        ], mode: ProcessStartMode.detached);
      }
    } catch (_) {
      error = 'Не удалось открыть установщик. Повторите установку или проверку обновлений.';
    } finally {
      phase = UpdatePhase.ready;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cancel?.cancel();
    dio.close(force: true);
    super.dispose();
  }
}
