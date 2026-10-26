import 'package:flutter/material.dart';

typedef _TextMeasure = (
  Object,
  double,
  double,
  bool,
  TextScaler,
  TextDirection,
);

Color nativeTextColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xffc1c1c1)
    : const Color(0xff6f6f6f);

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

  static final _digits = RegExp(r'^[0-9]+$');
  static final _heights = _createHeightCache();

  static Map<_TextMeasure, double> _createHeightCache() {
    final cache = <_TextMeasure, double>{};
    // Font loading must replace any metrics measured with fallback fonts.
    PaintingBinding.instance.systemFonts.addListener(cache.clear);
    return cache;
  }

  // Android TextView includes the font's top/bottom bounds outside its line metrics.
  static EdgeInsets fontPadding(double size) =>
      EdgeInsets.only(top: size * 263 / 2048, bottom: size * 55 / 2048);

  static TextStyle style(double size, Color color, bool bold) => TextStyle(
    fontFamily: 'DroidSansMono',
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
    // Every digit has the same metrics in Droid Sans Mono.
    final key = (
      _digits.hasMatch(text) ? text.length : text,
      size,
      width,
      bold,
      scaler,
      direction,
    );
    final cached = _heights[key];
    if (cached != null) return cached;
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
    if (_heights.length == 128) _heights.remove(_heights.keys.first);
    _heights[key] = result;
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
