import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SharedPreferences> loadPreferences() async {
  // The plugin caches a typed map before filtering keys, including unrelated keys.
  if (Platform.isLinux) await _repairLinuxStore();
  try {
    return await SharedPreferences.getInstance();
  } on FormatException {
    if (!Platform.isLinux) rethrow;
    await _repairLinuxStore();
    return SharedPreferences.getInstance();
  }
}

bool _isPreferenceValue(Object? value) =>
    value is bool ||
    value is String ||
    value is num && value.isFinite ||
    value is List && value.every((item) => item is String);

Future<void> _repairLinuxStore() async {
  final directory = await getApplicationSupportDirectory();
  final file = File('${directory.path}/shared_preferences.json');
  late final List<int> bytes;
  try {
    bytes = await file.readAsBytes();
  } on FileSystemException catch (error) {
    // Only ENOENT permits a fresh store; access failures must remain retryable.
    if (error.osError?.errorCode == 2) return;
    rethrow;
  }
  final valid = <String, Object>{};
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is Map<String, dynamic>) {
      for (final entry in decoded.entries) {
        if (_isPreferenceValue(entry.value)) valid[entry.key] = entry.value;
      }
      if (valid.length == decoded.length) return;
    }
  } on FormatException {
    // Keep the original bytes even when decoding cannot recover any entries.
  }

  final backup = File(
    '${file.path}.${DateTime.now().microsecondsSinceEpoch}.$pid.corrupt',
  );
  await backup.create(exclusive: true);
  await backup.writeAsBytes(bytes, flush: true);
  final temporary = File('${backup.path}.tmp');
  try {
    await temporary.create(exclusive: true);
    await temporary.writeAsString(jsonEncode(valid), flush: true);
    await temporary.rename(file.path);
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}
