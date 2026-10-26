import 'package:wakelock_plus/wakelock_plus.dart';

import '../timer_engine.dart';
import 'timer_platform_native.dart'
    if (dart.library.js_interop) 'timer_platform_web.dart'
    as implementation;

abstract class TimerPlatform {
  Future<void> _wakeChange = Future.value();

  Future<void> initialize();
  void unlock();
  void schedule(List<SoundEvent> events, MonotonicClock clock);
  void cancel();
  void setVolume(int percent);

  void keepAwake(bool enabled) {
    // The Linux plugin allocates a new portal handle for each enable call.
    _wakeChange = _wakeChange
        .then((_) async {
          if (await WakelockPlus.enabled != enabled) {
            await WakelockPlus.toggle(enable: enabled);
          }
        })
        .catchError((Object _) {});
  }

  void dispose();
}

TimerPlatform createTimerPlatform() => implementation.PlatformBackend();
