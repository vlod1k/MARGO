import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_fonts.dart';

class FontSettings extends ConsumerStatefulWidget {
  const FontSettings({super.key});

  @override
  ConsumerState<FontSettings> createState() => _FontSettingsState();
}

class _FontSettingsState extends ConsumerState<FontSettings> {
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Не удалось обновить шрифт.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = ref.watch(appFontStoreProvider).value;
    final font = ref.watch(appFontProvider);
    final loaded = font.value;
    final busy = _busy || font.isLoading || store == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Шрифт приложения', style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(
          loaded?.fileName ??
              (loaded == null ? 'Стандартный шрифт' : 'Пользовательский шрифт'),
        ),
        if (loaded?.headlinesOnly == true) ...[
          const SizedBox(height: 6),
          Text(
            'Шрифт применяется к крупным заголовкам, чтобы интерфейс работал плавнее.',
            style: theme.textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 6),
        Text(
          Platform.isAndroid
              ? 'Выберите файл .ttf или .otf, чтобы скопировать его в папку шрифтов MARGO.'
              : 'Положите файл .ttf или .otf в папку и нажмите «Обновить шрифт». Уберите файл из папки, чтобы вернуться к стандартному шрифту.',
          style: theme.textTheme.bodySmall,
        ),
        if (Platform.isWindows && store != null) ...[
          const SizedBox(height: 6),
          Text(store.directory.path, style: theme.textTheme.bodySmall),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (Platform.isWindows)
              OutlinedButton.icon(
                onPressed: busy
                    ? null
                    : () => _run(() async {
                        await store.directory.create(recursive: true);
                        await Process.start('explorer.exe', [
                          store.directory.path,
                        ]);
                      }),
                icon: const Icon(Icons.folder_open),
                label: const Text('Открыть папку'),
              ),
            if (Platform.isAndroid) ...[
              OutlinedButton.icon(
                onPressed: busy
                    ? null
                    : () => _run(() async {
                        final file = await openFile(
                          acceptedTypeGroups: const [
                            XTypeGroup(
                              label: 'Шрифты',
                              extensions: ['ttf', 'otf'],
                              mimeTypes: [
                                'font/ttf',
                                'font/otf',
                                'application/font-sfnt',
                                'application/x-font-ttf',
                                'application/x-font-otf',
                                'application/octet-stream',
                              ],
                            ),
                          ],
                        );
                        if (file == null || !mounted) return;
                        await store.importFont(file);
                        if (mounted) ref.invalidate(appFontProvider);
                      }),
                icon: const Icon(Icons.upload_file),
                label: const Text('Импортировать шрифт'),
              ),
              if (loaded != null)
                TextButton(
                  onPressed: busy
                      ? null
                      : () => _run(() async {
                          await store.resetImport();
                          if (mounted) ref.invalidate(appFontProvider);
                        }),
                  child: const Text('Вернуть стандартный шрифт'),
                ),
            ] else
              OutlinedButton.icon(
                onPressed: busy ? null : () => ref.invalidate(appFontProvider),
                icon: const Icon(Icons.refresh),
                label: const Text('Обновить шрифт'),
              ),
          ],
        ),
        if (_error != null || font.hasError)
          Text(
            _error ?? 'Папка шрифтов недоступна.',
            style: TextStyle(color: theme.colorScheme.error),
          ),
      ],
    );
  }
}
