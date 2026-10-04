import 'package:flutter/material.dart';

Color habitAccent(BuildContext context, int value) => ColorScheme.fromSeed(
  seedColor: Color(value),
  brightness: Theme.of(context).brightness,
).primary;

Color readableOn(Color background) =>
    background.computeLuminance() > 0.179 ? Colors.black : Colors.white;

Duration motionDuration(BuildContext context, int milliseconds) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : Duration(milliseconds: milliseconds);

class ColorChoice extends StatelessWidget {
  const ColorChoice({
    super.key,
    required this.value,
    required this.selected,
    required this.onSelected,
  });
  final int value;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) => Semantics(
    label:
        '颜色 #${value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
    button: true,
    selected: selected,
    child: InkWell(
      onTap: onSelected,
      borderRadius: BorderRadius.circular(24),
      child: SizedBox.square(
        dimension: 48,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Color(value),
              shape: BoxShape.circle,
              border: Border.all(
                width: selected ? 3 : 1,
                color: selected
                    ? Theme.of(context).colorScheme.onSurface
                    : Theme.of(context).colorScheme.outline,
              ),
            ),
            child: selected
                ? Icon(
                    Icons.check_rounded,
                    color: readableOn(Color(value)),
                    size: 20,
                  )
                : null,
          ),
        ),
      ),
    ),
  );
}

/// Seven tappable dates retain a 48dp minimum on narrow screens. A horizontal
/// scroll preserves both weekday alignment and the system text scale.
class AccessibleCalendar extends StatelessWidget {
  const AccessibleCalendar({
    super.key,
    required this.child,
    this.minimumWidth = 366,
  });
  final Widget child;
  final double minimumWidth;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: constraints.maxWidth < minimumWidth
            ? minimumWidth
            : constraints.maxWidth,
        child: child,
      ),
    ),
  );
}
