import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../app/widgets.dart';
import '../../data/repository.dart';
import '../../sync/controller.dart';
import 'account_access_dialog.dart';

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});
  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final form = GlobalKey<FormState>();
  final email = TextEditingController(),
      password = TextEditingController(),
      name = TextEditingController(text: 'Исследователь');
  bool register = false, busy = false, hidden = true;
  String? error;
  @override
  void dispose() {
    email.dispose();
    password.dispose();
    name.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await ref
          .read(sessionProvider.notifier)
          .authenticate(
            email.text,
            password.text,
            name: register ? name.text : null,
          );
      if (mounted) {
        final completed =
            ref.read(sessionProvider).asData?.value.profile?['onboarded'] ==
            true;
        context.go(completed ? '/' : '/onboarding');
      }
    } catch (e) {
      if (mounted) setState(() => error = apiError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> tryDemo() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await ref.read(sessionProvider.notifier).enterDemo();
      if (mounted) context.go('/');
    } catch (e) {
      if (mounted) setState(() => error = apiError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: LayoutBuilder(
      builder: (context, size) => Row(
        children: [
          if (size.maxWidth >= 1000 && size.maxHeight >= 650)
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color.alphaBlend(
                        Theme.of(context).colorScheme.primary
                            .withValues(alpha: .16),
                        ink,
                      ),
                      ink,
                    ],
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(64),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Brand(inverse: true),
                      const Spacer(),
                      const Text(
                        'Знание начинается\nс любопытства.',
                        style: TextStyle(
                          color: ivory,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -1.5,
                          fontSize: 48,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 25),
                      const Text(
                        'Одна статья. Новый взгляд.\nКаждый день.',
                        style: TextStyle(
                          color: sand,
                          fontSize: 17,
                          height: 1.8,
                        ),
                      ),
                      const Spacer(),
                      const Text(
                        'MARGO · ПЕРСОНАЛЬНЫЙ ПРОВОДНИК ПО ЗНАНИЯМ',
                        style: TextStyle(
                          color: gold,
                          fontSize: 9,
                          letterSpacing: 1.7,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 410),
                  child: Form(
                    key: form,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (size.maxWidth < 1000 || size.maxHeight < 650) ...[
                          const Brand(compact: true),
                          const SizedBox(height: 38),
                        ],
                        Text(
                          register ? 'Начните свой путь.' : 'С возвращением.',
                          style: Theme.of(context).textTheme.headlineLarge,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          register
                              ? 'Одно небольшое открытие — каждый день.'
                              : 'Ваше следующее открытие уже ждёт.',
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 20),
                        if (ref.watch(sessionProvider).asData?.value.message !=
                            null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                              ref.watch(sessionProvider).asData!.value.message!,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton(
                            onPressed: busy ? null : tryDemo,
                            child: const Text(
                              'Попробовать без аккаунта',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                        const SizedBox(height: 7),
                        const Text(
                          'Демокаталог без сервера. Данные хранятся только на этом устройстве.',
                          style: TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                        const SizedBox(height: 25),
                        if (register) ...[
                          TextFormField(
                            controller: name,
                            decoration: const InputDecoration(
                              labelText: 'Ваше имя',
                            ),
                            validator: (v) => v == null || v.trim().isEmpty
                                ? 'Укажите имя'
                                : null,
                          ),
                          const SizedBox(height: 17),
                        ],
                        TextFormField(
                          controller: email,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.email],
                          decoration: const InputDecoration(
                            labelText: 'Электронная почта',
                          ),
                          validator: (v) => v == null || !v.contains('@')
                              ? 'Проверьте email'
                              : null,
                        ),
                        if (!register)
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => showDialog<void>(
                                    context: context,
                                    barrierDismissible: false,
                                    builder: (_) => const AccountAccessDialog(),
                                  ),
                            child: const Text('Забыли пароль?'),
                          ),
                        const SizedBox(height: 17),
                        TextFormField(
                          controller: password,
                          obscureText: hidden,
                          autofillHints: [
                            register
                                ? AutofillHints.newPassword
                                : AutofillHints.password,
                          ],
                          decoration: InputDecoration(
                            labelText: 'Пароль',
                            helperText: register ? 'Не менее 8 символов' : null,
                            suffixIcon: IconButton(
                              onPressed: () => setState(() => hidden = !hidden),
                              icon: Icon(
                                hidden
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                            ),
                          ),
                          validator: (v) => (v?.length ?? 0) < 8
                              ? 'Не менее 8 символов'
                              : null,
                          onFieldSubmitted: (_) => submit(),
                        ),
                        if (error != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            child: Text(
                              error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: busy ? null : submit,
                            child: busy
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Text(register ? 'Создать аккаунт' : 'Войти'),
                          ),
                        ),
                        const SizedBox(height: 17),
                        Center(
                          child: TextButton(
                            onPressed: busy
                                ? null
                                : () => setState(() {
                                    register = !register;
                                    error = null;
                                  }),
                            child: Text(
                              register
                                  ? 'Уже есть аккаунт? Войти'
                                  : 'Первое открытие? Создать аккаунт',
                            ),
                          ),
                        ),
                        const SizedBox(height: 25),
                        const Text(
                          'Никаких AI-сервисов и истории браузера. Только ваши интересы, открытия и оценки.',
                          style: TextStyle(
                            color: Colors.grey,
                            fontSize: 11,
                            height: 1.8,
                          ),
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
    ),
  );
}
