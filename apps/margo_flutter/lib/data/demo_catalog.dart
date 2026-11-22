import 'dart:convert';

import 'package:timezone/timezone.dart' as tz;

import 'models.dart';

// Original short descriptions bundled with the app; no server or image download.
final List<Json> demoArticles =
    [
      {
        'id': 'antikythera',
        'title': 'Антикитерский механизм',
        'summary': 'Бронзовые шестерёнки, которые предсказывали движение небесных тел за две тысячи лет до появления компьютеров.',
        'topics': {'history': 1.0, 'technology': 0.9, 'space': 0.7},
        'minutes': 12,
      },
      {
        'id': 'aurora',
        'title': 'Полярное сияние',
        'summary': 'Встреча солнечного ветра и магнитного поля Земли, превращающая ночное небо в полотно света.',
        'topics': {'physics': 1.0, 'nature': 0.8},
        'minutes': 8,
      },
      {
        'id': 'bauhaus',
        'title': 'Баухаус',
        'summary': 'Школа, объединившая искусство, архитектуру и ремесло в поиске новой повседневной эстетики.',
        'topics': {'art': 1.0, 'history': 0.6},
        'minutes': 10,
      },
      {
        'id': 'mycelium',
        'title': 'Мицелий',
        'summary':
            'Невидимая грибная сеть под нашими ногами и её роль в жизни леса.',
        'topics': {'biology': 1.0, 'nature': 1.0},
        'minutes': 7,
      },
    ].map((entry) {
      final url =
          'https://ru.wikipedia.org/wiki/${Uri.encodeComponent((entry['title'] as String).replaceAll(' ', '_'))}';
      return <String, dynamic>{
        ...entry,
        'language': 'ru',
        'url': url,
        'attribution': {
          'source': url,
          'history': '$url?action=history',
          'notice': 'Авторское краткое описание MARGO. Демонстрационный материал. Полный текст и авторы — в Википедии.',
        },
      };
    }).toList();

Json createDemoSnapshot() {
  final now = tz.TZDateTime.now(tz.getLocation('Europe/Moscow'));
  final date =
      '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  final recommendation = {
    'date': date,
    'mode': 'demo',
    'explanation': 'Пример карточки MARGO. В деморежиме новая статья дня автоматически не назначается.',
    'article': demoArticles.first,
  };
  return updateDemoWeights(
    jsonDecode(
      jsonEncode({
        'demo': true,
        'profile': {
          'id': 'local-demo',
          'email': 'Без аккаунта',
          'name': 'Исследователь',
          'timezone': 'Europe/Moscow',
          'language': 'ru',
          'interests': ['history', 'technology', 'space'],
          'reminder': '09:00',
          'notifications': false,
          'onboarded': true,
          'version': 0,
        },
        'today': recommendation,
        'history': [recommendation],
        'articles': demoArticles,
        'interactions': [],
      }),
    ) as Json,
  );
}

Json updateDemoWeights(Json snapshot) {
  final profile = snapshot['profile'] as Json;
  final interests = profile['interests'] as List;
  final weights = {
    for (final topic in topicNames.keys)
      topic: interests.contains(topic) ? 0.8 : 0.2,
  };
  for (final interaction in (snapshot['interactions'] as List? ?? [])) {
    final article = demoArticles
        .where((a) => a['id'] == interaction['article_id'])
        .firstOrNull;
    if (article == null) continue;
    final feedback = interaction['feedback'] == 'liked'
        ? 1
        : interaction['feedback'] == 'uninterested'
        ? -1
        : 0;
    for (final entry in (article['topics'] as Map).entries) {
      weights[entry.key as String] =
          weights[entry.key]! + 0.05 * feedback * (entry.value as num);
    }
  }
  profile['weights'] = weights.map(
    (key, value) => MapEntry(key, value.clamp(0.0, 1.0)),
  );
  return snapshot;
}
