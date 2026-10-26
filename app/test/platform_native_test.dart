import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:easytimer/platform/timer_platform_native.dart';
import 'package:easytimer/timer_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

class _Player implements AudioPlayer {
  _Player(this.clock);

  final FakeClock clock;
  final completed = StreamController<void>.broadcast();
  final calls = <(String, Object?)>[];
  final starts = <(String, int)>[];
  final attempts = <int>[];
  FutureOr<void> Function(String) respond = (_) {};
  String asset = '';
  bool playing = false;

  Future<void> _call(String method, [Object? value]) async {
    calls.add((method, value));
    await respond(method);
  }

  @override
  Stream<void> get onPlayerComplete => completed.stream;
  @override
  Future<void> setPlayerMode(PlayerMode mode) => _call('mode', mode);
  @override
  Future<void> setReleaseMode(ReleaseMode mode) => _call('release', mode);
  @override
  Future<void> setAudioContext(AudioContext context) =>
      _call('context', context);
  @override
  Future<void> setSource(Source source) async {
    await _call('source', (source as AssetSource).path);
    asset = source.path;
  }

  @override
  Future<void> resume() async {
    attempts.add(clock.nowMs);
    await _call('resume');
    starts.add((asset, clock.nowMs));
    playing = true;
  }

  @override
  Future<void> stop() async {
    await _call('stop');
    playing = false;
  }

  @override
  Future<void> setVolume(double volume) => _call('volume', volume);
  @override
  Future<void> dispose() async {
    await _call('dispose');
    playing = false;
    await completed.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Backend extends PlatformBackend {
  _Backend(AudioPlayer player) : super(player: player);

  @override
  void keepAwake(bool enabled) {}
}

class _Harness {
  _Harness(this.tester);

  final WidgetTester tester;
  final clock = FakeClock();
  late final player = _Player(clock);
  late final backend = _Backend(player);

  Future<void> pump([int milliseconds = 0]) =>
      advanceClock(tester, clock, milliseconds);

  void schedule(List<SoundEvent> events) => backend.schedule(events, clock);

  Future<void> complete() async {
    player.playing = false;
    player.completed.add(null);
    await pump();
  }
}

void _nativeTest(String name, Future<void> Function(_Harness) body) {
  testWidgets(name, (tester) async {
    final h = _Harness(tester);
    try {
      await body(h);
    } finally {
      h.backend.dispose();
      await tester.pump();
    }
  });
}

void main() {
  _nativeTest('initialization gates playback and shares one future', (h) async {
    final loading = Completer<void>();
    h.player.respond = (method) => method == 'source' ? loading.future : null;
    final first = h.backend.initialize();
    expect(identical(first, h.backend.initialize()), isTrue);
    h.schedule([const SoundEvent(SoundKind.alarm, 0, 49)]);
    await h.pump();
    expect(h.player.starts, isEmpty);
    loading.complete();
    await h.pump();
    expect(h.player.starts, [('audio/threesecbeep.wav', 0)]);
    expect(
      h.player.calls.where((call) => call.$1 == 'mode').single.$2,
      PlayerMode.mediaPlayer,
    );
    expect(
      h.player.calls.where((call) => call.$1 == 'release').single.$2,
      ReleaseMode.stop,
    );
    final context =
        h.player.calls.singleWhere((call) => call.$1 == 'context').$2
            as AudioContext;
    expect(context.android.usageType, AndroidUsageType.media);
    expect(context.android.contentType, AndroidContentType.sonification);
    expect(context.android.audioFocus, AndroidAudioFocus.none);
  });

  _nativeTest('sorted overlapping plans keep one pending instance per cue', (
    h,
  ) async {
    const first = SoundEvent(SoundKind.alarm, 2000, 2049);
    const second = SoundEvent(SoundKind.alarm, 5000, 5049);
    h.schedule([second, first, first]);
    h.schedule([first, second]);
    await h.pump(1999);
    expect(h.player.starts, isEmpty);
    await h.pump(1);
    await h.pump(3000);
    expect(h.player.starts, [
      ('audio/threesecbeep.wav', 2000),
      ('audio/threesecbeep.wav', 5000),
    ]);
  });

  _nativeTest('only one wake timer services a long plan', (h) async {
    final timers = <Timer>[];
    await runZoned(
      () async {
        h.schedule([
          for (var at = 3000; at <= 300000; at += 3000)
            SoundEvent(SoundKind.alarm, at, at + 49),
        ]);
        expect(timers.where((timer) => timer.isActive), hasLength(1));
        await h.pump(1000);
        expect(timers.where((timer) => timer.isActive), hasLength(1));
        h.backend.cancel();
        expect(timers.where((timer) => timer.isActive), isEmpty);
      },
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          expectSync(duration, lessThanOrEqualTo(const Duration(seconds: 1)));
          final timer = parent.createTimer(zone, duration, callback);
          timers.add(timer);
          return timer;
        },
      ),
    );
  });

