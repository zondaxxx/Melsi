// Melsi design tokens: colour, spacing, radii, typography.
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

/// Continuous-corner radii (rendered as superellipses).
abstract final class Radii {
  static const double xs = 6;
  static const double s = 10;
  static const double m = 14;
  static const double l = 20;
  static const double xl = 26;
  static const double pill = 999;

  static OutlinedBorder shape(double r, {BorderSide side = BorderSide.none}) =>
      RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(r), side: side);
}

/// Colour tokens. Instances for light/dark live in [MelsiColors.light] and
/// [MelsiColors.dark]; access with `context.c`.
@immutable
class MelsiColors extends ThemeExtension<MelsiColors> {
  const MelsiColors({
    required this.brightness,
    required this.background,
    required this.backgroundTint,
    required this.surface,
    required this.surfaceRaised,
    required this.fill,
    required this.fillStrong,
    required this.label,
    required this.secondaryLabel,
    required this.tertiaryLabel,
    required this.separator,
    required this.accent,
    required this.accent2,
    required this.onAccent,
    required this.success,
    required this.warning,
    required this.danger,
    required this.info,
    required this.glass,
    required this.glassHeavy,
    required this.glassEdge,
    required this.shadow,
  });

  final Brightness brightness;

  /// Grouped background (behind cards).
  final Color background;

  /// A faint coloured wash used by page backdrops.
  final Color backgroundTint;

  /// Cards / grouped rows.
  final Color surface;

  /// Sheets, popovers, anything floating above cards.
  final Color surfaceRaised;

  /// Neutral fills for chips, segmented tracks, inputs.
  final Color fill;
  final Color fillStrong;

  final Color label;
  final Color secondaryLabel;
  final Color tertiaryLabel;
  final Color separator;

  /// Indigo → violet brand gradient ends.
  final Color accent;
  final Color accent2;
  final Color onAccent;

  final Color success;
  final Color warning;
  final Color danger;
  final Color info;

  /// Translucent material fills (light = chrome, heavy = sidebars).
  final Color glass;
  final Color glassHeavy;

  /// Hairline highlight along the edge of a material.
  final Color glassEdge;
  final Color shadow;

  bool get isDark => brightness == Brightness.dark;

  LinearGradient get accentGradient => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [accent, accent2],
      );

  LinearGradient get successGradient => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [success, Color.lerp(success, const Color(0xFF00C7BE), 0.6)!],
      );

  /// Latency colour: green < 100ms, yellow < 250ms, red otherwise.
  Color latency(int? ms) {
    if (ms == null || ms <= 0) return tertiaryLabel;
    if (ms < 100) return success;
    if (ms < 250) return warning;
    return danger;
  }

  static const light = MelsiColors(
    brightness: Brightness.light,
    background: Color(0xFFF2F2F7),
    backgroundTint: Color(0xFFE9E7FB),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFFFFFFF),
    fill: Color(0x14767680),
    fillStrong: Color(0x1F767680),
    label: Color(0xFF0B0B12),
    secondaryLabel: Color(0x993C3C43),
    tertiaryLabel: Color(0x4D3C3C43),
    separator: Color(0x2E3C3C43),
    accent: Color(0xFF5B50F0),
    accent2: Color(0xFFA24CF0),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF28B84F),
    warning: Color(0xFFF59E0B),
    danger: Color(0xFFFF3B30),
    info: Color(0xFF0A84FF),
    glass: Color(0xB8F9F9FC),
    glassHeavy: Color(0xD6F2F2F7),
    glassEdge: Color(0x99FFFFFF),
    shadow: Color(0x1A1B1B3A),
  );

  static const dark = MelsiColors(
    brightness: Brightness.dark,
    background: Color(0xFF000000),
    backgroundTint: Color(0xFF14112B),
    surface: Color(0xFF1C1C1E),
    surfaceRaised: Color(0xFF2C2C2E),
    fill: Color(0x2E767680),
    fillStrong: Color(0x3D767680),
    label: Color(0xFFFFFFFF),
    secondaryLabel: Color(0x99EBEBF5),
    tertiaryLabel: Color(0x4DEBEBF5),
    separator: Color(0x40545458),
    accent: Color(0xFF7067FF),
    accent2: Color(0xFFB45CFF),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF30D158),
    warning: Color(0xFFFFB020),
    danger: Color(0xFFFF453A),
    info: Color(0xFF0A84FF),
    glass: Color(0xB01C1C1E),
    glassHeavy: Color(0xD6141416),
    glassEdge: Color(0x24FFFFFF),
    shadow: Color(0x66000000),
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
      backgroundTint: l(backgroundTint, other.backgroundTint),
      surface: l(surface, other.surface),
      surfaceRaised: l(surfaceRaised, other.surfaceRaised),
      fill: l(fill, other.fill),
      fillStrong: l(fillStrong, other.fillStrong),
      label: l(label, other.label),
      secondaryLabel: l(secondaryLabel, other.secondaryLabel),
      tertiaryLabel: l(tertiaryLabel, other.tertiaryLabel),
      separator: l(separator, other.separator),
      accent: l(accent, other.accent),
      accent2: l(accent2, other.accent2),
      onAccent: l(onAccent, other.onAccent),
      success: l(success, other.success),
      warning: l(warning, other.warning),
      danger: l(danger, other.danger),
      info: l(info, other.info),
      glass: l(glass, other.glass),
      glassHeavy: l(glassHeavy, other.glassHeavy),
      glassEdge: l(glassEdge, other.glassEdge),
      shadow: l(shadow, other.shadow),
    );
  }
}

/// Type ramp with size-specific tracking: negative for large sizes, ~0 for
/// body, slightly positive for captions. Leading tightens as size grows.
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
        leadingDistribution: TextLeadingDistribution.even,
      );

  /// 56 — the connection timer.
  TextStyle get display => _s(52, FontWeight.w600, -1.6, 1.0)
      .copyWith(fontFeatures: _tabular);
  TextStyle get largeTitle => _s(34, FontWeight.w700, -0.9, 1.12);
  TextStyle get title1 => _s(28, FontWeight.w700, -0.6, 1.15);
  TextStyle get title2 => _s(22, FontWeight.w700, -0.4, 1.2);
  TextStyle get title3 => _s(20, FontWeight.w600, -0.3, 1.25);
  TextStyle get headline => _s(17, FontWeight.w600, -0.25, 1.3);
  TextStyle get body => _s(16, FontWeight.w400, -0.18, 1.38);
  TextStyle get callout => _s(15, FontWeight.w400, -0.12, 1.36);
  TextStyle get subhead => _s(14, FontWeight.w400, -0.06, 1.36);
  TextStyle get footnote =>
      _s(13, FontWeight.w400, 0, 1.38).copyWith(color: secondary);
  TextStyle get caption =>
      _s(12, FontWeight.w500, 0.1, 1.33).copyWith(color: secondary);
  TextStyle get caption2 =>
      _s(11, FontWeight.w600, 0.35, 1.2).copyWith(color: secondary);

  /// Numbers that tick (speeds, latency) — tabular so they don't jiggle.
  TextStyle get mono => _s(15, FontWeight.w600, -0.2, 1.2)
      .copyWith(fontFeatures: _tabular);

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

  /// Accessibility: user asked for higher contrast (also used as our
  /// "reduce transparency" signal — materials go solid).
  bool get highContrast => MediaQuery.maybeHighContrastOf(this) ?? false;

  bool get isWide => MediaQuery.sizeOf(this).width >= 900;
}
