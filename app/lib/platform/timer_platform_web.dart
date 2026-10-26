import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;

import '../timer_engine.dart';
import 'timer_platform.dart';

class _ScheduledSound {
  _ScheduledSound(this.workout, this.event, this.nodes, this.when, this.until);

  final int workout;
  final SoundEvent event;
  final List<web.AudioBufferSourceNode> nodes;
  final double when;
  double until;
  bool played = false;

  (int, String) get key => (workout, event.id);
}

class PlatformBackend extends TimerPlatform {
  late final web.AudioContext _context;
  late final web.GainNode _gain;
  late final web.AudioBuffer _alarm;
  late final web.AudioBuffer _end;
  late final JSFunction _visibility;
  final _sources = <(int, String), _ScheduledSound>{};
  final _pending = <String, SoundEvent>{};
  final _played = <String>{};
  int _workout = 0;
  bool _endPlayed = false;
  int? _lastAlarmAtMs;
  MonotonicClock? _clock;
  double? _clockOffsetMs;
  web.WakeLockSentinel? _wakeLock;
  bool _awake = false;
  bool _disposed = false;
  bool _acquiringWakeLock = false;
  int _wakeGeneration = 0;
  int _wakeAttempt = -1;
  Timer? _retry;
  SoundKind? _retryKind;

  @override
  Future<void> initialize() async {
    _context = web.AudioContext(
      web.AudioContextOptions(latencyHint: 'interactive'.toJS),
    );
    _gain = _context.createGain()..connect(_context.destination);
    final buffers = await Future.wait([
      _decode('assets/audio/threesecbeep.wav'),
      _decode('assets/audio/hit.wav'),
    ]);
    _alarm = buffers[0];
    _end = buffers[1];
    _context.onstatechange = ((web.Event event) {
      _reconcile(rebase: true);
    }).toJS;
    _visibility = ((web.Event event) {
      if (web.document.visibilityState == 'visible') {
        unawaited(_resume());
        if (_awake) {
          _wakeGeneration++;
          unawaited(_acquireWakeLock());
        }
      } else {
        _reconcile(rebase: true);
      }
      onVisibilityChanged?.call();
    }).toJS;
    web.document.addEventListener('visibilitychange', _visibility);
  }

  Future<web.AudioBuffer> _decode(String path) async {
    final data = await rootBundle.load(path);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    return _context.decodeAudioData(bytes.sublist(0).buffer.toJS).toDart;
  }

  @override
  void unlock() {
    // This call must stay in the Start/Space event's synchronous call stack.
    if (!_disposed) unawaited(_resume());
  }

  Future<void> _resume() async {
    try {
      _reconcile(rebase: true);
      await _context.resume().toDart;
      _reconcile(rebase: true);
    } catch (_) {
      // A browser can require another user gesture after an interruption.
    }
  }

  @override
  void schedule(List<SoundEvent> events, MonotonicClock clock) {
    if (_disposed) return;
    _clock = clock;
    for (final event in events) {
      if (!_played.contains(event.id) &&
          !(event.kind == SoundKind.end && _endPlayed)) {
        _pending[event.id] = event;
      }
    }
    _reconcile();
  }

  void _recordPlayback(_ScheduledSound sound, double audioNow) {
    // Queued nodes can be stopped before rendering a single sample.
    if (audioNow <= sound.when || sound.until <= sound.when) return;
    sound.played = true;
    // A previous finish may still be audible during the new workout's prepare.
    if (sound.workout != _workout) return;
    if (!_played.add(sound.event.id)) return;
    _pending.remove(sound.event.id);
    if (sound.event.kind == SoundKind.end) {
      _endPlayed = true;
    } else {
      _lastAlarmAtMs = math.max(
        _lastAlarmAtMs ?? sound.event.atMs,
        sound.event.atMs,
      );
    }
  }

  void _removeSound(_ScheduledSound sound, {bool stop = false}) {
    _sources.remove(sound.key);
    for (final node in sound.nodes) {
      node.onended = null;
      if (stop) node.stop();
      node.disconnect();
    }
  }

