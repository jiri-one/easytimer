import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:easytimer/platform/timer_platform.dart';
import 'package:easytimer/settings.dart';
import 'package:easytimer/timer_engine.dart';
import 'package:easytimer/workout_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const fontAsset = 'assets/fonts/DroidSansMono.ttf';

class FakeClock implements MonotonicClock {
  FakeClock([this._nowMs = 0]);

  int _nowMs;
  int reads = 0;

  @override
  int get nowMs {
    reads++;
    return _nowMs;
  }

  set nowMs(int value) => _nowMs = value;
}

class RecordingPreferences implements SharedPreferences {
  RecordingPreferences([Map<String, Object> initial = const {}])
    : values = {...initial};

  final Map<String, Object> values;
  final writes = <(String, int)>[];
  bool failWrites = false;

  @override
  Object? get(String key) => values[key];

  @override
  Future<bool> setInt(String key, int value) async {
    if (failWrites) throw StateError('Storage unavailable');
    writes.add((key, value));
    values[key] = value;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> advanceClock(
  WidgetTester tester,
  FakeClock clock,
  int milliseconds,
) async {
  clock.nowMs += milliseconds;
  await tester.pump(Duration(milliseconds: milliseconds));
}

Future<void> loadAppFont() =>
    (FontLoader('Roboto')..addFont(rootBundle.load(fontAsset))).load();

Future<WorkoutController> createTestController(
  WidgetTester tester, {
  Map<String, Object> preferences = const {},
  FakeClock? clock,
  RecordingTimerPlatform? platform,
}) async {
  SharedPreferences.setMockInitialValues(preferences);
  final recording = platform ?? RecordingTimerPlatform();
  final controller = WorkoutController(
    await TimerSettings.load(loader: SharedPreferences.getInstance),
    recording,
    clock: clock ?? FakeClock(),
    keepAwake: recording.keepAwake,
  );
  addTearDown(tester.view.reset);
  addTearDown(controller.dispose);
  return controller;
}

class RecordedSchedule {
  RecordedSchedule(List<SoundEvent> events)
    : events = List.unmodifiable(events);

  final List<SoundEvent> events;
}

class RecordingTimerPlatform extends TimerPlatform {
  final calls = <String>[];
  final schedules = <RecordedSchedule>[];
  final volumes = <int>[];
  final awake = <bool>[];
  int cancellations = 0;

  @override
  Future<void> initialize() async => calls.add('initialize');

  @override
  void schedule(List<SoundEvent> events) {
    calls.add('schedule');
    schedules.add(RecordedSchedule(events));
  }

  @override
  void cancel() {
    calls.add('cancel');
    cancellations++;
  }

  @override
  void setVolume(int percent) {
    calls.add('setVolume');
    volumes.add(percent);
  }

  void keepAwake(bool enabled) {
    calls.add('keepAwake');
    awake.add(enabled);
  }
}

class FakeAudioPlayer implements AudioPlayer {
  FakeAudioPlayer(this.clock, {List<(SoundKind, int)>? starts, this.onStart})
    : starts = starts ?? [];

  final FakeClock clock;
  final calls = <(String, Object?)>[];
  final List<(SoundKind, int)> starts;
  final attempts = <int>[];
  final _completions = StreamController<void>.broadcast();
  final void Function()? onStart;
  Duration position = Duration.zero;
  FutureOr<void> Function(String) respond = (_) {};
  @override
  Source? source;
  @override
  PlayerState state = PlayerState.stopped;
  @override
  double volume = 1;
  @override
  Stream<void> get onPlayerComplete => _completions.stream;

  bool get playing => state == PlayerState.playing;

  void complete() {
    state = PlayerState.completed;
    position = const Duration(seconds: 30);
    _completions.add(null);
  }

  SoundKind get currentKind {
    final value = source;
    if (value is BytesSource) {
      return ByteData.sublistView(value.bytes).getUint16(22, Endian.little) == 1
          ? SoundKind.alarm
          : SoundKind.end;
    }
    return (value as DeviceFileSource).path.endsWith('/end.wav')
        ? SoundKind.end
        : SoundKind.alarm;
  }

  Future<void> _call(String method, [Object? value]) async {
    calls.add((method, value));
    await respond(method);
  }

  @override
  Future<void> setPlayerMode(PlayerMode mode) => _call('mode', mode);
  @override
  Future<void> setReleaseMode(ReleaseMode mode) => _call('release', mode);
  @override
  Future<void> setAudioContext(AudioContext context) =>
      _call('context', context);
  @override
  Future<void> setSource(Source source) async {
    this.source = source;
    await _call('source', source);
  }

  @override
  Future<void> setSourceBytes(Uint8List bytes, {String? mimeType}) =>
      setSource(BytesSource(bytes, mimeType: mimeType));

  @override
  Future<void> setSourceDeviceFile(String path, {String? mimeType}) async {
    source = DeviceFileSource(path, mimeType: mimeType);
    await _call('file', path);
  }

  @override
  Future<void> seek(Duration position) async {
    await _call('seek', position);
    this.position = position;
  }

  @override
  Future<void> resume() async {
    attempts.add(clock.nowMs);
    await _call('resume');
    starts.add((currentKind, clock.nowMs));
    state = PlayerState.playing;
    onStart?.call();
  }

  @override
  Future<void> pause() async {
    await _call('pause');
    state = PlayerState.paused;
  }

  @override
  Future<void> stop() async {
    await _call('stop');
    state = PlayerState.stopped;
  }

  @override
  Future<void> setVolume(double volume) async {
    this.volume = volume;
    await _call('volume', volume);
  }

  @override
  Future<void> dispose() async {
    await _call('dispose');
    state = PlayerState.disposed;
    source = null;
    await _completions.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
