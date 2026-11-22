import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:margo/app/widgets.dart';
import 'package:margo/app/theme.dart';

void main() {
  testWidgets('heading and art support mobile width and enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: margoTheme(Brightness.light),
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: const SingleChildScrollView(
              child: Padding(
                padding: EdgeInsets.all(21),
                child: Column(
                  children: [
                    PageHeading(
                      eyebrow: 'ОДНО ОТКРЫТИЕ',
                      title: 'Мир больше, чем кажется.',
                      description: 'Остановитесь на несколько минут.',
                    ),
                    MechanismArt(height: 250),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Мир больше, чем кажется.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
