import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:margo/updates/app_updates.dart';
import 'package:margo/updates/update_widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';

class UpdateAdapter implements HttpClientAdapter {
  Map<String, dynamic> manifest;
  final List<int> bytes;
  int requests = 0;
  int downloads = 0;
  UpdateAdapter(this.manifest, this.bytes);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    if (options.uri.path.endsWith('latest.json')) {
      return ResponseBody.fromString(jsonEncode(manifest), 200);
    }
    downloads++;
    return ResponseBody.fromBytes(
      bytes,
      200,
      headers: {
        Headers.contentLengthHeader: ['${bytes.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory cache;
  late UpdateAdapter adapter;
  late AppUpdates updates;
  var installs = 0;
  final bytes = utf8.encode('test application installer');
  final manifestUri = Uri.parse('https://example.com/updates/latest.json');
  Map<String, dynamic> entry() => {
    'version': '0.4.0',
    'build': 8,
    'url': 'MARGO.exe',
    'sha256': sha256.convert(bytes).toString(),
    'size': bytes.length,
  };

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('margo-updater-test-');
    adapter = UpdateAdapter({'windows': entry()}, bytes);
    installs = 0;
    updates = AppUpdates(
      dio: Dio()..httpClientAdapter = adapter,
      manifest: manifestUri,
      platform: 'windows',
      cacheDirectory: () async => cache,
      packageInfo: () async => PackageInfo(
        appName: 'MARGO',
        packageName: 'dev.thoth.thoth',
        version: '0.3.1',
        buildNumber: '7',
      ),
      installer: (_) async {
        installs++;
      },
    );
  });
  tearDown(() async {
    updates.dispose();
    await cache.delete(recursive: true);
  });

  test('numeric versions include build and compare 0.10 after 0.9', () {
    expect(
      AppVersion('0.10.0', 2).compareTo(AppVersion('0.9.9', 99)),
      greaterThan(0),
    );
    expect(
      AppVersion('0.4.0', 9).compareTo(AppVersion('0.4.0', 8)),
      greaterThan(0),
    );
  });
  test(
    'automatically downloads but installs only on request; throttles checks',
    () async {
      await updates.check();
      expect(updates.phase, UpdatePhase.ready);
      expect(installs, 0);
      expect(adapter.downloads, 1);
      await updates.check();
      expect(adapter.requests, 2);
      await updates.install();
      expect(installs, 1);
      await updates.check(force: true);
      expect(
        adapter.downloads,
        1,
        reason: 'Verified cached installer is reused',
      );
    },
  );
  test('refuses older versions', () async {
    adapter.manifest['windows']['version'] = '0.2.0';
    await updates.check();
    expect(updates.phase, UpdatePhase.idle);
    expect(adapter.downloads, 0);
  });
  test('missing platform is not an update', () async {
    adapter.manifest.clear();
    await updates.check();
    expect(updates.phase, UpdatePhase.idle);
    expect(updates.release, isNull);
  });
  test('bad checksum removes partial file and allows retry', () async {
    adapter.manifest['windows']['sha256'] = '0' * 64;
    await updates.check();
    expect(updates.phase, UpdatePhase.failed);
    expect(
      await cache.list(recursive: true).where((e) => e is File).isEmpty,
      isTrue,
    );
    adapter.manifest['windows'] = entry();
    await updates.check(force: true);
    expect(updates.phase, UpdatePhase.ready);
  });
  test('rechecks checksum before installation', () async {
    await updates.check();
    final file = await cache
        .list(recursive: true)
        .where((e) => e is File)
        .first;
    await File(file.path).writeAsString('tampered');
    await updates.install();
    expect(installs, 0);
    expect(updates.error, isNotNull);
  });
  test('rejects wrong download size', () async {
    adapter.manifest['windows']['size'] = bytes.length - 1;
    await updates.check();
    expect(updates.phase, UpdatePhase.failed);
    expect(installs, 0);
  });
  test(
    'rejects HTTP, other origins, paths outside updates and wrong extensions',
    () {
      for (final url in [
        'http://example.com/updates/a.exe',
        'https://evil.com/updates/a.exe',
        '/other/a.exe',
        '../a.exe',
        'a.apk',
        'a.exe?key=1',
      ]) {
        expect(
          () => AppRelease.fromJson(
            {...entry(), 'url': url},
            manifestUri,
            'windows',
          ),
          throwsFormatException,
        );
      }
    },
  );
  testWidgets('update actions fit a small phone with enlarged text', (
    tester,
  ) async {
    updates.release = AppRelease.fromJson(entry(), manifestUri, 'windows');
    updates.phase = UpdatePhase.ready;
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appUpdatesProvider.overrideWithValue(updates)],
        child: MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
              child: const SingleChildScrollView(child: UpdateStatus()),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Установить обновление'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
