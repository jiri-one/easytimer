@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:easytimer/audio.dart';
import 'package:easytimer/platform/timer_platform_web.dart';
import 'package:easytimer/timer_engine.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

import 'test_support.dart';
import 'web/browser_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BrowserFixture audio;
  late PlatformBackend backend;
  late FakeClock clock;
  const alarm = SoundEvent(SoundKind.alarm, 12000, 12049);
  const end = SoundEvent(SoundKind.end, 10000, null);

  setUp(() async {
    audio = BrowserFixture()..install();
    clock = FakeClock();
    backend = PlatformBackend(clock);
    await backend.initialize();
  });

  tearDown(() async {
    backend.dispose();
    await pumpEventQueue(times: 2);
    audio.restore();
  });

  void schedule(List<SoundEvent> events) => backend.schedule(events);

  test(
    'keyboard resumes before Flutter stops propagation to the document',
    () async {
      final stop = ((web.Event event) => event.stopPropagation()).toJS;
      web.window.addEventListener('keydown', stop, true.toJS);
      try {
        audio.state('suspended');
        schedule([alarm]);
        audio.activate('keydown');
        await pumpEventQueue(times: 2);
        expect(audio.resumeCalls, 1);
        expect(audio.context.state, 'running');
        expect(audio.liveStarts, [12]);
      } finally {
        web.window.removeEventListener('keydown', stop, true.toJS);
      }
    },
  );

  for (final action in ['continue', 'cancel', 'dispose']) {
    test('asynchronous loading respects the current plan: $action', () async {
      backend.dispose();
      audio.restore();
      audio = BrowserFixture()..install();
      audio.decodeGate = Completer<void>();
      backend = PlatformBackend(clock);
      final initialized = backend.initialize();
      schedule([alarm]);
      audio.activate('pointerup');
      await audio.decoding.future;
      expect(audio.startTimes, isEmpty);
      if (action == 'cancel') backend.cancel();
      if (action == 'dispose') backend.dispose();
      audio.decodeGate!.complete();
      await initialized;
      expect(audio.liveStarts, action == 'continue' ? [12] : isEmpty);
      if (action == 'dispose') {
        audio.visible('visible');
        expect(audio.resumeCalls, 1);
      }
    });
  }

  for (final type in ['pointerdown', 'pointerup', 'touchend', 'keydown']) {
    test('$type resumes synchronously through document capture', () async {
      audio.state('suspended');
      schedule([alarm]);
      audio.activate(type);
      expect(audio.resumeCalls, 1);
      await pumpEventQueue(times: 2);
      expect(audio.liveStarts, [12]);
    });
  }

  test(
    'healthy activation resumes without rebuilding the running plan',
    () async {
      schedule([alarm]);
      clock.nowMs = 1000;
      audio.advance(0.997);
      audio.activate('pointerup');
      expect(audio.resumeCalls, 1);
      await pumpEventQueue(times: 2);
      expect(audio.startTimes, [12]);
      expect(audio.liveStarts, [12]);

      audio.state('suspended');
      audio.holdResume = true;
      audio.activate('pointerup');
      expect(audio.resumeCalls, 2);
      expect(audio.liveStarts, isEmpty);
      audio.resolveResume();
      await pumpEventQueue(times: 2);
      expect(audio.liveStarts.single, closeTo(11.997, 0.000001));
    },
  );

  for (final state in ['suspended', 'interrupted']) {
    for (final resume in ['gesture', 'visibility', 'statechange']) {
      test('$state resyncs the future alarm through $resume', () async {
        schedule([alarm]);
        audio.state(state);
        expect(audio.liveStarts, isEmpty);
        clock.nowMs = 10000;
        switch (resume) {
          case 'gesture':
            audio.activate('pointerup');
          case 'visibility':
            audio.visible('hidden');
            expect(audio.resumeCalls, 0);
            audio.visible('visible');
          case 'statechange':
            audio.state('running');
        }
        await pumpEventQueue(times: 2);
        expect(audio.liveStarts, [2]);
        audio.advance(2.01);
        expect(audio.played, hasLength(1));
      });
    }
  }

  for (final trigger in ['tick', 'visibility']) {
    test('running audio-clock drift is corrected on $trigger', () async {
      audio.context.currentTime = 40;
      schedule([alarm]);
      expect(audio.liveStarts, [52]);
      clock.nowMs = 10000;
      audio.advance(41);
      if (trigger == 'tick') {
        schedule([alarm]);
      } else {
        audio.visible('visible');
        await pumpEventQueue(times: 2);
      }
      expect(audio.liveStarts, [43]);
    });
  }

  for (final now in [12000, 12049, 12050]) {
    test('alarm deadline is inclusive at $now ms after interruption', () {
      schedule([alarm]);
      audio.state('interrupted');
      clock.nowMs = now;
      audio.state('running');
      expect(audio.liveStarts, now <= 12049 ? [0] : isEmpty);
    });
  }

  test('clock jump drops expired alarm and keeps next future cue', () {
    schedule([alarm, const SoundEvent(SoundKind.alarm, 18000, 18049)]);
    clock.nowMs = 15000;
    schedule([]);
    expect(audio.liveStarts, [3]);
    audio.advance(3.01);
    expect(audio.played, hasLength(1));
  });

  test('future sources dropped by a newly merged cue are stopped', () {
    const later = SoundEvent(SoundKind.alarm, 5000, 5049);
    schedule([later]);
    final dropped = audio.starts.single;
    schedule([const SoundEvent(SoundKind.alarm, 3000, 3049)]);
    expect(dropped.disconnected, isTrue);
    expect(dropped.stopAt, 0);
    expect(audio.liveStarts, [3]);
    clock.nowMs = 3001;
    audio.advance(3.001);
    schedule([later]);
    expect(audio.startTimes, [5, 3]);
  });

  test('end decodes tripled PCM into one continuous source', () async {
    final original = await rootBundle.load(SoundKind.end.asset);
    final hitSeconds =
        original.getUint32(40, Endian.little) /
        original.getUint32(28, Endian.little);
    schedule([end]);
    expect(audio.buffers, hasLength(2));
    final source = audio.starts.single;
    expect(source.buffer.duration, closeTo(hitSeconds * 3, 0.000001));
    expect(
      source.buffer.bytes.lengthInBytes,
      44 + (original.lengthInBytes - 44) * 3,
    );
    audio.advance(10 + hitSeconds * 2);
    expect(source.disconnected, isFalse);
    audio.advance(10 + hitSeconds * 3);
    expect(audio.played, [source]);
    expect(source.disconnected, isTrue);
  });

  for (final historical in [false, true]) {
    for (final deliverEnded in [false, true]) {
      test('end once: historical=$historical, ended=$deliverEnded', () {
        clock.nowMs = historical ? 60000 : 0;
        schedule([end]);
        schedule([end]);
        expect(audio.startTimes, hasLength(1));
        audio.advance(60, deliverEnded: deliverEnded);
        clock.nowMs = 600000;
        schedule([]);
        schedule([end, const SoundEvent(SoundKind.end, 590000, null)]);
        audio.visible('visible');
        expect(audio.played, hasLength(1));
        expect(audio.startTimes, hasLength(1));
        expect(audio.liveStarts, isEmpty);
      });
    }
  }

  for (final begun in [false, true]) {
    for (final deliverEnded in [false, true]) {
      test('end resync: begun=$begun, ended=$deliverEnded', () {
        schedule([end]);
        audio.advance(begun ? 10.1 : 10);
        clock.nowMs = begun ? 10100 : 10000;
        audio.state('interrupted');
        clock.nowMs = 60000;
        schedule([end]);
        audio.state('running');
        audio.advance(14, deliverEnded: deliverEnded);
        schedule([end]);
        expect(audio.played, hasLength(1));
        expect(audio.startTimes, hasLength(begun ? 1 : 2));
        expect(audio.liveStarts, isEmpty);
      });
    }
  }

  test(
    'touch release retries a denied activation and historical end',
    () async {
      audio.state('interrupted');
      audio.failResume = true;
      clock.nowMs = 60000;
      schedule([end]);
      audio.activate('pointerdown', pointerType: 'touch');
      await pumpEventQueue(times: 2);
      expect(audio.startTimes, isEmpty);
      audio.failResume = false;
      audio.activate('pointerup', pointerType: 'touch');
      await pumpEventQueue(times: 2);
      expect(audio.liveStarts, [0]);
      audio.advance(4);
      schedule([end]);
      expect(audio.played, hasLength(1));
      expect(audio.resumeCalls, 2);
    },
  );

  test('played alarm ledger survives source cleanup and long idle time', () {
    schedule([alarm]);
    audio.advance(16);
    clock.nowMs = 600000;
    schedule([const SoundEvent(SoundKind.alarm, 12000, 700000)]);
    expect(audio.played, hasLength(1));
    expect(audio.startTimes, [12]);
    expect(audio.liveStarts, isEmpty);
  });

  test('cancel drops queued nodes and resets identities for the next plan', () {
    schedule([alarm, end]);
    backend.cancel();
    expect(audio.liveStarts, isEmpty);
    schedule([alarm, end]);
    expect(audio.startTimes, hasLength(4));
    expect(audio.liveStarts, [10, 12]);
  });

  test('cancel stops a playing alarm and resets the planned-time guard', () {
    const immediate = SoundEvent(SoundKind.alarm, 0, 49);
    for (var index = 0; index < 3; index++) {
      schedule([immediate]);
      clock.nowMs += 10;
      audio.advance(clock.nowMs / 1000);
      backend.cancel();
      expect(audio.liveStarts, isEmpty);
    }
    expect(audio.played, hasLength(3));
  });

  test('cancel preserves the end source through repeated cancellation', () {
    schedule([end]);
    clock.nowMs = 10100;
    audio.advance(10.1);
    backend.cancel();
    backend.cancel();
    expect(audio.liveStarts, [10]);
    expect(
      audio.starts.map((node) => node.stopAt),
      everyElement(double.infinity),
    );
    audio.advance(14);
    expect(audio.played, hasLength(1));
    expect(audio.liveStarts, isEmpty);
  });

  test('old end tail completion cannot consume the new plan end', () {
    schedule([end]);
    clock.nowMs = 10100;
    audio.advance(10.1);
    backend.cancel();
    const nextEnd = SoundEvent(SoundKind.end, 20000, null);
    schedule([nextEnd]);
    audio.advance(14);
    clock.nowMs = 14000;
    schedule([nextEnd]);
    expect(audio.liveStarts, [20]);
    audio.advance(24);
    clock.nowMs = 24000;
    schedule([nextEnd]);
    expect(audio.played, hasLength(2));
    expect(audio.startTimes, hasLength(2));
  });

  test('new prepare cue replaces an overlapping finish as one stream', () {
    schedule([end]);
    final tail = audio.starts.single;
    clock.nowMs = 10100;
    audio.advance(10.1);
    backend.cancel();
    final engine = TimerEngine(clock)
      ..start(const WorkoutOptions(active: 5, sets: 1));
    schedule(engine.soundsBetween(clock.nowMs, clock.nowMs + 300000));
    expect(tail.stopAt, closeTo(12.1, 0.000001));
    audio.advance(13);
    expect(tail.disconnected, isTrue);
    expect(audio.played, [tail, audio.starts[1]]);
  });

  test('a stale resume cannot restore canceled deferred sounds', () async {
    audio.state('interrupted');
    audio.holdResume = true;
    schedule([alarm, end]);
    audio.activate('pointerup');
    backend.cancel();
    schedule([const SoundEvent(SoundKind.alarm, 20000, 20049)]);
    audio.resolveResume();
    await pumpEventQueue(times: 2);
    expect(audio.liveStarts, [20]);
  });

  test('a suppressed future cue survives failure of its preceding alarm', () {
    schedule([
      const SoundEvent(SoundKind.alarm, 1000, 1049),
      const SoundEvent(SoundKind.alarm, 3000, 3049),
    ]);
    expect(audio.liveStarts, [1]);
    clock.nowMs = 1500;
    audio.state('interrupted');
    audio.state('running');
    expect(audio.liveStarts, [1.5]);
    audio.advance(1.501);
    expect(audio.played, hasLength(1));
  });

  for (final jitterMs in [1, 25, 49]) {
    test('three-second rest retains both cues with ${jitterMs}ms jitter', () {
      final engine = TimerEngine(clock)
        ..start(const WorkoutOptions(active: 5, rest: 3, sets: 2));
      clock.nowMs = 7000 + jitterMs;
      audio.advance(clock.nowMs / 1000);
      schedule(engine.soundsBetween(6951, 10000));
      expect(audio.startTimes, [7 + jitterMs / 1000, 10]);
      clock.nowMs++;
      audio.advance(clock.nowMs / 1000);
      schedule([]);
      audio.state('interrupted');
      audio.state('running');
      clock.nowMs = 10001;
      audio.advance(10.001);
      schedule(engine.soundsBetween(9951, 10049));
      expect(audio.played, hasLength(2));
    });
  }

  test('five-minute rolling plan extends an endless workout', () {
    final engine = TimerEngine(clock)
      ..start(const WorkoutOptions(active: 5, rest: 3, sets: 0));
    schedule(engine.soundsBetween(-49, 300000));
    final firstCount = audio.startTimes.length;
    expect(audio.startTimes, everyElement(lessThanOrEqualTo(300)));
    clock.nowMs = 300000;
    audio.advance(300);
    schedule(engine.soundsBetween(clock.nowMs - 49, clock.nowMs + 300000));
    expect(audio.startTimes.length, greaterThan(firstCount));
    expect(audio.liveStarts.last, greaterThan(590));
    expect(audio.liveStarts, everyElement(lessThanOrEqualTo(600)));
  });

  test('later cues replace one stream and share live squared volume', () {
    schedule([
      const SoundEvent(SoundKind.alarm, 0, 49),
      const SoundEvent(SoundKind.alarm, 3000, 3049),
      const SoundEvent(SoundKind.end, 5000, null),
    ]);
    expect(audio.starts[0].stopAt, 3);
    expect(audio.starts[1].stopAt, 5);
    expect(
      audio.starts.map((node) => node.connectedTo),
      everyElement(audio.gain.js),
    );
    for (final (percent, gain) in [
      (50, 0.25),
      (30, 0.09),
      (0, 0.0),
      (100, 1.0),
    ]) {
      backend.setVolume(percent);
      expect(audio.gain.value, closeTo(gain, 0.000001));
    }
    expect(audio.startTimes, hasLength(3));
  });

  test(
    'dispose stops the end tail, removes listeners and ignores further work',
    () async {
      schedule([end]);
      audio.advance(10.1);
      backend.cancel();
      backend.dispose();
      expect(audio.liveStarts, isEmpty);
      expect(audio.context.state, 'closed');
      audio.visible('visible');
      for (final type in ['pointerdown', 'pointerup', 'touchend', 'keydown']) {
        audio.activate(type);
      }
      schedule([alarm]);
      await pumpEventQueue(times: 2);
      expect(audio.resumeCalls, 0);
      expect(audio.startTimes, hasLength(1));
    },
  );
}
