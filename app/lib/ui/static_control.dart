import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'native_style.dart';

class StaticFocusBorder extends StatelessWidget {
  const StaticFocusBorder({
    super.key,
    required this.focused,
    required this.child,
    this.shape = BoxShape.rectangle,
  });

  final bool focused;
  final Widget child;
  final BoxShape shape;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    position: DecorationPosition.foreground,
    decoration: BoxDecoration(
      shape: shape,
      border: Border.all(
        color: focused ? nativeTextColor(context) : Colors.transparent,
        width: 2,
      ),
    ),
    child: child,
  );
}

class StaticButton extends StatefulWidget {
  const StaticButton({
    super.key,
    required this.label,
    required this.onPressed,
    required this.child,
    this.shape = BoxShape.rectangle,
  });

  final String label;
  final VoidCallback onPressed;
  final Widget child;
  final BoxShape shape;

  @override
  State<StaticButton> createState() => _StaticButtonState();
}

class _StaticButtonState extends State<StaticButton> {
  late final _focus = FocusNode(debugLabel: widget.label);

  void _activate() {
    _focus.requestFocus();
    widget.onPressed();
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focus,
    includeSemantics: false,
    onFocusChange: (_) => setState(() {}),
    onKeyEvent: (_, event) {
      if (event.logicalKey != LogicalKeyboardKey.enter &&
          event.logicalKey != LogicalKeyboardKey.numpadEnter &&
          event.logicalKey != LogicalKeyboardKey.space) {
        return KeyEventResult.ignored;
      }
      if (event is KeyDownEvent) _activate();
      return KeyEventResult.handled;
    },
    child: Semantics(
      label: widget.label,
      button: true,
      enabled: true,
      focusable: true,
      focused: _focus.hasFocus,
      onTap: _activate,
      onFocus: _focus.requestFocus,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTapDown: (_) => _focus.requestFocus(),
          onTap: _activate,
          child: StaticFocusBorder(
            focused: _focus.hasFocus,
            shape: widget.shape,
            child: widget.child,
          ),
        ),
      ),
    ),
  );
}
