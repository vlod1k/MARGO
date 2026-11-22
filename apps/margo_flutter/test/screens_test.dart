import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:margo/app/theme.dart';
import 'package:margo/data/models.dart';
import 'package:margo/data/repository.dart';
import 'package:margo/sync/controller.dart';
import 'package:margo/features/daily_article/article_screen.dart';
import 'package:margo/features/library/library_screen.dart';
import 'package:margo/features/statistics/statistics_screen.dart';
import 'package:margo/features/settings/profile_screen.dart';

final fixture = <String, dynamic>{
  'profile': {
    'id': 'test',
    'name': 'Исследователь',
    'email': 'test@example.com',
    'timezone': 'Europe/Moscow',
    'language': 'ru',
    'interests': ['history', 'technology'],
    'weights': {'history': .8, 'technology': .8},
    'reminder': '09:00',
    'notifications': false,
    'version': 0,
  },
  'today': {
    'date': '2000-01-01',
    'mode': 'personal',
    'explanation': 'Связана с вашим интересом к истории',
    'article': article,
  },
  'articles': [article],
  'interactions': [],
  'history': [
    {'date': '2026-11-04', 'article': article},
  ],
};
const article = <String, dynamic>{
  'id': 'antikythera',
  'title': 'Антикитерский механизм',
  'summary': 'Бронзовые шестерёнки предсказывали движение небесных тел.',
  'url': 'https://ru.wikipedia.org/wiki/Антикитерский_механизм',
  'topics': {'history': 1.0, 'technology': .9},
  'minutes': 12,
  'attribution': {'notice': 'Авторское описание MARGO'},
};

class FakeSession extends SessionController {
  @override
  Future<AppData> build() async =>
      AppData(snapshot: MargoRepository.clone(fixture));
  @override
  Future<void> act(String id, String field, dynamic value) async {
    state = AsyncData(
      AppData(
        snapshot: MargoRepository.overlay(state.asData!.value.snapshot, {
          'article_id': id,
          'field': field,
          'value': value,
          'base_version': 0,
        }),
        pending: 1,
      ),
    );
  }
}

void main() {
  setUpAll(tz.initializeTimeZones);
  for (final width in [390.0, 1280.0]) {
    for (final screen in <Widget>[
      const TodayScreen(),
      const LibraryScreen(),
      const StatisticsScreen(),
      const ProfileScreen(),
    ]) {
      testWidgets(
        '${screen.runtimeType} renders at $width with enlarged text',
        (tester) async {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [sessionProvider.overrideWith(FakeSession.new)],
              child: MaterialApp(
                theme: margoTheme(Brightness.light),
                locale: const Locale('ru'),
                localizationsDelegates: GlobalMaterialLocalizations.delegates,
                supportedLocales: const [Locale('ru')],
                home: Consumer(
                  builder: (context, ref, _) {
                    final data = ref.watch(sessionProvider);
                    return data.when(
                      loading: () => const SizedBox(),
                      error: (e, _) => Text('$e'),
                      data: (_) => Scaffold(
                        body: MediaQuery(
                          data: MediaQuery.of(context).copyWith(
                            textScaler: TextScaler.linear(
                              width < 500 ? 1.4 : 1,
                            ),
                          ),
                          child: SingleChildScrollView(
                            child: Padding(
                              padding: const EdgeInsets.all(21),
                              child: screen,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          if (screen is ProfileScreen) {
            final changePassword = find.text('Сменить пароль');
            expect(changePassword, findsOneWidget);
            expect(find.text('Завершить остальные сессии'), findsOneWidget);
            await tester.ensureVisible(changePassword);
            await tester.tap(changePassword);
            await tester.pumpAndSettle();
            expect(find.text('Текущий пароль'), findsOneWidget);
            expect(find.text('Новый пароль'), findsOneWidget);
            expect(tester.takeException(), isNull);
            await tester.tap(find.text('Отмена'));
            await tester.pumpAndSettle();
          }
          if (screen is TodayScreen) {
            expect(
              find.textContaining('Последняя загруженная статья'),
              findsOneWidget,
            );
            await tester.ensureVisible(find.text('На потом'));
            await tester.tap(find.text('На потом'));
            await tester.pumpAndSettle();
            expect(find.text('Сохранено'), findsOneWidget);
            await tester.ensureVisible(find.text('Я прочитал(а) статью'));
            await tester.tap(find.text('Я прочитал(а) статью'));
            await tester.pumpAndSettle();
            expect(find.text('Снять отметку «Прочитано»'), findsOneWidget);
            await tester.ensureVisible(find.text('Снять отметку «Прочитано»'));
            await tester.tap(find.text('Снять отметку «Прочитано»'));
            await tester.pumpAndSettle();
            expect(find.text('Я прочитал(а) статью'), findsOneWidget);
            final container = ProviderScope.containerOf(
              tester.element(find.byType(TodayScreen)),
            );
            expect(
              container
                  .read(sessionProvider)
                  .asData!
                  .value
                  .interaction('antikythera')['read_at'],
              isNull,
            );
            expect(tester.takeException(), isNull);
          }
        },
      );
    }
  }
}
