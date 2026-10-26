import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easytimer/platform/timer_platform_native.dart';
import 'package:easytimer/timer_engine.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

const _channel = MethodChannel('easytimer/platform');

class _NativeHarness {
  _NativeHarness(this.tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'playAlarm' || call.method == 'playEnd') {
        plays.add((call.method, clock.nowMs));
      }
      final result = await respond(call);
      if ((call.method == 'playAlarm' || call.method == 'playEnd') &&
          result == true) {
        return {'startedAtMs': clock.nowMs};
      }
      return result;
    });
  }

  final WidgetTester tester;
  late final backend = PlatformBackend(dispatchClock: dispatchClock);
  final clock = FakeClock();
  final dispatchClock = FakeClock();
  final calls = <MethodCall>[];
  final plays = <(String, int)>[];
  FutureOr<Object?> Function(MethodCall) respond = (_) => true;

  Future<void> pump([int milliseconds = 0]) => _pump(milliseconds);

  Future<void> _pump(int milliseconds) {
    dispatchClock.nowMs += milliseconds;
    return advanceClock(tester, clock, milliseconds);
  }

  void schedule(List<SoundEvent> events) => backend.schedule(events, clock);
}

void _nativeTest(
  String description,
  Future<void> Function(_NativeHarness) body,
) {
  testWidgets(description, (tester) async {
    final harness = _NativeHarness(tester);
    try {
      await body(harness);
    } finally {
      harness.backend.dispose();
      await tester.pump();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _channel,
        null,
      );
    }
  });
}

