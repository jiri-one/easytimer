import 'package:flutter/material.dart';

import 'static_control.dart';
import 'palette.dart';

enum ControlSymbol { play, pause, stop }

class CircleControl extends StatelessWidget {
  const CircleControl({
    super.key,
    required this.label,
    required this.symbol,
    required this.size,
    required this.onPressed,
  });

  final String label;
  final ControlSymbol symbol;
  final double size;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: StaticButton(
      label: label,
      onPressed: onPressed,
      shape: BoxShape.circle,
      child: CustomPaint(
        size: Size.square(size),
        painter: _ControlPainter(symbol, AppPalette.of(context).foreground),
      ),
    ),
  );
}

class _ControlPainter extends CustomPainter {
  _ControlPainter(this.symbol, this.outline);

  final ControlSymbol symbol;
  final Color outline;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    final color = switch (symbol) {
      ControlSymbol.play => AppPalette.playFill,
      ControlSymbol.pause => AppPalette.pauseFill,
      ControlSymbol.stop => AppPalette.stopFill,
    };
    final shape = Path()..addOval(const Rect.fromLTWH(2, 2, 20, 20));
    shape.fillType = PathFillType.evenOdd;
    switch (symbol) {
      case ControlSymbol.play:
        shape.addPath(
          Path()
            ..moveTo(9.5, 7.5)
            ..lineTo(16.5, 12)
            ..lineTo(9.5, 16.5)
            ..close(),
          Offset.zero,
        );
      case ControlSymbol.pause:
        shape.addRect(const Rect.fromLTWH(9, 8, 2, 8));
        shape.addRect(const Rect.fromLTWH(13, 8, 2, 8));
      case ControlSymbol.stop:
        shape.addRect(const Rect.fromLTWH(8, 8, 8, 8));
    }
    canvas.drawPath(shape, Paint()..color = color);
    canvas.drawPath(
      shape,
      Paint()
        ..color = outline
        ..style = PaintingStyle.stroke
        ..strokeWidth = .5,
    );
  }

  @override
  bool shouldRepaint(_ControlPainter oldDelegate) =>
      symbol != oldDelegate.symbol || outline != oldDelegate.outline;
}
