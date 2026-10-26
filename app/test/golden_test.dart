import 'package:easytimer/app.dart';
import 'package:easytimer/platform/timer_platform.dart';
import 'package:easytimer/settings.dart';
import 'package:easytimer/timer_engine.dart';
import 'package:easytimer/workout_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Clock implements MonotonicClock {
  @override
  int nowMs = 0;
}

class _SilentPlatform extends TimerPlatform {
  @override
  Future<void> initialize() async {}
  @override
  void unlock() {}
  @override
  void schedule(List<SoundEvent> events, MonotonicClock clock) {}
  @override
  void cancel({bool keepEnd = false}) {}
  @override
  void setVolume(double gain) {}
  @override
  void keepAwake(bool enabled) {}
  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final font = FontLoader('RobotoMono')
      ..addFont(rootBundle.load('assets/fonts/RobotoMono-Regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/RobotoMono-Bold.ttf'));
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait([font.load(), icons.load()]);
  });

  final sizes = [
    ('phone_150', const Size(824, 1648), 1.5),
    ('phone_1875', const Size(824, 1648), 1.875),
    ('phone_250', const Size(824, 1648), 2.5),
    ('desktop', const Size(420, 760), 1.0),
    ('wide', const Size(1440, 900), 1.0),
  ];

  Future<void> capture(
    WidgetTester tester,
    String name,
    Size size,
    double dpr, {
    bool timer = false,
    int time = 0,
    String locale = 'en',
    bool dark = false,
    bool paused = false,
  }) async {
    tester.view.devicePixelRatio = dpr;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    SharedPreferences.setMockInitialValues({});
    final clock = _Clock();
    final controller = WorkoutController(
      await TimerSettings.load(),
      _SilentPlatform(),
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
      controller.dispose();
    }
  }

  for (final (name, physicalSize, dpr) in sizes) {
    for (final timer in [false, true]) {
      testWidgets('${timer ? 'timer' : 'settings'} $name', (tester) async {
        await capture(
          tester,
          '${timer ? 'timer' : 'settings'}_$name',
          physicalSize,
          dpr,
          timer: timer,
        );
      });
    }
  }

  for (final (name, time, locale, dark, paused) in [
    ('active', 5000, 'en', false, false),
    ('rest_dark', 50000, 'cs', true, false),
    ('paused', 8500, 'fr', false, true),
  ]) {
    testWidgets('timer $name', (tester) async {
      await capture(
        tester,
        'timer_$name',
        const Size(824, 1648),
        1.875,
        timer: true,
        time: time,
        locale: locale,
        dark: dark,
        paused: paused,
      );
    });
  }
}
