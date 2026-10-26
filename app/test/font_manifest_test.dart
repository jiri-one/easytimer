@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'default and monospace fonts resolve to the bundled native font',
    () async {
      final manifest =
          jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
      final families = {
        for (final family in manifest.cast<Map<String, dynamic>>())
          family['family'] as String: family['fonts'] as List,
      };
      expect(families.keys, unorderedEquals(['Roboto', 'DroidSansMono']));
      expect(families['Roboto'], families['DroidSansMono']);
      expect(families['DroidSansMono'], [
        {'asset': 'assets/fonts/DroidSansMono.ttf'},
      ]);
      for (final fonts in families.values) {
        for (final font in fonts.cast<Map<String, dynamic>>()) {
          final bytes = await rootBundle.load(font['asset'] as String);
          expect(bytes.lengthInBytes, greaterThan(0));
        }
      }
    },
  );
}
