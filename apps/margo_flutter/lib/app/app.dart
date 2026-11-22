import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/models.dart';
import '../sync/controller.dart';
import '../notifications/notification_adapter.dart';
import '../features/onboarding/auth_screen.dart';
import '../features/daily_article/article_screen.dart';
import '../features/library/library_screen.dart';
import '../features/statistics/statistics_screen.dart';
import '../features/settings/profile_screen.dart';
import 'app_fonts.dart';
import 'theme.dart';
import 'widgets.dart';
import '../updates/app_updates.dart';
import '../updates/update_widgets.dart';

final appRouter = GoRouter(
  routes: [
    GoRoute(
      path: '/',
      builder: (_, _) => const AppShell(section: 0, child: TodayScreen()),
    ),
    GoRoute(
      path: '/library',
      builder: (_, _) => const AppShell(section: 1, child: LibraryScreen()),
    ),
    GoRoute(
      path: '/statistics',
      builder: (_, _) => const AppShell(section: 2, child: StatisticsScreen()),
    ),
    GoRoute(
      path: '/profile',
      builder: (_, _) => const AppShell(section: 3, child: ProfileScreen()),
    ),
    GoRoute(
      path: '/onboarding',
      builder: (_, _) =>
          const AppShell(section: 3, child: ProfileScreen(onboarding: true)),
    ),
    GoRoute(
      path: '/article/:id',
      builder: (_, state) => AppShell(
        section: 1,
        child: ArticleScreen(id: state.pathParameters['id']!),
      ),
    ),
  ],
);

class MargoApp extends ConsumerStatefulWidget {
  const MargoApp({super.key});
  @override
  ConsumerState<MargoApp> createState() => _MargoAppState();
}

