@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'all app bundles carry the unmodified GPL and complete asset notices',
    () async {
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
      ]) {
        final text = await rootBundle.loadString('assets/licenses/$name');
        expect(text.length, greaterThan(1000));
      }
    },
  );

  test(
    'only the bundled native font is declared and generated l10n is marked',
    () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('uses-material-design: false'));
      expect(pubspec, isNot(contains('MaterialIcons')));
      final fonts = Directory('assets/fonts')
          .listSync()
          .map((file) => file.path);
      expect(fonts, ['assets/fonts/DroidSansMono.ttf']);
      expect(
        File('../.gitattributes').readAsStringSync(),
        contains(
          'app/lib/l10n/app_localizations*.dart linguist-generated=true',
        ),
      );
    },
  );
}
