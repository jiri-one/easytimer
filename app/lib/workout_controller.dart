import 'dart:async';

import 'package:flutter/foundation.dart';

import 'platform/timer_platform.dart';
import 'settings.dart';
import 'timer_engine.dart';

class WorkoutController {
  WorkoutController(this.settings, this.platform, {MonotonicClock? clock})
    : engine = TimerEngine(clock ?? createWorkoutClock()),
      volume = ValueNotifier(settings.volumePercent) {
    platform.setVolume(volume.value);
  }

  final TimerSettings settings;
  final TimerPlatform platform;
  final TimerEngine engine;
  final showingTimer = ValueNotifier(false);
  final display = ValueNotifier(stoppedSnapshot);
  final ValueNotifier<int> volume;
  Timer? _update;
  Timer? _volumeSave;

  void start(WorkoutOptions options) {
    platform.unlock();
    platform.cancel();
    unawaited(settings.saveOptions(options));
    engine.start(options);
    showingTimer.value = true;
    platform.keepAwake(true);
    refresh();
  }

  void togglePause() {
    if (!showingTimer.value) return;
    if (engine.snapshot.mode == TimerMode.running) {
      engine.pause();
      platform.cancel();
    } else {
      platform.unlock();
      engine.resume();
    }
    refresh();
  }

  void stop() {
    engine.stop();
    _update?.cancel();
    platform.cancel();
    platform.keepAwake(false);
    showingTimer.value = false;
    display.value = stoppedSnapshot;
  }

  void stepVolume(int percent) => changeVolume(volume.value + percent);

  void changeVolume(int percent) {
    final next = percent.clamp(0, 100);
    if (next == volume.value) return;
    volume.value = next;
    settings.volumePercent = next;
    platform.setVolume(next);
    _volumeSave?.cancel();
    _volumeSave = Timer(const Duration(milliseconds: 250), () {
      unawaited(settings.saveVolume(volume.value));
    });
  }

  void refresh() {
    _update?.cancel();
    if (!showingTimer.value) return;
    final now = engine.clock.nowMs;
    final next = engine.snapshotAt(now);
    if (next.mode != TimerMode.paused) {
      platform.schedule(engine.soundsBetween(now, now + 300000), engine.clock);
    }
    if (!next.sameDisplay(display.value)) display.value = next;
    if (next.mode == TimerMode.complete) {
      platform.keepAwake(false);
      showingTimer.value = false;
    } else if (next.mode == TimerMode.running) {
      final delay = next.remainingMs - (next.seconds - 1) * 1000;
      _update = Timer(Duration(milliseconds: delay.clamp(1, 1000)), refresh);
    }
  }

  void dispose() {
    _update?.cancel();
    if (_volumeSave?.isActive ?? false) {
      _volumeSave!.cancel();
      unawaited(settings.saveVolume(volume.value));
    }
    platform.keepAwake(false);
    platform.dispose();
    showingTimer.dispose();
    display.dispose();
    volume.dispose();
  }
}
