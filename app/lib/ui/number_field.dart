import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'instant_scroll.dart';
import 'native_style.dart';
import 'static_control.dart';

class NumberField extends StatefulWidget {
  const NumberField({
    super.key,
    required this.label,
    required this.controller,
    required this.scale,
    required this.onChanged,
    required this.onSubmitted,
    this.hint,
    this.semanticHint,
  });

  final String label;
  final TextEditingController controller;
  final double scale;
  final VoidCallback onChanged;
  final VoidCallback onSubmitted;
  final String? hint;
  final String? semanticHint;

  @override
  State<NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<NumberField> {
  late final _focus = FocusNode(debugLabel: widget.label);
  final _scroll = InstantScrollController();

  @override
  void dispose() {
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final foreground = dark ? const Color(0xffeeeeee) : const Color(0xff212121);
    final style = NativeText.style(18 * widget.scale, foreground, false);
    return ListenableBuilder(
      listenable: Listenable.merge([_focus, widget.controller]),
      builder: (context, _) => Semantics(
        label: widget.label,
        hint: widget.controller.text.isEmpty ? widget.semanticHint : null,
        child: StaticFocusBorder(
          focused: _focus.hasFocus,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _focus.requestFocus,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: dark
                        ? const Color(0xffaaaaaa)
                        : const Color(0xff525252),
                  ),
                ),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: nativeDimension(context, 4, widget.scale),
                  vertical: nativeDimension(context, 8, widget.scale),
                ),
                child: Center(
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (widget.controller.text.isEmpty && widget.hint != null)
                        ExcludeSemantics(
                          child: Text(
                            widget.hint!,
                            style: style.copyWith(
                              color: nativeTextColor(context),
                            ),
                          ),
                        ),
                      EditableText(
                        controller: widget.controller,
                        focusNode: _focus,
                        scrollController: _scroll,
                        style: style,
                        cursorColor: foreground,
                        backgroundCursorColor: foreground,
                        cursorOpacityAnimates: false,
                        showCursor: false,
                        selectionColor: dark
                            ? const Color(0xff666666)
                            : const Color(0xffcccccc),
                        // Selection handles and Material menus fade; keyboard and
                        // accessibility editing remain available without them.
                        contextMenuBuilder: null,
                        showSelectionHandles: false,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.done,
                        textAlign: TextAlign.center,
                        autocorrect: false,
                        enableSuggestions: false,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(4),
                        ],
                        onChanged: (_) => widget.onChanged(),
                        onSubmitted: (_) => widget.onSubmitted(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class NumberStepButton extends StatelessWidget {
  const NumberStepButton({
    super.key,
    required this.label,
    required this.add,
    required this.scale,
    required this.onPressed,
  });

  final String label;
  final bool add;
  final double scale;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: nativeDimension(context, 56, scale),
    child: StaticButton(
      label: label,
      onPressed: onPressed,
      child: Center(
        child: CustomPaint(
          size: Size.square(nativeDimension(context, 24, scale)),
          painter: _StepPainter(add, nativeTextColor(context)),
        ),
      ),
    ),
  );
}

class _StepPainter extends CustomPainter {
  const _StepPainter(this.add, this.color);

  final bool add;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    final paint = Paint()..color = color;
    canvas.drawRect(
      add
          ? const Rect.fromLTWH(5, 11, 14, 2)
          : const Rect.fromLTWH(4, 11, 16, 2),
      paint,
    );
    if (add) canvas.drawRect(const Rect.fromLTWH(11, 5, 2, 14), paint);
  }

  @override
  bool shouldRepaint(_StepPainter oldDelegate) =>
      add != oldDelegate.add || color != oldDelegate.color;
}
