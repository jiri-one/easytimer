import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:easytimer/audio.dart';
import 'package:flutter/services.dart';
import 'package:easytimer/platform/timer_platform_native.dart';
import 'package:easytimer/timer_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

class _Harness {
  _Harness(this.tester);

  final WidgetTester tester;
  final clock = FakeClock();
  final starts = <(SoundKind, int)>[];
  int maximumPlaying = 0;
  late final alarm = FakeAudioPlayer(
    clock,
    starts: starts,
    onStart: _checkStream,
  );
  late final end = FakeAudioPlayer(
    clock,
    starts: starts,
    onStart: _checkStream,
  );
  late final backend = PlatformBackend(
    clock,
    alarmPlayer: alarm,
    endPlayer: end,
  );

  List<FakeAudioPlayer> get players => [alarm, end];

  void _checkStream() {
    final playing = players.where((player) => player.playing).length;
    if (playing > maximumPlaying) maximumPlaying = playing;
  }

  Future<void> pump([int milliseconds = 0]) =>
      advanceClock(tester, clock, milliseconds);

  void schedule(List<SoundEvent> events) => backend.schedule(events);

  Future<void> complete() async {
    for (final player in players.where((player) => player.playing)) {
      player.state = PlayerState.completed;
      player.position = const Duration(seconds: 30);
    }
    await pump();
  }
}

