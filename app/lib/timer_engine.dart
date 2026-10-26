import 'dart:math' as math;

import 'clock.dart';

export 'clock.dart';

class WorkoutOptions {
  const WorkoutOptions({this.active = 45, this.rest = 15, this.sets = 0});

  final int active;
  final int rest;
  final int sets;

  static int? parse(String text) {
    if (!RegExp(r'^\d{1,4}$').hasMatch(text)) return null;
    return int.tryParse(text);
  }

  factory WorkoutOptions.fromText(
    String active,
    String rest,
    String sets, {
    WorkoutOptions fallback = const WorkoutOptions(),
  }) => WorkoutOptions(
    active: math.max(5, parse(active) ?? fallback.active),
    rest: math.max(0, parse(rest) ?? fallback.rest),
    sets: math.max(0, parse(sets) ?? 0),
  );
}

enum TimerPhase { prepare, active, rest }

enum TimerMode { stopped, running, paused, complete }

class TimerSnapshot {
  const TimerSnapshot(this.mode, this.phase, this.set, this.remainingMs);

  final TimerMode mode;
  final TimerPhase phase;
  final int set;
  final int remainingMs;

  int get seconds => (remainingMs + 999) ~/ 1000;

  bool sameDisplay(TimerSnapshot other) =>
      mode == other.mode &&
      phase == other.phase &&
      set == other.set &&
      seconds == other.seconds;
}

class PhaseSpan {
  const PhaseSpan(this.phase, this.set, this.startMs, this.endMs);

  final TimerPhase phase;
  final int set;
  final int startMs;
  final int endMs;
}

enum SoundKind { alarm, end }

class SoundEvent {
  const SoundEvent(this.kind, this.atMs, this.deadlineMs);

  final SoundKind kind;
  final int atMs;
  final int deadlineMs;

  String get id => '${kind.name}:$atMs';
}

class AlarmGate {
  int? _lastSuccessCueMs;

  bool allows(int cueMs) =>
      _lastSuccessCueMs == null || cueMs - _lastSuccessCueMs! >= 3000;

  void succeeded(int cueMs) => _lastSuccessCueMs = cueMs;

  void reset() => _lastSuccessCueMs = null;
}

class TimerEngine {
  TimerEngine(this.clock);

  final MonotonicClock clock;
  WorkoutOptions options = const WorkoutOptions();
  TimerMode _mode = TimerMode.stopped;
  PhaseSpan _anchor = const PhaseSpan(TimerPhase.prepare, 0, 0, 5000);
  TimerSnapshot? _paused;

  void start(WorkoutOptions value) {
    assert(value.active >= 5 && value.rest >= 0 && value.sets >= 0);
    options = value;
    _anchor = PhaseSpan(TimerPhase.prepare, 0, clock.nowMs, clock.nowMs + 5000);
    _paused = null;
    _mode = TimerMode.running;
  }

  int get _firstActiveStart =>
      _anchor.endMs +
      (_anchor.phase == TimerPhase.active ? options.rest * 1000 : 0);

  int? get completionMs {
    if (options.sets == 0) return null;
    if (_anchor.phase == TimerPhase.active && _anchor.set >= options.sets) {
      return _anchor.endMs;
    }
    return _firstActiveStart +
        (options.sets - _anchor.set - 1) *
            (options.active + options.rest) *
            1000 +
        options.active * 1000;
  }

  PhaseSpan? phaseAt(int timeMs) {
    final end = completionMs;
    if (end != null && timeMs >= end) return null;
    if (timeMs < _anchor.endMs) return _anchor;
    final first = _firstActiveStart;
    if (timeMs < first) {
      return PhaseSpan(TimerPhase.rest, _anchor.set, _anchor.endMs, first);
    }
    final cycle = (options.active + options.rest) * 1000;
    final index = (timeMs - first) ~/ cycle;
    final start = first + index * cycle;
    final set = _anchor.set + 1 + index;
    final activeEnd = start + options.active * 1000;
    return timeMs < activeEnd
        ? PhaseSpan(TimerPhase.active, set, start, activeEnd)
        : PhaseSpan(TimerPhase.rest, set, activeEnd, start + cycle);
  }

  TimerSnapshot get snapshot {
    if (_mode == TimerMode.paused) return _paused!;
    if (_mode == TimerMode.stopped) {
      return const TimerSnapshot(
        TimerMode.stopped,
        TimerPhase.prepare,
        0,
        5000,
      );
    }
    final phase = phaseAt(clock.nowMs);
    if (phase == null) {
      return TimerSnapshot(
        TimerMode.complete,
        TimerPhase.active,
        options.sets,
        0,
      );
    }
    return TimerSnapshot(
      TimerMode.running,
      phase.phase,
      phase.set,
      math.max(0, phase.endMs - clock.nowMs),
    );
  }

  void pause() {
    final value = snapshot;
    if (value.mode != TimerMode.running) return;
    _paused = TimerSnapshot(
      TimerMode.paused,
      value.phase,
      value.set,
      value.remainingMs,
    );
    _mode = TimerMode.paused;
  }

  void resume() {
    if (_mode != TimerMode.paused) return;
    final value = _paused!;
    final active = value.phase == TimerPhase.active;
    _anchor = PhaseSpan(
      active ? TimerPhase.active : TimerPhase.prepare,
      value.set,
      clock.nowMs,
      clock.nowMs + (active ? value.remainingMs : 5000),
    );
    _mode = TimerMode.running;
    _paused = null;
  }

  void stop() {
    _mode = TimerMode.stopped;
    _paused = null;
  }

  List<SoundEvent> soundsBetween(int fromMs, int throughMs) {
    if (_mode != TimerMode.running) return const [];
    final events = <SoundEvent>[];
    var cursor = math.max(fromMs, _anchor.startMs);
    while (cursor <= throughMs) {
      final span = phaseAt(cursor);
      if (span == null) break;
      // A resumed phase can start inside Kotlin's 2951..3049 ms window.
      if (span.endMs - span.startMs >= 2951) {
        final at = span.endMs - span.startMs <= 3049
            ? span.startMs
            : span.endMs - 3000;
        if (at >= fromMs && at <= throughMs) {
          events.add(SoundEvent(SoundKind.alarm, at, span.endMs - 2951));
        }
      }
      cursor = span.endMs;
    }
    final end = completionMs;
    if (end != null && end >= fromMs && end <= throughMs) {
      events.add(SoundEvent(SoundKind.end, end, end));
    }
    return events;
  }
}
