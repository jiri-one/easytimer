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

class _SoundPlayer {
  _SoundPlayer(this.player);

  final AudioPlayer player;
  final _pending = <Completer<void>>{};
  bool invalidated = false;
  late final StreamSubscription<void> completion;
  bool prepared = false;
  bool primed = false;
  bool rewound = false;
  Future<void>? rewind;

  Future<void> run(Future<void> Function() operation) async {
    check();
    final pending = Completer<void>();
    _pending.add(pending);
    unawaited(
      Future.sync(operation).then(
        (_) {
          if (!pending.isCompleted) pending.complete();
        },
        onError: (Object error, StackTrace stack) {
          if (!pending.isCompleted) pending.completeError(error, stack);
        },
      ),
    );
    try {
      await pending.future;
      check();
    } finally {
      _pending.remove(pending);
    }
  }

  void invalidate() {
    invalidated = true;
    // An errored native operation may never return.
    for (final pending in _pending) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('Player invalidated'));
      }
    }
  }

  void check() {
    if (invalidated) throw StateError('Player invalidated');
  }
}

class PlatformBackend extends TimerPlatform {
  PlatformBackend(this._clock, {AudioPlayer Function(SoundKind)? playerFactory})
    : _playerFactory = playerFactory ?? ((_) => AudioPlayer()) {
    for (final kind in SoundKind.values) {
      _players[kind] = _createPlayer(kind);
    }
  }

  final MonotonicClock _clock;
  final AudioPlayer Function(SoundKind) _playerFactory;
  final _players = <SoundKind, _SoundPlayer>{};
  final _policy = CuePolicy();
  final _sources = <SoundKind, _CachedBytesSource>{};
  final _stops = <Future<void>>{};
  Future<void>? _initialization;
  Future<void>? _volumeUpdate;
  Timer? _timer;
  SoundEvent? _inFlight;
  _SoundPlayer? _resuming;
  _SoundPlayer? _playing;
  int _revision = 0;
  double _gain = 1;
  bool _initialized = false;

  _SoundPlayer _createPlayer(SoundKind kind) {
    final sound = _SoundPlayer(_playerFactory(kind)..positionUpdater = null);
    sound.completion = sound.player.onPlayerComplete.listen((_) {
      sound.rewound = false;
      unawaited(_rewind(sound).catchError((Object _) {}));
    }, onError: (Object _) => _replace(kind, sound));
    return sound;
  }

  void _replace(SoundKind kind, _SoundPlayer failed) {
    if (!identical(_players[kind], failed)) return;
    failed.invalidate();
    unawaited(failed.completion.cancel().catchError((Object _) {}));
    unawaited(Future.sync(failed.player.dispose).catchError((Object _) {}));
    _players[kind] = _createPlayer(kind);
    _initialized = false;
    if (_playing == failed) _playing = null;
  }

  @override
  Future<void> initialize() {
    if (_initialized) return Future.value();
    return _initialization ??= () async {
      while (_stops.isNotEmpty) {
        await Future.wait(_stops.toList());
      }
      // A live gain update must finish before muting a new Android player.
      await _volumeUpdate;
      if (_sources.isEmpty) {
        final bytes = await Future.wait(SoundKind.values.map(loadSound));
        for (final kind in SoundKind.values) {
          _sources[kind] = _CachedBytesSource(kind, bytes[kind.index]);
        }
      }
      final players = _players.entries.toList();
      for (final entry in players) {
        final sound = entry.value;
        final player = sound.player;
        if (!sound.prepared) {
          // SoundPool does not report reliable completion, so state goes stale.
          await sound.run(() => player.setPlayerMode(PlayerMode.mediaPlayer));
          await sound.run(() => player.setReleaseMode(ReleaseMode.stop));
          await sound.run(
            () => player.setAudioContext(
              AudioContext(
                android: const AudioContextAndroid(
                  usageType: AndroidUsageType.media,
                  contentType: AndroidContentType.sonification,
                  audioFocus: AndroidAudioFocus.none,
                ),
              ),
            ),
          );
          await sound.run(() => player.setSource(_sources[entry.key]!));
          sound.prepared = true;
        }
        if (defaultTargetPlatform == TargetPlatform.android && !sound.primed) {
          // Android allocates its AudioTrack on first start; warm it silently.
          await sound.run(() => player.setVolume(0));
          try {
            await sound.run(player.resume);
          } finally {
            if (!sound.invalidated) await sound.run(player.pause);
          }
          sound.primed = true;
        }
        if (player.state != PlayerState.playing) await _rewind(sound);
        sound.check();
      }
      await _volumeUpdate;
      await _applyVolume();
      for (final entry in players) {
        entry.value.check();
      }
      _initialized = true;
    }().catchError((Object _) {}).whenComplete(() => _initialization = null);
  }

