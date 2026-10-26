import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'platform/timer_platform.dart';
import 'settings.dart';
import 'workout_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    final display =
        WidgetsBinding.instance.platformDispatcher.implicitView!.display;
    await SystemChrome.setPreferredOrientations(
      display.size.shortestSide / display.devicePixelRatio < 600
          ? [DeviceOrientation.portraitUp]
          : [],
    );
  }
  final settings = await TimerSettings.load();
  final platform = createTimerPlatform();
  unawaited(platform.initialize().catchError((Object _) {}));
  runApp(EasyTimerApp(controller: WorkoutController(settings, platform)));
}
