@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:easytimer/settings.dart';
import 'package:easytimer/timer_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_linux/path_provider_linux.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_linux/shared_preferences_linux.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _PathProvider extends PathProviderLinux {
  _PathProvider(this.directory);

  final String directory;
  FileSystemException? failure;

  @override
  Future<String?> getApplicationSupportPath() async {
    final error = failure;
    if (error != null) throw error;
    return directory;
  }
}

class _MalformedReads extends SharedPreferencesLinux {
  int reads = 0;

  @override
  Future<Map<String, Object>> getAll() async {
    reads++;
    throw const FormatException('Malformed preferences');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Linux preferences', () {
    late Directory directory;
    late File file;
    late _PathProvider paths;
    late PathProviderPlatform previousPaths;
    late SharedPreferencesStorePlatform previousStore;

    Future<TimerSettings> reload() {
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = SharedPreferencesLinux()
        ..pathProvider = paths;
      return TimerSettings.load();
    }

    Future<List<File>> backups() async => (await directory.list().toList())
        .whereType<File>()
        .where((entry) => entry.path.endsWith('.corrupt'))
        .toList();

    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'easytimer-linux-prefs-',
      );
      file = File('${directory.path}/shared_preferences.json');
      paths = _PathProvider(directory.path);
      previousPaths = PathProviderPlatform.instance;
      previousStore = SharedPreferencesStorePlatform.instance;
      PathProviderPlatform.instance = paths;
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = SharedPreferencesLinux()
        ..pathProvider = paths;
    });

    tearDown(() async {
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = previousStore;
      PathProviderPlatform.instance = previousPaths;
      await directory.delete(recursive: true);
    });

    test(
      'malformed JSON is backed up and later edits survive a fresh plugin',
      () async {
        await file.writeAsString('{broken');
        final olderBackup = File('${file.path}.earlier.corrupt');
        await olderBackup.writeAsString('earlier corruption');

        final settings = await TimerSettings.load();
        expect(settings.preferences, isNotNull);
        expect(
          (
            settings.options.active,
            settings.options.rest,
            settings.volumePercent,
          ),
          (45, 15, 100),
        );
        expect(await file.exists(), isFalse);
        final savedBackups = await backups();
        expect(savedBackups, hasLength(2));
        final recovered = savedBackups.singleWhere(
          (entry) => entry.path != olderBackup.path,
        );
        expect(await recovered.readAsString(), '{broken');
        expect(await olderBackup.readAsString(), 'earlier corruption');

        await settings.saveOptions(
          const WorkoutOptions(active: 55, rest: 25, sets: 3),
        );
        await settings.saveVolume(40);
        final next = await reload();
        expect(
          (
            next.options.active,
            next.options.rest,
            next.options.sets,
            next.volumePercent,
          ),
          (55, 25, 3, 40),
        );
        expect(await recovered.readAsString(), '{broken');
      },
    );

    test(
      'valid JSON keeps raw neighbours and is not rewritten during startup',
      () async {
        const raw =
            '{"flutter.activeTime":"bad","flutter.restTime":25.0,'
            '"flutter.sets":3,"flutter.volumePercent":40.0,'
            '"unrelated":{"enabled":true},"flutter.extra":["keep"]}';
        await file.writeAsString(raw);
        final settings = await TimerSettings.load();
        expect(settings.preferences, isNotNull);
        expect(
          (
            settings.options.active,
            settings.options.rest,
            settings.options.sets,
            settings.volumePercent,
          ),
          (45, 25, 3, 40),
        );
        await settings.saveVolume(40);
        expect(await file.readAsString(), raw);
        expect(await backups(), isEmpty);

        await settings.saveVolume(55);
        final stored =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final expected = jsonDecode(raw) as Map<String, dynamic>;
        expected['flutter.volumePercent'] = 55;
        expect(stored, expected);
        expect(stored['flutter.restTime'], isA<double>());
      },
    );

    test(
      'startup access failures leave the file intact and retry pending edits',
      () async {
        const raw =
            '{"flutter.activeTime":60,"flutter.restTime":20,'
            '"flutter.sets":8,"flutter.volumePercent":35,"other":"keep"}';
        await file.writeAsString(raw);
        paths.failure = const FileSystemException(
          'Permission denied',
          '',
          OSError('Permission denied', 13),
        );
        final settings = await TimerSettings.load();
        expect(settings.preferences, isNull);
        expect(settings.options.active, 45);
        await settings.saveOptions(
          const WorkoutOptions(active: 55, rest: 25, sets: 3),
        );
        expect(await file.readAsString(), raw);
        expect(await backups(), isEmpty);

        paths.failure = null;
        await settings.saveVolume(40);
        final next = await reload();
        expect(
          (
            next.options.active,
            next.options.rest,
            next.options.sets,
            next.volumePercent,
          ),
          (55, 25, 3, 40),
        );
        expect((jsonDecode(await file.readAsString()) as Map)['other'], 'keep');
      },
    );

    test(
      'failed real file writes can be retried with unchanged cached values',
      () async {
        await file.writeAsString(
          '{"flutter.activeTime":45,"flutter.restTime":15,"flutter.sets":0}',
        );
        final settings = await TimerSettings.load();
        final saved = await file.rename('${directory.path}/original.json');
        final blocked = await Directory(file.path).create();
        const options = WorkoutOptions(active: 55, rest: 25, sets: 3);
        await settings.saveOptions(options);
        expect(settings.preferences!.get('activeTime'), 55);
        expect(await blocked.exists(), isTrue);
        expect(await backups(), isEmpty);

        await blocked.delete();
        await saved.rename(file.path);
        await settings.saveOptions(options);
        final next = await reload();
        expect(
          (next.options.active, next.options.rest, next.options.sets),
          (55, 25, 3),
        );
      },
    );

    test(
      'parse recovery retries only once and does not quarantine valid JSON',
      () async {
        const raw = '{"flutter.activeTime":60,"flutter.restTime":20}';
        await file.writeAsString(raw);
        final store = _MalformedReads()..pathProvider = paths;
        SharedPreferencesStorePlatform.instance = store;
        final settings = await TimerSettings.load();
        expect(settings.preferences, isNull);
        expect(store.reads, 2);
        expect(await file.readAsString(), raw);
        expect(await backups(), isEmpty);

        await settings.saveVolume(40);
        expect(store.reads, 4);
        expect(await file.readAsString(), raw);
      },
    );

    test('an injected loader never invokes filesystem recovery', () async {
      await file.writeAsString('{broken');
      var loads = 0;
      final settings = await TimerSettings.load(
        loader: () async {
          loads++;
          throw const FormatException('Injected load failure');
        },
      );
      await settings.saveVolume(40);
      expect(loads, 2);
      expect(settings.preferences, isNull);
      expect(await file.readAsString(), '{broken');
      expect(await backups(), isEmpty);
    });
  }, skip: !Platform.isLinux);
}
