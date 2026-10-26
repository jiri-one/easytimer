import 'package:easytimer/settings.dart';
import 'package:easytimer/timer_engine.dart';
import 'package:easytimer/workout_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final preferenceCases = <(Map<String, Object>, (int, int, int, int))>[
    ({}, (45, 15, 0, 100)),
    (
      {'activeTime': 60, 'restTime': 20, 'sets': 8, 'volumePercent': 40},
      (60, 20, 8, 40),
    ),
    (
      {'activeTime': 0, 'restTime': 0, 'sets': 0, 'volumePercent': -1},
      (5, 0, 0, 0),
    ),
    (
      {'activeTime': -1, 'restTime': -2, 'sets': -3, 'volumePercent': 200},
      (45, 15, 0, 100),
    ),
    (
      {'activeTime': 60.0, 'restTime': 20.0, 'sets': 8.0, 'volumePercent': 1},
      (60, 20, 8, 1),
    ),
    ({'volumePercent': 35.0, 'volume': .9}, (45, 15, 0, 35)),
    ({'volume': .35}, (45, 15, 0, 100)),
    (
      {'activeTime': -.4, 'restTime': 10000, 'sets': double.infinity},
      (45, 15, 0, 100),
    ),
    for (final (key, invalid) in [
      ('activeTime', '45'),
      ('restTime', true),
      ('sets', <String>['2']),
      ('volumePercent', 'loud'),
      ('volumePercent', double.nan),
      ('volumePercent', double.infinity),
    ])
      (
        {
          'activeTime': 60,
          'restTime': 20,
          'sets': 8,
          'volumePercent': 40,
          key: invalid,
        },
        (
          key == 'activeTime' ? 45 : 60,
          key == 'restTime' ? 15 : 20,
          key == 'sets' ? 0 : 8,
          key == 'volumePercent' ? 100 : 40,
        ),
      ),
  ];
  for (final (index, (values, expected)) in preferenceCases.indexed) {
    test('preference normalization case $index preserves valid neighbours', () {
      final settings = TimerSettings(RecordingPreferences(values));
      expect((
        settings.options.active,
        settings.options.rest,
        settings.options.sets,
        settings.volumePercent,
      ), expected);
    });
  }

  test('failed load and writes retain usable in-memory settings', () async {
    final settings = await TimerSettings.load(
      loader: () async => throw const FormatException('Malformed JSON'),
    );
    await settings.saveOptions(
      const WorkoutOptions(active: 25, rest: 0, sets: 4),
    );
    await settings.saveVolume(70);
    expect(settings.preferences, isNull);
    expect(
      (
        settings.options.active,
        settings.options.rest,
        settings.options.sets,
        settings.volumePercent,
      ),
      (25, 0, 4, 100),
    );
    final broken = TimerSettings(RecordingPreferences()..failWrites = true);
    await broken.saveOptions(const WorkoutOptions(active: 30));
    await broken.saveVolume(50);
    expect((broken.options.active, broken.volumePercent), (30, 100));
  });

  test(
    'writes only changed keys through the percent persistence path',
    () async {
      final preferences = RecordingPreferences({
        'activeTime': 45,
        'restTime': 15,
        'sets': 0,
        'volumePercent': 35,
      });
      final settings = TimerSettings(preferences);
      await settings.saveOptions(const WorkoutOptions());
      expect(preferences.writes, isEmpty);
      await settings.saveOptions(const WorkoutOptions(rest: 20));
      await settings.saveVolume(40);
      expect(preferences.writes, [('restTime', 20), ('volumePercent', 40)]);
      await settings.saveOptions(const WorkoutOptions(rest: 20));
      await settings.saveVolume(40);
      expect(preferences.writes, hasLength(2));
      expect(settings.volumePercent, 35);
      expect(TimerSettings(preferences).volumePercent, 40);
    },
  );

  testWidgets(
    'start and late completion use the normal deadline-free cue plan',
    (tester) async {
      final clock = FakeClock();
      final platform = RecordingTimerPlatform();
      final controller = await createTestController(
        tester,
        clock: clock,
        platform: platform,
      );
      var screens = 0;
      var displays = 0;
      controller.showingTimer.addListener(() => screens++);
      controller.display.addListener(() => displays++);
      controller.start(const WorkoutOptions(active: 5, rest: 0, sets: 1));
      await tester.pump();
      expect(controller.showingTimer.value, isTrue);
      expect(platform.calls, ['setVolume', 'cancel', 'keepAwake', 'schedule']);
      expect((screens, displays), (1, 1));
      expect(controller.settings.preferences!.get('activeTime'), 5);
      await advanceClock(tester, clock, 60000);
      expect(controller.showingTimer.value, isFalse);
      expect(controller.display.value.mode, TimerMode.complete);
      expect((screens, displays), (2, 2));
      expect(platform.cancellations, 1);
      expect(platform.awake, [true, false]);
      final end = platform.schedules.last.events.single;
      expect(
        (end.kind, end.atMs, end.deadlineMs),
        (SoundKind.end, 10000, null),
      );
      final count = platform.schedules.length;
      controller.refresh();
      controller.togglePause();
      expect(platform.schedules, hasLength(count));
    },
  );

  for (final (at, phase, remaining) in [
    (2250, TimerPhase.prepare, 5000),
    (7001, TimerPhase.active, 2999),
    (11234, TimerPhase.prepare, 5000),
  ]) {
    testWidgets(
      'pause/resume at $at keeps the screen awake and reanchors cues',
      (tester) async {
        final clock = FakeClock();
        final platform = RecordingTimerPlatform();
        final controller = await createTestController(
          tester,
          clock: clock,
          platform: platform,
        );
        controller.start(const WorkoutOptions(active: 5, rest: 3, sets: 2));
        clock.nowMs = at;
        controller.refresh();
        controller.togglePause();
        final paused = controller.display.value.remainingMs;
        expect(platform.cancellations, 2);
        final count = platform.schedules.length;
        await advanceClock(tester, clock, 60000);
        expect(controller.display.value.remainingMs, paused);
        expect(platform.schedules, hasLength(count));
        expect(platform.awake, [true]);
        controller.togglePause();
        expect(
          (
            controller.display.value.phase,
            controller.display.value.remainingMs,
          ),
          (phase, remaining),
        );
        controller.stop();
        expect(controller.display.value, same(stoppedSnapshot));
        expect(controller.showingTimer.value, isFalse);
        expect(platform.awake.last, isFalse);
        final stopped = platform.schedules.length;
        await advanceClock(tester, clock, 300000);
        expect(platform.schedules, hasLength(stopped));
      },
    );
  }

  testWidgets(
    'only changed whole-second displays notify; screen listens separately',
    (tester) async {
      final clock = FakeClock();
      final controller = await createTestController(tester, clock: clock);
      controller.start(const WorkoutOptions());
      var screens = 0;
      var displays = 0;
      controller.showingTimer.addListener(() => screens++);
      controller.display.addListener(() => displays++);
      for (final at in [1, 50, 499, 999, 1000, 1001, 1999, 2000]) {
        clock.nowMs = at;
        controller.refresh();
        expect(displays, at ~/ 1000);
        expect(screens, 0);
      }
      controller.stop();
    },
  );

  testWidgets(
    'integer volume applies live, reaches exact mute and saves after debounce',
    (tester) async {
      final platform = RecordingTimerPlatform();
      final controller = await createTestController(
        tester,
        platform: platform,
        preferences: {'volumePercent': 35},
      );
      var screens = 0;
      var displays = 0;
      controller.showingTimer.addListener(() => screens++);
      controller.display.addListener(() => displays++);
      for (var step = 0; step < 7; step++) {
        controller.stepVolume(-5);
      }
      expect(controller.volume.value, 0);
      expect(platform.volumes, [35, 30, 25, 20, 15, 10, 5, 0]);
      expect(controller.settings.preferences!.get('volumePercent'), 35);
      await tester.pump(const Duration(milliseconds: 249));
      expect(controller.settings.preferences!.get('volumePercent'), 35);
      await tester.pump(const Duration(milliseconds: 1));
      expect(controller.settings.preferences!.get('volumePercent'), 0);
      controller.changeVolume(-1);
      controller.stepVolume(1000);
      controller.changeVolume(200);
      expect(controller.volume.value, 100);
      expect(platform.volumes.last, 100);
      expect((screens, displays), (0, 0));
      await tester.pump(const Duration(milliseconds: 250));
      expect(controller.settings.preferences!.get('volumePercent'), 100);
    },
  );

  testWidgets('dispose flushes pending volume and cancels display updates', (
    tester,
  ) async {
    final preferences = RecordingPreferences();
    final platform = RecordingTimerPlatform();
    final controller = WorkoutController(
      TimerSettings(preferences),
      platform,
      clock: FakeClock(),
      keepAwake: platform.keepAwake,
    );
    controller.start(const WorkoutOptions());
    controller.changeVolume(40);
    controller.dispose();
    await tester.pump(const Duration(seconds: 10));
    expect(preferences.get('volumePercent'), 40);
    expect(platform.cancellations, 2);
    expect(platform.awake.last, isFalse);
  });
}
