import 'package:shared_preferences/shared_preferences.dart';

Future<SharedPreferences> loadPreferences() => SharedPreferences.getInstance();
