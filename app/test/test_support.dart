import 'package:easytimer/platform/timer_platform.dart';
import 'package:easytimer/timer_engine.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeClock implements MonotonicClock {
  FakeClock([this.nowMs = 0]);

  @override
  int nowMs;
}

Future<void> advanceClock(
  WidgetTester tester,
  FakeClock clock,
  int milliseconds,
) async {
  clock.nowMs += milliseconds;
  await tester.pump(Duration(milliseconds: milliseconds));
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
  final cancellations = <bool>[];
  final gains = <double>[];
  final awake = <bool>[];
  int unlocks = 0;
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
  void cancel({bool keepEnd = false}) {
    calls.add(keepEnd ? 'cancelAlarm' : 'cancel');
    cancellations.add(keepEnd);
  }

  @override
  void setVolume(double gain) {
    calls.add('setVolume');
    gains.add(gain);
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
