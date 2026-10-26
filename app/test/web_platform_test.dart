@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:easytimer/platform/timer_platform_web.dart';
import 'package:easytimer/timer_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'web/browser_fixture.dart';

class _Clock implements MonotonicClock {
  @override
  int nowMs = 0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PlatformBackend backend;
  late _Clock clock;
  var disposed = false;
  const alarm = SoundEvent(SoundKind.alarm, 12000, 12049);
  const end = SoundEvent(SoundKind.end, 10000, 10000);

  setUp(() async {
    installBrowserFixture();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (_) async => ByteData(1));
    clock = _Clock();
    backend = PlatformBackend();
    disposed = false;
    await backend.initialize();
  });

  tearDown(() async {
    if (!disposed) backend.dispose();
    await flushBrowserPromises();
    script('timerFixture.restore()');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
  });

  List<double> starts() =>
      numbers('timerFixture.starts.map(node => node.when)');
  List<double> liveStarts() => numbers(
    'timerFixture.starts.filter(node => !node.disconnected).map(node => node.when)',
  );
  void schedule(List<SoundEvent> events) => backend.schedule(events, clock);

  test('unlock calls resume synchronously in the input gesture', () async {
    script("timerFixture.state('suspended'); timerFixture.holdResume = true");
    backend.unlock();
    expect(number('timerFixture.resumeCalls'), 1);
    script('timerFixture.resolveResume()');
    await flushBrowserPromises();
  });

  test(
    'suspended audio is rebased before the queued alarm can resume',
    () async {
      schedule([alarm]);
      expect(starts(), [12]);
      script("timerFixture.context.state = 'suspended'");
      clock.nowMs = 10000;
      schedule([alarm]);
      expect(liveStarts(), isEmpty);
      backend.unlock();
      await flushBrowserPromises();
      expect(liveStarts(), [2]);
      expect(boolean('timerFixture.starts[0].disconnected'), isTrue);
      script('timerFixture.advance(2.01)');
      expect(number('timerFixture.played.length'), 1);
    },
  );

  test('interrupted state cancels future nodes without waiting for a tick', () {
    schedule([alarm]);
    script("timerFixture.state('interrupted')");
    expect(liveStarts(), isEmpty);
    clock.nowMs = 10000;
    script("timerFixture.state('running')");
    expect(liveStarts(), [2]);
  });

  test('running clock skew is corrected on a scheduling tick', () {
    script('timerFixture.context.currentTime = 40');
    schedule([alarm]);
    expect(liveStarts(), [52]);
    clock.nowMs = 10000;
    script('timerFixture.advance(41)');
    schedule([alarm]);
    expect(liveStarts(), [43]);
  });

  test('visibility rebases without relying on a controller callback', () {
    schedule([alarm]);
    clock.nowMs = 10000;
    script("timerFixture.visible('visible')");
    expect(liveStarts(), [2]);
  });

  test(
    'visible resumes suspended audio and rebases the future alarm',
    () async {
      schedule([alarm]);
      script("timerFixture.state('suspended'); timerFixture.visible('hidden')");
      expect(number('timerFixture.resumeCalls'), 0);
      clock.nowMs = 10000;
      script("timerFixture.visible('visible')");
      expect(number('timerFixture.resumeCalls'), 1);
      await flushBrowserPromises();
      expect(liveStarts(), [2]);
      script('timerFixture.advance(2.01)');
      expect(number('timerFixture.played.length'), 1);
    },
  );

  test(
    'visible retries a deferred finish after completion releases wake lock',
    () async {
      script(
        "timerFixture.state('interrupted'); timerFixture.failResume = true",
      );
      clock.nowMs = 60000;
      schedule([end]);
      backend.cancel(keepEnd: true);
      backend.keepAwake(false);
      script("timerFixture.visible('visible')");
      await flushBrowserPromises();
      expect(starts(), isEmpty);
      expect(number('timerFixture.resumeCalls'), 1);
      backend.cancel(keepEnd: true);
      script(
        "timerFixture.failResume = false; timerFixture.visible('visible')",
      );
      await flushBrowserPromises();
      expect(liveStarts(), [0, 0.25, 0.5]);
      script('timerFixture.advance(1)');
      schedule([end]);
      backend.cancel(keepEnd: true);
      script("timerFixture.visible('visible')");
      await flushBrowserPromises();
      expect(number('timerFixture.played.length'), 3);
      expect(liveStarts(), isEmpty);
      expect(number('timerFixture.wakeRequests.length'), 0);
    },
  );

  test('small audio rendering quantization does not rebuild every tick', () {
    schedule([alarm]);
    clock.nowMs = 1000;
    script('timerFixture.advance(0.997)');
    schedule([alarm]);
    expect(starts(), [12]);
  });

  test('a jump discards an expired alarm but retains the next future cue', () {
    const later = SoundEvent(SoundKind.alarm, 18000, 18049);
    schedule([alarm, later]);
    clock.nowMs = 15000;
    script("timerFixture.visible('visible')");
    expect(liveStarts(), [3]);
    script('timerFixture.advance(3.01)');
    expect(number('timerFixture.played.length'), 1);
  });

  test('resume at the alarm deadline is allowed and after it is silent', () {
    script("timerFixture.state('interrupted')");
    schedule([alarm]);
    clock.nowMs = 12049;
    script("timerFixture.state('running')");
    expect(liveStarts(), [0]);
    backend.cancel();
    script("timerFixture.state('interrupted')");
    schedule([alarm]);
    clock.nowMs = 12050;
    script("timerFixture.state('running')");
    expect(liveStarts(), isEmpty);
  });

  for (final deliverEnded in [false, true]) {
    test('late completion stays once after cleanup (ended=$deliverEnded)', () {
      schedule([end]);
      expect(starts(), [10, 10.25, 10.5]);
      clock.nowMs = 60000;
      script('timerFixture.advance(60, $deliverEnded)');
      schedule([]);
      schedule([end]);
      backend.cancel(keepEnd: true);
      schedule([end]);
      expect(starts(), [10, 10.25, 10.5]);
      expect(number('timerFixture.played.length'), 3);
      expect(liveStarts(), isEmpty);
    });
  }

  test('completion is idempotent before rendering the immediate end', () {
    clock.nowMs = 60000;
    schedule([end]);
    backend.cancel(keepEnd: true);
    schedule([end]);
    backend.cancel(keepEnd: true);
    expect(starts(), [0, 0.25, 0.5]);
    script('timerFixture.advance(1)');
    schedule([end]);
    expect(number('timerFixture.played.length'), 3);
    expect(starts(), [0, 0.25, 0.5]);
  });

  test('an unplayed end survives interruption and keepEnd completion', () {
    schedule([end]);
    script("timerFixture.state('interrupted')");
    clock.nowMs = 60000;
    schedule([]);
    schedule([end]);
    backend.cancel(keepEnd: true);
    expect(liveStarts(), isEmpty);
    expect(number('timerFixture.played.length'), 0);
    script("timerFixture.state('running')");
    expect(liveStarts(), [0, 0.25, 0.5]);
    script('timerFixture.advance(1)');
    schedule([end]);
    expect(number('timerFixture.played.length'), 3);
    expect(starts(), hasLength(6));
  });

  test('a resume rejection leaves unplayed completion available', () async {
    script("timerFixture.state('interrupted'); timerFixture.failResume = true");
    clock.nowMs = 60000;
    schedule([end]);
    backend.cancel(keepEnd: true);
    backend.unlock();
    await flushBrowserPromises();
    expect(starts(), isEmpty);
    script('timerFixture.failResume = false');
    backend.unlock();
    await flushBrowserPromises();
    expect(liveStarts(), [0, 0.25, 0.5]);
    script('timerFixture.advance(1)');
    expect(number('timerFixture.played.length'), 3);
  });

  test('an end that started keeps its remaining hits across interruption', () {
    schedule([end]);
    clock.nowMs = 10100;
    script('timerFixture.advance(10.1)');
    script("timerFixture.state('interrupted')");
    clock.nowMs = 60000;
    schedule([end]);
    backend.cancel(keepEnd: true);
    script("timerFixture.state('running'); timerFixture.advance(11)");
    schedule([end]);
    expect(starts(), [10, 10.25, 10.5]);
    expect(number('timerFixture.played.length'), 3);
  });

  test('played alarm identity outlives node cleanup and resynchronization', () {
    schedule([alarm]);
    clock.nowMs = 16000;
    script('timerFixture.advance(16)');
    script("timerFixture.visible('visible')");
    schedule([alarm]);
    expect(starts(), [12]);
    expect(number('timerFixture.played.length'), 1);
  });

  test('full cancel resets end delivery for a new workout', () {
    schedule([end]);
    clock.nowMs = 11000;
    script('timerFixture.advance(11)');
    backend.cancel();
    schedule([end]);
    script('timerFixture.advance(12)');
    expect(number('timerFixture.played.length'), 6);
  });

  test('Start keeps a playing finish tail without consuming the new end', () {
    schedule([end]);
    clock.nowMs = 10100;
    script('timerFixture.advance(10.1)');
    backend.beginWorkout();
    schedule([const SoundEvent(SoundKind.end, 20000, 20000)]);
    expect(
      numbers('timerFixture.starts.slice(0, 3).map(node => node.stopAt)'),
      everyElement(double.infinity),
    );
    clock.nowMs = 11000;
    script('timerFixture.advance(11)');
    schedule([]);
    expect(number('timerFixture.played.length'), 3);
    expect(liveStarts(), [20, 20.25, 20.5]);
    clock.nowMs = 60000;
    script('timerFixture.advance(60)');
    schedule([const SoundEvent(SoundKind.end, 20000, 20000)]);
    backend.cancel(keepEnd: true);
    expect(number('timerFixture.played.length'), 6);
    expect(starts(), hasLength(6));
  });

  test('the new prepare alarm preempts a long finish tail as one stream', () {
    script('timerFixture.buffers[1].duration = 1.17553');
    schedule([end]);
    clock.nowMs = 10100;
    script('timerFixture.advance(10.1)');
    backend.beginWorkout();
    final engine = TimerEngine(clock)
      ..start(const WorkoutOptions(active: 5, sets: 1));
    schedule(engine.soundsBetween(clock.nowMs, clock.nowMs + 300000));
    expect(
      numbers('timerFixture.starts.slice(0, 3).map(node => node.stopAt)'),
      everyElement(closeTo(12.1, 0.000001)),
    );
    expect(boolean('timerFixture.starts[0].disconnected'), isFalse);
    clock.nowMs = 13000;
    script('timerFixture.advance(13)');
    expect(
      number(
        "timerFixture.played.filter(node => node.buffer.kind === 'end').length",
      ),
      2,
    );
    expect(
      number(
        "timerFixture.played.filter(node => node.buffer.kind === 'alarm').length",
      ),
      1,
    );
  });

  test('Start cancels old alarms and a future finish without marking either played', () {
    schedule([alarm, end]);
    backend.beginWorkout();
    expect(liveStarts(), isEmpty);
    schedule([alarm, end]);
    expect(starts(), hasLength(8));
    expect(liveStarts(), [10, 10.25, 10.5, 12]);
  });

  test('Start discards an old deferred finish while preserving the new plan', () async {
    script("timerFixture.state('interrupted')");
    clock.nowMs = 60000;
    schedule([end]);
    backend.cancel(keepEnd: true);
    backend.beginWorkout();
    schedule([const SoundEvent(SoundKind.alarm, 62000, 62049)]);
    script("timerFixture.visible('visible')");
    await flushBrowserPromises();
    expect(liveStarts(), [2]);
    expect(
      number(
        "timerFixture.starts.filter(node => node.buffer.kind === 'end').length",
      ),
      0,
    );
  });

  test(
    'an old finish callback cannot remove a new sound with the same identity',
    () {
      schedule([end]);
      clock.nowMs = 10100;
      script('timerFixture.advance(10.1)');
      backend.beginWorkout();
      schedule([end]);
      script('timerFixture.advance(10.2)');
      expect(liveStarts(), [10.1, 10.35, 10.6]);
      clock.nowMs = 11000;
      script('timerFixture.advance(11)');
      schedule([end]);
      expect(number('timerFixture.played.length'), 4);
      expect(starts(), hasLength(6));
    },
  );

  test('Stop still cancels a finish tail preserved by Start', () {
    schedule([end]);
    clock.nowMs = 10100;
    script('timerFixture.advance(10.1)');
    backend.beginWorkout();
    expect(liveStarts(), [10, 10.25, 10.5]);
    backend.cancel();
    expect(liveStarts(), isEmpty);
    script('timerFixture.advance(11)');
    expect(number('timerFixture.played.length'), 1);
  });

  test('pause resets the alarm guard for a repeated resumed phase beep', () {
    const immediate = SoundEvent(SoundKind.alarm, 0, 49);
    schedule([immediate]);
    clock.nowMs = 10;
    script('timerFixture.advance(0.01)');
    backend.cancel();
    schedule([immediate]);
    clock.nowMs = 20;
    script('timerFixture.advance(0.02)');
    backend.cancel();
    schedule([const SoundEvent(SoundKind.alarm, 20, 69)]);
    script('timerFixture.advance(0.03)');
    expect(number('timerFixture.played.length'), 3);
  });

  test(
    'full cancel removes deferred sounds even after an old resume resolves',
    () async {
      script(
        "timerFixture.state('interrupted'); timerFixture.holdResume = true",
      );
      schedule([alarm, end]);
      backend.unlock();
      backend.cancel();
      script('timerFixture.resolveResume()');
      await flushBrowserPromises();
      expect(starts(), isEmpty);
    },
  );

  test('failed starts do not consume identity or the alarm guard', () {
    script('timerFixture.failStarts = 1');
    const immediate = SoundEvent(SoundKind.alarm, 0, 49);
    schedule([immediate]);
    expect(starts(), isEmpty);
    clock.nowMs = 10;
    script('timerFixture.advance(0.01)');
    schedule([immediate]);
    expect(starts(), [0.01]);
    expect(boolean('timerFixture.nodes[0].disconnected'), isTrue);
    script('timerFixture.advance(0.02)');
    schedule([immediate]);
    expect(number('timerFixture.played.length'), 1);
  });

  test('failed starts cannot retry an expired alarm', () {
    script('timerFixture.failStarts = 1');
    const immediate = SoundEvent(SoundKind.alarm, 0, 49);
    schedule([immediate]);
    clock.nowMs = 50;
    script('timerFixture.advance(0.05)');
    schedule([immediate]);
    expect(number('timerFixture.attempts'), 1);
    expect(starts(), isEmpty);
  });

  testWidgets('a failed start retries automatically inside its deadline', (
    tester,
  ) async {
    script('timerFixture.failStarts = 1');
    schedule([const SoundEvent(SoundKind.alarm, 0, 49)]);
    clock.nowMs = 10;
    script('timerFixture.advance(0.01)');
    await tester.pump(const Duration(milliseconds: 10));
    expect(starts(), [0.01]);
    script('timerFixture.advance(0.02)');
    expect(number('timerFixture.played.length'), 1);
    backend.cancel();
  });

  testWidgets('a retry after a clock jump discards the expired alarm', (
    tester,
  ) async {
    script('timerFixture.failStarts = 2');
    schedule([const SoundEvent(SoundKind.alarm, 0, 49)]);
    clock.nowMs = 1000;
    await tester.pump(const Duration(milliseconds: 10));
    expect(number('timerFixture.attempts'), 1);
    expect(starts(), isEmpty);
    backend.cancel();
  });

  testWidgets('full cancel removes the failed-start retry', (tester) async {
    script('timerFixture.failStarts = 1');
    schedule([const SoundEvent(SoundKind.alarm, 0, 49)]);
    backend.cancel();
    clock.nowMs = 10;
    await tester.pump(const Duration(milliseconds: 10));
    expect(number('timerFixture.attempts'), 1);
    expect(starts(), isEmpty);
  });

  test(
    'partially queued end failure cancels all nodes and remains eligible',
    () {
      script('timerFixture.failAttempt = 2');
      schedule([end]);
      expect(liveStarts(), isEmpty);
      schedule([end]);
      expect(liveStarts(), [10, 10.25, 10.5]);
      clock.nowMs = 60000;
      script('timerFixture.advance(60)');
      schedule([end]);
      expect(number('timerFixture.played.length'), 3);
    },
  );

  test('later cues replace the one stream and receive live squared gain', () {
    backend.setVolume(0.25);
    schedule([
      const SoundEvent(SoundKind.alarm, 0, 49),
      const SoundEvent(SoundKind.alarm, 3000, 3049),
      const SoundEvent(SoundKind.end, 5000, 5000),
    ]);
    expect(number('timerFixture.starts[0].stopAt'), 3);
    expect(number('timerFixture.starts[1].stopAt'), 5);
    expect(
      numbers('timerFixture.starts.map(node => node.gain.gain.value)'),
      everyElement(0.25),
    );
    backend.setVolume(0.09);
    expect(
      numbers('timerFixture.starts.map(node => node.gain.gain.value)'),
      everyElement(0.09),
    );
  });

  test(
    'the alarm guard rejects close planned cues instead of delaying them',
    () {
      schedule([
        const SoundEvent(SoundKind.alarm, 0, 49),
        const SoundEvent(SoundKind.alarm, 2999, 3048),
        const SoundEvent(SoundKind.alarm, 3100, 3149),
      ]);
      expect(starts(), [0, 3.1]);
    },
  );

  for (final jitterMs in [1, 25, 49]) {
    test(
      'three-second rest keeps both planned cues with ${jitterMs}ms jitter',
      () {
        final engine = TimerEngine(clock)
          ..start(const WorkoutOptions(active: 5, rest: 3, sets: 2));
        clock.nowMs = 7000 + jitterMs;
        script('timerFixture.advance(${clock.nowMs / 1000})');
        schedule(engine.soundsBetween(6951, 10000));
        expect(starts(), [7 + jitterMs / 1000, 10]);
        clock.nowMs++;
        script('timerFixture.advance(${clock.nowMs / 1000})');
        schedule([]);
        script(
          "timerFixture.state('interrupted'); timerFixture.state('running')",
        );
        expect(liveStarts(), [7 + jitterMs / 1000, 10]);
        clock.nowMs = 10001;
        script('timerFixture.advance(10.001)');
        schedule(engine.soundsBetween(9951, 10049));
        expect(number('timerFixture.played.length'), 2);
        expect(
          number('timerFixture.starts.lastIndexOf(timerFixture.played[1])'),
          2,
        );
      },
    );
  }

  test('a canceled planned alarm never stamps the successful cue guard', () {
    schedule([const SoundEvent(SoundKind.alarm, 1000, 1049)]);
    clock.nowMs = 1500;
    script("timerFixture.state('interrupted')");
    schedule([const SoundEvent(SoundKind.alarm, 3000, 3049)]);
    script("timerFixture.state('running')");
    expect(liveStarts(), [1.5]);
    script('timerFixture.advance(1.501)');
    expect(number('timerFixture.played.length'), 1);
  });

  test(
    'a failed start does not block a later cue inside three planned seconds',
    () {
      script('timerFixture.failStarts = 1');
      schedule([const SoundEvent(SoundKind.alarm, 0, 49)]);
      clock.nowMs = 2000;
      script('timerFixture.advance(2)');
      schedule([const SoundEvent(SoundKind.alarm, 2000, 2049)]);
      expect(liveStarts(), [2]);
      script('timerFixture.advance(2.001)');
      expect(number('timerFixture.played.length'), 1);
    },
  );

  test(
    'rapid Start Stop Start replaces a stale wake lock after release',
    () async {
      backend.keepAwake(true);
      backend.keepAwake(false);
      backend.keepAwake(true);
      expect(number('timerFixture.wakeRequests.length'), 1);
      script('timerFixture.resolveWake(0, true)');
      await flushBrowserPromises();
      expect(number('timerFixture.locks[0].releaseCalls'), 1);
      expect(number('timerFixture.wakeRequests.length'), 1);
      script('timerFixture.locks[0].finishRelease()');
      await flushBrowserPromises();
      expect(number('timerFixture.wakeRequests.length'), 2);
      script('timerFixture.resolveWake(1)');
      await flushBrowserPromises();
      expect(boolean('timerFixture.locks[1].released'), isFalse);
      backend.keepAwake(false);
      expect(number('timerFixture.locks[1].releaseCalls'), 1);
    },
  );

  test(
    'a stale failed wake request still acquires for the latest Start',
    () async {
      backend.keepAwake(true);
      backend.keepAwake(false);
      backend.keepAwake(true);
      script("timerFixture.wakeRequests[0].reject(new Error('denied'))");
      await flushBrowserPromises();
      expect(number('timerFixture.wakeRequests.length'), 2);
      script('timerFixture.resolveWake(1)');
      await flushBrowserPromises();
      expect(boolean('timerFixture.locks[1].released'), isFalse);
    },
  );

  test('stale release failure cannot strand a newer wake request', () async {
    backend.keepAwake(true);
    backend.keepAwake(false);
    backend.keepAwake(true);
    script('timerFixture.resolveWake(0, false, true)');
    await flushBrowserPromises();
    expect(number('timerFixture.wakeRequests.length'), 2);
    script('timerFixture.resolveWake(1)');
    await flushBrowserPromises();
  });

  test('wake denial waits for visibility or an explicit new Start', () async {
    backend.keepAwake(true);
    script("timerFixture.wakeRequests[0].reject(new Error('denied'))");
    await flushBrowserPromises();
    await flushBrowserPromises();
    expect(number('timerFixture.wakeRequests.length'), 1);
    script("timerFixture.visible('visible')");
    expect(number('timerFixture.wakeRequests.length'), 2);
    script("timerFixture.wakeRequests[1].reject(new Error('denied again'))");
    await flushBrowserPromises();
    expect(number('timerFixture.wakeRequests.length'), 2);
    backend.keepAwake(true);
    expect(number('timerFixture.wakeRequests.length'), 3);
    script('timerFixture.resolveWake(2)');
    await flushBrowserPromises();
  });

  test(
    'visibility retry during a failing acquisition is reconciled once',
    () async {
      backend.keepAwake(true);
      script("timerFixture.visible('hidden'); timerFixture.visible('visible')");
      script("timerFixture.wakeRequests[0].reject(new Error('denied'))");
      await flushBrowserPromises();
      expect(number('timerFixture.wakeRequests.length'), 2);
      script("timerFixture.wakeRequests[1].reject(new Error('denied'))");
      await flushBrowserPromises();
      expect(number('timerFixture.wakeRequests.length'), 2);
    },
  );

  test('a stale release finishing after Stop cannot reacquire', () async {
    backend.keepAwake(true);
    backend.keepAwake(false);
    backend.keepAwake(true);
    script('timerFixture.resolveWake(0, true)');
    await flushBrowserPromises();
    backend.keepAwake(false);
    script('timerFixture.locks[0].finishRelease()');
    await flushBrowserPromises();
    expect(number('timerFixture.wakeRequests.length'), 1);
  });

  test('disposal releases a late acquisition and prevents retries', () async {
    backend.keepAwake(true);
    backend.dispose();
    disposed = true;
    script('timerFixture.resolveWake(0)');
    await flushBrowserPromises();
    expect(number('timerFixture.locks[0].releaseCalls'), 1);
    expect(number('timerFixture.wakeRequests.length'), 1);
    script("timerFixture.visible('visible')");
    expect(number('timerFixture.wakeRequests.length'), 1);
  });
}