  for (final jitter in [0, 1, 23, 49]) {
    _nativeTest('planned spacing survives $jitter ms of callback jitter', (
      h,
    ) async {
      h.schedule(const [
        SoundEvent(SoundKind.alarm, 2000, 2049),
        SoundEvent(SoundKind.alarm, 7000, 7049),
        SoundEvent(SoundKind.alarm, 10000, 10049),
      ]);
      await h.pump(2000);
      await h.pump(5000 + jitter);
      await h.pump(3000 - jitter);
      expect(h.player.starts.map((start) => start.$2), [
        2000,
        7000 + jitter,
        10000,
      ]);
    });
  }

  _nativeTest('cancel clears both successful ledger and planned guard', (
    h,
  ) async {
    const first = SoundEvent(SoundKind.alarm, 0, 50000);
    h.schedule([first]);
    await h.pump();
    await h.pump(15000);
    h.schedule([first]);
    await h.pump();
    expect(h.player.starts, hasLength(1));
    h.schedule([const SoundEvent(SoundKind.alarm, 15000, 15049)]);
    await h.pump();
    h.backend.cancel();
    h.schedule([const SoundEvent(SoundKind.alarm, 16000, 16049)]);
    await h.pump(1000);
    expect(h.player.starts.map((start) => start.$2), [0, 15000, 16000]);
  });

  for (final operation in [
    'mode',
    'release',
    'context',
    'source',
    'volume',
    'stop',
    'resume',
  ]) {
    _nativeTest('$operation failure leaves the alarm retryable', (h) async {
      var failed = false;
      h.player.respond = (method) {
        if (method == operation && !failed) {
          failed = true;
          throw StateError('unavailable');
        }
      };
      h.schedule([const SoundEvent(SoundKind.alarm, 0, 49)]);
      await h.pump();
      expect(h.player.starts, isEmpty);
      await h.pump(10);
      expect(h.player.starts, [('audio/threesecbeep.wav', 10)]);
    });
  }

  _nativeTest('failed alarms retry every 10 ms only inside the window', (
    h,
  ) async {
    h.player.respond = (method) {
      if (method == 'resume') throw StateError('unavailable');
    };
    h.schedule([const SoundEvent(SoundKind.alarm, 0, 49)]);
    await h.pump();
    for (var i = 0; i < 10; i++) {
      await h.pump(10);
    }
    expect(h.player.attempts, [0, 10, 20, 30, 40]);
    h.player.respond = (_) {};
    h.schedule([const SoundEvent(SoundKind.alarm, 100, 149)]);
    await h.pump();
    expect(h.player.starts.single.$2, 100);
  });

  for (final late in [false, true]) {
    _nativeTest(
      'source preparation checks deadline before resume (late=$late)',
      (h) async {
        await h.backend.initialize();
        final loading = Completer<void>();
        h.player.respond = (method) =>
            method == 'source' ? loading.future : null;
        h.schedule([const SoundEvent(SoundKind.alarm, 0, 49)]);
        await h.pump();
        h.clock.nowMs = late ? 50 : 49;
        loading.complete();
        await h.pump();
        expect(h.player.attempts, late ? isEmpty : [49]);
      },
    );
  }

  for (final operation in ['source', 'resume']) {
    _nativeTest(
      'cancel during $operation ignores the old reply in the new plan',
      (h) async {
        await h.backend.initialize();
        final pending = Completer<void>();
        h.player.respond = (method) =>
            method == operation ? pending.future : null;
        h.schedule([const SoundEvent(SoundKind.alarm, 0, 49)]);
        await h.pump();
        h.backend.cancel();
        h.clock.nowMs = 100;
        h.schedule([const SoundEvent(SoundKind.alarm, 100, 149)]);
        h.player.respond = (_) {};
        pending.complete();
        await h.pump();
        expect(h.player.starts.last.$2, 100);
        expect(h.player.starts.length, operation == 'resume' ? 2 : 1);
      },
    );
  }

  _nativeTest(
    'duplicate scheduling retains an alarm awaiting its start reply',
    (h) async {
      final pending = Completer<void>();
      h.player.respond = (method) => method == 'resume' ? pending.future : null;
      const event = SoundEvent(SoundKind.alarm, 0, 49);
      h.schedule([event]);
      await h.pump();
      h.schedule([event]);
      await h.pump();
      expect(h.player.attempts, [0]);
      pending.complete();
      await h.pump();
      h.schedule([event]);
      await h.pump();
      expect(h.player.attempts, [0]);
    },
  );

