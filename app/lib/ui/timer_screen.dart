import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../timer_engine.dart';
import '../workout_controller.dart';
import 'controls.dart';

class TimerScreen extends StatelessWidget {
  const TimerScreen({super.key, required this.controller});

  final WorkoutController controller;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final value = controller.display;
    final (label, color) = switch (value.phase) {
      TimerPhase.prepare => (strings.prepareTimeLabel, const Color(0xff6f6f6f)),
      TimerPhase.active => (strings.activeTimeLabel, const Color(0xff1a9f0b)),
      TimerPhase.rest => (strings.restTimeLabel, const Color(0xffab0606)),
    };
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.min(constraints.maxWidth, 640.0);
        final height = constraints.maxHeight;
        final typeScale = math.min(width / 400, height / 690).clamp(.55, 1.6);
        final textHeight = 528 * typeScale;
        final buttonSize = math.max(
          64.0,
          math.min(
            (width - 126) / 2,
            math.min(200.0, height - textHeight - 24),
          ),
        );
        Widget text(
          String value,
          double size,
          double boxHeight, {
          Color? color,
          FontWeight weight = FontWeight.normal,
        }) => SizedBox(
          height: boxHeight * typeScale,
          width: width - 32,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: TextStyle(
                fontSize: size * typeScale,
                fontWeight: weight,
                color: color,
                height: 1.15,
              ),
            ),
          ),
        );
        return Center(
          child: SingleChildScrollView(
            child: SizedBox(
              width: width,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  text(strings.setLabel, 24, 36),
                  text(strings.setCount(math.max(1, value.set)), 64, 88),
                  SizedBox(height: 20 * typeScale),
                  text(
                    label.toUpperCase(),
                    65,
                    82,
                    color: color,
                    weight: FontWeight.bold,
                  ),
                  SizedBox(height: 20 * typeScale),
                  text('${value.seconds}', 150, 154, weight: FontWeight.bold),
                  SizedBox(height: 28 * typeScale),
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
                      const SizedBox(width: 30),
                      CircleControl(
                        label: strings.stop,
                        symbol: ControlSymbol.stop,
                        size: buttonSize,
                        onPressed: controller.stop,
                      ),
                      const SizedBox(width: 16),
                      SizedBox(
                        width: 48,
                        height: buttonSize,
                        child: RotatedBox(
                          quarterTurns: 3,
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              activeTrackColor: Theme.of(context)
                                  .colorScheme
                                  .onSurface,
                              inactiveTrackColor: const Color(0xff6f6f6f),
                              thumbColor: Theme.of(context)
                                  .colorScheme
                                  .onSurface,
                              overlayShape: SliderComponentShape.noOverlay,
                              thumbShape: _SpeakerThumb(controller.volume == 0),
                              showValueIndicator: ShowValueIndicator.never,
                            ),
                            child: Slider(
                              value: controller.volume,
                              divisions: 100,
                              semanticFormatterCallback: (value) =>
                                  '${strings.volume}: ${(value * 100).round()}%',
                              onChanged: controller.changeVolume,
                            ),
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

class _SpeakerThumb extends SliderComponentShape {
  const _SpeakerThumb(this.muted);

  final bool muted;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size(24, 24);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(
          (muted ? Icons.volume_off : Icons.volume_up).codePoint,
        ),
        style: TextStyle(
          fontFamily: 'MaterialIcons',
          fontSize: 24,
          color: sliderTheme.thumbColor,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    context.canvas.save();
    context.canvas.translate(center.dx, center.dy);
    context.canvas.rotate(math.pi / 2);
    painter.paint(
      context.canvas,
      Offset(-painter.width / 2, -painter.height / 2),
    );
    context.canvas.restore();
  }
}
