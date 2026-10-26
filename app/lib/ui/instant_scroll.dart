import 'dart:math' as math;

import 'package:flutter/widgets.dart';

// Caret reveal and focus traversal must not introduce scrolling animations.
class InstantScrollController extends ScrollController {
  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _InstantScrollPosition(
    physics: physics,
    context: context,
    oldPosition: oldPosition,
  );
}

class _InstantScrollPosition extends ScrollPositionWithSingleContext {
  _InstantScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
  });

  @override
  Future<void> animateTo(
    double to, {
    required Duration duration,
    required Curve curve,
  }) async => jumpTo(to);

  @override
  void goBallistic(double velocity) => goIdle();
}

class InstantScrollView extends StatefulWidget {
  const InstantScrollView({super.key, required this.builder});

  final LayoutWidgetBuilder builder;

  @override
  State<InstantScrollView> createState() => _InstantScrollViewState();
}

class _InstantScrollViewState extends State<InstantScrollView> {
  final _scroll = InstantScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final capped = constraints.loosen().copyWith(
        maxWidth: math.min(constraints.maxWidth, 640),
      );
      return Center(
        child: SingleChildScrollView(
          controller: _scroll,
          physics: const ClampingScrollPhysics(),
          child: SizedBox(
            width: capped.maxWidth,
            child: widget.builder(context, capped),
          ),
        ),
      );
    },
  );
}
