import 'package:easytimer/settings.dart';
import 'package:easytimer/timer_engine.dart';
import 'package:easytimer/workout_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_support.dart';

class _ControllerHarness {
  _ControllerHarness(this.tester, this.settings) {
    controller = WorkoutController(settings, platform, clock: clock);
    controller.addListener(() => notifications++);
  }

  final WidgetTester tester;
  final TimerSettings settings;
  final platform = RecordingTimerPlatform();
  final clock = FakeClock();
  late final WorkoutController controller;
  int notifications = 0;

  Future<void> pump([int milliseconds = 0]) =>
      advanceClock(tester, clock, milliseconds);
}

void _controllerTest(
  String description,
  Future<void> Function(_ControllerHarness) body, {
  Map<String, Object> preferences = const {},
}) {
  testWidgets(description, (tester) async {
    SharedPreferences.setMockInitialValues(preferences);
    final harness = _ControllerHarness(tester, await TimerSettings.load());
    try {
      await body(harness);
    } finally {
      if (!harness.platform.disposed) harness.controller.dispose();
      await tester.pump();
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('settings', () {
    test('loads defaults from empty preferences', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = await TimerSettings.load();
      expect(
        (settings.options.active, settings.options.rest, settings.options.sets),
        (45, 15, 0),
      );
      expect(settings.volume, 1);
    });

    test('loads saved workout values and slider position', () async {
      SharedPreferences.setMockInitialValues({
        'activeTime': 60,
        'restTime': 20,
        'sets': 8,
        'volume': 0.4,
      });
      final settings = await TimerSettings.load();
      expect(
        (settings.options.active, settings.options.rest, settings.options.sets),
        (60, 20, 8),
      );
      expect(settings.volume, 0.4);
    });

    for (final (saved, expected) in [(-1.0, 0.0), (2.0, 1.0)]) {
      test('clamps saved volume $saved to $expected', () async {
        SharedPreferences.setMockInitialValues({'volume': saved});
        expect((await TimerSettings.load()).volume, expected);
      });
    }

    test('normalizes invalid saved durations and set counts', () async {
      SharedPreferences.setMockInitialValues({
        'activeTime': -1,
        'restTime': -2,
        'sets': -3,
      });
      final settings = await TimerSettings.load();
      expect(
        (settings.options.active, settings.options.rest, settings.options.sets),
        (45, 15, 0),
      );
      SharedPreferences.setMockInitialValues({
        'activeTime': 0,
        'restTime': 0,
        'sets': 0,
      });
      final zero = await TimerSettings.load();
      expect(
        (zero.options.active, zero.options.rest, zero.options.sets),
        (5, 0, 0),
      );
    });

    test(
      'saves options and clamped slider values to their existing keys',
      () async {
        SharedPreferences.setMockInitialValues({});
        final settings = await TimerSettings.load();
        await settings.saveOptions(
          const WorkoutOptions(active: 25, rest: 0, sets: 4),
        );
        await settings.saveVolume(0.6);
        await settings.preferences.reload();
        final saved = await TimerSettings.load();
        expect(
          (saved.options.active, saved.options.rest, saved.options.sets),
          (25, 0, 4),
        );
        expect(saved.volume, 0.6);
        expect(settings.preferences.getKeys(), {
          'activeTime',
          'restTime',
          'sets',
          'volume',
        });
        await settings.saveVolume(-3);
        expect(settings.preferences.getDouble('volume'), 0);
        await settings.saveVolume(3);
        expect(settings.preferences.getDouble('volume'), 1);
      },
    );
  });

  _controllerTest(
    'initialization applies squared saved gain and binds visibility',
    (h) async {
      expect(h.controller.showingTimer, isFalse);
      expect(h.controller.display.mode, TimerMode.stopped);
      expect(h.platform.gains.single, closeTo(0.16, 0.0000001));
      expect(h.platform.onVisibilityChanged, isNotNull);
      expect(h.platform.schedules, isEmpty);
      h.platform.onVisibilityChanged!();
      await h.pump(1000);
      expect(h.platform.schedules, isEmpty);
      expect(h.notifications, 0);
    },
    preferences: {'volume': 0.4},
  );

  _controllerTest(
    'start persists options, unlocks audio, and keeps the display awake',
    (h) async {
      const options = WorkoutOptions(active: 8, rest: 4, sets: 3);
      h.controller.start(options);
      await h.pump();
      expect(h.controller.showingTimer, isTrue);
      expect(h.controller.engine.options, same(options));
      expect(h.controller.display.mode, TimerMode.running);
      expect(h.controller.display.phase, TimerPhase.prepare);
      expect(h.controller.display.seconds, 5);
      expect(h.notifications, 1);
      expect(h.platform.calls, [
        'setVolume',
        'unlock',
        'cancel',
        'keepAwake',
        'schedule',
      ]);
      expect(h.platform.cancellations, [false]);
      expect(h.platform.awake, [true]);
      await h.settings.preferences.reload();
      final saved = await TimerSettings.load();
      expect(
        (saved.options.active, saved.options.rest, saved.options.sets),
        (8, 4, 3),
      );
    },
  );

  _controllerTest(
    'slider changes persist the raw value and apply squared gain',
    (h) async {
      h.controller.changeVolume(0.5);
      await h.pump();
      expect(h.controller.volume, 0.5);
      expect(h.settings.preferences.getDouble('volume'), 0.5);
      expect(h.platform.gains, [1, 0.25]);
      expect(h.notifications, 1);
      h.controller.changeVolume(0.5);
      await h.pump();
      expect(h.platform.gains, [1, 0.25]);
      expect(h.notifications, 1);
      h.controller.changeVolume(-1);
      await h.pump();
      expect(h.controller.volume, 0);
      expect(h.settings.preferences.getDouble('volume'), 0);
      h.controller.changeVolume(2);
      await h.pump();
      h.controller.changeVolume(3);
      expect(h.controller.volume, 1);
      expect(h.settings.preferences.getDouble('volume'), 1);
      expect(h.platform.gains, [1, 0.25, 0, 1]);
      expect(h.notifications, 3);
    },
  );

  _controllerTest('refresh does not rebuild within the same displayed second', (
    h,
  ) async {
    h.controller.start(const WorkoutOptions(active: 5, rest: 3, sets: 2));
    for (final now in [1, 50, 499, 999]) {
      h.clock.nowMs = now;
      h.controller.refresh();
      expect(h.controller.display.seconds, 5);
      expect(h.notifications, 1, reason: 'Refresh at $now ms');
    }
    h.clock.nowMs = 1000;
    h.controller.refresh();
    expect(h.controller.display.seconds, 4);
    expect(h.notifications, 2);
    for (final now in [1001, 1500, 1999]) {
      h.clock.nowMs = now;
      h.controller.refresh();
      expect(h.notifications, 2, reason: 'Refresh at $now ms');
    }
    h.clock.nowMs = 2000;
    h.controller.refresh();
    expect(h.controller.display.seconds, 3);
    expect(h.notifications, 3);
    h.controller.refresh(force: true);
    expect(h.notifications, 4);
  });

  _controllerTest('automatic updates wake only at the next visible second', (
    h,
  ) async {
    h.controller.start(const WorkoutOptions(active: 5, rest: 3, sets: 2));
    await h.pump(999);
    expect(h.notifications, 1);
    expect(h.platform.schedules, hasLength(1));
    await h.pump(1);
    expect(h.notifications, 2);
    expect(h.platform.schedules, hasLength(2));
    expect(h.controller.display.seconds, 4);
    await h.pump(999);
    expect(h.notifications, 2);
    await h.pump(1);
    expect(h.notifications, 3);
    expect(h.controller.display.seconds, 3);
    await h.pump(3000);
    expect(h.controller.display.phase, TimerPhase.active);
    expect(h.controller.display.set, 1);
    expect(h.controller.display.seconds, 5);
  });

  _controllerTest('resume schedules its fractional-second display boundary', (
    h,
  ) async {
    h.controller.start(const WorkoutOptions(active: 5, rest: 0, sets: 1));
    h.clock.nowMs = 6789;
    h.controller.togglePause();
    expect(h.controller.display.remainingMs, 3211);
    h.clock.nowMs = 100000;
    h.controller.togglePause();
    expect(h.controller.display.seconds, 4);
    final notifications = h.notifications;
    await h.pump(210);
    expect(h.notifications, notifications);
    await h.pump(1);
    expect(h.controller.display.remainingMs, 3000);
    expect(h.controller.display.seconds, 3);
    expect(h.notifications, notifications + 1);
  });

  _controllerTest(
    'pause cancels sounds and freezes refreshes until audio is unlocked on resume',
    (h) async {
      h.controller.start(const WorkoutOptions(active: 5, rest: 3, sets: 2));
      h.clock.nowMs = 6789;
      h.controller.togglePause();
      expect(h.controller.display.mode, TimerMode.paused);
      expect(h.controller.display.phase, TimerPhase.active);
      expect(h.controller.display.set, 1);
      expect(h.controller.display.remainingMs, 3211);
      expect(h.platform.cancellations, [false, false]);
      final schedules = h.platform.schedules.length;
      final notifications = h.notifications;
      await h.pump(100000);
      h.platform.onVisibilityChanged!();
      expect(h.platform.schedules, hasLength(schedules));
      expect(h.notifications, notifications);
      expect(h.controller.display.remainingMs, 3211);
      h.controller.togglePause();
      expect(h.controller.display.mode, TimerMode.running);
      expect(h.controller.display.remainingMs, 3211);
      expect(h.platform.unlocks, 2);
      expect(h.platform.schedules, hasLength(schedules + 1));
      expect(h.platform.schedules.last.events.first.atMs, h.clock.nowMs + 211);
      expect(h.platform.awake, [true]);
    },
  );

  _controllerTest(
    'visibility tops up precisely the next five minutes using the injected clock',
    (h) async {
      h.controller.start(const WorkoutOptions(active: 5, rest: 0));
      final initial = h.platform.schedules.single;
      expect(initial.clock, same(h.clock));
      expect(initial.atMs, 0);
      expect(initial.events, hasLength(60));
      expect(initial.events.first.atMs, 2000);
      expect(initial.events.last.atMs, 297000);
      h.clock.nowMs = 400000;
      h.platform.onVisibilityChanged!();
      final topUp = h.platform.schedules.last;
      expect(topUp.clock, same(h.clock));
      expect(topUp.atMs, 400000);
      expect(topUp.events, hasLength(60));
      expect(topUp.events.first.atMs, 402000);
      expect(topUp.events.last.atMs, 697000);
      expect(topUp.events.every((event) => event.atMs <= 700000), isTrue);
      expect(h.controller.display.phase, TimerPhase.active);
      expect(h.controller.display.set, 80);
      expect(h.controller.display.seconds, 5);
    },
  );

  _controllerTest(
    'top-up includes an alarm 49 ms late but excludes one 50 ms late',
    (h) async {
      h.controller.start(const WorkoutOptions(active: 5, rest: 0, sets: 1));
      h.clock.nowMs = 2049;
      h.platform.onVisibilityChanged!();
      expect(h.platform.schedules.last.events.first.atMs, 2000);
      h.clock.nowMs = 2050;
      h.platform.onVisibilityChanged!();
      expect(h.platform.schedules.last.events.first.atMs, 7000);
    },
  );

  _controllerTest(
    'completion preserves the finish, cancels alarms, and returns to settings once',
    (h) async {
      h.controller.start(const WorkoutOptions(active: 5, rest: 3, sets: 1));
      h.clock.nowMs = 10000;
      h.controller.refresh();
      expect(h.controller.showingTimer, isFalse);
      expect(h.controller.display.mode, TimerMode.complete);
      expect(h.controller.display.phase, TimerPhase.active);
      expect(h.controller.display.set, 1);
      expect(h.controller.display.remainingMs, 0);
      expect(h.platform.cancellations, [false, true]);
      expect(h.platform.awake, [true, false]);
      final finish = h.platform.schedules.last.events.single;
      expect(
        (finish.kind, finish.atMs, finish.deadlineMs),
        (SoundKind.end, 10000, 10000),
      );
      expect(h.platform.calls.sublist(h.platform.calls.length - 3), [
        'schedule',
        'cancelAlarm',
        'keepAwake',
      ]);
      expect(h.notifications, 2);
      final calls = h.platform.calls.length;
      h.controller.refresh(force: true);
      h.controller.togglePause();
      h.platform.onVisibilityChanged!();
      await h.pump(300000);
      expect(h.platform.calls, hasLength(calls));
      expect(h.notifications, 2);
    },
  );

  _controllerTest(
    'visibility after a long suspension still explicitly schedules completion',
    (h) async {
      h.controller.start(const WorkoutOptions(active: 5, rest: 0, sets: 1));
      h.clock.nowMs = 600000;
      h.platform.onVisibilityChanged!();
      expect(h.controller.display.mode, TimerMode.complete);
      expect(h.controller.showingTimer, isFalse);
      expect(
        h.platform.schedules[h.platform.schedules.length - 2].events,
        isEmpty,
      );
      final finish = h.platform.schedules.last.events.single;
      expect((finish.kind, finish.atMs), (SoundKind.end, 10000));
      expect(h.platform.cancellations.last, isTrue);
      expect(h.platform.awake.last, isFalse);
    },
  );

  _controllerTest(
    'stop cancels audio and display timers and releases the wake lock',
    (h) async {
      h.controller.start(const WorkoutOptions(active: 5, rest: 3, sets: 2));
      await h.pump(1000);
      h.controller.stop();
      expect(h.controller.engine.snapshot.mode, TimerMode.stopped);
      expect(h.controller.showingTimer, isFalse);
      expect(h.platform.cancellations, [false, false]);
      expect(h.platform.awake, [true, false]);
      final notifications = h.notifications;
      final calls = h.platform.calls.length;
      await h.pump(300000);
      h.platform.onVisibilityChanged!();
      h.controller.togglePause();
      expect(h.notifications, notifications);
      expect(h.platform.calls, hasLength(calls));
    },
  );

  _controllerTest(
    'starting another workout cancels the earlier schedule and resets its set',
    (h) async {
      h.controller.start(const WorkoutOptions(active: 5, rest: 0, sets: 2));
      await h.pump(11000);
      expect(h.controller.display.set, 2);
      h.controller.start(const WorkoutOptions(active: 10, rest: 3, sets: 1));
      expect(h.controller.display.phase, TimerPhase.prepare);
      expect(h.controller.display.set, 0);
      expect(h.controller.display.seconds, 5);
      expect(h.platform.cancellations, [false, false]);
      expect(h.platform.unlocks, 2);
      final notifications = h.notifications;
      await h.pump(999);
      expect(h.notifications, notifications);
      await h.pump(1);
      expect(h.notifications, notifications + 1);
      expect(h.controller.display.seconds, 4);
    },
  );

  _controllerTest('dispose removes the visibility callback and stops updates', (
    h,
  ) async {
    h.controller.start(const WorkoutOptions(active: 5, rest: 0));
    h.controller.dispose();
    expect(h.platform.onVisibilityChanged, isNull);
    expect(h.platform.disposed, isTrue);
    expect(h.platform.awake, [true, false]);
    final notifications = h.notifications;
    final schedules = h.platform.schedules.length;
    await h.pump(300000);
    expect(h.notifications, notifications);
    expect(h.platform.schedules, hasLength(schedules));
  });
}
