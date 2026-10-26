import 'timer_engine.dart';

class CuePolicy {
  final _started = <CueId, int>{};
  int? _lastAlarmAt;

  bool handled(SoundEvent cue) => _started.containsKey(cue.id);

  bool expired(SoundEvent cue, int nowMs) =>
      cue.deadlineMs != null && nowMs > cue.deadlineMs!;

  bool allows(SoundEvent cue, int nowMs) => select([cue], nowMs).isNotEmpty;

  Iterable<SoundEvent> select(Iterable<SoundEvent> plan, int nowMs) sync* {
    var previous = _lastAlarmAt;
    for (final cue in plan) {
      if (handled(cue) || expired(cue, nowMs)) continue;
      if (cue.kind == SoundKind.alarm) {
        if (previous != null && cue.atMs - previous < 3000) continue;
        previous = cue.atMs;
      }
      yield cue;
    }
  }

  void started(SoundEvent cue, int startedAtMs) {
    _started[cue.id] = startedAtMs;
    if (cue.kind == SoundKind.alarm) _lastAlarmAt = cue.atMs;
  }

  void reset() {
    _started.clear();
    _lastAlarmAt = null;
  }
}
