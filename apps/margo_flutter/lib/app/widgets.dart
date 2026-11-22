import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

class Brand extends StatelessWidget {
  final bool compact, inverse;
  const Brand({super.key, this.compact = false, this.inverse = false});
  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.centerLeft,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 37,
          height: 49,
          child: CustomPaint(painter: CrownPainter()),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'MARGO',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: compact ? 26 : 32,
                letterSpacing: 1.8,
                color: inverse
                    ? ivory
                    : Theme.of(context).colorScheme.onSurface,
              ),
            ),
            if (!compact)
              Text(
                'Каждый день — открытие',
                style: TextStyle(
                  color: inverse
                      ? sand
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 11,
                ),
              ),
          ],
        ),
      ],
    ),
  );
}

class CrownPainter extends CustomPainter {
  const CrownPainter();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 45, size.height / 55);
    final p = Paint()
      ..color = gold
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 1.6;
    final path = Path()
      ..moveTo(7, 17)
      ..lineTo(15, 25)
      ..lineTo(22.5, 10)
      ..lineTo(30, 25)
      ..lineTo(38, 17)
      ..lineTo(34, 37)
      ..lineTo(11, 37)
      ..close();
    canvas.drawPath(path, p);
    canvas.drawLine(const Offset(11, 42), const Offset(34, 42), p);
    canvas.drawCircle(const Offset(22.5, 5), 2, p);
    canvas.drawCircle(const Offset(22.5, 32), 1.5, p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class MechanismArt extends StatelessWidget {
  final double height;
  const MechanismArt({super.key, this.height = 350});
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Стилизованная иллюстрация древнего астрономического механизма',
    child: Container(
      width: double.infinity,
      height: height,
      decoration: BoxDecoration(
        gradient: RadialGradient(
          colors: [
            Color.alphaBlend(
              Theme.of(context).colorScheme.primary.withValues(alpha: .24),
              ink,
            ),
            ink,
          ],
          radius: .9,
        ),
      ),
      child: const CustomPaint(painter: MechanismPainter()),
    ),
  );
}

class MechanismPainter extends CustomPainter {
  const MechanismPainter();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.translate(size.width / 2, size.height / 2 + 10);
    final radius = math.min(size.width, size.height) * .32;
    final orbit = Paint()
      ..color = ivory.withValues(alpha: .2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final scale in [1.3, 1.4]) {
      canvas.drawCircle(Offset.zero, radius * scale, orbit);
    }
    canvas.rotate(-.27);
    final outline = Path();
    for (var i = 0; i < 8; i++) {
      final a = i * math.pi / 4;
      final x = radius * 1.12 * math.cos(a), y = radius * 1.12 * math.sin(a);
      if (i == 0) {
        outline.moveTo(x, y);
      } else {
        outline.lineTo(x, y);
      }
    }
    outline.close();
    canvas.drawShadow(outline, Colors.black54, 18, true);
    canvas.drawPath(outline, Paint()..color = const Color(0xff65705a));
    canvas.drawPath(
      outline,
      Paint()
        ..color = const Color(0xffb2a16b)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8,
    );
    void gear(Offset center, double r) {
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..shader = const LinearGradient(
            colors: [Color(0xffc3b17c), Color(0xff757956)],
          ).createShader(Rect.fromCircle(center: center, radius: r)),
      );
      for (final scale in [1.0, .92, .78, .57]) {
        canvas.drawCircle(
          center,
          r * scale,
          Paint()
            ..color = const Color(0xffe6d69e).withValues(alpha: .6)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
      for (var i = 0; i < 64; i++) {
        final a = i * math.pi / 32;
        canvas.drawLine(
          center + Offset(math.cos(a) * r * .85, math.sin(a) * r * .85),
          center + Offset(math.cos(a) * r * .95, math.sin(a) * r * .95),
          Paint()
            ..color = sand.withValues(alpha: .5)
            ..strokeWidth = 2,
        );
      }
      for (var i = 0; i < 6; i++) {
        final a = i * math.pi / 3;
        canvas.drawLine(
          center,
          center + Offset(math.cos(a) * r * .78, math.sin(a) * r * .78),
          Paint()
            ..color = const Color(0xff667154)
            ..strokeWidth = r * .08,
        );
      }
      canvas.drawCircle(
        center,
        r * .23,
        Paint()..color = const Color(0xffb3a36f),
      );
      canvas.drawCircle(
        center,
        r * .1,
        Paint()..color = const Color(0xff7c815b),
      );
    }

    gear(Offset.zero, radius * .9);
    gear(Offset(radius * .67, radius * .5), radius * .34);
    gear(Offset(-radius * .65, -radius * .5), radius * .29);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class PageHeading extends StatelessWidget {
  final String eyebrow, title, description;
  const PageHeading({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.description,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 32),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          eyebrow,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: Theme.of(context).colorScheme.primary),
        ),
        const SizedBox(height: 13),
        Text(title, style: Theme.of(context).textTheme.headlineLarge),
        const SizedBox(height: 9),
        Text(
          description,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );
}

Future<void> runUi(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }
}
