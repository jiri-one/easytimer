import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../timer_engine.dart';
import '../workout_controller.dart';
import 'controls.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller});

  final WorkoutController controller;

  @override
  State<SettingsScreen> createState() => SettingsScreenState();
}

class SettingsScreenState extends State<SettingsScreen> {
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

  void start() {
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = math
            .min(
              2.5,
              math.min(
                .8 * constraints.maxWidth / 200,
                .85 * constraints.maxHeight / 446,
              ),
            )
            .clamp(.65, 2.5);
        Widget field(
          String label,
          TextEditingController controller,
          String less,
          String more,
          VoidCallback subtract,
          VoidCallback add, {
          String? hint,
        }) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 30 * scale,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 20 * scale,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 200 * scale,
              height: 56 * scale,
              child: Row(
                children: [
                  IconButton(
                    onPressed: subtract,
                    tooltip: less,
                    padding: EdgeInsets.all(16 * scale),
                    constraints: BoxConstraints.tightFor(
                      width: 56 * scale,
                      height: 56 * scale,
                    ),
                    iconSize: 24 * scale,
                    icon: const Icon(Icons.remove),
                  ),
                  Expanded(
                    child: TextField(
                      key: ValueKey(label),
                      controller: controller,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      cursorOpacityAnimates: false,
                      showCursor: false,
                      style: TextStyle(fontSize: 20 * scale),
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(4),
                      ],
                      decoration: InputDecoration(
                        hintText: hint,
                        hintFadeDuration: Duration.zero,
                        hintStyle: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface
                              .withValues(alpha: .65),
                        ),
                        contentPadding: EdgeInsets.symmetric(
                          vertical: 8 * scale,
                        ),
                        isDense: true,
                        enabledBorder: const UnderlineInputBorder(
                          borderSide: BorderSide(color: Color(0xff6f6f6f)),
                        ),
                        focusedBorder: UnderlineInputBorder(
                          borderSide: BorderSide(
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      ),
                      onChanged: (_) => _save(),
                      onSubmitted: (_) => start(),
                    ),
                  ),
                  IconButton(
                    onPressed: add,
                    tooltip: more,
                    padding: EdgeInsets.all(16 * scale),
                    constraints: BoxConstraints.tightFor(
                      width: 56 * scale,
                      height: 56 * scale,
                    ),
                    iconSize: 24 * scale,
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
            ),
          ],
        );
        return Center(
          child: SingleChildScrollView(
            child: SizedBox(
              width: math.min(constraints.maxWidth, 640),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  field(
                    strings.activeTimeLabel,
                    _active,
                    strings.decreaseActiveTime,
                    strings.increaseActiveTime,
                    () => _change(_active, _defaults.active, 5, -5),
                    () => _change(_active, _defaults.active, 5, 5),
                  ),
                  SizedBox(height: 20 * scale),
                  field(
                    strings.restTimeLabel,
                    _rest,
                    strings.decreaseRestTime,
                    strings.increaseRestTime,
                    () => _change(_rest, _defaults.rest, 0, -5),
                    () => _change(_rest, _defaults.rest, 0, 5),
                  ),
                  SizedBox(height: 20 * scale),
                  field(
                    strings.setsLabel,
                    _sets,
                    strings.decreaseSets,
                    strings.increaseSets,
                    () => _change(_sets, 0, 0, -1, emptyZero: true),
                    () => _change(_sets, 0, 0, 1, emptyZero: true),
                    hint: '∞',
                  ),
                  SizedBox(height: 30 * scale),
                  CircleControl(
                    label: strings.start,
                    symbol: ControlSymbol.play,
                    size: 100 * scale,
                    onPressed: start,
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
