import 'package:easytimer/app.dart';
import 'package:easytimer/platform/timer_platform.dart';
import 'package:easytimer/settings.dart';
import 'package:easytimer/timer_engine.dart';
import 'package:easytimer/workout_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Clock implements MonotonicClock {
  @override
  int nowMs = 0;
}

class _Platform extends TimerPlatform {
  bool awake = false;
  double gain = 1;
  int unlocks = 0;

  @override
  Future<void> initialize() async {}
  @override
  void unlock() => unlocks++;
  @override
  void schedule(List<SoundEvent> events, MonotonicClock clock) {}
  @override
  void cancel({bool keepEnd = false}) {}
  @override
  void setVolume(double value) => gain = value;
  @override
  void keepAwake(bool enabled) => awake = enabled;
  @override
  void dispose() {}
}

void main() {
  late _Clock clock;
  late _Platform platform;
  late WorkoutController controller;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    clock = _Clock();
    platform = _Platform();
    controller = WorkoutController(
      await TimerSettings.load(),
      platform,
      clock: clock,
    );
  });

  tearDown(() => controller.dispose());

  Future<void> mount(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
  }) async {
    await tester.pumpWidget(
      EasyTimerApp(controller: controller, locale: locale),
    );
    await tester.pumpAndSettle();
  }

  void timerTest(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        controller.stop();
        await tester.pumpWidget(const SizedBox());
      }
    });
  }

  timerTest('settings edits, clamps, falls back, and persists on start', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text('Active'), findsOneWidget);
    expect(find.text('Rest'), findsOneWidget);
    expect(find.text('Sets'), findsOneWidget);
    await tester.tap(find.byTooltip('Decrease Active Time'));
    await tester.pump();
    expect(find.text('40'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), '');
    await tester.tap(find.byTooltip('Increase Active Time'));
    await tester.pump();
    expect(find.text('50'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), '0');
    await tester.enterText(find.byType(TextField).at(1), '0');
    await tester.enterText(find.byType(TextField).at(2), '2');
    await tester.tap(find.bySemanticsLabel('Start'));
    await tester.pump();
    expect(controller.engine.options.active, 5);
    expect(controller.engine.options.rest, 0);
    expect(controller.engine.options.sets, 2);
    expect(controller.settings.preferences.getInt('sets'), 2);
  });

  timerTest('start, pause, resume and stop keep the screen awake', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.bySemanticsLabel('Start'));
    await tester.pump();
    expect(find.text('PREPARE'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    expect(platform.awake, isTrue);
    clock.nowMs = 5000;
    controller.refresh();
    await tester.pump();
    expect(find.text('ACTIVE'), findsOneWidget);
    expect(find.text('45'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Pause'));
    await tester.pump();
    expect(controller.display.mode, TimerMode.paused);
    expect(platform.awake, isTrue);
    await tester.tap(find.bySemanticsLabel('Resume'));
    await tester.pump();
    expect(controller.display.mode, TimerMode.running);
    await tester.tap(find.bySemanticsLabel('Stop'));
    await tester.pump();
    expect(find.text('Active'), findsOneWidget);
    expect(platform.awake, isFalse);
  });

  timerTest('empty fields use defaults and zero sets is unlimited', (
    tester,
  ) async {
    await mount(tester);
    for (final field in find.byType(TextField).evaluate().toList()) {
      await tester.enterText(find.byWidget(field.widget), '');
    }
    await tester.tap(find.bySemanticsLabel('Start'));
    await tester.pump();
    expect(controller.engine.options.active, 45);
    expect(controller.engine.options.rest, 15);
    expect(controller.engine.options.sets, 0);
    expect(controller.settings.preferences.getInt('activeTime'), 45);
  });

  timerTest('minimum values and a finite workout return to settings', (
    tester,
  ) async {
    await mount(tester);
    await tester.enterText(find.byType(TextField).at(0), '0');
    await tester.enterText(find.byType(TextField).at(1), '0');
    await tester.enterText(find.byType(TextField).at(2), '1');
    await tester.tap(find.bySemanticsLabel('Start'));
    await tester.pump();
    expect(controller.engine.options.active, 5);
    clock.nowMs = 10000;
    controller.refresh();
    await tester.pump();
    expect(find.text('Active'), findsOneWidget);
    expect(platform.awake, isFalse);
    expect(find.text('5'), findsOneWidget);
  });

  timerTest(
    'Space starts and toggles pause; arrows change gain; Escape stops',
    (tester) async {
      await mount(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(controller.showingTimer, isTrue);
      expect(platform.unlocks, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(controller.display.mode, TimerMode.paused);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(controller.volume, closeTo(.95, .0001));
      expect(platform.gain, closeTo(.9025, .0001));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(controller.volume, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(controller.display.mode, TimerMode.running);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(controller.showingTimer, isFalse);
    },
  );

  timerTest('shortcuts also work with a number field or slider focused', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(controller.showingTimer, isTrue);
    await tester.tap(find.byType(Slider));
    await tester.pump();
    final before = controller.volume;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(controller.volume, closeTo(before - .05, .0001));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(controller.display.mode, TimerMode.paused);
  });

  for (final (locale, active) in [
    ('cs', 'Aktivita'),
    ('ca', 'Esforç'),
    ('es', 'Trabajo'),
    ('fr', 'Effort'),
  ]) {
    timerTest('$locale follows the system locale', (tester) async {
      tester.binding.platformDispatcher.localesTestValue = [Locale(locale)];
      addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
      await tester.pumpWidget(EasyTimerApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.text(active), findsOneWidget);
    });
  }

  timerTest('unknown locales fall back to English', (tester) async {
    await mount(tester, locale: const Locale('ja'));
    expect(find.text('Active'), findsOneWidget);
  });
}
