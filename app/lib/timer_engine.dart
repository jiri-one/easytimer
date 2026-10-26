import 'dart:math' as math;

import 'clock.dart';
import 'constants.dart';

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

  factory WorkoutOptions.normalized(int? active, int? rest, int? sets) {
    int value(int? number, int fallback) =>
        number != null && number >= 0 && number <= 9999 ? number : fallback;
    return WorkoutOptions(
      active: math.max(5, value(active, 45)),
      rest: value(rest, 15),
      sets: value(sets, 0),
    );
  }

  factory WorkoutOptions.fromText(
    String active,
    String rest,
    String sets, {
    WorkoutOptions fallback = const WorkoutOptions(),
  }) => WorkoutOptions.normalized(
    parse(active) ?? fallback.active,
    parse(rest) ?? fallback.rest,
    parse(sets),
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

const stoppedSnapshot = TimerSnapshot(
  TimerMode.stopped,
  TimerPhase.prepare,
  0,
  prepareMs,
);

class PhaseSpan {
  const PhaseSpan(this.phase, this.set, this.startMs, this.endMs);

  final TimerPhase phase;
  final int set;
  final int startMs;
  final int endMs;
}

enum SoundKind { alarm, end }

typedef CueId = (SoundKind, int);

class SoundEvent {
  const SoundEvent(this.kind, this.atMs, this.deadlineMs)
    : id = (kind, kind == SoundKind.end ? 0 : atMs);

  final SoundKind kind;
  final int atMs;
  final int? deadlineMs;
  final CueId id;
}

class TimerEngine {
  TimerEngine(this.clock);

  final MonotonicClock clock;
  WorkoutOptions options = const WorkoutOptions();
  TimerMode _mode = TimerMode.stopped;
  PhaseSpan _anchor = const PhaseSpan(TimerPhase.prepare, 0, 0, prepareMs);
  TimerSnapshot? _paused;

  void start(WorkoutOptions value) {
    assert(value.active >= 5 && value.rest >= 0 && value.sets >= 0);
    options = value;
    final now = clock.nowMs;
    _anchor = PhaseSpan(TimerPhase.prepare, 0, now, now + prepareMs);
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

  TimerSnapshot get snapshot => snapshotAt(clock.nowMs);

  TimerSnapshot snapshotAt(int nowMs) {
    if (_mode == TimerMode.paused) return _paused!;
    if (_mode == TimerMode.stopped) {
      return stoppedSnapshot;
    }
    final phase = phaseAt(nowMs);
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
      math.max(0, phase.endMs - nowMs),
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
    final now = clock.nowMs;
    _anchor = PhaseSpan(
      active ? TimerPhase.active : TimerPhase.prepare,
      value.set,
      now,
      now + (active ? value.remainingMs : prepareMs),
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
        if (span.endMs - 2951 >= fromMs && at <= throughMs) {
          events.add(SoundEvent(SoundKind.alarm, at, span.endMs - 2951));
        }
      }
      cursor = span.endMs;
    }
    final end = completionMs;
    if (end != null && end <= throughMs) {
      events.add(SoundEvent(SoundKind.end, end, null));
    }
    return events;
  }
}
