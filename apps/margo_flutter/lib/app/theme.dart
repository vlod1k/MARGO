import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sync/controller.dart';

const ink = Color(0xff252329),
    gold = Color(0xffb88737),
    sand = Color(0xffe8d8b8),
    ivory = Color(0xfff5f6f8);

final themeProvider = NotifierProvider<ThemeController, ThemeMode>(
  ThemeController.new,
);

class ThemeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    return ThemeMode.system;
  }

  Future<void> load() async {
    final repository = await ref.read(repositoryProvider.future);
    final settings = await repository.local.read('settings') ?? {};
    if (!ref.mounted) return;
    state = ThemeMode.values.firstWhere(
      (v) => v.name == settings['theme'],
      orElse: () => ThemeMode.system,
    );
  }

  Future<void> change(ThemeMode mode) async {
    state = mode;
    final repository = await ref.read(repositoryProvider.future);
    await repository.local.write('settings', {
      ...await repository.local.read('settings') ?? {},
      'theme': mode.name,
    });
  }
}

ThemeData margoTheme(
  Brightness brightness, {
  String? fontFamily,
  bool headlinesOnly = false,
}) {
  final headlineFamily = headlinesOnly ? fontFamily : null;
  final dark = brightness == Brightness.dark;
  final accent = dark ? const Color(0xffeeecff) : const Color(0xffefbf00);
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: brightness)
      .copyWith(
        primary: accent,
        onPrimary: ink,
        surface: dark ? ink : Colors.white,
        onSurface: dark ? ivory : ink,
      );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark
        ? const Color(0xff19181c)
        : const Color(0xfffdffec),
    fontFamily: (headlinesOnly ? null : fontFamily) ?? 'Segoe UI',
    fontFamilyFallback: fontFamily == null
        ? null
        : const ['Segoe UI', 'Roboto'],
    textTheme: TextTheme(
      headlineLarge: TextStyle(
        fontFamily: headlineFamily,
        fontSize: 38,
        fontWeight: FontWeight.w700,
        letterSpacing: -1.4,
        color: scheme.onSurface,
      ),
      headlineMedium: TextStyle(
        fontFamily: headlineFamily,
        fontSize: 30,
        fontWeight: FontWeight.w700,
        letterSpacing: -.6,
      ),
      titleLarge: const TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
      bodyLarge: const TextStyle(fontSize: 16, height: 1.65),
      bodyMedium: const TextStyle(fontSize: 14, height: 1.6),
      labelSmall: const TextStyle(
        fontSize: 11,
        letterSpacing: .8,
        fontWeight: FontWeight.w600,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .4)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.all(17),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 17),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: scheme.primary.withValues(alpha: .12),
    ),
    chipTheme: ChipThemeData(
      selectedColor: scheme.primary.withValues(alpha: .22),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      side: BorderSide(color: scheme.outlineVariant),
      shape: const StadiumBorder(),
    ),
  );
}
