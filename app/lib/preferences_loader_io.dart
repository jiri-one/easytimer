import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SharedPreferences> loadPreferences() async {
  try {
    return await SharedPreferences.getInstance();
  } on FormatException {
    if (!Platform.isLinux) rethrow;
    final directory = await getApplicationSupportDirectory();
    final file = File('${directory.path}/shared_preferences.json');
    if (await file.exists()) {
      try {
        final raw = await file.readAsString();
        // Another instance may have repaired the file since the failed load.
        if (raw.isNotEmpty) jsonDecode(raw);
      } on FormatException {
        await file.rename(
          '${file.path}.${DateTime.now().microsecondsSinceEpoch}.$pid.corrupt',
        );
      }
    }
    return SharedPreferences.getInstance();
  }
}
