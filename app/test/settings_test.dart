import 'dart:async';

import 'package:easytimer/settings.dart';
import 'package:easytimer/timer_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Preferences extends Fake implements SharedPreferences {
  _Preferences([Map<String, Object> initial = const {}])
    : values = {...initial},
      stored = {...initial};

  final Map<String, Object> values;
  final Map<String, Object> stored;
  final writes = <(String, int)>[];
  Future<bool> Function(String, int)? write;

  @override
  Object? get(String key) => values[key];

  @override
  Future<bool> setInt(String key, int value) async {
    values[key] = value;
    writes.add((key, value));
    final result = await (write?.call(key, value) ?? Future.value(true));
    if (result) stored[key] = value;
    return result;
  }
}

const _initial = <String, Object>{
  'activeTime': 45,
  'restTime': 15,
  'sets': 0,
  'volumePercent': 100,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'edits made during an active write persist the latest full snapshot',
    () async {
      final started = Completer<void>();
      final release = Completer<bool>();
      final preferences = _Preferences(_initial)
        ..write = (key, value) {
          if (key == 'activeTime' && value == 50) {
            started.complete();
            return release.future;
          }
          return Future.value(true);
        };
      final settings = TimerSettings(preferences);
      final first = settings.saveOptions(const WorkoutOptions(active: 50));
      expect(settings.options.active, 50);
      await started.future;

      final second = settings.saveOptions(
        const WorkoutOptions(active: 50, rest: 20),
      );
      final third = settings.saveOptions(
        const WorkoutOptions(active: 50, rest: 20, sets: 3),
      );
      final volume = settings.saveVolume(40);
      expect(
        (settings.options.active, settings.options.rest, settings.options.sets),
        (50, 20, 3),
      );
      await pumpEventQueue();
      release.complete(true);
      await Future.wait([first, second, third, volume]);

      expect(preferences.stored, {
        'activeTime': 50,
        'restTime': 20,
        'sets': 3,
        'volumePercent': 40,
      });
      expect(preferences.writes, [
        ('activeTime', 50),
        ('restTime', 20),
        ('sets', 3),
        ('volumePercent', 40),
      ]);
    },
  );

  test(
    'unchanged numeric values and valid neighbours stay untouched',
    () async {
      final preferences = _Preferences({
        'activeTime': 60.0,
        'restTime': 20.0,
        'sets': 8.0,
        'volumePercent': 35.0,
        'other': 'preserved',
      });
      final settings = TimerSettings(preferences);
      await settings.saveOptions(
        const WorkoutOptions(active: 60, rest: 20, sets: 8),
      );
      await settings.saveVolume(35);
      expect(preferences.writes, isEmpty);

      await settings.saveOptions(
        const WorkoutOptions(active: 60, rest: 25, sets: 8),
      );
      await settings.saveVolume(40);
      expect(preferences.writes, [('restTime', 25), ('volumePercent', 40)]);
      expect(preferences.stored['activeTime'], isA<double>());
      expect(preferences.stored['sets'], isA<double>());
      expect(preferences.stored['other'], 'preserved');
      expect(settings.volumePercent, 35);
    },
  );

  test(
    'startup loader failures retain edits until storage becomes available',
    () async {
      final preferences = _Preferences({..._initial, 'other': 'preserved'});
      var loads = 0;
      final settings = await TimerSettings.load(
        loader: () async {
          if (++loads <= 2) throw StateError('Storage unavailable');
          return preferences;
        },
      );
      expect(settings.preferences, isNull);
      expect(
        (
          settings.options.active,
          settings.options.rest,
          settings.volumePercent,
        ),
        (45, 15, 100),
      );
      final options = settings.saveOptions(
        const WorkoutOptions(active: 55, rest: 25, sets: 3),
      );
      expect(settings.options.active, 55);
      await options;
      expect(settings.preferences, isNull);

      await settings.saveVolume(40);
      expect(loads, 3);
      expect(settings.preferences, same(preferences));
      expect(preferences.stored, {
        'activeTime': 55,
        'restTime': 25,
        'sets': 3,
        'volumePercent': 40,
        'other': 'preserved',
      });
    },
  );

  for (final throwsError in [false, true]) {
    test(
      'a ${throwsError ? 'throwing' : 'false'} write is retried despite its cache update',
      () async {
        final preferences = _Preferences(_initial)
          ..write = (_, _) async {
            if (throwsError) throw StateError('Storage unavailable');
            return false;
          };
        final settings = TimerSettings(preferences);
        await settings.saveOptions(
          const WorkoutOptions(active: 55, rest: 25, sets: 3),
        );
        expect(preferences.get('activeTime'), 55);
        expect(preferences.stored, _initial);

        preferences.write = null;
        await settings.saveVolume(40);
        expect(preferences.stored, {
          'activeTime': 55,
          'restTime': 25,
          'sets': 3,
          'volumePercent': 40,
        });
        final count = preferences.writes.length;
        await settings.saveOptions(
          const WorkoutOptions(active: 55, rest: 25, sets: 3),
        );
        await settings.saveVolume(40);
        expect(preferences.writes, hasLength(count));
      },
    );
  }

  test('newer edits replace values retained after a failed write', () async {
    final preferences = _Preferences(_initial)..write = (_, _) async => false;
    final settings = TimerSettings(preferences);
    await settings.saveOptions(
      const WorkoutOptions(active: 55, rest: 25, sets: 3),
    );
    await settings.saveVolume(40);

    preferences.write = null;
    await settings.saveOptions(
      const WorkoutOptions(active: 65, rest: 30, sets: 4),
    );
    await settings.saveVolume(70);
    expect(preferences.stored, {
      'activeTime': 65,
      'restTime': 30,
      'sets': 4,
      'volumePercent': 70,
    });
  });
}
