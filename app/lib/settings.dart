import 'package:shared_preferences/shared_preferences.dart';

import 'timer_engine.dart';

class TimerSettings {
  TimerSettings(this.preferences)
    : options = WorkoutOptions.fromText(
        '${preferences.getInt('activeTime') ?? 45}',
        '${preferences.getInt('restTime') ?? 15}',
        '${preferences.getInt('sets') ?? 0}',
      ),
      volume = (preferences.getDouble('volume') ?? 1).clamp(0, 1);

  final SharedPreferences preferences;
  WorkoutOptions options;
  double volume;

  static Future<TimerSettings> load() async =>
      TimerSettings(await SharedPreferences.getInstance());

  Future<void> saveOptions(WorkoutOptions value) async {
    options = value;
    await Future.wait([
      preferences.setInt('activeTime', value.active),
      preferences.setInt('restTime', value.rest),
      preferences.setInt('sets', value.sets),
    ]);
  }

  Future<void> saveVolume(double value) async {
    volume = value.clamp(0, 1);
    await preferences.setDouble('volume', volume);
  }
}
