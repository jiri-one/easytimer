import 'dart:async';

import 'package:flutter/foundation.dart';

import 'platform/timer_platform.dart';
import 'settings.dart';
import 'screen_wake_lock.dart';
import 'timer_engine.dart';

class WorkoutController {
  WorkoutController(
    this.settings,
    this.platform, {
    MonotonicClock? clock,
    void Function(bool)? keepAwake,
  }) : engine = TimerEngine(clock ?? createWorkoutClock()),
       volume = ValueNotifier(settings.volumePercent),
       _keepAwake = keepAwake ?? ScreenWakeLock().setEnabled {
    platform.setVolume(volume.value);
    showingTimer.addListener(() => _keepAwake(showingTimer.value));
  }

  final TimerSettings settings;
  final TimerPlatform platform;
  final TimerEngine engine;
  final showingTimer = ValueNotifier(false);
  final display = ValueNotifier(stoppedSnapshot);
  final ValueNotifier<int> volume;
  final void Function(bool) _keepAwake;
  Timer? _update;
  Timer? _volumeSave;

  void start(WorkoutOptions options) {
    platform.cancel();
    unawaited(settings.saveOptions(options));
    engine.start(options);
    showingTimer.value = true;
    refresh();
  }

  void togglePause() {
    if (!showingTimer.value) return;
    if (engine.snapshot.mode == TimerMode.running) {
      engine.pause();
      platform.cancel();
    } else {
      engine.resume();
    }
    refresh();
  }

  void stop() {
    engine.stop();
    _update?.cancel();
    platform.cancel();
    showingTimer.value = false;
    display.value = stoppedSnapshot;
  }

  void stepVolume(int percent) => changeVolume(volume.value + percent);

  void changeVolume(int percent) {
    final next = percent.clamp(0, 100);
    if (next == volume.value) return;
    volume.value = next;
    platform.setVolume(next);
    _volumeSave?.cancel();
    _volumeSave = Timer(const Duration(milliseconds: 250), () {
      unawaited(settings.saveVolume(volume.value));
    });
  }

  void refresh({bool recoverWakeLock = false}) {
    _update?.cancel();
    if (!showingTimer.value) return;
    final now = engine.clock.nowMs;
    final next = engine.snapshotAt(now);
    if (next.mode != TimerMode.paused) {
      platform.schedule(engine.soundsBetween(now, now + 300000));
    }
    if (!next.sameDisplay(display.value)) display.value = next;
    if (next.mode == TimerMode.complete) {
      showingTimer.value = false;
    } else if (next.mode == TimerMode.running) {
      final delay = next.remainingMs - (next.seconds - 1) * 1000;
      _update = Timer(Duration(milliseconds: delay.clamp(1, 1000)), refresh);
    }
    // Browsers release the lock while hidden without changing our desired state.
    if (recoverWakeLock && showingTimer.value) _keepAwake(true);
  }

  void dispose() {
    _update?.cancel();
    if (_volumeSave?.isActive ?? false) {
      _volumeSave!.cancel();
      unawaited(settings.saveVolume(volume.value));
    }
    showingTimer.value = false;
    platform.cancel();
    showingTimer.dispose();
    display.dispose();
    volume.dispose();
  }
}
