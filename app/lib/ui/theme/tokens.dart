// Melsi design tokens: colour, spacing, radii, typography.
//
// The visual system is an instrument, not a landing page: a warm-neutral
// monochrome base, one accent (burnt orange) reserved for the primary action
// and selection, and colour otherwise carrying meaning only — green for
// "connected / good", amber and red for "degraded / bad", always as small
// indicators and text. Hierarchy comes from type and hairlines.
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

/// Corner radii: moderate and consistent. Panels and buttons share [m];
/// small controls (tags, code boxes) use [xs]/[s]; sheets use [l].
abstract final class Radii {
  static const double xs = 4;
  static const double s = 6;
  static const double m = 10;
  static const double l = 14;
  static const double pill = 999;

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

  /// Page background (paper in light, warm near-black in dark).
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

  /// The one accent: primary action, selection, links.
  final Color accent;
  final Color onAccent;

  /// Meaning colours — small indicators and text only.
  final Color success;
  final Color warning;
  final Color danger;

  bool get isDark => brightness == Brightness.dark;

  /// Latency colour: green < 100ms, amber < 250ms, red otherwise.
  Color latency(int? ms) {
    if (ms == null || ms <= 0) return tertiaryLabel;
    if (ms < 100) return success;
    if (ms < 250) return warning;
    return danger;
  }

  static const light = MelsiColors(
    brightness: Brightness.light,
    background: Color(0xFFF4F2EF),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFFFFFFF),
    fill: Color(0x0D1B1A17),
    fillStrong: Color(0x1A1B1A17),
    label: Color(0xFF1B1A17),
    secondaryLabel: Color(0x9E1B1A17),
    tertiaryLabel: Color(0x661B1A17),
    separator: Color(0x1F1B1A17),
    accent: Color(0xFFC24E1C),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF1E8A4E),
    warning: Color(0xFF9A6B00),
    danger: Color(0xFFC0392B),
  );

  static const dark = MelsiColors(
    brightness: Brightness.dark,
    background: Color(0xFF141312),
    surface: Color(0xFF1C1B19),
    surfaceRaised: Color(0xFF242220),
    fill: Color(0x12ECE8E1),
    fillStrong: Color(0x22ECE8E1),
    label: Color(0xFFECE8E1),
    secondaryLabel: Color(0xA3ECE8E1),
    tertiaryLabel: Color(0x66ECE8E1),
    separator: Color(0x1FECE8E1),
    accent: Color(0xFFE8763A),
    onAccent: Color(0xFF1B120C),
    success: Color(0xFF4CC272),
    warning: Color(0xFFE0B23E),
    danger: Color(0xFFEE6A5C),
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

/// Monospaced family for metrics (latency, speeds, timer, codes). The name
/// resolves to the platform monospace where one is registered; the fallback
/// list covers iOS/macOS/Windows/Linux system fonts.
const String kMonoFamily = 'monospace';
const List<String> kMonoFallback = [
  'Menlo',
  'SF Mono',
  'Roboto Mono',
  'Consolas',
  'DejaVu Sans Mono',
  'Liberation Mono',
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

  /// Page titles.
  TextStyle get title1 => _s(28, FontWeight.w600, -0.7, 1.15);
  TextStyle get title2 => _s(22, FontWeight.w600, -0.45, 1.2);
  TextStyle get title3 => _s(18, FontWeight.w600, -0.3, 1.25);

  /// Row titles that need emphasis, panel titles.
  TextStyle get headline => _s(16, FontWeight.w600, -0.2, 1.3);
  TextStyle get body => _s(15, FontWeight.w400, -0.1, 1.4);
  TextStyle get callout => _s(14, FontWeight.w400, -0.05, 1.36);
  TextStyle get subhead => _s(14, FontWeight.w500, -0.05, 1.36);
  TextStyle get footnote =>
      _s(13, FontWeight.w400, 0, 1.38).copyWith(color: secondary);
  TextStyle get caption =>
      _s(12, FontWeight.w500, 0.05, 1.33).copyWith(color: secondary);

  /// Small uppercase tracked label (section headers, metric labels). Apply
  /// `.toUpperCase()` to the string; the style only sets the tracking.
  TextStyle get overline =>
      _s(11, FontWeight.w600, 0.8, 1.2).copyWith(color: secondary);

  /// Metrics: monospaced, tabular. [mono] for inline values, [monoSmall]
  /// for codes and protocol tags, [monoLarge] for the headline number of a
  /// panel (latency, speed).
  TextStyle get mono => _m(13, FontWeight.w500, 0, 1.3);
  TextStyle get monoSmall =>
      _m(11, FontWeight.w500, 0.4, 1.2).copyWith(color: secondary);
  TextStyle get monoLarge => _m(22, FontWeight.w500, -0.6, 1.1);
  TextStyle get monoDisplay => _m(34, FontWeight.w500, -1.2, 1.05);

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
