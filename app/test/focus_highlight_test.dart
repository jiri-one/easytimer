import 'package:easytimer/ui/static_control.dart';
import 'package:easytimer/ui/volume_control.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final volume in [false, true]) {
    testWidgets(
      'touch hides and keyboard shows ${volume ? 'volume' : 'button'} focus',
      (tester) async {
        final strategy = FocusManager.instance.highlightStrategy;
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic;
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: Center(
                child: SizedBox(
                  width: 64,
                  height: 160,
                  child: volume
                      ? VolumeControl(
                          label: 'Volume',
                          percent: 50,
                          onChanged: (_) {},
                          onStep: (_) {},
                        )
                      : StaticButton(
                          label: 'Start',
                          onPressed: () {},
                          child: const Text('Start'),
                        ),
                ),
              ),
            ),
          );
          final target = volume
              ? find.byType(VolumeControl)
              : find.byType(StaticButton);
          final outline = find.descendant(
            of: target,
            matching: find.byType(StaticFocusBorder),
          );
          double opacity() =>
              (tester
                          .widget<DecoratedBox>(
                            find
                                .descendant(
                                  of: outline,
                                  matching: find.byType(DecoratedBox),
                                )
                                .first,
                          )
                          .decoration
                      as BoxDecoration)
                  .border!
                  .top
                  .color
                  .a;
          await tester.tap(target, kind: PointerDeviceKind.touch);
          FocusManager.instance.applyFocusChangesIfNeeded();
          await tester.pump();
          expect(FocusManager.instance.highlightMode, FocusHighlightMode.touch);
          expect(tester.widget<StaticFocusBorder>(outline).focused, isTrue);
          expect(opacity(), 0);
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pump();
          expect(
            FocusManager.instance.highlightMode,
            FocusHighlightMode.traditional,
          );
          expect(opacity(), 1);
          expect(tester.binding.transientCallbackCount, 0);
        } finally {
          await tester.pumpWidget(const SizedBox());
          FocusManager.instance.highlightStrategy = strategy;
        }
      },
    );
  }
}
