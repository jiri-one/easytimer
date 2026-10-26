import '../timer_engine.dart';
import 'timer_platform_native.dart'
    if (dart.library.js_interop) 'timer_platform_web.dart'
    as implementation;

abstract class TimerPlatform {
  void Function()? onVisibilityChanged;

  Future<void> initialize();
  void unlock();
  void beginWorkout() => cancel();
  void schedule(List<SoundEvent> events, MonotonicClock clock);
  void cancel({bool keepEnd = false});
  void setVolume(double gain);
  void keepAwake(bool enabled);
  void dispose();
}

TimerPlatform createTimerPlatform() => implementation.PlatformBackend();
