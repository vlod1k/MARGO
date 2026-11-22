import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:margo/data/models.dart';
import 'package:margo/notifications/notification_adapter.dart';

class ScheduledReminder {
  ScheduledReminder(this.id, this.date, this.repeat, this.payload);
  final int id;
  final tz.TZDateTime date;
  final DateTimeComponents? repeat;
  final String? payload;
}

class FakeNotifications implements FlutterLocalNotificationsPlugin {
  final pending = <ScheduledReminder>[];
  int cancellations = 0;
  bool fail = false;

  @override
  Future<void> cancelAll() async {
    cancellations++;
    pending.clear();
  }

  @override
  Future<void> zonedSchedule({
    required int id,
    required tz.TZDateTime scheduledDate,
    required NotificationDetails notificationDetails,
    required AndroidScheduleMode androidScheduleMode,
    String? title,
    String? body,
    String? payload,
    DateTimeComponents? matchDateTimeComponents,
  }) async {
    if (fail) throw StateError('OS scheduling failed');
    expect(androidScheduleMode, AndroidScheduleMode.inexactAllowWhileIdle);
    expect(title, 'Время для открытия');
    pending.add(
      ScheduledReminder(id, scheduledDate, matchDateTimeComponents, payload),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AppData account({
  String user = 'one',
  String zone = 'Europe/Moscow',
  String reminder = '09:00',
  bool enabled = true,
  bool demo = false,
  Json? today,
}) => AppData(
  snapshot: {
    'demo': demo,
    'profile': {
      'id': user,
      'timezone': zone,
      'reminder': reminder,
      'notifications': enabled,
    },
    'today': today,
  },
);

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late FakeNotifications plugin;
  late NotificationAdapter adapter;
  late DateTime now;

  setUp(() {
    plugin = FakeNotifications();
    now = DateTime.utc(2026, 11, 18, 5); // 08:00 Moscow.
    adapter = NotificationAdapter(
      plugin: plugin,
      clock: () => now,
      isWindows: false,
    )..ready = true;
  });

  test('Linux initializes time zones without starting notifications', () async {
    final linux = NotificationAdapter(plugin: plugin);
    await linux.initialize((_) => fail('Unexpected notification launch'));
    await linux.update(account());
    expect(tz.getLocation('Europe/Moscow').name, 'Europe/Moscow');
    expect(linux.ready, isFalse);
    expect(plugin.cancellations, 0);
    expect(plugin.pending, isEmpty);
  }, skip: !Platform.isLinux);

  test('Android repeats without a downloaded article or network', () async {
    await adapter.update(account());
    final reminder = plugin.pending.single;
    expect(reminder.date.hour, 9);
    expect(reminder.date.day, 18);
    expect(reminder.repeat, DateTimeComponents.time);
    expect(reminder.payload, NotificationAdapter.dailyPayload);
    expect(NotificationAdapter.routeForPayload(reminder.payload!), '/');
  });

  test('stale cached article never becomes the notification target', () async {
    await adapter.update(
      account(
        today: {
          'date': '2020-01-01',
          'article': {'id': 'old', 'title': 'Старая статья'},
        },
      ),
    );
    expect(plugin.pending.single.payload, NotificationAdapter.dailyPayload);
  });

  test(
    'opening after reminder time schedules tomorrow without a catch-up',
    () async {
      now = DateTime.utc(2026, 11, 18, 6);
      await adapter.update(account());
      expect(plugin.pending.single.date.day, 19);
      expect(plugin.pending.single.date.hour, 9);
    },
  );

  test(
    'refreshes do not recreate schedules; preference and account changes do',
    () async {
      await adapter.update(account());
      await adapter.update(account());
      expect(plugin.cancellations, 1);
      await adapter.update(account(reminder: '10:15'));
      expect(plugin.pending.single.date.hour, 10);
      expect(plugin.pending.single.date.minute, 15);
      await adapter.update(account(zone: 'Asia/Tokyo', reminder: '10:15'));
      expect(plugin.pending.single.date.location.name, 'Asia/Tokyo');
      expect(plugin.pending.single.date.day, 19);
      await adapter.update(
        account(user: 'two', zone: 'Asia/Tokyo', reminder: '10:15'),
      );
      expect(plugin.cancellations, 4);
    },
  );

  test(
    'disable, logout, demo and explicit clear cancel all scheduled reminders',
    () async {
      for (final data in [
        account(enabled: false),
        const AppData(),
        account(demo: true),
      ]) {
        await adapter.update(account());
        expect(plugin.pending, isNotEmpty);
        await adapter.update(data);
        expect(plugin.pending, isEmpty);
      }
      await adapter.update(account());
      await adapter.clear();
      expect(plugin.pending, isEmpty);
      await adapter.update(account());
      expect(plugin.pending, hasLength(1));
    },
  );

  test(
    'Windows schedules thirty future dates and renews the next day',
    () async {
      adapter = NotificationAdapter(
        plugin: plugin,
        clock: () => now,
        isWindows: true,
      )..ready = true;
      await adapter.update(account());
      expect(plugin.pending, hasLength(30));
      expect(plugin.pending.first.date.day, 18);
      expect(
        plugin.pending.last.date,
        tz.TZDateTime(tz.getLocation('Europe/Moscow'), 2026, 12, 17, 9),
      );
      expect(plugin.pending.map((n) => n.id).toSet(), hasLength(30));
      expect(plugin.pending.every((n) => n.repeat == null), isTrue);
      now = DateTime.utc(2026, 11, 19, 5);
      await adapter.update(account());
      expect(plugin.pending, hasLength(30));
      expect(plugin.pending.first.date.day, 19);
      expect(plugin.pending.last.date.day, 18);
    },
  );

  test(
    'calendar scheduling preserves local hour across daylight saving',
    () async {
      now = DateTime.utc(2026, 10, 24, 5);
      adapter = NotificationAdapter(
        plugin: plugin,
        clock: () => now,
        isWindows: true,
      )..ready = true;
      await adapter.update(account(zone: 'Europe/Berlin'));
      expect(plugin.pending.every((n) => n.date.hour == 9), isTrue);
      expect(
        plugin.pending[1].date.difference(plugin.pending[0].date),
        const Duration(hours: 25),
      );
    },
  );

  test('failed scheduling is retried on the next session update', () async {
    plugin.fail = true;
    await expectLater(adapter.update(account()), throwsStateError);
    plugin.fail = false;
    await adapter.update(account());
    expect(plugin.pending, hasLength(1));
  });

  test(
    'cold start replaces schedules left by a previous app version',
    () async {
      await adapter.update(account());
      final restarted = NotificationAdapter(
        plugin: plugin,
        clock: () => now,
        isWindows: false,
      )..ready = true;
      await restarted.update(account());
      expect(plugin.cancellations, 2);
      expect(plugin.pending, hasLength(1));
      expect(
        NotificationAdapter.routeForPayload('legacy-article'),
        '/article/legacy-article',
      );
    },
  );
}
