import 'dart:async';

import 'package:audioplayers/audioplayers.dart';

import '../constants.dart';
import '../cue_policy.dart';
import '../timer_engine.dart';
import 'timer_platform.dart';

class PlatformBackend extends TimerPlatform {
  PlatformBackend({AudioPlayer? player})
    : _player = player ?? (AudioPlayer()..positionUpdater = null) {
    _completion = _player.onPlayerComplete.listen(
      (_) => _completed(),
      onError: (Object _) {
        _playing = null;
        _endRemaining = 0;
      },
    );
  }

  final AudioPlayer _player;
  final _policy = CuePolicy();
  final _pending = <CueId, SoundEvent>{};
  late final StreamSubscription<void> _completion;
  Future<void> _operations = Future.value();
  Future<void>? _initialization;
  MonotonicClock? _clock;
  Timer? _timer;
  SoundEvent? _inFlight;
  SoundEvent? _playing;
  int _revision = 0;
  int _endRemaining = 0;
  double _gain = 1;
  bool _initialized = false;
  bool _disposed = false;

  Future<void> _serial(Future<void> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.catchError((Object _) {});
    return result;
  }

  @override
  Future<void> initialize() => _initialization ??=
      _serial(() async {
        if (_disposed) return;
        // SoundPool has no completion events for the three finish hits.
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
        await _player.setSource(AssetSource(alarmAsset.substring(7)));
        await _player.setVolume(_gain);
        _initialized = true;
      }).catchError((Object _) {
        _initialization = null;
      });

  @override
  void unlock() {}

  @override
  void schedule(List<SoundEvent> events, MonotonicClock clock) {
    if (_disposed) return;
    _clock = clock;
    for (final event in events) {
      if (_policy.allows(event, clock.nowMs)) {
        _pending.putIfAbsent(event.id, () => event);
      }
    }
    _wake();
  }

  void _wake() {
    _timer?.cancel();
    _timer = null;
    if (_disposed || _clock == null) return;
    final now = _clock!.nowMs;
    _pending.removeWhere(
      (_, event) => !identical(event, _inFlight) && !_policy.allows(event, now),
    );
    final plan = _pending.values.toList()
      ..sort((a, b) => a.atMs.compareTo(b.atMs));
    if (_inFlight == null && plan.isNotEmpty && plan.first.atMs <= now) {
      unawaited(_start(plan.first, _clock!, _revision));
    }
    _arm();
  }

  void _arm([int minimumDelay = 0]) {
    _timer?.cancel();
    _timer = null;
    if (_disposed || _pending.isEmpty) return;
    final firstAt = _pending.values
        .map((event) => event.atMs)
        .reduce((a, b) => a < b ? a : b);
    // Re-read BOOTTIME after suspend instead of trusting a long Dart timer.
    final delay = _inFlight == null
        ? (firstAt - _clock!.nowMs).clamp(minimumDelay, 1000)
        : 1000;
    _timer = Timer(Duration(milliseconds: delay), _wake);
  }

  Future<void> _start(
    SoundEvent event,
    MonotonicClock clock,
    int revision,
  ) async {
    _inFlight = event;
    bool current() => !_disposed && revision == _revision;
    try {
      await initialize();
      if (!_initialized || !current()) return;
      await _serial(() async {
        if (!current() || !_policy.allows(event, clock.nowMs)) return;
        _playing = null;
        _endRemaining = 0;
        await _player.stop();
        if (!current()) return;
        final asset = event.kind == SoundKind.alarm ? alarmAsset : endAsset;
        await _player.setSource(AssetSource(asset.substring(7)));
        // Loading can outlive an alarm's window or a cancelled plan.
        if (!current() || !_policy.allows(event, clock.nowMs)) return;
        _playing = event;
        _endRemaining = event.kind == SoundKind.end ? 2 : 0;
        await _player.resume();
        if (current()) _policy.started(event, clock.nowMs);
      });
    } catch (_) {
      if (identical(_playing, event)) {
        _playing = null;
        _endRemaining = 0;
      }
    } finally {
      if (current() &&
          (event.kind == SoundKind.end ||
              _policy.handled(event) ||
              _policy.expired(event, clock.nowMs))) {
        _pending.remove(event.id);
      }
      _inFlight = null;
      _arm(current() && !_policy.handled(event) ? 10 : 0);
    }
  }

  void _completed() {
    final event = _playing;
    if (event == null) return;
    if (event.kind != SoundKind.end || _endRemaining == 0) {
      _playing = null;
      return;
    }
    _endRemaining--;
    unawaited(
      _serial(() async {
        if (_disposed || !identical(_playing, event)) return;
        try {
          await _player.resume();
        } catch (_) {
          if (identical(_playing, event)) {
            _playing = null;
            _endRemaining = 0;
          }
        }
      }),
    );
  }

  @override
  void cancel() {
    _revision++;
    _timer?.cancel();
    _timer = null;
    _pending.clear();
    _policy.reset();
    if (_playing?.kind != SoundKind.end) {
      _playing = null;
      _endRemaining = 0;
      unawaited(_serial(_player.stop));
    }
  }

  @override
  void setVolume(int percent) {
    if (_disposed) return;
    final linear = percent / 100;
    _gain = linear * linear;
    unawaited(_serial(() => _player.setVolume(_gain)));
  }

  @override
  void dispose() {
    if (_disposed) return;
    cancel();
    _disposed = true;
    _playing = null;
    _endRemaining = 0;
    unawaited(_completion.cancel());
    keepAwake(false);
    unawaited(_serial(_player.dispose));
  }
}
