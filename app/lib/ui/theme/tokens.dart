// Melsi design tokens: colour, spacing, radii, typography.
//
// The visual system is a sharp instrument: pure-black AMOLED in dark, a cool
// graphite paper in light, Courier-like monospace throughout, and square
// geometry. One accent (brand violet) is reserved for the primary action and
// selection. Green, amber and red carry meaning only — connected, degraded,
// failed — as small indicators and text. Hierarchy comes from type size and
// hairlines, not shadows or rounded cards.
//
// Everything visual in the app reads from here (via `context.c` / `context.t`)
// so light/dark and high-contrast variants stay consistent.

import 'package:flutter/material.dart';

/// 8pt spacing scale (with a 4pt half-step for tight clusters).
abstract final class Space {
  static const double xxs = 2;
  static const double xs = 4;
  static const double s = 8;
  static const double m = 12;
  static const double l = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double x3 = 32;
  static const double x4 = 40;
  static const double x6 = 48;

  /// Horizontal page gutter on phones / wide layouts.
  static const double gutter = 16;
  static const double gutterWide = 32;
}

/// Corner radii. Square by default: panels, buttons, sheets and tags share
/// a hard edge. [pill] is kept only so older call sites stay rectangular.
abstract final class Radii {
  static const double xs = 0;
  static const double s = 0;
  static const double m = 0;
  static const double l = 0;
  static const double pill = 0;

  static OutlinedBorder shape(double r, {BorderSide side = BorderSide.none}) =>
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(r), side: side);
}

/// Hairline thickness (rendered crisp on 2x and 3x screens).
const double kHairline = 1;

/// Colour tokens. Instances for light/dark live in [MelsiColors.light] and
/// [MelsiColors.dark]; access with `context.c`.
@immutable
class MelsiColors extends ThemeExtension<MelsiColors> {
  const MelsiColors({
    required this.brightness,
    required this.background,
    required this.surface,
    required this.surfaceRaised,
    required this.fill,
    required this.fillStrong,
    required this.label,
    required this.secondaryLabel,
    required this.tertiaryLabel,
    required this.separator,
    required this.accent,
    required this.onAccent,
    required this.success,
    required this.warning,
    required this.danger,
  });

  final Brightness brightness;

  /// Page background (graphite paper in light, pure black in dark).
  final Color background;

  /// Panels / grouped rows — the single "card" level.
  final Color surface;

  /// Sheets, popovers, anything floating above panels.
  final Color surfaceRaised;

  /// Neutral fills for chips, segmented tracks, inputs, hover.
  final Color fill;
  final Color fillStrong;

  final Color label;
  final Color secondaryLabel;
  final Color tertiaryLabel;

  /// Hairline dividers and panel borders.
  final Color separator;

  final Color accent;
  final Color onAccent;

  /// Meaning colours — small indicators and text only.
  final Color success;
  final Color warning;
  final Color danger;

  bool get isDark => brightness == Brightness.dark;

  /// Off-state switch track: the strong fill, a step stronger in dark where
  /// 13% on a card all but disappears.
  Color get offTrack => isDark ? label.withValues(alpha: 0.22) : fillStrong;

  /// Latency colour: green < 100ms, amber < 250ms, red otherwise.
  Color latency(int? ms) {
    if (ms == null || ms <= 0) return tertiaryLabel;
    if (ms < 100) return success;
    if (ms < 250) return warning;
    return danger;
  }

  static const light = MelsiColors(
    brightness: Brightness.light,
    background: Color(0xFFECECEC),
    surface: Color(0xFFF7F7F7),
    surfaceRaised: Color(0xFFFFFFFF),
    fill: Color(0x0F111111),
    fillStrong: Color(0x1A111111),
    label: Color(0xFF111111),
    secondaryLabel: Color(0xFF5E5E5E),
    tertiaryLabel: Color(0xFF8A8A8A),
    separator: Color(0xFFCFCFCF),
    accent: Color(0xFF7053E8),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF147A3E),
    warning: Color(0xFF8A5A00),
    danger: Color(0xFFC62828),
  );

  static const dark = MelsiColors(
    brightness: Brightness.dark,
    background: Color(0xFF000000),
    surface: Color(0xFF070707),
    surfaceRaised: Color(0xFF101010),
    fill: Color(0xFF121212),
    fillStrong: Color(0xFF1C1C1C),
    label: Color(0xFFF4F4F4),
    secondaryLabel: Color(0xFF9A9A9A),
    tertiaryLabel: Color(0xFF6A6A6A),
    separator: Color(0xFF2A2A2A),
    accent: Color(0xFF7053E8),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF3DDC97),
    warning: Color(0xFFE6B450),
    danger: Color(0xFFFF4D4D),
  );

  @override
  MelsiColors copyWith() => this;

  @override
  MelsiColors lerp(covariant MelsiColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return MelsiColors(
      brightness: t < 0.5 ? brightness : other.brightness,
      background: l(background, other.background),
      surface: l(surface, other.surface),
      surfaceRaised: l(surfaceRaised, other.surfaceRaised),
      fill: l(fill, other.fill),
      fillStrong: l(fillStrong, other.fillStrong),
      label: l(label, other.label),
      secondaryLabel: l(secondaryLabel, other.secondaryLabel),
      tertiaryLabel: l(tertiaryLabel, other.tertiaryLabel),
      separator: l(separator, other.separator),
      accent: l(accent, other.accent),
      onAccent: l(onAccent, other.onAccent),
      success: l(success, other.success),
      warning: l(warning, other.warning),
      danger: l(danger, other.danger),
    );
  }
}

