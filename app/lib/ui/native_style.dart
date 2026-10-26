import 'package:flutter/material.dart';

import 'palette.dart';

Color nativeTextColor(BuildContext context) =>
    AppPalette.of(context).foreground;

class NativeText extends StatelessWidget {
  const NativeText(
    this.text, {
    super.key,
    required this.size,
    this.color,
    this.bold = false,
  });

  final String text;
  final double size;
  final Color? color;
  final bool bold;

  static TextStyle style(double size, Color color, bool bold) => TextStyle(
    fontFamily: 'Roboto',
    fontSize: size,
    fontWeight: bold ? FontWeight.bold : FontWeight.normal,
    color: color,
    height: 1,
  );

  static double fitSize(
    BuildContext context,
    String text, {
    required double maxSize,
    required double width,
    double height = double.infinity,
    bool bold = false,
  }) {
    final painter = TextPainter(
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    );
    bool fits(double size) {
      painter.text = TextSpan(
        text: text,
        style: style(size, nativeTextColor(context), bold),
      );
      painter.layout();
      return painter.width <= width && painter.height <= height;
    }

    var lower = 0.0;
    var upper = maxSize;
    if (fits(upper)) {
      lower = upper;
    } else {
      for (var i = 0; i < 12; i++) {
        final middle = (lower + upper) / 2;
        if (fits(middle)) {
          lower = middle;
        } else {
          upper = middle;
        }
      }
    }
    painter.dispose();
    return lower;
  }

  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: TextAlign.center,
    maxLines: 1,
    softWrap: false,
    style: style(size, color ?? nativeTextColor(context), bold),
  );
}
