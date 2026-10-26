import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class VolumeControl extends StatelessWidget {
  const VolumeControl({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  void _step(double delta) => onChanged((value + delta).clamp(0, 1));

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      void position(Offset local) {
        final fraction = (1 - (local.dy - 16) / (constraints.maxHeight - 32))
            .clamp(0, 1);
        onChanged((fraction * 100).round() / 100);
      }

      return Semantics(
        label: label,
        slider: true,
        value: '${(value * 100).round()}%',
        increasedValue: '${((value + .05).clamp(0, 1) * 100).round()}%',
        decreasedValue: '${((value - .05).clamp(0, 1) * 100).round()}%',
        onIncrease: () => _step(.05),
        onDecrease: () => _step(-.05),
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowUp): () => _step(.05),
            const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                _step(-.05),
          },
          child: Focus(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) => position(details.localPosition),
              onVerticalDragStart: (details) => position(details.localPosition),
              onVerticalDragUpdate: (details) =>
                  position(details.localPosition),
              child: CustomPaint(
                size: constraints.biggest,
                painter: _VolumePainter(
                  value,
                  Theme.of(context).brightness == Brightness.dark,
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
    final painter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(
          (value == 0 ? Icons.volume_off : Icons.volume_up).codePoint,
        ),
        style: const TextStyle(
          fontFamily: 'MaterialIcons',
          fontSize: 20,
          color: Color(0xff222222),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
    painter.dispose();
  }

  @override
  bool shouldRepaint(_VolumePainter oldDelegate) =>
      oldDelegate.value != value || oldDelegate.dark != dark;
}