void _nativeTest(String name, Future<void> Function(_Harness) body) {
  testWidgets(name, (tester) async {
    final h = _Harness(tester);
    try {
      await body(h);
      expect(h.maximumPlaying, lessThanOrEqualTo(1));
    } finally {
      h.backend.cancel();
      await tester.pump();
      for (final player in h.players) {
        await player.dispose();
      }
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final assets = <String, ByteData>{};
  setUpAll(() async {
    for (final kind in SoundKind.values) {
      assets[kind.asset] = await rootBundle.load(kind.asset);
    }
  });
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
          return assets[utf8.decode(
            message!.buffer.asUint8List(
              message.offsetInBytes,
              message.lengthInBytes,
            ),
          )];
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
  });
  _nativeTest('initialization gates playback and shares one future', (h) async {
    final loading = Completer<void>();
    h.alarm.respond = (method) => method == 'source' ? loading.future : null;
    final first = h.backend.initialize();
    expect(identical(first, h.backend.initialize()), isTrue);
    h.schedule([const SoundEvent(SoundKind.alarm, 0, 49)]);
    await h.pump();
    expect(h.starts, isEmpty);
    loading.complete();
    await h.pump();
    expect(h.starts, [(SoundKind.alarm, 0)]);
    for (final player in h.players) {
      expect(
        player.calls.singleWhere((call) => call.$1 == 'mode').$2,
        PlayerMode.mediaPlayer,
      );
      expect(
        player.calls.singleWhere((call) => call.$1 == 'release').$2,
        ReleaseMode.stop,
      );
      final context =
          player.calls.singleWhere((call) => call.$1 == 'context').$2
              as AudioContext;
      expect(context.android.usageType, AndroidUsageType.media);
      expect(context.android.contentType, AndroidContentType.sonification);
      expect(context.android.audioFocus, AndroidAudioFocus.none);
    }
  });

  _nativeTest('sorted overlapping plans keep one pending instance per cue', (
    h,
  ) async {
    const first = SoundEvent(SoundKind.alarm, 2000, 2049);
    const second = SoundEvent(SoundKind.alarm, 5000, 5049);
    h.schedule([second, first, first]);
    h.schedule([first, second]);
    await h.pump(1999);
    expect(h.starts, isEmpty);
    await h.pump(1);
    await h.pump(3000);
    expect(h.starts, [(SoundKind.alarm, 2000), (SoundKind.alarm, 5000)]);
  });

  _nativeTest(
    'schedule reads the clock once and duplicate plans do not rearm',
    (h) async {
      final timers = <Timer>[];
      await runZoned(
        () async {
          const event = SoundEvent(SoundKind.alarm, 3000, 3049);
          h.clock.reads = 0;
          h.schedule([event]);
          expect(h.clock.reads, 1);
          expect(timers, hasLength(1));
          final timer = timers.single;
          h.clock.reads = 0;
          h.schedule([event]);
          expect(h.clock.reads, 1);
          expect(timers, [timer]);
          expect(timer.isActive, isTrue);
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            final timer = parent.createTimer(zone, duration, callback);
            timers.add(timer);
            return timer;
          },
        ),
      );
    },
  );

  _nativeTest(
    'each source is prepared once and every cue seeks before resume',
    (h) async {
      await h.backend.initialize();
      final alarm = h.alarm.source;
      expect(alarm, isA<BytesSource>());
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler(
            'flutter/assets',
            (_) async => throw StateError('already preloaded'),
          );
      h.schedule(const [SoundEvent(SoundKind.end, 0, null)]);
      await h.pump();
      final end = h.end.source;
      expect(end, isA<BytesSource>());
      h.backend.cancel();
      h.schedule(const [SoundEvent(SoundKind.alarm, 100, 149)]);
      await h.pump(100);
      expect(identical(h.alarm.source, alarm), isTrue);
      h.backend.cancel();
      h.schedule(const [SoundEvent(SoundKind.end, 100, null)]);
      await h.pump();
      expect(identical(h.end.source, end), isTrue);
      expect(h.starts.map((start) => start.$1), [
        SoundKind.end,
        SoundKind.alarm,
        SoundKind.end,
      ]);
      for (final player in h.players) {
        expect(player.calls.where((call) => call.$1 == 'source'), hasLength(1));
        expect(
          player.calls.where((call) => ['seek', 'resume'].contains(call.$1)),
          [
            for (final _ in player.attempts) ...[
              ('seek', Duration.zero),
              ('resume', null),
            ],
          ],
        );
      }
    },
  );

  _nativeTest('completed players replay from zero without preparing again', (
    h,
  ) async {
    for (var round = 0; round < 2; round++) {
      for (final kind in SoundKind.values) {
        h.backend.cancel();
        h.schedule([SoundEvent(kind, h.clock.nowMs, null)]);
        await h.pump();
        final player = kind == SoundKind.alarm ? h.alarm : h.end;
        expect(player.position, Duration.zero);
        expect(player.playing, isTrue);
        await h.complete();
      }
    }
    expect(h.starts.map((event) => event.$1), [
      SoundKind.alarm,
      SoundKind.end,
      SoundKind.alarm,
      SoundKind.end,
    ]);
    for (final player in h.players) {
      expect(player.calls.where((call) => call.$1 == 'source'), hasLength(1));
      expect(player.calls.where((call) => call.$1 == 'seek'), hasLength(2));
      expect(player.calls.where((call) => call.$1 == 'stop'), isEmpty);
    }
  });

  for (final operation in ['source', 'volume']) {
    _nativeTest(
      'initialization retries $operation without resetting prepared sources',
      (h) async {
        var failed = false;
        h.end.respond = (method) {
          if (!failed && method == operation) {
            failed = true;
            throw StateError('unavailable');
          }
        };
        await h.backend.initialize();
        await h.backend.initialize();
        expect(
          h.alarm.calls.where((call) => call.$1 == 'source'),
          hasLength(1),
        );
        expect(
          h.end.calls.where((call) => call.$1 == 'source'),
          hasLength(operation == 'source' ? 2 : 1),
        );
        h.schedule(const [SoundEvent(SoundKind.alarm, 0, 49)]);
        await h.pump();
        expect(h.starts, [(SoundKind.alarm, 0)]);
      },
    );
  }

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
      expect(h.starts.map((start) => start.$2), [2000, 7000 + jitter, 10000]);
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
    expect(h.starts, hasLength(1));
    h.schedule([const SoundEvent(SoundKind.alarm, 15000, 15049)]);
    await h.pump();
    h.backend.cancel();
    h.schedule([const SoundEvent(SoundKind.alarm, 16000, 16049)]);
    await h.pump(1000);
    expect(h.starts.map((start) => start.$2), [0, 15000, 16000]);
  });

  for (final operation in [
    'mode',
    'release',
    'context',
    'source',
    'volume',
    'seek',
    'resume',
  ]) {
    _nativeTest('$operation failure leaves the alarm retryable', (h) async {
      var failed = false;
      h.alarm.respond = (method) {
        if (method == operation && !failed) {
          failed = true;
          throw StateError('unavailable');
        }
      };
      h.schedule([const SoundEvent(SoundKind.alarm, 0, 49)]);
      await h.pump();
      expect(h.starts, isEmpty);
      await h.pump(10);
      expect(h.starts, [(SoundKind.alarm, 10)]);
    });
  }

  _nativeTest('failed alarms retry every 10 ms only inside the window', (
    h,
  ) async {
    h.alarm.respond = (method) {
      if (method == 'resume') throw StateError('unavailable');
    };
    h.schedule([const SoundEvent(SoundKind.alarm, 0, 49)]);
    await h.pump();
    for (var i = 0; i < 10; i++) {
      await h.pump(10);
    }
    expect(h.alarm.attempts, [0, 10, 20, 30, 40]);
    h.alarm.respond = (_) {};
    h.schedule([const SoundEvent(SoundKind.alarm, 100, 149)]);
    await h.pump();
    expect(h.starts.single.$2, 100);
  });

  _nativeTest(
    'replacement retries a failed stop without dropping the next cue',
    (h) async {
      h.schedule(const [SoundEvent(SoundKind.end, 0, null)]);
      await h.pump();
      var failed = false;
      h.end.respond = (method) {
        if (method == 'stop' && !failed) {
          failed = true;
          throw StateError('unavailable');
        }
      };
      h.schedule(const [SoundEvent(SoundKind.alarm, 100, 149)]);
      await h.pump(100);
      expect(h.starts, [(SoundKind.end, 0)]);
      await h.pump(10);
      expect(h.starts, [(SoundKind.end, 0), (SoundKind.alarm, 110)]);
    },
  );

  _nativeTest('a failed reservation leaves the nearby future alarm available', (
    h,
  ) async {
    h.alarm.respond = (method) {
      if (method == 'resume') throw StateError('unavailable');
    };
    h.schedule(const [
      SoundEvent(SoundKind.alarm, 0, 49),
      SoundEvent(SoundKind.alarm, 2999, 3048),
    ]);
    await h.pump();
    await h.pump(50);
    h.alarm.respond = (_) {};
    await h.pump(2949);
    expect(h.starts, [(SoundKind.alarm, 2999)]);
  });

  for (final operation in ['source', 'seek', 'resume']) {
    _nativeTest(
      'an eligible alarm survives a slow $operation past its original window',
      (h) async {
        if (operation != 'source') await h.backend.initialize();
        final pending = Completer<void>();
        h.alarm.respond = (method) =>
            method == operation ? pending.future : null;
        h.schedule(const [SoundEvent(SoundKind.alarm, 0, 49)]);
        await h.pump();
        await h.pump(1000);
        pending.complete();
        await h.pump();
        expect(h.starts, [(SoundKind.alarm, 1000)]);
        expect(h.alarm.playing, isTrue);
        expect(h.alarm.calls.where((call) => call.$1 == 'stop'), isEmpty);
      },
    );
  }

  _nativeTest('an eligible alarm survives a slow stop replacing a finish', (
    h,
  ) async {
    h.schedule(const [SoundEvent(SoundKind.end, 0, null)]);
    await h.pump();
    final pending = Completer<void>();
    h.end.respond = (method) => method == 'stop' ? pending.future : null;
    h.schedule(const [SoundEvent(SoundKind.alarm, 100, 149)]);
    await h.pump(100);
    await h.pump(1000);
    expect(h.alarm.attempts, isEmpty);
    pending.complete();
    await h.pump();
    expect(h.starts, [(SoundKind.end, 0), (SoundKind.alarm, 1100)]);
    expect(h.alarm.playing, isTrue);
    expect(h.end.playing, isFalse);
    expect(h.alarm.calls.where((call) => call.$1 == 'source'), hasLength(1));
  });

  for (final operation in ['source', 'seek', 'resume']) {
    _nativeTest(
      'cancel during $operation cleans up before the new plan starts',
      (h) async {
        if (operation != 'source') await h.backend.initialize();
        final pending = Completer<void>();
        h.alarm.respond = (method) =>
            method == operation ? pending.future : null;
        h.schedule([const SoundEvent(SoundKind.alarm, 0, 49)]);
        await h.pump();
        h.backend.cancel();
        await h.pump();
        expect(
          h.alarm.calls.where((call) => call.$1 == 'stop'),
          hasLength(operation == 'resume' ? 1 : 0),
        );
        h.clock.nowMs = 100;
        h.schedule([const SoundEvent(SoundKind.alarm, 100, 149)]);
        h.alarm.respond = (_) {};
        pending.complete();
        await h.pump();
        await h.pump();
        expect(h.starts.last, (SoundKind.alarm, 100));
        expect(h.starts.length, operation == 'resume' ? 2 : 1);
        expect(h.alarm.playing, isTrue);
        expect(
          h.alarm.calls.where((call) => call.$1 == 'stop'),
          hasLength(operation == 'resume' ? 2 : 0),
        );
        expect(h.alarm.calls.last.$1, 'resume');
      },
    );
  }

  for (final kind in SoundKind.values) {
    for (final alreadyAudible in [false, true]) {
      _nativeTest(
        'cancel stops pending $kind before and after reply (audible=$alreadyAudible)',
        (h) async {
          await h.backend.initialize();
          final player = kind == SoundKind.alarm ? h.alarm : h.end;
          final pending = Completer<void>();
          player.respond = (method) =>
              method == 'resume' ? pending.future : null;
          h.schedule([
            SoundEvent(kind, 0, kind == SoundKind.alarm ? 49 : null),
          ]);
          await h.pump();
          if (alreadyAudible) player.state = PlayerState.playing;
          h.backend.cancel();
          await h.pump();
          expect(player.calls.where((call) => call.$1 == 'stop'), hasLength(1));
          expect(player.playing, isFalse);
          h.clock.nowMs = 1000;
          pending.complete();
          await h.pump();
          expect(h.starts, [(kind, 1000)]);
          expect(player.calls.where((call) => call.$1 == 'stop'), hasLength(2));
          expect(player.calls.last.$1, 'stop');
          expect(player.playing, isFalse);
        },
      );
    }
  }

  _nativeTest('alarms already late at their first due check never start', (
    h,
  ) async {
    await h.backend.initialize();
    h.clock.nowMs = 50;
    h.schedule(const [SoundEvent(SoundKind.alarm, 0, 49)]);
    await h.pump();
    expect(h.starts, isEmpty);
    expect(h.alarm.calls.where((call) => call.$1 == 'seek'), isEmpty);
  });

  _nativeTest(
    'an obsolete resume gets a fresh stop while cancellation stop is pending',
    (h) async {
      await h.backend.initialize();
      final resume = Completer<void>();
      final stop = Completer<void>();
      var stops = 0;
      h.alarm.respond = (method) => switch (method) {
        'resume' => resume.future,
        'stop' => ++stops == 1 ? stop.future : null,
        _ => null,
      };
      h.schedule(const [SoundEvent(SoundKind.alarm, 0, 49)]);
      await h.pump();
      h.backend.cancel();
      await h.pump();
      expect(h.alarm.calls.where((call) => call.$1 == 'stop'), hasLength(1));
      h.clock.nowMs = 100;
      h.schedule(const [SoundEvent(SoundKind.end, 100, null)]);
      resume.complete();
      await h.pump();
      await h.pump();
      expect(h.alarm.calls.where((call) => call.$1 == 'stop'), hasLength(2));
      expect(h.end.attempts, isEmpty);
      expect(h.alarm.playing, isFalse);
      stop.complete();
      await h.pump();
      await h.pump();
      expect(h.alarm.playing, isFalse);
      expect(h.end.playing, isTrue);
      expect(h.starts, [(SoundKind.alarm, 100), (SoundKind.end, 100)]);
    },
  );

  for (final kind in SoundKind.values) {
    _nativeTest(
      'a delayed cancellation stop settles before the newer $kind cue',
      (h) async {
        h.schedule(const [SoundEvent(SoundKind.alarm, 0, 49)]);
        await h.pump();
        final pending = Completer<void>();
        h.alarm.respond = (method) => method == 'stop' ? pending.future : null;
        h.backend.cancel();
        h.clock.nowMs = 100;
        h.schedule([
          SoundEvent(kind, 100, kind == SoundKind.alarm ? 149 : null),
        ]);
        await h.pump();
        expect(h.starts, hasLength(1));
        h.alarm.respond = (_) {};
        pending.complete();
        await h.pump();
        expect(h.starts, [(SoundKind.alarm, 0), (kind, 100)]);
        expect((kind == SoundKind.alarm ? h.alarm : h.end).playing, isTrue);
      },
    );
  }

  _nativeTest(
    'duplicate scheduling retains an alarm awaiting its start reply',
    (h) async {
      final pending = Completer<void>();
      h.alarm.respond = (method) => method == 'resume' ? pending.future : null;
      const event = SoundEvent(SoundKind.alarm, 0, 49);
      h.schedule([event]);
      await h.pump();
      h.schedule([event]);
      await h.pump();
      expect(h.alarm.attempts, [0]);
      pending.complete();
      await h.pump();
      h.schedule([event]);
      await h.pump();
      expect(h.alarm.attempts, [0]);
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
    expect(h.starts, isEmpty);
    await h.pump(1000);
    expect(h.starts, [(SoundKind.end, 10000)]);
  });

  _nativeTest(
    'a delayed successful reply retains the planned guard through a bounded wake',
    (h) async {
      final pending = Completer<void>();
      h.alarm.respond = (method) => method == 'resume' ? pending.future : null;
      const first = SoundEvent(SoundKind.alarm, 0, 49);
      h.schedule(const [first, SoundEvent(SoundKind.alarm, 2999, 3048)]);
      await h.pump();
      await h.pump(1000);
      h.schedule([first]);
      await h.pump();
      expect(h.alarm.attempts, [0]);
      pending.complete();
      await h.pump();
      expect(h.alarm.playing, isTrue);
      expect(h.alarm.calls.last.$1, 'resume');
      h.alarm.respond = (_) {};
      await h.pump(1999);
      expect(h.starts, [(SoundKind.alarm, 1000)]);
    },
  );

  for (final at in [0, 60000]) {
    _nativeTest('finish at $at starts exactly one continuous tripled buffer', (
      h,
    ) async {
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
      expect(h.starts, [(SoundKind.end, at)]);
      final bytes = (h.end.source as BytesSource).bytes;
      expect(
        ByteData.sublistView(bytes).getUint32(40, Endian.little),
        207364 * 3,
      );
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
    expect(h.end.playing, isTrue);
    await h.complete();
    await h.complete();
    await h.pump(100);
    expect(h.starts.map((start) => start.$1), [SoundKind.end]);
  });

  _nativeTest('a new cue replaces the playing finish buffer', (h) async {
    h.schedule([const SoundEvent(SoundKind.end, 0, null)]);
    await h.pump();
    h.backend.cancel();
    h.schedule([const SoundEvent(SoundKind.alarm, 100, 149)]);
    await h.pump(100);
    await h.complete();
    expect(h.starts, [(SoundKind.end, 0), (SoundKind.alarm, 100)]);
  });

  _nativeTest(
    'failed finish waits for rescheduling, then stamps one successful buffer',
    (h) async {
      h.end.respond = (method) {
        if (method == 'resume') throw StateError('unavailable');
      };
      const event = SoundEvent(SoundKind.end, 0, null);
      h.schedule([event]);
      await h.pump();
      await h.pump(10000);
      expect(h.end.attempts, [0]);
      h.end.respond = (_) {};
      h.schedule([event]);
      await h.pump();
      await h.complete();
      await h.complete();
      h.schedule([event]);
      await h.pump();
      expect(h.starts, [(SoundKind.end, 10000)]);
    },
  );

  _nativeTest('squared gain updates a playing finish', (h) async {
    h.schedule([const SoundEvent(SoundKind.end, 0, null)]);
    await h.pump();
    h.end.calls.clear();
    for (final percent in [0, 25, 50, 100]) {
      h.backend.setVolume(percent);
      await h.pump();
    }
    expect(
      h.end.calls.where((call) => call.$1 == 'volume').map((call) => call.$2),
      [0.0, 0.0625, 0.25, 1.0],
    );
    expect(h.end.playing, isTrue);
    expect(h.starts, hasLength(1));
  });

  _nativeTest(
    'volume changes coalesce to the latest gain with one call per player in flight',
    (h) async {
      await h.backend.initialize();
      final first = Completer<void>();
      final active = <FakeAudioPlayer, int>{};
      final maximumActive = <FakeAudioPlayer, int>{};
      for (final player in h.players) {
        player.calls.clear();
        active[player] = 0;
        maximumActive[player] = 0;
        player.respond = (method) async {
          if (method != 'volume') return;
          active[player] = active[player]! + 1;
          if (active[player]! > maximumActive[player]!) {
            maximumActive[player] = active[player]!;
          }
          await first.future;
          active[player] = active[player]! - 1;
        };
      }
      h.backend.setVolume(25);
      h.backend.setVolume(50);
      h.backend.setVolume(75);
      h.backend.setVolume(100);
      await h.pump();
      for (final player in h.players) {
        expect(
          player.calls
              .where((call) => call.$1 == 'volume')
              .map((call) => call.$2),
          [0.0625],
        );
      }
      first.complete();
      await h.pump();
      for (final player in h.players) {
        expect(
          player.calls
              .where((call) => call.$1 == 'volume')
              .map((call) => call.$2),
          [0.0625, 1],
        );
      }
      h.backend.setVolume(100);
      await h.pump();
      for (final player in h.players) {
        expect(player.calls.where((call) => call.$1 == 'volume'), hasLength(2));
        expect(maximumActive[player], 1);
      }
    },
  );

  _nativeTest(
    'volume can change while resume is pending without restarting a cue',
    (h) async {
      await h.backend.initialize();
      final pending = Completer<void>();
      h.alarm.respond = (method) => method == 'resume' ? pending.future : null;
      h.schedule(const [SoundEvent(SoundKind.alarm, 0, 49)]);
      await h.pump();
      h.backend.setVolume(50);
      await h.pump();
      for (final player in h.players) {
        expect(player.volume, 0.25);
      }
      pending.complete();
      await h.pump();
      expect(h.starts, [(SoundKind.alarm, 0)]);
      expect(h.alarm.playing, isTrue);
    },
  );

  _nativeTest(
    'initialization applies only the latest previously requested gain to both players',
    (h) async {
      h.backend.setVolume(25);
      h.backend.setVolume(50);
      h.backend.setVolume(75);
      await h.backend.initialize();
      for (final player in h.players) {
        expect(
          player.calls
              .where((call) => call.$1 == 'volume')
              .map((call) => call.$2),
          [0.5625],
        );
      }
    },
  );

  _nativeTest('idle cancellation and completed playback do not call stop', (
    h,
  ) async {
    await h.backend.initialize();
    h.backend.cancel();
    await h.pump();
    h.schedule(const [SoundEvent(SoundKind.alarm, 0, 49)]);
    await h.pump();
    await h.complete();
    h.backend.cancel();
    h.schedule(const [SoundEvent(SoundKind.end, 100, null)]);
    await h.pump(100);
    expect(h.alarm.calls.where((call) => call.$1 == 'stop'), isEmpty);
  });

  _nativeTest('cancel stops an alarm but never disposes the player', (h) async {
    h.schedule([const SoundEvent(SoundKind.alarm, 0, 49)]);
    await h.pump();
    h.backend.cancel();
    await h.pump();
    expect(h.alarm.playing, isFalse);
    h.schedule(const [
      SoundEvent(SoundKind.end, 0, null),
      SoundEvent(SoundKind.alarm, 1000, 1049),
    ]);
    await h.pump();
    expect(h.end.playing, isTrue);
    h.backend.cancel();
    h.backend.cancel();
    await h.pump(1000);
    expect(h.end.playing, isTrue);
    expect(h.alarm.calls.where((call) => call.$1 == 'dispose'), isEmpty);
    expect(h.starts, hasLength(2));
  });
}
