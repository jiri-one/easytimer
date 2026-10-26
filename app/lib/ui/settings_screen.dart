import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../timer_engine.dart';
import '../workout_controller.dart';
import 'controls.dart';
import 'native_style.dart';

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
        final screen = MediaQuery.sizeOf(context);
        final baseHeight =
            [
              strings.activeTimeLabel,
              strings.restTimeLabel,
              strings.setsLabel,
            ].fold<double>(
              0,
              (height, label) =>
                  height + NativeText.measure(context, label, 20, screen.width),
            ) +
            56 * 3 +
            20 * 2 +
            30 +
            100;
        final scale = math
            .min(.8 * screen.width / 200, .85 * screen.height / baseHeight)
            .clamp(1.0, 2.5);
        double dimension(double value) =>
            nativeDimension(context, value, scale);
        final dark = Theme.of(context).brightness == Brightness.dark;
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
            NativeText(label, size: 20 * scale),
            SizedBox(
              width: dimension(200),
              height: dimension(56),
              child: Row(
                children: [
                  IconButton(
                    onPressed: subtract,
                    tooltip: less,
                    padding: EdgeInsets.all(dimension(16)),
                    constraints: BoxConstraints.tightFor(
                      width: dimension(56),
                      height: dimension(56),
                    ),
                    iconSize: dimension(24),
                    icon: const Icon(Icons.remove),
                  ),
                  Expanded(
                    child: Semantics(
                      label: label,
                      child: TextField(
                        key: ValueKey(label),
                        controller: controller,
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        cursorOpacityAnimates: false,
                        showCursor: false,
                        style: TextStyle(
                          fontFamily: 'DroidSansMono',
                          fontSize: 18 * scale,
                          color: dark
                              ? const Color(0xffeeeeee)
                              : const Color(0xff212121),
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(4),
                        ],
                        decoration: InputDecoration(
                          hintText: hint,
                          hintFadeDuration: Duration.zero,
                          hintStyle: TextStyle(
                            color: dark
                                ? const Color(0xffcccccc)
                                : const Color(0xff6f6f6f),
                          ),
                          contentPadding: EdgeInsets.symmetric(
                            vertical: dimension(8),
                          ),
                          isDense: true,
                          enabledBorder: UnderlineInputBorder(
                            borderSide: BorderSide(
                              color: dark
                                  ? const Color(0xffaaaaaa)
                                  : const Color(0xff525252),
                            ),
                          ),
                          focusedBorder: UnderlineInputBorder(
                            borderSide: BorderSide(
                              color: dark
                                  ? const Color(0xffcccccc)
                                  : const Color(0xff525252),
                            ),
                          ),
                        ),
                        onChanged: (_) => _save(),
                        onSubmitted: (_) => start(),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: add,
                    tooltip: more,
                    padding: EdgeInsets.all(dimension(16)),
                    constraints: BoxConstraints.tightFor(
                      width: dimension(56),
                      height: dimension(56),
                    ),
                    iconSize: dimension(24),
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
                  SizedBox(height: dimension(20)),
                  field(
                    strings.restTimeLabel,
                    _rest,
                    strings.decreaseRestTime,
                    strings.increaseRestTime,
                    () => _change(_rest, _defaults.rest, 0, -5),
                    () => _change(_rest, _defaults.rest, 0, 5),
                  ),
                  SizedBox(height: dimension(20)),
                  field(
                    strings.setsLabel,
                    _sets,
                    strings.decreaseSets,
                    strings.increaseSets,
                    () => _change(_sets, 0, 0, -1, emptyZero: true),
                    () => _change(_sets, 0, 0, 1, emptyZero: true),
                    hint: '∞',
                  ),
                  SizedBox(height: dimension(30)),
                  CircleControl(
                    label: strings.start,
                    symbol: ControlSymbol.play,
                    size: dimension(100),
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