class _MargoAppState extends ConsumerState<MargoApp>
    with WidgetsBindingObserver {
  AppFont? _displayedFont;
  Timer? _updateTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(() => ref.read(themeProvider.notifier).load());
    if (kReleaseMode) {
      Future.microtask(() => ref.read(appUpdatesProvider).check());
      _updateTimer = Timer.periodic(const Duration(hours: 1), (_) {
        unawaited(ref.read(appUpdatesProvider).check());
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _updateTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (kReleaseMode) unawaited(ref.read(appUpdatesProvider).check());
      unawaited(ref.read(sessionProvider.notifier).refresh());
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(sessionProvider, (previous, next) {
      final data = next.asData?.value;
      if (data == null) return;
      notifications.update(data).catchError((Object e) {
        notifications.error = e.toString();
      });
    });
    final font = ref.watch(appFontProvider.select((result) => result.value));
    final fontChanged = font != _displayedFont;
    _displayedFont = font;
    return MaterialApp.router(
      title: 'MARGO',
      debugShowCheckedModeBanner: false,
      theme: margoTheme(
        Brightness.light,
        fontFamily: font?.family,
        headlinesOnly: font?.headlinesOnly ?? false,
      ),
      darkTheme: margoTheme(
        Brightness.dark,
        fontFamily: font?.family,
        headlinesOnly: font?.headlinesOnly ?? false,
      ),
      themeAnimationDuration: fontChanged
          ? Duration.zero
          : kThemeAnimationDuration,
      themeMode: ref.watch(themeProvider),
      routerConfig: appRouter,
      builder: (context, child) => Column(
        children: [
          const UpdateStatus(compact: true),
          Expanded(child: child!),
        ],
      ),
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
    );
  }
}

class AppShell extends ConsumerStatefulWidget {
  final int section;
  final Widget child;
  const AppShell({super.key, required this.section, required this.child});
  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  final scroll = ScrollController();
  bool firstSync = false;
  static const paths = ['/', '/library', '/statistics', '/profile'];
  static const labels = ['Сегодня', 'Библиотека', 'Статистика', 'Профиль'];
  static const icons = [
    Icons.wb_sunny_outlined,
    Icons.auto_stories_outlined,
    Icons.bar_chart_outlined,
    Icons.person_outline,
  ];
  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.child.runtimeType != widget.child.runtimeType &&
        scroll.hasClients) {
      scroll.jumpTo(0);
    }
  }

  void go(int index) => context.go(paths[index]);

  Widget sidebar(AppData data) => SizedBox(
    width: 248,
    child: Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 28,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(left: 8),
                        child: Brand(),
                      ),
                      const SizedBox(height: 35),
                      Divider(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                      const SizedBox(height: 24),
                      Padding(
                        padding: const EdgeInsets.only(left: 16),
                        child: Text(
                          'ВАШЕ ПРОСТРАНСТВО',
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                            fontSize: 9,
                            letterSpacing: 1.7,
                          ),
                        ),
                      ),
                      const SizedBox(height: 17),
                      ...List.generate(
                        4,
                        (i) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            selected: widget.section == i,
                            selectedTileColor: Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: .09),
                            selectedColor: Theme.of(context)
                                .colorScheme
                                .primary,
                            iconColor: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                            textColor: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                            leading: Icon(icons[i], size: 20),
                            title: Text(
                              labels[i],
                              style: const TextStyle(fontSize: 13),
                            ),
                            onTap: () => go(i),
                          ),
                        ),
                      ),
                      const Spacer(),
                      Container(
                        margin: const EdgeInsets.only(top: 28),
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary
                              .withValues(alpha: .06),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.auto_awesome_rounded,
                              color: Theme.of(context).colorScheme.primary,
                              size: 24,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'Место для\nлюбопытства',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Одна статья. Новый взгляд. Каждый день.',
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.6,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 32),
                      Divider(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                      ListTile(
                        contentPadding: const EdgeInsets.only(left: 8),
                        leading: CircleAvatar(
                          radius: 17,
                          backgroundColor: gold.withValues(alpha: .15),
                          child: Text(
                            (data.profile!['name'] as String).characters.first,
                            style: const TextStyle(color: gold),
                          ),
                        ),
                        title: Text(
                          data.profile!['name'] as String,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          'Ваш путь к знаниям',
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                            fontSize: 9,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget body(AppData data, bool wide, bool reading) => SafeArea(
    child: Column(
      children: [
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: wide ? 40 : 20,
            vertical: 16,
          ),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).dividerColor.withValues(alpha: .12),
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: !wide
                    ? const Align(
                        alignment: Alignment.centerLeft,
                        child: Brand(compact: true),
                      )
                    : Text(
                        'Ваше пространство  /  ${labels[widget.section]}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
              ),
              Tooltip(
                message: data.isDemo
                    ? 'Деморежим · без сервера'
                    : data.online
                    ? 'Синхронизировано'
                    : 'Нет связи · доступны загруженные карточки',
                child: Icon(
                  data.isDemo
                      ? Icons.science_outlined
                      : data.online
                      ? Icons.cloud_done_outlined
                      : Icons.cloud_off_outlined,
                  size: 18,
                  color: data.online ? const Color(0xff839478) : gold,
                ),
              ),
              if (data.pending > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    '${data.pending}',
                    style: const TextStyle(fontSize: 11, color: gold),
                  ),
                ),
              const SizedBox(width: 9),
              IconButton(
                tooltip: data.isDemo
                    ? 'В деморежиме синхронизация не используется'
                    : 'Синхронизировать · Ctrl+R',
                onPressed: data.isDemo
                    ? null
                    : () => ref.read(sessionProvider.notifier).refresh(),
                icon: const Icon(Icons.sync, size: 20),
              ),
            ],
          ),
        ),
        if (data.isDemo || data.message != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
            color: gold.withValues(alpha: .1),
            child: Text(
              data.isDemo
                  ? 'Деморежим · Без аккаунта и сервера. Сохранения и оценки — только на этом устройстве.'
                  : data.message!,
              style: const TextStyle(fontSize: 11),
            ),
          ),
        Expanded(
          child: SelectionArea(
            child: SingleChildScrollView(
              controller: scroll,
              padding: EdgeInsets.all(wide ? 38 : 21),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: reading ? 680 : 1220),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget.child is TodayScreen) ...[
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(top: 3),
                              child: Icon(
                                Icons.account_circle_outlined,
                                size: 28,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    data.isDemo
                                        ? 'Демопрофиль'
                                        : 'Текущий профиль',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
                                  ),
                                  Text(
                                    data.profile!['name'] as String,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                      ],
                      if (GoRouterState.of(context).uri.path
                          .startsWith('/article/'))
                        TextButton.icon(
                          onPressed: () =>
                              context.canPop() ? context.pop() : go(1),
                          icon: const Icon(Icons.arrow_back, size: 17),
                          label: const Text('В библиотеку'),
                        ),
                      if (data.profile!['onboarded'] != true)
                        const ProfileScreen(onboarding: true)
                      else
                        widget.child,
                      const SizedBox(height: 40),
                      const Divider(),
                      const SizedBox(height: 12),
                      const Text(
                        'MARGO · Один день. Одна статья. Одно новое открытие.',
                        style: TextStyle(fontSize: 10, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return ref
        .watch(sessionProvider)
        .when(
          loading: () => const Scaffold(
            body: Center(child: CircularProgressIndicator(color: gold)),
          ),
          error: (error, _) => Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Не удалось открыть локальные данные.'),
                  const SizedBox(height: 15),
                  FilledButton(
                    onPressed: () => ref.invalidate(sessionProvider),
                    child: const Text('Повторить'),
                  ),
                ],
              ),
            ),
          ),
          data: (data) {
            if (!data.signedIn) return const AuthScreen();
            if (!firstSync) {
              firstSync = true;
              Future.microtask(
                () => ref.read(sessionProvider.notifier).refresh(),
              );
            }
            final wide = MediaQuery.sizeOf(context).width >= 900;
            final reading =
                data.profile?['onboarded'] == true &&
                (widget.child is ArticleScreen ||
                    (widget.child is TodayScreen && data.today != null));
            final theme = Theme.of(context);
            final scaffold = Scaffold(
              backgroundColor: reading && theme.brightness == Brightness.dark
                  ? theme.colorScheme.surface
                  : null,
              bottomNavigationBar: wide
                  ? null
                  : NavigationBar(
                      selectedIndex: widget.section,
                      onDestinationSelected: go,
                      destinations: List.generate(
                        4,
                        (i) => NavigationDestination(
                          icon: Icon(icons[i]),
                          label: labels[i],
                        ),
                      ),
                    ),
              body: Row(
                children: [
                  if (wide) sidebar(data),
                  Expanded(child: body(data, wide, reading)),
                ],
              ),
            );
            return CallbackShortcuts(
              bindings: {
                for (var i = 0; i < 4; i++)
                  SingleActivator(
                    [
                      LogicalKeyboardKey.digit1,
                      LogicalKeyboardKey.digit2,
                      LogicalKeyboardKey.digit3,
                      LogicalKeyboardKey.digit4,
                    ][i],
                    control: true,
                  ): () =>
                      go(i),
                const SingleActivator(
                  LogicalKeyboardKey.keyR,
                  control: true,
                ): () =>
                    ref.read(sessionProvider.notifier).refresh(),
                const SingleActivator(
                  LogicalKeyboardKey.keyS,
                  control: true,
                ): () {
                  final article = data.today?['article'] as Json?;
                  if (article != null) {
                    ref
                        .read(sessionProvider.notifier)
                        .act(
                          article['id'] as String,
                          'saved',
                          data.interaction(article['id'] as String)['saved'] !=
                              true,
                        );
                  }
                },
              },
              child: Focus(autofocus: true, child: scaffold),
            );
          },
        );
  }
}
