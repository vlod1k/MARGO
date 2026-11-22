typedef Json = Map<String, dynamic>;

const topicNames = <String, String>{
  'history': 'История',
  'physics': 'Физика',
  'chemistry': 'Химия',
  'biology': 'Биология',
  'space': 'Космос',
  'technology': 'Технологии',
  'programming': 'Программирование',
  'mathematics': 'Математика',
  'geography': 'География',
  'nature': 'Природа и экология',
  'psychology': 'Психология',
  'philosophy': 'Философия',
  'art': 'Искусство',
  'literature': 'Литература',
  'music': 'Музыка',
  'languages': 'Языки',
  'society': 'Общество и право',
  'economics': 'Экономика',
  'medicine': 'Медицина',
  'mythology': 'Мифология и религии',
};
const feedbackNames = <String, String>{
  'liked': 'Понравилось',
  'uninterested': 'Неинтересно',
  'known': 'Уже знаю',
  'difficult': 'Слишком сложно',
};

class AppData {
  final Json snapshot;
  final bool online;
  final int pending;
  final String? message;
  const AppData({
    this.snapshot = const {},
    this.online = false,
    this.pending = 0,
    this.message,
  });
  Json? get profile => snapshot['profile'] as Json?;
  Json? get today => snapshot['today'] as Json?;
  List<Json> get articles => (snapshot['articles'] as List? ?? [])
      .map((a) => Map<String, dynamic>.from(a as Map))
      .toList();
  List<Json> get interactions => (snapshot['interactions'] as List? ?? [])
      .map((a) => Map<String, dynamic>.from(a as Map))
      .toList();
  List<Json> get history => (snapshot['history'] as List? ?? [])
      .map((a) => Map<String, dynamic>.from(a as Map))
      .toList();
  Json interaction(String id) => interactions.firstWhere(
    (i) => i['article_id'] == id,
    orElse: () => {
      'article_id': id,
      'saved': false,
      'feedback': null,
      'field_versions': <String, dynamic>{},
    },
  );
  bool get signedIn => profile != null;
  bool get isDemo => snapshot['demo'] == true;
}
