import 'clock_native.dart'
    if (dart.library.js_interop) 'clock_web.dart'
    as platform;

abstract interface class MonotonicClock {
  int get nowMs;
}

MonotonicClock createWorkoutClock() => platform.createClock();