  void _reconcile({bool rebase = false}) {
    final clock = _clock;
    if (_disposed || clock == null) return;
    _retry?.cancel();
    _retry = null;
    _retryKind = null;
    final now = clock.nowMs;
    final audioNow = _context.currentTime;
    final running = _context.state == 'running';
    final offset = audioNow * 1000 - now;
    // Audio rendering is quantized, but a paused context can drift by seconds.
    rebase =
        rebase ||
        !running ||
        _clockOffsetMs == null ||
        (offset - _clockOffsetMs!).abs() > 20;
    for (final sound in _sources.values.toList()) {
      _recordPlayback(sound, audioNow);
      if (audioNow >= sound.until) {
        _removeSound(sound);
      } else if (rebase && !sound.played) {
        _removeSound(sound, stop: true);
      }
    }
    if (rebase) _clockOffsetMs = running ? offset : null;
    _pending.removeWhere((id, event) {
      final discard =
          _played.contains(id) ||
          (event.kind == SoundKind.end && _endPlayed) ||
          (event.kind == SoundKind.alarm && now > event.deadlineMs);
      if (discard) {
        final sound = _sources[(_workout, id)];
        if (sound != null && !_played.contains(id)) {
          _removeSound(sound, stop: true);
        }
      }
      return discard;
    });
    if (!running) return;

    final events = _pending.values.toList()
      ..sort((a, b) => a.atMs.compareTo(b.atMs));
    var lastAlarm = _lastAlarmAtMs;
    for (final event in events) {
      final existing = _sources[(_workout, event.id)];
      if (existing != null) {
        if (event.kind == SoundKind.alarm) lastAlarm = event.atMs;
        continue;
      }
      // Delivery jitter must not suppress the next three-second rest cue.
      if (event.kind == SoundKind.alarm &&
          lastAlarm != null &&
          event.atMs < lastAlarm + 3000) {
        continue;
      }
      final startMs = math.max(now, event.atMs);
      final when = audioNow + (startMs - now) / 1000;
      final buffer = event.kind == SoundKind.alarm ? _alarm : _end;
      final repeats = event.kind == SoundKind.end ? 3 : 1;
      final nodes = <web.AudioBufferSourceNode>[];
      try {
        for (var index = 0; index < repeats; index++) {
          final source = _context.createBufferSource()..buffer = buffer;
          nodes.add(source);
          source.connect(_gain);
          source.start(when + index * buffer.duration);
        }
        final sound = _ScheduledSound(
          _workout,
          event,
          nodes,
          when,
          when + buffer.duration * repeats,
        );
        // SoundPool has one stream: a later cue replaces any overlapping sound.
        for (final other in _sources.values) {
          if (other.when <= when && other.until > when) {
            _cutOff(other, when);
          } else if (other.when > when && other.when < sound.until) {
            _cutOff(sound, other.when);
          }
        }
        _sources[sound.key] = sound;
        nodes.last.onended = ((web.Event event) {
          if (!identical(_sources[sound.key], sound)) return;
          _recordPlayback(sound, _context.currentTime);
          _removeSound(sound);
        }).toJS;
        if (event.kind == SoundKind.alarm) lastAlarm = event.atMs;
      } catch (_) {
        for (final source in nodes) {
          // start() may have failed before the node became stoppable.
          try {
            source.stop();
          } catch (_) {}
          source.disconnect();
        }
        if (now <= event.deadlineMs && event.atMs - now <= 49) {
          _retryKind = event.kind;
          _retry = Timer(const Duration(milliseconds: 10), _reconcile);
        }
        return;
      }
    }
  }

  void _cutOff(_ScheduledSound sound, double when) {
    sound.until = when;
    for (final source in sound.nodes) {
      source.stop(when);
    }
  }

  @override
  void beginWorkout() => _cancel(preservePlayingEnd: true);

  @override
  void cancel({bool keepEnd = false}) => _cancel(keepEnd: keepEnd);

  void _cancel({bool keepEnd = false, bool preservePlayingEnd = false}) {
    if (!keepEnd || _retryKind != SoundKind.end) {
      _retry?.cancel();
      _retry = null;
      _retryKind = null;
    }
    final audioNow = _context.currentTime;
    for (final sound in _sources.values.toList()) {
      _recordPlayback(sound, audioNow);
      if (sound.event.kind == SoundKind.end &&
          (keepEnd ||
              (preservePlayingEnd && sound.played && audioNow < sound.until))) {
        continue;
      }
      _removeSound(sound, stop: true);
    }
    if (keepEnd) {
      _pending.removeWhere((_, event) => event.kind == SoundKind.alarm);
    } else {
      _pending.clear();
      _played.clear();
      _workout++;
      _endPlayed = false;
      _lastAlarmAtMs = null;
      _clock = null;
      _clockOffsetMs = null;
    }
  }

  @override
  void setVolume(double gain) => _gain.gain.value = gain;

  @override
  void keepAwake(bool enabled) {
    _awake = enabled;
    _wakeGeneration++;
    if (enabled) {
      unawaited(_acquireWakeLock());
    } else {
      final lock = _wakeLock;
      _wakeLock = null;
      if (lock != null) {
        unawaited(lock.release().toDart.catchError((Object _) => null));
      }
    }
  }

  Future<void> _acquireWakeLock() async {
    if (_disposed ||
        !_awake ||
        _acquiringWakeLock ||
        _wakeAttempt == _wakeGeneration ||
        web.document.visibilityState != 'visible' ||
        _wakeLock?.released == false) {
      return;
    }
    _acquiringWakeLock = true;
    final generation = _wakeGeneration;
    // A denial must wait for a new Start or visibility event, not spin retries.
    _wakeAttempt = generation;
    try {
      final lock = await web.window.navigator.wakeLock.request('screen').toDart;
      if (!_disposed &&
          _awake &&
          generation == _wakeGeneration &&
          web.document.visibilityState == 'visible') {
        _wakeLock = lock;
      } else {
        await lock.release().toDart;
      }
    } catch (_) {
      // Browsers may deny wake locks for power saving or an insecure origin.
    } finally {
      _acquiringWakeLock = false;
      unawaited(_acquireWakeLock());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    keepAwake(false);
    _context.onstatechange = null;
    web.document.removeEventListener('visibilitychange', _visibility);
    unawaited(_context.close().toDart);
  }
}
