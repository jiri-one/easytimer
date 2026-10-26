import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:easytimer/app.dart';
import 'package:easytimer/l10n/app_localizations.dart';
import 'package:easytimer/timer_engine.dart';
import 'package:easytimer/ui/controls.dart';
import 'package:easytimer/ui/native_style.dart';
import 'package:easytimer/ui/number_field.dart';
import 'package:easytimer/ui/settings_screen.dart';
import 'package:easytimer/ui/static_control.dart';
import 'package:easytimer/ui/timer_screen.dart';
import 'package:easytimer/ui/volume_control.dart';
import 'package:easytimer/workout_controller.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

void main() {
  late FakeClock clock;
  late RecordingTimerPlatform platform;
  late WorkoutController controller;

  setUpAll(loadAppFont);

  void timerTest(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      clock = FakeClock();
      platform = RecordingTimerPlatform();
      controller = await createTestController(
        tester,
        clock: clock,
        platform: platform,
      );
      try {
        await body(tester);
      } finally {
        controller.stop();
        await tester.pumpWidget(const SizedBox());
      }
    });
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(EasyTimerApp(controller: controller));
    await tester.pumpAndSettle();
  }

  void hideApp(WidgetTester tester, {bool paused = false}) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    if (paused) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    }
  }

  void resumeApp(WidgetTester tester) {
    if (tester.binding.lifecycleState == AppLifecycleState.paused) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    }
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }

  Future<void> staticFrame(WidgetTester tester) async {
    // Flush focus before counting callbacks so pending layout is not an animation.
    FocusManager.instance.applyFocusChangesIfNeeded();
    for (final delay in [
      Duration.zero,
      const Duration(milliseconds: 16),
      const Duration(milliseconds: 600),
    ]) {
      await tester.pump(delay);
      expect(tester.binding.transientCallbackCount, 0);
    }
    expect(tester.takeException(), isNull);
  }

  FocusNode focusOf(WidgetTester tester, Finder target) => tester
      .widgetList<Focus>(
        find.descendant(of: target, matching: find.byType(Focus)),
      )
      .firstWhere((widget) => widget.focusNode != null)
      .focusNode!;

  Future<void> focusControl(WidgetTester tester, Finder target) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    final focus = focusOf(tester, target)..requestFocus();
    await staticFrame(tester);
    expect(focus.hasPrimaryFocus, isTrue);
    final outline = find.descendant(
      of: target,
      matching: find.byType(StaticFocusBorder),
    );
    expect(tester.widget<StaticFocusBorder>(outline).focused, isTrue);
    final border =
        tester
                .widget<DecoratedBox>(
                  find
                      .descendant(
                        of: outline,
                        matching: find.byType(DecoratedBox),
                      )
                      .first,
                )
                .decoration
            as BoxDecoration;
    expect(border.border!.top.width, 2);
    expect(border.border!.top.color.a, 1);
  }

  timerTest('locale fallback, title and editable unlimited-set semantics', (
    tester,
  ) async {
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    expect(AppLocalizations.supportedLocales.first, const Locale('en'));
    for (final (locale, active, sets, unlimited) in [
      ('en', 'Active', 'Sets', 'Unlimited'),
      ('cs', 'Aktivita', 'Sety', 'Neomezeně'),
      ('ca', 'Esforç', 'Repeticions', 'Sense límit'),
      ('es', 'Trabajo', 'Repeticiones', 'Sin límite'),
      ('fr', 'Effort', 'Répétitions', 'Illimité'),
      ('ja', 'Active', 'Sets', 'Unlimited'),
    ]) {
      tester.binding.platformDispatcher.localesTestValue = [Locale(locale)];
      await mount(tester);
      expect(find.text(active), findsOneWidget);
      final strings = AppLocalizations.of(
        tester.element(find.byType(SettingsScreen)),
      );
      expect(strings.setsLabel, sets);
      expect(strings.unlimited, unlimited);
      expect(tester.widget<Title>(find.byType(Title)).title, strings.appTitle);
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).supportedLocales,
        AppLocalizations.supportedLocales,
      );
    }
    final field = find.byType(EditableText).at(2);
    tester.widget<EditableText>(field).focusNode.requestFocus();
    await staticFrame(tester);
    expect(
      tester.getSemantics(field),
      isSemantics(
        label: 'Sets',
        hint: 'Unlimited',
        value: '',
        isTextField: true,
        isFocused: true,
        hasSetTextAction: true,
        hasSetSelectionAction: true,
      ),
    );
    for (final value in ['3', '']) {
      final node = tester.getSemantics(field);
      node.owner!.performAction(node.id, ui.SemanticsAction.setText, value);
      await staticFrame(tester);
      expect(controller.settings.options.sets, value.isEmpty ? 0 : 3);
      expect(
        tester.getSemantics(field),
        isSemantics(
          value: value,
          hint: value.isEmpty ? 'Unlimited' : '',
          hasSetTextAction: true,
          hasSetSelectionAction: true,
        ),
      );
      expect(find.text('∞'), value.isEmpty ? findsOneWidget : findsNothing);
    }
  });

  timerTest('settings keyboard edits, defaults, bounds and finite completion', (
    tester,
  ) async {
    await mount(tester);
    for (final (index, key, active) in [
      (0, LogicalKeyboardKey.enter, 40),
      (1, LogicalKeyboardKey.space, 45),
    ]) {
      await focusControl(tester, find.byType(NumberStepButton).at(index));
      await tester.sendKeyEvent(key);
      await staticFrame(tester);
      expect(controller.settings.options.active, active);
      expect(controller.showingTimer.value, isFalse);
    }
    for (final field in find.byType(EditableText).evaluate().toList()) {
      await tester.enterText(find.byWidget(field.widget), '');
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(
      (
        controller.engine.options.active,
        controller.engine.options.rest,
        controller.engine.options.sets,
      ),
      (45, 15, 0),
    );
    controller.stop();
    await tester.pump();
    for (final (index, value) in [(0, '0'), (1, '0'), (2, '1')]) {
      await tester.enterText(find.byType(EditableText).at(index), value);
    }
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(
      (
        controller.engine.options.active,
        controller.engine.options.rest,
        controller.engine.options.sets,
      ),
      (5, 0, 1),
    );
    expect(controller.settings.preferences!.getInt('sets'), 1);
    clock.nowMs = 10000;
    controller.refresh();
    await tester.pump();
    expect(controller.showingTimer.value, isFalse);
    expect(platform.awake.last, isFalse);
    expect(find.text('Active'), findsOneWidget);
  });

  timerTest('Space and Start use synchronized empty and invalid field edits', (
    tester,
  ) async {
    (int, int, int) values(WorkoutOptions options) =>
        (options.active, options.rest, options.sets);

    for (final (inputs, expected) in [
      (['', '', ''], (65, 25, 0)),
      (['0', '0', '0000'], (5, 0, 0)),
      (['12x', '99999', '3x'], (12, 9999, 3)),
    ]) {
      for (final space in [false, true]) {
        await controller.settings.saveOptions(
          const WorkoutOptions(active: 65, rest: 25, sets: 4),
        );
        await mount(tester);
        for (var index = 0; index < inputs.length; index++) {
          await tester.enterText(
            find.byType(EditableText).at(index),
            inputs[index],
          );
        }
        expect(values(controller.settings.options), expected);
        if (space) {
          await tester.sendKeyEvent(LogicalKeyboardKey.space);
        } else {
          await tester.tap(find.bySemanticsLabel('Start'));
        }
        await tester.pump();
        expect(controller.showingTimer.value, isTrue);
        expect(values(controller.engine.options), expected);
        controller.stop();
        await tester.pumpWidget(const SizedBox());
      }
    }
  });

  timerTest(
    'settings focus, hover, press and editing remain static and native',
    (tester) async {
      await mount(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      for (final field in find.byType(NumberField).evaluate().toList()) {
        final target = find.byWidget(field.widget);
        await focusControl(tester, target);
        await mouse.moveTo(tester.getCenter(target));
        await tester.tap(target);
        await tester.enterText(target, '12345x');
        await staticFrame(tester);
        expect(
          tester
              .widget<EditableText>(
                find.descendant(
                  of: target,
                  matching: find.byType(EditableText),
                ),
              )
              .controller
              .text,
          '1234',
        );
      }
      for (final element in [
        ...find.byType(NumberStepButton).evaluate(),
        ...find.byType(CircleControl).evaluate(),
      ]) {
        final target = find.byWidget(element.widget);
        await focusControl(tester, target);
        await mouse.moveTo(tester.getCenter(target));
        final press = await tester.startGesture(tester.getCenter(target));
        await staticFrame(tester);
        await press.cancel();
        await staticFrame(tester);
      }
      for (final timer in [false, true]) {
        if (timer) {
          controller.start(const WorkoutOptions());
          controller.togglePause();
          await tester.pump();
        }
        for (final type in [
          Icon,
          IconButton,
          TextButton,
          TextField,
          InputDecorator,
          Tooltip,
          Slider,
          InkWell,
          FocusableActionDetector,
        ]) {
          expect(find.byType(type), findsNothing);
        }
        expect(
          tester
              .widgetList<Text>(find.byType(Text))
              .every((text) => text.style?.fontFamily == 'Roboto'),
          isTrue,
        );
      }
    },
  );

  timerTest('volume arrows apply only while the timer is shown', (
    tester,
  ) async {
    controller.changeVolume(50);
    await mount(tester);
    for (final field in tester.widgetList<EditableText>(
      find.byType(EditableText),
    )) {
      field.controller.selection = TextSelection.collapsed(
        offset: field.controller.text.length,
      );
      field.focusNode.requestFocus();
      await staticFrame(tester);
      expect(field.focusNode.hasPrimaryFocus, isTrue);
      final text = field.controller.text;
      for (final key in [
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowUp,
      ]) {
        await tester.sendKeyDownEvent(key);
        await tester.pump();
        await tester.sendKeyRepeatEvent(key);
        await tester.sendKeyUpEvent(key);
        await staticFrame(tester);
        expect(controller.volume.value, 50);
        expect(
          field.controller.selection.extentOffset,
          key == LogicalKeyboardKey.arrowDown ? text.length : 0,
        );
        expect(field.controller.text, text);
      }
    }
    await focusControl(tester, find.byType(CircleControl));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await staticFrame(tester);
    expect(controller.volume.value, 50);
    expect(platform.volumes, [100, 50]);
    expect(controller.settings.preferences!.getInt('volumePercent'), 50);

    controller.start(const WorkoutOptions());
    controller.togglePause();
    await tester.pump();
    await focusControl(tester, find.byType(CircleControl).first);
    for (final (key, expected) in [
      (LogicalKeyboardKey.arrowDown, 45),
      (LogicalKeyboardKey.arrowUp, 50),
    ]) {
      await tester.sendKeyEvent(key);
      await staticFrame(tester);
      expect(controller.volume.value, expected);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    final field = tester.widget<EditableText>(find.byType(EditableText).first);
    field.controller.selection = TextSelection.collapsed(
      offset: field.controller.text.length,
    );
    field.focusNode.requestFocus();
    await staticFrame(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await staticFrame(tester);
    expect(controller.showingTimer.value, isFalse);
    expect(controller.volume.value, 50);
  });

  timerTest(
    'focused slider keys, repeats, semantics and pointer endpoints stay static',
    (tester) async {
      controller.start(const WorkoutOptions());
      controller.togglePause();
      await mount(tester);
      final slider = find.byType(VolumeControl);
      await focusControl(tester, slider);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
      await staticFrame(tester);
      expect(controller.volume.value, 90);
      for (final (key, expected) in [
        (LogicalKeyboardKey.arrowUp, 95),
        (LogicalKeyboardKey.arrowLeft, 90),
        (LogicalKeyboardKey.arrowRight, 95),
      ]) {
        await tester.sendKeyEvent(key);
        await staticFrame(tester);
        expect(controller.volume.value, expected);
      }
      final node = tester.getSemantics(find.bySemanticsLabel('Volume'));
      expect(
        node,
        isSemantics(
          label: 'Volume',
          value: '95%',
          increasedValue: '100%',
          decreasedValue: '90%',
          isSlider: true,
          isFocusable: true,
          isFocused: true,
          hasIncreaseAction: true,
          hasDecreaseAction: true,
          hasFocusAction: true,
        ),
      );
      for (final (action, expected) in [
        (ui.SemanticsAction.decrease, 90),
        (ui.SemanticsAction.increase, 95),
      ]) {
        node.owner!.performAction(node.id, action);
        await staticFrame(tester);
        expect(controller.volume.value, expected);
      }
      controller.changeVolume(35);
      for (var step = 0; step < 7; step++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await staticFrame(tester);
      }
      expect(controller.volume.value, 0);
      expect(platform.volumes.last, 0);
      expect(controller.settings.preferences!.getInt('volumePercent'), 0);
      expect(tester.getSemantics(find.bySemanticsLabel('Volume')).value, '0%');
      expect(
        tester.getSemantics(find.bySemanticsLabel('Volume')).decreasedValue,
        '0%',
      );
      final bounds = tester.getRect(slider);
      expect(bounds.width, greaterThanOrEqualTo(48));
      expect(bounds.height, greaterThanOrEqualTo(64));
      for (final (y, expected) in [(bounds.top, 100), (bounds.bottom - 1, 0)]) {
        await tester.tapAt(Offset(bounds.center.dx, y));
        await staticFrame(tester);
        expect(controller.volume.value, expected);
        if (expected == 100) {
          expect(
            tester.getSemantics(find.bySemanticsLabel('Volume')).increasedValue,
            '100%',
          );
        }
      }
      final drag = await tester.startGesture(
        Offset(bounds.center.dx, bounds.bottom - 16),
      );
      await drag.moveTo(
        Offset(bounds.center.dx, bounds.top + 16 + .63 * (bounds.height - 32)),
      );
      await drag.up();
      await staticFrame(tester);
      expect(controller.volume.value, 37);
      expect(tester.widget<VolumeControl>(slider).percent, 37);
      expect(focusOf(tester, slider).hasPrimaryFocus, isTrue);
      for (final element in find.byType(CircleControl).evaluate().toList()) {
        await focusControl(tester, find.byWidget(element.widget));
      }
      await focusControl(tester, slider);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(controller.display.value.mode, TimerMode.running);
      expect(platform.awake.last, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(controller.showingTimer.value, isFalse);
      expect(platform.awake.last, isFalse);
    },
  );

  timerTest('notifiers isolate root, timer text and slider rebuilds', (
    tester,
  ) async {
    await mount(tester);
    final rebuilt = <Widget>[];
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previous?.call(element, builtOnce);
      rebuilt.add(element.widget);
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);
    controller.changeVolume(40);
    await staticFrame(tester);
    expect(rebuilt, isEmpty);
    controller.start(const WorkoutOptions());
    await tester.pump();
    final root = tester.element(find.byType(Scaffold));
    rebuilt.clear();
    clock.nowMs = 1000;
    controller.refresh();
    await tester.pump();
    expect(rebuilt.whereType<NativeText>(), isNotEmpty);
    expect(rebuilt.whereType<Scaffold>(), isEmpty);
    expect(rebuilt.whereType<TimerScreen>(), isEmpty);
    expect(tester.element(find.byType(Scaffold)), same(root));
    rebuilt.clear();
    controller.changeVolume(35);
    await staticFrame(tester);
    expect(rebuilt.whereType<VolumeControl>(), isNotEmpty);
    expect(rebuilt.whereType<NativeText>(), isEmpty);
    expect(rebuilt.whereType<CircleControl>(), isEmpty);
    expect(rebuilt.whereType<Scaffold>(), isEmpty);
    expect(rebuilt.whereType<TimerScreen>(), isEmpty);
  });

  timerTest('resuming the app refreshes the visible monotonic countdown', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.bySemanticsLabel('Start'));
    await tester.pump();
    expect(find.text('PREPARE'), findsOneWidget);
    expect(platform.awake.last, isTrue);
    hideApp(tester, paused: true);
    clock.nowMs = 5000;
    resumeApp(tester);
    await tester.pump();
    expect(find.text('ACTIVE'), findsOneWidget);
    expect(find.text('45'), findsOneWidget);
    expect(platform.awake, [true, true]);
    await tester.tap(find.bySemanticsLabel('Pause'));
    await tester.pump();
    expect(controller.display.value.mode, TimerMode.paused);
    hideApp(tester);
    clock.nowMs = 60000;
    resumeApp(tester);
    await tester.pump();
    expect(controller.display.value.mode, TimerMode.paused);
    expect(find.text('45'), findsOneWidget);
    expect(platform.awake, [true, true, true]);
    await tester.tap(find.bySemanticsLabel('Resume'));
    await tester.pump();
    expect(controller.display.value.mode, TimerMode.running);
  });

  timerTest('lifecycle resume keeps stopped and completed workouts wake-off', (
    tester,
  ) async {
    await mount(tester);
    hideApp(tester);
    resumeApp(tester);
    await tester.pump();
    expect(platform.awake, isEmpty);

    controller.start(const WorkoutOptions(active: 5, rest: 0, sets: 1));
    await tester.pump();
    hideApp(tester);
    clock.nowMs = 60000;
    resumeApp(tester);
    await tester.pump();
    expect(controller.display.value.mode, TimerMode.complete);
    expect(controller.showingTimer.value, isFalse);
    expect(platform.awake, [true, false]);

    hideApp(tester);
    resumeApp(tester);
    await tester.pump();
    expect(platform.awake, [true, false]);
  });

  timerTest('native sizing keeps text, proportions and reachable controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(618, 1125);
    tester.view.devicePixelRatio = 1.5;
    await mount(tester);
    final label = tester.widget<Text>(find.text('Active'));
    final scale = tester
        .widget<NumberField>(find.byType(NumberField).first)
        .scale;
    expect(label.style!.fontSize, 20 * scale);
    expect(label.style!.fontWeight, FontWeight.bold);
    expect(label.style!.color, const Color(0xff6f6f6f));
    final minus = tester.getRect(find.byType(NumberStepButton).at(0));
    final plus = tester.getRect(find.byType(NumberStepButton).at(1));
    expect((plus.right - minus.left) / 412, closeTo(.8, .005));
    for (final element in [
      ...find.byType(NumberStepButton).evaluate(),
      ...find.byType(NumberField).evaluate(),
    ]) {
      final size = tester.getSize(find.byWidget(element.widget));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
    controller.start(const WorkoutOptions());
    controller.togglePause();
    tester.view.devicePixelRatio = 1;
    for (final height in [570.0, 400.0]) {
      tester.view.physicalSize = Size(640, height);
      await tester.pump();
      final top = tester.getRect(find.byType(NativeText).first).top;
      final row = tester.getRect(find.byType(CircleControl).first);
      final expected = math.max(
        64.0,
        math.min(200.0, math.min((640 - 126) / 2, height - (row.top - top))),
      );
      final buttons = tester.widgetList<CircleControl>(
        find.byType(CircleControl),
      );
      expect(buttons.first.size, closeTo(expected.roundToDouble(), 1));
      expect(buttons.last.size, buttons.first.size);
      for (final (text, size) in [
        ('SET', 24.0),
        ('1', 64.0),
        ('PREPARE', 65.0),
        ('5', 150.0),
      ]) {
        final style = tester.widget<Text>(find.text(text)).style!;
        expect(style.fontSize, size);
        expect(style.fontFamily, 'Roboto');
      }
      if (height == 400) {
        expect(buttons.first.size, 64);
        await tester.drag(find.byType(TimerScreen), const Offset(0, -400));
        await staticFrame(tester);
        expect(find.bySemanticsLabel('Stop').hitTestable(), findsOneWidget);
      } else {
        expect(row.bottom, lessThanOrEqualTo(height + .5));
      }
    }
  });
}
