import 'package:flutter/widgets.dart';

/// Tabular number whose digits roll when the value changes (stub: plain
/// text; the motion feature implements the rolling cells).
class MonoNumber extends StatelessWidget {
  const MonoNumber(this.text, {super.key, required this.style, this.semanticsLabel});
  final String text;
  final TextStyle style;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) => Text(
        text,
        maxLines: 1,
        softWrap: false,
        style: style,
        semanticsLabel: semanticsLabel,
      );
}
