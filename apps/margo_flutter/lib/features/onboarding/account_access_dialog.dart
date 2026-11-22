import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repository.dart';
import '../../sync/controller.dart';

class AccountAccessDialog extends ConsumerStatefulWidget {
  final bool changePassword;
  const AccountAccessDialog({super.key, this.changePassword = false});

  @override
  ConsumerState<AccountAccessDialog> createState() =>
      _AccountAccessDialogState();
}

class _AccountAccessDialogState extends ConsumerState<AccountAccessDialog> {
  final form = GlobalKey<FormState>();
  final email = TextEditingController();
  final code = TextEditingController();
  final current = TextEditingController();
  final password = TextEditingController();
  final repeat = TextEditingController();
  bool confirming = false, busy = false, complete = false;
  String? error, message;

  @override
  void dispose() {
    for (final controller in [email, code, current, password, repeat]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> submit() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final repository = await ref.read(repositoryProvider.future);
      if (widget.changePassword) {
        await repository.changePassword(current.text, password.text);
      } else if (confirming) {
        await repository.confirmPasswordReset(
          email.text,
          code.text,
          password.text,
        );
      } else {
        await repository.requestPasswordReset(email.text);
      }
      if (!mounted) return;
      setState(() {
        if (widget.changePassword || confirming) {
          complete = true;
          message = widget.changePassword
              ? 'Пароль изменён. Остальные сессии завершены. На этом устройстве вход сохранён.'
              : 'Пароль изменён. Все сессии завершены. Войдите с новым паролем.';
          current.clear();
          password.clear();
          repeat.clear();
          code.clear();
        } else {
          confirming = true;
          message = 'Если аккаунт существует, письмо с кодом будет отправлено. Проверьте также «Спам». Код действует 30 минут.';
        }
      });
    } catch (e) {
      if (mounted) setState(() => error = apiError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget passwordField(TextEditingController controller, String label) =>
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: TextFormField(
          controller: controller,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          maxLength: 128,
          decoration: InputDecoration(labelText: label, counterText: ''),
          validator: (v) {
            if ((v?.length ?? 0) < 8) return 'Не менее 8 символов';
            if (controller == repeat && v != password.text) {
              return 'Пароли не совпадают';
            }
            return null;
          },
        ),
      );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text(
        widget.changePassword ? 'Смена пароля' : 'Восстановление доступа',
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (message != null) Text(message!),
                if (!complete) ...[
                  if (widget.changePassword) ...[
                    const Text(
                      'После смены пароля остальные устройства выйдут из аккаунта.',
                    ),
                    passwordField(current, 'Текущий пароль'),
                  ] else ...[
                    TextFormField(
                      controller: email,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      decoration: const InputDecoration(
                        labelText: 'Email аккаунта',
                      ),
                      validator: (v) => (v != null && v.trim().contains('@'))
                          ? null
                          : 'Укажите email',
                    ),
                    if (confirming)
                      TextFormField(
                        controller: code,
                        keyboardType: TextInputType.number,
                        autofillHints: const [AutofillHints.oneTimeCode],
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(6),
                        ],
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(
                          labelText: 'Код из письма',
                        ),
                        validator: (v) =>
                            RegExp(r'^[0-9]{6}$').hasMatch(v?.trim() ?? '')
                            ? null
                            : 'Введите 6 цифр из письма',
                      ),
                  ],
                  if (widget.changePassword || confirming) ...[
                    passwordField(password, 'Новый пароль'),
                    passwordField(repeat, 'Повторите новый пароль'),
                  ],
                  if (!widget.changePassword)
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => setState(() {
                              confirming = !confirming;
                              error = null;
                              message = null;
                              form.currentState?.reset();
                            }),
                      child: Text(
                        confirming ? 'Запросить новый код' : 'У меня есть код',
                      ),
                    ),
                ],
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.of(context).pop(),
          child: Text(complete ? 'Готово' : 'Отмена'),
        ),
        if (!complete)
          FilledButton(
            onPressed: busy ? null : submit,
            child: Text(
              busy
                  ? 'Подождите…'
                  : widget.changePassword || confirming
                  ? 'Изменить пароль'
                  : 'Отправить код',
            ),
          ),
      ],
    ),
  );
}
