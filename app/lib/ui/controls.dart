import 'package:flutter/material.dart';

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
    child: TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: EdgeInsets.zero,
        shape: const CircleBorder(),
        animationDuration: Duration.zero,
        overlayColor: Colors.transparent,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Semantics(
        label: label,
        child: CustomPaint(
          size: Size.square(size),
          painter: _ControlPainter(
            symbol,
            Theme.of(context).scaffoldBackgroundColor,
          ),
        ),
      ),
    ),
  );
}

class _ControlPainter extends CustomPainter {
  _ControlPainter(this.symbol, this.background);

  final ControlSymbol symbol;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    final color = switch (symbol) {
      ControlSymbol.play => const Color(0xff88d86c),
      ControlSymbol.pause => const Color(0xfff1ee0e),
      ControlSymbol.stop => const Color(0xffcd4d2c),
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
        ..color = const Color(0xff222222)
        ..style = PaintingStyle.stroke
        ..strokeWidth = .5,
    );
  }

  @override
  bool shouldRepaint(_ControlPainter oldDelegate) =>
      symbol != oldDelegate.symbol || background != oldDelegate.background;
}
