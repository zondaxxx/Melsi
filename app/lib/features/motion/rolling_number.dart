// Tabular numbers whose digits roll: each digit sits in a fixed-width cell
// and slides to its new value along the shortest way round 0…9, so a timer
// ticks and a speed breathes instead of flickering.

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../ui/theme/theme.dart';

/// [text] rendered with every digit in its own rolling cell (see
/// [RollingDigit]); runs of other characters (":", ".", "—", units) are plain
/// text that cross-fades in 120 ms. A change of length grows or shrinks the
/// whole thing in 180 ms, anchored to the leading edge. The first real value
/// after a dash enters from below.
///
/// Cells are repaint boundaries and carry no semantics of their own: the
/// widget as a whole reads as [semanticsLabel] (or [text]). Reduced motion:
/// the same fixed cells, no rolling.
class MonoNumber extends StatefulWidget {
  const MonoNumber(this.text, {super.key, required this.style, this.semanticsLabel});
  final String text;
  final TextStyle style;
  final String? semanticsLabel;

  @override
  State<MonoNumber> createState() => MonoNumberState();
}

class MonoNumberState extends State<MonoNumber> {
  static bool _isDigit(int code) => code >= 0x30 && code <= 0x39;
  static bool _hasDigits(String s) => s.codeUnits.any(_isDigit);

  /// Whether the previous text had any digit: a value replacing a plain
  /// dash enters from below rather than rolling from nowhere.
  late bool _hadDigits = _hasDigits(widget.text);

  /// Read during build, so cells created in this build know whether they
  /// are the first real value.
  bool _enterFromBelow = false;

