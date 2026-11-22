import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/widgets.dart';
import '../../app/theme.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import '../../sync/controller.dart';
import '../../notifications/notification_adapter.dart';
import '../../updates/update_widgets.dart';
import 'font_settings.dart';
import '../onboarding/account_access_dialog.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  final bool onboarding;
  const ProfileScreen({super.key, this.onboarding = false});
  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final form = GlobalKey<FormState>();
  late TextEditingController name, zone;
  late Set<String> interests;
  late String language, reminder;
  late bool enabled;
  late int version;
  bool busy = false;
  String? error;
  bool endingSessions = false;

  Future<void> endOtherSessions() async {
    if (endingSessions) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Завершить остальные сессии?'),
        content: const Text(
          'На остальных устройствах потребуется войти снова. На этом устройстве вход сохранится.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Завершить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => endingSessions = true);
    try {
      final repository = await ref.read(repositoryProvider.future);
      await repository.logoutOthers();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Остальные сессии завершены.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(apiError(e))));
      }
    } finally {
      if (mounted) setState(() => endingSessions = false);
    }
  }

  @override
  void initState() {
    super.initState();
    final profile = ref.read(sessionProvider).asData!.value.profile!;
    name = TextEditingController(text: profile['name'] as String);
    zone = TextEditingController(text: profile['timezone'] as String);
    interests = Set<String>.from(profile['interests'] as List);
    language = profile['language'] as String;
    reminder = profile['reminder'] as String;
    enabled = profile['notifications'] == true;
    version = profile['version'] as int;
  }

  @override
  void dispose() {
    name.dispose();
    zone.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await ref.read(sessionProvider.notifier).preferences({
        'name': name.text.trim(),
        'timezone': zone.text.trim(),
        'interests': interests.toList(),
        'language': language,
        'reminder': reminder,
        'notifications': enabled,
        'version': version,
      });
      if (!mounted) return;
      final currentProfile = ref.read(sessionProvider).asData?.value.profile;
      if (currentProfile == null) return;
      version = currentProfile['version'] as int;
      if (mounted) {
        if (widget.onboarding) {
          context.go('/');
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Настройки сохранены. Статья на сегодня не изменится.',
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) setState(() => error = apiError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> reloadProfile() async {
    await ref.read(sessionProvider.notifier).refresh();
    if (!mounted) return;
    final p = ref.read(sessionProvider).asData?.value.profile;
    if (p == null) return;
    setState(() {
      name.text = p['name'] as String;
      zone.text = p['timezone'] as String;
      interests = Set<String>.from(p['interests'] as List);
      language = p['language'] as String;
      reminder = p['reminder'] as String;
      enabled = p['notifications'] == true;
      version = p['version'] as int;
      error = null;
    });
  }

  Future<void> export() async {
    try {
      final repository = await ref.read(repositoryProvider.future);
      final data = await repository.exportAccount();
      final json = const JsonEncoder.withIndent('  ').convert(data);
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        final location = await getSaveLocation(
          suggestedName: 'margo-export.json',
          acceptedTypeGroups: [
            const XTypeGroup(label: 'JSON', extensions: ['json']),
          ],
        );
        if (location != null) {
          await XFile.fromData(
            Uint8List.fromList(utf8.encode(json)),
            mimeType: 'application/json',
          ).saveTo(location.path);
        }
      } else if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Экспорт ваших данных'),
            content: SizedBox(
              width: 500,
              child: SingleChildScrollView(
                child: SelectableText(
                  json,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: json));
                  Navigator.pop(context);
                },
                child: const Text('Скопировать JSON'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Закрыть'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(apiError(e))));
      }
    }
  }

  Future<void> deleteAccount() async {
    final demo = ref.read(sessionProvider).asData!.value.isDemo;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(demo ? 'Сбросить демоданные?' : 'Удалить аккаунт MARGO?'),
        content: Text(
          demo
              ? 'Локальные оценки, сохранения и настройки деморежима будут удалены. Серверный аккаунт не затрагивается.'
              : 'Серверные персональные данные, локальные карточки, ожидающие действия и токен на этом устройстве будут удалены. Другие устройства очистятся при следующей синхронизации. Это действие нельзя отменить.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              demo ? 'Сбросить демоданные' : 'Удалить аккаунт',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (yes == true && mounted) {
      try {
        await ref.read(sessionProvider.notifier).deleteAccount();
        await notifications.clear();
        if (mounted) context.go('/');
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(apiError(e))));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(sessionProvider).asData!.value;
    return Form(
      key: form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHeading(
            eyebrow: widget.onboarding
                ? 'ОТПРАВНАЯ ТОЧКА'
                : 'ВАШ СОБСТВЕННЫЙ МАРШРУТ',
            title: widget.onboarding ? 'Что вам любопытно?' : 'Ваш профиль.',
            description: widget.onboarding
                ? 'Выберите интересы. Мы оставим место и для неожиданных открытий.'
                : 'Пусть открытия вписываются в ваш ритм жизни.',
          ),
          if (data.snapshot['catalog'] case final Map catalog) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Запас статей',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    for (final entry in catalog.entries)
                      Text(
                        '${entry.key == 'ru' ? 'Русский' : 'Английский'}: новых для вас ${entry.value['remaining']}, всего ${entry.value['available']}',
                      ),
                    const SizedBox(height: 8),
                    const Text(
                      'По последней синхронизации. Уже назначенные статьи не входят в остаток.',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(27),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Мои интересы',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Выбранные направления — отправная точка, а не границы.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 23),
                  Wrap(
                    spacing: 8,
                    runSpacing: 9,
                    children: topicNames.entries
                        .map(
                          (entry) => FilterChip(
                            label: Text(entry.value),
                            selected: interests.contains(entry.key),
                            onSelected: (selected) => setState(() {
                              selected
                                  ? interests.add(entry.key)
                                  : interests.remove(entry.key);
                            }),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Выбрано ${interests.length} из 20 · Невыбранные темы тоже могут появляться',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(27),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Личный ритм',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: name,
                    decoration: const InputDecoration(
                      labelText: 'Как вас называть',
                    ),
                    maxLength: 80,
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? 'Укажите имя' : null,
                  ),
                  const SizedBox(height: 18),
                  DropdownButtonFormField<String>(
                    initialValue: language,
                    decoration: const InputDecoration(labelText: 'Язык статей'),
                    items: const [
                      DropdownMenuItem(value: 'ru', child: Text('Русский')),
                      DropdownMenuItem(value: 'en', child: Text('English')),
                    ],
                    onChanged: data.isDemo
                        ? null
                        : (v) => setState(() => language = v!),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 10),
                    child: Text(
                      'Статьи доступны на языках, для которых сервер наполнил каталог.',
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: zone,
                    decoration: const InputDecoration(
                      labelText: 'Часовой пояс IANA',
                      hintText: 'Europe/Moscow',
                    ),
                    validator: (v) => v == null || v.trim().isEmpty
                        ? 'Укажите часовой пояс'
                        : null,
                  ),
                  const SizedBox(height: 20),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Время напоминания'),
                    subtitle: Text('$reminder · ${zone.text}'),
                    trailing: const Icon(Icons.schedule, color: gold),
                    onTap: () async {
                      final parts = reminder.split(':');
                      final time = await showTimePicker(
                        context: context,
                        initialTime: TimeOfDay(
                          hour: int.parse(parts[0]),
                          minute: int.parse(parts[1]),
                        ),
                      );
                      if (time != null) {
                        setState(
                          () => reminder =
                              '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                        );
                      }
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Ежедневное напоминание'),
                    value: enabled,
                    onChanged: data.isDemo
                        ? null
                        : (value) async {
                            if (value && !notifications.ready) {
                              setState(
                                () => error =
                                    'Уведомления недоступны: ${notifications.error ?? 'платформенный адаптер не инициализирован'}',
                              );
                              return;
                            }
                            if (value &&
                                !await notifications.requestPermission()) {
                              if (mounted) {
                                setState(
                                  () => error = 'Разрешите уведомления в системных настройках.',
                                );
                              }
                              return;
                            }
                            if (mounted) setState(() => enabled = value);
                          },
                  ),
                  Text(
                    data.isDemo
                        ? 'В деморежиме доступны встроенные карточки на русском языке. Серверные рекомендации и уведомления не используются.'
                        : 'Напоминаем каждый день, даже если приложение закрыто и статья ещё не загружена. На Windows расписание действует на 30 дней вперёд и продлевается при открытии приложения. Нажатие открывает «Сегодня»; для загрузки новой статьи нужен интернет. Доставка зависит от настроек уведомлений и энергосбережения ОС; точное время не гарантируется. Изменения вступают в силу после сохранения профиля.',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.grey,
                      height: 1.8,
                    ),
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 18),
                      child: Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (error != null)
                    TextButton(
                      onPressed: reloadProfile,
                      child: Text(
                        data.isDemo
                            ? 'Вернуть сохранённые настройки'
                            : 'Загрузить настройки с сервера',
                      ),
                    ),
                  const SizedBox(height: 25),
                  FilledButton.icon(
                    onPressed: busy ? null : save,
                    icon: const Icon(Icons.arrow_forward, size: 18),
                    label: Text(
                      busy
                          ? 'Сохраняем…'
                          : widget.onboarding
                          ? 'Начать открытия'
                          : 'Сохранить настройки',
                    ),
                  ),
                  if (!data.online && !data.isDemo)
                    const Padding(
                      padding: EdgeInsets.only(top: 15),
                      child: Text(
                        'Для изменения профиля требуется связь с сервером. Оценки и сохранения доступны офлайн.',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (!widget.onboarding) ...[
            const SizedBox(height: 20),
            const Card(margin: EdgeInsets.zero, child: UpdateStatus()),
            const SizedBox(height: 20),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(27),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Оформление',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 9,
                      children: ThemeMode.values
                          .map(
                            (mode) => ChoiceChip(
                              label: Text(switch (mode) {
                                ThemeMode.system => 'Как в системе',
                                ThemeMode.light => 'Светлая',
                                ThemeMode.dark => 'Тёмная',
                              }),
                              selected: ref.watch(themeProvider) == mode,
                              onSelected: (_) =>
                                  ref.read(themeProvider.notifier).change(mode),
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 20),
                    const FontSettings(),
                    const SizedBox(height: 20),
                    const Text(
                      'Горячие клавиши Windows: Ctrl+1…4 — разделы, Ctrl+S — сохранить статью дня, Ctrl+R — синхронизация.',
                      style: TextStyle(color: Colors.grey, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(27),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Прозрачная персонализация',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Без AI и скрытых данных. Ни «Уже знаю», ни «Слишком сложно» не понижают интерес к теме.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 14),
                    ...interests.map(
                      (t) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                topicNames[t]!,
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                            Text(
                              '${(((data.profile!['weights'] as Map)[t] as num? ?? .2) * 100).round()}%',
                              style: const TextStyle(color: gold),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(27),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Данные и конфиденциальность',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      data.isDemo
                          ? 'Без аккаунта · данные только на устройстве\nДемоданные не отправляются при последующем входе.'
                          : 'Аккаунт: ${data.profile!['email']}\nОжидают отправки: ${data.pending}',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 16,
                      runSpacing: 12,
                      children: [
                        OutlinedButton.icon(
                          onPressed: export,
                          icon: const Icon(Icons.download_outlined, size: 18),
                          label: const Text('Экспортировать данные'),
                        ),
                        if (!data.isDemo) ...[
                          OutlinedButton(
                            onPressed: () => showDialog<void>(
                              context: context,
                              barrierDismissible: false,
                              builder: (_) => const AccountAccessDialog(
                                changePassword: true,
                              ),
                            ),
                            child: const Text('Сменить пароль'),
                          ),
                          OutlinedButton(
                            onPressed: endingSessions ? null : endOtherSessions,
                            child: const Text('Завершить остальные сессии'),
                          ),
                        ],
                        TextButton(
                          onPressed: () async {
                            try {
                              await ref.read(sessionProvider.notifier).logout();
                              await notifications.clear();
                              if (context.mounted) context.go('/');
                            } catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(apiError(e))),
                                );
                              }
                            }
                          },
                          child: Text(
                            data.isDemo ? 'Выйти из деморежима' : 'Выйти',
                          ),
                        ),
                        TextButton(
                          onPressed: deleteAccount,
                          child: Text(
                            data.isDemo
                                ? 'Сбросить демоданные'
                                : 'Удалить аккаунт',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
