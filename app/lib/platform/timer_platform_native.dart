import 'dart:async';

import 'package:flutter/services.dart';

import '../timer_engine.dart';
import 'timer_platform.dart';

class _PendingSound {
  _PendingSound(this.event);

  final SoundEvent event;
  Timer? timer;
}

class PlatformBackend extends TimerPlatform {
  PlatformBackend({MonotonicClock? dispatchClock})
    : _dispatchClock = dispatchClock ?? StopwatchClock();

  static const _channel = MethodChannel('easytimer/platform');
  final MonotonicClock _dispatchClock;
  final _pending = <String, _PendingSound>{};
  final _handled = <String, int>{};
  final _gate = AlarmGate();
  bool _endHandled = false;
  int? _clockOffset;
  int _generation = 0;
  int _alarmGeneration = 0;

  Map<String, int> get _generations => {
    'generation': _generation,
    'alarmGeneration': _alarmGeneration,
  };

  @override
  Future<void> initialize() async {
    final assets = await Future.wait([
      rootBundle.load('assets/audio/threesecbeep.wav'),
      rootBundle.load('assets/audio/hit.wav'),
    ]);
    await _invoke('initialize', {
      'alarm': assets[0].buffer.asUint8List(),
      'end': assets[1].buffer.asUint8List(),
    });
  }

  Future<Object?> _invoke(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<Object?>(method, arguments);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  void unlock() {}

  @override
  void schedule(List<SoundEvent> events, MonotonicClock clock) {
    final now = clock.nowMs;
    final offset = now - _dispatchClock.nowMs;
    if (_clockOffset != null && (offset - _clockOffset!).abs() > 25) {
      // Dart timers exclude suspend, so their remaining delays are now stale.
      _alarmGeneration++;
      _pending.removeWhere((_, pending) {
        if (pending.event.kind == SoundKind.end && pending.timer == null) {
          return false;
        }
        pending.timer?.cancel();
        return true;
      });
      unawaited(_invoke('cancelAlarm', _generations));
    }
    _clockOffset = offset;
    _handled.removeWhere((_, at) => at < now - 10000);
    for (final event in events) {
      if (_pending.containsKey(event.id) ||
          _handled.containsKey(event.id) ||
          (event.kind == SoundKind.end && _endHandled)) {
        continue;
      }
      if (event.kind == SoundKind.alarm && now > event.deadlineMs) continue;
      _arm(event, clock, _generation);
    }
  }

  void _arm(SoundEvent event, MonotonicClock clock, int generation) {
    final alarmGeneration = _alarmGeneration;
    bool cancelled() =>
        generation != _generation ||
        (event.kind == SoundKind.alarm && alarmGeneration != _alarmGeneration);
    final pending = _PendingSound(event);
    _pending[event.id] = pending;
    final delay = (event.atMs - clock.nowMs).clamp(0, 300000);
    pending.timer = Timer(Duration(milliseconds: delay), () async {
      pending.timer = null;
      if (cancelled()) return;
      final now = clock.nowMs;
      if (event.kind == SoundKind.alarm && now > event.deadlineMs) {
        _handled[event.id] = event.atMs;
        _pending.remove(event.id);
        return;
      }
      Object? result;
      if (event.kind == SoundKind.end || _gate.allows(event.atMs)) {
        if (event.kind == SoundKind.end) _endHandled = true;
        result = await _invoke(
          event.kind == SoundKind.alarm ? 'playAlarm' : 'playEnd',
          {
            ..._generations,
            'eventId': event.id,
            'plannedAtMs': event.atMs,
            'deadlineMs': event.deadlineMs,
          },
        );
      }
      if (cancelled()) return;
      final startedAt = result is Map ? result['startedAtMs'] : null;
      if (startedAt is int || event.kind == SoundKind.end) {
        _handled[event.id] = event.atMs;
        _pending.remove(event.id);
        if (startedAt is int && event.kind == SoundKind.alarm) {
          _gate.succeeded(event.atMs);
        }
      } else if (clock.nowMs < event.deadlineMs) {
        // Only successful starts consume the planned cue's duplicate guard.
        pending.timer = Timer(const Duration(milliseconds: 10), () {
          _pending.remove(event.id);
          if (!cancelled()) _arm(event, clock, generation);
        });
      } else {
        _pending.remove(event.id);
      }
    });
  }

  @override
  void beginWorkout() => _cancel(begin: true);

  @override
  void cancel({bool keepEnd = false}) => _cancel(keepEnd: keepEnd);

  void _cancel({bool keepEnd = false, bool begin = false}) {
    _alarmGeneration++;
    if (!keepEnd) _generation++;
    _pending.removeWhere((_, pending) {
      if (keepEnd && pending.event.kind == SoundKind.end) return false;
      pending.timer?.cancel();
      return true;
    });
    if (!keepEnd) {
      _handled.clear();
      _endHandled = false;
      _clockOffset = null;
    }
    _gate.reset();
    unawaited(
      _invoke(
        begin ? 'beginWorkout' : (keepEnd ? 'cancelAlarm' : 'stop'),
        _generations,
      ),
    );
  }

  @override
  void setVolume(double gain) => unawaited(_invoke('setVolume', gain));

  @override
  void keepAwake(bool enabled) => unawaited(_invoke('keepAwake', enabled));

  @override
  void dispose() {
    cancel();
    unawaited(_invoke('dispose'));
  }
}
