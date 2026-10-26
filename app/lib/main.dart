import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'clock.dart';
import 'platform/timer_platform.dart';
import 'settings.dart';
import 'workout_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final (_, settings) = await (_orientPhone(), TimerSettings.load()).wait;
  final clock = createWorkoutClock();
  final platform = createTimerPlatform(clock);
  platform.initialize().ignore();
  runApp(
    EasyTimerApp(
      controller: WorkoutController(settings, platform, clock: clock),
    ),
  );
}

Future<void> _orientPhone() async {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    final display =
        WidgetsBinding.instance.platformDispatcher.implicitView!.display;
    await SystemChrome.setPreferredOrientations(
      display.size.shortestSide / display.devicePixelRatio < 600
          ? [DeviceOrientation.portraitUp]
          : [],
    );
  }
}
