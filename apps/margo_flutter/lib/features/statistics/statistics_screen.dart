import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../app/theme.dart';
import '../../app/widgets.dart';
import '../../data/models.dart';
import '../../sync/controller.dart';

class StatisticsScreen extends ConsumerWidget {
  const StatisticsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(sessionProvider).asData!.value;
    final read = data.interactions.where((i) => i['read_at'] != null).toList();
    final counts = <String, int>{};
    final dates = <String>{};
    final location = tz.getLocation(data.profile!['timezone'] as String);
    for (final i in read) {
      final article = data.articles
          .where((a) => a['id'] == i['article_id'])
          .firstOrNull;
      if (article != null) {
        for (final t in (article['topics'] as Map).keys) {
          counts[t as String] = (counts[t] ?? 0) + 1;
        }
      }
      final d = tz.TZDateTime.from(
        DateTime.parse(i['read_at'] as String),
        location,
      );
      dates.add('${d.year}-${d.month}-${d.day}');
    }
    final now = tz.TZDateTime.now(location);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PageHeading(
          eyebrow: 'ЛЮБОПЫТСТВО В ЦИФРАХ',
          title: 'Каждый день — чуть больше.',
          description:
              'Маленькие шаги к большому миру. Без гонки за результатами.',
        ),
        LayoutBuilder(
          builder: (context, size) {
            final width = size.maxWidth > 700
                ? (size.maxWidth - 32) / 3
                : size.maxWidth;
            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children:
                  [
                        (read.length, 'статей прочитано', Icons.menu_book),
                        (
                          counts.length,
                          'направлений изучено',
                          Icons.auto_awesome_outlined,
                        ),
                        (
                          dates.length,
                          'дней с открытиями',
                          Icons.wb_sunny_outlined,
                        ),
                      ]
                      .map(
                        (s) => SizedBox(
                          width: width,
                          child: Card(
                            margin: EdgeInsets.zero,
                            child: Padding(
                              padding: const EdgeInsets.all(25),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(s.$3, color: gold),
                                  const SizedBox(height: 18),
                                  Text(
                                    '${s.$1}',
                                    style: const TextStyle(
                                      fontSize: 43,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  Text(
                                    s.$2,
                                    style: const TextStyle(color: Colors.grey),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      )
                      .toList(),
            );
          },
        ),
        const SizedBox(height: 26),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(27),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Календарь любопытства',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 7),
                const Text(
                  'Последние 28 дней · отмеченные прочитанными статьи',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 23),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: List.generate(28, (i) {
                    final d = tz.TZDateTime(
                      location,
                      now.year,
                      now.month,
                      now.day - 27 + i,
                    );
                    final active = dates.contains(
                      '${d.year}-${d.month}-${d.day}',
                    );
                    return Tooltip(
                      message:
                          '${d.day}.${d.month}.${d.year}${active ? ' · есть открытие' : ''}',
                      child: Container(
                        width: 39,
                        height: 39,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: active
                              ? gold
                              : Theme.of(context).scaffoldBackgroundColor,
                          borderRadius: BorderRadius.circular(12),
                          border: i == 27 ? Border.all(color: gold) : null,
                        ),
                        child: Text(
                          '${d.day}',
                          style: TextStyle(
                            fontSize: 12,
                            color: active ? ink : Colors.grey,
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 25),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(27),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Горизонты знаний',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 20),
                if (counts.isEmpty)
                  const Text(
                    'Прочитайте первую статью — и здесь появятся ваши горизонты.',
                    style: TextStyle(color: Colors.grey),
                  )
                else
                  ...counts.entries.map(
                    (e) => Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(child: Text(topicNames[e.key] ?? e.key)),
                              Text(
                                '${e.value}',
                                style: const TextStyle(color: gold),
                              ),
                            ],
                          ),
                          const SizedBox(height: 9),
                          LinearProgressIndicator(
                            value: e.value / read.length,
                            color: gold,
                            backgroundColor: Theme.of(context)
                                .scaffoldBackgroundColor,
                            minHeight: 4,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