  @override
  void schedule(List<SoundEvent> events) {
    final now = _clock.nowMs;
    _policy.merge(events);
    _wake(now);
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
    final sound = _players[event.kind]!;
    try {
      await initialize();
      if (!current()) return;
      if (!_initialized) {
        _policy.failed(event);
        return;
      }
      sound.check();
      // A delayed stop reply must settle before the same player is reused.
      while (_stops.isNotEmpty) {
        await Future.wait(_stops.toList());
      }
      if (!current()) return;
      await _sources[event.kind]!.ensureAvailable();
      if (!current()) return;
      sound.check();
      for (final other in _players.values) {
        if (other.player.state == PlayerState.playing) await _stop(other);
        if (!current()) return;
        sound.check();
      }
      _playing = null;
      await _rewind(sound);
      if (!current()) return;
      sound.check();
      sound.rewound = false;
      _resuming = sound;
      await sound.run(sound.player.resume);
      if (!current()) {
        // The plugin cannot retract a submitted resume or bound its latency.
        await _stop(sound);
        return;
      }
      _playing = sound;
      _policy.started(event);
    } catch (_) {
      if (_resuming == sound && !sound.invalidated) {
        await _stop(sound).catchError((Object _) {});
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

  Future<void> _stop(_SoundPlayer sound) {
    sound.rewound = false;
    final stop = sound.run(sound.player.stop).then((_) {
      unawaited(_rewind(sound).catchError((Object _) {}));
    });
    _stops.add(stop);
    return stop.whenComplete(() => _stops.remove(stop));
  }

  Future<void> _rewind(_SoundPlayer sound) {
    if (!sound.prepared || sound.rewound) return Future.value();
    return sound.rewind ??= sound
        .run(() => sound.player.seek(Duration.zero))
        .then<void>((_) {
          sound.rewound = true;
        })
        .whenComplete(() => sound.rewind = null);
  }

  @override
  void cancel() {
    _revision++;
    _timer?.cancel();
    _timer = null;
    _policy.reset();
    for (final entry in _players.entries) {
      final sound = entry.value;
      final playing = sound.player.state == PlayerState.playing;
      final keep =
          entry.key.keepsOnCancel &&
          _playing == sound &&
          playing &&
          _resuming != sound;
      if (!keep && (playing || _resuming == sound)) {
        // Cancellation must bypass an unfinished resume, even for an end cue.
        unawaited(_stop(sound).catchError((Object _) {}));
      }
    }
  }

  Future<void> _applyVolume() => _volumeUpdate ??= () async {
    double sent;
    do {
      sent = _gain;
      await Future.wait(
        _players.values
            .where(
              (sound) =>
                  sound.prepared &&
                  (defaultTargetPlatform != TargetPlatform.android ||
                      sound.primed),
            )
            .map((sound) => sound.run(() => sound.player.setVolume(sent))),
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
            _playing!.prepared &&
            _playing!.player.state == PlayerState.playing)) {
      unawaited(_applyVolume().catchError((Object _) {}));
    }
  }
}
