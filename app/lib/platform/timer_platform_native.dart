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

  Future<void> _prepare() =>
      _preparation ??= _publish().whenComplete(() => _preparation = null);

  Future<void> _publish() async {
    final cache = await getApplicationCacheDirectory();
    final directory = await Directory('${cache.path}/audio')
        .create(recursive: true);
    final file = File('${directory.path}/${kind.name}.wav');
    if (!await file.exists() || !listEquals(await file.readAsBytes(), bytes)) {
      final temporary = File(
        '${file.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.'
        '${math.Random.secure().nextInt(1 << 32)}.tmp',
      );
      await temporary.create(exclusive: true);
      try {
        // Decoders in another process must only see a complete, closed WAV.
        await temporary.writeAsBytes(bytes, flush: true);
        await temporary.rename(file.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    }
    _path = file.path;
  }

  Future<void> ensureAvailable() async {
    if (_path != null && !await File(_path!).exists()) await _prepare();
  }

  @override
  Future<void> setOnPlayer(AudioPlayer player) async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
      // The plugin's process-randomized byte hash leaves a new file each launch.
      await _prepare();
      await player.setSourceDeviceFile(_path!, mimeType: mimeType);
    } else {
      await super.setOnPlayer(player);
    }
  }
}

class PlatformBackend extends TimerPlatform {
  PlatformBackend(
    this._clock, {
    AudioPlayer? alarmPlayer,
    AudioPlayer? endPlayer,
  }) : _players = {
         SoundKind.alarm:
             alarmPlayer ?? (AudioPlayer()..positionUpdater = null),
         SoundKind.end: endPlayer ?? (AudioPlayer()..positionUpdater = null),
       } {
    for (final kind in SoundKind.values) {
      _players[kind]!.onPlayerComplete.listen((_) {
        _rewound.remove(kind);
        unawaited(_rewind(kind).catchError((Object _) {}));
      }, onError: (Object _) => _invalidate(kind));
    }
  }

  final MonotonicClock _clock;
  final Map<SoundKind, AudioPlayer> _players;
  final _policy = CuePolicy();
  final _sources = <SoundKind, _CachedBytesSource>{};
  final _prepared = <SoundKind>{};
  final _primed = <SoundKind>{};
  final _rewound = <SoundKind>{};
  final _rewinds = <SoundKind, Completer<void>>{};
  final _failures = <SoundKind, int>{};
  final _stops = <Future<void>>{};
  Future<void>? _initialization;
  Future<void>? _volumeUpdate;
  Timer? _timer;
  SoundEvent? _inFlight;
  SoundKind? _resuming;
  SoundKind? _playing;
  int _revision = 0;
  int _audioRevision = 0;
  double _gain = 1;
  bool _initialized = false;

  @override
  Future<void> initialize() {
    if (_initialized) return Future.value();
    return _initialization ??= () async {
      final revision = _audioRevision;
      void check() {
        if (revision != _audioRevision) {
          throw StateError('Player preparation invalidated');
        }
      }

      while (_stops.isNotEmpty) {
        await Future.wait(_stops.toList());
        check();
      }
      if (_audioRevision != 0 &&
          defaultTargetPlatform == TargetPlatform.android) {
        for (final entry in _players.entries) {
          if (_prepared.contains(entry.key) &&
              entry.value.state == PlayerState.playing) {
            await _stop(entry.key);
            check();
          }
        }
      }
      // Let an older live gain update finish before muting a recovery prime.
      await _volumeUpdate;
      check();
      if (_sources.isEmpty) {
        final bytes = await Future.wait(SoundKind.values.map(loadSound));
        for (final kind in SoundKind.values) {
          _sources[kind] = _CachedBytesSource(kind, bytes[kind.index]);
        }
      }
      check();
      for (final entry in _players.entries) {
        final player = entry.value;
        if (!_prepared.contains(entry.key)) {
          if (_failures.containsKey(entry.key)) {
            // Native playing can outlive its Dart state after an error.
            await _stop(entry.key);
            check();
          }
          // SoundPool does not report reliable completion, so state goes stale.
          await player.setPlayerMode(PlayerMode.mediaPlayer);
          check();
          await player.setReleaseMode(ReleaseMode.stop);
          check();
          await player.setAudioContext(
            AudioContext(
              android: const AudioContextAndroid(
                usageType: AndroidUsageType.media,
                contentType: AndroidContentType.sonification,
                audioFocus: AndroidAudioFocus.none,
              ),
            ),
          );
          check();
          await player.setSource(_sources[entry.key]!);
          check();
          _prepared.add(entry.key);
        }
        if (defaultTargetPlatform == TargetPlatform.android &&
            !_primed.contains(entry.key)) {
          // Android allocates its AudioTrack on first start; warm it silently.
          await player.setVolume(0);
          check();
          try {
            await player.resume();
          } finally {
            await player.pause();
          }
          check();
          _primed.add(entry.key);
        }
        if (player.state != PlayerState.playing) await _rewind(entry.key);
        check();
      }
      await _volumeUpdate;
      check();
      await _applyVolume();
      check();
      _initialized = true;
    }().catchError((Object _) {}).whenComplete(() => _initialization = null);
  }

