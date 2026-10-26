import 'dart:async';

import 'package:flutter/services.dart';

import '../timer_engine.dart';
import 'timer_platform.dart';

class PlatformBackend extends TimerPlatform {
  static const _channel = MethodChannel('easytimer/platform');
  final _pending = <String, (SoundEvent, Timer)>{};
  final _handled = <String, int>{};
  final _gate = AlarmGate();
  int _generation = 0;
  int _alarmGeneration = 0;

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

  Future<bool> _invoke(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<bool>(method, arguments) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  void unlock() {}

  @override
  void schedule(List<SoundEvent> events, MonotonicClock clock) {
    _handled.removeWhere((_, at) => at < clock.nowMs - 10000);
    for (final event in events) {
      if (_pending.containsKey(event.id) || _handled.containsKey(event.id)) {
        continue;
      }
      _arm(event, clock, _generation);
    }
  }

  void _arm(SoundEvent event, MonotonicClock clock, int generation) {
    final alarmGeneration = _alarmGeneration;
    bool cancelled() =>
        generation != _generation ||
        (event.kind == SoundKind.alarm && alarmGeneration != _alarmGeneration);
    final delay = (event.atMs - clock.nowMs).clamp(0, 300000);
    _pending[event.id] = (
      event,
      Timer(Duration(milliseconds: delay), () async {
        if (cancelled()) return;
        final now = clock.nowMs;
        if (event.kind == SoundKind.alarm &&
            (now > event.deadlineMs || !_gate.allows(now))) {
          _handled[event.id] = event.atMs;
          _pending.remove(event.id);
          return;
        }
        final played = await _invoke(
          event.kind == SoundKind.alarm ? 'playAlarm' : 'playEnd',
        );
        if (cancelled()) return;
        if (played || event.kind == SoundKind.end) {
          _handled[event.id] = event.atMs;
          _pending.remove(event.id);
          if (played && event.kind == SoundKind.alarm) _gate.succeeded(now);
        } else if (clock.nowMs < event.deadlineMs) {
          // A failed SoundPool play must not consume the duplicate guard.
          _pending[event.id] = (
            event,
            Timer(const Duration(milliseconds: 10), () {
              _pending.remove(event.id);
              if (!cancelled()) _arm(event, clock, generation);
            }),
          );
        } else {
          _pending.remove(event.id);
        }
      }),
    );
  }

  @override
  void cancel({bool keepEnd = false}) {
    _alarmGeneration++;
    if (!keepEnd) _generation++;
    _pending.removeWhere((_, entry) {
      if (keepEnd && entry.$1.kind == SoundKind.end) return false;
      entry.$2.cancel();
      return true;
    });
    if (!keepEnd) _handled.clear();
    _gate.reset();
    unawaited(_invoke(keepEnd ? 'cancelAlarm' : 'stop'));
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
