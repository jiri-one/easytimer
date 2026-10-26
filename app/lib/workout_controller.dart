import 'dart:async';

import 'package:flutter/foundation.dart';

import 'platform/timer_platform.dart';
import 'settings.dart';
import 'timer_engine.dart';

class WorkoutController extends ChangeNotifier {
  WorkoutController(this.settings, this.platform, {MonotonicClock? clock})
    : engine = TimerEngine(clock ?? createWorkoutClock()),
      volumeState = ValueNotifier(settings.volume) {
    platform.setVolume(volume * volume);
    platform.onVisibilityChanged = refresh;
  }

  final TimerSettings settings;
  final TimerPlatform platform;
  final TimerEngine engine;
  final ValueNotifier<double> volumeState;
  Timer? _update;
  bool showingTimer = false;
  TimerSnapshot _display = const TimerSnapshot(
    TimerMode.stopped,
    TimerPhase.prepare,
    0,
    5000,
  );

  TimerSnapshot get display => _display;
  double get volume => settings.volume;

  void stepVolume(int percent) =>
      changeVolume((settings.volumePercent + percent).clamp(0, 100) / 100);

  void start(WorkoutOptions options) {
    platform.unlock();
    platform.beginWorkout();
    unawaited(settings.saveOptions(options));
    engine.start(options);
    showingTimer = true;
    platform.keepAwake(true);
    refresh(force: true);
  }

  void togglePause() {
    if (!showingTimer) return;
    if (engine.snapshot.mode == TimerMode.running) {
      engine.pause();
      platform.cancel();
    } else if (engine.snapshot.mode == TimerMode.paused) {
      platform.unlock();
      engine.resume();
    }
    refresh(force: true);
  }

  void stop() {
    engine.stop();
    _update?.cancel();
    platform.cancel();
    platform.keepAwake(false);
    showingTimer = false;
    notifyListeners();
  }

  void changeVolume(double value) {
    final next = value.isFinite
        ? (value * 100).round().clamp(0, 100) / 100
        : 1.0;
    if (next == volume) return;
    unawaited(settings.saveVolume(next));
    platform.setVolume(next * next);
    volumeState.value = next;
  }

  void refresh({bool force = false}) {
    _update?.cancel();
    if (!showingTimer) return;
    final now = engine.clock.nowMs;
    final next = engine.snapshot;
    if (next.mode != TimerMode.paused) {
      platform.schedule(
        engine.soundsBetween(now - 49, now + 300000),
        engine.clock,
      );
    }
    if (next.mode == TimerMode.complete) {
      final end = engine.completionMs!;
      platform.schedule([SoundEvent(SoundKind.end, end, end)], engine.clock);
      platform.cancel(keepEnd: true);
      platform.keepAwake(false);
      showingTimer = false;
    }
    final changed = !next.sameDisplay(_display);
    _display = next;
    if (changed || force) notifyListeners();
    if (next.mode == TimerMode.running) {
      final delay = next.remainingMs - (next.seconds - 1) * 1000;
      _update = Timer(Duration(milliseconds: delay.clamp(1, 1000)), refresh);
    }
  }

  @override
  void dispose() {
    _update?.cancel();
    platform.onVisibilityChanged = null;
    platform.keepAwake(false);
    platform.dispose();
    volumeState.dispose();
    super.dispose();
  }
}