  void _invalidate(SoundKind kind) {
    _failures[kind] = ++_audioRevision;
    _prepared.remove(kind);
    _primed.remove(kind);
    _rewound.remove(kind);
    _initialized = false;
    if (_playing == kind) _playing = null;
    // The plugin cannot complete a seek while its native player is unprepared.
    _rewinds.remove(kind)?.completeError(StateError('Player invalidated'));
  }

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
    final firstAt = plan.first.atMs;
    // Re-read BOOTTIME after suspend instead of trusting a long Dart timer.
    final delay = _inFlight == null
        ? (firstAt - now).clamp(minimumDelay, 1000)
        : 1000;
    _timer = Timer(Duration(milliseconds: delay), () => _wake(_clock.nowMs));
  }

  Future<void> _start(SoundEvent event, int revision) async {
    _inFlight = event;
    bool current() => revision == _revision;
    final player = _players[event.kind]!;
    final failure = _failures[event.kind];
    void check() {
      if (failure != _failures[event.kind]) {
        throw StateError('Cue player invalidated');
      }
    }

    try {
      await initialize();
      if (!current()) return;
      if (!_initialized) {
        _policy.failed(event);
        return;
      }
      check();
      // A delayed stop reply must settle before the same player is reused.
      while (_stops.isNotEmpty) {
        await Future.wait(_stops.toList());
      }
      if (!current()) return;
      await _sources[event.kind]!.ensureAvailable();
      if (!current()) return;
      check();
      for (final other in _players.entries) {
        if (other.value.state == PlayerState.playing) await _stop(other.key);
        if (!current()) return;
        check();
      }
      _playing = null;
      await _rewind(event.kind);
      if (!current()) return;
      check();
      _rewound.remove(event.kind);
      _resuming = event.kind;
      await player.resume();
      if (!current()) {
        // The plugin cannot retract a submitted resume or bound its latency.
        await _stop(event.kind);
        return;
      }
      check();
      _playing = event.kind;
      _policy.started(event);
    } catch (_) {
      if (_resuming != null) {
        await _stop(event.kind).catchError((Object _) {});
      }
      if (current()) _policy.failed(event);
    } finally {
      _resuming = null;
      _inFlight = null;
      final now = _clock.nowMs;
      final delay = current() && event.kind.retries && !_policy.handled(event)
          ? 10
          : 0;
      _arm(_policy.due(now), now, delay);
    }
  }

  Future<void> _stop(SoundKind kind) {
    _rewound.remove(kind);
    final stop = _players[kind]!.stop().then((_) {
      unawaited(_rewind(kind).catchError((Object _) {}));
    });
    _stops.add(stop);
    return stop.whenComplete(() => _stops.remove(stop));
  }

  Future<void> _rewind(SoundKind kind) {
    if (!_prepared.contains(kind) || _rewound.contains(kind)) {
      return Future.value();
    }
    final pending = _rewinds[kind];
    if (pending != null) return pending.future;
    final rewind = Completer<void>();
    _rewinds[kind] = rewind;
    unawaited(() async {
      try {
        await _players[kind]!.seek(Duration.zero);
        if (!rewind.isCompleted) {
          _rewound.add(kind);
          rewind.complete();
        }
      } catch (error, stack) {
        if (!rewind.isCompleted) rewind.completeError(error, stack);
      } finally {
        if (identical(_rewinds[kind], rewind)) _rewinds.remove(kind);
      }
    }());
    return rewind.future;
  }

  @override
  void cancel() {
    _revision++;
    _timer?.cancel();
    _timer = null;
    _policy.reset();
    for (final entry in _players.entries) {
      final playing = entry.value.state == PlayerState.playing;
      final keep =
          entry.key.keepsOnCancel &&
          _playing == entry.key &&
          playing &&
          _resuming != entry.key;
      if (!keep && (playing || _resuming == entry.key)) {
        // Cancellation must bypass an unfinished resume, even for an end cue.
        unawaited(_stop(entry.key).catchError((Object _) {}));
      }
    }
  }

  Future<void> _applyVolume() => _volumeUpdate ??= () async {
    double sent;
    do {
      sent = _gain;
      await Future.wait(
        _players.entries
            .where((entry) => _prepared.contains(entry.key))
            .map((entry) => entry.value.setVolume(sent)),
      );
    } while (sent != _gain);
  }().whenComplete(() => _volumeUpdate = null);

  @override
  void setVolume(int percent) {
    final gain = gainOf(percent);
    if (gain == _gain) return;
    _gain = gain;
    if (_initialized ||
        (_playing != null &&
            _prepared.contains(_playing) &&
            _players[_playing]!.state == PlayerState.playing)) {
      unawaited(_applyVolume().catchError((Object _) {}));
    }
  }
}
