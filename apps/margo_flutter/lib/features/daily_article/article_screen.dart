import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:url_launcher/url_launcher.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../app/widgets.dart';
import '../../data/models.dart';
import '../../sync/controller.dart';

class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(sessionProvider).asData!.value;
    final today = data.today;
    if (today == null) {
      final empty = data.snapshot['catalog_empty'] as Map?;
      final exhausted = empty != null;
      final language = empty?['language'] == 'en' ? 'английском' : 'русском';
      final inventory = empty?['inventory'] as Map?;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHeading(
            eyebrow: 'ОДИН ДЕНЬ. ОДНО ОТКРЫТИЕ.',
            title: 'Ваш мир становится больше.',
            description: exhausted
                ? 'Новых статей на $language языке пока нет.'
                : 'Новая статья появится после подключения к серверу.',
          ),
          Card(
            child: Padding(
              padding: EdgeInsets.all(
                MediaQuery.sizeOf(context).width < 600 ? 22 : 36,
              ),
              child: Column(
                children: [
                  const Icon(
                    Icons.auto_stories_outlined,
                    size: 40,
                    color: gold,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    exhausted
                        ? (empty['code'] == 'catalog_empty'
                              ? 'Каталог ещё наполняется'
                              : 'Вы просмотрели все доступные статьи')
                        : 'Загрузите первую статью',
                  ),
                  const SizedBox(height: 12),
                  Text(
                    exhausted
                        ? 'Повторов не будет. Проверьте обновления позже или вернитесь к сохранённым материалам в библиотеке.'
                        : 'Подключитесь к серверу и синхронизируйте приложение. Ранее загруженные карточки доступны в библиотеке.',
                  ),
                  if (inventory != null) ...[
                    const SizedBox(height: 12),
                    for (final entry in inventory.entries)
                      Text(
                        '${entry.key == 'ru' ? 'Русский' : 'Английский'}: новых ${entry.value['remaining']}, всего ${entry.value['available']}',
                      ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: () =>
                        ref.read(sessionProvider.notifier).refresh(),
                    child: const Text('Проверить статью дня'),
                  ),
                  if (exhausted) ...[
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () => context.go('/library'),
                      child: const Text('Открыть библиотеку'),
                    ),
                    TextButton(
                      onPressed: () => context.go('/profile'),
                      child: const Text('Выбрать язык в профиле'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      );
    }
    final location = tz.getLocation(data.profile!['timezone'] as String);
    final now = tz.TZDateTime.now(location);
    final actual =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final stale = today['date'] != actual;
    return ArticleView(
      article: today['article'] as Json,
      explanation: today['explanation'] as String,
      date: today['date'] as String,
      stale: stale,
      discovery: today['mode'] == 'discovery',
    );
  }
}

class ArticleScreen extends ConsumerWidget {
  final String id;
  const ArticleScreen({super.key, required this.id});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final articles = ref.watch(sessionProvider).asData!.value.articles;
    final article = articles.where((a) => a['id'] == id).firstOrNull;
    return article == null
        ? const Text(
            'Карточка не загружена на это устройство. Синхронизируйте библиотеку.',
          )
        : ArticleView(article: article);
  }
}

class ArticleView extends ConsumerWidget {
  final Json article;
  final String? explanation, date;
  final bool stale, discovery;
  const ArticleView({
    super.key,
    required this.article,
    this.explanation,
    this.date,
    this.stale = false,
    this.discovery = false,
  });
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(sessionProvider).asData!.value;
    final interaction = data.interaction(article['id'] as String);
    final saved = interaction['saved'] == true;
    final controller = ref.read(sessionProvider.notifier);
    Future<void> act(String field, dynamic value) =>
        controller.act(article['id'] as String, field, value);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: colors.onSurfaceVariant,
    );
    final parsedDate = DateTime.tryParse(date ?? '');
    final readingTime = '~ ${article['minutes']} мин';
    final dateLabel = parsedDate == null
        ? date
        : MaterialLocalizations.of(context).formatShortDate(parsedDate);
    final topics = (article['topics'] as Map).keys;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (date != null) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(
                avatar: Icon(
                  stale ? Icons.history : Icons.auto_awesome,
                  size: 16,
                  color: colors.primary,
                ),
                label: Text(
                  stale ? 'Последняя загруженная статья' : 'Статья дня',
                ),
                visualDensity: VisualDensity.compact,
              ),
              if (discovery)
                const Chip(
                  label: Text('Новые горизонты'),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        Semantics(
          header: true,
          child: Text(
            article['title'] as String,
            style: theme.textTheme.headlineLarge?.copyWith(
              fontSize: MediaQuery.sizeOf(context).width < 600 ? 34 : 48,
              height: 1.13,
              letterSpacing: -1.2,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          article['summary'] as String,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: colors.onSurfaceVariant,
            fontSize: 18,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 20),
        Text([readingTime, ?dateLabel].join(' · '), style: muted),
        const SizedBox(height: 10),
        Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: colors.surfaceContainerHighest,
              foregroundColor: colors.onSurfaceVariant,
              child: const Icon(Icons.language, size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Википедия', style: theme.textTheme.titleSmall),
            ),
          ],
        ),
        if (stale) ...[
          const SizedBox(height: 12),
          Text(
            'Это карточка за прошлую дату. Без связи с сервером новая рекомендация не назначается.',
            style: muted,
          ),
        ],
        if (article['id'] == 'antikythera') ...[
          const SizedBox(height: 24),
          const AspectRatio(aspectRatio: 1.8, child: MechanismArt()),
          const SizedBox(height: 8),
          Text(
            'Иллюстрация антикитерского механизма',
            textAlign: TextAlign.center,
            style: muted,
          ),
        ],
        const SizedBox(height: 20),
        const Divider(height: 1),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            TextButton.icon(
              onPressed: () async {
                final opened = await launchUrl(
                  Uri.parse(article['url'] as String),
                  mode: LaunchMode.externalApplication,
                );
                if (!opened && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Не удалось открыть браузер.'),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('Читать в Википедии'),
            ),
            TextButton.icon(
              onPressed: () => runUi(context, () => act('saved', !saved)),
              icon: Icon(
                saved ? Icons.bookmark : Icons.bookmark_border,
                size: 20,
              ),
              label: Text(saved ? 'Сохранено' : 'На потом'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Divider(height: 1),
        if (topics.isNotEmpty) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final topic in topics)
                Chip(
                  label: Text(topicNames[topic] ?? topic),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
        if (explanation != null) ...[
          const SizedBox(height: 20),
          Text('Почему эта статья?', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(explanation!.replaceAll('THOTH', 'MARGO'), style: muted),
        ],
        const SizedBox(height: 28),
        Text(
          'Вам интересно это открытие?',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Оценка уточняет будущие рекомендации. Её всегда можно изменить.',
          style: muted,
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 9,
          runSpacing: 9,
          children: feedbackNames.entries
              .map(
                (entry) => FilterChip(
                  selected: interaction['feedback'] == entry.key,
                  onSelected: (_) => runUi(
                    context,
                    () => act(
                      'feedback',
                      interaction['feedback'] == entry.key ? null : entry.key,
                    ),
                  ),
                  label: Text(entry.value),
                  avatar: Icon(switch (entry.key) {
                    'liked' => Icons.thumb_up_outlined,
                    'uninterested' => Icons.thumb_down_outlined,
                    'known' => Icons.check_circle_outline,
                    _ => Icons.school_outlined,
                  }, size: 17),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 18),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => runUi(
              context,
              () => act('read', interaction['read_at'] == null),
            ),
            icon: Icon(
              interaction['read_at'] != null
                  ? Icons.remove_done
                  : Icons.done_all,
              size: 18,
            ),
            label: Text(
              interaction['read_at'] != null
                  ? 'Снять отметку «Прочитано»'
                  : 'Я прочитал(а) статью',
            ),
          ),
        ),
        const Divider(height: 35),
        Text(
          ((article['attribution'] as Map?)?['notice'] as String? ??
                  'Источник — Википедия.')
              .replaceAll('THOTH', 'MARGO'),
          style: muted,
        ),
        Wrap(
          children: [
            TextButton(
              onPressed: () => launchUrl(
                Uri.parse(article['url'] as String),
                mode: LaunchMode.externalApplication,
              ),
              child: const Text('Источник', style: TextStyle(fontSize: 11)),
            ),
            if ((article['attribution'] as Map?)?['history'] != null)
              TextButton(
                onPressed: () => launchUrl(
                  Uri.parse(article['attribution']['history'] as String),
                  mode: LaunchMode.externalApplication,
                ),
                child: const Text(
                  'Авторы и история',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            if ((article['attribution'] as Map?)?['license'] != null)
              TextButton(
                onPressed: () => launchUrl(
                  Uri.parse(article['attribution']['license'] as String),
                  mode: LaunchMode.externalApplication,
                ),
                child: const Text('CC BY-SA', style: TextStyle(fontSize: 11)),
              ),
          ],
        ),
      ],
    );
  }
}
