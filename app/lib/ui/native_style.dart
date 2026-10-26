import 'package:flutter/material.dart';

import 'palette.dart';

Color nativeTextColor(BuildContext context) =>
    AppPalette.of(context).foreground;

double nativeDimension(BuildContext context, double value, [double scale = 1]) {
  final density = MediaQuery.devicePixelRatioOf(context);
  return ((value * density).round() * scale).round() / density;
}

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

  // Android TextView includes the font's top/bottom bounds outside its line metrics.
  static EdgeInsets fontPadding(double size) =>
      EdgeInsets.only(top: size * 263 / 2048, bottom: size * 55 / 2048);

  static TextStyle style(double size, Color color, bool bold) => TextStyle(
    fontFamily: 'Roboto',
    fontSize: size,
    fontWeight: bold ? FontWeight.bold : FontWeight.normal,
    color: color,
    height: 2400 / 2048,
  );

  static double measure(
    BuildContext context,
    String text,
    double size,
    double width, {
    bool bold = false,
  }) {
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: style(size, nativeTextColor(context), bold),
      ),
      textDirection: direction,
      textScaler: scaler,
    )..layout(maxWidth: width);
    final result = painter.height + fontPadding(scaler.scale(size)).vertical;
    painter.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: fontPadding(MediaQuery.textScalerOf(context).scale(size)),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: style(size, color ?? nativeTextColor(context), bold),
    ),
  );
}
