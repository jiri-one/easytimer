import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:easytimer/app.dart';
import 'package:easytimer/l10n/app_localizations.dart';
import 'package:easytimer/l10n/app_localizations_en.dart';
import 'package:easytimer/platform/timer_platform.dart';
import 'package:easytimer/settings.dart';
import 'package:easytimer/timer_engine.dart';
import 'package:easytimer/workout_controller.dart';
import 'package:easytimer/ui/controls.dart';
import 'package:easytimer/ui/native_style.dart';
import 'package:easytimer/ui/volume_control.dart';
import 'package:easytimer/ui/settings_screen.dart';
import 'package:easytimer/ui/timer_screen.dart';
import 'package:easytimer/ui/number_field.dart';
import 'package:easytimer/ui/static_control.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Clock implements MonotonicClock {
  @override
  int nowMs = 0;
}

class _Platform extends TimerPlatform {
  bool awake = false;
  double gain = 1;
  int unlocks = 0;

  @override
  Future<void> initialize() async {}
  @override
  void unlock() => unlocks++;
  @override
  void schedule(List<SoundEvent> events, MonotonicClock clock) {}
  @override
  void cancel({bool keepEnd = false}) {}
  @override
  void setVolume(double value) => gain = value;
  @override
  void keepAwake(bool enabled) => awake = enabled;
  @override
  void dispose() {}
}

class _TitleLocalizations extends AppLocalizationsEn {
  @override
  String get appTitle => 'Localized timer title';
}

class _TitleDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _TitleDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<AppLocalizations> load(Locale locale) =>
      SynchronousFuture(_TitleLocalizations());

  @override
  bool shouldReload(_TitleDelegate old) => false;
}

