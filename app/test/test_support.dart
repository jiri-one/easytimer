import 'package:easytimer/constants.dart';
import 'package:easytimer/platform/timer_platform.dart';
import 'package:easytimer/settings.dart';
import 'package:easytimer/timer_engine.dart';
import 'package:easytimer/workout_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeClock implements MonotonicClock {
  FakeClock([this._nowMs = 0]);

  int _nowMs;
  int reads = 0;

  @override
  int get nowMs {
    reads++;
    return _nowMs;
  }

  set nowMs(int value) => _nowMs = value;
}

class RecordingPreferences implements SharedPreferences {
  RecordingPreferences([Map<String, Object> initial = const {}])
    : values = {...initial};

  final Map<String, Object> values;
  final writes = <(String, int)>[];
  bool failWrites = false;

  @override
  Object? get(String key) => values[key];

  @override
  Future<bool> setInt(String key, int value) async {
    if (failWrites) throw StateError('Storage unavailable');
    writes.add((key, value));
    values[key] = value;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> advanceClock(
  WidgetTester tester,
  FakeClock clock,
  int milliseconds,
) async {
  clock.nowMs += milliseconds;
  await tester.pump(Duration(milliseconds: milliseconds));
}

Future<void> loadAppFont() =>
    (FontLoader('DroidSansMono')..addFont(rootBundle.load(fontAsset))).load();

Future<WorkoutController> createTestController(
  WidgetTester tester, {
  Map<String, Object> preferences = const {},
  FakeClock? clock,
  RecordingTimerPlatform? platform,
}) async {
  SharedPreferences.setMockInitialValues(preferences);
  final controller = WorkoutController(
    await TimerSettings.load(),
    platform ?? RecordingTimerPlatform(),
    clock: clock ?? FakeClock(),
  );
  addTearDown(tester.view.reset);
  addTearDown(controller.dispose);
  return controller;
}

class RecordedSchedule {
  RecordedSchedule(List<SoundEvent> events, this.clock)
    : events = List.unmodifiable(events),
      atMs = clock.nowMs;

  final List<SoundEvent> events;
  final MonotonicClock clock;
  final int atMs;
}

class RecordingTimerPlatform extends TimerPlatform {
  final calls = <String>[];
  final schedules = <RecordedSchedule>[];
  final volumes = <int>[];
  final awake = <bool>[];
  int unlocks = 0;
  int cancellations = 0;
  bool disposed = false;

  @override
  Future<void> initialize() async => calls.add('initialize');

  @override
  void unlock() {
    calls.add('unlock');
    unlocks++;
  }

  @override
  void schedule(List<SoundEvent> events, MonotonicClock clock) {
    calls.add('schedule');
    schedules.add(RecordedSchedule(events, clock));
  }

  @override
  void cancel() {
    calls.add('cancel');
    cancellations++;
  }

  @override
  void setVolume(int percent) {
    calls.add('setVolume');
    volumes.add(percent);
  }

  @override
  void keepAwake(bool enabled) {
    calls.add('keepAwake');
    awake.add(enabled);
  }

  @override
  void dispose() {
    calls.add('dispose');
    disposed = true;
  }
}
