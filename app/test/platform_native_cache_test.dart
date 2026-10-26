import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:easytimer/audio.dart';
import 'package:easytimer/platform/timer_platform_native.dart';
import 'package:easytimer/timer_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

class _FilePlayer extends FakeAudioPlayer {
  _FilePlayer(super.clock);

  final firstRead = Completer<void>();
  final decoded = <Uint8List>[];
  Uint8List? _expected;

  @override
  Future<void> setSource(Source source) async {
    _expected = (source as BytesSource).bytes;
    await super.setSource(source);
    await source.setOnPlayer(this);
  }

  @override
  Future<void> setSourceDeviceFile(String path, {String? mimeType}) async {
    final bytes = await File(path).readAsBytes();
    decoded.add(bytes);
    if (!firstRead.isCompleted) firstRead.complete();
    if (!listEquals(bytes, _expected)) {
      throw const FormatException('partial WAV');
    }
    await super.setSourceDeviceFile(path, mimeType: mimeType);
  }

  @override
  Future<void> seek(Duration position) async {
    final bytes = await File((source as DeviceFileSource).path).readAsBytes();
    if (!listEquals(bytes, _expected)) {
      throw const FormatException('partial WAV');
    }
    await super.seek(position);
  }
}

class _ControlledFile implements File {
  _ControlledFile(this.file, {this.write, this.beforeRename});

  final File file;
  final Future<void> Function(File, List<int>, FileMode, bool)? write;
  final Future<void> Function()? beforeRename;

