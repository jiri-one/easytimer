import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'static_control.dart';

class VolumeControl extends StatefulWidget {
  const VolumeControl({
    super.key,
    required this.label,
    required this.percent,
    required this.onChanged,
    required this.onStep,
  });

  final String label;
  final int percent;
  final ValueChanged<int> onChanged;
  final ValueChanged<int> onStep;

  @override
  State<VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<VolumeControl> {
  final _focus = FocusNode(debugLabel: 'Volume');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      void position(Offset local) {
        final fraction = 1 - (local.dy - 16) / (constraints.maxHeight - 32);
        _focus.requestFocus();
        widget.onChanged((fraction * 100).round());
      }

      return Semantics(
        label: widget.label,
        slider: true,
        focusable: true,
        focused: _focus.hasFocus,
        onFocus: _focus.requestFocus,
        value: '${widget.percent}%',
        increasedValue: '${(widget.percent + 5).clamp(0, 100)}%',
        decreasedValue: '${(widget.percent - 5).clamp(0, 100)}%',
        onIncrease: () => widget.onStep(5),
        onDecrease: () => widget.onStep(-5),
        child: Focus(
          focusNode: _focus,
          includeSemantics: false,
          onFocusChange: (_) => setState(() {}),
          onKeyEvent: (_, event) {
            final delta = switch (event.logicalKey) {
              LogicalKeyboardKey.arrowRight => 5,
              LogicalKeyboardKey.arrowLeft => -5,
              _ => null,
            };
            if (delta == null) return KeyEventResult.ignored;
            if (event is KeyDownEvent || event is KeyRepeatEvent) {
              widget.onStep(delta);
            }
            return KeyEventResult.handled;
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onTapDown: (details) => position(details.localPosition),
              onVerticalDragStart: (details) => position(details.localPosition),
              onVerticalDragUpdate: (details) =>
                  position(details.localPosition),
              child: StaticFocusBorder(
                focused: _focus.hasFocus,
                child: CustomPaint(
                  size: constraints.biggest,
                  painter: _VolumePainter(
                    widget.percent / 100,
                    Theme.of(context).brightness == Brightness.dark,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _VolumePainter extends CustomPainter {
  const _VolumePainter(this.value, this.dark);

  final double value;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(
      size.width / 2,
      16 + (1 - value) * (size.height - 32),
    );
    final track = RRect.fromRectAndRadius(
      Rect.fromLTRB(
        size.width / 2 - 4,
        16,
        size.width / 2 + 4,
        size.height - 16,
      ),
      const Radius.circular(4),
    );
    canvas.drawRRect(
      track,
      Paint()..color = dark ? const Color(0xff5f5f5f) : const Color(0xffcecece),
    );
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, center.dy, size.width, size.height));
    canvas.drawRRect(
      track,
      Paint()..color = dark ? const Color(0xffcccccc) : const Color(0xff525252),
    );
    canvas.restore();
    canvas.drawCircle(center, 16, Paint()..color = const Color(0xfff1f1f1));
    canvas.drawCircle(
      center,
      15,
      Paint()
        ..color = const Color(0xff222222)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.save();
    canvas.translate(center.dx - 10, center.dy - 10);
    canvas.scale(20 / 24);
    canvas.drawPath(
      value == 0 ? _mutedSpeaker : _speaker,
      Paint()..color = const Color(0xff222222),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_VolumePainter oldDelegate) =>
      oldDelegate.value != value || oldDelegate.dark != dark;
}

final _speaker = Path()
  ..moveTo(3, 9)
  ..lineTo(3, 15)
  ..lineTo(7, 15)
  ..lineTo(12, 20)
  ..lineTo(12, 4)
  ..lineTo(7, 9)
  ..close()
  ..moveTo(16.5, 12)
  ..relativeCubicTo(0, -1.77, -1.02, -3.29, -2.5, -4.03)
  ..relativeLineTo(0, 8.05)
  ..relativeCubicTo(1.48, -.73, 2.5, -2.25, 2.5, -4.02)
  ..close()
  ..moveTo(14, 3.23)
  ..relativeLineTo(0, 2.06)
  ..relativeCubicTo(2.89, .86, 5, 3.54, 5, 6.71)
  ..relativeCubicTo(0, 3.17, -2.11, 5.85, -5, 6.71)
  ..relativeLineTo(0, 2.06)
  ..relativeCubicTo(4.01, -.91, 7, -4.49, 7, -8.77)
  ..relativeCubicTo(0, -4.28, -2.99, -7.86, -7, -8.77)
  ..close();

final _mutedSpeaker = Path()
  ..moveTo(16.5, 12)
  ..relativeCubicTo(0, -1.77, -1.02, -3.29, -2.5, -4.03)
  ..relativeLineTo(0, 2.21)
  ..relativeLineTo(2.45, 2.45)
  ..relativeCubicTo(.03, -.2, .05, -.41, .05, -.63)
  ..close()
  ..moveTo(19, 12)
  ..relativeCubicTo(0, .94, -.2, 1.82, -.54, 2.64)
  ..relativeLineTo(1.51, 1.51)
  ..cubicTo(20.63, 14.91, 21, 13.5, 21, 12)
  ..relativeCubicTo(0, -4.28, -2.99, -7.86, -7, -8.77)
  ..relativeLineTo(0, 2.06)
  ..relativeCubicTo(2.89, .86, 5, 3.54, 5, 6.71)
  ..close()
  ..moveTo(4.27, 3)
  ..lineTo(3, 4.27)
  ..lineTo(7.73, 9)
  ..lineTo(3, 9)
  ..lineTo(3, 15)
  ..lineTo(7, 15)
  ..lineTo(12, 20)
  ..lineTo(12, 13.27)
  ..relativeLineTo(4.25, 4.25)
  ..relativeCubicTo(-.67, .52, -1.42, .93, -2.25, 1.18)
  ..relativeLineTo(0, 2.06)
  ..relativeCubicTo(1.38, -.31, 2.63, -.95, 3.69, -1.81)
  ..lineTo(19.73, 21)
  ..lineTo(21, 19.73)
  ..relativeLineTo(-9, -9)
  ..close()
  ..moveTo(12, 4)
  ..lineTo(9.91, 6.09)
  ..lineTo(12, 8.18)
  ..close();
