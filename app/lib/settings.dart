import 'package:shared_preferences/shared_preferences.dart';

import 'timer_engine.dart';

class TimerSettings {
  TimerSettings(this.preferences)
    : options = WorkoutOptions.fromText(
        '${_duration(preferences?.get('activeTime'), 45)}',
        '${_duration(preferences?.get('restTime'), 15)}',
        '${_duration(preferences?.get('sets'), 0)}',
      ),
      volumePercent = _savedVolume(preferences);

  final SharedPreferences? preferences;
  WorkoutOptions options;
  int volumePercent;
  double get volume => volumePercent / 100;

  static int _duration(Object? value, int fallback) =>
      value is num && value.isFinite && value >= 0 && value <= 9999
      ? value.round()
      : fallback;

  static int _percent(num value) =>
      value.isFinite ? value.round().clamp(0, 100) : 100;

  static int _savedVolume(SharedPreferences? preferences) {
    final percent = preferences?.get('volumePercent');
    if (percent is num && percent.isFinite) return _percent(percent);
    // The former key stores a fraction, including JSON's integer spelling of 1.0.
    final legacy = preferences?.get('volume');
    return legacy is num ? _percent(legacy * 100) : 100;
  }

  static Future<TimerSettings> load({
    Future<SharedPreferences> Function()? loader,
  }) async {
    try {
      return TimerSettings(await (loader ?? SharedPreferences.getInstance)());
    } catch (_) {
      return TimerSettings(null);
    }
  }

  Future<void> saveOptions(WorkoutOptions value) async {
    options = value;
    final store = preferences;
    if (store == null) return;
    try {
      await Future.wait([
        store.setInt('activeTime', value.active),
        store.setInt('restTime', value.rest),
        store.setInt('sets', value.sets),
      ]);
    } catch (_) {
      // Unavailable storage must not interrupt an active workout.
    }
  }

  Future<void> saveVolume(double value) async {
    volumePercent = _percent(value * 100);
    try {
      await preferences?.setInt('volumePercent', volumePercent);
    } catch (_) {
      // Volume remains usable when persistence fails.
    }
  }
}
