import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:margo/app/app_fonts.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  late Uint8List font;

  setUpAll(() async {
    final asset = await rootBundle.load('fonts/MaterialIcons-Regular.otf');
    font = Uint8List.sublistView(asset);
  });

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('margo-fonts-');
  });

  tearDown(() async {
    // These files belong to the temporary folder created by this test.
    await for (final entry in folder.list()) {
      await entry.delete();
    }
    await folder.delete();
  });

  test(
    'folder reload selects the newest usable font and handles removal',
    () async {
      final store = AppFontStore(folder, useImportedFont: false);
      expect(await store.load(), isNull);

      final older = await File(p.join(folder.path, 'older.OTF'))
          .writeAsBytes(font);
      final newer = await File(p.join(folder.path, 'newer.otf'))
          .writeAsBytes(font);
      final broken = await File(p.join(folder.path, 'broken.ttf'))
          .writeAsString('not a font');
      await older.setLastModified(DateTime(2020));
      await newer.setLastModified(DateTime(2021));
      await broken.setLastModified(DateTime(2022));

      final loaded = await store.load();
      expect(loaded?.fileName, 'newer.otf');
      expect(await store.load(), loaded);
      await newer.delete();
      expect((await store.load())?.fileName, 'older.OTF');
      await older.delete();
      expect(await store.load(), isNull);
    },
  );

  test(
    'failed import keeps the prior font and reset restores the default',
    () async {
      final store = AppFontStore(folder, useImportedFont: true);
      await store.importFont(XFile.fromData(font, name: 'valid.otf'));
      final loaded = await store.load();
      expect(loaded, isNotNull);

      await expectLater(
        store.importFont(XFile.fromData(Uint8List(12), name: 'broken.ttf')),
        throwsFormatException,
      );
      expect(await store.load(), loaded);

      await store.resetImport();
      expect(await store.load(), isNull);
    },
  );
}