  _nativeTest('bounded wake detects BOOTTIME jumping over expired cues', (
    h,
  ) async {
    h.schedule(const [
      SoundEvent(SoundKind.alarm, 2000, 2049),
      SoundEvent(SoundKind.alarm, 7000, 7049),
      SoundEvent(SoundKind.end, 10000, null),
    ]);
    h.clock.nowMs = 9000;
    await h.tester.pump(const Duration(seconds: 1));
    expect(h.player.starts, isEmpty);
    await h.pump(1000);
    expect(h.player.starts, [('audio/hit.wav', 10000)]);
  });

  for (final at in [0, 60000]) {
    _nativeTest('finish at $at has one chain of exactly three hits', (h) async {
      h.clock.nowMs = at;
      const event = SoundEvent(SoundKind.end, 0, null);
      h.schedule([event, const SoundEvent(SoundKind.end, 1, null)]);
      await h.pump();
      for (var i = 0; i < 4; i++) {
        await h.complete();
      }
      h.clock.nowMs += 20000;
      h.schedule([event]);
      await h.pump();
      expect(h.player.starts, List.filled(3, ('audio/hit.wav', at)));
    });
  }

  _nativeTest('cancel preserves a playing finish but cancels future cues', (
    h,
  ) async {
    h.schedule(const [
      SoundEvent(SoundKind.end, 0, null),
      SoundEvent(SoundKind.alarm, 100, 149),
    ]);
    await h.pump();
    h.backend.cancel();
    await h.pump();
    expect(h.player.playing, isTrue);
    await h.complete();
    await h.complete();
    await h.pump(100);
    expect(
      h.player.starts.map((start) => start.$1),
      List.filled(3, 'audio/hit.wav'),
    );
  });

  _nativeTest('a new cue replaces the playing finish and its remaining hits', (
    h,
  ) async {
    h.schedule([const SoundEvent(SoundKind.end, 0, null)]);
    await h.pump();
    h.backend.cancel();
    h.schedule([const SoundEvent(SoundKind.alarm, 100, 149)]);
    await h.pump(100);
    await h.complete();
    expect(h.player.starts, [
      ('audio/hit.wav', 0),
      ('audio/threesecbeep.wav', 100),
    ]);
  });

  _nativeTest(
    'failed finish waits for rescheduling, then stamps one successful chain',
    (h) async {
      h.player.respond = (method) {
        if (method == 'resume') throw StateError('unavailable');
      };
      const event = SoundEvent(SoundKind.end, 0, null);
      h.schedule([event]);
      await h.pump();
      await h.pump(10000);
      expect(h.player.attempts, [0]);
      h.player.respond = (_) {};
      h.schedule([event]);
      await h.pump();
      await h.complete();
      await h.complete();
      h.schedule([event]);
      await h.pump();
      expect(h.player.starts, List.filled(3, ('audio/hit.wav', 10000)));
    },
  );

  _nativeTest('squared gain updates a playing finish', (h) async {
    h.schedule([const SoundEvent(SoundKind.end, 0, null)]);
    await h.pump();
    h.player.calls.clear();
    for (final percent in [0, 25, 50, 100]) {
      h.backend.setVolume(percent);
      await h.pump();
    }
    expect(
      h.player.calls
          .where((call) => call.$1 == 'volume')
          .map((call) => call.$2),
      [0.0, 0.0625, 0.25, 1.0],
    );
    expect(h.player.playing, isTrue);
    expect(h.player.starts, hasLength(1));
  });

  _nativeTest(
    'cancel stops an alarm and dispose stops finish and pending work',
    (h) async {
      h.schedule([const SoundEvent(SoundKind.alarm, 0, 49)]);
      await h.pump();
      h.backend.cancel();
      await h.pump();
      expect(h.player.playing, isFalse);
      h.schedule(const [
        SoundEvent(SoundKind.end, 0, null),
        SoundEvent(SoundKind.alarm, 1000, 1049),
      ]);
      await h.pump();
      expect(h.player.playing, isTrue);
      h.backend.dispose();
      h.backend.dispose();
      await h.pump(1000);
      expect(h.player.playing, isFalse);
      expect(
        h.player.calls.where((call) => call.$1 == 'dispose'),
        hasLength(1),
      );
      expect(h.player.starts, hasLength(2));
    },
  );
}