  @override
  void didUpdateWidget(MonoNumber oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _enterFromBelow = !_hadDigits;
      _hadDigits = _hasDigits(widget.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduce = context.reduceMotion;
    final scaler = MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling;
    final glyphs = DigitGlyphs.of(widget.style, scaler);
    final text = widget.text;
    final children = <Widget>[];
    var i = 0;
    while (i < text.length) {
      final code = text.codeUnitAt(i);
      if (_isDigit(code)) {
        children.add(RollingDigit(
          key: ValueKey('d$i'),
          digit: code - 0x30,
          glyphs: glyphs,
          reduce: reduce,
          enterFromBelow: _enterFromBelow,
        ));
        i++;
        continue;
      }
      // A run of non-digits, as one Text so words stay findable and
      // shapeable.
      final start = i;
      while (i < text.length && !_isDigit(text.codeUnitAt(i))) {
        i++;
      }
      children.add(_Run(
        key: ValueKey('r$start'),
        text: text.substring(start, i),
        style: widget.style,
        reduce: reduce,
      ));
    }
    _enterFromBelow = false;

    return Semantics(
      label: widget.semanticsLabel ?? text,
      child: ExcludeSemantics(
        child: AnimatedSize(
          duration: Duration(milliseconds: reduce ? 1 : 180),
          curve: Curves.easeOutCubic,
          alignment: AlignmentDirectional.centerStart,
          // A row of cells cannot ellipsize; where a Text would clip, the
          // number scales down instead — still a number, never a stripe.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}

/// Plain characters between digits; a change cross-fades.
class _Run extends StatelessWidget {
  const _Run({super.key, required this.text, required this.style, required this.reduce});
  final String text;
  final TextStyle style;
  final bool reduce;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
        duration: Duration(milliseconds: reduce ? 1 : 120),
        transitionBuilder: (w, a) => FadeTransition(opacity: a, child: w),
        layoutBuilder: (current, previous) => Stack(
          alignment: AlignmentDirectional.centerStart,
          children: [...previous, ?current],
        ),
        child: Text(text, key: ValueKey(text), maxLines: 1, softWrap: false, style: style),
      );
}

/// The ten digit glyphs laid out once per (style, scale): shared by every
/// cell drawn in that style. The cell is as wide as the widest digit (with
/// tabular figures they are all the same) and one line tall.
class DigitGlyphs {
  DigitGlyphs._(TextStyle style, TextScaler scaler)
      : painters = List.generate(
          10,
          (d) => TextPainter(
            text: TextSpan(text: '$d', style: style),
            textDirection: TextDirection.ltr,
            textScaler: scaler,
            maxLines: 1,
          )..layout(),
        ) {
    width = painters.map((p) => p.width).reduce((a, b) => a > b ? a : b).ceilToDouble();
    height = painters.first.height;
    baseline = painters.first.computeDistanceToActualBaseline(TextBaseline.alphabetic);
  }

  final List<TextPainter> painters;
  late final double width;
  late final double height;
  late final double baseline;

  static final Map<(TextStyle, TextScaler), DigitGlyphs> _cache = {};

  /// Cached per style; the cache stays small (a handful of styles exist)
  /// and drops the oldest entry once it grows past [_max].
  static DigitGlyphs of(TextStyle style, TextScaler scaler) {
    final key = (style, scaler);
    final hit = _cache[key];
    if (hit != null) return hit;
    if (_cache.length >= _max) _cache.remove(_cache.keys.first);
    return _cache[key] = DigitGlyphs._(style, scaler);
  }

  static const int _max = 24;
}

/// One digit cell: a fixed-width, one-line-tall window over a column of the
/// glyphs 0…9. Its controller's value is the position in that column; on a
/// change it springs (0.32 s, critically damped) the shortest way round, so
/// 9 → 0 is one step up, not nine down.
class RollingDigit extends StatefulWidget {
  const RollingDigit({
    super.key,
    required this.digit,
    required this.glyphs,
    this.reduce = false,
    this.enterFromBelow = false,
  });

  final int digit;
  final DigitGlyphs glyphs;
  final bool reduce;

  /// Start one step below and roll up into place (first real value).
  final bool enterFromBelow;

  @override
  State<RollingDigit> createState() => RollingDigitState();
}

class RollingDigitState extends State<RollingDigit> with SingleTickerProviderStateMixin {
  static final SpringDescription _spring = Springs.of(0.32, 1.0);

  late final AnimationController _c = AnimationController.unbounded(
    vsync: this,
    value: widget.enterFromBelow && !widget.reduce
        ? widget.digit - 1.0
        : widget.digit.toDouble(),
  );

  /// Column position (tests). Rests exactly on the digit; between digits
  /// while rolling (10 means "just past 9", i.e. 0).
  double get debugValue => _c.value;
  bool get debugAnimating => _c.isAnimating;

  @override
  void initState() {
    super.initState();
    if (widget.enterFromBelow && !widget.reduce) _roll();
  }

  @override
  void didUpdateWidget(RollingDigit oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.digit != widget.digit) _roll();
  }

  void _roll() {
    final target = widget.digit;
    if (widget.reduce) {
      _c.value = target.toDouble();
      return;
    }
    // Shortest way round the wheel from wherever the cell is now.
    var d = (target - _c.value) % 10;
    if (d > 5) d -= 10;
    final to = _c.value + d;
    _c.springTo(to, spring: _spring).then((_) {
      // Rest exactly on the glyph (and back inside 0…9) — crisp text.
      if (mounted && widget.digit == target) _c.value = target.toDouble();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: _DigitCell(position: _c, glyphs: widget.glyphs),
      );
}

class _DigitCell extends LeafRenderObjectWidget {
  const _DigitCell({required this.position, required this.glyphs});
  final Animation<double> position;
  final DigitGlyphs glyphs;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderDigitCell(position, glyphs);

  @override
  void updateRenderObject(BuildContext context, _RenderDigitCell renderObject) {
    renderObject
      ..position = position
      ..glyphs = glyphs;
  }
}

/// Paints the one or two glyphs visible through the cell, clipped; reports
/// the glyph baseline so the cell sits on the line with neighbouring text.
class _RenderDigitCell extends RenderBox {
  _RenderDigitCell(this._position, this._glyphs);

  Animation<double> _position;
  Animation<double> get position => _position;
  set position(Animation<double> v) {
    if (identical(v, _position)) return;
    if (attached) _position.removeListener(markNeedsPaint);
    _position = v;
    if (attached) _position.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  DigitGlyphs _glyphs;
  DigitGlyphs get glyphs => _glyphs;
  set glyphs(DigitGlyphs v) {
    if (identical(v, _glyphs)) return;
    _glyphs = v;
    markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _position.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _position.removeListener(markNeedsPaint);
    super.detach();
  }

  Size get _cell => Size(_glyphs.width, _glyphs.height);

  @override
  double computeMinIntrinsicWidth(double height) => _cell.width;
  @override
  double computeMaxIntrinsicWidth(double height) => _cell.width;
  @override
  double computeMinIntrinsicHeight(double width) => _cell.height;
  @override
  double computeMaxIntrinsicHeight(double width) => _cell.height;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.constrain(_cell);

  @override
  void performLayout() => size = constraints.constrain(_cell);

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => _glyphs.baseline;

  @override
  double? computeDryBaseline(BoxConstraints constraints, TextBaseline baseline) =>
      _glyphs.baseline;

  @override
  bool get isRepaintBoundary => false;

  @override
  void paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    final h = _glyphs.height;
    final w = size.width;
    final pos = _position.value % 10; // Dart's % is non-negative for a positive divisor
    final i = pos.floor();
    final frac = pos - i;
    canvas.save();
    canvas.clipRect(offset & size);
    void draw(int digit, double dy) {
      final p = _glyphs.painters[digit % 10];
      p.paint(canvas, offset + Offset((w - p.width) / 2, dy));
    }

    draw(i, -frac * h);
    if (frac > 0.001) draw(i + 1, (1 - frac) * h);
    canvas.restore();
  }
}
