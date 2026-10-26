import '../timer_engine.dart';
import 'timer_platform_native.dart'
    if (dart.library.js_interop) 'timer_platform_web.dart'
    as implementation;

abstract class TimerPlatform {
  Future<void> initialize();
  void schedule(List<SoundEvent> events);
  void cancel();
  void setVolume(int percent);
}

TimerPlatform createTimerPlatform(MonotonicClock clock) =>
    implementation.PlatformBackend(clock);
