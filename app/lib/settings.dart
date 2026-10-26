import 'package:shared_preferences/shared_preferences.dart';

import 'timer_engine.dart';

class TimerSettings {
  TimerSettings(this.preferences)
    : options = WorkoutOptions.normalized(
        _duration(preferences?.get('activeTime')),
        _duration(preferences?.get('restTime')),
        _duration(preferences?.get('sets')),
      ),
      volumePercent = _savedVolume(preferences);

  final SharedPreferences? preferences;
  WorkoutOptions options;
  final int volumePercent;

  static int? _duration(Object? value) =>
      value is num && value.isFinite && value >= 0 && value <= 9999
      ? value.round()
      : null;

  static int _percent(num value) =>
      value.isFinite ? value.round().clamp(0, 100) : 100;

  static int _savedVolume(SharedPreferences? preferences) {
    final percent = preferences?.get('volumePercent');
    return percent is num ? _percent(percent) : 100;
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
    for (final (key, number) in [
      ('activeTime', value.active),
      ('restTime', value.rest),
      ('sets', value.sets),
    ]) {
      await _save(key, number);
    }
  }

  Future<void> saveVolume(int percent) => _save('volumePercent', percent);

  Future<void> _save(String key, int value) async {
    if (preferences == null || preferences!.get(key) == value) return;
    try {
      await preferences!.setInt(key, value);
    } catch (_) {
      // Unavailable storage must not interrupt a workout or volume control.
    }
  }
}
