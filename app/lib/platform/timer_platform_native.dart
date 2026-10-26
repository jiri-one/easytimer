import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../audio.dart';
import '../cue_policy.dart';
import '../timer_engine.dart';
import 'timer_platform.dart';

class _CachedBytesSource extends BytesSource {
  _CachedBytesSource(this.kind, super.bytes) : super(mimeType: 'audio/wav');

  final SoundKind kind;
  Future<void>? _preparation;
  String? _path;

  Future<void> _prepare() async {
    final cache = await getApplicationCacheDirectory();
    final directory = await Directory('${cache.path}/audio')
        .create(recursive: true);
    final file = File('${directory.path}/${kind.name}.wav');
    if (!await file.exists() || !listEquals(await file.readAsBytes(), bytes)) {
      await file.writeAsBytes(bytes, flush: true);
    }
    _path = file.path;
  }

  @override
  Future<void> setOnPlayer(AudioPlayer player) async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
      // The plugin's process-randomized byte hash leaves a new file each launch.
      try {
        await (_preparation ??= _prepare());
      } catch (_) {
        _preparation = null;
        rethrow;
      }
      await player.setSourceDeviceFile(_path!, mimeType: mimeType);
    } else {
      await super.setOnPlayer(player);
    }
  }

  bool matches(Source? source) =>
      source is BytesSource && identical(source.bytes, bytes) ||
      source is DeviceFileSource && source.path == _path;
}

class PlatformBackend extends TimerPlatform {
  PlatformBackend(this._clock, {AudioPlayer? player})
    : _player = player ?? (AudioPlayer()..positionUpdater = null);

  final MonotonicClock _clock;
  final AudioPlayer _player;
  final _policy = CuePolicy();
  final _sources = <SoundKind, _CachedBytesSource>{};
  Future<void> _operations = Future.value();
  Future<void>? _initialization;
  Future<void>? _volumeUpdate;
  Timer? _timer;
  SoundEvent? _inFlight;
  int _revision = 0;
  double _gain = 1;
  bool _initialized = false;

  Future<void> _serial(Future<void> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.catchError((Object _) {});
    return result;
  }

  @override
  Future<void> initialize() => _initialization ??=
      _serial(() async {
        if (_sources.isEmpty) {
          final bytes = await Future.wait(SoundKind.values.map(loadSound));
          for (final kind in SoundKind.values) {
            _sources[kind] = _CachedBytesSource(kind, bytes[kind.index]);
          }
        }
        // SoundPool does not report reliable completion, so player state goes stale.
        await _player.setPlayerMode(PlayerMode.mediaPlayer);
        await _player.setReleaseMode(ReleaseMode.stop);
        await _player.setAudioContext(
          AudioContext(
            android: const AudioContextAndroid(
              usageType: AndroidUsageType.media,
              contentType: AndroidContentType.sonification,
              audioFocus: AndroidAudioFocus.none,
            ),
          ),
        );
        await _player.setSource(_sources[SoundKind.alarm]!);
        await _applyVolume();
        _initialized = true;
      }).catchError((Object _) {
        _initialization = null;
      });

  @override
  void schedule(List<SoundEvent> events) {
    final now = _clock.nowMs;
    if (_policy.merge(events)) _wake(now);
  }

  void _wake(int now) {
    final plan = _policy.due(now, inFlight: _inFlight?.id);
    if (_inFlight == null && plan.isNotEmpty && plan.first.atMs <= now) {
      unawaited(_start(plan.first, _revision));
    }
    _arm(plan, now);
  }

  void _arm(List<SoundEvent> plan, int now, [int minimumDelay = 0]) {
    _timer?.cancel();
    _timer = null;
    if (plan.isEmpty) return;
    final firstAt = plan.map((event) => event.atMs).reduce(math.min);
    // Re-read BOOTTIME after suspend instead of trusting a long Dart timer.
    final delay = _inFlight == null
        ? (firstAt - now).clamp(minimumDelay, 1000)
        : 1000;
    _timer = Timer(Duration(milliseconds: delay), () => _wake(_clock.nowMs));
  }

  Future<void> _start(SoundEvent event, int revision) async {
    _inFlight = event;
    bool current() => revision == _revision;
    bool valid() => current() && !_policy.expired(event, _clock.nowMs);
    try {
      await initialize();
      if (!_initialized || !current()) return;
      await _serial(() async {
        if (!valid()) return;
        if (_player.state == PlayerState.playing) await _player.stop();
        if (!current()) return;
        await _player.setSource(_sources[event.kind]!);
        // Loading can outlive an alarm's window or a cancelled plan.
        if (!valid()) return;
        await _player.resume();
        if (current()) _policy.started(event);
      });
    } catch (_) {
      // A failed alarm remains eligible until its original deadline.
    } finally {
      if (current()) _policy.failed(event);
      _inFlight = null;
      final now = _clock.nowMs;
      final delay = current() && event.kind.retries && !_policy.handled(event)
          ? 10
          : 0;
      _arm(_policy.due(now), now, delay);
    }
  }

  @override
  void cancel() {
    _revision++;
    _timer?.cancel();
    _timer = null;
    _policy.reset();
    unawaited(
      _serial(() async {
        if (_player.state != PlayerState.playing) return;
        final keep = _sources.entries.any(
          (entry) =>
              entry.key.keepsOnCancel && entry.value.matches(_player.source),
        );
        if (!keep) await _player.stop();
      }).catchError((Object _) {}),
    );
  }

  Future<void> _applyVolume() => _volumeUpdate ??= () async {
    double sent;
    do {
      sent = _gain;
      await _player.setVolume(sent);
    } while (sent != _gain);
  }().whenComplete(() => _volumeUpdate = null);

  @override
  void setVolume(int percent) {
    final gain = gainOf(percent);
    if (gain == _gain) return;
    _gain = gain;
    if (_initialized) {
      unawaited(_applyVolume().catchError((Object _) {}));
    }
  }
}
