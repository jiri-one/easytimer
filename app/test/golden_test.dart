import 'package:easytimer/app.dart';
import 'package:easytimer/timer_engine.dart';
import 'package:easytimer/ui/controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadAppFont);

  Future<void> Function(WidgetTester, String) capture(
    Size size,
    double dpr, {
    bool timer = false,
    int time = 0,
    String locale = 'en',
    bool dark = false,
    bool paused = false,
    int volume = 100,
    bool showControls = false,
  }) => (tester, name) async {
    tester.view.devicePixelRatio = dpr;
    tester.view.physicalSize = size;
    final clock = FakeClock();
    final controller = await createTestController(
      tester,
      preferences: {'volumePercent': volume},
      clock: clock,
    );
    if (timer) {
      controller.start(const WorkoutOptions());
      clock.nowMs = time;
      controller.refresh();
      if (paused) controller.togglePause();
    }
    final boundary = GlobalKey();
    try {
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: EasyTimerApp(
            controller: controller,
            locale: Locale(locale),
            themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          ),
        ),
      );
      await tester.pump();
      if (showControls) {
        await tester.ensureVisible(find.byType(CircleControl).last);
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
      final image =
          await (boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: dpr);
      expect(image.width, size.width.round());
      expect(image.height, size.height.round());
      await expectLater(image, matchesGoldenFile('goldens/$name.png'));
      image.dispose();
    } finally {
      controller.stop();
      await tester.pumpWidget(const SizedBox());
    }
  };

  final captures = {
    for (final dark in [false, true]) ...{
      'contrast_settings_${dark ? 'dark' : 'light'}': capture(
        const Size(618, 1125),
        1.5,
        dark: dark,
        locale: 'cs',
      ),
      for (final (phase, time) in [
        ('prepare', 0),
        ('active', 5000),
        ('rest', 50000),
      ])
        'contrast_${phase}_${dark ? 'dark' : 'light'}': capture(
          const Size(618, 1125),
          1.5,
          timer: true,
          time: time,
          dark: dark,
          locale: 'cs',
          volume: 60,
        ),
    },
    'settings_phone_150': capture(const Size(824, 1648), 1.5),
    'settings_phone_1875': capture(const Size(824, 1648), 1.875),
    'settings_phone_250': capture(const Size(824, 1648), 2.5),
    'settings_desktop': capture(const Size(420, 760), 1),
    'settings_short': capture(const Size(640, 400), 1),
    'settings_wide': capture(const Size(1440, 900), 1),
    'timer_phone_150': capture(const Size(824, 1648), 1.5, timer: true),
    'timer_phone_1875': capture(const Size(824, 1648), 1.875, timer: true),
    'timer_phone_250': capture(const Size(824, 1648), 2.5, timer: true),
    'timer_desktop': capture(const Size(420, 760), 1, timer: true),
    'timer_short': capture(const Size(640, 400), 1, timer: true),
    'timer_wide': capture(const Size(1440, 900), 1, timer: true),
    'native_timer_light': capture(
      const Size(618, 985),
      1.5,
      timer: true,
      time: 5000,
      volume: 60,
    ),
    'native_timer_dark': capture(
      const Size(618, 985),
      1.5,
      timer: true,
      time: 5000,
      dark: true,
      volume: 60,
    ),
    'timer_short_controls': capture(
      const Size(640, 400),
      1,
      timer: true,
      paused: true,
      volume: 0,
      showControls: true,
    ),
    'timer_muted_light': capture(
      const Size(618, 985),
      1.5,
      timer: true,
      time: 5000,
      paused: true,
      volume: 0,
    ),
    'timer_muted_dark': capture(
      const Size(618, 985),
      1.5,
      timer: true,
      time: 5000,
      paused: true,
      dark: true,
      volume: 0,
    ),
    'native_settings': capture(const Size(618, 1125), 1.5),
    'timer_active': capture(
      const Size(824, 1648),
      1.875,
      timer: true,
      time: 5000,
    ),
    'timer_active_dark': capture(
      const Size(824, 1648),
      1.875,
      timer: true,
      time: 5000,
      dark: true,
    ),
    'timer_rest_dark': capture(
      const Size(824, 1648),
      1.875,
      timer: true,
      time: 50000,
      locale: 'cs',
      dark: true,
    ),
    'timer_paused': capture(
      const Size(824, 1648),
      1.875,
      timer: true,
      time: 8500,
      locale: 'fr',
      paused: true,
    ),
  };

  for (final entry in captures.entries) {
    testWidgets(entry.key, (tester) => entry.value(tester, entry.key));
  }
}
