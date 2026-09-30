import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'tokens.dart';

export 'motion.dart';
export 'tokens.dart';

ThemeData buildTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? MelsiColors.dark : MelsiColors.light;
  final t = MelsiType.of(c);
  final scheme = ColorScheme.fromSeed(
    seedColor: c.accent,
    brightness: brightness,
  ).copyWith(
    primary: c.accent,
    onPrimary: c.onAccent,
    secondary: c.accent2,
    surface: c.surface,
    onSurface: c.label,
    error: c.danger,
    outline: c.separator,
    outlineVariant: c.separator,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.background,
    canvasColor: c.background,
    extensions: [c, t],
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: c.fill,
    dividerColor: c.separator,
    dividerTheme: DividerThemeData(color: c.separator, thickness: 0.5, space: 0.5),
    iconTheme: IconThemeData(color: c.label, size: 22),
    textTheme: TextTheme(
      displayLarge: t.display,
      headlineLarge: t.largeTitle,
      headlineMedium: t.title1,
      headlineSmall: t.title2,
      titleLarge: t.title3,
      titleMedium: t.headline,
      titleSmall: t.subhead.copyWith(fontWeight: FontWeight.w600),
      bodyLarge: t.body,
      bodyMedium: t.callout,
      bodySmall: t.footnote,
      labelLarge: t.callout.copyWith(fontWeight: FontWeight.w600),
      labelMedium: t.caption,
      labelSmall: t.caption2,
    ),
    cupertinoOverrideTheme: CupertinoThemeData(
      brightness: brightness,
      primaryColor: c.accent,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.success : c.fillStrong),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.accent,
      selectionColor: c.accent.withValues(alpha: 0.25),
      selectionHandleColor: c.accent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.fill,
      isDense: true,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: Space.m, vertical: Space.m),
      hintStyle: t.body.copyWith(color: c.tertiaryLabel),
      labelStyle: t.callout.copyWith(color: c.secondaryLabel),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.s),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.s),
        borderSide: BorderSide(color: c.accent, width: 1.5),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.isDark ? const Color(0xFF2C2C2E) : const Color(0xFF1C1C1E),
      contentTextStyle: t.callout.copyWith(color: Colors.white),
      shape: Radii.shape(Radii.m),
      elevation: 0,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surfaceRaised,
      modalBackgroundColor: c.surfaceRaised,
      shape: const RoundedSuperellipseBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xl))),
      showDragHandle: false,
      elevation: 0,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surfaceRaised,
      shape: Radii.shape(Radii.l),
      titleTextStyle: t.headline,
      contentTextStyle: t.callout,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.surfaceRaised,
      shape: Radii.shape(Radii.m),
      textStyle: t.callout,
      elevation: 8,
      shadowColor: c.shadow,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.accent,
      linearTrackColor: c.fill,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: ShapeDecoration(
          color: c.isDark ? const Color(0xFF3A3A3C) : const Color(0xFF1C1C1E),
          shape: Radii.shape(Radii.s)),
      textStyle: t.caption.copyWith(color: Colors.white),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: CupertinoPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
      TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
    }),
  );
}
