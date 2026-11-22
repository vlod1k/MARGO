import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/widgets.dart';
import '../../app/theme.dart';
import '../../data/models.dart';
import '../../sync/controller.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});
  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  String search = '', filter = 'all', topic = 'all';
  Widget articleCard(Json article, AppData data) {
    final interaction = data.interaction(article['id'] as String);
    final saved = interaction['saved'] == true;
    final recommendation = data.history
        .where((h) => (h['article'] as Map)['id'] == article['id'])
        .firstOrNull;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/article/${article['id']}'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      topicNames[(article['topics'] as Map).keys.first] ?? '',
                      style: const TextStyle(fontSize: 10, color: gold),
                    ),
                  ),
                  IconButton(
                    tooltip: saved ? 'Убрать из сохранённого' : 'Сохранить',
                    onPressed: () => runUi(
                      context,
                      () => ref
                          .read(sessionProvider.notifier)
                          .act(article['id'] as String, 'saved', !saved),
                    ),
                    icon: Icon(
                      saved ? Icons.bookmark : Icons.bookmark_border,
                      color: gold,
                      size: 21,
                    ),
                  ),
                ],
              ),
              Text(
                article['title'] as String,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 13),
              Text(
                article['summary'] as String,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Text(
                    recommendation?['date'] as String? ??
                        (data.isDemo ? 'Демокарточка' : 'Сохранённое'),
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                  const Spacer(),
                  Text(
                    '${article['minutes']} мин',
                    style: const TextStyle(fontSize: 11, color: gold),
                  ),
                  const SizedBox(width: 10),
                  const Icon(Icons.arrow_forward, size: 17, color: gold),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(sessionProvider).asData!.value;
    final articles = data.articles.where((a) {
      final i = data.interaction(a['id'] as String);
      return (filter != 'saved' || i['saved'] == true) &&
          (filter != 'read' || i['read_at'] != null) &&
          (topic == 'all' || (a['topics'] as Map).containsKey(topic)) &&
          (a['title'] as String).toLowerCase().contains(search.toLowerCase());
    }).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PageHeading(
          eyebrow: 'ЗНАНИЯ, К КОТОРЫМ ХОЧЕТСЯ ВЕРНУТЬСЯ',
          title: 'Моя библиотека.',
          description:
              'Загруженные карточки остаются с вами даже без интернета.',
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children:
              {
                    'all': 'Все статьи',
                    'saved': 'Сохранённое',
                    'read': 'Прочитанное',
                  }.entries
                  .map(
                    (e) => ChoiceChip(
                      label: Text(e.value),
                      selected: filter == e.key,
                      onSelected: (_) => setState(() => filter = e.key),
                    ),
                  )
                  .toList(),
        ),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, size) => Wrap(
            spacing: 15,
            runSpacing: 15,
            children: [
              SizedBox(
                width: size.maxWidth < 600
                    ? size.maxWidth
                    : size.maxWidth * .55,
                child: TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Найти открытие',
                  ),
                  onChanged: (v) => setState(() => search = v),
                ),
              ),
              SizedBox(
                width: size.maxWidth < 600 ? size.maxWidth : size.maxWidth * .4,
                child: DropdownButtonFormField<String>(
                  initialValue: topic,
                  decoration: const InputDecoration(labelText: 'Направление'),
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(
                      value: 'all',
                      child: Text('Все темы'),
                    ),
                    ...topicNames.entries.map(
                      (e) =>
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ),
                  ],
                  onChanged: (v) => setState(() => topic = v!),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 26),
        if (articles.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(35),
              child: Column(
                children: [
                  Icon(Icons.auto_stories_outlined, size: 35, color: gold),
                  SizedBox(height: 20),
                  Text('Открытия появятся здесь постепенно.'),
                  SizedBox(height: 8),
                  Text(
                    'Сохраните статью дня или попробуйте другой фильтр.',
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ),
          )
        else
          LayoutBuilder(
            builder: (context, size) {
              final count = size.maxWidth > 1150
                  ? 3
                  : size.maxWidth > 650
                  ? 2
                  : 1;
              final width = (size.maxWidth - (count - 1) * 18) / count;
              return Wrap(
                spacing: 18,
                runSpacing: 18,
                children: articles
                    .map(
                      (article) => SizedBox(
                        width: width,
                        child: articleCard(article, data),
                      ),
                    )
                    .toList(),
              );
            },
          ),
      ],
    );
  }
}