/// Bundled Courier-metric family. Cyrillic is in the font files, so Russian
/// and English render the same offline. Fallbacks cover a machine that has
/// not registered the asset yet (tests, first frame).
const String kUiFamily = 'Liberation Mono';
const String kMonoFamily = kUiFamily;
const List<String> kMonoFallback = [
  'Courier New',
  'Courier',
  'monospace',
  'Menlo',
  'Consolas',
  'DejaVu Sans Mono',
];

/// Type ramp with size-specific tracking: negative for large sizes, ~0 for
/// body, positive for the small uppercase labels. Numbers are always tabular.
@immutable
class MelsiType extends ThemeExtension<MelsiType> {
  const MelsiType._(this.color, this.secondary);

  factory MelsiType.of(MelsiColors c) => MelsiType._(c.label, c.secondaryLabel);

  final Color color;
  final Color secondary;

  static const _tabular = [FontFeature.tabularFigures()];

  TextStyle _s(double size, FontWeight w, double tracking, double height) =>
      TextStyle(
        fontFamily: kUiFamily,
        fontFamilyFallback: kMonoFallback,
        fontSize: size,
        fontWeight: w,
        letterSpacing: tracking,
        height: height,
        color: color,
        fontFeatures: _tabular,
        leadingDistribution: TextLeadingDistribution.even,
      );

  TextStyle _m(double size, FontWeight w, double tracking, double height) =>
      _s(size, w, tracking, height).copyWith(
        fontFamily: kMonoFamily,
        fontFamilyFallback: kMonoFallback,
      );

  /// Page titles. Only regular and bold are bundled, so emphasis is w700.
  TextStyle get title1 => _s(28, FontWeight.w700, -0.6, 1.12);
  TextStyle get title2 => _s(22, FontWeight.w700, -0.4, 1.15);
  TextStyle get title3 => _s(18, FontWeight.w700, -0.3, 1.2);

  /// Row titles that need emphasis, panel titles.
  TextStyle get headline => _s(15, FontWeight.w700, 0, 1.25);
  TextStyle get body => _s(14, FontWeight.w400, 0, 1.35);
  TextStyle get callout => _s(13, FontWeight.w400, 0, 1.35);
  TextStyle get subhead => _s(13, FontWeight.w700, 0, 1.3);
  TextStyle get footnote =>
      _s(12, FontWeight.w400, 0, 1.35).copyWith(color: secondary);
  TextStyle get caption =>
      _s(11, FontWeight.w400, 0.4, 1.3).copyWith(color: secondary);

  /// Small uppercase tracked label (section headers, metric labels). Apply
  /// `.toUpperCase()` to the string; the style only sets the tracking.
  TextStyle get overline =>
      _s(10, FontWeight.w700, 1.4, 1.2).copyWith(color: secondary);

  /// Metrics. The whole UI is monospace; these sizes are the numeric ramp.
  TextStyle get mono => _m(13, FontWeight.w400, 0, 1.3);
  TextStyle get monoSmall =>
      _m(11, FontWeight.w400, 0.4, 1.2).copyWith(color: secondary);
  TextStyle get monoLarge => _m(22, FontWeight.w700, -0.4, 1.1);
  TextStyle get monoDisplay => _m(34, FontWeight.w700, -0.8, 1.05);

  @override
  MelsiType copyWith() => this;

  @override
  MelsiType lerp(covariant MelsiType? other, double t) =>
      other == null ? this : MelsiType._(
          Color.lerp(color, other.color, t)!,
          Color.lerp(secondary, other.secondary, t)!);
}

extension MelsiThemeX on BuildContext {
  MelsiColors get c =>
      Theme.of(this).extension<MelsiColors>() ?? MelsiColors.light;
  MelsiType get t =>
      Theme.of(this).extension<MelsiType>() ?? MelsiType.of(c);

  /// Accessibility: user asked for reduced motion.
  bool get reduceMotion => MediaQuery.maybeDisableAnimationsOf(this) ?? false;

  /// Accessibility: user asked for higher contrast — hairlines get stronger.
  bool get highContrast => MediaQuery.maybeHighContrastOf(this) ?? false;

  bool get isWide => MediaQuery.sizeOf(this).width >= 900;
}
