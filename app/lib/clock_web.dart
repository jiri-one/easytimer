import 'clock.dart';

class StopwatchClock implements MonotonicClock {
  final _watch = Stopwatch()..start();
  @override
  int get nowMs => _watch.elapsedMilliseconds;
}

MonotonicClock createClock() => StopwatchClock();
