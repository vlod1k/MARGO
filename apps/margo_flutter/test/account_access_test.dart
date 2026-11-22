import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:margo/data/local_database.dart';
import 'package:margo/data/repository.dart';
import 'package:margo/features/onboarding/account_access_dialog.dart';
import 'package:margo/sync/controller.dart';

import 'session_lifecycle_test.dart' show UnusedDatabase;

class AccessRepository extends MargoRepository {
  AccessRepository() : super(LocalDatabase(UnusedDatabase()));
  String? requestedEmail,
      submittedEmail,
      submittedCode,
      oldPassword,
      newPassword;
  bool reject = false;

  @override
  Future<void> requestPasswordReset(String email) async {
    requestedEmail = email;
  }

  @override
  Future<void> confirmPasswordReset(
    String email,
    String code,
    String password,
  ) async {
    if (reject) {
      throw StateError('Код недействителен или истёк. Запросите новый.');
    }
    submittedEmail = email;
    submittedCode = code;
    newPassword = password;
  }

  @override
  Future<void> changePassword(String current, String next) async {
    oldPassword = current;
    newPassword = next;
  }
}

Future<void> openDialog(
  WidgetTester tester,
  AccessRepository repository, {
  bool change = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [repositoryProvider.overrideWith((ref) async => repository)],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AccountAccessDialog(changePassword: change),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

Future<void> enter(WidgetTester tester, String label, String value) async {
  final field = find.widgetWithText(TextFormField, label);
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
}

void main() {
  testWidgets('request recovery then confirm with matching password', (
    tester,
  ) async {
    final repo = AccessRepository();
    await openDialog(tester, repo);
    await enter(tester, 'Email аккаунта', 'reader@example.com');
    await tester.tap(find.text('Отправить код'));
    await tester.pumpAndSettle();
    expect(repo.requestedEmail, 'reader@example.com');
    expect(find.textContaining('Если аккаунт существует'), findsOneWidget);
    final code = '012345';
    await enter(tester, 'Код из письма', code);
    await enter(tester, 'Новый пароль', 'newpass8');
    await enter(tester, 'Повторите новый пароль', 'different-password');
    await tester.tap(find.text('Изменить пароль'));
    await tester.pumpAndSettle();
    expect(find.text('Пароли не совпадают'), findsOneWidget);
    expect(repo.submittedCode, isNull);
    await enter(tester, 'Повторите новый пароль', 'newpass8');
    await tester.tap(find.text('Изменить пароль'));
    await tester.pumpAndSettle();
    expect(repo.submittedEmail, 'reader@example.com');
    expect(repo.submittedCode, code);
    expect(repo.newPassword, 'newpass8');
    expect(find.textContaining('Войдите с новым паролем'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
  });

  testWidgets('existing recovery code shows error and allows retry', (
    tester,
  ) async {
    final repo = AccessRepository()..reject = true;
    await openDialog(tester, repo);
    await tester.tap(find.text('У меня есть код'));
    await tester.pumpAndSettle();
    await enter(tester, 'Email аккаунта', 'reader@example.com');
    await enter(tester, 'Код из письма', '012345');
    await enter(tester, 'Новый пароль', 'newpass8');
    await enter(tester, 'Повторите новый пароль', 'newpass8');
    await tester.tap(find.text('Изменить пароль'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Код недействителен'), findsOneWidget);
    await tester.ensureVisible(find.text('Запросить новый код'));
    await tester.tap(find.text('Запросить новый код'));
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(TextFormField, 'Email аккаунта'),
      findsOneWidget,
    );
  });

  testWidgets(
    'change password submits current password and confirms session behavior',
    (tester) async {
      final repo = AccessRepository();
      await openDialog(tester, repo, change: true);
      await enter(tester, 'Текущий пароль', 'oldpass8');
      await enter(tester, 'Новый пароль', 'newpass8');
      await enter(tester, 'Повторите новый пароль', 'newpass8');
      await tester.tap(find.text('Изменить пароль'));
      await tester.pumpAndSettle();
      expect(repo.oldPassword, 'oldpass8');
      expect(repo.newPassword, 'newpass8');
      expect(
        find.textContaining('На этом устройстве вход сохранён'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
