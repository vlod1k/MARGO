import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_updates.dart';

class UpdateStatus extends ConsumerWidget {
  final bool compact;
  const UpdateStatus({super.key, this.compact = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final updates = ref.watch(appUpdatesProvider);
    return ListenableBuilder(
      listenable: updates,
      builder: (context, _) {
        if (compact && updates.release == null) return const SizedBox.shrink();
        final ready = updates.phase == UpdatePhase.ready;
        final downloading = updates.phase == UpdatePhase.downloading;
        final text = switch (updates.phase) {
          UpdatePhase.checking => 'Проверяем обновления…',
          UpdatePhase.downloading =>
            'Загружаем MARGO ${updates.release!.version} · ${(updates.progress * 100).round()}%',
          UpdatePhase.ready =>
            'MARGO ${updates.release!.version} готова к установке',
          UpdatePhase.installing => 'Открываем установщик…',
          UpdatePhase.failed => 'Обновление недоступно',
          UpdatePhase.idle =>
            updates.currentVersion == null
                ? 'Автоматическая проверка и загрузка новых версий'
                : 'Установлена актуальная версия ${updates.currentVersion}',
        };
        final content = Material(
          color: compact
              ? Theme.of(context).colorScheme.primaryContainer
              : Colors.transparent,
          child: Padding(
            padding: EdgeInsets.all(compact ? 12 : 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!compact) ...[
                  Text(
                    'Обновления приложения',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                ],
                Text(text),
                if (downloading) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: updates.progress),
                ],
                if (updates.error != null) Text(updates.error!),
                if (!compact || ready) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      if (ready)
                        FilledButton.icon(
                          onPressed: updates.install,
                          icon: const Icon(Icons.system_update),
                          label: const Text('Установить обновление'),
                        ),
                      if (!compact)
                        TextButton(
                          onPressed: updates.busy
                              ? null
                              : () => updates.check(force: true),
                          child: const Text('Проверить обновления'),
                        ),
                    ],
                  ),
                ],
                if (!compact) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'Новые версии загружаются автоматически. Установка запускается по кнопке; приложение может закрыться. На Android подтвердите установку в системном окне.',
                    style: TextStyle(fontSize: 12),
                  ),
                  if (updates.release?.notes.isNotEmpty == true) ...[
                    const SizedBox(height: 8),
                    Text(updates.release!.notes),
                  ],
                ],
              ],
            ),
          ),
        );
        return compact ? SafeArea(bottom: false, child: content) : content;
      },
    );
  }
}
