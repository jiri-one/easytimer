import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:easytimer/audio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:easytimer/platform/timer_platform_native.dart';
import 'package:easytimer/timer_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

class _FilePlayer extends FakeAudioPlayer {
  _FilePlayer(super.clock);

  @override
  Future<void> setSource(Source source) async {
    await super.setSource(source);
    await source.setOnPlayer(this);
  }
}

class _Harness {
  _Harness(this.tester);

  final WidgetTester tester;
  final clock = FakeClock();
  late final player = FakeAudioPlayer(clock);
  late final backend = PlatformBackend(clock, player: player);

  Future<void> pump([int milliseconds = 0]) =>
      advanceClock(tester, clock, milliseconds);

  void schedule(List<SoundEvent> events) => backend.schedule(events);

  Future<void> complete() async {
    player.state = PlayerState.completed;
    await pump();
  }
}

void _nativeTest(String name, Future<void> Function(_Harness) body) {
  testWidgets(name, (tester) async {
    final h = _Harness(tester);
    try {
      await body(h);
    } finally {
      h.backend.cancel();
      await tester.pump();
      await h.player.dispose();
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
    h.player.respond = (method) => method == 'source' ? loading.future : null;
    final first = h.backend.initialize();
    expect(identical(first, h.backend.initialize()), isTrue);
    h.schedule([const SoundEvent(SoundKind.alarm, 0, 49)]);
    await h.pump();
    expect(h.player.starts, isEmpty);
    loading.complete();
    await h.pump();
    expect(h.player.starts, [(SoundKind.alarm, 0)]);
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
    expect(h.player.starts, [(SoundKind.alarm, 2000), (SoundKind.alarm, 5000)]);
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

  _nativeTest('preloaded source objects are reused without reloading assets', (
    h,
  ) async {
    await h.backend.initialize();
    final alarm = h.player.source;
    expect(alarm, isA<BytesSource>());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
          'flutter/assets',
          (_) async => throw StateError('already preloaded'),
        );
    h.schedule(const [SoundEvent(SoundKind.end, 0, null)]);
    await h.pump();
    final end = h.player.source;
    expect(end, isA<BytesSource>());
    h.backend.cancel();
    h.schedule(const [SoundEvent(SoundKind.alarm, 100, 149)]);
    await h.pump(100);
    expect(identical(h.player.source, alarm), isTrue);
    h.backend.cancel();
    h.schedule(const [SoundEvent(SoundKind.end, 100, null)]);
    await h.pump();
    expect(identical(h.player.source, end), isTrue);
    expect(h.player.starts.map((start) => start.$1), [
      SoundKind.end,
      SoundKind.alarm,
      SoundKind.end,
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
      expect(h.player.starts, [(SoundKind.alarm, 10)]);
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

  _nativeTest(
    'replacement retries a failed stop without dropping the next cue',
    (h) async {
      h.schedule(const [SoundEvent(SoundKind.end, 0, null)]);
      await h.pump();
      var failed = false;
      h.player.respond = (method) {
        if (method == 'stop' && !failed) {
          failed = true;
          throw StateError('unavailable');
        }
      };
      h.schedule(const [SoundEvent(SoundKind.alarm, 100, 149)]);
      await h.pump(100);
      expect(h.player.starts, [(SoundKind.end, 0)]);
      await h.pump(10);
      expect(h.player.starts, [(SoundKind.end, 0), (SoundKind.alarm, 110)]);
    },
  );

  _nativeTest('a failed reservation leaves the nearby future alarm available', (
    h,
  ) async {
    h.player.respond = (method) {
      if (method == 'resume') throw StateError('unavailable');
    };
    h.schedule(const [
      SoundEvent(SoundKind.alarm, 0, 49),
      SoundEvent(SoundKind.alarm, 2999, 3048),
    ]);
    await h.pump();
    await h.pump(50);
    h.player.respond = (_) {};
    await h.pump(2949);
    expect(h.player.starts, [(SoundKind.alarm, 2999)]);
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
    expect(h.player.starts, [(SoundKind.end, 10000)]);
  });

  _nativeTest('an expired in-flight start survives the bounded timer wake', (
    h,
  ) async {
    final pending = Completer<void>();
    h.player.respond = (method) => method == 'resume' ? pending.future : null;
    const first = SoundEvent(SoundKind.alarm, 0, 49);
    h.schedule(const [first, SoundEvent(SoundKind.alarm, 2999, 3048)]);
    await h.pump();
    await h.pump(1000);
    h.schedule([first]);
    await h.pump();
    expect(h.player.attempts, [0]);
    pending.complete();
    await h.pump();
    h.player.respond = (_) {};
    await h.pump(1999);
    expect(h.player.starts, [(SoundKind.alarm, 1000)]);
  });

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
      expect(h.player.starts, [(SoundKind.end, at)]);
      final bytes = (h.player.source as BytesSource).bytes;
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
    expect(h.player.playing, isTrue);
    await h.complete();
    await h.complete();
    await h.pump(100);
    expect(h.player.starts.map((start) => start.$1), [SoundKind.end]);
  });

  _nativeTest('a new cue replaces the playing finish buffer', (h) async {
    h.schedule([const SoundEvent(SoundKind.end, 0, null)]);
    await h.pump();
    h.backend.cancel();
    h.schedule([const SoundEvent(SoundKind.alarm, 100, 149)]);
    await h.pump(100);
    await h.complete();
    expect(h.player.starts, [(SoundKind.end, 0), (SoundKind.alarm, 100)]);
  });

  _nativeTest(
    'failed finish waits for rescheduling, then stamps one successful buffer',
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
      expect(h.player.starts, [(SoundKind.end, 10000)]);
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
    'volume changes coalesce to the latest gain with one call in flight',
    (h) async {
      await h.backend.initialize();
      h.player.calls.clear();
      final first = Completer<void>();
      var active = 0;
      var maximumActive = 0;
      h.player.respond = (method) async {
        if (method != 'volume') return;
        active++;
        if (active > maximumActive) maximumActive = active;
        await first.future;
        active--;
      };
      h.backend.setVolume(25);
      h.backend.setVolume(50);
      h.backend.setVolume(75);
      h.backend.setVolume(100);
      await h.pump();
      expect(
        h.player.calls
            .where((call) => call.$1 == 'volume')
            .map((call) => call.$2),
        [0.0625],
      );
      first.complete();
      await h.pump();
      expect(
        h.player.calls
            .where((call) => call.$1 == 'volume')
            .map((call) => call.$2),
        [0.0625, 1],
      );
      expect(maximumActive, 1);
      h.backend.setVolume(100);
      await h.pump();
      expect(h.player.calls.where((call) => call.$1 == 'volume'), hasLength(2));
    },
  );

  _nativeTest(
    'initialization applies only the latest previously requested gain',
    (h) async {
      h.backend.setVolume(25);
      h.backend.setVolume(50);
      h.backend.setVolume(75);
      await h.backend.initialize();
      expect(
        h.player.calls
            .where((call) => call.$1 == 'volume')
            .map((call) => call.$2),
        [0.5625],
      );
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
    expect(h.player.calls.where((call) => call.$1 == 'stop'), isEmpty);
  });

  _nativeTest('cancel stops an alarm but never disposes the player', (h) async {
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
    h.backend.cancel();
    h.backend.cancel();
    await h.pump(1000);
    expect(h.player.playing, isTrue);
    expect(h.player.calls.where((call) => call.$1 == 'dispose'), isEmpty);
    expect(h.player.starts, hasLength(2));
  });

  test(
    'Linux cache reuses exactly two fixed files across backend instances',
    () async {
      final cache = await Directory.systemTemp.createTemp(
        'easytimer-audio-test-',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getApplicationCacheDirectory');
        return cache.path;
      });
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() async {
        debugDefaultTargetPlatformOverride = null;
        messenger.setMockMethodCallHandler(channel, null);
        await cache.delete(recursive: true);
      });

      for (var instance = 0; instance < 3; instance++) {
        final clock = FakeClock();
        final player = _FilePlayer(clock);
        final backend = PlatformBackend(clock, player: player);
        try {
          await backend.initialize();
          expect(
            (player.source as DeviceFileSource).path,
            '${cache.path}/audio/alarm.wav',
          );
          final started = Completer<void>();
          player.respond = (method) {
            if (method == 'resume') started.complete();
          };
          backend.schedule(const [SoundEvent(SoundKind.end, 0, null)]);
          await started.future;
          await Future<void>.delayed(Duration.zero);
          expect(
            (player.source as DeviceFileSource).path,
            '${cache.path}/audio/end.wav',
          );
          backend.cancel();
          await Future<void>.delayed(Duration.zero);
          expect(player.playing, isTrue);
          expect(player.calls.where((call) => call.$1 == 'stop'), isEmpty);
          final entries = await cache
              .list(recursive: true)
              .map((entry) => entry.path)
              .toList();
          expect(
            entries,
            unorderedEquals([
              '${cache.path}/audio',
              '${cache.path}/audio/alarm.wav',
              '${cache.path}/audio/end.wav',
            ]),
          );
          for (final kind in SoundKind.values) {
            expect(
              await File('${cache.path}/audio/${kind.name}.wav').readAsBytes(),
              await loadSound(kind),
            );
          }
        } finally {
          backend.cancel();
          await Future<void>.delayed(Duration.zero);
          await player.dispose();
        }
      }
    },
  );
}
