import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final appFontStoreProvider = FutureProvider<AppFontStore>(
  retry: (_, _) => null,
  (ref) async {
    final support = await getApplicationSupportDirectory();
    return AppFontStore(
      Directory(p.join(support.path, 'fonts')),
      useImportedFont: Platform.isAndroid,
    );
  },
);

typedef AppFont = ({String family, String? fileName, bool headlinesOnly});

final appFontProvider = FutureProvider<AppFont?>(retry: (_, _) => null, (
  ref,
) async {
  final store = await ref.watch(appFontStoreProvider.future);
  return store.load();
});

class AppFontStore {
  AppFontStore(this.directory, {required this.useImportedFont});

  final Directory directory;
  final bool useImportedFont;
  static const _maxBytes = 32 * 1024 * 1024;
  static int _nextFamily = 0;
  final _fonts = <(String, DateTime, int), AppFont>{};

  File get _imported => File(p.join(directory.path, 'imported-font'));

  static bool _supported(String name) =>
      const {'.ttf', '.otf'}.contains(p.extension(name).toLowerCase());

  Future<AppFont?> load() async {
    await directory.create(recursive: true);
    if (useImportedFont) {
      return _loadFile(_imported);
    }

    final fonts = <({File file, DateTime modified})>[];
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File || !_supported(entry.path)) continue;
      final stat = await entry.stat();
      if (stat.type == FileSystemEntityType.file) {
        fonts.add((file: entry, modified: stat.modified));
      }
    }
    fonts.sort((a, b) {
      final order = b.modified.compareTo(a.modified);
      return order == 0 ? a.file.path.compareTo(b.file.path) : order;
    });
    for (final candidate in fonts) {
      final font = await _loadFile(candidate.file);
      if (font != null) return font;
    }
    return null;
  }

  Future<AppFont?> _loadFile(File file) async {
    try {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file || stat.size > _maxBytes) {
        return null;
      }
      final key = (file.path, stat.modified, stat.size);
      final cached = _fonts[key];
      if (cached != null) return cached;

      final input = await file.open();
      final Uint8List bytes;
      try {
        bytes = await input.read(stat.size + 1);
      } finally {
        await input.close();
      }
      final headlinesOnly = _checkFont(bytes);
      final family = 'MargoCustomFont${_nextFamily++}';
      await ui.loadFontFromList(bytes, fontFamily: family);
      return _fonts[key] = (
        family: family,
        fileName: useImportedFont ? null : p.basename(file.path),
        headlinesOnly: headlinesOnly,
      );
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> importFont(XFile source) async {
    if (await source.length() > _maxBytes) {
      throw const FormatException('Размер шрифта должен быть не больше 32 МБ.');
    }
    final bytes = await source.readAsBytes();
    _checkFont(bytes);

    final staging = await directory.createTemp('.font-');
    final copy = File(p.join(staging.path, 'font'));
    try {
      await copy.writeAsBytes(bytes, flush: true);
      await copy.rename(_imported.path);
      _fonts.removeWhere((key, _) => key.$1 == _imported.path);
    } finally {
      if (await copy.exists()) await copy.delete();
      await staging.delete();
    }
  }

  Future<void> resetImport() async {
    if (await _imported.exists()) await _imported.delete();
    _fonts.removeWhere((key, _) => key.$1 == _imported.path);
  }

  static bool _checkFont(Uint8List bytes) {
    if (bytes.length > _maxBytes) {
      throw const FormatException('Размер шрифта должен быть не больше 32 МБ.');
    }
    const invalid = FormatException(
      'Не удалось прочитать шрифт .ttf или .otf.',
    );
    if (bytes.length < 12) throw invalid;
    final data = ByteData.sublistView(bytes);
    final signature = data.getUint32(0);
    if (signature != 0x00010000 && signature != 0x4f54544f) throw invalid;
    final tables = data.getUint16(4);
    final directoryEnd = 12 + 16 * tables;
    if (directoryEnd > bytes.length) throw invalid;

    final tags = <String>{};
    var glyphCount = 0;
    var outlineBytes = 0;
    for (var entry = 12; entry < directoryEnd; entry += 16) {
      final offset = data.getUint32(entry + 8);
      final length = data.getUint32(entry + 12);
      if (offset < directoryEnd || offset + length > bytes.length) {
        throw invalid;
      }
      final tag = String.fromCharCodes(bytes, entry, entry + 4);
      tags.add(tag);
      if (tag == 'maxp' && length >= 6) glyphCount = data.getUint16(offset + 4);
      if (tag == 'glyf') outlineBytes = length;
    }
    if (!tags.containsAll(const {'head', 'cmap', 'maxp'}) ||
        !(tags.containsAll(const {'glyf', 'loca'}) ||
            tags.contains('CFF ') ||
            tags.contains('CFF2'))) {
      throw invalid;
    }
    // Large TrueType outlines cost more to rasterize at each UI text size.
    return glyphCount > 0 && outlineBytes >= 1024 * glyphCount;
  }
}
