import 'dart:math' as math;

import 'package:easytimer/ui/palette.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double _contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return (math.max(x, y) + .05) / (math.min(x, y) + .05);
}

void main() {
  for (final brightness in Brightness.values) {
    test('text and phases meet AAA contrast in $brightness', () {
      final colors = AppPalette.forBrightness(brightness);
      expect(_contrast(colors.foreground, colors.background), 21);
      expect(
        _contrast(colors.active, colors.background),
        greaterThanOrEqualTo(7),
      );
      expect(
        _contrast(colors.rest, colors.background),
        greaterThanOrEqualTo(7),
      );
      expect(
        _contrast(colors.foreground, colors.track),
        greaterThanOrEqualTo(7),
      );
    });
  }
}