void main() {
  _nativeTest('initialize sends the real bundled WAV bytes to native audio', (
    h,
  ) async {
    // Future.wait requires replies after all asset futures are registered.
    h.tester.binding.defaultBinaryMessenger.setMockMessageHandler(
      'flutter/assets',
      (message) async {
        final path = utf8.decode(Uint8List.sublistView(message!));
        return ByteData.sublistView(File(path).readAsBytesSync());
      },
    );
    await h.backend.initialize();
    final initialize = h.calls.singleWhere(
      (call) => call.method == 'initialize',
    );
    final arguments = initialize.arguments as Map<Object?, Object?>;
    for (final (key, file) in [
      ('alarm', 'assets/audio/threesecbeep.wav'),
      ('end', 'assets/audio/hit.wav'),
    ]) {
      final bytes = arguments[key] as Uint8List;
      expect(bytes, orderedEquals(File(file).readAsBytesSync()));
      expect(String.fromCharCodes(bytes.take(4)), 'RIFF');
      expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
    }
  });

  _nativeTest('future alarms are single shots despite overlapping schedules', (
    h,
  ) async {
    const event = SoundEvent(SoundKind.alarm, 2000, 2049);
    h.schedule([event, event]);
    h.schedule([event]);
    await h.pump(1999);
    expect(h.plays, isEmpty);
    await h.pump(1);
    expect(h.plays, [('playAlarm', 2000)]);
    h.schedule([event]);
    await h.pump(49);
    expect(h.plays, [('playAlarm', 2000)]);
  });

  _nativeTest('plays each phase beep and the finite finish exactly once', (
    h,
  ) async {
    final engine = TimerEngine(h.clock)
      ..start(const WorkoutOptions(active: 5, rest: 3, sets: 2));
    final events = engine.soundsBetween(0, 300000);
    h.schedule(events);
    for (final elapsed in [2000, 5000, 3000, 5000, 3000]) {
      await h.pump(elapsed);
      h.schedule(
        engine.soundsBetween(h.clock.nowMs - 49, h.clock.nowMs + 300000),
      );
      await h.pump();
    }
    h.schedule([const SoundEvent(SoundKind.end, 18000, 18000)]);
    h.backend.cancel(keepEnd: true);
    await h.pump();
    expect(h.plays, [
      ('playAlarm', 2000),
      ('playAlarm', 7000),
      ('playAlarm', 10000),
      ('playAlarm', 15000),
      ('playEnd', 18000),
    ]);
    expect(h.calls.last.method, 'cancelAlarm');
  });

  _nativeTest(
    'failed alarm plays retry without consuming the duplicate guard',
    (h) async {
      var attempts = 0;
      h.respond = (call) => call.method != 'playAlarm' || ++attempts >= 3;
      h.schedule([const SoundEvent(SoundKind.alarm, 100, 149)]);
      await h.pump(100);
      await h.pump(10);
      await h.pump(10);
      h.schedule([const SoundEvent(SoundKind.alarm, 100, 149)]);
      await h.pump(29);
      expect(h.plays, [
        ('playAlarm', 100),
        ('playAlarm', 110),
        ('playAlarm', 120),
      ]);
    },
  );

  for (final failure in [
    'false',
    'null',
    'platform exception',
    'missing plugin',
  ]) {
    _nativeTest('a $failure play result can retry within the window', (
      h,
    ) async {
      var attempts = 0;
      h.respond = (call) {
        if (call.method != 'playAlarm' || ++attempts > 1) return true;
        return switch (failure) {
          'false' => false,
          'null' => null,
          'platform exception' => throw PlatformException(code: 'not-ready'),
          _ => throw MissingPluginException(),
        };
      };
      h.schedule([const SoundEvent(SoundKind.alarm, 100, 149)]);
      await h.pump(100);
      await h.pump(10);
      await h.pump(100);
      expect(h.plays, [('playAlarm', 100), ('playAlarm', 110)]);
    });
  }

  _nativeTest(
    'persistent failures stop retrying when the alarm window closes',
    (h) async {
      h.respond = (call) => call.method != 'playAlarm';
      h.schedule([const SoundEvent(SoundKind.alarm, 100, 149)]);
      await h.pump(100);
      for (var retry = 0; retry < 5; retry++) {
        await h.pump(10);
      }
      await h.pump(1000);
      expect(h.plays, [
        ('playAlarm', 100),
        ('playAlarm', 110),
        ('playAlarm', 120),
        ('playAlarm', 130),
        ('playAlarm', 140),
      ]);
    },
  );

  for (final lateBy in [0, 49, 50]) {
    _nativeTest('a callback $lateBy ms late respects the 2951 ms cutoff', (
      h,
    ) async {
      h.schedule([const SoundEvent(SoundKind.alarm, 100, 149)]);
      h.clock.nowMs = 100 + lateBy;
      await h.tester.pump(const Duration(milliseconds: 100));
      expect(h.plays, lateBy <= 49 ? [('playAlarm', 100 + lateBy)] : isEmpty);
    });
  }

  _nativeTest('the guard allows the next alarm at exactly 3000 ms', (h) async {
    h.schedule([
      const SoundEvent(SoundKind.alarm, 0, 49),
      const SoundEvent(SoundKind.alarm, 2999, 3048),
      const SoundEvent(SoundKind.alarm, 3000, 3049),
    ]);
    await h.pump();
    await h.pump(2999);
    await h.pump(1);
    expect(h.plays, [('playAlarm', 0), ('playAlarm', 3000)]);
  });

  _nativeTest(
    'full cancel stops current audio and removes every pending sound',
    (h) async {
      h.schedule([
        const SoundEvent(SoundKind.alarm, 0, 49),
        const SoundEvent(SoundKind.alarm, 5000, 5049),
        const SoundEvent(SoundKind.end, 10000, 10000),
      ]);
      await h.pump();
      h.backend.cancel();
      await h.pump();
      expect(h.calls.last.method, 'stop');
      await h.pump(10000);
      expect(h.plays, [('playAlarm', 0)]);
    },
  );

  _nativeTest('cancel resets both duplicate IDs and the 3000 ms guard', (
    h,
  ) async {
    const event = SoundEvent(SoundKind.alarm, 0, 49);
    h.schedule([event]);
    await h.pump();
    h.backend.cancel();
    h.schedule([event]);
    await h.pump();
    expect(h.plays, [('playAlarm', 0), ('playAlarm', 0)]);
  });

  _nativeTest('cancel also removes a pending failed-play retry', (h) async {
    h.respond = (call) => call.method != 'playAlarm';
    h.schedule([const SoundEvent(SoundKind.alarm, 0, 49)]);
    await h.pump();
    h.backend.cancel();
    await h.pump(10);
    await h.pump(100);
    expect(h.plays, [('playAlarm', 0)]);
  });

  _nativeTest(
    'completion cancels current and pending alarms but preserves finish',
    (h) async {
      h.schedule([
        const SoundEvent(SoundKind.alarm, 0, 49),
        const SoundEvent(SoundKind.alarm, 5000, 5049),
        const SoundEvent(SoundKind.end, 10000, 10000),
      ]);
      await h.pump();
      h.backend.cancel(keepEnd: true);
      await h.pump();
      expect(h.calls.last.method, 'cancelAlarm');
      await h.pump(5000);
      expect(h.plays, [('playAlarm', 0)]);
      await h.pump(5000);
      h.schedule([const SoundEvent(SoundKind.end, 10000, 10000)]);
      h.backend.cancel(keepEnd: true);
      await h.pump();
      expect(h.plays, [('playAlarm', 0), ('playEnd', 10000)]);
    },
  );

  _nativeTest(
    'a late active callback skips stale alarms while completion still plays',
    (h) async {
      final engine = TimerEngine(h.clock)
        ..start(const WorkoutOptions(active: 5, rest: 0, sets: 1));
      h.schedule(engine.soundsBetween(0, 300000));
      h.clock.nowMs = 20000;
      await h.tester.pump(const Duration(seconds: 20));
      expect(h.plays, [('playEnd', 20000)]);
      h.schedule([const SoundEvent(SoundKind.end, 10000, 10000)]);
      await h.pump();
      expect(h.plays, [('playEnd', 20000)]);
    },
  );

  _nativeTest('completion is attempted once even if native play fails', (
    h,
  ) async {
    h.respond = (call) => call.method != 'playEnd';
    const event = SoundEvent(SoundKind.end, 0, 0);
    h.schedule([event]);
    await h.pump();
    h.schedule([event]);
    await h.pump(1000);
    expect(h.plays, [('playEnd', 0)]);
  });

  for (final keepEnd in [false, true]) {
    _nativeTest(
      'cancel keepEnd=$keepEnd invalidates an in-flight failed alarm',
      (h) async {
        final pendingPlay = Completer<bool>();
        h.respond = (call) =>
            call.method == 'playAlarm' ? pendingPlay.future : true;
        h.schedule([
          const SoundEvent(SoundKind.alarm, 0, 49),
          const SoundEvent(SoundKind.end, 100, 100),
        ]);
        await h.pump();
        expect(h.plays, [('playAlarm', 0)]);
        h.backend.cancel(keepEnd: keepEnd);
        pendingPlay.complete(false);
        await h.pump();
        await h.pump(10);
        expect(h.plays, [('playAlarm', 0)]);
        await h.pump(90);
        expect(h.plays, [('playAlarm', 0), if (keepEnd) ('playEnd', 100)]);
      },
    );
  }

  _nativeTest('overlapping schedules do not duplicate an in-flight play', (
    h,
  ) async {
    final pendingPlay = Completer<bool>();
    h.respond = (call) =>
        call.method == 'playAlarm' ? pendingPlay.future : true;
    const event = SoundEvent(SoundKind.alarm, 0, 49);
    h.schedule([event]);
    await h.pump();
    h.schedule([event]);
    await h.pump();
    pendingPlay.complete(true);
    await h.pump();
    expect(h.plays, [('playAlarm', 0)]);
  });

  _nativeTest('volume gains and awake state pass through to native unchanged', (
    h,
  ) async {
    for (final gain in [0.0, 0.25, 1.0]) {
      h.backend.setVolume(gain);
    }
    h.backend.keepAwake(true);
    h.backend.keepAwake(false);
    h.backend.unlock();
    await h.pump();
    expect(h.calls.map((call) => (call.method, call.arguments)), [
      ('setVolume', 0.0),
      ('setVolume', 0.25),
      ('setVolume', 1.0),
      ('keepAwake', true),
      ('keepAwake', false),
    ]);
  });

  _nativeTest('dispose stops playback and removes timers', (h) async {
    h.schedule([
      const SoundEvent(SoundKind.alarm, 100, 149),
      const SoundEvent(SoundKind.end, 1000, 1000),
    ]);
    h.backend.dispose();
    await h.pump(1000);
    expect(h.plays, isEmpty);
    expect(h.calls.map((call) => call.method), ['stop', 'dispose']);
  });
  _nativeTest(
    'native receives absolute deadlines and cancellation generations',
    (h) async {
      h.clock.nowMs = 50000;
      h.backend.cancel();
      h.schedule([const SoundEvent(SoundKind.alarm, 50000, 50049)]);
      await h.pump();
      expect(h.calls.first.arguments, {'generation': 1, 'alarmGeneration': 1});
      expect(h.calls.last.arguments, {
        'eventId': 'alarm:50000',
        'plannedAtMs': 50000,
        'generation': 1,
        'alarmGeneration': 1,
        'deadlineMs': 50049,
      });
    },
  );

  _nativeTest(
    'successful starts guard planned cue times despite native latency',
    (h) async {
      h.respond = (call) => call.method == 'playAlarm' && h.clock.nowMs == 100
          ? {'startedAtMs': 120}
          : true;
      h.schedule([
        const SoundEvent(SoundKind.alarm, 100, 149),
        const SoundEvent(SoundKind.alarm, 3100, 3149),
      ]);
      await h.pump(100);
      await h.pump(3000);
      expect(h.plays, [('playAlarm', 100), ('playAlarm', 3100)]);
    },
  );

  _nativeTest('suspend rebases pending timers and skips expired cues', (
    h,
  ) async {
    const events = [
      SoundEvent(SoundKind.alarm, 2000, 2049),
      SoundEvent(SoundKind.alarm, 7000, 7049),
      SoundEvent(SoundKind.end, 10000, 10000),
    ];
    h.schedule(events);
    h.clock.nowMs = 9000;
    h.schedule(events);
    await h.pump();
    expect(h.plays, isEmpty);
    expect(h.calls.last.method, 'cancelAlarm');
    await h.pump(1000);
    expect(h.plays, [('playEnd', 10000)]);
  });

  _nativeTest('a cue still valid after suspend can start immediately', (
    h,
  ) async {
    const event = SoundEvent(SoundKind.alarm, 2000, 2049);
    h.schedule([event]);
    h.clock.nowMs = 2040;
    h.schedule([event]);
    await h.pump();
    expect(h.plays, [('playAlarm', 2040)]);
  });

  _nativeTest('late completion remains delivered for the entire workout', (
    h,
  ) async {
    const event = SoundEvent(SoundKind.end, 10000, 10000);
    h.schedule([event]);
    h.clock.nowMs = 60000;
    h.schedule([event]);
    h.backend.cancel(keepEnd: true);
    await h.pump();
    expect(h.plays, [('playEnd', 60000)]);
    await h.pump(20001);
    h.schedule([event, const SoundEvent(SoundKind.end, 80000, 80000)]);
    await h.pump();
    expect(h.plays, [('playEnd', 60000)]);
    h.backend.cancel();
    h.schedule([event]);
    await h.pump();
    expect(h.plays, [('playEnd', 60000), ('playEnd', 80001)]);
  });
  for (final jitter in [0, 1, 23, 49]) {
    _nativeTest(
      'rest=3 preserves every planned beep with $jitter ms callback jitter',
      (h) async {
        final engine = TimerEngine(h.clock)
          ..start(const WorkoutOptions(active: 5, rest: 3, sets: 2));
        h.schedule(engine.soundsBetween(0, 300000));
        await h.pump(2000);
        h.clock.nowMs = 7000 + jitter;
        h.dispatchClock.nowMs = 7000;
        await h.tester.pump(const Duration(milliseconds: 5000));
        h.clock.nowMs = 10000;
        h.dispatchClock.nowMs = 10000;
        await h.tester.pump(const Duration(milliseconds: 3000));
        expect(h.plays, [
          ('playAlarm', 2000),
          ('playAlarm', 7000 + jitter),
          ('playAlarm', 10000),
        ]);
      },
    );
  }

  _nativeTest(
    'Start invalidates old timers with the finish-preserving native method',
    (h) async {
      h.schedule([const SoundEvent(SoundKind.alarm, 1000, 1049)]);
      h.backend.beginWorkout();
      await h.pump(1000);
      expect(h.plays, isEmpty);
      expect(h.calls.single.method, 'beginWorkout');
      expect(h.calls.single.arguments, {'generation': 1, 'alarmGeneration': 1});
    },
  );
}