  @override
  String get path => file.path;
  @override
  Directory get parent => file.parent;
  @override
  Future<bool> exists() => file.exists();
  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();
  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) =>
      file.create(recursive: recursive, exclusive: exclusive);
  @override
  Future<File> delete({bool recursive = false}) async {
    await file.delete(recursive: recursive);
    return this;
  }

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    if (write == null) {
      await file.writeAsBytes(bytes, mode: mode, flush: flush);
    } else {
      await write!(file, bytes, mode, flush);
    }
    return this;
  }

  @override
  Future<File> rename(String newPath) async {
    await beforeRename?.call();
    return file.rename(newPath);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory cache;

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('native-audio-');
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getApplicationCacheDirectory');
      return cache.path;
    });
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
    await cache.delete(recursive: true);
  });

  (PlatformBackend, _FilePlayer, _FilePlayer) backend(FakeClock clock) {
    final alarm = _FilePlayer(clock);
    final end = _FilePlayer(clock);
    final backend = PlatformBackend(clock, alarmPlayer: alarm, endPlayer: end);
    addTearDown(() async {
      backend.cancel();
      await Future<void>.delayed(Duration.zero);
      await alarm.dispose();
      await end.dispose();
    });
    return (backend, alarm, end);
  }

  Future<void> checkCache() async {
    final paths = await cache
        .list(recursive: true)
        .map((entry) => entry.path)
        .toList();
    expect(
      paths,
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
  }

  test(
    'Linux cache reuses exactly two fixed files across backend instances',
    () async {
      for (var instance = 0; instance < 3; instance++) {
        final (native, alarm, end) = backend(FakeClock());
        await native.initialize();
        expect(
          (alarm.source as DeviceFileSource).path,
          '${cache.path}/audio/alarm.wav',
        );
        expect(
          (end.source as DeviceFileSource).path,
          '${cache.path}/audio/end.wav',
        );
        await checkCache();
      }
    },
  );

  for (final existing in [false, true]) {
    test(
      'concurrent cache publishers expose complete WAVs (existing=$existing)',
      () async {
        final alarmPath = '${cache.path}/audio/alarm.wav';
        if (existing) {
          await Directory('${cache.path}/audio').create();
          await File(alarmPath).writeAsBytes([0, 1]);
        }
        final secondTruncated = Completer<void>();
        final finishSecond = Completer<void>();
        final writes = <String>[];
        final rootZone = Zone.current;
        final (first, firstAlarm, _) = backend(FakeClock());
        final (second, secondAlarm, _) = backend(FakeClock());
        await IOOverrides.runZoned(
          () async {
            final preparations = [first.initialize(), second.initialize()];
            try {
              await secondTruncated.future;
              await Future.any([
                firstAlarm.firstRead.future,
                secondAlarm.firstRead.future,
              ]);
              expect(
                [...firstAlarm.decoded, ...secondAlarm.decoded],
                [await loadSound(SoundKind.alarm)],
              );
              expect(
                await File(alarmPath).readAsBytes(),
                await loadSound(SoundKind.alarm),
              );
              expect(writes.toSet(), hasLength(2));
              expect(writes, everyElement(isNot(alarmPath)));
              expect(
                writes.map((path) => File(path).parent.path),
                everyElement('${cache.path}/audio'),
              );
            } finally {
              finishSecond.complete();
              await Future.wait(preparations);
            }
          },
          createFile: (path) {
            final real = rootZone.run(() => File(path));
            if (!path.contains('/alarm.wav')) return real;
            return _ControlledFile(
              real,
              write: (file, bytes, mode, flush) async {
                expect(flush, isTrue);
                writes.add(file.path);
                if (writes.length == 1) {
                  await file.writeAsBytes(bytes, mode: mode, flush: flush);
                  await secondTruncated.future;
                } else {
                  final output = await file.open(mode: mode);
                  try {
                    secondTruncated.complete();
                    await finishSecond.future;
                    await output.writeFrom(bytes);
                    await output.flush();
                  } finally {
                    await output.close();
                  }
                }
              },
            );
          },
        );
        expect(firstAlarm.decoded.single, await loadSound(SoundKind.alarm));
        expect(secondAlarm.decoded.single, await loadSound(SoundKind.alarm));
        await checkCache();
      },
    );
  }

  for (final failure in ['write', 'rename']) {
    test(
      'failed atomic $failure cleans its temporary file and preserves the target',
      () async {
        final audio = await Directory('${cache.path}/audio').create();
        final target = File('${audio.path}/alarm.wav');
        await target.writeAsBytes([1, 2, 3]);
        final (native, alarm, end) = backend(FakeClock());
        final rootZone = Zone.current;
        await IOOverrides.runZoned(
          () async {
            await native.initialize();
          },
          createFile: (path) {
            final real = rootZone.run(() => File(path));
            if (!path.endsWith('.tmp')) return real;
            return _ControlledFile(
              real,
              write: failure == 'write'
                  ? (file, bytes, mode, flush) async {
                      await file.writeAsBytes(
                        bytes.take(8).toList(),
                        mode: mode,
                        flush: flush,
                      );
                      throw FileSystemException('injected write failure', path);
                    }
                  : null,
              beforeRename: failure == 'rename'
                  ? () async {
                      throw FileSystemException(
                        'injected rename failure',
                        path,
                      );
                    }
                  : null,
            );
          },
        );
        expect(await target.readAsBytes(), [1, 2, 3]);
        expect(await audio.list().map((entry) => entry.path).toList(), [
          target.path,
        ]);
        await native.initialize();
        expect(alarm.source, isA<DeviceFileSource>());
        expect(end.source, isA<DeviceFileSource>());
        await checkCache();
      },
    );
  }

  for (final wholeDirectory in [false, true]) {
    test(
      'cache eviction is repaired on use without resetting sources (directory=$wholeDirectory)',
      () async {
        final clock = FakeClock();
        final (native, alarm, end) = backend(clock);
        await native.initialize();
        for (var round = 0; round < 2; round++) {
          for (final kind in SoundKind.values) {
            native.cancel();
            final file = File('${cache.path}/audio/${kind.name}.wav');
            if (wholeDirectory) {
              await Directory('${cache.path}/audio').delete(recursive: true);
            } else if (await file.exists()) {
              await file.delete();
            }
            final player = kind == SoundKind.alarm ? alarm : end;
            final resumed = Completer<void>();
            player.respond = (method) {
              if (method == 'resume' && !resumed.isCompleted) {
                resumed.complete();
              }
            };
            native.schedule([SoundEvent(kind, clock.nowMs, null)]);
            await resumed.future;
            await Future<void>.delayed(Duration.zero);
            expect(player.playing, isTrue);
            expect(await file.readAsBytes(), await loadSound(kind));
            for (final prepared in [alarm, end]) {
              expect(
                prepared.calls.where((call) => call.$1 == 'source'),
                hasLength(1),
              );
              expect(
                prepared.calls.where((call) => call.$1 == 'file'),
                hasLength(1),
              );
            }
          }
        }
      },
    );
  }
}
