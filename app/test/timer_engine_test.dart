import 'package:easytimer/constants.dart';
import 'package:easytimer/timer_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

void main() {
  late FakeClock clock;
  late TimerEngine engine;
  setUp(() {
    clock = FakeClock();
    engine = TimerEngine(clock);
  });
  (TimerMode, TimerPhase, int, int) snapshot() {
    final value = engine.snapshot;
    return (value.mode, value.phase, value.set, value.remainingMs);
  }

  test('each snapshot reads the clock once', () {
    engine.start(const WorkoutOptions());
    clock.reads = 0;
    expect(engine.snapshot.remainingMs, prepareMs);
    expect(clock.reads, 1);
    expect(engine.snapshotAt(2000).remainingMs, 3000);
    expect(clock.reads, 1);
  });

  test('text and stored numbers share normalization', () {
    for (final (active, rest, sets, expected) in [
      (null, null, null, (45, 15, 0)),
      (0, 0, 0, (5, 0, 0)),
      (-1, -2, -3, (45, 15, 0)),
      (9999, 9999, 9999, (9999, 9999, 9999)),
      (10000, 10000, 10000, (45, 15, 0)),
    ]) {
      final value = WorkoutOptions.normalized(active, rest, sets);
      expect((value.active, value.rest, value.sets), expected);
    }
    for (final (text, expected) in [('0', 0), ('0005', 5), ('9999', 9999)]) {
      expect(WorkoutOptions.parse(text), expected);
    }
    for (final text in [
      '',
      '-1',
      '+1',
      '1.0',
      '1e3',
      ' 5',
      '5 ',
      '5\n',
      '10000',
      '１２',
    ]) {
      expect(WorkoutOptions.parse(text), isNull);
    }
    final value = WorkoutOptions.fromText(
      '',
      'x',
      '',
      fallback: const WorkoutOptions(active: 30, rest: 10, sets: 4),
    );
    expect((value.active, value.rest, value.sets), (30, 10, 0));
  });

  test(
    'finite phases are derived at exact boundaries and after late wakes',
    () {
      engine.start(const WorkoutOptions(active: 5, rest: 3, sets: 3));
      for (final (at, mode, phase, set, remaining) in [
        (0, TimerMode.running, TimerPhase.prepare, 0, 5000),
        (4999, TimerMode.running, TimerPhase.prepare, 0, 1),
        (5000, TimerMode.running, TimerPhase.active, 1, 5000),
        (9999, TimerMode.running, TimerPhase.active, 1, 1),
        (10000, TimerMode.running, TimerPhase.rest, 1, 3000),
        (12999, TimerMode.running, TimerPhase.rest, 1, 1),
        (13000, TimerMode.running, TimerPhase.active, 2, 5000),
        (18000, TimerMode.running, TimerPhase.rest, 2, 3000),
        (21000, TimerMode.running, TimerPhase.active, 3, 5000),
        (25999, TimerMode.running, TimerPhase.active, 3, 1),
        (26000, TimerMode.complete, TimerPhase.active, 3, 0),
        (1000000000000, TimerMode.complete, TimerPhase.active, 3, 0),
      ]) {
        clock.nowMs = at;
        expect(snapshot(), (mode, phase, set, remaining), reason: '$at ms');
      }
      engine.pause();
      engine.resume();
      expect(engine.snapshot.mode, TimerMode.complete);
      engine.stop();
      engine.resume();
      expect(engine.snapshot, same(stoppedSnapshot));
      expect(engine.soundsBetween(0, 1000000), isEmpty);
    },
  );

  for (final rest in [0, 2]) {
    test('endless rest=$rest catches up without walking past sets', () {
      engine.start(WorkoutOptions(active: 7, rest: rest));
      const skipped = 100000000;
      clock.nowMs = prepareMs + skipped * (7 + rest) * 1000 + 6999;
      expect(snapshot(), (
        TimerMode.running,
        TimerPhase.active,
        skipped + 1,
        1,
      ));
      clock.nowMs++;
      expect(snapshot(), (
        TimerMode.running,
        rest == 0 ? TimerPhase.active : TimerPhase.rest,
        skipped + (rest == 0 ? 2 : 1),
        rest == 0 ? 7000 : 2000,
      ));
      expect(engine.completionMs, isNull);
      expect(
        engine
            .soundsBetween(clock.nowMs, clock.nowMs + 5000)
            .every((cue) => cue.kind == SoundKind.alarm),
        isTrue,
      );
    });
  }

  for (final (at, phase, set, remaining, finishAfter) in [
    (0, TimerPhase.prepare, 0, 5000, 18000),
    (2250, TimerPhase.prepare, 0, 5000, 18000),
    (4999, TimerPhase.prepare, 0, 5000, 18000),
    (5000, TimerPhase.active, 1, 5000, 13000),
    (7001, TimerPhase.active, 1, 2999, 10999),
    (9999, TimerPhase.active, 1, 1, 8001),
    (10000, TimerPhase.prepare, 1, 5000, 10000),
    (11234, TimerPhase.prepare, 1, 5000, 10000),
    (12999, TimerPhase.prepare, 1, 5000, 10000),
    (13000, TimerPhase.active, 2, 5000, 5000),
    (14567, TimerPhase.active, 2, 3433, 3433),
    (17999, TimerPhase.active, 2, 1, 1),
  ]) {
    test('pause/resume boundary $at preserves native phase semantics', () {
      engine.start(const WorkoutOptions(active: 5, rest: 3, sets: 2));
      clock.nowMs = at;
      final before = engine.snapshot;
      engine.pause();
      clock.nowMs = 100000;
      engine.pause();
      expect(engine.snapshot.remainingMs, before.remainingMs);
      expect(engine.soundsBetween(0, 200000), isEmpty);
      engine.resume();
      engine.resume();
      expect(snapshot(), (TimerMode.running, phase, set, remaining));
      expect(engine.completionMs, 100000 + finishAfter);
    });
  }

  test('repeated final-active pauses and restarting discard old anchors', () {
    engine.start(const WorkoutOptions(active: 5, sets: 1));
    clock.nowMs = 7001;
    engine.pause();
    clock.nowMs = 100000;
    engine.resume();
    clock.nowMs += 1000;
    engine.pause();
    clock.nowMs = 200000;
    engine.resume();
    expect(snapshot(), (TimerMode.running, TimerPhase.active, 1, 1999));
    expect(engine.completionMs, 201999);
    engine.stop();
    engine.start(const WorkoutOptions(active: 10, rest: 0));
    expect(snapshot(), (TimerMode.running, TimerPhase.prepare, 0, prepareMs));
    expect(engine.completionMs, isNull);
  });

  test(
    'whole seconds use ceil and display equality ignores subsecond changes',
    () {
      for (final remaining in [0, 1, 999, 1000, 1001, 1999, 2000, 2001]) {
        final value = TimerSnapshot(
          TimerMode.running,
          TimerPhase.active,
          1,
          remaining,
        );
        expect(value.seconds, (remaining / 1000).ceil());
        expect(
          value.sameDisplay(
            TimerSnapshot(
              TimerMode.running,
              TimerPhase.active,
              1,
              value.seconds * 1000,
            ),
          ),
          isTrue,
        );
        expect(
          value.sameDisplay(
            TimerSnapshot(TimerMode.paused, TimerPhase.active, 1, remaining),
          ),
          isFalse,
        );
      }
    },
  );

  test(
    'cue windows include a still-valid past alarm and a deadline-free end',
    () {
      engine.start(const WorkoutOptions(active: 5, rest: 3, sets: 2));
      final cues = engine.soundsBetween(0, 300000);
      expect(cues.map((cue) => (cue.kind, cue.atMs, cue.deadlineMs)), [
        (SoundKind.alarm, 2000, 2049),
        (SoundKind.alarm, 7000, 7049),
        (SoundKind.alarm, 10000, 10049),
        (SoundKind.alarm, 15000, 15049),
        (SoundKind.end, 18000, null),
      ]);
      expect(cues.map((cue) => cue.id).toSet().length, cues.length);
      expect(engine.soundsBetween(2040, 2040).single.atMs, 2000);
      expect(engine.soundsBetween(2050, 2050), isEmpty);
      expect(engine.soundsBetween(60000, 60000).single.kind, SoundKind.end);
    },
  );

  for (final remaining in [2950, 2951, 2999, 3000, 3001, 3049, 3050]) {
    test('resumed alarm window at $remaining ms', () {
      engine.start(const WorkoutOptions(active: 5, sets: 1));
      clock.nowMs = 10000 - remaining;
      engine.pause();
      clock.nowMs = 100000;
      engine.resume();
      final alarms = engine
          .soundsBetween(100000, 200000)
          .where((cue) => cue.kind == SoundKind.alarm)
          .toList();
      if (remaining < 2951) {
        expect(alarms, isEmpty);
      } else {
        expect(
          alarms.single.atMs,
          remaining <= 3049 ? 100000 : 100000 + remaining - 3000,
        );
        expect(alarms.single.deadlineMs, 100000 + remaining - 2951);
      }
    });
  }
}
