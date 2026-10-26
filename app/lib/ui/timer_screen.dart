import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../constants.dart';
import '../l10n/app_localizations.dart';
import '../timer_engine.dart';
import '../workout_controller.dart';
import 'controls.dart';
import 'instant_scroll.dart';
import 'native_style.dart';
import 'palette.dart';
import 'volume_control.dart';

class TimerScreen extends StatelessWidget {
  const TimerScreen({super.key, required this.controller});

  final WorkoutController controller;

  @override
  Widget build(BuildContext context) => InstantScrollView(
    // This size plan belongs outside the display listeners: ticking changes
    // only the digits, never the available space or the configured samples.
    builder: (context, constraints) {
      final strings = AppLocalizations.of(context);
      final colors = AppPalette.of(context);
      final width = constraints.maxWidth;
      final height = constraints.maxHeight;
      final wide = width > height * 1.2;
      final contentWidth = width * (wide ? .96 : .92);
      final padding = height * (wide ? .01 : .015);
      final availableHeight = height - padding * 2;
      final columnGap = wide ? contentWidth * .02 : 0.0;
      final buttonGap = wide ? height * .028 : contentWidth * .04;
      final volumeGap = wide ? height * .018 : contentWidth * .02;
      final controlsWidth = wide
          ? math.max(contentWidth * .26, 64 + 48 + volumeGap)
          : contentWidth;
      final timerWidth = wide
          ? contentWidth - columnGap - controlsWidth
          : contentWidth;
      final stackButtons =
          wide || controlsWidth < 2 * 64 + 48 + buttonGap + volumeGap;
      final buttonCount = stackButtons ? 1 : 2;
      final buttonRoom =
          controlsWidth - volumeGap - (stackButtons ? 0 : buttonGap);
      final buttonSize = math.max(
        64.0,
        math.min(
          height * (wide ? .30 : .18),
          math.min(
            math.min(
              buttonRoom / (buttonCount + .5),
              (buttonRoom - 48) / buttonCount,
            ),
            stackButtons ? (availableHeight - buttonGap) / 2 : availableHeight,
          ),
        ),
      );
      final volumeScale = math.max(1.0, buttonSize / 96);
      final controlsHeight = stackButtons
          ? buttonSize * 2 + buttonGap
          : buttonSize;
      final setLabelHeight = height * (wide ? .06 : .065);
      final setNumberHeight = height * (wide ? .12 : .14);
      final headerHeight = wide
          ? setNumberHeight
          : setLabelHeight + setNumberHeight;
      final phaseHeight = height * .11;
      // Accented uppercase phase labels can paint above a tight text line.
      final headerGap = height * .012;
      final digitGap = height * .01;
      final controlsGap = wide ? 0.0 : height * .02;
      final headerSpace = headerHeight + headerGap + phaseHeight + digitGap;
      final contentHeight = math.max(
        availableHeight,
        wide
            ? controlsHeight
            : headerSpace + height * .16 + controlsGap + controlsHeight,
      );
      final digitHeight =
          contentHeight -
          headerSpace -
          (wide ? 0 : controlsHeight + controlsGap);
      final phaseLabels = {
        TimerPhase.prepare: strings.prepareTimeLabel.toUpperCase(),
        TimerPhase.active: strings.activeTimeLabel.toUpperCase(),
        TimerPhase.rest: strings.restTimeLabel.toUpperCase(),
      };
      final phaseSize = phaseLabels.values
          .map(
            (label) => NativeText.fitSize(
              context,
              label,
              maxSize: phaseHeight,
              width: timerWidth,
              height: phaseHeight,
              bold: true,
            ),
          )
          .reduce(math.min);
      final options = controller.engine.options;
      final digitSizes = {
        for (final entry in {
          TimerPhase.prepare: (prepareMs + 999) ~/ 1000,
          TimerPhase.active: options.active,
          TimerPhase.rest: options.rest,
        }.entries)
          entry.key: NativeText.fitSize(
            context,
            // All digits in the bundled mono font have the same advance.
            '8' * entry.value.toString().length,
            maxSize: digitHeight,
            width: timerWidth,
            height: digitHeight,
            bold: true,
          ),
      };
      final inlineGap = wide ? height * .015 : 0.0;
      final setLabel = NativeText(
        strings.setLabel,
        size: NativeText.fitSize(
          context,
          strings.setLabel,
          maxSize: setLabelHeight,
          width: timerWidth * (wide ? .65 : 1),
          height: setLabelHeight,
        ),
      );
      final setNumber = _TimerValue<int>(
        controller: controller,
        select: (value) => math.max(1, value.set),
        builder: (context, set) => NativeText(
          '$set',
          size: NativeText.fitSize(
            context,
            '$set',
            maxSize: setNumberHeight,
            width: timerWidth * (wide ? .35 : 1) - inlineGap,
            height: setNumberHeight,
          ),
        ),
      );
      final pause = _TimerValue<TimerMode>(
        controller: controller,
        select: (value) => value.mode,
        builder: (context, mode) => CircleControl(
          label: mode == TimerMode.paused ? strings.resume : strings.pause,
          symbol: mode == TimerMode.paused
              ? ControlSymbol.play
              : ControlSymbol.pause,
          size: buttonSize,
          onPressed: controller.togglePause,
        ),
      );
      final stop = CircleControl(
        label: strings.stop,
        symbol: ControlSymbol.stop,
        size: buttonSize,
        onPressed: controller.stop,
      );
      final controls = RepaintBoundary(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (stackButtons)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  pause,
                  SizedBox(height: buttonGap),
                  stop,
                ],
              )
            else ...[
              pause,
              SizedBox(width: buttonGap),
              stop,
            ],
            SizedBox(width: volumeGap),
            SizedBox(
              width: 48 * volumeScale,
              height: controlsHeight,
              child: ValueListenableBuilder<int>(
                valueListenable: controller.volume,
                builder: (context, volume, _) => VolumeControl(
                  label: strings.volume,
                  percent: volume,
                  onChanged: controller.changeVolume,
                  onStep: controller.stepVolume,
                  scale: volumeScale,
                ),
              ),
            ),
          ],
        ),
      );
      final timer = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (wide)
            SizedBox(
              height: headerHeight,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  setLabel,
                  SizedBox(width: inlineGap),
                  setNumber,
                ],
              ),
            )
          else ...[
            SizedBox(
              height: setLabelHeight,
              child: Center(child: setLabel),
            ),
            SizedBox(
              height: setNumberHeight,
              child: Center(child: setNumber),
            ),
          ],
          SizedBox(height: headerGap),
          SizedBox(
            height: phaseHeight,
            child: Center(
              child: _TimerValue<TimerPhase>(
                controller: controller,
                select: (value) => value.phase,
                builder: (context, phase) => NativeText(
                  phaseLabels[phase]!,
                  size: phaseSize,
                  color: switch (phase) {
                    TimerPhase.prepare => nativeTextColor(context),
                    TimerPhase.active => colors.active,
                    TimerPhase.rest => colors.rest,
                  },
                  bold: true,
                ),
              ),
            ),
          ),
          SizedBox(height: digitGap),
          SizedBox(
            height: digitHeight,
            child: RepaintBoundary(
              child: Center(
                child: SizedBox(
                  // Keep the text bounds as well as its font stable at 10 → 9.
                  width: timerWidth,
                  child: _TimerValue<(TimerPhase, int)>(
                    controller: controller,
                    select: (value) => (value.phase, value.seconds),
                    builder: (context, value) => NativeText(
                      '${value.$2}',
                      size: digitSizes[value.$1]!,
                      bold: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (!wide) ...[SizedBox(height: controlsGap), controls],
        ],
      );
      return Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: padding),
          child: SizedBox(
            width: contentWidth,
            height: contentHeight,
            child: wide
                ? Row(
                    children: [
                      SizedBox(width: timerWidth, child: timer),
                      SizedBox(width: columnGap),
                      SizedBox(width: controlsWidth, child: controls),
                    ],
                  )
                : timer,
          ),
        ),
      );
    },
  );
}

// E-ink should repaint only the text or control whose visible value changed.
class _TimerValue<T> extends StatefulWidget {
  const _TimerValue({
    required this.controller,
    required this.select,
    required this.builder,
  });

  final WorkoutController controller;
  final T Function(TimerSnapshot) select;
  final Widget Function(BuildContext, T) builder;

  @override
  State<_TimerValue<T>> createState() => _TimerValueState<T>();
}

class _TimerValueState<T> extends State<_TimerValue<T>> {
  late T _value;

  @override
  void initState() {
    super.initState();
    _value = widget.select(widget.controller.display.value);
    widget.controller.display.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant _TimerValue<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.display.removeListener(_changed);
      widget.controller.display.addListener(_changed);
    }
    _value = widget.select(widget.controller.display.value);
  }

  void _changed() {
    final next = widget.select(widget.controller.display.value);
    if (next != _value) setState(() => _value = next);
  }

  @override
  void dispose() {
    widget.controller.display.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _value);
}
