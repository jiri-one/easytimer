@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the only font family is Roboto with the bundled native font', () async {
    final manifest =
        jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    final families = {
      for (final family in manifest.cast<Map<String, dynamic>>())
        family['family'] as String: family['fonts'] as List,
    };
    expect(manifest, hasLength(1));
    expect(families.keys, ['Roboto']);
    expect(families['Roboto'], [
      {'asset': 'assets/fonts/DroidSansMono.ttf'},
    ]);
    for (final fonts in families.values) {
      for (final font in fonts.cast<Map<String, dynamic>>()) {
        final bytes = await rootBundle.load(font['asset'] as String);
        expect(bytes.lengthInBytes, greaterThan(0));
      }
    }
    final assets = await AssetManifest.loadFromAssetBundle(rootBundle);
    expect(
      assets.listAssets().where(
        (asset) => asset.endsWith('.ttf') || asset.endsWith('.otf'),
      ),
      ['assets/fonts/DroidSansMono.ttf'],
    );
  });

  test('all app bundles carry the GPL and complete asset notices', () async {
    expect(
      await rootBundle.loadString('assets/licenses/EasyTimer-GPL-3.0.txt'),
      File('../LICENSE').readAsStringSync(),
    );
    expect(
      await rootBundle.loadString('assets/licenses/NOTICE.txt'),
      File('../NOTICE').readAsStringSync(),
    );
    for (final name in [
      'DroidSansMono-Apache-2.0.txt',
      'MaterialIcons-Apache-2.0.txt',
      'IntervalTimer-MIT.txt',
      'NoSleep-MIT.txt',
    ]) {
      final text = await rootBundle.loadString('assets/licenses/$name');
      expect(text.length, greaterThan(1000));
      if (name == 'NoSleep-MIT.txt') {
        expect(text, contains('Copyright (c) Rich Tibbett'));
      }
    }
  });

  test('local font files and generated localization metadata stay minimal', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('uses-material-design: false'));
    expect(pubspec, isNot(contains('MaterialIcons')));
    expect(Directory('assets/fonts').listSync().map((file) => file.path), [
      'assets/fonts/DroidSansMono.ttf',
    ]);
    expect(
      File('../.gitattributes').readAsStringSync(),
      contains('app/lib/l10n/app_localizations*.dart linguist-generated=true'),
    );
  });
}
