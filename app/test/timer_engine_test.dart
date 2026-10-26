import 'package:easytimer/timer_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

void expectSnapshot(
  TimerEngine engine,
  TimerMode mode,
  TimerPhase phase,
  int set,
  int remainingMs,
) {
  final snapshot = engine.snapshot;
  expect(
    (snapshot.mode, snapshot.phase, snapshot.set, snapshot.remainingMs),
    (mode, phase, set, remainingMs),
    reason: 'At ${engine.clock.nowMs} ms',
  );
}

List<(SoundKind, int, int)> soundValues(List<SoundEvent> events) => [
  for (final event in events) (event.kind, event.atMs, event.deadlineMs),
];

void main() {
  late FakeClock clock;
  late TimerEngine engine;

  setUp(() {
    clock = FakeClock();
    engine = TimerEngine(clock);
  });

  group('workout options', () {
    test('accepts only one to four decimal digits', () {
      for (final (text, value) in [
        ('0', 0),
        ('5', 5),
        ('0005', 5),
        ('9999', 9999),
      ]) {
        expect(WorkoutOptions.parse(text), value, reason: text);
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
        expect(WorkoutOptions.parse(text), isNull, reason: text);
      }
    });

    test(
      'uses saved durations, clamps active, and defaults sets to endless',
      () {
        const saved = WorkoutOptions(active: 30, rest: 10, sets: 4);
        final invalid = WorkoutOptions.fromText('', 'x', '', fallback: saved);
        expect((invalid.active, invalid.rest, invalid.sets), (30, 10, 0));
        final minimum = WorkoutOptions.fromText('0', '0', '0');
        expect((minimum.active, minimum.rest, minimum.sets), (5, 0, 0));
        final maximum = WorkoutOptions.fromText('9999', '9999', '9999');
        expect(
          (maximum.active, maximum.rest, maximum.sets),
          (9999, 9999, 9999),
        );
      },
    );
  });

  group('phase transitions', () {
    test('stopped time stays at five seconds and ignores pause and resume', () {
      clock.nowMs = 1000000;
      engine.pause();
      engine.resume();
      expectSnapshot(engine, TimerMode.stopped, TimerPhase.prepare, 0, 5000);
      expect(engine.soundsBetween(0, 1000000), isEmpty);
    });

    test(
      'finite workout changes phases at exact boundaries without final rest',
      () {
        engine.start(const WorkoutOptions(active: 5, rest: 3, sets: 3));
        for (final (at, phase, set, remaining) in [
          (0, TimerPhase.prepare, 0, 5000),
          (1, TimerPhase.prepare, 0, 4999),
          (4999, TimerPhase.prepare, 0, 1),
          (5000, TimerPhase.active, 1, 5000),
          (9999, TimerPhase.active, 1, 1),
          (10000, TimerPhase.rest, 1, 3000),
          (12999, TimerPhase.rest, 1, 1),
          (13000, TimerPhase.active, 2, 5000),
          (17999, TimerPhase.active, 2, 1),
          (18000, TimerPhase.rest, 2, 3000),
          (20999, TimerPhase.rest, 2, 1),
          (21000, TimerPhase.active, 3, 5000),
          (25999, TimerPhase.active, 3, 1),
        ]) {
          clock.nowMs = at;
          expectSnapshot(engine, TimerMode.running, phase, set, remaining);
        }
        expect(engine.completionMs, 26000);
        for (final at in [26000, 26001, 1000000000000]) {
          clock.nowMs = at;
          expectSnapshot(engine, TimerMode.complete, TimerPhase.active, 3, 0);
          expect(engine.phaseAt(at), isNull);
        }
      },
    );

    test('zero rest moves straight into the next set', () {
      engine.start(const WorkoutOptions(active: 5, rest: 0, sets: 3));
      for (final (at, set, remaining) in [
        (5000, 1, 5000),
        (9999, 1, 1),
        (10000, 2, 5000),
        (14999, 2, 1),
        (15000, 3, 5000),
        (19999, 3, 1),
      ]) {
        clock.nowMs = at;
        expectSnapshot(
          engine,
          TimerMode.running,
          TimerPhase.active,
          set,
          remaining,
        );
      }
      clock.nowMs = 20000;
      expectSnapshot(engine, TimerMode.complete, TimerPhase.active, 3, 0);
    });

    test('one set ends after active even with a long configured rest', () {
      clock.nowMs = 12345;
      engine.start(const WorkoutOptions(active: 5, rest: 9999, sets: 1));
      expect(engine.completionMs, 22345);
      clock.nowMs = 22344;
      expectSnapshot(engine, TimerMode.running, TimerPhase.active, 1, 1);
      clock.nowMs++;
      expectSnapshot(engine, TimerMode.complete, TimerPhase.active, 1, 0);
    });

    for (final rest in [0, 2]) {
      test(
        'endless workout catches up across 100 million sets with rest $rest',
        () {
          clock.nowMs = 123;
          engine.start(WorkoutOptions(active: 7, rest: rest));
          const skippedSets = 100000000;
          final activeStart = 5123 + skippedSets * (7 + rest) * 1000;
          clock.nowMs = activeStart + 6999;
          expect(engine.completionMs, isNull);
          expectSnapshot(
            engine,
            TimerMode.running,
            TimerPhase.active,
            skippedSets + 1,
            1,
          );
          clock.nowMs++;
          expectSnapshot(
            engine,
            TimerMode.running,
            rest == 0 ? TimerPhase.active : TimerPhase.rest,
            skippedSets + (rest == 0 ? 2 : 1),
            rest == 0 ? 7000 : 2000,
          );
          if (rest > 0) {
            clock.nowMs += 2000;
            expectSnapshot(
              engine,
              TimerMode.running,
              TimerPhase.active,
              skippedSets + 2,
              7000,
            );
          }
        },
      );
    }

    test('phase lookup does not move the clock or consume transitions', () {
      engine.start(const WorkoutOptions(active: 5, rest: 3, sets: 3));
      final future = engine.phaseAt(13500)!;
      expect(
        (future.phase, future.set, future.startMs, future.endMs),
        (TimerPhase.active, 2, 13000, 18000),
      );
      expectSnapshot(engine, TimerMode.running, TimerPhase.prepare, 0, 5000);
      clock.nowMs = 11000;
      expectSnapshot(engine, TimerMode.running, TimerPhase.rest, 1, 2000);
      expectSnapshot(engine, TimerMode.running, TimerPhase.rest, 1, 2000);
    });

    test('stop and restart discard the old phase, set, and finite end', () {
      engine.start(const WorkoutOptions(active: 5, rest: 3, sets: 3));
      clock.nowMs = 15000;
      engine.pause();
      engine.stop();
      engine.resume();
      expectSnapshot(engine, TimerMode.stopped, TimerPhase.prepare, 0, 5000);
      expect(engine.soundsBetween(0, 100000), isEmpty);
      clock.nowMs = 100000;
      engine.start(const WorkoutOptions(active: 10, rest: 0));
      expectSnapshot(engine, TimerMode.running, TimerPhase.prepare, 0, 5000);
      expect(engine.completionMs, isNull);
      clock.nowMs = 105000;
      expectSnapshot(engine, TimerMode.running, TimerPhase.active, 1, 10000);
    });

    test('pause and resume cannot revive a completed workout', () {
      engine.start(const WorkoutOptions(active: 5, rest: 3, sets: 1));
      clock.nowMs = 10000;
      engine.pause();
      engine.resume();
      expectSnapshot(engine, TimerMode.complete, TimerPhase.active, 1, 0);
      engine.start(const WorkoutOptions(active: 8, rest: 1, sets: 2));
      expectSnapshot(engine, TimerMode.running, TimerPhase.prepare, 0, 5000);
      expect(engine.completionMs, 32000);
    });
  });

  group('pause and resume', () {
    test('prepare freezes while paused and restarts a full five seconds', () {
      engine.start(const WorkoutOptions(active: 5, rest: 3, sets: 2));
      clock.nowMs = 2250;
      engine.pause();
      clock.nowMs = 60000;
      engine.pause();
      expectSnapshot(engine, TimerMode.paused, TimerPhase.prepare, 0, 2750);
      expect(engine.soundsBetween(0, 100000), isEmpty);
      engine.resume();
      expectSnapshot(engine, TimerMode.running, TimerPhase.prepare, 0, 5000);
      expect(engine.completionMs, 78000);
      clock.nowMs = 64999;
      expectSnapshot(engine, TimerMode.running, TimerPhase.prepare, 0, 1);
      clock.nowMs++;
      expectSnapshot(engine, TimerMode.running, TimerPhase.active, 1, 5000);
    });

    test(
      'active preserves exact remaining time and set, then resumes its rest',
      () {
        engine.start(const WorkoutOptions(active: 5, rest: 3, sets: 3));
        clock.nowMs = 14567;
        engine.pause();
        clock.nowMs = 60000;
        expectSnapshot(engine, TimerMode.paused, TimerPhase.active, 2, 3433);
        engine.resume();
        expectSnapshot(engine, TimerMode.running, TimerPhase.active, 2, 3433);
        expect(engine.completionMs, 71433);
        clock.nowMs = 63432;
        expectSnapshot(engine, TimerMode.running, TimerPhase.active, 2, 1);
        clock.nowMs++;
        expectSnapshot(engine, TimerMode.running, TimerPhase.rest, 2, 3000);
        clock.nowMs = 66433;
        expectSnapshot(engine, TimerMode.running, TimerPhase.active, 3, 5000);
        clock.nowMs = 71433;
        expectSnapshot(engine, TimerMode.complete, TimerPhase.active, 3, 0);
      },
    );

    test(
      'final active can be paused repeatedly without adding another set',
      () {
        engine.start(const WorkoutOptions(active: 5, rest: 3, sets: 1));
        clock.nowMs = 7001;
        engine.pause();
        clock.nowMs = 100000;
        engine.resume();
        clock.nowMs += 1000;
        engine.pause();
        expectSnapshot(engine, TimerMode.paused, TimerPhase.active, 1, 1999);
        clock.nowMs = 200000;
        engine.resume();
        engine.resume();
        expect(engine.completionMs, 201999);
        clock.nowMs = 201998;
        expectSnapshot(engine, TimerMode.running, TimerPhase.active, 1, 1);
        clock.nowMs++;
        expectSnapshot(engine, TimerMode.complete, TimerPhase.active, 1, 0);
      },
    );

    test('rest resumes through prepare and keeps the completed set number', () {
      engine.start(const WorkoutOptions(active: 5, rest: 3, sets: 3));
      clock.nowMs = 11234;
      engine.pause();
      clock.nowMs = 50000;
      expectSnapshot(engine, TimerMode.paused, TimerPhase.rest, 1, 1766);
      engine.resume();
      expectSnapshot(engine, TimerMode.running, TimerPhase.prepare, 1, 5000);
      expect(engine.completionMs, 68000);
      clock.nowMs = 54999;
      expectSnapshot(engine, TimerMode.running, TimerPhase.prepare, 1, 1);
      clock.nowMs++;
      expectSnapshot(engine, TimerMode.running, TimerPhase.active, 2, 5000);
      clock.nowMs = 68000;
      expectSnapshot(engine, TimerMode.complete, TimerPhase.active, 3, 0);
    });

    test('pausing the prepare after rest still keeps its completed set', () {
      engine.start(const WorkoutOptions(active: 5, rest: 3, sets: 2));
      clock.nowMs = 10000;
      engine.pause();
      clock.nowMs = 20000;
      engine.resume();
      clock.nowMs = 21000;
      engine.pause();
      clock.nowMs = 30000;
      engine.resume();
      expectSnapshot(engine, TimerMode.running, TimerPhase.prepare, 1, 5000);
      expect(engine.completionMs, 40000);
      clock.nowMs = 35000;
      expectSnapshot(engine, TimerMode.running, TimerPhase.active, 2, 5000);
    });

    for (final (at, phase, set, remaining) in [
      (4999, TimerPhase.prepare, 0, 5000),
      (5000, TimerPhase.active, 1, 5000),
      (9999, TimerPhase.active, 1, 1),
      (10000, TimerPhase.prepare, 1, 5000),
      (12999, TimerPhase.prepare, 1, 5000),
      (13000, TimerPhase.active, 2, 5000),
    ]) {
      test('pause at boundary $at resumes the correct phase', () {
        engine.start(const WorkoutOptions(active: 5, rest: 3, sets: 2));
        clock.nowMs = at;
        engine.pause();
        clock.nowMs = 100000;
        engine.resume();
        expectSnapshot(engine, TimerMode.running, phase, set, remaining);
      });
    }
  });

  group('display', () {
    test('remaining seconds round upward including one millisecond', () {
      for (final (remaining, seconds) in [
        (0, 0),
        (1, 1),
        (999, 1),
        (1000, 1),
        (1001, 2),
        (1999, 2),
        (2000, 2),
        (2001, 3),
      ]) {
        expect(
          TimerSnapshot(
            TimerMode.running,
            TimerPhase.active,
            1,
            remaining,
          ).seconds,
          seconds,
          reason: '$remaining ms',
        );
      }
    });

    test('display equality includes mode, phase, set, and rounded second', () {
      const base = TimerSnapshot(TimerMode.running, TimerPhase.active, 2, 3000);
      expect(
        base.sameDisplay(
          const TimerSnapshot(TimerMode.running, TimerPhase.active, 2, 2001),
        ),
        isTrue,
      );
      for (final other in [
        const TimerSnapshot(TimerMode.paused, TimerPhase.active, 2, 3000),
        const TimerSnapshot(TimerMode.running, TimerPhase.rest, 2, 3000),
        const TimerSnapshot(TimerMode.running, TimerPhase.active, 3, 3000),
        const TimerSnapshot(TimerMode.running, TimerPhase.active, 2, 2000),
      ]) {
        expect(base.sameDisplay(other), isFalse);
      }
    });
  });

  group('sound plan', () {
    test('plans prepare, active, and rest beeps followed by one finish', () {
      engine.start(const WorkoutOptions(active: 5, rest: 3, sets: 2));
      final events = engine.soundsBetween(-100, 100000);
      expect(soundValues(events), [
        (SoundKind.alarm, 2000, 2049),
        (SoundKind.alarm, 7000, 7049),
        (SoundKind.alarm, 10000, 10049),
        (SoundKind.alarm, 15000, 15049),
        (SoundKind.end, 18000, 18000),
      ]);
      expect(events.map((event) => event.id).toSet(), hasLength(events.length));
    });

    for (final rest in [0, 1, 2]) {
      test('rest of $rest seconds has no beep', () {
        engine.start(WorkoutOptions(active: 5, rest: rest, sets: 2));
        expect(soundValues(engine.soundsBetween(0, 100000)), [
          (SoundKind.alarm, 2000, 2049),
          (SoundKind.alarm, 7000, 7049),
          (SoundKind.alarm, 12000 + rest * 1000, 12049 + rest * 1000),
          (SoundKind.end, 15000 + rest * 1000, 15000 + rest * 1000),
        ]);
      });
    }

    test('ranges include both endpoints and exclude neighboring events', () {
      engine.start(const WorkoutOptions(active: 5, rest: 3, sets: 1));
      expect(engine.soundsBetween(0, 1999), isEmpty);
      expect(soundValues(engine.soundsBetween(2000, 2000)), [
        (SoundKind.alarm, 2000, 2049),
      ]);
      expect(engine.soundsBetween(2001, 6999), isEmpty);
      expect(soundValues(engine.soundsBetween(10000, 10000)), [
        (SoundKind.end, 10000, 10000),
      ]);
      expect(engine.soundsBetween(10001, 100000), isEmpty);
      expect(engine.soundsBetween(7001, 7000), isEmpty);
    });

    test('late discovery includes the beep until the 2951 ms boundary', () {
      engine.start(const WorkoutOptions(active: 5, rest: 0, sets: 1));
      expect(soundValues(engine.soundsBetween(2049 - 49, 2049)), [
        (SoundKind.alarm, 2000, 2049),
      ]);
      expect(engine.soundsBetween(2050 - 49, 2050), isEmpty);
    });

    for (final remaining in [
      1,
      2949,
      2950,
      2951,
      2999,
      3000,
      3001,
      3049,
      3050,
    ]) {
      test(
        'resumed active with $remaining ms uses the immediate Kotlin beep window',
        () {
          engine.start(const WorkoutOptions(active: 5, rest: 0, sets: 1));
          clock.nowMs = 10000 - remaining;
          engine.pause();
          clock.nowMs = 100000;
          engine.resume();
          final events = engine.soundsBetween(100000, 100000 + remaining - 1);
          if (remaining < 2951) {
            expect(events, isEmpty);
          } else {
            final at = remaining > 3049 ? 100000 + remaining - 3000 : 100000;
            expect(soundValues(events), [
              (SoundKind.alarm, at, 100000 + remaining - 2951),
            ]);
            expect(100000 + remaining - at, inInclusiveRange(2951, 3049));
          }
          expect(
            soundValues(
              engine.soundsBetween(100000 + remaining, 100000 + remaining),
            ),
            [(SoundKind.end, 100000 + remaining, 100000 + remaining)],
          );
        },
      );
    }

    test(
      'resuming rest replaces old alarms and completion with a fresh plan',
      () {
        engine.start(const WorkoutOptions(active: 5, rest: 3, sets: 2));
        clock.nowMs = 11000;
        engine.pause();
        clock.nowMs = 100000;
        engine.resume();
        expect(soundValues(engine.soundsBetween(0, 200000)), [
          (SoundKind.alarm, 102000, 102049),
          (SoundKind.alarm, 107000, 107049),
          (SoundKind.end, 110000, 110000),
        ]);
      },
    );

    test(
      'a distant endless horizon has only its local alarms and no finish',
      () {
        engine.start(const WorkoutOptions(active: 5, rest: 0));
        const from = 1000000000000;
        final events = engine.soundsBetween(from, from + 5000);
        expect(soundValues(events), [
          (SoundKind.alarm, from + 2000, from + 2049),
        ]);
      },
    );
  });

  group('alarm gate', () {
    test('success at clock zero blocks duplicates for exactly 3000 ms', () {
      final gate = AlarmGate();
      expect(gate.allows(0), isTrue);
      gate.succeeded(0);
      expect(gate.allows(0), isFalse);
      expect(gate.allows(2999), isFalse);
      expect(gate.allows(3000), isTrue);
      gate.succeeded(3000);
      expect(gate.allows(5999), isFalse);
      expect(gate.allows(6000), isTrue);
    });

    test('an unsuccessful attempt does not consume the guard', () {
      final gate = AlarmGate();
      for (final now in [100, 100, 110, 120]) {
        expect(gate.allows(now), isTrue);
      }
      gate.succeeded(120);
      expect(gate.allows(121), isFalse);
    });

    test('cancel reset permits an immediate new countdown alarm', () {
      final gate = AlarmGate()..succeeded(10000);
      expect(gate.allows(10001), isFalse);
      gate.reset();
      expect(gate.allows(10001), isTrue);
      gate.reset();
      expect(gate.allows(10001), isTrue);
    });
  });
}
