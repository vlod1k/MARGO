import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'notifications/notification_adapter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await notifications.initialize(
      (payload) => appRouter.go(NotificationAdapter.routeForPayload(payload)),
    );
  } catch (e) {
    notifications.error = e.toString();
  }
  runApp(const ProviderScope(child: MargoApp()));
}
