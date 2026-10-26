import 'package:flutter/material.dart';

class AppPalette {
  const AppPalette._(
    this.background,
    this.foreground,
    this.active,
    this.rest,
    this.track,
  );

  static const light = AppPalette._(
    Colors.white,
    Colors.black,
    Color(0xff005a00),
    Color(0xff8b0000),
    Color(0xffbdbdbd),
  );
  static const dark = AppPalette._(
    Colors.black,
    Colors.white,
    Color(0xff90ee90),
    Color(0xffff8a80),
    Color(0xff424242),
  );
  static const playFill = Color(0xff88d86c);
  static const pauseFill = Color(0xfff1ee0e);
  static const stopFill = Color(0xffcd4d2c);

  final Color background;
  final Color foreground;
  final Color active;
  final Color rest;
  final Color track;

  static AppPalette forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  static AppPalette of(BuildContext context) =>
      forBrightness(Theme.of(context).brightness);
}
