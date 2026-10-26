import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../timer_engine.dart';
import '../workout_controller.dart';
import 'controls.dart';
import 'instant_scroll.dart';
import 'native_style.dart';
import 'number_field.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller});

  final WorkoutController controller;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final WorkoutOptions _defaults = widget.controller.settings.options;
  late final _active = TextEditingController(text: '${_defaults.active}');
  late final _rest = TextEditingController(text: '${_defaults.rest}');
  late final _sets = TextEditingController(
    text: _defaults.sets > 0 ? '${_defaults.sets}' : '',
  );

  WorkoutOptions get _options => WorkoutOptions.fromText(
    _active.text,
    _rest.text,
    _sets.text,
    fallback: _defaults,
  );

  void _start() {
    Focus.of(context).requestFocus();
    widget.controller.start(_options);
  }

  void _save() => unawaited(widget.controller.settings.saveOptions(_options));

  void _change(
    TextEditingController field,
    int fallback,
    int minimum,
    int step, {
    bool emptyZero = false,
  }) {
    final value = ((WorkoutOptions.parse(field.text) ?? fallback) + step).clamp(
      minimum,
      9999,
    );
    field.text = emptyZero && value == 0 ? '' : '$value';
    _save();
  }

  @override
  void dispose() {
    _active.dispose();
    _rest.dispose();
    _sets.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return InstantScrollView(
      builder: (context, constraints) {
        const minimumTarget = 64.0;
        // Keep the controls readable when the keyboard or a short window leaves
        // too little height; InstantScrollView makes the remaining groups reachable.
        final layoutHeight = math.max(constraints.maxHeight, minimumTarget * 5);
        final columnWidth = math.min(
          .92 * constraints.maxWidth,
          1.25 * layoutHeight,
        );
        final valueExtent = math.min(.13 * layoutHeight, columnWidth / 5.1);
        final targetSize = math.max(minimumTarget, 1.25 * valueExtent);
        final fieldPadding = EdgeInsets.symmetric(
          horizontal: .05 * valueExtent,
        );
        // Fit every possible value before the first frame. Editing or stepping
        // through 0..9999 must not resize the text or move its neighbouring buttons.
        final valueFontSize = NativeText.fitSize(
          context,
          '9999',
          maxSize: valueExtent,
          width: math.max(
            0,
            columnWidth - 2 * targetSize - fieldPadding.horizontal - 2,
          ),
          height: valueExtent,
        );
        final textScaler = MediaQuery.textScalerOf(context);
        final scaledValueSize = textScaler.scale(valueFontSize);
        final labelFontSize =
            [
              strings.activeTimeLabel,
              strings.restTimeLabel,
              strings.setsLabel,
            ].fold<double>(
              valueFontSize / 1.7,
              (size, label) => NativeText.fitSize(
                context,
                label,
                maxSize: size,
                width: columnWidth,
                height: scaledValueSize / 1.7,
                bold: true,
              ),
            );
        final rowHeight = math.max(targetSize, 1.4 * scaledValueSize);
        // The native plus occupies 14/24 of its canvas; this matches the
        // Droid Sans Mono digit cap height (1462/2048 of the value font size).
        final glyphSize = 1.22 * scaledValueSize;
        final minimumGap = .04 * scaledValueSize;
        final startSize = math.min(
          columnWidth,
          math.max(minimumTarget, .18 * layoutHeight),
        );

        Widget field(
          String label,
          TextEditingController controller,
          String less,
          String more,
          VoidCallback subtract,
          VoidCallback add, {
          String? hint,
          String? semanticHint,
        }) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            NativeText(label, size: labelFontSize, bold: true),
            SizedBox(
              width: columnWidth,
              height: rowHeight,
              child: Row(
                children: [
                  NumberStepButton(
                    label: less,
                    add: false,
                    size: targetSize,
                    glyphSize: glyphSize,
                    onPressed: subtract,
                  ),
                  Expanded(
                    child: NumberField(
                      key: ValueKey(label),
                      label: label,
                      controller: controller,
                      fontSize: valueFontSize,
                      padding: fieldPadding,
                      hint: hint,
                      semanticHint: semanticHint,
                      onChanged: _save,
                      onSubmitted: _start,
                    ),
                  ),
                  NumberStepButton(
                    label: more,
                    add: true,
                    size: targetSize,
                    glyphSize: glyphSize,
                    onPressed: add,
                  ),
                ],
              ),
            ),
          ],
        );
        final groups = [
          field(
            strings.activeTimeLabel,
            _active,
            strings.decreaseActiveTime,
            strings.increaseActiveTime,
            () => _change(_active, _defaults.active, 5, -5),
            () => _change(_active, _defaults.active, 5, 5),
          ),
          field(
            strings.restTimeLabel,
            _rest,
            strings.decreaseRestTime,
            strings.increaseRestTime,
            () => _change(_rest, _defaults.rest, 0, -5),
            () => _change(_rest, _defaults.rest, 0, 5),
          ),
          field(
            strings.setsLabel,
            _sets,
            strings.decreaseSets,
            strings.increaseSets,
            () => _change(_sets, 0, 0, -1, emptyZero: true),
            () => _change(_sets, 0, 0, 1, emptyZero: true),
            hint: '∞',
            semanticHint: strings.unlimited,
          ),
          CircleControl(
            label: strings.start,
            symbol: ControlSymbol.play,
            size: startSize,
            onPressed: _start,
          ),
        ];
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: minimumGap / 2),
              child: SizedBox(
                width: columnWidth,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final group in groups)
                      Padding(
                        padding: EdgeInsets.symmetric(vertical: minimumGap / 2),
                        child: group,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
