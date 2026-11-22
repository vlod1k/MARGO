import 'dart:convert';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:synchronized/synchronized.dart';

import '../data/models.dart';

final notifications = NotificationAdapter();

class NotificationAdapter {
  NotificationAdapter({
    FlutterLocalNotificationsPlugin? plugin,
    DateTime Function()? clock,
    bool? isWindows,
  }) : plugin = plugin ?? FlutterLocalNotificationsPlugin(),
       _clock = clock ?? DateTime.now,
       _isWindows = isWindows ?? Platform.isWindows;

  static const dailyPayload = 'margo:today';
  static const windowsDays = 30;
  final _lock = Lock();
  final FlutterLocalNotificationsPlugin plugin;
  final DateTime Function() _clock;
  final bool _isWindows;
  String? _scheduledKey;
  bool ready = false;
  String? error;

  // Keep notifications created by older versions usable after an upgrade.
  static String routeForPayload(String payload) => payload == dailyPayload
      ? '/'
      : '/article/${Uri.encodeComponent(payload)}';

  Future<void> initialize(void Function(String) openNotification) async {
    tzdata.initializeTimeZones();
    if (Platform.isLinux) return;
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_notification'),
        windows: WindowsInitializationSettings(
          appName: 'MARGO',
          appUserModelId: 'dev.thoth.app',
          guid: 'd963ac64-9855-42b4-bf16-e664890731ae',
        ),
      ),
      onDidReceiveNotificationResponse: (response) {
        if (response.payload != null) openNotification(response.payload!);
      },
    );
    ready = true;
    final launch = await plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true &&
        launch?.notificationResponse?.payload != null) {
      openNotification(launch!.notificationResponse!.payload!);
    }
  }

  Future<bool> requestPermission() async =>
      await plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission() ??
      true;

  Future<void> clear() => _lock.synchronized(() async {
    _scheduledKey = null;
    if (ready) await plugin.cancelAll();
  });

  Future<void> update(AppData data) => _lock.synchronized(() => _update(data));

  Future<void> _update(AppData data) async {
    if (!ready) return;
    final profile = data.profile;
    if (data.isDemo || profile == null || profile['notifications'] != true) {
      _scheduledKey = null;
      await plugin.cancelAll();
      return;
    }

    final zone = profile['timezone'] as String;
    final location = tz.getLocation(zone);
    final now = tz.TZDateTime.from(_clock(), location);
    final reminder = profile['reminder'] as String;
    final key = jsonEncode([
      profile['id'],
      zone,
      reminder,
      now.year,
      now.month,
      now.day,
    ]);
    // The session refreshes frequently. Rebuild only after a day or preference
    // change; a new process always reinstalls the OS schedule, including upgrades.
    if (_scheduledKey == key) return;
    final time = reminder.split(':').map(int.parse).toList();
    tz.TZDateTime atDay(int offset) => tz.TZDateTime(
      location,
      now.year,
      now.month,
      now.day + offset,
      time[0],
      time[1],
    );
    final firstDay = atDay(0).isAfter(now) ? 0 : 1;

    _scheduledKey = null;
    // Also removes the old article-specific reminder during migration.
    await plugin.cancelAll();
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'thoth_daily',
        'Открытие дня',
        channelDescription: 'Ежедневное напоминание открыть MARGO',
        importance: Importance.defaultImportance,
      ),
      windows: WindowsNotificationDetails(),
    );
    // Windows ignores matchDateTimeComponents. Supply individual calendar
    // dates there; Android reschedules the next daily occurrence itself.
    final count = _isWindows ? windowsDays : 1;
    for (var i = 0; i < count; i++) {
      await plugin.zonedSchedule(
        id: i + 1,
        title: 'Время для открытия',
        body: 'Откройте MARGO и узнайте что-нибудь новое.',
        scheduledDate: atDay(firstDay + i),
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: _isWindows ? null : DateTimeComponents.time,
        payload: dailyPayload,
      );
    }
    _scheduledKey = key;
    error = null;
  }
}
