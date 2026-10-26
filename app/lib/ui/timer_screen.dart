import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../timer_engine.dart';
import '../workout_controller.dart';
import 'controls.dart';
import 'instant_scroll.dart';
import 'native_style.dart';
import 'volume_control.dart';

class TimerScreen extends StatelessWidget {
  const TimerScreen({super.key, required this.controller});

  final WorkoutController controller;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final value = controller.display;
    final (label, color) = switch (value.phase) {
      TimerPhase.prepare => (
        strings.prepareTimeLabel,
        nativeTextColor(context),
      ),
      TimerPhase.active => (strings.activeTimeLabel, const Color(0xff1a9f0b)),
      TimerPhase.rest => (strings.restTimeLabel, const Color(0xffab0606)),
    };
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.min(constraints.maxWidth, 640.0);
        final status = label.toUpperCase();
        final set = strings.setCount(math.max(1, value.set));
        final seconds = '${value.seconds}';
        final gap = nativeDimension(context, 20);
        final bottomGap = nativeDimension(context, 28);
        final textHeight =
            NativeText.measure(context, strings.setLabel, 24, width) +
            NativeText.measure(context, set, 64, width) +
            NativeText.measure(context, status, 65, width, bold: true) +
            NativeText.measure(context, seconds, 150, width, bold: true) +
            gap * 2 +
            bottomGap;
        final size = math.max(
          64.0,
          math.min(
            (width - 126) / 2,
            math.min(200.0, constraints.maxHeight - textHeight),
          ),
        );
        final density = MediaQuery.devicePixelRatioOf(context);
        final buttonSize = (size * density).round() / density;
        return Center(
          child: InstantScrollView(
            child: SizedBox(
              width: width,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  NativeText(strings.setLabel, size: 24),
                  NativeText(set, size: 64),
                  SizedBox(height: gap),
                  NativeText(status, size: 65, color: color, bold: true),
                  SizedBox(height: gap),
                  NativeText(seconds, size: 150, bold: true),
                  SizedBox(height: bottomGap),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircleControl(
                        label: value.mode == TimerMode.paused
                            ? strings.resume
                            : strings.pause,
                        symbol: value.mode == TimerMode.paused
                            ? ControlSymbol.play
                            : ControlSymbol.pause,
                        size: buttonSize,
                        onPressed: controller.togglePause,
                      ),
                      SizedBox(width: nativeDimension(context, 30)),
                      CircleControl(
                        label: strings.stop,
                        symbol: ControlSymbol.stop,
                        size: buttonSize,
                        onPressed: controller.stop,
                      ),
                      SizedBox(width: nativeDimension(context, 16)),
                      SizedBox(
                        width: nativeDimension(context, 48),
                        height: buttonSize,
                        child: ValueListenableBuilder<double>(
                          valueListenable: controller.volumeState,
                          builder: (context, volume, _) => VolumeControl(
                            label: strings.volume,
                            value: volume,
                            onChanged: controller.changeVolume,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
