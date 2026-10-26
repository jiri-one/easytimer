import 'package:shared_preferences/shared_preferences.dart';

import 'preferences_loader.dart'
    if (dart.library.io) 'preferences_loader_io.dart';
import 'timer_engine.dart';

class TimerSettings {
  TimerSettings(SharedPreferences? preferences)
    : _preferences = preferences,
      options = WorkoutOptions.normalized(
        _duration(preferences?.get('activeTime')),
        _duration(preferences?.get('restTime')),
        _duration(preferences?.get('sets')),
      ),
      volumePercent = _savedVolume(preferences);

  SharedPreferences? _preferences;
  SharedPreferences? get preferences => _preferences;
  Future<SharedPreferences> Function() _loader = loadPreferences;
  Future<void> _writes = Future<void>.value();
  final _pending = <String, int>{};
  final _unconfirmed = <String>{};
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
    final read = loader ?? loadPreferences;
    try {
      return TimerSettings(await read()).._loader = read;
    } catch (_) {
      return TimerSettings(null).._loader = read;
    }
  }

  Future<void> saveOptions(WorkoutOptions value) {
    options = value;
    return _save({
      'activeTime': value.active,
      'restTime': value.rest,
      'sets': value.sets,
    });
  }

  Future<void> saveVolume(int percent) => _save({'volumePercent': percent});

  Future<void> _save(Map<String, int> values) {
    return _writes = _writes.then((_) async {
      _pending.addAll(values);
      try {
        final preferences = _preferences ??= await _loader();
        for (final entry in Map<String, int>.of(_pending).entries) {
          final key = entry.key;
          final value = entry.value;
          if (_unconfirmed.contains(key) || preferences.get(key) != value) {
            // The plugin updates its cache even when the disk write fails.
            _unconfirmed.add(key);
            if (!await preferences.setInt(key, value)) continue;
          }
          _unconfirmed.remove(key);
          _pending.remove(key);
        }
      } catch (_) {
        // Keep pending edits for the next save without interrupting a workout.
      }
    });
  }
}
