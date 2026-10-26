@TestOn('browser')
library;

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:easytimer/constants.dart';
import 'package:easytimer/platform/timer_platform_native.dart' as native;
import 'package:easytimer/platform/timer_platform_web.dart' as web;
import 'package:easytimer/timer_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';
import 'web/browser_fixture.dart';

class _Player implements AudioPlayer {
  final completed = StreamController<void>.broadcast(sync: true);
  final starts = <SoundKind>[];
  late SoundKind currentKind;

  @override
  Stream<void> get onPlayerComplete => completed.stream;
  @override
  Future<void> setPlayerMode(PlayerMode mode) async {}
  @override
  Future<void> setReleaseMode(ReleaseMode mode) async {}
  @override
  Future<void> setAudioContext(AudioContext context) async {}
  @override
  Future<void> setSource(Source value) async {
    currentKind = (value as AssetSource).path == alarmAsset.substring(7)
        ? SoundKind.alarm
        : SoundKind.end;
  }

  @override
  Future<void> resume() async => starts.add(currentKind);
  @override
  Future<void> stop() async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> dispose() => completed.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  final audio = BrowserFixture()..install();
  final clock = FakeClock();
  final player = _Player();
  final browser = web.PlatformBackend();
  late final device = native.PlatformBackend(player: player);

  void schedule(List<SoundEvent> events) {
    browser.schedule(events, clock);
    device.schedule(events, clock);
  }

  void cancel() {
    browser.cancel();
    device.cancel();
  }

  Future<void> finish(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      player.completed.add(null);
      await tester.pump();
    }
  }

  void expectPlays(List<SoundKind> expected) {
    expect(player.starts, expected, reason: 'native plugin path');
    expect(
      audio.played.map((node) => node.buffer.kind),
      expected,
      reason: 'Web Audio path',
    );
  }
}

void _parityTest(
  String name,
  Future<void> Function(_Harness, WidgetTester) body,
) {
  testWidgets(name, (tester) async {
    final h = _Harness();
    try {
      await tester.runAsync(h.browser.initialize);
      await h.device.initialize();
      await body(h, tester);
    } finally {
      h.browser.dispose();
      h.device.dispose();
      await tester.pump();
      h.audio.restore();
    }
  });
}

void main() {
  const alarm = SoundEvent(SoundKind.alarm, 1000, 1049);
  const end = SoundEvent(SoundKind.end, 1000, null);
  for (final (event, now, count) in [
    (alarm, 1000, 1),
    (alarm, 1049, 1),
    (alarm, 1050, 0),
    (end, 1000, 3),
    (end, 600000, 3),
  ]) {
    _parityTest('${event.kind.name} parity at $now ms', (h, tester) async {
      h.clock.nowMs = now;
      h.schedule([event, event]);
      await tester.pump();
      h.audio.advance(1);
      await h.finish(tester);
      h.clock.nowMs = 900000;
      h.schedule([event]);
      await tester.pump();
      h.expectPlays(List.filled(count, event.kind));
    });
  }

  for (final jitterMs in [1, 25, 49]) {
    _parityTest('planned three-second spacing parity at ${jitterMs}ms jitter', (
      h,
      tester,
    ) async {
      final engine = TimerEngine(h.clock)
        ..start(const WorkoutOptions(active: 5, rest: 3, sets: 2));
      h.clock.nowMs = 7000 + jitterMs;
      h.audio.advance(h.clock.nowMs / 1000);
      h.schedule(engine.soundsBetween(6951, 10000));
      await tester.pump();
      h.audio.advance((h.clock.nowMs + 1) / 1000);
      h.clock.nowMs = 10000;
      await tester.pump(Duration(milliseconds: 3000 - jitterMs));
      h.audio.advance(10.001);
      h.schedule(engine.soundsBetween(9951, 10049));
      await tester.pump();
      h.expectPlays([SoundKind.alarm, SoundKind.alarm]);
    });
  }

  _parityTest('future reservation does not stamp guard; cancel resets it', (
    h,
    tester,
  ) async {
    h.schedule([alarm]);
    h.clock.nowMs = 1500;
    h.audio.state('interrupted');
    const next = SoundEvent(SoundKind.alarm, 3000, 3049);
    h.schedule([next]);
    h.audio.state('running');
    h.clock.nowMs = 3000;
    await tester.pump(const Duration(milliseconds: 3000));
    h.audio.advance(1.501);
    h.expectPlays([SoundKind.alarm]);
    h.cancel();
    h.clock.nowMs = 3010;
    h.schedule([next]);
    await tester.pump();
    h.audio.advance(1.511);
    h.expectPlays([SoundKind.alarm, SoundKind.alarm]);
  });

  _parityTest(
    'close planned cues are dropped instead of delayed on both paths',
    (h, tester) async {
      h.schedule([
        const SoundEvent(SoundKind.alarm, 0, 49),
        const SoundEvent(SoundKind.alarm, 2999, 3048),
        const SoundEvent(SoundKind.alarm, 3100, 3149),
      ]);
      await tester.pump();
      h.audio.advance(0.001);
      h.clock.nowMs = 2999;
      await tester.pump(const Duration(milliseconds: 2999));
      h.audio.advance(2.999);
      h.expectPlays([SoundKind.alarm]);
      h.clock.nowMs = 3100;
      await tester.pump(const Duration(milliseconds: 101));
      h.audio.advance(3.101);
      h.expectPlays([SoundKind.alarm, SoundKind.alarm]);
    },
  );

  _parityTest('cancel keeps end tail and gives the next plan a fresh end', (
    h,
    tester,
  ) async {
    h.clock.nowMs = 60000;
    h.schedule([end]);
    await tester.pump();
    h.audio.advance(0.1);
    h.cancel();
    h.cancel();
    await tester.pump();
    await h.finish(tester);
    h.audio.advance(1);
    h.expectPlays(List.filled(3, SoundKind.end));
    h.schedule([end]);
    await tester.pump();
    await h.finish(tester);
    h.audio.advance(2);
    h.expectPlays(List.filled(6, SoundKind.end));
  });
}
