import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'platform/timer_platform.dart';
import 'settings.dart';
import 'workout_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await TimerSettings.load();
  final platform = createTimerPlatform();
  final fonts = FontLoader('DroidSansMono')
    ..addFont(rootBundle.load('assets/fonts/DroidSansMono.ttf'));
  await Future.wait([platform.initialize(), fonts.load()]);
  runApp(EasyTimerApp(controller: WorkoutController(settings, platform)));
}
