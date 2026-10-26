import 'clock_base.dart';
import 'clock_native.dart'
    if (dart.library.js_interop) 'clock_web.dart'
    as platform;

export 'clock_base.dart';

MonotonicClock createWorkoutClock() => platform.createClock();
