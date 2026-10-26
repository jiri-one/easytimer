import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;

import '../timer_engine.dart';
import 'timer_platform.dart';

class PlatformBackend extends TimerPlatform {
  late final web.AudioContext _context;
  late final web.GainNode _gain;
  late final web.AudioBuffer _alarm;
  late final web.AudioBuffer _end;
  late final JSFunction _visibility;
  final _sources = <String, (SoundEvent, List<web.AudioBufferSourceNode>)>{};
  final _gate = AlarmGate();
  web.WakeLockSentinel? _wakeLock;
  bool _awake = false;
  bool _disposed = false;
  bool _acquiringWakeLock = false;
  int _wakeGeneration = 0;
  Timer? _retry;
  (List<SoundEvent>, MonotonicClock)? _deferred;

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
    _visibility = ((web.Event event) {
      if (_awake && web.document.visibilityState == 'visible') {
        unawaited(_acquireWakeLock());
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
    unawaited(_resume());
  }

  Future<void> _resume() async {
    try {
      await _context.resume().toDart;
      final deferred = _deferred;
      _deferred = null;
      if (!_disposed && deferred != null) schedule(deferred.$1, deferred.$2);
    } catch (_) {
      // A browser can require another user gesture after an interruption.
    }
  }

  @override
  void schedule(List<SoundEvent> events, MonotonicClock clock) {
    if (_disposed) return;
    if (_context.state != 'running') {
      _deferred = (events, clock);
      return;
    }
    _sources.removeWhere((_, entry) {
      final duration = entry.$1.kind == SoundKind.end
          ? _end.duration * 3
          : _alarm.duration;
      if (entry.$1.atMs + duration * 1000 + 10000 >= clock.nowMs) return false;
      for (final source in entry.$2) {
        source.disconnect();
      }
      return true;
    });
    for (final event in events) {
      if (_sources.containsKey(event.id)) continue;
      if (event.kind == SoundKind.alarm &&
          (clock.nowMs > event.deadlineMs || !_gate.allows(event.atMs))) {
        continue;
      }
      final nodes = <web.AudioBufferSourceNode>[];
      try {
        final when =
            _context.currentTime + math.max(0, event.atMs - clock.nowMs) / 1000;
        final buffer = event.kind == SoundKind.alarm ? _alarm : _end;
        final repeats = event.kind == SoundKind.end ? 3 : 1;
        for (var index = 0; index < repeats; index++) {
          final source = _context.createBufferSource()..buffer = buffer;
          source.connect(_gain);
          source.start(when + index * buffer.duration);
          nodes.add(source);
        }
        // SoundPool's single stream is replaced by the next alarm or finish.
        for (final entry in _sources.values) {
          if (entry.$1.kind == SoundKind.alarm &&
              entry.$1.atMs < event.atMs &&
              entry.$1.atMs + _alarm.duration * 1000 > event.atMs) {
            for (final source in entry.$2) {
              source.stop(when);
            }
          }
        }
        _sources[event.id] = (event, nodes);
        if (event.kind == SoundKind.alarm) _gate.succeeded(event.atMs);
      } catch (_) {
        // Keep failed events eligible for the next scheduling pass.
        for (final source in nodes) {
          source.stop();
          source.disconnect();
        }
        if (clock.nowMs <= event.deadlineMs && event.atMs - clock.nowMs <= 49) {
          _retry?.cancel();
          _retry = Timer(
            const Duration(milliseconds: 10),
            () => schedule(events, clock),
          );
        }
        return;
      }
    }
  }

  @override
  void cancel({bool keepEnd = false}) {
    _retry?.cancel();
    _deferred = null;
    _sources.removeWhere((_, entry) {
      if (keepEnd && entry.$1.kind == SoundKind.end) return false;
      for (final source in entry.$2) {
        source.stop();
        source.disconnect();
      }
      return true;
    });
    _gate.reset();
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
    if (_acquiringWakeLock ||
        web.document.visibilityState != 'visible' ||
        _wakeLock?.released == false) {
      return;
    }
    _acquiringWakeLock = true;
    final generation = _wakeGeneration;
    try {
      final lock = await web.window.navigator.wakeLock.request('screen').toDart;
      if (_awake && generation == _wakeGeneration) {
        _wakeLock = lock;
      } else {
        await lock.release().toDart;
      }
    } catch (_) {
      // Browsers may deny wake locks for power saving or an insecure origin.
    } finally {
      _acquiringWakeLock = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    keepAwake(false);
    web.document.removeEventListener('visibilitychange', _visibility);
    unawaited(_context.close().toDart);
  }
}