void main() {
  late _Clock clock;
  late _Platform platform;
  late WorkoutController controller;

  setUpAll(() async {
    await (FontLoader(
      'DroidSansMono',
    )..addFont(rootBundle.load('assets/fonts/DroidSansMono.ttf'))).load();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    clock = _Clock();
    platform = _Platform();
    controller = WorkoutController(
      await TimerSettings.load(),
      platform,
      clock: clock,
    );
  });

  tearDown(() => controller.dispose());

  Future<void> mount(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
  }) async {
    await tester.pumpWidget(
      EasyTimerApp(controller: controller, locale: locale),
    );
    await tester.pumpAndSettle();
  }

  void timerTest(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        controller.stop();
        await tester.pumpWidget(const SizedBox());
      }
    });
  }

  Future<void> expectStaticFrame(WidgetTester tester) async {
    // Focus arrives in a microtask; flush it before the first paint so the
    // callback count cannot mistake an unpainted layout request for animation.
    FocusManager.instance.applyFocusChangesIfNeeded();
    await tester.pump();
    tester.binding.debugAssertNoTransientCallbacks('Static UI interaction');
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.binding.transientCallbackCount, 0);
  }

  FocusNode controlFocus(WidgetTester tester, Finder control) => tester
      .widgetList<Focus>(
        find.descendant(of: control, matching: find.byType(Focus)),
      )
      .firstWhere((widget) => widget.focusNode != null)
      .focusNode!;

  void expectFocusBorder(WidgetTester tester, Finder control) {
    final outline = find.descendant(
      of: control,
      matching: find.byType(StaticFocusBorder),
    );
    expect(tester.widget<StaticFocusBorder>(outline).focused, isTrue);
    final border = tester.widget<DecoratedBox>(
      find.descendant(of: outline, matching: find.byType(DecoratedBox)).first,
    );
    final decoration = border.decoration as BoxDecoration;
    expect(decoration.border!.top.width, 2);
    expect(decoration.border!.top.color.a, 1);
  }

  timerTest('app title resolves through the active localization delegate', (
    tester,
  ) async {
    await mount(tester);
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.title, isEmpty);
    expect(app.onGenerateTitle, isNotNull);
    expect(tester.widget<Title>(find.byType(Title)).title, 'EasyTimer');
    String? title;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [_TitleDelegate()],
        home: Builder(
          builder: (context) {
            title = app.onGenerateTitle!(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(title, 'Localized timer title');
  });

  for (final (locale, label, unlimited) in [
    ('en', 'Sets', 'Unlimited'),
    ('cs', 'Sety', 'Neomezeně'),
    ('ca', 'Repeticions', 'Sense límit'),
    ('es', 'Repeticiones', 'Sin límite'),
    ('fr', 'Répétitions', 'Illimité'),
  ]) {
    timerTest(
      '$locale announces unlimited sets without replacing editing semantics',
      (tester) async {
        await mount(tester, locale: Locale(locale));
        final field = find.byType(EditableText).at(2);
        final input = tester.widget<EditableText>(field);
        input.focusNode.requestFocus();
        await expectStaticFrame(tester);
        expect(input.focusNode.hasPrimaryFocus, isTrue);
        final node = tester.getSemantics(field);
        expect(
          node,
          isSemantics(
            label: label,
            hint: unlimited,
            value: '',
            isTextField: true,
            isFocused: true,
            hasSetTextAction: true,
            hasSetSelectionAction: true,
          ),
        );
        expect(find.text('∞'), findsOneWidget);

        node.owner!.performAction(node.id, ui.SemanticsAction.setText, '3');
        await expectStaticFrame(tester);
        expect(controller.settings.options.sets, 3);
        expect(
          tester.getSemantics(field),
          isSemantics(
            label: label,
            hint: '',
            value: '3',
            isTextField: true,
            hasSetTextAction: true,
            hasSetSelectionAction: true,
          ),
        );
        expect(find.text('∞'), findsNothing);

        node.owner!.performAction(node.id, ui.SemanticsAction.setText, '');
        await expectStaticFrame(tester);
        expect(controller.settings.options.sets, 0);
        expect(
          tester.getSemantics(field),
          isSemantics(
            label: label,
            hint: unlimited,
            value: '',
            hasSetTextAction: true,
          ),
        );
      },
    );
  }

  timerTest('pointer down retries audio on blank space, fields and controls', (
    tester,
  ) async {
    await mount(tester);
    final press = await tester.startGesture(const Offset(5, 5));
    expect(platform.unlocks, 1);
    await press.up();
    await expectStaticFrame(tester);
    expect(platform.unlocks, 1);
    await tester.tap(find.byType(NumberField).first);
    await expectStaticFrame(tester);
    expect(platform.unlocks, 2);
    await tester.tap(find.bySemanticsLabel('Increase Active Time'));
    await expectStaticFrame(tester);
    expect(platform.unlocks, 3);
    expect(controller.settings.options.active, 50);

    controller.start(const WorkoutOptions());
    controller.togglePause();
    await tester.pump();
    final before = platform.unlocks;
    await tester.tap(find.byType(VolumeControl));
    await expectStaticFrame(tester);
    expect(platform.unlocks, before + 1);
    expect(controller.display.mode, TimerMode.paused);
  });

  timerTest(
    'all key down and repeat events retry audio without consuming keys',
    (tester) async {
      await mount(tester);
      expect(await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA), isFalse);
      expect(platform.unlocks, 1);
      expect(await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyA), isFalse);
      expect(platform.unlocks, 2);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
      expect(platform.unlocks, 2);
      await expectStaticFrame(tester);

      controller.start(const WorkoutOptions());
      controller.togglePause();
      await tester.pump();
      final slider = find.byType(VolumeControl);
      final focus = controlFocus(tester, slider);
      focus.requestFocus();
      await expectStaticFrame(tester);
      expect(focus.hasPrimaryFocus, isTrue);
      final before = platform.unlocks;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      await expectStaticFrame(tester);
      expect(platform.unlocks, before + 1);
      expect(controller.volume, .95);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      await expectStaticFrame(tester);
      expect(platform.unlocks, before + 2);
      expect(controller.volume, closeTo(.9, .000001));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
      expect(platform.unlocks, before + 2);
      expect(focus.hasPrimaryFocus, isTrue);
    },
  );

  timerTest('disposing and remounting does not retain audio key handlers', (
    tester,
  ) async {
    await mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(platform.unlocks, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(platform.unlocks, 1);
    await mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(platform.unlocks, 2);
  });

  timerTest('settings focus, hover, press and editing schedule no animation', (
    tester,
  ) async {
    await mount(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    for (final field in find.byType(NumberField).evaluate().toList()) {
      final target = find.byWidget(field.widget);
      final input = tester.widget<EditableText>(
        find.descendant(of: target, matching: find.byType(EditableText)),
      );
      input.focusNode.requestFocus();
      await expectStaticFrame(tester);
      expect(input.focusNode.hasPrimaryFocus, isTrue);
      expectFocusBorder(tester, target);
      await mouse.moveTo(tester.getCenter(target));
      await expectStaticFrame(tester);
      await tester.tap(target);
      await expectStaticFrame(tester);
      await tester.enterText(target, '12345x');
      await expectStaticFrame(tester);
      expect(input.controller.text, '1234');
    }

    for (final button in find.byType(NumberStepButton).evaluate().toList()) {
      final target = find.byWidget(button.widget);
      final focus = controlFocus(tester, target);
      focus.requestFocus();
      await expectStaticFrame(tester);
      expect(focus.hasPrimaryFocus, isTrue);
      expectFocusBorder(tester, target);
      await mouse.moveTo(tester.getCenter(target));
      await expectStaticFrame(tester);
      final press = await tester.startGesture(tester.getCenter(target));
      await expectStaticFrame(tester);
      await press.up();
      await expectStaticFrame(tester);
    }

    final start = find.byType(CircleControl);
    final focus = controlFocus(tester, start);
    focus.requestFocus();
    await expectStaticFrame(tester);
    expect(focus.hasPrimaryFocus, isTrue);
    expectFocusBorder(tester, start);
    await mouse.moveTo(tester.getCenter(start));
    await expectStaticFrame(tester);
    final press = await tester.startGesture(tester.getCenter(start));
    await expectStaticFrame(tester);
    await press.cancel();
    await expectStaticFrame(tester);
  });

  timerTest('real slider focus keeps five-percent keys and semantics static', (
    tester,
  ) async {
    controller.start(const WorkoutOptions());
    controller.togglePause();
    await mount(tester);
    final slider = find.byType(VolumeControl);
    final focus = controlFocus(tester, slider);
    focus.requestFocus();
    await expectStaticFrame(tester);
    expect(focus.hasPrimaryFocus, isTrue);
    expectFocusBorder(tester, slider);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await expectStaticFrame(tester);
    expect(controller.volume, .95);
    expect(platform.gain, closeTo(.9025, .000001));
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
    node.owner!.performAction(node.id, ui.SemanticsAction.decrease);
    await expectStaticFrame(tester);
    expect(controller.volume, closeTo(.9, .000001));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await expectStaticFrame(tester);
    expect(controller.volume, closeTo(.95, .000001));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(slider));
    await expectStaticFrame(tester);
    final bounds = tester.getRect(slider);
    await tester.tapAt(
      Offset(bounds.center.dx, bounds.top + 16 + .63 * (bounds.height - 32)),
    );
    await expectStaticFrame(tester);
    expect(controller.volume, .37);
    expect(focus.hasPrimaryFocus, isTrue);
    expect(controller.display.mode, TimerMode.paused);

    for (final circle in find.byType(CircleControl).evaluate().toList()) {
      final target = find.byWidget(circle.widget);
      final focus = controlFocus(tester, target);
      focus.requestFocus();
      await expectStaticFrame(tester);
      expect(focus.hasPrimaryFocus, isTrue);
      expectFocusBorder(tester, target);
      await mouse.moveTo(tester.getCenter(target));
      await expectStaticFrame(tester);
      final press = await tester.startGesture(tester.getCenter(target));
      await expectStaticFrame(tester);
      await press.cancel();
      await expectStaticFrame(tester);
    }
  });

  timerTest('hidden volume changes do not rebuild mounted settings', (
    tester,
  ) async {
    await mount(tester);
    final settings = tester.element(find.byType(SettingsScreen));
    final rebuilt = <Element>[];
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previous?.call(element, builtOnce);
      if (element == settings ||
          element.findAncestorWidgetOfExactType<SettingsScreen>() != null) {
        rebuilt.add(element);
      }
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await expectStaticFrame(tester);
    controller.changeVolume(.4);
    await expectStaticFrame(tester);
    expect(controller.volume, .4);
    expect(platform.gain, closeTo(.16, .000001));
    expect(rebuilt, isEmpty);
    expect(tester.element(find.byType(SettingsScreen)), same(settings));
  });

  timerTest('timer volume changes rebuild only the local slider subtree', (
    tester,
  ) async {
    controller.start(const WorkoutOptions());
    controller.togglePause();
    await mount(tester);
    final rebuilt = <Widget>[];
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previous?.call(element, builtOnce);
      if (element.widget is TimerScreen ||
          element.widget is NativeText ||
          element.widget is CircleControl) {
        rebuilt.add(element.widget);
      }
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);
    controller.changeVolume(.35);
    await expectStaticFrame(tester);
    expect(tester.widget<VolumeControl>(find.byType(VolumeControl)).value, .35);
    expect(rebuilt, isEmpty);
  });

  timerTest('number fields keep keyboard submit and accessible text editing', (
    tester,
  ) async {
    await mount(tester);
    final input = tester.widget<EditableText>(find.byType(EditableText).first);
    input.focusNode.requestFocus();
    await expectStaticFrame(tester);
    expect(input.focusNode.hasPrimaryFocus, isTrue);
    final field = tester.getSemantics(find.byType(EditableText).first);
    expect(field, isSemantics(isTextField: true, hasSetTextAction: true));
    await tester.enterText(find.byType(EditableText).first, '0030');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(controller.showingTimer, isTrue);
    expect(controller.engine.options.active, 30);
  });

  timerTest('focused plus and minus activate once from the keyboard', (
    tester,
  ) async {
    await mount(tester);
    final minus = find.byType(NumberStepButton).at(0);
    final focus = controlFocus(tester, minus);
    focus.requestFocus();
    await expectStaticFrame(tester);
    expect(focus.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await expectStaticFrame(tester);
    expect(controller.settings.options.active, 40);
    final plus = find.byType(NumberStepButton).at(1);
    final plusFocus = controlFocus(tester, plus);
    plusFocus.requestFocus();
    await expectStaticFrame(tester);
    expect(plusFocus.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await expectStaticFrame(tester);
    expect(controller.settings.options.active, 45);
    expect(controller.showingTimer, isFalse);
  });

  timerTest('settings labels are bold native grey monospace and column grows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(618, 1125);
    tester.view.devicePixelRatio = 1.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester);
    final label = tester.widget<Text>(find.text('Active'));
    final scale = tester
        .widget<NumberField>(find.byType(NumberField).first)
        .scale;
    expect(label.style!.fontSize, 20 * scale);
    expect(label.style!.fontWeight, FontWeight.bold);
    expect(label.style!.fontFamily, 'DroidSansMono');
    expect(label.style!.color, const Color(0xff6f6f6f));
    final minus = tester.getRect(find.byType(NumberStepButton).at(0));
    final plus = tester.getRect(find.byType(NumberStepButton).at(1));
    final symbolWidth = nativeDimension(
      tester.element(find.text('Active')),
      24,
      scale,
    );
    final paintedWidth =
        plus.center.dx +
        symbolWidth * 7 / 24 -
        (minus.center.dx - symbolWidth * 8 / 24);
    expect(paintedWidth / 412, inInclusiveRange(.63, .65));
    expect((plus.right - minus.left) / 412, closeTo(.8, .005));
    for (final control in [
      ...find.byType(NumberStepButton).evaluate(),
      ...find.byType(NumberField).evaluate(),
    ]) {
      final size = tester.getSize(find.byWidget(control.widget));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
  });

  for (final height in [400.0, 570.0]) {
    timerTest('640x$height derives control space from rendered native text', (
      tester,
    ) async {
      tester.view.physicalSize = Size(640, height);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      controller.start(const WorkoutOptions());
      controller.togglePause();
      await mount(tester);
      final set = tester.getRect(find.byType(NativeText).first);
      final buttons = tester.widgetList<CircleControl>(
        find.byType(CircleControl),
      );
      final row = tester.getRect(find.byType(CircleControl).first);
      final renderedTextHeight = row.top - set.top;
      final expected = math.max(
        64.0,
        math.min(200.0, math.min((640 - 126) / 2, height - renderedTextHeight)),
      );
      expect(buttons.first.size, closeTo(expected.roundToDouble(), 1));
      expect(buttons.last.size, buttons.first.size);
      expect(tester.widget<Text>(find.text('SET')).style!.fontSize, 24);
      expect(tester.widget<Text>(find.text('1')).style!.fontSize, 64);
      expect(tester.widget<Text>(find.text('PREPARE')).style!.fontSize, 65);
      expect(tester.widget<Text>(find.text('5')).style!.fontSize, 150);
      if (height == 570) {
        expect(buttons.first.size, greaterThan(90));
        expect(row.bottom, lessThanOrEqualTo(height + .5));
      } else {
        expect(buttons.first.size, 64);
        await tester.drag(find.byType(TimerScreen), const Offset(0, -400));
        await expectStaticFrame(tester);
        expect(find.bySemanticsLabel('Stop').hitTestable(), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  timerTest(
    'controls use no icon fonts, Material fields, overlays or tooltips',
    (tester) async {
      await mount(tester);
      void expectNoMaterialControls() {
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
        for (final text in tester.widgetList<Text>(find.byType(Text))) {
          expect(text.style?.fontFamily, isNot('MaterialIcons'));
        }
      }

      expectNoMaterialControls();
      controller.start(const WorkoutOptions());
      controller.togglePause();
      await tester.pump();
      expectNoMaterialControls();
    },
  );

  timerTest('settings edits, clamps, falls back, and persists on start', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text('Active'), findsOneWidget);
    expect(find.text('Rest'), findsOneWidget);
    expect(find.text('Sets'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Decrease Active Time'));
    await tester.pump();
    expect(find.text('40'), findsOneWidget);
    await tester.enterText(find.byType(EditableText).at(0), '');
    await tester.tap(find.bySemanticsLabel('Increase Active Time'));
    await tester.pump();
    expect(find.text('50'), findsOneWidget);
    await tester.enterText(find.byType(EditableText).at(0), '0');
    await tester.enterText(find.byType(EditableText).at(1), '0');
    await tester.enterText(find.byType(EditableText).at(2), '2');
    await tester.tap(find.bySemanticsLabel('Start'));
    await tester.pump();
    expect(controller.engine.options.active, 5);
    expect(controller.engine.options.rest, 0);
    expect(controller.engine.options.sets, 2);
    expect(controller.settings.preferences!.getInt('sets'), 2);
  });

  timerTest('start, pause, resume and stop keep the screen awake', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.bySemanticsLabel('Start'));
    await tester.pump();
    expect(find.text('PREPARE'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    expect(platform.awake, isTrue);
    clock.nowMs = 5000;
    controller.refresh();
    await tester.pump();
    expect(find.text('ACTIVE'), findsOneWidget);
    expect(find.text('45'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Pause'));
    await tester.pump();
    expect(controller.display.mode, TimerMode.paused);
    expect(platform.awake, isTrue);
    await tester.tap(find.bySemanticsLabel('Resume'));
    await tester.pump();
    expect(controller.display.mode, TimerMode.running);
    await tester.tap(find.bySemanticsLabel('Stop'));
    await tester.pump();
    expect(find.text('Active'), findsOneWidget);
    expect(platform.awake, isFalse);
  });

  timerTest('empty fields use defaults and zero sets is unlimited', (
    tester,
  ) async {
    await mount(tester);
    for (final field in find.byType(EditableText).evaluate().toList()) {
      await tester.enterText(find.byWidget(field.widget), '');
    }
    await tester.tap(find.bySemanticsLabel('Start'));
    await tester.pump();
    expect(controller.engine.options.active, 45);
    expect(controller.engine.options.rest, 15);
    expect(controller.engine.options.sets, 0);
    expect(controller.settings.preferences!.getInt('activeTime'), 45);
  });

  timerTest('minimum values and a finite workout return to settings', (
    tester,
  ) async {
    await mount(tester);
    await tester.enterText(find.byType(EditableText).at(0), '0');
    await tester.enterText(find.byType(EditableText).at(1), '0');
    await tester.enterText(find.byType(EditableText).at(2), '1');
    await tester.tap(find.bySemanticsLabel('Start'));
    await tester.pump();
    expect(controller.engine.options.active, 5);
    clock.nowMs = 10000;
    controller.refresh();
    await tester.pump();
    expect(find.text('Active'), findsOneWidget);
    expect(platform.awake, isFalse);
    expect(find.text('5'), findsOneWidget);
  });

  timerTest(
    'Space starts and toggles pause; arrows change gain; Escape stops',
    (tester) async {
      await mount(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(controller.showingTimer, isTrue);
      expect(platform.unlocks, inInclusiveRange(1, 2));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(controller.display.mode, TimerMode.paused);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(controller.volume, closeTo(.95, .0001));
      expect(platform.gain, closeTo(.9025, .0001));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(controller.volume, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(controller.display.mode, TimerMode.running);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(controller.showingTimer, isFalse);
    },
  );

  timerTest(
    'focused volume reaches exact mute after seven decreases from 35 percent',
    (tester) async {
      await mount(tester);
      controller.start(const WorkoutOptions());
      controller.togglePause();
      controller.changeVolume(.35);
      await expectStaticFrame(tester);
      final slider = find.byType(VolumeControl);
      final focus = controlFocus(tester, slider);
      focus.requestFocus();
      await expectStaticFrame(tester);
      expect(focus.hasPrimaryFocus, isTrue);
      for (var step = 0; step < 7; step++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await expectStaticFrame(tester);
      }
      expect(controller.settings.volumePercent, 0);
      expect(controller.settings.preferences!.get('volumePercent'), 0);
      expect(tester.widget<VolumeControl>(slider).value, 0);
      expect(tester.getSemantics(find.bySemanticsLabel('Volume')).value, '0%');
    },
  );
  timerTest('shortcuts also work with a number field or slider focused', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byType(EditableText).first);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(controller.showingTimer, isTrue);
    await tester.tap(find.byType(VolumeControl));
    await tester.pump();
    final before = controller.volume;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(controller.volume, closeTo(before - .05, .0001));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(controller.display.mode, TimerMode.paused);
  });

  timerTest(
    'volume track keeps a 48 dp touch target and reaches both endpoints',
    (tester) async {
      await mount(tester);
      await tester.tap(find.bySemanticsLabel('Start'));
      await tester.pump();
      final slider = find.byType(VolumeControl);
      final bounds = tester.getRect(slider);
      expect(bounds.width, greaterThanOrEqualTo(48));
      expect(bounds.height, greaterThanOrEqualTo(64));
      await tester.tapAt(Offset(bounds.center.dx, bounds.bottom - 16));
      await tester.pump();
      expect(controller.volume, 0);
      await tester.tapAt(Offset(bounds.center.dx, bounds.top + 16));
      await tester.pump();
      expect(controller.volume, 1);
    },
  );

  timerTest(
    'timer uses the native type sizes and remaining-height button limit',
    (tester) async {
      tester.view.physicalSize = const Size(412, 657);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester);
      controller.start(const WorkoutOptions());
      clock.nowMs = 5000;
      controller.refresh();
      await tester.pump();
      final digits = tester.widget<Text>(find.text('45'));
      expect(digits.style!.fontSize, 150);
      expect(digits.style!.color, const Color(0xff6f6f6f));
      expect(digits.style!.fontFamily, 'DroidSansMono');
      final buttons = tester.widgetList<CircleControl>(
        find.byType(CircleControl),
      );
      expect(buttons.every((button) => button.size == 143), isTrue);
      expect(find.byType(NativeText), findsNWidgets(4));
    },
  );

  timerTest(
    'volume drags and keyboard adjustment remain immediate and accessible',
    (tester) async {
      final semantics = tester.ensureSemantics();

      try {
        await mount(tester);
        controller.start(const WorkoutOptions());
        await tester.pump();
        final slider = find.byType(VolumeControl);
        final bounds = tester.getRect(slider);
        final drag = await tester.startGesture(
          Offset(bounds.center.dx, bounds.bottom - 16),
        );
        await drag.moveTo(Offset(bounds.center.dx, bounds.top + 16));
        await drag.up();
        await tester.pump();
        expect(controller.volume, 1);
        final paintedSlider = find.descendant(
          of: slider,
          matching: find.byType(CustomPaint),
        );
        Focus.of(tester.element(paintedSlider)).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(controller.volume, .95);
        final node = tester.getSemantics(find.bySemanticsLabel('Volume'));
        expect(node.getSemanticsData().label, 'Volume');
        expect(node.getSemanticsData().value, '95%');
      } finally {
        semantics.dispose();
      }
    },
  );

  for (final (locale, active) in [
    ('cs', 'Aktivita'),
    ('ca', 'Esforç'),
    ('es', 'Trabajo'),
    ('fr', 'Effort'),
  ]) {
    timerTest('$locale follows the system locale', (tester) async {
      tester.binding.platformDispatcher.localesTestValue = [Locale(locale)];
      addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
      await tester.pumpWidget(EasyTimerApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.text(active), findsOneWidget);
    });
  }

  timerTest('unknown locales fall back to English', (tester) async {
    await mount(tester, locale: const Locale('ja'));
    expect(find.text('Active'), findsOneWidget);
  });
}
