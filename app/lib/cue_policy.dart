import 'timer_engine.dart';

extension SoundKindPolicy on SoundKind {
  bool get retries => this == SoundKind.alarm;
  bool get keepsOnCancel => this == SoundKind.end;
}

class CuePolicy {
  final _pending = <CueId, SoundEvent>{};
  final _started = <CueId>{};
  int? _lastAlarmAt;

  bool handled(SoundEvent cue) => _started.contains(cue.id);

  bool expired(SoundEvent cue, int nowMs) =>
      cue.deadlineMs != null && nowMs > cue.deadlineMs!;

  bool merge(Iterable<SoundEvent> events) {
    var added = false;
    for (final event in events) {
      if (!handled(event) && !_pending.containsKey(event.id)) {
        _pending[event.id] = event;
        added = true;
      }
    }
    return added;
  }

  List<SoundEvent> due(int nowMs, {CueId? inFlight}) {
    _pending.removeWhere(
      (id, cue) => id != inFlight && (handled(cue) || expired(cue, nowMs)),
    );
    final plan = _pending.values.toList()
      ..sort((a, b) => a.atMs.compareTo(b.atMs));
    final selected = <SoundEvent>[];
    var previous = _lastAlarmAt;
    for (final cue in plan) {
      if (cue.kind == SoundKind.alarm) {
        if (previous != null && cue.atMs - previous < 3000) continue;
        previous = cue.atMs;
      }
      selected.add(cue);
    }
    return selected;
  }

  void started(SoundEvent cue) {
    _started.add(cue.id);
    _pending.remove(cue.id);
    if (cue.kind == SoundKind.alarm) _lastAlarmAt = cue.atMs;
  }

  void failed(SoundEvent cue) {
    if (!cue.kind.retries) _pending.remove(cue.id);
  }

  void reset() {
    _pending.clear();
    _started.clear();
    _lastAlarmAt = null;
  }
}
