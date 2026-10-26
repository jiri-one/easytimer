abstract interface class MonotonicClock {
  int get nowMs;
}

class StopwatchClock implements MonotonicClock {
  final Stopwatch _watch = Stopwatch()..start();

  @override
  int get nowMs => _watch.elapsedMilliseconds;
}
